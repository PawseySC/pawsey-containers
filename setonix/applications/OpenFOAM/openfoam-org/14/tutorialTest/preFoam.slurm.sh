#!/bin/bash --login
# Prepare the version-specific OpenFOAM tutorial for parallel
# execution using either an explicit Singularity image or the installed SHPC
# module for the configured OpenFOAM fork and version.
#
# This Slurm job is the second stage of the version-specific tutorial test. It
# expects extractCase.sh to have copied the case to the host work directory. It
# restores initial conditions, updates dictionaries, runs the serial preparation
# tools, checks their exit statuses, and validates the collated decomposition.
#
# Runtime modes
# -------------
# Explicit-image mode receives --image and executes OpenFOAM commands with
# singularity exec. SHPC mode receives --shpc, derives and loads the container
# module from OPENFOAM_FORK and OPENFOAM_VERSION, and invokes foamDictionary,
# blockMesh, checkMesh, and decomposePar directly through module wrappers. The
# generic <OPENFOAM_FORK>-exec wrapper is used only when no normal OpenFOAM tool
# provides the required operation. Bare-metal mode loads
# <OPENFOAM_FORK>/<OPENFOAM_VERSION> and uses the same tools directly.
#
# The general openfoamTutorialTestLauncher.sh normally submits this job and
# supplies the runtime selection, configuration file, work root, and persistent
# artifact directory. The script can also be submitted independently.
#
# Usage:
#   sbatch preFoam.slurm.sh --image <file> --config <file> [options]
#   sbatch preFoam.slurm.sh --shpc --config <file> [options]
#   sbatch preFoam.slurm.sh --bare-metal --config <file> [options]
#   sbatch preFoam.slurm.sh --image <file> --recipe-dir <directory> [options]
#   sbatch preFoam.slurm.sh --shpc --recipe-dir <directory> [options]
#   sbatch preFoam.slurm.sh --bare-metal --recipe-dir <directory> [options]
#
# Exit status:
#   0  The case was prepared and decomposed successfully.
#   1  Invalid input, runtime setup failure, command failure, or validation failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

#SBATCH --job-name=preFoam-tutorialCase
##SBATCH --partition=debug
#SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=14GB
#SBATCH --time=00:10:00

# Treat any use of an unset variable as an error.
set -u

# --- Version-specific tutorial settings
CASE_NAME="channel395"
nProcs=4 # Number of processors in the decomposition
mGroup=2 # Size of the groups for collated file handling
decompositionX=1
decompositionY=2
decompositionZ=2

# --- Initial settings
thisScript=$(basename "$0")
imageInput=""
useSHPC=false
useBareMetal=false
workRootInput=""
recipeDirInput=""
configFileInput=""
testArtifactsDirInput=""
SINGULARITY_MODULE=${SINGULARITY_MODULE:-singularity/4.3.5-mpi}

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  sbatch $thisScript --image <file> --config <file> [options]
  sbatch $thisScript --shpc --config <file> [options]
  sbatch $thisScript --bare-metal --config <file> [options]
  sbatch $thisScript --image <file> --recipe-dir <directory> [options]
  sbatch $thisScript --shpc --recipe-dir <directory> [options]
  sbatch $thisScript --bare-metal --recipe-dir <directory> [options]
  $thisScript --help

Runtime selection (choose exactly one):
  --image, -i <file>          Use the supplied Singularity image directly
  --shpc                      Load <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>
  --bare-metal                Load <OPENFOAM_FORK>/<OPENFOAM_VERSION> and use the
                              OpenFOAM tools directly

Configuration selection (choose exactly one):
  --recipe-dir, -r <directory>  OpenFOAM version directory containing the
                                buildAndValidationConfig configuration file
  --config <file>             Version configuration file defining OPENFOAM_FORK
                              and OPENFOAM_VERSION

Optional settings:
  --work-root, -w <directory> Override the shared host work root. By default:
                              MYSCRATCH/OpenFOAM/<user>-<configured-version>
  --test-artifacts-dir <directory>
                              Test-artifact destination; defaults to
                              <work-root>/test-output
  --help, -h                  Show this help message and exit

Expected extracted case:
  <work-root>/run/$CASE_NAME

In SHPC mode, OpenFOAM tools are invoked directly through wrappers installed by
its container module. SINGULARITY_CONTAINER records the module's backing image.
USAGE
}

# --- Parse command-line arguments
while [[ $# -gt 0 ]]; do
   case "$1" in
      --image|-i)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --image requires <file>" >&2; usage >&2; exit 1; }
         imageInput="$2"
         shift 2
         ;;
      --shpc)
         useSHPC=true
         shift
         ;;
      --bare-metal)
         useBareMetal=true
         shift
         ;;
      --work-root|-w)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --work-root requires <directory>" >&2; usage >&2; exit 1; }
         workRootInput="$2"
         shift 2
         ;;
      --recipe-dir|-r)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --recipe-dir requires <directory>" >&2; usage >&2; exit 1; }
         recipeDirInput="$2"; shift 2 ;;
      --config)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --config requires <file>" >&2; usage >&2; exit 1; }
         configFileInput="$2"; shift 2 ;;
      --test-artifacts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --test-artifacts-dir requires <directory>" >&2; usage >&2; exit 1; }
         testArtifactsDirInput="$2"; shift 2 ;;
      -h|--help)
         usage
         exit 0
         ;;
      *)
         echo "ERROR: Unknown option '$1'" >&2
         usage >&2
         exit 1
         ;;
   esac
done

# --- Validate common inputs and load version identity
# The configuration is authoritative for fork and version in both runtime modes.
locationSelectorCount=0
[[ -n "$recipeDirInput" ]] && ((locationSelectorCount += 1))
[[ -n "$configFileInput" ]] && ((locationSelectorCount += 1))
[[ $locationSelectorCount -eq 1 ]] || {
   echo "ERROR: Choose exactly one of --recipe-dir <directory> or --config <file>" >&2
   usage >&2
   exit 1
}
if [[ -n "$recipeDirInput" ]]; then
   [[ -d "$recipeDirInput" ]] || { echo "ERROR: Recipe directory not found: $recipeDirInput" >&2; exit 1; }
   recipeDir=$(realpath "$recipeDirInput")
   configFileInput="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
fi
[[ -r "$configFileInput" ]] || { echo "ERROR: Configuration is not readable: $configFileInput" >&2; usage >&2; exit 1; }
configFile=$(realpath "$configFileInput")
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || { echo "ERROR: $requiredSetting is not defined in $configFile" >&2; exit 1; }
done

runtimeSelectorCount=0
[[ -n "$imageInput" ]] && ((runtimeSelectorCount += 1))
[[ "$useSHPC" == true ]] && ((runtimeSelectorCount += 1))
[[ "$useBareMetal" == true ]] && ((runtimeSelectorCount += 1))
[[ $runtimeSelectorCount -eq 1 ]] || {
   echo "ERROR: Choose exactly one of --image <file>, --shpc, or --bare-metal" >&2
   usage >&2
   exit 1
}

if [[ -n "$imageInput" ]]; then
   [[ -f "$imageInput" ]] || { echo "ERROR: Singularity image not found: $imageInput" >&2; exit 1; }
   SINGULARITY_CONTAINER=$(realpath "$imageInput")
fi

if [[ -n "$workRootInput" ]]; then
   workRoot=$(realpath -m "$workRootInput")
else
   baseWorkDir=${MYSCRATCH:-${TMPDIR:-$HOME}}
   workRoot="${baseWorkDir}/OpenFOAM/${USER}-${OPENFOAM_VERSION}"
fi
TEST_CASE="${workRoot}/run/${CASE_NAME}"

# --- Resolve the persistent test-artifact directory
# The launcher passes its timestamped invocation directory. When this stage is
# run independently, the default is the stable <work-root>/test-output path.
workOutputPath="${workRoot}/test-output"
if [[ -n "$testArtifactsDirInput" ]]; then
   outputDir=$(realpath -m "$testArtifactsDirInput")
   mkdir -p "$outputDir" || { echo "ERROR: Could not create test-artifact directory: $outputDir" >&2; exit 1; }
   mkdir -p "$workRoot"
   if [[ -e "$workOutputPath" && ! -L "$workOutputPath" ]]; then
      echo "ERROR: Refusing to replace non-symbolic-link output path: $workOutputPath" >&2
      echo "       Remove it deliberately or omit --test-artifacts-dir to use it directly." >&2
      exit 1
   fi
   ln -sfn "$outputDir" "$workOutputPath"
else
   outputDir="$workOutputPath"
   mkdir -p "$outputDir" || { echo "ERROR: Could not create default test-artifact directory: $outputDir" >&2; exit 1; }
fi
stageName="prepareFoam"
stageRunLog="${outputDir}/${stageName}.run.log"
stageStatusFile="${outputDir}/${stageName}.status.txt"
printf '%s\n' RUNNING > "$stageStatusFile"
record_stage_status() {
   local exitStatus=$?
   trap - EXIT
   if [[ $exitStatus -eq 0 ]]; then
      printf '%s\n' SUCCESS > "$stageStatusFile"
   else
      printf '%s\n' FAILED > "$stageStatusFile"
   fi
   exit "$exitStatus"
}
trap record_stage_status EXIT
exec > >(tee "$stageRunLog") 2>&1

echo "Test artifacts: $outputDir"
echo "Stage run log: $stageRunLog"
echo "Stage status: $stageStatusFile"
echo

# --- Set up and validate the selected OpenFOAM runtime
# In SHPC mode, normal OpenFOAM tool names resolve to module wrappers. In
# explicit-image mode, the command prefix enters the selected SIF.
if [[ "$useSHPC" == true ]]; then
   runtimeMode="SHPC module"
   shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
   shpcExec="${OPENFOAM_FORK}-exec"
   openfoamCommandPrefix=()
   module load "$shpcModule" || { echo "ERROR: Failed to load SHPC module: $shpcModule" >&2; exit 1; }
   command -v "$shpcExec" >/dev/null 2>&1 || { echo "ERROR: SHPC execution wrapper is unavailable: $shpcExec" >&2; exit 1; }
   for openfoamTool in foamDictionary blockMesh checkMesh decomposePar; do
      command -v "$openfoamTool" >/dev/null 2>&1 || { echo "ERROR: OpenFOAM wrapper is unavailable: $openfoamTool" >&2; exit 1; }
   done
   [[ -n "${SINGULARITY_CONTAINER:-}" ]] || { echo "ERROR: $shpcModule did not set SINGULARITY_CONTAINER" >&2; exit 1; }
   [[ -r "$SINGULARITY_CONTAINER" ]] || { echo "ERROR: SHPC backing image is not readable: $SINGULARITY_CONTAINER" >&2; exit 1; }
   SINGULARITY_CONTAINER=$(realpath "$SINGULARITY_CONTAINER")
elif [[ "$useBareMetal" == true ]]; then
   runtimeMode="Bare-metal module"
   bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
   shpcModule=""
   shpcExec=""
   openfoamCommandPrefix=()
   module load "$bareMetalModule" || { echo "ERROR: Failed to load bare-metal module: $bareMetalModule" >&2; exit 1; }
   for openfoamTool in foamDictionary blockMesh checkMesh decomposePar; do
      command -v "$openfoamTool" >/dev/null 2>&1 || { echo "ERROR: OpenFOAM tool is unavailable: $openfoamTool" >&2; exit 1; }
   done
else
   runtimeMode="Explicit Singularity image"
   bareMetalModule=""
   shpcModule=""
   shpcExec=""
   openfoamCommandPrefix=(singularity exec "$SINGULARITY_CONTAINER")
   module load "$SINGULARITY_MODULE" || { echo "ERROR: Failed to load $SINGULARITY_MODULE" >&2; exit 1; }
   command -v singularity >/dev/null 2>&1 || { echo "ERROR: singularity is unavailable after loading $SINGULARITY_MODULE" >&2; exit 1; }
fi

echo "Loaded modules:"
module list
echo "Execution mode: $runtimeMode"
if [[ "$useSHPC" == true ]]; then
   echo "SHPC module: $shpcModule"
   echo "SHPC execution wrapper: $shpcExec"
elif [[ "$useBareMetal" == true ]]; then
   echo "Bare-metal module: $bareMetalModule"
else
   echo "Singularity module: $SINGULARITY_MODULE"
fi
if [[ "$useBareMetal" != true ]]; then echo "Backing image: $SINGULARITY_CONTAINER"; fi

if [[ "$useSHPC" == true ]]; then
   WM_PROJECT_VERSION=$("$shpcExec" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || { echo "ERROR: Failed to read WM_PROJECT_VERSION from the SHPC runtime" >&2; exit 1; }
elif [[ "$useBareMetal" != true ]]; then
   WM_PROJECT_VERSION=$(singularity exec "$SINGULARITY_CONTAINER" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || { echo "ERROR: Failed to read WM_PROJECT_VERSION from the image environment" >&2; exit 1; }
else
   WM_PROJECT_VERSION=${WM_PROJECT_VERSION:-}
fi
[[ -n "$WM_PROJECT_VERSION" ]] || { echo "ERROR: WM_PROJECT_VERSION is empty in the runtime environment" >&2; exit 1; }
[[ "$WM_PROJECT_VERSION" == "$OPENFOAM_VERSION" ]] || {
   echo "ERROR: OpenFOAM version mismatch between the runtime and configuration" >&2
   echo "       Runtime environment: $WM_PROJECT_VERSION" >&2
   echo "       Configuration:       $OPENFOAM_VERSION" >&2
   exit 1
}
echo "PASS: Runtime WM_PROJECT_VERSION matches OPENFOAM_VERSION='$OPENFOAM_VERSION'"
echo

# --- Set the I/O ranks for collated file handling
echo "Setting the grouping ratio for collated file handling"
of_ioRanks="0"
iC=$mGroup
while (( iC <= nProcs )); do
   of_ioRanks="$of_ioRanks $iC"
   ((iC += mGroup))
done
export FOAM_IORANKS="($of_ioRanks)"
echo "FOAM_IORANKS=$FOAM_IORANKS"
echo

# --- Basic checks
[[ -d "$TEST_CASE" ]] || { echo "ERROR: Case directory not found: $TEST_CASE" >&2; exit 1; }
[[ -d "${TEST_CASE}/system" ]] || { echo "ERROR: Missing directory: ${TEST_CASE}/system" >&2; exit 1; }
[[ -d "${TEST_CASE}/constant" ]] || { echo "ERROR: Missing directory: ${TEST_CASE}/constant" >&2; exit 1; }
[[ -d "${TEST_CASE}/0.orig" ]] || { echo "ERROR: Missing directory: ${TEST_CASE}/0.orig" >&2; exit 1; }

# --- Restore the initial conditions and remove an existing decomposition
cd "$TEST_CASE" || { echo "ERROR: Could not enter case directory: $TEST_CASE" >&2; exit 1; }
rm -rf 0
cp -a 0.orig 0 || { echo "ERROR: Failed to restore 0 from 0.orig" >&2; exit 1; }
rm -rf "processors${nProcs}"*

# --- Shorten the tutorial execution and set a suitable output interval
echo "Updating system/controlDict for the functional test"
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary system/controlDict -entry endTime -set 100 || {
      echo "ERROR: Failed to set endTime in system/controlDict" >&2
      exit 1
   }
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary system/controlDict -entry writeInterval -set 20 || {
      echo "ERROR: Failed to set writeInterval in system/controlDict" >&2
      exit 1
   }
endTime=$("${openfoamCommandPrefix[@]}" \
   foamDictionary system/controlDict -entry endTime -value) || {
      echo "ERROR: Failed to read endTime from system/controlDict" >&2
      exit 1
   }
writeInterval=$("${openfoamCommandPrefix[@]}" \
   foamDictionary system/controlDict -entry writeInterval -value) || {
      echo "ERROR: Failed to read writeInterval from system/controlDict" >&2
      exit 1
   }
[[ "$endTime" == "100" ]] || {
   echo "ERROR: Expected endTime=100; found endTime=$endTime" >&2
   exit 1
}
[[ "$writeInterval" == "20" ]] || {
   echo "ERROR: Expected writeInterval=20; found writeInterval=$writeInterval" >&2
   exit 1
}
echo "PASS: controlDict updated with endTime=$endTime and writeInterval=$writeInterval"
echo

# --- Set the decomposition size and distribution for this functional test
echo "Updating system/decomposeParDict for $nProcs processor tasks"
(( decompositionX * decompositionY * decompositionZ == nProcs )) || {
   echo "ERROR: Decomposition ($decompositionX $decompositionY $decompositionZ) does not produce $nProcs subdomains" >&2
   exit 1
}
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary system/decomposeParDict \
   -entry numberOfSubdomains -set "$nProcs" || {
      echo "ERROR: Failed to set numberOfSubdomains" >&2
      exit 1
   }
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary system/decomposeParDict \
   -entry method -set simple || {
      echo "ERROR: Failed to set the decomposition method" >&2
      exit 1
   }
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary system/decomposeParDict \
   -entry simple/n \
   -set "($decompositionX $decompositionY $decompositionZ)" || {
      echo "ERROR: Failed to set the simple decomposition coefficients" >&2
      exit 1
   }
numberOfSubdomains=$("${openfoamCommandPrefix[@]}" \
   foamDictionary system/decomposeParDict \
   -entry numberOfSubdomains -value) || {
      echo "ERROR: Failed to read numberOfSubdomains" >&2
      exit 1
   }
decompositionMethod=$("${openfoamCommandPrefix[@]}" \
   foamDictionary system/decomposeParDict \
   -entry method -value) || {
      echo "ERROR: Failed to read the decomposition method" >&2
      exit 1
   }
decompositionN=$("${openfoamCommandPrefix[@]}" \
   foamDictionary system/decomposeParDict \
   -entry simple/n -value) || {
      echo "ERROR: Failed to read the decomposition coefficients" >&2
      exit 1
   }
[[ "$numberOfSubdomains" == "$nProcs" ]] || {
   echo "ERROR: Expected numberOfSubdomains=$nProcs; found $numberOfSubdomains" >&2
   exit 1
}
[[ "$decompositionMethod" == "simple" ]] || {
   echo "ERROR: Expected method=simple; found $decompositionMethod" >&2
   exit 1
}
# Parse the returned vector so harmless whitespace differences are ignored.
read -r actualX actualY actualZ extraValue <<< "${decompositionN//[()]/}"
[[ "$actualX" == "$decompositionX" &&
   "$actualY" == "$decompositionY" &&
   "$actualZ" == "$decompositionZ" &&
   -z "$extraValue" ]] || {
   echo "ERROR: Expected coeffs/n=($decompositionX $decompositionY $decompositionZ); found $decompositionN" >&2
   exit 1
}
echo "PASS: decomposeParDict configured for $numberOfSubdomains subdomains"
echo "      method=$decompositionMethod, n=$decompositionN"
echo

# --- Function that executes one serial OpenFOAM preparation step
# The first argument supplies a short step name used for the log file and error
# messages. All remaining arguments are passed directly to the OpenFOAM command.
# PIPESTATUS[0] preserves the status of srun even though output is piped to tee.
runOpenFOAMStep() {
   local stepName="$1"
   shift
   local logFile="${outputDir}/${stepName}.log"
   local stepStatus

   echo "Running: $*"
   srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
      "$@" 2>&1 | tee "$logFile"
   stepStatus=${PIPESTATUS[0]}

   [[ $stepStatus -eq 0 ]] || {
      echo "ERROR: $stepName failed with exit status $stepStatus" >&2
      exit 1
   }

   grep -qE 'FOAM FATAL (ERROR|IO ERROR)' "$logFile" && {
      echo "ERROR: $stepName reported an OpenFOAM fatal error" >&2
      exit 1
   }

   echo "PASS: $stepName completed successfully"
   echo
}

# --- Run the serial OpenFOAM preparation tools
# Each call remains explicit and follows the order in the tutorial Allrun script.
runOpenFOAMStep blockMesh blockMesh
#runOpenFOAMStep renumberMesh renumberMesh -overwrite -constant
runOpenFOAMStep checkMesh checkMesh -allTopology -allGeometry -constant

# checkMesh requires one additional output validation beyond command success.
checkMeshLog="${outputDir}/checkMesh.log"
grep -q "Mesh OK" "$checkMeshLog" || {
   echo "ERROR: checkMesh did not report 'Mesh OK'" >&2
   exit 1
}
echo "PASS: checkMesh reported 'Mesh OK'"
echo

runOpenFOAMStep decomposePar decomposePar -cellProc -force

# --- Check the collated processor directories
echo
echo "Checking collated processor directories ..."
IORANKS_ARRAY=($of_ioRanks)
for rank in "${IORANKS_ARRAY[@]}"; do
   start=$rank
   (( start >= nProcs )) && break
   end=$((rank + mGroup - 1))
   (( end >= nProcs )) && end=$((nProcs - 1))
   dir="processors${nProcs}_${start}-${end}"

   [[ -d "$dir" ]] || {
      echo "ERROR: Missing collated processor directory: $dir" >&2
      exit 1
   }
   echo "$dir exists"
done

echo "PASS: Collated processor directories are complete"
echo

# --- Final summary
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Tutorial case: $CASE_NAME"
echo "Case directory: $TEST_CASE"
echo "Execution mode: $runtimeMode"
if [[ "$useSHPC" == true ]]; then
   echo "SHPC module: $shpcModule"
elif [[ "$useBareMetal" == true ]]; then
   echo "Bare-metal module: $bareMetalModule"
else
   echo "Backing image: $SINGULARITY_CONTAINER"
fi
echo "ALL STEPS PASSED: OpenFOAM tutorial preparation completed successfully."
exit 0
