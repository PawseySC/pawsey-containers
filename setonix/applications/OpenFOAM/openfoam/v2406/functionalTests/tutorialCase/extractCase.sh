#!/bin/bash
#NOTE: Extraction of the Tutorial case is performed without slurm allocation
#      directly executing this script on the login node
# This script performs only the extraction (copy from the interior of the image) to the host.
# The following two slurm job scripts should be submitted afterwards to run the case:
#    -preFoam.sh (job for preparing the domain decomposition for this case to run in parallel)
#    -runFoam.sh (job for executing the case in parallel)
# NOTE: Check that the Image settings are the same for the three scripts  


#--- Load modules (test assumes image is not part of a module yet)
module load singularity/4.1.0-mpi
module list

#--- Image settings
OF_FORK="openfoam" #OpenFOAM fork: "openfoam" (ESI fork) or "openfoam-org" (Foundation fork)
OF_VERSION="v2406" #OpenFOAM version
UBUNTU_VERSION="24.04" #Ubuntu version
# Exact path of the singularity image:
IMAGE_NAME="${OF_FORK}-testing_${OF_VERSION}-ubuntu${UBUNTU_VERSION}.sif"
#IMAGE_NAME="${OF_FORK}-2ndTest_${OF_VERSION}-ubuntu${UBUNTU_VERSION}.sif"
IMAGE_PATH="${MYSOFTWARE}/singularity/images"
SINGULARITY_CONTAINER="${IMAGE_PATH}/${IMAGE_NAME}"
echo "Image to use: ${SINGULARITY_CONTAINER}"

#--- Case to extract
CASE_NAME="periodicPlaneChannel"
HOST_RUN_DIR="${MYSCRATCH}/OpenFOAM/${USER}-${OF_VERSION}/run"
mkdir -p ${HOST_RUN_DIR}
TEST_CASE="${HOST_RUN_DIR}/${CASE_NAME}"

#--- Extract the case
if [[ ! -d "${TEST_CASE}" ]]; then
   INTERNAL_CASE=$(singularity exec $SINGULARITY_CONTAINER bash -c 'find $FOAM_TUTORIALS -type d -name '"${CASE_NAME}")
   echo "Copying:"
   echo "Internal Tutorial: ${INTERNAL_CASE}"
   echo "Target Case: ${TEST_CASE}"
   singularity exec $SINGULARITY_CONTAINER cp -r $INTERNAL_CASE $TEST_CASE
else
   echo "WARNING: Case directory already exists:"
   echo $TEST_CASE
   echo "No overwriting will be performed. Remove the directory first if you want to obtain a fresh copy."
   exit 1
fi

#--- Basic checks
if [[ ! -d "${TEST_CASE}" ]]; then
    echo "ERROR: Case directory not found after the copy attempt!"
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

#--- Final steps
echo "extractCase.sh: Done"


