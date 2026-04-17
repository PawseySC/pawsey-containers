#!/bin/bash --login
# This script prepares the domain decomposition for the tutorial case to run in parallel
# This will only run if this other script was previously succesfully executed:
#    -extractCase.sh (normal bash script to be executed on the login node for copying a tutorial case into the host)
# The following slurm job script should be submitted afterwards to run the case:
#    -runFoam.sh (slurm job script for executing the case in parallel)
# NOTE: Check that the Image settings are the same for the three scripts 

#SBATCH --job-name=preFoam-tutorialCase
#SBATCH --partition=debug
##SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mem=14GB 
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

#--- Case to prepare:
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

#--- Checking the singularity bindings
# This was needed for running on Joey;
#export SINGULARITY_BINDPATH="/lus/joey/scratch,/lus/joey/software${SINGULARITY_BINDPATH}"
#echo "Checking singularity bindings"
#echo "SINGULARITY_BINDPATH=$SINGULARITY_BINDPATH"

#--- CD into TEST_CASE directory and restore the `0` Dir and removing existing decomposition
cd $TEST_CASE
rm -rf 0
cp -r 0.orig 0
rm -rf "processors${nProcs}"*

#--- Execute tools (instructions were obtained after inspection of the $TEST_CASE/Allrun script):
#    All these tools are serial
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_CONTAINER blockMesh | tee log.blockMesh.${SLURM_JOBID}
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_CONTAINER renumberMesh -overwrite -constant | tee log.renumberMesh.${SLURM_JOBID}
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_CONTAINER checkMesh -allTopology -allGeometry -constant | tee log.checkMesh.${SLURM_JOBID}
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_CONTAINER decomposePar -cellDist | tee log.decomposePar.${SLURM_JOBID}

#--- Checks of existance of decomposition
echo "Checking collated processor directories ..."

IORANKS_ARRAY=($of_ioRanks)
for rank in "${IORANKS_ARRAY[@]}"; do
   start=$rank
   ((start >= nProcs)) && break
   end=$((rank + mGroup - 1))
   ((end >= nProcs)) && end=$((nProcs - 1))
   dir="processors${nProcs}_${start}-${end}"
   if [[ ! -d $dir ]]; then
      echo "ERROR: Missing collated processor directory $dir"
      exit 1
   else
      echo "$dir exists ✓"
   fi
done

echo "Collated processor directories check: OK"

#--- Final steps:
echo "preFoam.sh: Done"

