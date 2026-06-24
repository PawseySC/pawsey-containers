#!/bin/bash --login
#SBATCH --job-name=T04-mpi4py-2nodes
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:15:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=artifacts/output/slurm-test_04-%j.out

# Focus:
# This test focuses on mpi4py functionality

#--- Strict mode
set -euo pipefail

#--- Helper functions
fail() {
    echo
    echo "TEST_04: FAIL"
    echo "Reason: $*" >&2

    if [[ -n "${OUTPUT_DIR:-}" ]]; then
        mkdir -p "${ARTIFACTS_DIR:-${OUTPUT_DIR}/..}" "${OUTPUT_DIR}"
        echo "$*" > "${OUTPUT_DIR}/test_04.FAIL"
    fi

    exit 1
}

pass() {
    echo
    echo "TEST_04: PASS"

    mkdir -p "${ARTIFACTS_DIR}" "${OUTPUT_DIR}"
    echo "PASS" > "${OUTPUT_DIR}/test_04.PASS"

    exit 0
}

#--- Basic path setup
# This script is expected to be submitted from:
#   pawsey-containers/setonix/mpi/mpich-base/tests
TESTS_DIR="$(realpath "${SLURM_SUBMIT_DIR:-$PWD}")"

if [[ "$(basename "${TESTS_DIR}")" != "tests" ]]; then
    fail "This test must be submitted from the tests directory. Current submit directory: ${TESTS_DIR}"
fi

MPICH_BASE_DIR="$(realpath "${TESTS_DIR}/..")"
MPI_DIR="$(realpath "${MPICH_BASE_DIR}/..")"
SETONIX_DIR="$(realpath "${MPI_DIR}/..")"
REPO_ROOT="$(realpath "${SETONIX_DIR}/..")"

#--- Test directories
FIXTURE_DIR="${TESTS_DIR}/fixtures"
ARTIFACTS_DIR="${TESTS_DIR}/artifacts"
BUILD_DIR="${ARTIFACTS_DIR}/build"
OUTPUT_DIR="${ARTIFACTS_DIR}/output"

mkdir -p "${ARTIFACTS_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"

# Remove stale PASS/FAIL markers from previous runs
rm -f "${OUTPUT_DIR}/test_04.PASS" "${OUTPUT_DIR}/test_04.FAIL"

#--- Names and version settings
MPICH_VERSION="${MPICH_VERSION:-4.2.2}"
OS_VERSION="${OS_VERSION:-24.04}"
IMAGE_NAME="${IMAGE_NAME:-mpich-base}"

IMAGE_DIR="${IMAGE_DIR:-${ARTIFACTS_DIR}/singularityImages}"
AUX_DIR="${AUX_DIR:-${MPI_DIR}/auxiliary}"

#--- Canonical paths
FIXTURE_DIR="$(realpath "${FIXTURE_DIR}")"
ARTIFACTS_DIR="$(realpath "${ARTIFACTS_DIR}")"
BUILD_DIR="$(realpath "${BUILD_DIR}")"
OUTPUT_DIR="$(realpath "${OUTPUT_DIR}")"
IMAGE_DIR="$(realpath "${IMAGE_DIR}")"
AUX_DIR="$(realpath "${AUX_DIR}")"

#--- Defining image to use
IMAGE_TAG="${MPICH_VERSION}-ubuntu${OS_VERSION}"
IMAGE_FULL="${IMAGE_NAME}--${IMAGE_TAG}.sif"
SINGULARITY_IMAGE="${IMAGE_DIR}/${IMAGE_FULL}"

if [[ ! -f "${SINGULARITY_IMAGE}" ]]; then
    fail "Singularity image not found: ${SINGULARITY_IMAGE}"
fi

echo "Using image: ${SINGULARITY_IMAGE}"
echo "Repository root: ${REPO_ROOT}"
echo "Tests directory: ${TESTS_DIR}"
echo "Fixtures directory: ${FIXTURE_DIR}"
echo "Artifacts directory: ${ARTIFACTS_DIR}"
echo "Build directory: ${BUILD_DIR}"
echo "Output directory: ${OUTPUT_DIR}"

#--- Modules and settings
module load singularity/4.1.0-mpi

if [[ "${PAWSEY_CLUSTER:-}" == "joey" ]]; then
    source "${AUX_DIR}/common.Joey.settings.sh"
fi

module list

#--- Input/output files
testScript="${FIXTURE_DIR}/mpi4py_acceptance.py"

fileOutImport="${OUTPUT_DIR}/res_test_04.mpi4py_import.out"
fileOutLinkage="${OUTPUT_DIR}/res_test_04.mpi4py_linkage.out"
fileOutRun="${OUTPUT_DIR}/res_test_04.mpi4py_acceptance.out"

if [[ ! -f "${testScript}" ]]; then
    fail "mpi4py test script not found: ${testScript}"
fi

#--- Python and mpi4py import check
echo
echo "=== Python and mpi4py import check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" python3 - <<'PY' | tee "${fileOutImport}"
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
then
    fail "Python/mpi4py import check failed. See: ${fileOutImport}"
fi

if ! grep -q "mpi4py_package_version=" "${fileOutImport}"; then
    fail "mpi4py package version was not reported. See: ${fileOutImport}"
fi

if ! grep -q "mpi_runtime_version_begin" "${fileOutImport}"; then
    fail "MPI runtime version was not reported during import check. See: ${fileOutImport}"
fi

echo "Python and mpi4py import check passed"

#--- mpi4py linkage check
echo
echo "=== mpi4py linkage check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "MPI_SO=\$(python3 -c 'import mpi4py.MPI as m; print(m.__file__)'); echo \"MPI_SO=\${MPI_SO}\"; ldd \"\${MPI_SO}\" | grep -E 'mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true" \
    | tee "${fileOutLinkage}"; then
    fail "mpi4py linkage command failed. See: ${fileOutLinkage}"
fi

if ! grep -q "/opt/cray/pe/mpich" "${fileOutLinkage}"; then
    fail "Expected mpi4py MPI extension to link against /opt/cray/pe/mpich. See: ${fileOutLinkage}"
fi

if ! grep -q "/opt/cray/libfabric" "${fileOutLinkage}"; then
    fail "Expected mpi4py MPI extension to link against /opt/cray/libfabric. See: ${fileOutLinkage}"
fi

echo "mpi4py linkage check passed"

#--- mpi4py acceptance test
echo
echo "=== mpi4py acceptance: ${SLURM_JOB_NUM_NODES} nodes, ${SLURM_NTASKS_PER_NODE} ranks per node ==="

TOTAL_TASKS=$((SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE))

if ! srun -N "${SLURM_JOB_NUM_NODES}" \
     --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
     singularity exec "${SINGULARITY_IMAGE}" python3 "${testScript}" \
     | tee "${fileOutRun}"; then
    fail "mpi4py acceptance run failed. See: ${fileOutRun}"
fi

expected_success_line="MPI4PY_ACCEPTANCE_SUCCESS size=${TOTAL_TASKS}"

if ! grep -q "${expected_success_line}" "${fileOutRun}"; then
    fail "Expected success line not found: ${expected_success_line}. See: ${fileOutRun}"
fi

if ! grep -q "numpy_buffer_test=PASSED" "${fileOutRun}"; then
    fail "NumPy buffer test did not pass. See: ${fileOutRun}"
fi

RANK_COUNT="$(awk '/^RANK_OK / {c++} END {print c+0}' "${fileOutRun}")"

if [[ "${RANK_COUNT}" -ne "${TOTAL_TASKS}" ]]; then
    fail "Expected ${TOTAL_TASKS} RANK_OK lines, found ${RANK_COUNT}. See: ${fileOutRun}"
fi

HOST_COUNT="$(awk -F= '/^unique_host_count=/ {print $2; found=1} END {if (!found) print ""}' "${fileOutRun}")"

if [[ -z "${HOST_COUNT}" ]]; then
    fail "Could not determine unique_host_count from mpi4py output. See: ${fileOutRun}"
fi

if [[ "${HOST_COUNT}" -lt 2 ]]; then
    fail "Expected ranks to run on at least 2 nodes, but unique_host_count=${HOST_COUNT}. See: ${fileOutRun}"
fi

echo "mpi4py acceptance check passed"
echo "Observed ${RANK_COUNT}/${TOTAL_TASKS} expected MPI ranks"
echo "Observed unique_host_count=${HOST_COUNT}"

pass