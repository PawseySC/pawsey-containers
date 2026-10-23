#!/bin/bash --login
# Run and validate the version-specific OpenFOAM tutorial in parallel.
#
# This Slurm job is the final stage of the version-specific tutorial test. It
# expects preFoam.slurm.sh to have prepared and decomposed the case. It checks the
# required case data, runs pimpleFoam across two nodes, and validates the solver
# output before returning its status to openfoamTutorialTestsLauncher.sh.
#
# The general launcher normally submits this job with an afterok dependency on
# preFoam.slurm.sh and provides the image and shared work root. The Slurm defaults
# below also allow direct submission with the same command-line arguments.
#
# Usage:
#   sbatch runFoam.slurm.sh --image <file> --config <file> [options]
#   sbatch runFoam.slurm.sh --shpc --config <file> [options]
#   sbatch runFoam.slurm.sh --bare-metal --config <file> [options]
#
# Exit status:
#   0  The solver ran and all required validations passed.
#   1  Invalid input, missing preparation output, solver failure, or validation
#      failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

#SBATCH --job-name=runFoam-tutorialCase
##SBATCH --partition=debug
#SBATCH --partition=work
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00

# Treat any use of an unset variable as an error.
set -u

# --- Version-specific tutorial settings
CASE_NAME="periodicPlaneChannel"
SOLVER="pimpleFoam"
nProcs=4 # Number of processors in the decomposition
mGroup=2 # Size of the groups for collated file handling
expectedFinalSimulationTime=100
maxReasonableExecutionTime=50 #This is ~2.5 times the usual 20s execution time for this tutorial setting
maxUxLastInitialResidual=0.012

# --- Initial settings
thisScript=$(basename "$0")
imageInput=""
useSHPC=false
useBareMetal=false
workRootInput=""
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
  $thisScript --help

Runtime selection (choose exactly one):
  --image, -i <file>          Use the supplied Singularity image directly
  --shpc                      Load <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>
  --bare-metal                Load <OPENFOAM_FORK>/<OPENFOAM_VERSION> and run the
                              solver directly

Required in both modes:
  --config <file>             Version configuration file defining runtime identity

Optional settings:
  --work-root, -w <directory>
                             Override the shared host work root. By default, the
                             script uses MYSCRATCH/OpenFOAM/<user>-<configured-OpenFOAM-version>.
  --test-artifacts-dir <directory>      Test-artifact destination; defaults to <work-root>/test-output
  --help, -h                 Show this help message and exit

Default work root:
  ${MYSCRATCH:-${TMPDIR:-$HOME}}/OpenFOAM/<user>-<configured-OpenFOAM-version>
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
[[ -n "$configFileInput" ]] || { echo "ERROR: --config is required" >&2; usage >&2; exit 1; }
[[ -r "$configFileInput" ]] || { echo "ERROR: Configuration is not readable: $configFileInput" >&2; exit 1; }
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
   exit 1
}
if [[ -n "$imageInput" ]]; then
   [[ -f "$imageInput" ]] || { echo "ERROR: Singularity image not found: $imageInput" >&2; exit 1; }
   SINGULARITY_CONTAINER=$(realpath "$imageInput")
fi
if [[ -n "$workRootInput" ]]; then workRoot=$(realpath -m "$workRootInput"); else
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
stageName="runFoam"
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
if [[ "$useSHPC" == true ]]; then
   runtimeMode="SHPC module"
   shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
   shpcExec="${OPENFOAM_FORK}-exec"
   solverCommandPrefix=()
   module load "$shpcModule" || { echo "ERROR: Failed to load $shpcModule" >&2; exit 1; }
   command -v "$shpcExec" >/dev/null 2>&1 || { echo "ERROR: Missing wrapper: $shpcExec" >&2; exit 1; }
   command -v "$SOLVER" >/dev/null 2>&1 || { echo "ERROR: Missing solver wrapper: $SOLVER" >&2; exit 1; }
   [[ -n "${SINGULARITY_CONTAINER:-}" && -r "$SINGULARITY_CONTAINER" ]] || { echo "ERROR: Invalid SHPC backing image" >&2; exit 1; }
   SINGULARITY_CONTAINER=$(realpath "$SINGULARITY_CONTAINER")
elif [[ "$useBareMetal" == true ]]; then
   runtimeMode="Bare-metal module"
   #bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
   bareMetalModule="${OPENFOAM_FORK}/2206"
   shpcModule=""
   shpcExec=""
   solverCommandPrefix=()
   module load "$bareMetalModule" || { echo "ERROR: Failed to load bare-metal module: $bareMetalModule" >&2; exit 1; }
   command -v "$SOLVER" >/dev/null 2>&1 || { echo "ERROR: Missing solver: $SOLVER" >&2; exit 1; }
else
   runtimeMode="Explicit Singularity image"
   bareMetalModule=""
   shpcModule=""
   shpcExec=""
   solverCommandPrefix=(singularity exec "$SINGULARITY_CONTAINER")
   module load "$SINGULARITY_MODULE" || { echo "ERROR: Failed to load $SINGULARITY_MODULE" >&2; exit 1; }
   command -v singularity >/dev/null 2>&1 || { echo "ERROR: singularity unavailable" >&2; exit 1; }
fi
echo "Loaded modules:"
module list
echo "Execution mode: $runtimeMode"
if [[ "$useSHPC" == true ]]; then
   echo "SHPC module: $shpcModule"
elif [[ "$useBareMetal" == true ]]; then
   echo "Bare-metal module: $bareMetalModule"
fi
if [[ "$useBareMetal" != true ]]; then echo "Backing image: $SINGULARITY_CONTAINER"; fi
if [[ "$useSHPC" == true ]]; then
   WM_PROJECT_VERSION=$("$shpcExec" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || exit 1
elif [[ "$useBareMetal" != true ]]; then
   WM_PROJECT_VERSION=$(singularity exec "$SINGULARITY_CONTAINER" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || exit 1
else
   WM_PROJECT_VERSION=${WM_PROJECT_VERSION:-}
fi
[[ -n "$WM_PROJECT_VERSION" ]] || { echo "ERROR: WM_PROJECT_VERSION is empty in the runtime environment" >&2; exit 1; }
[[ "$WM_PROJECT_VERSION" == "$OPENFOAM_VERSION" ]] || { echo "ERROR: Runtime version $WM_PROJECT_VERSION does not match $OPENFOAM_VERSION" >&2; exit 1; }
echo "PASS: Runtime WM_PROJECT_VERSION matches OPENFOAM_VERSION='$OPENFOAM_VERSION'"
echo "Case to run: $TEST_CASE"
echo

# --- Check that the allocation matches the prepared decomposition
[[ "${SLURM_JOB_NUM_NODES:-0}" -eq 2 ]] || {
   echo "ERROR: This test requires 2 nodes" >&2
   exit 1
}
[[ "${SLURM_NTASKS:-0}" -eq "$nProcs" ]] || {
   echo "ERROR: This test requires $nProcs tasks" >&2
   exit 1
}
TASKS_PER_NODE=$((SLURM_NTASKS / SLURM_JOB_NUM_NODES))

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
[[ -d "${TEST_CASE}/0" ]] || { echo "ERROR: Missing directory: ${TEST_CASE}/0" >&2; exit 1; }

IORANKS_ARRAY=($of_ioRanks)
for rank in "${IORANKS_ARRAY[@]}"; do
   start=$rank
   (( start >= nProcs )) && break
   end=$((rank + mGroup - 1))
   (( end >= nProcs )) && end=$((nProcs - 1))
   dir="${TEST_CASE}/processors${nProcs}_${start}-${end}"

   [[ -d "$dir" ]] || {
      echo "ERROR: Missing collated processor directory: $dir" >&2
      exit 1
   }
   echo "$dir exists"
done
echo

# --- Execute the solver
# Two nodes are deliberately used to test the image's inter-node MPICH support.
cd "$TEST_CASE" || { echo "ERROR: Could not enter case directory: $TEST_CASE" >&2; exit 1; }
LOGFILE="${outputDir}/${SOLVER}.log"

srun -l -u \
   -N "$SLURM_JOB_NUM_NODES" \
   -n "$SLURM_NTASKS" \
   -c "$SLURM_CPUS_PER_TASK" \
   --ntasks-per-node="$TASKS_PER_NODE" \
   "${solverCommandPrefix[@]}" \
   "$SOLVER" -parallel 2>&1 | tee "$LOGFILE"
solverStatus=${PIPESTATUS[0]}

[[ $solverStatus -eq 0 ]] || {
   echo "ERROR: $SOLVER returned exit status $solverStatus" >&2
   exit 1
}
[[ -s "$LOGFILE" ]] || { echo "ERROR: Solver log is empty: $LOGFILE" >&2; exit 1; }
grep -qE 'FOAM FATAL (ERROR|IO ERROR)' "$LOGFILE" && {
   echo "ERROR: $SOLVER reported an OpenFOAM fatal error" >&2
   exit 1
}

# --- Final log-based validation checks
echo
echo "Running post-run checks on $LOGFILE ..."

grep -qE "(^|[[:space:]])Time = ${expectedFinalSimulationTime}s?([[:space:]]|$)" "$LOGFILE" || {
   echo "ERROR: Simulation did not reach Time = $expectedFinalSimulationTime" >&2
   exit 1
}
echo "PASS: Simulation reached Time = $expectedFinalSimulationTime"

execTime=$(grep "ExecutionTime =" "$LOGFILE" | tail -n 1 | \
   sed -E 's/.*ExecutionTime = ([0-9.eE+-]+).*/\1/')
[[ -n "$execTime" ]] || {
   echo "ERROR: Could not extract ExecutionTime from $LOGFILE" >&2
   exit 1
}

# Runtime varies with system and filesystem load, so this remains a warning.
if ! awk -v actual="$execTime" -v maximum="$maxReasonableExecutionTime" \
   'BEGIN { exit (actual < maximum ? 0 : 1) }'; then
   echo "WARNING: ExecutionTime is high: ${execTime}s; expected less than ${maxReasonableExecutionTime}s" >&2
else
   echo "PASS: ExecutionTime = ${execTime}s"
fi

UxLastInitialResidual=$(grep "Solving for Ux" "$LOGFILE" | tail -n 1 | \
   sed -E 's/.*Initial residual = ([0-9.eE+-]+).*/\1/')
[[ -n "$UxLastInitialResidual" ]] || {
   echo "ERROR: Could not extract the final Ux initial residual from $LOGFILE" >&2
   exit 1
}

awk -v residual="$UxLastInitialResidual" -v maximum="$maxUxLastInitialResidual" \
   'BEGIN { exit (residual < maximum ? 0 : 1) }' || {
      echo "ERROR: Final Ux initial residual $UxLastInitialResidual is not below $maxUxLastInitialResidual" >&2
      exit 1
   }
echo "PASS: Final Ux initial residual = $UxLastInitialResidual"
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
echo "Solver: $SOLVER"
echo "Solver log: $LOGFILE"
echo "ALL STEPS PASSED: OpenFOAM tutorial solver test completed successfully."
exit 0
