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
# This test validates execution of selected MPI communication tests from the
# profile_util repository inside the mpich-base container.

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

extract_max_tag_world_average_usec() {
    local test_name="$1"
    local input_file="$2"

    awk -v test_name="${test_name}" '
        /MPI Comm=Tag_world/ && $0 ~ test_name && /timing \[ave,std,min,max\]/ {
            if (match($0, /timing \[ave,std,min,max\]=\[[^]]+\]/)) {
                metric = substr($0, RSTART, RLENGTH)
                gsub(/^timing \[ave,std,min,max\]=\[/, "", metric)
                gsub(/\]$/, "", metric)
                split(metric, values, ",")
                ave = values[1] + 0
                if (ave > max_ave) {
                    max_ave = ave
                }
                count++
            }
        }
        END {
            if (count > 0) {
                print max_ave
            }
        }
    ' "${input_file}"
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
PROFILEUTIL_MPI_COMM_EXE="${PROFILEUTIL_MPI_COMM_EXE:-/opt/profile_util/build/src/tests/test_mpi_comm}"

# Important:
# -s 0.001: keeps messages small and CI-safe.
# -i 1: one iteration.
# -d 1 -m 1000: harmless safety values if longdelay is ever re-enabled.
# -D 0: disables longdelay.
# -C 0: disables correct-values test.
# -G 0 -S 0: disables empty gather/scatter tests.
# -R 1: enables allreduce.
# -B 1: enables Bcast test.
# -P 1: enables sendrecv.
# -p 1: enables sendrecv_singlerank.
PROFILEUTIL_MPI_COMM_ARGS="${PROFILEUTIL_MPI_COMM_ARGS:--s 0.001 -i 1 -d 1 -m 1000 -D 0 -C 0 -G 0 -S 0 -R 1 -B 1 -P 1 -p 1}"

# Whole-job wall-clock thresholds.
PROFILEUTIL_WARN_TIME_SEC="${PROFILEUTIL_WARN_TIME_SEC:-600}"
PROFILEUTIL_FAIL_TIME_SEC="${PROFILEUTIL_FAIL_TIME_SEC:-840}"

# MPI operation timing thresholds.
# test_mpi_comm reports these timings in microseconds.
# Defaults are broad regression guards, not tight benchmark targets.
PROFILEUTIL_ALLREDUCE_WARN_USEC="${PROFILEUTIL_ALLREDUCE_WARN_USEC:-8000000}"
PROFILEUTIL_ALLREDUCE_FAIL_USEC="${PROFILEUTIL_ALLREDUCE_FAIL_USEC:-12000000}"

PROFILEUTIL_SENDRECV_WARN_USEC="${PROFILEUTIL_SENDRECV_WARN_USEC:-80000000}"
PROFILEUTIL_SENDRECV_FAIL_USEC="${PROFILEUTIL_SENDRECV_FAIL_USEC:-120000000}"

read -r -a mpi_comm_args <<< "${PROFILEUTIL_MPI_COMM_ARGS}"

TOTAL_TASKS=$((SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE))

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"

#--- Output files
fileOutBinaryCheck="${OUTPUT_DIR}/res_test_05.profileUtil_binaries.out"
fileOutLinkage="${OUTPUT_DIR}/res_test_05.test_mpi_comm_linkage.out"
fileOutRun="${OUTPUT_DIR}/res_test_05.test_mpi_comm_run.out"
fileOutPerf="${OUTPUT_DIR}/res_test_05.performance.out"
fileOutSummary="${OUTPUT_DIR}/res_test_05.summary.out"

#--- Binary availability check
echo
echo "=== ProfileUtil binary availability check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" test -x "${PROFILEUTIL_MPI_COMM_EXE}"; then
    fail "ProfileUtil executable not found or not executable: ${PROFILEUTIL_MPI_COMM_EXE}. See: ${fileOutBinaryCheck}"
fi

echo "${PROFILEUTIL_MPI_COMM_EXE}" | tee "${fileOutBinaryCheck}"

if ! grep -aq "${PROFILEUTIL_MPI_COMM_EXE}" "${fileOutBinaryCheck}"; then
    fail "ProfileUtil executable path was not reported correctly. See: ${fileOutBinaryCheck}"
fi

echo "ProfileUtil binary check passed"

#--- Linkage check
echo
echo "=== ProfileUtil test_mpi_comm linkage check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" ldd "${PROFILEUTIL_MPI_COMM_EXE}" \
    | grep -aE 'profile_util|mpi|fabric|cxi|pmi|pmix|pals|xpmem' \
    | tee "${fileOutLinkage}"; then
    fail "Linkage command failed for ${PROFILEUTIL_MPI_COMM_EXE}. See: ${fileOutLinkage}"
fi

if ! grep -aq "libprofile_util" "${fileOutLinkage}"; then
    fail "Expected test_mpi_comm to link against libprofile_util. See: ${fileOutLinkage}"
fi

if ! grep -aq "/opt/cray/pe/mpich" "${fileOutLinkage}"; then
    fail "Expected test_mpi_comm to link against /opt/cray/pe/mpich. See: ${fileOutLinkage}"
fi

if ! grep -aq "/opt/cray/libfabric" "${fileOutLinkage}"; then
    fail "Expected test_mpi_comm to link against /opt/cray/libfabric. See: ${fileOutLinkage}"
fi

echo "ProfileUtil linkage check passed"

#--- Runtime test
echo
echo "=== ProfileUtil test_mpi_comm runtime test ==="
echo "Executable: ${PROFILEUTIL_MPI_COMM_EXE}"
echo "Arguments : ${PROFILEUTIL_MPI_COMM_ARGS}"
echo "Ranks     : ${TOTAL_TASKS}"
echo "OMP_NUM_THREADS=${OMP_NUM_THREADS}"
date -Iseconds

START_TIME_SEC="$(date +%s)"

if ! srun -N "${SLURM_JOB_NUM_NODES}" \
     --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
     singularity exec "${SINGULARITY_IMAGE}" \
     "${PROFILEUTIL_MPI_COMM_EXE}" "${mpi_comm_args[@]}" \
     2>&1 | tee "${fileOutRun}"; then
    fail "ProfileUtil test_mpi_comm run failed. See: ${fileOutRun}"
fi

END_TIME_SEC="$(date +%s)"
ELAPSED_TIME_SEC=$((END_TIME_SEC - START_TIME_SEC))

date -Iseconds

#--- Runtime validation
echo
echo "=== Validate ProfileUtil test_mpi_comm output ==="

if grep -aqE "MPICH ERROR|Fatal error|MPI_Abort|Invalid root|srun: error" "${fileOutRun}"; then
    fail "test_mpi_comm output contains MPI/runtime error diagnostics. See: ${fileOutRun}"
fi

if ! grep -aq "Starting job" "${fileOutRun}"; then
    fail "test_mpi_comm output missing 'Starting job'. See: ${fileOutRun}"
fi

if ! grep -aq "Version:" "${fileOutRun}"; then
    fail "test_mpi_comm output missing profile_util version information. See: ${fileOutRun}"
fi

if ! grep -aq "MPI Comm world size ${TOTAL_TASKS}" "${fileOutRun}"; then
    fail "test_mpi_comm output missing expected MPI world size ${TOTAL_TASKS}. See: ${fileOutRun}"
fi

if ! grep -aq "Core Binding" "${fileOutRun}"; then
    fail "test_mpi_comm output missing core binding information. See: ${fileOutRun}"
fi

if ! grep -aq "Node system memory report" "${fileOutRun}"; then
    fail "test_mpi_comm output missing node system memory report. See: ${fileOutRun}"
fi

if ! grep -aq "running sendrecv_singlerank test" "${fileOutRun}"; then
    fail "test_mpi_comm output missing sendrecv_singlerank test. See: ${fileOutRun}"
fi

if ! grep -aq "running allreduce test" "${fileOutRun}"; then
    fail "test_mpi_comm output missing allreduce test. See: ${fileOutRun}"
fi

if ! grep -aq "running sendrecv test" "${fileOutRun}"; then
    fail "test_mpi_comm output missing sendrecv test. See: ${fileOutRun}"
fi

if ! grep -aq "running Bcast test" "${fileOutRun}"; then
    fail "test_mpi_comm output missing Bcast test. See: ${fileOutRun}"
fi

if ! grep -aq "MPI Comm=Tag_world" "${fileOutRun}"; then
    fail "test_mpi_comm output missing Tag_world communicator timing/reporting. See: ${fileOutRun}"
fi

if ! grep -aq "MPI Comm=Tag_world @MPITestBcast" "${fileOutRun}"; then
    fail "test_mpi_comm output missing Tag_world Bcast timing. See: ${fileOutRun}"
fi

if ! grep -aq "timing \[ave,std,min,max\]" "${fileOutRun}"; then
    fail "test_mpi_comm output missing aggregate timing statistics. See: ${fileOutRun}"
fi

if ! grep -aq "Ending job" "${fileOutRun}"; then
    fail "test_mpi_comm output missing 'Ending job'. See: ${fileOutRun}"
fi

#--- Timing/reporting validation
echo
echo "=== Validate ProfileUtil test_mpi_comm reporting/performance ==="

TIMING_LINE_COUNT="$(
    awk '/timing \[ave,std,min,max\]/ {c++} END {print c+0}' "${fileOutRun}"
)"

TAG_WORLD_TIMING_COUNT="$(
    awk '/MPI Comm=Tag_world/ && /timing \[ave,std,min,max\]/ {c++} END {print c+0}' "${fileOutRun}"
)"

MEMORY_REPORT_COUNT="$(
    awk '/Memory report/ {c++} END {print c+0}' "${fileOutRun}"
)"

ALLREDUCE_TAG_WORLD_MAX_AVE_USEC="$(
    extract_max_tag_world_average_usec "MPITestAllReduce" "${fileOutRun}"
)"

SENDRECV_TAG_WORLD_MAX_AVE_USEC="$(
    extract_max_tag_world_average_usec "MPITestSendRecv" "${fileOutRun}"
)"

{
    echo "METRIC profileutil_test_mpi_comm_elapsed_time_sec ${ELAPSED_TIME_SEC}"
    echo "METRIC profileutil_test_mpi_comm_timing_lines ${TIMING_LINE_COUNT}"
    echo "METRIC profileutil_test_mpi_comm_tag_world_timing_lines ${TAG_WORLD_TIMING_COUNT}"
    echo "METRIC profileutil_test_mpi_comm_memory_report_lines ${MEMORY_REPORT_COUNT}"
    echo "METRIC profileutil_test_mpi_comm_allreduce_tag_world_max_average_usec ${ALLREDUCE_TAG_WORLD_MAX_AVE_USEC}"
    echo "METRIC profileutil_test_mpi_comm_sendrecv_tag_world_max_average_usec ${SENDRECV_TAG_WORLD_MAX_AVE_USEC}"
    echo "WARN_THRESHOLD_SEC ${PROFILEUTIL_WARN_TIME_SEC}"
    echo "FAIL_THRESHOLD_SEC ${PROFILEUTIL_FAIL_TIME_SEC}"
    echo "ALLREDUCE_WARN_THRESHOLD_USEC ${PROFILEUTIL_ALLREDUCE_WARN_USEC}"
    echo "ALLREDUCE_FAIL_THRESHOLD_USEC ${PROFILEUTIL_ALLREDUCE_FAIL_USEC}"
    echo "SENDRECV_WARN_THRESHOLD_USEC ${PROFILEUTIL_SENDRECV_WARN_USEC}"
    echo "SENDRECV_FAIL_THRESHOLD_USEC ${PROFILEUTIL_SENDRECV_FAIL_USEC}"
} | tee "${fileOutPerf}"

echo "Observed ProfileUtil elapsed time                 : ${ELAPSED_TIME_SEC} sec"
echo "Observed timing lines                             : ${TIMING_LINE_COUNT}"
echo "Observed Tag_world timing lines                   : ${TAG_WORLD_TIMING_COUNT}"
echo "Observed memory report lines                      : ${MEMORY_REPORT_COUNT}"
echo "Observed allreduce Tag_world max average timing   : ${ALLREDUCE_TAG_WORLD_MAX_AVE_USEC} usec"
echo "Observed sendrecv Tag_world max average timing    : ${SENDRECV_TAG_WORLD_MAX_AVE_USEC} usec"
echo "Warning threshold, elapsed time                   : ${PROFILEUTIL_WARN_TIME_SEC} sec"
echo "Failure threshold, elapsed time                   : ${PROFILEUTIL_FAIL_TIME_SEC} sec"
echo "Warning threshold, allreduce Tag_world average    : ${PROFILEUTIL_ALLREDUCE_WARN_USEC} usec"
echo "Failure threshold, allreduce Tag_world average    : ${PROFILEUTIL_ALLREDUCE_FAIL_USEC} usec"
echo "Warning threshold, sendrecv Tag_world average     : ${PROFILEUTIL_SENDRECV_WARN_USEC} usec"
echo "Failure threshold, sendrecv Tag_world average     : ${PROFILEUTIL_SENDRECV_FAIL_USEC} usec"

if [[ "${TIMING_LINE_COUNT}" -lt 1 ]]; then
    fail "Expected at least one aggregate timing line, got ${TIMING_LINE_COUNT}. See: ${fileOutPerf}"
fi

if [[ "${TAG_WORLD_TIMING_COUNT}" -lt 1 ]]; then
    fail "Expected at least one Tag_world timing line, got ${TAG_WORLD_TIMING_COUNT}. See: ${fileOutPerf}"
fi

if [[ "${MEMORY_REPORT_COUNT}" -lt 1 ]]; then
    fail "Expected at least one memory report line, got ${MEMORY_REPORT_COUNT}. See: ${fileOutPerf}"
fi

if [[ -z "${ALLREDUCE_TAG_WORLD_MAX_AVE_USEC}" ]]; then
    fail "Could not extract MPITestAllReduce Tag_world average timing. See: ${fileOutRun}"
fi

if [[ -z "${SENDRECV_TAG_WORLD_MAX_AVE_USEC}" ]]; then
    fail "Could not extract MPITestSendRecv Tag_world average timing. See: ${fileOutRun}"
fi

if compare_float_gt "${ELAPSED_TIME_SEC}" "${PROFILEUTIL_FAIL_TIME_SEC}"; then
    fail "ProfileUtil test_mpi_comm elapsed time ${ELAPSED_TIME_SEC} sec exceeded failure threshold ${PROFILEUTIL_FAIL_TIME_SEC} sec. See: ${fileOutPerf}"
fi

if compare_float_gt "${ELAPSED_TIME_SEC}" "${PROFILEUTIL_WARN_TIME_SEC}"; then
    warn "ProfileUtil test_mpi_comm elapsed time ${ELAPSED_TIME_SEC} sec exceeded warning threshold ${PROFILEUTIL_WARN_TIME_SEC} sec. See: ${fileOutPerf}"
fi

if compare_float_gt "${ALLREDUCE_TAG_WORLD_MAX_AVE_USEC}" "${PROFILEUTIL_ALLREDUCE_FAIL_USEC}"; then
    fail "MPITestAllReduce Tag_world max average ${ALLREDUCE_TAG_WORLD_MAX_AVE_USEC} usec exceeded failure threshold ${PROFILEUTIL_ALLREDUCE_FAIL_USEC} usec. See: ${fileOutPerf}"
fi

if compare_float_gt "${ALLREDUCE_TAG_WORLD_MAX_AVE_USEC}" "${PROFILEUTIL_ALLREDUCE_WARN_USEC}"; then
    warn "MPITestAllReduce Tag_world max average ${ALLREDUCE_TAG_WORLD_MAX_AVE_USEC} usec exceeded warning threshold ${PROFILEUTIL_ALLREDUCE_WARN_USEC} usec. See: ${fileOutPerf}"
fi

if compare_float_gt "${SENDRECV_TAG_WORLD_MAX_AVE_USEC}" "${PROFILEUTIL_SENDRECV_FAIL_USEC}"; then
    fail "MPITestSendRecv Tag_world max average ${SENDRECV_TAG_WORLD_MAX_AVE_USEC} usec exceeded failure threshold ${PROFILEUTIL_SENDRECV_FAIL_USEC} usec. See: ${fileOutPerf}"
fi

if compare_float_gt "${SENDRECV_TAG_WORLD_MAX_AVE_USEC}" "${PROFILEUTIL_SENDRECV_WARN_USEC}"; then
    warn "MPITestSendRecv Tag_world max average ${SENDRECV_TAG_WORLD_MAX_AVE_USEC} usec exceeded warning threshold ${PROFILEUTIL_SENDRECV_WARN_USEC} usec. See: ${fileOutPerf}"
fi

echo "ProfileUtil runtime reporting/performance check passed"

# The current program can emit MPICH communicator-reference diagnostics at shutdown.
# Treat those as warnings for now: they are visible, but they do not fail CI.
if grep -aq "MPICH: Builtin communicator .* pending .* references" "${fileOutRun}"; then
    warn "test_mpi_comm emitted MPICH pending communicator reference diagnostics at shutdown. See: ${fileOutRun}"
fi

#--- Summary
echo
echo "=== Summary ==="

{
    echo "ProfileUtil test_mpi_comm summary"
    echo "Executable: ${PROFILEUTIL_MPI_COMM_EXE}"
    echo "Arguments : ${PROFILEUTIL_MPI_COMM_ARGS}"
    echo "Ranks     : ${TOTAL_TASKS}"
    echo "OMP_NUM_THREADS=${OMP_NUM_THREADS}"
    echo "Elapsed time: ${ELAPSED_TIME_SEC} sec"
    echo
    echo "--- Metrics ---"
    cat "${fileOutPerf}"
    echo
    echo "--- Key runtime lines ---"
    grep -aE "Starting job|Version:|MPI Comm world size|Core Binding|running .* test|MPI Comm=Tag_world|timing \[ave,std,min,max\]|Ending job" "${fileOutRun}" || true
    echo
    echo "--- Warning/error diagnostic lines ---"
    grep -aE "WARNING|MPICH: Builtin communicator|MPICH ERROR|Fatal error|MPI_Abort|Invalid root|srun: error" "${fileOutRun}" || true
} | tee "${fileOutSummary}"

echo
echo "ProfileUtil test_mpi_comm validation passed"
echo "Summary written to: ${fileOutSummary}"

pass