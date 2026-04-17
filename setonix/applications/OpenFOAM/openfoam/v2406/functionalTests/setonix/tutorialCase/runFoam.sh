#!/bin/bash --login
# This script executes a tutorial case in parallel in two nodes.
# This will only run if these other scripts were previously succesfully executed:
#    -extractCase.sh (normal bash script to be executed on the login node for copying a tutorial case into the host)
#    -preFoam.sh (slurm job script for preparing the domain decomposition for this case to run in parallel)
# NOTE: Check that the Image settings are the same for the three scripts 

#SBATCH --job-name=runFoam-tutorialCase
#SBATCH --partition=debug
##SBATCH --partition=work
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00

#--- Load modules (test assumes image is not part of a module yet)
module load singularity/4.1.0-mpi
module list

#--- Image settings
OF_FORK="openfoam" #OpenFOAM fork: "openfoam" (ESI fork) or "openfoam-org" (Foundation fork)
OF_VERSION="v2406" #OpenFOAM version
UBUNTU_VERSION="24.04" #Ubuntu version
# Exact path of the singularity image:
IMAGE_NAME="${OF_FORK}_${OF_VERSION}-ubuntu${UBUNTU_VERSION}.sif"
#IMAGE_DIR="${MYSOFTWARE}/singularity/images"
IMAGE_DIR="${MYSCRATCH}/singularity/images"
SINGULARITY_CONTAINER="${IMAGE_DIR}/${IMAGE_NAME}"
echo "Image to use: ${SINGULARITY_CONTAINER}"

#--- Case to execute:
CASE_NAME="periodicPlaneChannel"
HOST_RUN_DIR="${MYSCRATCH}/OpenFOAM/${USER}-${OF_VERSION}/run"
TEST_CASE="${HOST_RUN_DIR}/${CASE_NAME}"

#--- Automating the list of IORANKS for collated fileHandler
echo "Setting the grouping ration for collated fileHandling"
nProcs=4 #Number of total processors in decomposition for this case
mGroup=2   #Size of the groups for collated fileHandling (32 is the initial recommendation for Setonix)
of_ioRanks="0"
iC=$mGroup
while [ $iC -le $nProcs ]; do
   of_ioRanks="$of_ioRanks $iC"
   ((iC += $mGroup))
done
export FOAM_IORANKS="("${of_ioRanks}")"
echo "FOAM_IORANKS=$FOAM_IORANKS"

#--- Basic checks
#    (A previous execution of `preFoam.sh` should have decomposed the case already)
if [[ ! -d "${TEST_CASE}" ]]; then
    echo "ERROR: Case directory not found!"
    exit 1
fi

for d in system constant 0; do
    if [[ "${d}" == "0" ]]; then
        # Accept either 0 or 0.orig
        if [[ ! -d "${TEST_CASE}/0" && ! -d "${TEST_CASE}/0.orig" ]]; then
            echo "ERROR: Missing directory '0' or '0.orig' in case!"
            exit 1
        fi
    else
        if [[ ! -d "${TEST_CASE}/${d}" ]]; then
            echo "ERROR: Missing directory '${d}' in case!"
            exit 1
        fi
    fi
done

IORANKS_ARRAY=($of_ioRanks)
for rank in "${IORANKS_ARRAY[@]}"; do
   start=$rank
   ((start >= nProcs)) && break
   end=$((rank + mGroup - 1))
   ((end >= nProcs)) && end=$((nProcs - 1))
   dir="${TEST_CASE}/processors${nProcs}_${start}-${end}"
   if [[ ! -d $dir ]]; then
      echo "ERROR: Missing collated processor directory $dir"
      exit 1
   else
      echo "$dir exists ✓"
   fi
done

#--- Checking the singularity bindings
# This was needed for running on Joey;
#export SINGULARITY_BINDPATH="/lus/joey/scratch,/lus/joey/software${SINGULARITY_BINDPATH}"
#echo "Checking singularity bindings"
#echo "SINGULARITY_BINDPATH=$SINGULARITY_BINDPATH"

#--- CD into TEST_CASE
cd $TEST_CASE

#-- Execute solver:
#   Instructions were obtained after inspection of the $TEST_CASE/Allrun script):
#   Forcing the use of 2 nodes for testing MPICH functionality.
#   In production jobs, `--ntasks-per-node` setting is usually not needed.
#   In production jobs, `-l` setting is usualy not needed. 
TASKS_PER_NODE=$((SLURM_NTASKS / SLURM_JOB_NUM_NODES))
srun -l -u -N $SLURM_JOB_NUM_NODES -n $SLURM_NTASKS -c 1 --ntasks-per-node=$TASKS_PER_NODE \
   singularity exec $SINGULARITY_CONTAINER pimpleFoam -parallel | tee log.pimpleFoam.${SLURM_JOBID}
#srun -l -u -N 2 -n 4 -c 1 --ntasks-per-node=2 \
#   singularity exec $SINGULARITY_CONTAINER pimpleFoam -parallel | tee log.pimpleFoam.${SLURM_JOBID}

#--- Final log-based validation checks
LOGFILE="log.pimpleFoam.${SLURM_JOBID}"
echo "Running post-run checks on ${LOGFILE}..."

# 0. Expected values
expectedFinalTime=1000
maxExecTime=200
maxUxLastInitialResidual=0.012

# 1. Check final time reached
if ! grep -q "Time = ${expectedFinalTime}" "$LOGFILE"; then
    echo "ERROR: Simulation did not reach Time = ${expectedFinalTime}"
else 
    echo "Correct ✓: Simulation reached Time = ${expectedFinalTime}"
fi

# 2. Extract final ExecutionTime
execTime=$(grep "ExecutionTime =" "$LOGFILE" | tail -1 \
   | sed -E 's/.*ExecutionTime = ([0-9.eE+-]+).*/\1/')

if [[ -z "$execTime" ]]; then
    echo "ERROR: Could not extract ExecutionTime from ${LOGFILE}"
fi

# Compare ExecutionTime < maxExecTime
if [[ $(echo "$execTime < $maxExecTime" | bc -l) -eq 0 ]]; then
    echo "WARNING: ExecutionTime too high: ${execTime}s is greater than limit maxExecTime=${maxExecTime}s"
else
    echo "Correct ✔: ExecutionTime = ${execTime}s is in range. (Less than maxExecTime=${maxExecTime}s)"
fi

# 3. Extract final Ux residual
UxLastInitialResidual=$(grep "Solving for Ux" "$LOGFILE" | tail -1 \
    | sed -E 's/.*Initial residual = ([0-9.eE+-]+).*/\1/')

if [[ -z "$UxLastInitialResidual" ]]; then
    echo "ERROR: Could not extract Ux last initial residual from ${LOGFILE}"
fi

# Compare UxLastInitialResidual < maxUxLastInitialResidual using awk (to handle scientific notation)
if ! awk -v res="$UxLastInitialResidual" -v max="$maxUxLastInitialResidual" 'BEGIN {exit (res < max ? 0 : 1)}'; then
    echo "ERROR: UxLastInitialResidual too high: ${UxLastInitialResidual} is greater than limit maxUxLastInitialResidual=${maxUxLastInitialResidual}"
else
    echo "Correct ✔: UxLastInitialResidual = ${UxLastInitialResidual} is in range. (Less than maxUxLastInitialResidual=${maxUxLastInitialResidual})"
fi

#-- Final steps:
echo "runFoam.sh: Done"