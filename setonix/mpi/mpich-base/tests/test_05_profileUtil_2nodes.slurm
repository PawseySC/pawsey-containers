#!/bin/bash --login
#SBATCH --job-name=T05-profileUtil-2nodes
#SBATCH --nodes=2
#SBATCH --ntasks=16
#SBATCH --ntasks-per-node=8
#SBATCH --time=00:15:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=artifacts/output/slurm-test_05-%j.out

# Focus:
# This test validates execution of selected MPI programs from the profile_util repository
# inside the mpich-base container.

# Note:
# This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
# This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.

#--- Strict mode
set -euo pipefail

#--- Helper functions
fail() {
    echo
    echo "TEST_05: FAIL"
    echo "Reason: $*" >&2

    if [[ -n "${OUTPUT_DIR:-}" ]]; then
        mkdir -p "${ARTIFACTS_DIR:-${OUTPUT_DIR}/..}" "${OUTPUT_DIR}"
        echo "$*" > "${OUTPUT_DIR}/test_05.FAIL"
    fi

    exit 1
}

warn() {
    local msg="$*"

    echo "WARNING: ${msg}" >&2

    WARN_COUNT=$((WARN_COUNT + 1))

    if [[ -n "${OUTPUT_DIR:-}" ]]; then
        mkdir -p "${ARTIFACTS_DIR}" "${OUTPUT_DIR}"
        echo "WARNING: ${msg}" >> "${OUTPUT_DIR}/test_05.WARN"
    fi
}

compare_float_gt() {
    local lhs="$1"
    local rhs="$2"

    awk -v lhs="${lhs}" -v rhs="${rhs}" 'BEGIN { exit !(lhs > rhs) }'
}


pass() {
    echo

    if [[ "${WARN_COUNT}" -gt 0 ]]; then
        echo "TEST_05: PASS with ${WARN_COUNT} warning(s)"
        echo "PASS_WITH_WARNINGS" > "${OUTPUT_DIR}/test_05.PASS"
    else
        echo "TEST_05: PASS"
        echo "PASS" > "${OUTPUT_DIR}/test_05.PASS"
    fi

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
ARTIFACTS_DIR="${TESTS_DIR}/artifacts"
BUILD_DIR="${ARTIFACTS_DIR}/build"
OUTPUT_DIR="${ARTIFACTS_DIR}/output"

mkdir -p "${ARTIFACTS_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"

# Remove stale PASS/FAIL/WARN markers from previous runs
rm -f "${OUTPUT_DIR}/test_05.PASS" \
      "${OUTPUT_DIR}/test_05.FAIL" \
      "${OUTPUT_DIR}/test_05.WARN"

WARN_COUNT=0

#--- Names and version settings
MPICH_VERSION="${MPICH_VERSION:-4.2.2}"
OS_VERSION="${OS_VERSION:-24.04}"
IMAGE_NAME="${IMAGE_NAME:-mpich-base}"

IMAGE_DIR="${IMAGE_DIR:-${ARTIFACTS_DIR}/singularityImages}"
AUX_DIR="${AUX_DIR:-${MPI_DIR}/auxiliary}"

#--- Canonical paths
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
echo "Artifacts directory: ${ARTIFACTS_DIR}"
echo "Build directory: ${BUILD_DIR}"
echo "Output directory: ${OUTPUT_DIR}"

#--- Modules and settings
module load singularity/4.1.0-mpi

if [[ "${PAWSEY_CLUSTER:-}" == "joey" ]]; then
    source "${AUX_DIR}/common.Joey.settings.sh"
fi

module list

#--- ProfileUtil test configuration
PROFILEUTIL_MPI_COMPUTE_EXE="${PROFILEUTIL_MPI_COMPUTE_EXE:-/opt/profile_util/examples/mpi/bin/mpi-compute}"
PROFILEUTIL_MPI_COMPUTE_ARGS="${PROFILEUTIL_MPI_COMPUTE_ARGS:-512 10}"
PROFILEUTIL_WARN_TIME_MIN="${PROFILEUTIL_WARN_TIME_MIN:-6.0}"
PROFILEUTIL_FAIL_TIME_MIN="${PROFILEUTIL_FAIL_TIME_MIN:-10.0}"

read -r -a mpi_compute_args <<< "${PROFILEUTIL_MPI_COMPUTE_ARGS}"

TOTAL_TASKS=$((SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE))

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"

#--- Output files
fileOutBinaryCheck="${OUTPUT_DIR}/res_test_05.profileUtil_binaries.out"
fileOutLinkage="${OUTPUT_DIR}/res_test_05.mpi_compute_linkage.out"
fileOutRun="${OUTPUT_DIR}/res_test_05.mpi_compute_run.out"
fileOutPerf="${OUTPUT_DIR}/res_test_05.performance.out"
fileOutSummary="${OUTPUT_DIR}/res_test_05.summary.out"

#--- Binary availability check
echo
echo "=== ProfileUtil binary availability check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "test -x '${PROFILEUTIL_MPI_COMPUTE_EXE}' && echo '${PROFILEUTIL_MPI_COMPUTE_EXE}'" \
    | tee "${fileOutBinaryCheck}"; then
    fail "ProfileUtil executable not found or not executable: ${PROFILEUTIL_MPI_COMPUTE_EXE}. See: ${fileOutBinaryCheck}"
fi

if ! grep -q "${PROFILEUTIL_MPI_COMPUTE_EXE}" "${fileOutBinaryCheck}"; then
    fail "ProfileUtil executable path was not reported correctly. See: ${fileOutBinaryCheck}"
fi

echo "ProfileUtil binary check passed"

#--- Linkage check
echo
echo "=== ProfileUtil mpi-compute linkage check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "ldd '${PROFILEUTIL_MPI_COMPUTE_EXE}' | grep -E 'profile_util|mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true" \
    | tee "${fileOutLinkage}"; then
    fail "Linkage command failed for ${PROFILEUTIL_MPI_COMPUTE_EXE}. See: ${fileOutLinkage}"
fi

if ! grep -q "libprofile_util" "${fileOutLinkage}"; then
    fail "Expected mpi-compute to link against libprofile_util. See: ${fileOutLinkage}"
fi

if ! grep -q "/opt/cray/pe/mpich" "${fileOutLinkage}"; then
    fail "Expected mpi-compute to link against /opt/cray/pe/mpich. See: ${fileOutLinkage}"
fi

if ! grep -q "/opt/cray/libfabric" "${fileOutLinkage}"; then
    fail "Expected mpi-compute to link against /opt/cray/libfabric. See: ${fileOutLinkage}"
fi

echo "ProfileUtil linkage check passed"

#--- Runtime test
echo
echo "=== ProfileUtil mpi-compute runtime test ==="
echo "Executable: ${PROFILEUTIL_MPI_COMPUTE_EXE}"
echo "Arguments : ${PROFILEUTIL_MPI_COMPUTE_ARGS}"
echo "Ranks     : ${TOTAL_TASKS}"
echo "OMP_NUM_THREADS=${OMP_NUM_THREADS}"
date -Iseconds

if ! srun -N "${SLURM_JOB_NUM_NODES}" \
     --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
     singularity exec "${SINGULARITY_IMAGE}" \
     "${PROFILEUTIL_MPI_COMPUTE_EXE}" "${mpi_compute_args[@]}" \
     2>&1 | tee "${fileOutRun}"; then
    fail "ProfileUtil mpi-compute run failed. See: ${fileOutRun}"
fi

date -Iseconds

#--- Runtime validation
echo
echo "=== Validate ProfileUtil mpi-compute output ==="

if ! grep -q "Starting job" "${fileOutRun}"; then
    fail "mpi-compute output missing 'Starting job'. See: ${fileOutRun}"
fi

if ! grep -q "MPI Comm world size ${TOTAL_TASKS}" "${fileOutRun}"; then
    fail "mpi-compute output missing expected MPI world size ${TOTAL_TASKS}. See: ${fileOutRun}"
fi

if ! grep -q "OpenMP version" "${fileOutRun}"; then
    fail "mpi-compute output missing OpenMP runtime information. See: ${fileOutRun}"
fi

if ! grep -q "Producing" "${fileOutRun}"; then
    fail "mpi-compute output missing data generation phase. See: ${fileOutRun}"
fi

if ! grep -q "redistributing" "${fileOutRun}"; then
    fail "mpi-compute output missing redistribution phase. See: ${fileOutRun}"
fi

if ! grep -q "Transforming data" "${fileOutRun}"; then
    fail "mpi-compute output missing transform phase. See: ${fileOutRun}"
fi

if ! grep -q "gridding" "${fileOutRun}"; then
    fail "mpi-compute output missing gridding phase. See: ${fileOutRun}"
fi

if ! grep -q "computing" "${fileOutRun}"; then
    fail "mpi-compute output missing compute phase. See: ${fileOutRun}"
fi

if ! grep -q "Ending job" "${fileOutRun}"; then
    fail "mpi-compute output missing 'Ending job'. See: ${fileOutRun}"
fi

# With default args "512 10", expected iteration labels are 0..9.
# If users override PROFILEUTIL_MPI_COMPUTE_ARGS, infer Niter from the second argument.
EXPECTED_NITER="${mpi_compute_args[1]:-10}"
LAST_ITER=$((EXPECTED_NITER - 1))

if [[ "${EXPECTED_NITER}" -gt 0 ]]; then
    if ! grep -q "At iteration ${LAST_ITER}" "${fileOutRun}"; then
        fail "mpi-compute output missing expected final iteration ${LAST_ITER}. See: ${fileOutRun}"
    fi
fi

# Check rank-distributed logging. The program should report at least one line per rank
# during data generation.
PRODUCING_COUNT="$(awk '/Producing / {c++} END {print c+0}' "${fileOutRun}")"

if [[ "${PRODUCING_COUNT}" -lt "${TOTAL_TASKS}" ]]; then
    fail "Expected at least ${TOTAL_TASKS} 'Producing' lines, got ${PRODUCING_COUNT}. See: ${fileOutRun}"
fi

#--- Performance validation
echo
echo "=== Validate ProfileUtil mpi-compute runtime performance ==="

LOOP_TIME_MIN="$(
    awk '
        /Time taken between/ && /\[min\]/ {
            for (i = 1; i <= NF; i++) {
                if ($i == ":") {
                    value = $(i + 1)
                }
            }
        }
        END {
            if (value != "") print value
        }
    ' "${fileOutRun}"
)"

if [[ -z "${LOOP_TIME_MIN}" ]]; then
    fail "Could not extract total loop runtime in minutes from mpi-compute output. See: ${fileOutRun}"
fi

{
    echo "METRIC profileutil_mpi_compute_loop_time_min ${LOOP_TIME_MIN}"
    echo "WARN_THRESHOLD_MIN ${PROFILEUTIL_WARN_TIME_MIN}"
    echo "FAIL_THRESHOLD_MIN ${PROFILEUTIL_FAIL_TIME_MIN}"
} | tee "${fileOutPerf}"

echo "Observed ProfileUtil loop runtime: ${LOOP_TIME_MIN} min"
echo "Warning threshold             : ${PROFILEUTIL_WARN_TIME_MIN} min"
echo "Failure threshold             : ${PROFILEUTIL_FAIL_TIME_MIN} min"

if compare_float_gt "${LOOP_TIME_MIN}" "${PROFILEUTIL_FAIL_TIME_MIN}"; then
    fail "ProfileUtil mpi-compute loop runtime ${LOOP_TIME_MIN} min exceeded failure threshold ${PROFILEUTIL_FAIL_TIME_MIN} min. See: ${fileOutPerf}"
fi

if compare_float_gt "${LOOP_TIME_MIN}" "${PROFILEUTIL_WARN_TIME_MIN}"; then
    warn "ProfileUtil mpi-compute loop runtime ${LOOP_TIME_MIN} min exceeded warning threshold ${PROFILEUTIL_WARN_TIME_MIN} min. See: ${fileOutPerf}"
fi

echo "ProfileUtil runtime performance check passed"

# The current program can emit MPICH communicator-reference diagnostics at shutdown.
# Treat those as warnings for now: they are visible, but they do not fail CI.
if grep -q "MPICH: Builtin communicator .* pending .* references" "${fileOutRun}"; then
    warn "mpi-compute emitted MPICH pending communicator reference diagnostics at shutdown. See: ${fileOutRun}"
fi

#--- Summary
echo
echo "=== Summary ==="

{
    echo "ProfileUtil mpi-compute summary"
    echo "Executable: ${PROFILEUTIL_MPI_COMPUTE_EXE}"
    echo "Arguments : ${PROFILEUTIL_MPI_COMPUTE_ARGS}"
    echo "Ranks     : ${TOTAL_TASKS}"
    echo "OMP_NUM_THREADS=${OMP_NUM_THREADS}"
    echo
    echo "--- Key runtime lines ---"
    grep -E "Starting job|MPI Comm world size|OpenMP version|At iteration|Ending job|Time taken between" "${fileOutRun}" || true
    echo
    echo "--- Warning lines ---"
    grep -E "WARNING|MPICH: Builtin communicator" "${fileOutRun}" || true
} | tee "${fileOutSummary}"

echo
echo "ProfileUtil mpi-compute validation passed"
echo "Summary written to: ${fileOutSummary}"

pass