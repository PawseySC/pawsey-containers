#!/bin/bash --login
#SBATCH --job-name=T02-osu-2nodes
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:15:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-test_02-%j.out

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
echo "=== OSU binaries ==="
singularity exec "${SINGULARITY_IMAGE}" bash -lc '
command -v osu_latency
command -v osu_bw
command -v osu_allreduce
'

echo
echo "=== Linkage check ==="
fileOutLinkage="res_test_02.linkage.out"

singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "ldd \"\$(command -v osu_latency)\" | grep -E 'mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true" \
    | tee "${fileOutLinkage}"

grep -q "/opt/cray/pe/mpich" "${fileOutLinkage}"
grep -q "/opt/cray/libfabric" "${fileOutLinkage}"

echo
echo "=== OSU latency: 2 nodes, 1 rank per node ==="
fileOutLatency="res_test_02.osu_latency.out"

srun -N 2 -n 2 --ntasks-per-node=1 \
    singularity exec "${SINGULARITY_IMAGE}" osu_latency | tee "${fileOutLatency}"

grep -q "# OSU MPI Latency Test" "${fileOutLatency}"
grep -q "^4[[:space:]]" "${fileOutLatency}"
grep -q "^1048576[[:space:]]" "${fileOutLatency}"

echo
echo "=== OSU bandwidth: 2 nodes, 1 rank per node ==="
fileOutBW="res_test_02.osu_bw.out"

srun -N 2 -n 2 --ntasks-per-node=1 \
    singularity exec "${SINGULARITY_IMAGE}" osu_bw | tee "${fileOutBW}"

grep -q "# OSU MPI Bandwidth Test" "${fileOutBW}"
grep -q "^1048576[[:space:]]" "${fileOutBW}"

echo
echo "=== OSU allreduce: ${SLURM_JOB_NUM_NODES} nodes, ${SLURM_NTASKS_PER_NODE} ranks per node ==="
fileOutReduce="res_test_02.osu_allreduce.out"

srun -N "${SLURM_JOB_NUM_NODES}" --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
    singularity exec "${SINGULARITY_IMAGE}" osu_allreduce | tee "${fileOutReduce}"

grep -q "# OSU MPI Allreduce Latency Test" "${fileOutReduce}"
grep -q "^4[[:space:]]" "${fileOutReduce}"
grep -q "^1048576[[:space:]]" "${fileOutReduce}"

echo
echo "TEST_02: Done"