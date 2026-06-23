#!/bin/bash --login
#SBATCH --job-name=T01-compile+run-2nodes
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:10:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-test_01-%j.out

#--- Basic
set -euo pipefail
SUBMIT_DIR="$(realpath "${SLURM_SUBMIT_DIR:-$PWD}")"

#--- Names and Version settings
MPICH_VERSION="${MPICH_VERSION:-4.2.2}"
OS_VERSION="${OS_VERSION:-24.04}"
IMAGE_NAME="${IMAGE_NAME:-mpich-base}"
IMAGE_DIR="${IMAGE_DIR:-${SUBMIT_DIR}/ignore/singularityImages}"
AUX_DIR="${AUX_DIR:-${SUBMIT_DIR}/../../auxiliary}"

#--- Cleaning paths
IMAGE_DIR="$(realpath "${IMAGE_DIR}")"
AUX_DIR="$(realpath "${AUX_DIR}")"

#--- Defining image to use
IMAGE_TAG="${MPICH_VERSION}-ubuntu${OS_VERSION}"
IMAGE_FULL="${IMAGE_NAME}--${IMAGE_TAG}.sif"
SINGULARITY_IMAGE="${IMAGE_DIR}/${IMAGE_FULL}"

if [[ ! -f "${SINGULARITY_IMAGE}" ]]; then
    echo "ERROR: Singularity image not found: ${SINGULARITY_IMAGE}" >&2
    exit 1
fi
echo "Using image: ${SINGULARITY_IMAGE}"

#--- Modules and settings
module load singularity/4.1.0-mpi

if [[ "${PAWSEY_CLUSTER:-}" == "joey" ]]; then
    source "${AUX_DIR}/common.Joey.settings.sh"
fi

module list

#--- Proceed with testing
echo "=== Building with container mpicc ==="
theExe="mpi_acceptance.exe"
singularity exec "${SINGULARITY_IMAGE}" mpicc -O2 "${theExe%.exe}.c" -o "${theExe}"

echo
echo "=== Linkage check ==="
fileOutLinkage="res_test_01.linkage.out"
singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "ldd './${theExe}' | grep -E 'mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true" \
    | tee "${fileOutLinkage}"

grep -q "/opt/cray/pe/mpich" "${fileOutLinkage}"
grep -q "/opt/cray/libfabric" "${fileOutLinkage}"

echo
echo "=== Running on ${SLURM_JOB_NUM_NODES} nodes ==="
fileOutRun="res_test_01.run.out"
TOTAL_TASKS=$((SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE))

srun -N "${SLURM_JOB_NUM_NODES}" --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
    singularity exec "${SINGULARITY_IMAGE}" "./${theExe}" | tee "${fileOutRun}"

grep -q "TEST_01_MPI_CONTAINER_BUILD_RUN_SUCCESS size=${TOTAL_TASKS}" "${fileOutRun}"

RANK_COUNT="$(awk '/^RANK_OK / {c++} END {print c+0}' "${fileOutRun}")"
if [[ "${RANK_COUNT}" -ne "${TOTAL_TASKS}" ]]; then
    echo "FAIL: expected ${TOTAL_TASKS} RANK_OK lines, got ${RANK_COUNT}"
    exit 1
fi

echo
echo "TEST_01: Done"
