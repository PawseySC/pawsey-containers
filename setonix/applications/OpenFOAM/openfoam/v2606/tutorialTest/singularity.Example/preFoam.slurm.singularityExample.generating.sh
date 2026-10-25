#!/bin/bash --login

#SBATCH --job-name=preFoam-tutorialCase-singularityImage
#SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=14720M
#SBATCH --time=00:10:00
#SBATCH --output=preFoam-%j.generating.out

set -Eeuo pipefail
trap 'echo "ERROR: preFoam: line $LINENO: command failed: $BASH_COMMAND" >&2' ERR

printSection() {
   printf '\n\n================================================================\n'
   printf 'preFoam | %s\n' "$1"
   printf '================================================================\n\n'
}

# Prepare the extracted case. Override SINGULARITY_IMAGE, TUTORIAL_WORK_ROOT
# and TUTORIAL_OUTPUT_DIR through the environment when needed.
# Tool logs default to <case>/outputLogs/<tool>-<jobID>.generating.log.
# Slurm saves the complete transcript in the submission directory unless the
# caller supplies sbatch --output with another path (created before submission).

# =============================================================================
# 1. Tutorial settings
# =============================================================================
printSection "1. Tutorial settings"
OPENFOAM_VERSION="v2606"
CASE_NAME="periodicPlaneChannel"
nProcs=4
mGroup=2
logTag="$SLURM_JOB_ID.generating"
printf 'Case: %s | Version: %s | Domains: %s | Job: %s\n' \
   "$CASE_NAME" "$OPENFOAM_VERSION" "$nProcs" "$SLURM_JOB_ID"

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
echo "Tool logs: <tool>-$logTag.log"

# =============================================================================
# 4. Check inputs and restore the initial conditions
# =============================================================================
printSection "4. Check inputs and restore the initial conditions"
for directory in system constant 0.orig; do
   [[ -d "$TEST_CASE/$directory" ]] || {
      echo "ERROR: Missing case directory: $TEST_CASE/$directory" >&2; exit 1;
   }
done
cd -- "$TEST_CASE"
TEST_CASE=$PWD

numberOfSubdomains=$(singularity exec "$SINGULARITY_IMAGE" \
   foamDictionary system/decomposeParDict -entry numberOfSubdomains -value)
[[ "$numberOfSubdomains" == "$nProcs" ]] || {
   echo "ERROR: preFoam specifies nProcs=$nProcs, but decomposeParDict specifies numberOfSubdomains=$numberOfSubdomains." >&2
   echo "Make these settings agree before preparing the case." >&2
   exit 1
}

rm -rf -- 0
cp -a -- 0.orig 0
echo "Initial conditions restored from 0.orig."

# =============================================================================
# 5. Configure collated I/O and remove the previous decomposition
# =============================================================================
printSection "5. Configure collated I/O and remove the previous decomposition"
# Each I/O rank writes a group of mGroup domains: (0 2) for four domains.
of_ioRanks="0"
for ((rank=mGroup; rank<nProcs; rank+=mGroup)); do
   of_ioRanks="$of_ioRanks $rank"
done
export FOAM_IORANKS="($of_ioRanks)"
export SLURM_EXPORT_ENV=ALL
echo "FOAM_IORANKS=$FOAM_IORANKS"
for ((start=0; start<nProcs; start+=mGroup)); do
   end=$((start + mGroup - 1))
   ((end < nProcs)) || end=$((nProcs - 1))
   rm -rf -- "processors${nProcs}_${start}-${end}"
done

# =============================================================================
# 6. Build, check and decompose the mesh
# =============================================================================
printSection "6. Build, check and decompose the mesh"
# pipefail stops the job if either an OpenFOAM command or tee fails.
printSection "6.1 blockMesh - build the mesh"
srun -N 1 -n 1 -c 1 singularity exec "$SINGULARITY_IMAGE" \
   blockMesh 2>&1 | tee "$outputDir/blockMesh-$logTag.log"
printSection "6.2 renumberMesh - reorder the mesh"
srun -N 1 -n 1 -c 1 singularity exec "$SINGULARITY_IMAGE" \
   renumberMesh -overwrite -constant 2>&1 | tee "$outputDir/renumberMesh-$logTag.log"
printSection "6.3 checkMesh - examine mesh quality"
srun -N 1 -n 1 -c 1 singularity exec "$SINGULARITY_IMAGE" \
   checkMesh -allTopology -allGeometry -constant 2>&1 | tee "$outputDir/checkMesh-$logTag.log"
printSection "6.4 decomposePar - distribute the case"
srun -N 1 -n 1 -c 1 singularity exec "$SINGULARITY_IMAGE" \
   decomposePar -cellDist -force 2>&1 | tee "$outputDir/decomposePar-$logTag.log"
if grep -qE 'FOAM FATAL (ERROR|IO ERROR)' \
   "$outputDir/blockMesh-$logTag.log" "$outputDir/renumberMesh-$logTag.log" \
   "$outputDir/checkMesh-$logTag.log" "$outputDir/decomposePar-$logTag.log"; then
   echo "ERROR: Preparation reported an OpenFOAM fatal error" >&2; exit 1
fi

# =============================================================================
# 7. Check that the decomposition is ready for the solver
# =============================================================================
printSection "7. Check that the decomposition is ready for the solver"
for ((start=0; start<nProcs; start+=mGroup)); do
   end=$((start + mGroup - 1))
   ((end < nProcs)) || end=$((nProcs - 1))
   directory="processors${nProcs}_${start}-${end}"
   [[ -d "$directory" ]] || {
      echo "ERROR: Missing collated processor directory: $directory" >&2; exit 1;
   }
done
echo "Decomposition ready: $nProcs subdomains in the expected collated directories."

# =============================================================================
# 8. Summary
# =============================================================================
printSection "8. Summary"
echo "PREPARATION EXECUTION COMPLETE"
echo "Case directory: $TEST_CASE"
echo "Output directory: $outputDir"
echo "Job ID: $SLURM_JOB_ID"
echo "Tool logs: <tool>-$logTag.log"
echo "Scientific acceptance is checked separately by the tutorial audit."
