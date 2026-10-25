#!/bin/bash --login

#SBATCH --job-name=runFoam-tutorialCase-singularityImage
#SBATCH --partition=work
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00
#SBATCH --output=runFoam-%j.generating.out

set -Eeuo pipefail
trap 'echo "ERROR: runFoam: line $LINENO: command failed: $BASH_COMMAND" >&2' ERR

printSection() {
   printf '\n\n================================================================\n'
   printf 'runFoam | %s\n' "$1"
   printf '================================================================\n\n'
}

# Run the prepared case. Override SINGULARITY_IMAGE, TUTORIAL_WORK_ROOT
# and TUTORIAL_OUTPUT_DIR through the environment when needed.
# Tool logs default to <case>/outputLogs/<solver>-<jobID>.generating.log.
# Slurm saves the complete transcript in the submission directory unless the
# caller supplies sbatch --output with another path (created before submission).

# =============================================================================
# 1. Tutorial settings
# =============================================================================
printSection "1. Tutorial settings"
OPENFOAM_VERSION="v2606"
CASE_NAME="periodicPlaneChannel"
SOLVER="pimpleFoam"
nProcs=$SLURM_NTASKS
mGroup=2
expectedFinalTime=100
requiredFields=(U p)
logTag="$SLURM_JOB_ID.generating"
printf 'Case: %s | Solver: %s | Tasks: %s | Job: %s\n' \
   "$CASE_NAME" "$SOLVER" "$nProcs" "$SLURM_JOB_ID"

# =============================================================================
# 2. Load the runtime and verify the image
# =============================================================================
printSection "2. Load the runtime and verify the image"
SINGULARITY_MODULE=${SINGULARITY_MODULE:-singularity/4.3.5-mpi}
module load "$SINGULARITY_MODULE"
module list
export SINGULARITY_IMAGE=${SINGULARITY_IMAGE:-"${MYSCRATCH}/pawsey-containers/setonix/applications/OpenFOAM/openfoam/v2606/artifacts/singularity/latest/openfoam--v2606-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04.sif"}
[[ -r "$SINGULARITY_IMAGE" && -f "$SINGULARITY_IMAGE" ]] || {
   echo "ERROR: Image is not a readable file: $SINGULARITY_IMAGE" >&2; exit 1;
}
SINGULARITY_IMAGE=$(realpath -- "$SINGULARITY_IMAGE")
runtimeVersion=$(singularity exec "$SINGULARITY_IMAGE" bash -c 'printf "%s" "$WM_PROJECT_VERSION"')
[[ "$runtimeVersion" == "$OPENFOAM_VERSION" ]] || {
   echo "ERROR: Expected runtime $OPENFOAM_VERSION; found $runtimeVersion" >&2; exit 1;
}

# =============================================================================
# 3. Locate the case and its logs
# =============================================================================
printSection "3. Locate the case and its logs"
TUTORIAL_WORK_ROOT=${TUTORIAL_WORK_ROOT:-"${MYSCRATCH}/OpenFOAM/${USER}-${OPENFOAM_VERSION}/tutorialTesting"}
hostRunDir="$TUTORIAL_WORK_ROOT/run"
TEST_CASE="$hostRunDir/$CASE_NAME"
outputDir=${TUTORIAL_OUTPUT_DIR:-"$TEST_CASE/outputLogs"}
mkdir -p -- "$outputDir"
outputDir=$(cd -- "$outputDir" && pwd)
echo "SINGULARITY_IMAGE=$SINGULARITY_IMAGE"
echo "Output directory: $outputDir"

# =============================================================================
# 4. Match the solver task count to the prepared decomposition
# =============================================================================
printSection "4. Match the solver task count to the prepared decomposition"
for directory in system constant 0; do
   [[ -d "$TEST_CASE/$directory" ]] || {
      echo "ERROR: Missing case directory: $TEST_CASE/$directory" >&2; exit 1;
   }
done
for ((start=0; start<nProcs; start+=mGroup)); do
   end=$((start + mGroup - 1))
   ((end < nProcs)) || end=$((nProcs - 1))
   directory="$TEST_CASE/processors${nProcs}_${start}-${end}"
   [[ -d "$directory" ]] || {
      echo "ERROR: Missing collated processor directory: $directory" >&2; exit 1;
   }
done
echo "Decomposition ready: $nProcs tasks match the expected collated directories."

# =============================================================================
# 5. Configure collated I/O
# =============================================================================
printSection "5. Configure collated I/O"
of_ioRanks="0"
for ((rank=mGroup; rank<nProcs; rank+=mGroup)); do
   of_ioRanks="$of_ioRanks $rank"
done
export FOAM_IORANKS="($of_ioRanks)"
export SLURM_EXPORT_ENV=ALL
echo "FOAM_IORANKS=$FOAM_IORANKS"

# =============================================================================
# 6. Run the solver
# =============================================================================
printSection "6. Run $SOLVER"
# Two nodes are requested above to exercise inter-node MPI.
# pipefail stops the job if either the solver or tee fails.
TASKS_PER_NODE=$((SLURM_NTASKS / SLURM_JOB_NUM_NODES))
cd -- "$TEST_CASE"
TEST_CASE=$PWD
LOGFILE="$outputDir/$SOLVER-$logTag.log"
echo "Solver log: $LOGFILE"
echo
srun -l -u \
   -N "$SLURM_JOB_NUM_NODES" \
   -n "$SLURM_NTASKS" \
   -c "$SLURM_CPUS_PER_TASK" \
   --ntasks-per-node="$TASKS_PER_NODE" \
   singularity exec "$SINGULARITY_IMAGE" \
   "$SOLVER" -parallel 2>&1 | tee "$LOGFILE"
[[ -s "$LOGFILE" ]] || { echo "ERROR: Empty solver log: $LOGFILE" >&2; exit 1; }
if grep -qE 'FOAM FATAL (ERROR|IO ERROR)' "$LOGFILE"; then
   echo "ERROR: $SOLVER reported an OpenFOAM fatal error" >&2; exit 1
fi

# =============================================================================
# 7. Check the final result files in every collated group
# =============================================================================
printSection "7. Check the final result files at time $expectedFinalTime"
for ((start=0; start<nProcs; start+=mGroup)); do
   end=$((start + mGroup - 1))
   ((end < nProcs)) || end=$((nProcs - 1))
   resultDir="processors${nProcs}_${start}-${end}/$expectedFinalTime"
   [[ -d "$resultDir" ]] || {
      echo "ERROR: Missing final-time result directory: $resultDir" >&2; exit 1;
   }
   for field in "${requiredFields[@]}"; do
      [[ -f "$resultDir/$field" && -s "$resultDir/$field" ]] ||
         [[ -f "$resultDir/$field.gz" && -s "$resultDir/$field.gz" ]] || {
         echo "ERROR: Missing or empty result field: $resultDir/$field (or .gz)" >&2
         exit 1
      }
   done
   echo "Result files present: $resultDir (${requiredFields[*]})"
done

# =============================================================================
# 8. Summary
# =============================================================================
printSection "8. Summary"
echo "SOLVER EXECUTION COMPLETE"
echo "Case directory: $TEST_CASE"
echo "Solver log: $LOGFILE"
echo "Job ID: $SLURM_JOB_ID"
echo "Scientific acceptance is checked separately by the tutorial audit."
