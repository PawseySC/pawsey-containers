#!/bin/bash --login
#SBATCH --job-name=test_03_mpi4py
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:15:00
#SBATCH --partition=work
##SBATCH --partition=debug
#SBATCH --output=slurm-%x-%j.out
#SBATCH --error=slurm-%x-%j.err

# Focus:
# This test focuses on mpi4py functionality

# Note:
# This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
# This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.

# Normally this script is submitted by one of the product-specific launchers like:
#
#   pawsey-containers/setonix/mpi/mpich-base/testing/run_tests.sh
#   pawsey-containers/setonix/mpi/lustrempich-base/testing/run_tests.sh
#   pawsey-containers/setonix/mpi/rocm-mpich-base/testing/run_tests.sh
#
# Those launchers define the required environment variables and submit this
# script with sbatch.
#
# Manual submission example, from the relevant product testing directory:
#
#   export REPO_MPI_DIR="/path/to/repo/pawsey-containers/setonix/mpi"
#   export SINGULARITY_IMAGE="/path/to/image.sif"
#   export SINGULARITY_MODULE="singularity/4.1.0-mpi"
#   sbatch --export=REPO_MPI_DIR,SINGULARITY_IMAGE,SINGULARITY_MODULE \
#       /path/to/repo/pawsey-containers/setonix/mpi/tests/test_03_mpi4py.slurm.sh
#
# REPO_MPI_DIR must point to the repository's pawsey-containers/setonix/mpi directory.
# SINGULARITY_IMAGE must point to the container image being tested.
# SINGULARITY_MODULE defaults to singularity/4.1.0-mpi when not exported.

#--- Strict mode
set -euo pipefail

#--- Name used for output files and markers
: "${SLURM_JOB_NAME:?SLURM_JOB_NAME is not set}"
TEST_NAME="${SLURM_JOB_NAME}"

#--- Important variables to be provided as environment variable
# The singularity image to use:
: "${SINGULARITY_IMAGE:?SINGULARITY_IMAGE is not set}"
# The Singularity module to load (default supports direct submission):
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/4.1.0-mpi}"
# The path of the mpi subdirectory in the repository (needed as reference to find the rest of the stuff):
: "${REPO_MPI_DIR:?REPO_MPI_DIR is not set. Submit this test through a run_tests.sh script or export REPO_MPI_DIR manually.}"

#--- Basic path setup
LAUNCH_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
SHARED_TESTS_DIR="$REPO_MPI_DIR/tests"
FIXTURES_DIR="$SHARED_TESTS_DIR/fixtures"
TESTS_SUPPORT_DIR="$SHARED_TESTS_DIR/tests-support"

ARTIFACTS_ROOT_DIR="${LAUNCH_DIR}/artifacts"
RUN_ID="${CI_PIPELINE_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${ARTIFACTS_ROOT_DIR}/singleruns/${TEST_NAME}/${RUN_ID}}"

BUILD_DIR="${BUILD_DIR:-${ARTIFACTS_DIR}/build}"
OUTPUT_DIR="${OUTPUT_DIR:-${ARTIFACTS_DIR}/output}"
PASS_MARKER="$OUTPUT_DIR/${TEST_NAME}.PASS"
FAIL_MARKER="$OUTPUT_DIR/${TEST_NAME}.FAIL"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

rm -f "$PASS_MARKER" "$FAIL_MARKER"

#--- Helper functions
fail() {
    local reason="$*"
    echo
    echo "${TEST_NAME}: FAIL"
    echo "Reason: ${reason}" >&2
    {
        echo "${TEST_NAME}: FAIL"
        echo "Reason: ${reason}"
    } > "${FAIL_MARKER}"
    exit 1
}

pass() {
    echo
    echo "${TEST_NAME}: PASS"
    {
        echo "${TEST_NAME}: PASS"
    } > "${PASS_MARKER}"
}

#--- Resolve absolute path for REPO_MPI_DIR
if ! REPO_MPI_DIR="$(cd "${REPO_MPI_DIR}" && pwd)"; then
    fail "REPO_MPI_DIR does not exist or is not accessible: ${REPO_MPI_DIR}"
fi

#--- Image selected by launcher
if [[ ! -f "${SINGULARITY_IMAGE}" ]]; then
    fail "Singularity image not found: ${SINGULARITY_IMAGE}"
fi
echo "Using image: $SINGULARITY_IMAGE"
echo "Using Singularity module: $SINGULARITY_MODULE"
echo "Launch directory: $LAUNCH_DIR"
echo "MPI directory: $REPO_MPI_DIR"
echo "Shared tests directory: $SHARED_TESTS_DIR"
echo "Fixtures directory: $FIXTURES_DIR"
echo "Build directory: $BUILD_DIR"
echo "Output directory: $OUTPUT_DIR"

#--- Modules and settings
module load "${SINGULARITY_MODULE}"

if [[ "${PAWSEY_CLUSTER:-}" == "joey" ]]; then
    source "${TESTS_SUPPORT_DIR}/common.Joey.settings.sh"
fi

module list

#--- MPI and Slingshot settings
if [[ "${SLURM_JOB_NUM_NODES:-}" -gt 1 ]]; then
    echo "Running on multiple nodes: ${SLURM_JOB_NUM_NODES}"
    echo "Setting MPICH_OFI_STARTUP_CONNECT=1 and MPICH_OFI_VERBOSE=1 for multi-node runs"
    export MPICH_OFI_STARTUP_CONNECT=1
    export MPICH_OFI_VERBOSE=1
else
    echo "Running on a single node: ${SLURM_JOB_NUM_NODES:-1}"
fi

#Setting a random VNI for the test to avoid conflicts with other jobs on the same node
export FI_CXI_DEFAULT_VNI
FI_CXI_DEFAULT_VNI="$(od -vAn -N4 -tu < /dev/urandom)"

echo "MPICH_OFI_STARTUP_CONNECT=${MPICH_OFI_STARTUP_CONNECT}"
echo "MPICH_OFI_VERBOSE=${MPICH_OFI_VERBOSE}"
echo "FI_CXI_DEFAULT_VNI=${FI_CXI_DEFAULT_VNI}"

#--- Input/output files
testScript="${FIXTURES_DIR}/mpi4py_acceptance.py"

fileOutImport="${OUTPUT_DIR}/res_${TEST_NAME}.mpi4py_import.out"
fileOutLinkage="${OUTPUT_DIR}/res_${TEST_NAME}.mpi4py_linkage.out"
fileOutRun="${OUTPUT_DIR}/res_${TEST_NAME}.mpi4py_acceptance.out"

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

if ! grep -Fq "mpi4py_package_version=" "${fileOutImport}"; then
    fail "mpi4py package version was not reported. See: ${fileOutImport}"
fi

if ! grep -Fq "mpi_runtime_version_begin" "${fileOutImport}"; then
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

if ! grep -Fq "/opt/cray/pe/mpich" "${fileOutLinkage}"; then
    fail "Expected mpi4py MPI extension to link against /opt/cray/pe/mpich. See: ${fileOutLinkage}"
fi

if ! grep -Fq "/opt/cray/libfabric" "${fileOutLinkage}"; then
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

if ! grep -Fq "${expected_success_line}" "${fileOutRun}"; then
    fail "Expected success line not found: ${expected_success_line}. See: ${fileOutRun}"
fi

if ! grep -Fq "numpy_buffer_test=PASSED" "${fileOutRun}"; then
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

if ! [[ "${HOST_COUNT}" =~ ^[0-9]+$ ]]; then
    fail "unique_host_count is not numeric: ${HOST_COUNT}. See: ${fileOutRun}"
fi

if [[ "${HOST_COUNT}" -ne "${SLURM_JOB_NUM_NODES}" ]]; then
    fail "Expected ranks to run on ${SLURM_JOB_NUM_NODES} node(s), but unique_host_count=${HOST_COUNT}. See: ${fileOutRun}"
fi

echo "mpi4py acceptance check passed"
echo "Observed ${RANK_COUNT}/${TOTAL_TASKS} expected MPI ranks"
echo "Observed unique_host_count=${HOST_COUNT}"

pass
