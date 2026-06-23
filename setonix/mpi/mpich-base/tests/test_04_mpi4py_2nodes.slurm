#!/bin/bash --login
#SBATCH --job-name=T04-mpi4py-2nodes
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:15:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-test_04-%j.out

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
testScript="${SUBMIT_DIR}/mpi4py_acceptance.py"

if [[ ! -f "${testScript}" ]]; then
    echo "ERROR: mpi4py test script not found: ${testScript}" >&2
    exit 1
fi

echo "=== Python and mpi4py import check ==="
singularity exec "${SINGULARITY_IMAGE}" python3 - <<'PY'
import sys
print("python_executable=", sys.executable)
print("python_version=", sys.version.replace("\n", " "))
from mpi4py import MPI
import mpi4py
print("mpi4py_package_version=", mpi4py.__version__)
print("mpi4py_MPI_extension=", MPI.__file__)
print("mpi_runtime_version_begin")
print(MPI.Get_library_version(), end="")
print("mpi_runtime_version_end")
PY

echo
echo "=== mpi4py linkage check ==="
fileOutLinkage="res_test_03.mpi4py_linkage.out"

singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "MPI_SO=\$(python3 -c 'import mpi4py.MPI as m; print(m.__file__)'); echo \"MPI_SO=\${MPI_SO}\"; ldd \"\${MPI_SO}\" | grep -E 'mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true" \
    | tee "${fileOutLinkage}"

grep -q "/opt/cray/pe/mpich" "${fileOutLinkage}"
grep -q "/opt/cray/libfabric" "${fileOutLinkage}"

echo
echo "=== mpi4py acceptance: ${SLURM_JOB_NUM_NODES} nodes, ${SLURM_NTASKS_PER_NODE} ranks per node ==="
fileOutRun="res_test_03.mpi4py_acceptance.out"

srun -N "${SLURM_JOB_NUM_NODES}" --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
    singularity exec "${SINGULARITY_IMAGE}" python3 "${testScript}" | tee "${fileOutRun}"

TOTAL_TASKS=$((SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE))

grep -q "MPI4PY_ACCEPTANCE_SUCCESS size=${TOTAL_TASKS}" "${fileOutRun}"
grep -q "numpy_buffer_test=PASSED" "${fileOutRun}"

RANK_COUNT="$(grep -c "^RANK_OK " "${fileOutRun}")"
if [[ "${RANK_COUNT}" -ne "${TOTAL_TASKS}" ]]; then
    echo "ERROR: Expected ${TOTAL_TASKS} RANK_OK lines, found ${RANK_COUNT}" >&2
    exit 1
fi

HOST_COUNT="$(grep "MPI4PY_ACCEPTANCE_SUCCESS" "${fileOutRun}" | sed -E 's/.*unique_hosts=([0-9]+).*/\1/')"
if [[ "${HOST_COUNT}" -lt 2 ]]; then
    echo "ERROR: Expected ranks to run on 2 nodes, but unique_hosts=${HOST_COUNT}" >&2
    exit 1
fi

echo
echo "TEST_04: Done"
