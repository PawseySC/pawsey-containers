#!/bin/bash --login
#SBATCH --job-name=test_101_compile+run
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-%x-%j.out

# Focus:
# This test verifies that an MPI container image can compile an MPI program
# with the container's mpicc and execute it with the container's mpirun.
# The detected MPI implementation is reported for diagnostics, but the test is
# not restricted to a particular MPI implementation.
#
# This test is intentionally limited to one Slurm node. Slurm allocates one
# task and one CPU for each MPI rank. The container's mpirun is invoked directly
# from the batch script and starts one MPI rank per allocated Slurm task.
# Multi-node execution is outside the scope of this test.
#
# Note:
# This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
# This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.
#
# Normally this script is submitted by a product-specific launcher such as:
#
#   pawsey-containers/setonix/mpi/openmpi-base/testing/run_tests.sh
#
# The launcher defines the required environment variables and submits this
# script with sbatch.
#
# Manual submission example, from the relevant product testing directory:
#
#   export REPO_MPI_DIR="/path/to/repo/pawsey-containers/setonix/mpi"
#   export SINGULARITY_IMAGE="/path/to/image.sif"
#   export SINGULARITY_MODULE="singularity/4.1.0-nohost"
#   sbatch --export=REPO_MPI_DIR,SINGULARITY_IMAGE,SINGULARITY_MODULE \
#       /path/to/repo/pawsey-containers/setonix/mpi/tests/test_101_compile+run.mpirun.slurm.sh
#
# REPO_MPI_DIR must point to the repository's pawsey-containers/setonix/mpi directory.
# SINGULARITY_IMAGE must point to the container image being tested.
# SINGULARITY_MODULE defaults to singularity/4.1.0-nohost when not exported.

#--- Strict mode
set -euo pipefail

#--- Name used for output files and markers
: "${SLURM_JOB_NAME:?SLURM_JOB_NAME is not set}"
TEST_NAME="${SLURM_JOB_NAME}"

#--- Important variables to be provided as environment variables
: "${SINGULARITY_IMAGE:?SINGULARITY_IMAGE is not set}"
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/4.1.0-nohost}"
: "${REPO_MPI_DIR:?REPO_MPI_DIR is not set. Submit this test through a run_tests.sh script or export REPO_MPI_DIR manually.}"

#--- Basic path setup
LAUNCH_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
SHARED_TESTS_DIR="${REPO_MPI_DIR}/tests"
FIXTURES_DIR="${SHARED_TESTS_DIR}/fixtures"

ARTIFACTS_ROOT_DIR="${LAUNCH_DIR}/artifacts"
RUN_ID="${CI_PIPELINE_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${ARTIFACTS_ROOT_DIR}/singleruns/${TEST_NAME}/${RUN_ID}}"

BUILD_DIR="${BUILD_DIR:-${ARTIFACTS_DIR}/build}"
OUTPUT_DIR="${OUTPUT_DIR:-${ARTIFACTS_DIR}/output}"
PASS_MARKER="${OUTPUT_DIR}/${TEST_NAME}.PASS"
FAIL_MARKER="${OUTPUT_DIR}/${TEST_NAME}.FAIL"

mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"
rm -f "${PASS_MARKER}" "${FAIL_MARKER}"

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
    echo "${TEST_NAME}: PASS" > "${PASS_MARKER}"
}

#--- Resolve and validate inputs
if ! REPO_MPI_DIR="$(cd "${REPO_MPI_DIR}" && pwd)"; then
    fail "REPO_MPI_DIR does not exist or is not accessible: ${REPO_MPI_DIR}"
fi

SHARED_TESTS_DIR="${REPO_MPI_DIR}/tests"
FIXTURES_DIR="${SHARED_TESTS_DIR}/fixtures"

if [[ ! -f "${SINGULARITY_IMAGE}" ]]; then
    fail "Singularity image not found: ${SINGULARITY_IMAGE}"
fi

#--- Validate the single-node pure-MPI Slurm allocation
: "${SLURM_JOB_NUM_NODES:?SLURM_JOB_NUM_NODES is not set}"
: "${SLURM_NTASKS:?SLURM_NTASKS is not set}"
: "${SLURM_CPUS_PER_TASK:?SLURM_CPUS_PER_TASK is not set}"

if [[ "${SLURM_JOB_NUM_NODES}" != "1" ]]; then
    fail "This test supports exactly one Slurm node; allocated nodes: ${SLURM_JOB_NUM_NODES}"
fi

if ! [[ "${SLURM_NTASKS}" =~ ^[1-9][0-9]*$ ]]; then
    fail "SLURM_NTASKS must be a positive integer: ${SLURM_NTASKS}"
fi

if [[ "${SLURM_CPUS_PER_TASK}" != "1" ]]; then
    fail "This pure-MPI test requires one CPU per MPI rank; CPUs per task: ${SLURM_CPUS_PER_TASK}"
fi

MPI_RANKS="${SLURM_NTASKS}"

#--- Modules and selected configuration
echo "Using image: ${SINGULARITY_IMAGE}"
echo "Using Singularity module: ${SINGULARITY_MODULE}"
echo "Launch directory: ${LAUNCH_DIR}"
echo "MPI directory: ${REPO_MPI_DIR}"
echo "Shared tests directory: ${SHARED_TESTS_DIR}"
echo "Fixtures directory: ${FIXTURES_DIR}"
echo "Build directory: ${BUILD_DIR}"
echo "Output directory: ${OUTPUT_DIR}"
echo "Slurm nodes: ${SLURM_JOB_NUM_NODES}"
echo "Slurm tasks: ${SLURM_NTASKS}"
echo "CPUs per task: ${SLURM_CPUS_PER_TASK}"
echo "MPI ranks: ${MPI_RANKS}"

module load "${SINGULARITY_MODULE}"
module list

#--- Input/output files
src="${FIXTURES_DIR}/mpi_compile_acceptance.c"
theExe="${BUILD_DIR}/mpi_compile_acceptance.exe"

fileOutCompile="${OUTPUT_DIR}/res_${TEST_NAME}.compile.out"
fileOutLinkage="${OUTPUT_DIR}/res_${TEST_NAME}.linkage.out"
fileOutRun="${OUTPUT_DIR}/res_${TEST_NAME}.run.out"

if [[ ! -f "${src}" ]]; then
    fail "Fixture source file not found: ${src}"
fi

#--- Report the MPI implementation and compile
echo
echo "=== Container MPI information ==="

{
    echo "mpicc version:"
    singularity exec "${SINGULARITY_IMAGE}" mpicc --version || true
    echo
    echo "mpirun version:"
    singularity exec "${SINGULARITY_IMAGE}" mpirun --version || true
} | tee "${fileOutCompile}"

echo
echo "=== Building with container mpicc ==="

if ! singularity exec "${SINGULARITY_IMAGE}" \
    mpicc -O2 "${src}" -o "${theExe}" \
    >> "${fileOutCompile}" 2>&1; then
    cat "${fileOutCompile}" >&2 || true
    fail "Compilation failed. See: ${fileOutCompile}"
fi

if [[ ! -x "${theExe}" ]]; then
    fail "Expected executable was not created or is not executable: ${theExe}"
fi

echo "Compilation succeeded: ${theExe}"

#--- Dynamic linkage test
echo
echo "=== Linkage check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" ldd "${theExe}" \
    > "${fileOutLinkage}" 2>&1; then
    cat "${fileOutLinkage}" >&2 || true
    fail "ldd failed for the compiled executable. See: ${fileOutLinkage}"
fi

cat "${fileOutLinkage}"

if grep -Fq "not found" "${fileOutLinkage}"; then
    fail "The compiled executable has unresolved shared-library dependencies. See: ${fileOutLinkage}"
fi

if ! grep -Eq 'libmpi\.so([.[:space:]]|$)' "${fileOutLinkage}"; then
    fail "The compiled executable is not dynamically linked to libmpi. See: ${fileOutLinkage}"
fi

echo "Linkage check passed"

#--- Single-node runtime test using mpirun from inside the container
echo
echo "=== Running ${MPI_RANKS} MPI ranks on one node ==="

if ! singularity exec "${SINGULARITY_IMAGE}" \
    mpirun -n "${MPI_RANKS}" "${theExe}" \
    | tee "${fileOutRun}"; then
    fail "Runtime execution failed. See: ${fileOutRun}"
fi

expected_success_line="TEST_01_MPI_CONTAINER_BUILD_RUN_SUCCESS size=${MPI_RANKS}"

if ! grep -Fq "${expected_success_line}" "${fileOutRun}"; then
    fail "Expected success line not found: ${expected_success_line}. See: ${fileOutRun}"
fi

RANK_COUNT="$(awk '/^RANK_OK / {c++} END {print c+0}' "${fileOutRun}")"

if [[ "${RANK_COUNT}" -ne "${MPI_RANKS}" ]]; then
    fail "Expected ${MPI_RANKS} RANK_OK lines, got ${RANK_COUNT}. See: ${fileOutRun}"
fi

echo "Runtime check passed"
echo "Observed ${RANK_COUNT}/${MPI_RANKS} expected MPI ranks"

pass
