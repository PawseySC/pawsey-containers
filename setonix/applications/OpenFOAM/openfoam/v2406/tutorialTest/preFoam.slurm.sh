#!/bin/bash --login
# Prepare the OpenFOAM v2406 periodicPlaneChannel tutorial for parallel execution.
#
# This Slurm job is the second stage of the version-specific tutorial test. It
# expects extractCase.sh to have copied the case to the host work directory. It
# restores the initial conditions, runs the OpenFOAM preparation tools, checks
# their exit statuses, and verifies the resulting collated decomposition.
#
# The general openfoamTutorialTestsLauncher.sh script normally submits this job
# and provides the image and work root. The Slurm defaults below also allow the
# script to be submitted directly with the same command-line arguments.
#
# Usage:
#   sbatch preFoam.slurm.sh --image <file> [--work-root <directory>]
#
# Exit status:
#   0  The case was prepared and decomposed successfully.
#   1  Invalid input, setup failure, command failure, or validation failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

#SBATCH --job-name=preFoam-tutorialCase
#SBATCH --partition=debug
##SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=14GB
#SBATCH --time=00:10:00

# Treat any use of an unset variable as an error.
set -u

# --- Version-specific tutorial settings
CASE_NAME="periodicPlaneChannel"
nProcs=4 # Number of processors in the decomposition
mGroup=2 # Size of the groups for collated file handling
decompositionX=1
decompositionY=2
decompositionZ=2

# --- Initial settings
thisScript=$(basename "$0")
imageInput=""
workRootInput=""
configFileInput=""
testArtifactsDirInput=""
SINGULARITY_MODULE=${SINGULARITY_MODULE:-singularity/4.1.0-mpi}

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  sbatch $thisScript --image <file> --config <file> [--work-root <directory>] [--test-artifacts-dir <directory>]
  $thisScript --help

Options:
  --image, -i <file>          Singularity image containing the OpenFOAM tools
  --work-root, -w <directory>
                             Override the shared host work root. By default, the
                             script uses MYSCRATCH/OpenFOAM/$USER-v2406.
  --config <file>                Version configuration file; required for direct execution
  --test-artifacts-dir <directory>      Test-artifact destination; defaults to <work-root>/test-output
  --help, -h                 Show this help message and exit

Default work root:
  ${MYSCRATCH:-${TMPDIR:-$HOME}}/OpenFOAM/${USER}-v2406
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
      --work-root|-w)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --work-root requires <directory>" >&2; usage >&2; exit 1; }
         workRootInput="$2"
         shift 2
         ;;
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

# --- Resolve the image and case paths
[[ -n "$imageInput" ]] || { echo "ERROR: --image is required" >&2; usage >&2; exit 1; }
[[ -f "$imageInput" ]] || { echo "ERROR: Singularity image not found: $imageInput" >&2; usage >&2; exit 1; }
SINGULARITY_CONTAINER=$(realpath "$imageInput")
[[ -n "$configFileInput" ]] || {
   echo "ERROR: --config is required when this stage is executed independently" >&2
   usage >&2
   exit 1
}
[[ -r "$configFileInput" ]] || {
   echo "ERROR: Configuration is not readable: $configFileInput" >&2
   usage >&2
   exit 1
}
configFile=$(realpath "$configFileInput")
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || { echo "ERROR: $requiredSetting is not defined in $configFile" >&2; exit 1; }
done
imageFileName=$(basename "$SINGULARITY_CONTAINER")
expectedSifPrefix="${OPENFOAM_FORK}--${OPENFOAM_VERSION}"
[[ "$imageFileName" == "${expectedSifPrefix}"*.sif ]] || {
   echo "ERROR: Singularity image filename does not match the configured OpenFOAM identity" >&2
   echo "       Image filename:   $imageFileName" >&2
   echo "       Required pattern: ${expectedSifPrefix}*.sif" >&2
   exit 1
}



if [[ -n "$workRootInput" ]]; then
   workRoot=$(realpath -m "$workRootInput")
else
   baseWorkDir=${MYSCRATCH:-${TMPDIR:-$HOME}}
   workRoot="${baseWorkDir}/OpenFOAM/${USER}-v2406"
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

# --- Load modules
module load "$SINGULARITY_MODULE" || {
   echo "ERROR: Failed to load $SINGULARITY_MODULE" >&2
   exit 1
}
module list
echo "Image to use: $SINGULARITY_CONTAINER"
WM_PROJECT_VERSION=$(singularity exec "$SINGULARITY_CONTAINER" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || { echo "ERROR: Failed to read WM_PROJECT_VERSION from the image environment" >&2; exit 1; }
[[ -n "$WM_PROJECT_VERSION" ]] || { echo "ERROR: WM_PROJECT_VERSION is empty in the image environment" >&2; exit 1; }
[[ "$WM_PROJECT_VERSION" =~ ^v?[0-9][0-9A-Za-z.-]*$ ]] || { echo "ERROR: Invalid WM_PROJECT_VERSION='$WM_PROJECT_VERSION'" >&2; exit 1; }
[[ "$WM_PROJECT_VERSION" == "$OPENFOAM_VERSION" ]] || {
   echo "ERROR: OpenFOAM version mismatch between the image and configuration" >&2
   echo "       Image environment: $WM_PROJECT_VERSION" >&2
   echo "       Configuration:     $OPENFOAM_VERSION" >&2
   exit 1
}
echo "PASS: Image filename and WM_PROJECT_VERSION match OPENFOAM_FORK='$OPENFOAM_FORK' and OPENFOAM_VERSION='$OPENFOAM_VERSION'"
echo "Case to prepare: $TEST_CASE"
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
srun -N 1 -n 1 -c 1 singularity exec "$SINGULARITY_CONTAINER" \
   foamDictionary system/controlDict -entry endTime -set 100 || {
      echo "ERROR: Failed to set endTime in system/controlDict" >&2
      exit 1
   }
srun -N 1 -n 1 -c 1 singularity exec "$SINGULARITY_CONTAINER" \
   foamDictionary system/controlDict -entry writeInterval -set 20 || {
      echo "ERROR: Failed to set writeInterval in system/controlDict" >&2
      exit 1
   }
endTime=$(singularity exec "$SINGULARITY_CONTAINER" \
   foamDictionary system/controlDict -entry endTime -value) || {
      echo "ERROR: Failed to read endTime from system/controlDict" >&2
      exit 1
   }
writeInterval=$(singularity exec "$SINGULARITY_CONTAINER" \
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
srun -N 1 -n 1 -c 1 singularity exec "$SINGULARITY_CONTAINER" \
   foamDictionary system/decomposeParDict \
   -entry numberOfSubdomains -set "$nProcs" || {
      echo "ERROR: Failed to set numberOfSubdomains" >&2
      exit 1
   }
srun -N 1 -n 1 -c 1 singularity exec "$SINGULARITY_CONTAINER" \
   foamDictionary system/decomposeParDict \
   -entry method -set simple || {
      echo "ERROR: Failed to set the decomposition method" >&2
      exit 1
   }
srun -N 1 -n 1 -c 1 singularity exec "$SINGULARITY_CONTAINER" \
   foamDictionary system/decomposeParDict \
   -entry coeffs/n \
   -set "($decompositionX $decompositionY $decompositionZ)" || {
      echo "ERROR: Failed to set the simple decomposition coefficients" >&2
      exit 1
   }
numberOfSubdomains=$(singularity exec "$SINGULARITY_CONTAINER" \
   foamDictionary system/decomposeParDict \
   -entry numberOfSubdomains -value) || {
      echo "ERROR: Failed to read numberOfSubdomains" >&2
      exit 1
   }
decompositionMethod=$(singularity exec "$SINGULARITY_CONTAINER" \
   foamDictionary system/decomposeParDict \
   -entry method -value) || {
      echo "ERROR: Failed to read the decomposition method" >&2
      exit 1
   }
decompositionN=$(singularity exec "$SINGULARITY_CONTAINER" \
   foamDictionary system/decomposeParDict \
   -entry coeffs/n -value) || {
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
   srun -N 1 -n 1 -c 1 singularity exec "$SINGULARITY_CONTAINER" \
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
runOpenFOAMStep renumberMesh renumberMesh -overwrite -constant
runOpenFOAMStep checkMesh checkMesh -allTopology -allGeometry -constant

# checkMesh requires one additional output validation beyond command success.
checkMeshLog="${outputDir}/checkMesh.log"
grep -q "Mesh OK" "$checkMeshLog" || {
   echo "ERROR: checkMesh did not report 'Mesh OK'" >&2
   exit 1
}
echo "PASS: checkMesh reported 'Mesh OK'"
echo

runOpenFOAMStep decomposePar decomposePar -cellDist -force

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
echo "Image: $SINGULARITY_CONTAINER"
echo "ALL STEPS PASSED: OpenFOAM tutorial preparation completed successfully."
exit 0
