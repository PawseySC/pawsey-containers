#!/bin/bash --login
# This slurm job script shows the steps for compiling user's own solver
# starting from the source code of a typical OpenFOAM existing solver.
# The source code and the resulting binaries are kept in the host.
# But they are compiled and executed from inside the container.

#SBATCH --job-name=preFoam-tutorialCase
#SBATCH --partition=debug
##SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --mem=14GB 
#SBATCH --time=00:10:00

#NOTE: In practice, very similar steps are usually performed manually
#      during the development of user's own tools/solvers.
#      All within an interactive `salloc` allocation.

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
echo

#--- Define the name of the basic OpenFOAM tool to create the "cloned-tool" from (and define the name of user's own tool)
OF_TOOL="icoFoam"
MY_TOOL="myIcoFoam"
echo "Base tool: $OF_TOOL"
echo "My new tool: $MY_TOOL"
echo

#--- Create the directory where the own developed tool will be
MY_TOOL_PATH="${MYSOFTWARE}/OpenFOAM/${USER}-${OF_VERSION}/src/applications/solvers/${MY_TOOL}"
rm -rf ${MY_TOOL_PATH} #Starting test clean
mkdir -p ${MY_TOOL_PATH}
echo "Local path for my tool:"
ls -latd $MY_TOOL_PATH
echo

#--- Find the directory (internal to the image) of the OpenFOAM "mother" tool source files
OF_TOOL_PATH=$(singularity exec $SINGULARITY_CONTAINER bash -c 'find $FOAM_APP -type d -iname "'${OF_TOOL}'"')
if [[ -z $OF_TOOL_PATH ]]; then
   echo "ERROR: Can't find the $OF_TOOL tool inside the container"
   exit 1
fi
echo "Internal path of the tool:"
echo "$OF_TOOL_PATH"
echo

#---  Copy then to the user's development directory
singularity exec $SINGULARITY_CONTAINER bash -c 'cp -r '"${OF_TOOL_PATH}"'/* '"${MY_TOOL_PATH}"
echo "Local tree after copy:"
tree $MY_TOOL_PATH
echo

#--- Update the names and settings as a user's own tool
echo "Updating names and settings."
mv "${MY_TOOL_PATH}/${OF_TOOL}.C" "${MY_TOOL_PATH}/${MY_TOOL}.C"
sed -i "s,${OF_TOOL},${MY_TOOL},g" ${MY_TOOL_PATH}/Make/files
sed -i 's,APPBIN,USER_APPBIN,g' ${MY_TOOL_PATH}/Make/files
echo "Local tree after name and settings update:"
tree $MY_TOOL_PATH
echo

#--- Obtain the internal `WM_PROJECT_USER_DIR` (wmpudInside)
#    and define the local directory (wmpudOutside) that will be binded to the internal path
wmpudInside=$(singularity exec $SINGULARITY_CONTAINER bash -c 'echo $WM_PROJECT_USER_DIR')
wmpudOutside=${MYSOFTWARE}/OpenFOAM/${USER}-${OF_VERSION}
echo "Paths for the binding:"
echo "wmpudOutside=$wmpudOutside"
echo "wmpudInside=$wmpudInside"
echo

#--- Perform the OpenFOAM compilation operations of user's own tools using the binding of paths
cd ${MY_TOOL_PATH}
echo "Compiling with wclean + wmake:"
singularity exec -B $wmpudOutside:$wmpudInside $SINGULARITY_CONTAINER wclean
singularity exec -B $wmpudOutside:$wmpudInside $SINGULARITY_CONTAINER wmake
echo

#--- Verify that the new binary has been created in the right path
myToolBinary="${wmpudOutside}/platforms/linux64GccDPInt32Opt/bin/${MY_TOOL}"
if [[ ! -f $myToolBinary ]]; then
   echo "ERROR: Non existing binary: $myToolBinary"
   exit 1
fi
echo "ls the new tool:"
ls -lat $myToolBinary
echo

#--- Execute basic functionality of the new binary
#    No need to indicate full path as WM_PROJECT_USER_DIR is already in the path defined in the container installation
echo "Testing functionality:"
singularity exec -B $wmpudOutside:$wmpudInside $SINGULARITY_CONTAINER ${MY_TOOL} -help | tee log.${MY_TOOL}.${SLURM_JOBID}
echo

#--- Basic check of correct output
LOGFILE=log.${MY_TOOL}.${SLURM_JOBID}
echo "Checking output:"
if ! grep -q "Usage: ${MY_TOOL}" "$LOGFILE"; then
    echo "ERROR: No Usage ${MY_TOOL} message recognised from execution"
    exit 1
else 
    echo "Correct ✓: ${MY_TOOL} showed Usage message"
fi
echo

#--- Final steps
echo "runCompile.sh: Done"


