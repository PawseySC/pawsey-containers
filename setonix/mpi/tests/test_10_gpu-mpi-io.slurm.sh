#!/bin/bash --login
#SBATCH --job-name=test_10_gpu-mpi-io
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --gres=gpu:4
#SBATCH --time=00:10:00
#SBATCH --partition=gpu
#SBATCH --output=slurm-%x-%j.out
#SBATCH --error=slurm-%x-%j.err
#SBATCH --account=pawsey0001-gpu

# Focus:
# This test checks that MPI IO functions in a container running on GPU nodes and compatible with GPUs
# NOTE: This is not a test of MPI I/O using GPU buffers, this is MPI I/O using CPU buffers, 
#       but running on GPU nodes in a GPU-compatible container

# Note:
# This script is based off previous scripts developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.

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
#       /path/to/repo/pawsey-containers/setonix/mpi/tests/test_01_compile+run.slurm.sh
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
src="${FIXTURES_DIR}/mpi_io.cpp"
theExe="${BUILD_DIR}/mpi_io.exe"

fileOutCompile="${OUTPUT_DIR}/res_${TEST_NAME}.compile.out"
fileOutLinkage="${OUTPUT_DIR}/res_${TEST_NAME}.linkage.out"
fileOutRun="${OUTPUT_DIR}/res_${TEST_NAME}.run.out"

if [[ ! -f "${src}" ]]; then
    fail "Fixture source file not found: ${src}"
fi

#--- Compile test
echo
echo "=== Building with container mpicc ==="

if ! singularity exec "${SINGULARITY_IMAGE}" \
    mpic++ -O2 "${src}" -o "${theExe}" \
    > "${fileOutCompile}" 2>&1; then
    fail "Compilation failed. See: ${fileOutCompile}"
fi

if [[ ! -x "${theExe}" ]]; then
    fail "Expected executable was not created or is not executable: ${theExe}"
fi

echo "Compilation succeeded: ${theExe}"

#--- Linkage test
echo
echo "=== Linkage check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "ldd '${theExe}' | grep -E 'mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true" \
    | tee "${fileOutLinkage}"; then
    fail "Linkage check command failed. See: ${fileOutLinkage}"
fi

if ! grep -Fq "/opt/cray/pe/mpich" "${fileOutLinkage}"; then
    fail "Expected executable to link against /opt/cray/pe/mpich. See: ${fileOutLinkage}"
fi

if ! grep -Fq "/opt/cray/libfabric" "${fileOutLinkage}"; then
    fail "Expected executable to link against /opt/cray/libfabric. See: ${fileOutLinkage}"
fi

echo "Linkage check passed"

#--- Runtime test
echo
echo "=== Running on ${SLURM_JOB_NUM_NODES} nodes ==="

TOTAL_TASKS=$((SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE))
NUM_FILES=10
FILE_SIZE=10000

if ! srun -N "${SLURM_JOB_NUM_NODES}" \
     --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
     singularity exec "${SINGULARITY_IMAGE}" "${theExe}" ${NUM_FILES} ${FILE_SIZE} "${OUTPUT_DIR}" \
     | tee "${fileOutRun}"; then
    fail "Runtime execution failed. See: ${fileOutRun}"
fi

expected_success_line="TEST_05_MPI_CONTAINER_IO_SUCCESS size=${TOTAL_TASKS}"

if ! grep -Fq "${expected_success_line}" "${fileOutRun}"; then
    fail "Expected success line not found: ${expected_success_line}. See: ${fileOutRun}"
fi

collective_read_line="Completed collective read from"
noncollective_read_line="Completed non-collective read from"
collective_write_line="Completed collective write to"
noncollective_write_line="Completed non-collective write to"

if [[ $(grep -c "${collective_read_line}" "${fileOutRun}") -ne ${NUM_FILES} ]]; then
    fail "Expected ${NUM_FILES} collective reads. See: ${fileOutRun}"
fi
if [[ $(grep -c "${noncollective_read_line}" "${fileOutRun}") -ne ${NUM_FILES} ]]; then
    fail "Expected ${NUM_FILES} non-collective reads. See: ${fileOutRun}"
fi
if [[ $(grep -c "${collective_write_line}" "${fileOutRun}") -ne ${NUM_FILES} ]]; then
    fail "Expected ${NUM_FILES} collective writes. See: ${fileOutRun}"
fi
if [[ $(grep -c "${noncollective_write_line}" "${fileOutRun}") -ne ${NUM_FILES} ]]; then
    fail "Expected ${NUM_FILES} non-collective writes. See: ${fileOutRun}"
fi


echo "Runtime check passed"


pass
