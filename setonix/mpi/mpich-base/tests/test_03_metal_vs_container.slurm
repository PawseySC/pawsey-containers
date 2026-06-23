#!/bin/bash --login
#SBATCH --job-name=T03_metal-vs-cntr
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --time=00:20:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-test_03-%j.out

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
echo "=== Build native binary with Cray wrapper cc ==="
theMetalExe="mpi_perf_compare.metal.exe"
cc -O3 "${theMetalExe%.metal.exe}.c" -o "${theMetalExe}"

echo
echo "=== Build container binary with container mpicc ==="
theImageExe="mpi_perf_compare.image.exe"
singularity exec "${SINGULARITY_IMAGE}" \
    mpicc -O3 "${theImageExe%.image.exe}.c" -o "${theImageExe}"

echo
echo "=== Container binary linkage ==="
fileOutLinkage="res_test_03.linkage.out"
singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "ldd './${theImageExe}' | grep -E 'mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true" \
    | tee "${fileOutLinkage}"

grep -q "/opt/cray/pe/mpich" "${fileOutLinkage}"
grep -q "/opt/cray/libfabric" "${fileOutLinkage}"

echo
echo "============================================================"
echo "METAL_1NODE: 1 node, 8 ranks"
echo "============================================================"
fileOutMetal1Node="res_metal_1node.out"
srun -N 1 -n 8 \
    "./${theMetalExe}" | tee "${fileOutMetal1Node}"

echo
echo "============================================================"
echo "CONTAINER_1NODE: 1 node, 8 ranks"
echo "============================================================"
fileOutCtnr1Node="res_ctnr_1node.out"
srun -N 1 -n 8 \
    singularity exec "${SINGULARITY_IMAGE}" "./${theImageExe}" | tee "${fileOutCtnr1Node}"

echo
echo "============================================================"
echo "METAL_2NODE: 2 nodes, 8 ranks per node"
echo "============================================================"
fileOutMetal2Node="res_metal_2node.out"
srun -N 2 --ntasks-per-node=8 \
    "./${theMetalExe}" | tee "${fileOutMetal2Node}"

echo
echo "============================================================"
echo "CONTAINER_2NODE: 2 nodes, 8 ranks per node"
echo "============================================================"
fileOutCtnr2Node="res_ctnr_2node.out"
srun -N 2 --ntasks-per-node=8 \
    singularity exec "${SINGULARITY_IMAGE}" "./${theImageExe}" | tee "${fileOutCtnr2Node}"

echo
echo "=== Validate successful runs ==="
grep -q "MPI_PERF_TEST_SUCCESS size=8" "${fileOutMetal1Node}"
grep -q "MPI_PERF_TEST_SUCCESS size=8" "${fileOutCtnr1Node}"
grep -q "MPI_PERF_TEST_SUCCESS size=16" "${fileOutMetal2Node}"
grep -q "MPI_PERF_TEST_SUCCESS size=16" "${fileOutCtnr2Node}"

echo
echo "=== Summary ==="
echo "--- native single node ---"
grep -E "PINGPONG|ALLREDUCE" "${fileOutMetal1Node}"

echo
echo "--- container single node ---"
grep -E "PINGPONG|ALLREDUCE" "${fileOutCtnr1Node}"

echo
echo "--- native two node ---"
grep -E "PINGPONG|ALLREDUCE" "${fileOutMetal2Node}"

echo
echo "--- container two node ---"
grep -E "PINGPONG|ALLREDUCE" "${fileOutCtnr2Node}"

echo
echo "TEST_03: Done"