#!/bin/bash --login

#SBATCH --job-name=runFoam-tutorialCase-singularityImage
#SBATCH --partition=work
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00

# --- Version-specific tutorial settings
OPENFOAM_VERSION="v2606"
CASE_NAME="periodicPlaneChannel"
SOLVER="pimpleFoam"
nProcs=4 # Number of processors in the decomposition
mGroup=2 # Size of the groups for collated file handling
expectedFinalSimulationTime=100
maxReasonableExecutionTime=50 #This is ~2.5 times the usual 20s execution time for this tutorial setting
maxUxLastInitialResidual=0.012
TASKS_PER_NODE=$((SLURM_NTASKS / SLURM_JOB_NUM_NODES))

#--- Load neccessary modules and/or image:
SINGULARITY_MODULE=${SINGULARITY_MODULE:-singularity/4.3.5-mpi}
module load $SINGULARITY_MODULE
module list
export SINGULARITY_IMAGE=${SINGULARITY_IMAGE:-"${MYSCRATCH}/pawsey-containers/setonix/applications/OpenFOAM/openfoam/v2606/artifacts/singularity/latest/openfoam--v2606-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04.sif"}
echo "Using openfoam singularity image:"
echo "SINGULARITY_IMAGE=$SINGULARITY_IMAGE"
echo

#--- Path definitions
TUTORIAL_WORK_ROOT=${TUTORIAL_WORK_ROOT:-"${MYSCRATCH}/OpenFOAM/${USER}-${OPENFOAM_VERSION}/tutorialTesting"}
hostRunDir="$TUTORIAL_WORK_ROOT/run"
TEST_CASE="${hostRunDir}/${CASE_NAME}"
outputDir="$hostRunDir/outputLogs"
mkdir -p "$outputDir" || { echo "ERROR: Could not create output directory: $outputDir" >&2; exit 1; }

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
   singularity exec $SINGULARITY_IMAGE \
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
echo "Solver: $SOLVER"
echo "Solver log: $LOGFILE"
echo "ALL STEPS PASSED: OpenFOAM tutorial solver test completed successfully."
exit 0
