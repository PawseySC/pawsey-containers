#!/bin/bash --login
#SBATCH --job-name=T01-compile+run-2nodes
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:10:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-test_01-%j.out

set -euo pipefail

MPICH_VERSION="3.4.3"
#MPICH_VERSION="4.2.2"
OS_VERSION="24.04"
IMAGE_NAME="mpich-base"
IMAGE_BRANCH="${MPICH_VERSION}-ubuntu${OS_VERSION}"
IMAGE_DIR="${MYSCRATCH}/pawsey-containers/setonix/mpi/mpich-base/ignore/singularity"
#IMAGE_DIR="../ignore/singularity"
SINGULARITY_IMAGE="${IMAGE_DIR}/${IMAGE_NAME}--${IMAGE_BRANCH}.sif"
if [[ -f $SINGULARITY_IMAGE ]]; then
    echo "Using image: $SINGULARITY_IMAGE"
else
    echo "Singularity image not found: $SINGULARITY_IMAGE"
    exit 1
fi

module load singularity/4.1.0-mpi
[[ "$PAWSEY_CLUSTER" == "joey" ]] && source common.Joey.settings.sh
module list

echo "=== Building with container mpicc ==="
theExe="mpi_acceptance.exe"
singularity exec "${SINGULARITY_IMAGE}" mpicc -O2 "${theExe%.exe}.c" -o $theExe

echo
echo "=== Linkage check ==="
fileOutLinkage="res_test_01.linkage.out"
singularity exec "${SINGULARITY_IMAGE}" bash -lc "
ldd ./${theExe}"' | egrep "mpi|fabric|cxi|pmi|pmix|pals|xpmem" || true
' | tee $fileOutLinkage

grep -q "/opt/cray/pe/mpich" $fileOutLinkage
grep -q "/opt/cray/libfabric" $fileOutLinkage

echo
echo "=== Running on 2 nodes ==="
fileOutRun="res_test_01.run.out"
TOTAL_TASKS=$((SLURM_NNODES * SLURM_NTASKS_PER_NODE))

srun -N 2 --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
    singularity exec "${SINGULARITY_IMAGE}" "./${theExe}" | tee $fileOutRun

grep -q "TEST_01_MPI_CONTAINER_BUILD_RUN_SUCCESS size=${TOTAL_TASKS}" $fileOutRun

RANK_COUNT=$(grep -c "^RANK_OK " $fileOutRun)
if [[ "${RANK_COUNT}" -ne "${TOTAL_TASKS}" ]]; then
    echo "FAIL: expected ${TOTAL_TASKS} RANK_OK lines, got ${RANK_COUNT}"
    exit 1
fi

echo
echo "TEST_01_SUCCESS"
