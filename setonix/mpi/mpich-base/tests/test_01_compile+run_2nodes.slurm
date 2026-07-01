#!/bin/bash --login
#SBATCH --job-name=T01-compile+run-2nodes
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:10:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=artifacts/output/slurm-test_01-%j.out

# Focus:
# This test focuses on allowing compilation of code using container machinery
# and proper execution of the resulting binary.

# Note:
# This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
# This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.

#--- Strict mode
set -euo pipefail

#--- Helper functions
fail() {
    echo
    echo "TEST_01: FAIL"
    echo "Reason: $*" >&2

    if [[ -n "${OUTPUT_DIR:-}" ]]; then
        mkdir -p "${OUTPUT_DIR}"
        echo "$*" > "${OUTPUT_DIR}/test_01.FAIL"
    fi

    exit 1
}

pass() {
    echo
    echo "TEST_01: PASS"

    mkdir -p "${OUTPUT_DIR}"
    echo "PASS" > "${OUTPUT_DIR}/test_01.PASS"

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
FIXTURES_DIR="${TESTS_DIR}/fixtures"
ARTIFACTS_DIR="${TESTS_DIR}/artifacts"
BUILD_DIR="${ARTIFACTS_DIR}/build"
OUTPUT_DIR="${ARTIFACTS_DIR}/output"

mkdir -p "${ARTIFACTS_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"

# Remove stale PASS/FAIL markers from previous runs
rm -f "${OUTPUT_DIR}/test_01.PASS" "${OUTPUT_DIR}/test_01.FAIL"

#--- Names and version settings
MPICH_VERSION="${MPICH_VERSION:-4.2.2}"
OS_VERSION="${OS_VERSION:-24.04}"
IMAGE_NAME="${IMAGE_NAME:-mpich-base}"

IMAGE_DIR="${IMAGE_DIR:-${ARTIFACTS_DIR}/singularityImages}"
TESTS_SUPPORT_DIR="${TESTS_SUPPORT_DIR:-${MPI_DIR}/repo-support/tests-support}"

#--- Canonical paths
FIXTURES_DIR="$(realpath "${FIXTURES_DIR}")"
ARTIFACTS_DIR="$(realpath "${ARTIFACTS_DIR}")"
BUILD_DIR="$(realpath "${BUILD_DIR}")"
OUTPUT_DIR="$(realpath "${OUTPUT_DIR}")"
IMAGE_DIR="$(realpath "${IMAGE_DIR}")"
TESTS_SUPPORT_DIR="$(realpath "${TESTS_SUPPORT_DIR}")"

#--- Defining image to use
IMAGE_TAG="mpich${MPICH_VERSION}-ubuntu${OS_VERSION}"
IMAGE_FULL="${IMAGE_NAME}--${IMAGE_TAG}.sif"
SINGULARITY_IMAGE="${IMAGE_DIR}/${IMAGE_FULL}"

if [[ ! -f "${SINGULARITY_IMAGE}" ]]; then
    fail "Singularity image not found: ${SINGULARITY_IMAGE}"
fi

echo "Using image: ${SINGULARITY_IMAGE}"
echo "Repository root: ${REPO_ROOT}"
echo "Tests directory: ${TESTS_DIR}"
echo "Fixtures directory: ${FIXTURES_DIR}"
echo "Build directory: ${BUILD_DIR}"
echo "Output directory: ${OUTPUT_DIR}"

#--- Modules and settings
module load singularity/4.1.0-mpi

if [[ "${PAWSEY_CLUSTER:-}" == "joey" ]]; then
    source "${TESTS_SUPPORT_DIR}/common.Joey.settings.sh"
fi

module list

#--- Input/output files
src="${FIXTURES_DIR}/mpi_compile_acceptance.c"
theExe="${BUILD_DIR}/mpi_compile_acceptance.exe"

fileOutCompile="${OUTPUT_DIR}/res_test_01.compile.out"
fileOutLinkage="${OUTPUT_DIR}/res_test_01.linkage.out"
fileOutRun="${OUTPUT_DIR}/res_test_01.run.out"

if [[ ! -f "${src}" ]]; then
    fail "Fixture source file not found: ${src}"
fi

#--- Compile test
echo
echo "=== Building with container mpicc ==="

singularity exec "${SINGULARITY_IMAGE}" \
    mpicc -O2 "${src}" -o "${theExe}" \
    > "${fileOutCompile}" 2>&1 \
    || fail "Compilation failed. See: ${fileOutCompile}"

if [[ ! -x "${theExe}" ]]; then
    fail "Expected executable was not created or is not executable: ${theExe}"
fi

echo "Compilation succeeded: ${theExe}"

#--- Linkage test
echo
echo "=== Linkage check ==="

singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "ldd '${theExe}' | grep -E 'mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true" \
    | tee "${fileOutLinkage}"

if ! grep -q "/opt/cray/pe/mpich" "${fileOutLinkage}"; then
    fail "Expected executable to link against /opt/cray/pe/mpich. See: ${fileOutLinkage}"
fi

if ! grep -q "/opt/cray/libfabric" "${fileOutLinkage}"; then
    fail "Expected executable to link against /opt/cray/libfabric. See: ${fileOutLinkage}"
fi

echo "Linkage check passed"

#--- Runtime test
echo
echo "=== Running on ${SLURM_JOB_NUM_NODES} nodes ==="

TOTAL_TASKS=$((SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE))

srun -N "${SLURM_JOB_NUM_NODES}" \
     --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
     singularity exec "${SINGULARITY_IMAGE}" "${theExe}" \
     | tee "${fileOutRun}"

expected_success_line="TEST_01_MPI_CONTAINER_BUILD_RUN_SUCCESS size=${TOTAL_TASKS}"

if ! grep -q "${expected_success_line}" "${fileOutRun}"; then
    fail "Expected success line not found: ${expected_success_line}. See: ${fileOutRun}"
fi

RANK_COUNT="$(awk '/^RANK_OK / {c++} END {print c+0}' "${fileOutRun}")"

if [[ "${RANK_COUNT}" -ne "${TOTAL_TASKS}" ]]; then
    fail "Expected ${TOTAL_TASKS} RANK_OK lines, got ${RANK_COUNT}. See: ${fileOutRun}"
fi

echo "Runtime check passed"
echo "Observed ${RANK_COUNT}/${TOTAL_TASKS} expected MPI ranks"

pass
