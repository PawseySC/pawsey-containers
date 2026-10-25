#!/bin/bash --login

#SBATCH --job-name=preFoam-tutorialCase-singularityImage
#SBATCH --partition=work
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=14720M
#SBATCH --time=00:10:00

# --- Version-specific tutorial settings
OPENFOAM_VERSION="v2606"
CASE_NAME="periodicPlaneChannel"
nProcs=4   #Number of total processors in decomposition for this case
mGroup=2   #Size of the groups for collated fileHandling (check recommendation for Setonix in Pawsey documentation)

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

#--- Execute Mesh tools:
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_IMAGE blockMesh | tee "${outputDir}/blockMesh.log"
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_IMAGE renumberMesh -overwrite -constant | tee "${outputDir}/renumberMesh.log"
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_IMAGE checkMesh -allTopology -allGeometry -constant | tee "${outputDir}/checkMesh.log"

# checkMesh requires one additional output validation beyond command success.
checkMeshLog="${outputDir}/checkMesh.log"
grep -q "Mesh OK" "$checkMeshLog" || {
   echo "ERROR: checkMesh did not report 'Mesh OK'" >&2
   exit 1
}
echo "PASS: checkMesh reported 'Mesh OK'"
echo

#--- Execute Decomposition:
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_IMAGE decomposePar -cellDist -force | tee "${outputDir}/decomposePar.log"

# Check the collated processor directories
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
echo "ALL STEPS PASSED: OpenFOAM tutorial preparation completed successfully."
exit 0
