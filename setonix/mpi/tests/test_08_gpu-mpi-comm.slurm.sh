#!/bin/bash --login
#SBATCH --job-name=test_08_gpu-mpi-comm
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --gres=gpu:4
#SBATCH --time=00:15:00
#SBATCH --partition=gpu
#SBATCH --output=slurm-%x-%j.out
#SBATCH --error=slurm-%x-%j.err
#SBATCH --account=pawsey0001-gpu

# Focus:
# This test validates execution of the test:
# - test_gpu_mpi_comm: MPI communication tests.
# which is part of the profile_util repository.

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
#   export SINGULARITY_MODULE="singularity/4.1.0-mpi-gpu"
#   sbatch --export=REPO_MPI_DIR,SINGULARITY_IMAGE,SINGULARITY_MODULE \
#       /path/to/repo/pawsey-containers/setonix/mpi/tests/test_08_gpu-mpi-comm.slurm.sh
#
# REPO_MPI_DIR must point to the repository's pawsey-containers/setonix/mpi directory.
# SINGULARITY_IMAGE must point to the container image being tested.
# SINGULARITY_MODULE defaults to singularity/4.1.0-mpi-gpu when not exported.

#--- Strict mode
set -euo pipefail

#--- Name used for output files and markers
: "${SLURM_JOB_NAME:?SLURM_JOB_NAME is not set}"
TEST_NAME="${SLURM_JOB_NAME}"

#--- Important variables to be provided as environment variable
# The singularity image to use:
: "${SINGULARITY_IMAGE:?SINGULARITY_IMAGE is not set}"
# The Singularity module to load (default supports direct submission):
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/4.1.0-mpi-gpu}"
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
WARN_MARKER="$OUTPUT_DIR/${TEST_NAME}.WARN"
WARN_COUNT=0

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

rm -f "$PASS_MARKER" "$FAIL_MARKER" "$WARN_MARKER"

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

warn() {
    local msg="$*"
    echo
    echo "WARNING: ${msg}" >&2
    WARN_COUNT=$((WARN_COUNT + 1))
    {
        echo "WARNING: ${msg}"
    } >> "${WARN_MARKER}"
}

pass() {
    echo
    if [[ "${WARN_COUNT}" -gt 0 ]]; then
        echo "${TEST_NAME}: PASS with ${WARN_COUNT} warning(s)"
        {
            echo "PASS_WITH_WARNINGS"
            echo "Warnings: ${WARN_COUNT}"
            echo "Warning marker: ${WARN_MARKER}"
        } > "${PASS_MARKER}"
    else
        echo "${TEST_NAME}: PASS"
        {
            echo "PASS"
        } > "${PASS_MARKER}"
    fi
    exit 0
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

#--- test_gpu_mpi_comm settings:
MPI_COMM_EXE="${MPI_COMM_EXE:-/opt/profile_util/build/src/tests/test_gpu_mpi_comm}"

# test_gpu_mpi_comm configuration:
# -s 0.001: maximum message size in GB.
# -i 1    : one iteration per communication test.
# -C 0    : disables CPU-CPU comm tests
# -G 1    : enables GPU-GPU comm tests.
#
# Not set:
# -r      : the default value of 0 is fine
# -o      : the default value of (NProcs / 2) + 1 is fine
MPI_COMM_ARGS="${MPI_COMM_ARGS:--s 0.001 -i 1 -C 0 -G 1}"

# Whole-job wall-clock thresholds.
WARN_TIME_SEC="${WARN_TIME_SEC:-600}"
FAIL_TIME_SEC="${FAIL_TIME_SEC:-840}"

# MPI operation timing thresholds.
# test_gpu_mpi_comm reports these timings in microseconds.
# Defaults are broad regression guards, not tight benchmark targets.
ASYNC_SENDRECV_WARN_USEC="${ASYNC_SENDRECV_WARN_USEC:-80000000}"
ASYNC_SENDRECV_FAIL_USEC="${ASYNC_SENDRECV_FAIL_USEC:-120000000}"

read -r -a mpi_comm_args <<< "${MPI_COMM_ARGS}"

TOTAL_TASKS=$((SLURM_JOB_NUM_NODES * SLURM_NTASKS_PER_NODE))

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"

#--- Output files
fileOutBinaryCheck="${OUTPUT_DIR}/res_${TEST_NAME}.test_gpu_mpi_comm_binaries.out"
fileOutLinkage="${OUTPUT_DIR}/res_${TEST_NAME}.test_gpu_mpi_comm_linkage.out"
fileOutRun="${OUTPUT_DIR}/res_${TEST_NAME}.test_gpu_mpi_comm_run.out"
fileOutPerf="${OUTPUT_DIR}/res_${TEST_NAME}.performance.out"
fileOutSummary="${OUTPUT_DIR}/res_${TEST_NAME}.summary.out"

#--- Binary availability check
echo
echo "=== Binary availability check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" test -x "${MPI_COMM_EXE}"; then
    fail "Executable not found or not executable: ${MPI_COMM_EXE}. See: ${fileOutBinaryCheck}"
fi

echo "${MPI_COMM_EXE}" | tee "${fileOutBinaryCheck}"

if ! grep -Fq "${MPI_COMM_EXE}" "${fileOutBinaryCheck}"; then
    fail "Executable path was not reported correctly. See: ${fileOutBinaryCheck}"
fi

echo "Binary check passed"

#--- Linkage check
echo
echo "=== test_gpu_mpi_comm linkage check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" ldd "${MPI_COMM_EXE}" \
    | grep -E 'profile_util|mpi|fabric|cxi|pmi|pmix|pals|xpmem|gtl|hsa' \
    | tee "${fileOutLinkage}"; then
    fail "Linkage command failed for ${MPI_COMM_EXE}. See: ${fileOutLinkage}"
fi

if ! grep -Fq "libprofile_util" "${fileOutLinkage}"; then
    fail "Expected test_gpu_mpi_comm to link against libprofile_util. See: ${fileOutLinkage}"
fi

if ! grep -Fq "/opt/cray/pe/mpich" "${fileOutLinkage}"; then
    fail "Expected test_gpu_mpi_comm to link against /opt/cray/pe/mpich. See: ${fileOutLinkage}"
fi

if ! grep -Fq "/opt/cray/libfabric" "${fileOutLinkage}"; then
    fail "Expected test_gpu_mpi_comm to link against /opt/cray/libfabric. See: ${fileOutLinkage}"
fi

if ! grep -Fq "gtl_hsa.so" "${fileOutLinkage}"; then
    fail "Expected test_gpu_mpi_comm to link against GTL library. See: ${fileOutLinkage}"
fi

echo "Linkage check passed"

#--- Runtime test
echo
echo "=== test_gpu_mpi_comm runtime test ==="
echo "Executable: ${MPI_COMM_EXE}"
echo "Arguments : ${MPI_COMM_ARGS}"
echo "Ranks     : ${TOTAL_TASKS}"
echo "OMP_NUM_THREADS=${OMP_NUM_THREADS}"
date -Iseconds

START_TIME_SEC="$(date +%s)"

if ! srun -N "${SLURM_JOB_NUM_NODES}" \
     --ntasks="${TOTAL_TASKS}" \
     --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
     --gres=gpu:"${SLURM_NTASKS_PER_NODE}" \
     --gpus-per-task=1 --gpu-bind=closest \
     singularity exec "${SINGULARITY_IMAGE}" \
     "${MPI_COMM_EXE}" "${mpi_comm_args[@]}" \
     2>&1 | tee "${fileOutRun}"; then
    fail "test_gpu_mpi_comm run failed. See: ${fileOutRun}"
fi

END_TIME_SEC="$(date +%s)"
ELAPSED_TIME_SEC=$((END_TIME_SEC - START_TIME_SEC))

date -Iseconds

#--- Runtime validation
echo
echo "=== Validate test_gpu_mpi_comm output ==="

if grep -Eq "MPICH ERROR|Fatal error|MPI_Abort|Invalid root|srun: error" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output contains MPI/runtime error diagnostics. See: ${fileOutRun}"
fi

if ! grep -Fq "Starting job" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing 'Starting job'. See: ${fileOutRun}"
fi

if ! grep -Fq "Version:" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing profile_util version information. See: ${fileOutRun}"
fi

if ! grep -Fq "MPI Comm world size ${TOTAL_TASKS}" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing expected MPI world size ${TOTAL_TASKS}. See: ${fileOutRun}"
fi

if ! grep -Fq "Core Binding" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing core binding information. See: ${fileOutRun}"
fi

if ! grep -Fq "Node system memory report" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing node system memory report. See: ${fileOutRun}"
fi

if ! grep -Fq "running GPU_CPU_copy test" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing GPU-CPU copy test. See: ${fileOutRun}"
fi

if ! grep -Fq "running GPU_bandwidth_sendrecv test" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing GPU bandwidth sendrecv test. See: ${fileOutRun}"
fi

if ! grep -Fq "running GPU_async_sendrecv test" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing GPU async sendrecv test. See: ${fileOutRun}"
fi

if ! grep -Fq "running GPU_correct_sendrecv test" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing GPU correct sendrecv test. See: ${fileOutRun}"
fi

if ! grep -Fq "running GPU_allreduce test" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing GPU allreduce test. See: ${fileOutRun}"
fi

if ! grep -Fq "MPI Comm=Tag_world" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing Tag_world communicator timing/reporting. See: ${fileOutRun}"
fi

if ! grep -Fq "timing [ave,std,min,max]" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing aggregate timing statistics. See: ${fileOutRun}"
fi

if ! grep -Fq "Ending job" "${fileOutRun}"; then
    fail "test_gpu_mpi_comm output missing 'Ending job'. See: ${fileOutRun}"
fi

#--- Timing/reporting validation
echo
echo "=== Validate test_gpu_mpi_comm reporting/performance ==="

TIMING_LINE_COUNT="$(
    awk '/timing \[ave,std,min,max\]/ {c++} END {print c+0}' "${fileOutRun}"
)"

TAG_WORLD_TIMING_COUNT="$(
    awk '/MPI Comm=Tag_world/ && /timing \[ave,std,min,max\]/ {c++} END {print c+0}' "${fileOutRun}"
)"

MEMORY_REPORT_COUNT="$(
    awk '/Memory report/ {c++} END {print c+0}' "${fileOutRun}"
)"

ASYNC_SENDRECV_TAG_WORLD_MAX_AVE_USEC="$(
    extract_max_tag_world_average_usec "MPITestGPUAsyncSendRecv" "${fileOutRun}"
)"

{
    echo "METRIC test_gpu_mpi_comm_elapsed_time_sec ${ELAPSED_TIME_SEC}"
    echo "METRIC test_gpu_mpi_comm_timing_lines ${TIMING_LINE_COUNT}"
    echo "METRIC test_gpu_mpi_comm_tag_world_timing_lines ${TAG_WORLD_TIMING_COUNT}"
    echo "METRIC test_gpu_mpi_comm_memory_report_lines ${MEMORY_REPORT_COUNT}"
    echo "METRIC test_gpu_mpi_comm_async_sendrecv_tag_world_max_average_usec ${ASYNC_SENDRECV_TAG_WORLD_MAX_AVE_USEC}"
    echo "WARN_THRESHOLD_SEC ${WARN_TIME_SEC}"
    echo "FAIL_THRESHOLD_SEC ${FAIL_TIME_SEC}"
    echo "ASYNC_SENDRECV_WARN_THRESHOLD_USEC ${ASYNC_SENDRECV_WARN_USEC}"
    echo "ASYNC_SENDRECV_FAIL_THRESHOLD_USEC ${ASYNC_SENDRECV_FAIL_USEC}"
} | tee "${fileOutPerf}"

echo "Observed test_gpu_mpi_comm elapsed time               : ${ELAPSED_TIME_SEC} sec"
echo "Observed timing lines                             : ${TIMING_LINE_COUNT}"
echo "Observed Tag_world timing lines                   : ${TAG_WORLD_TIMING_COUNT}"
echo "Observed memory report lines                      : ${MEMORY_REPORT_COUNT}"
echo "Observed async_sendrecv Tag_world max average timing    : ${ASYNC_SENDRECV_TAG_WORLD_MAX_AVE_USEC} usec"
echo "Warning threshold, elapsed time                   : ${WARN_TIME_SEC} sec"
echo "Failure threshold, elapsed time                   : ${FAIL_TIME_SEC} sec"
echo "Warning threshold, async_sendrecv Tag_world average     : ${ASYNC_SENDRECV_WARN_USEC} usec"
echo "Failure threshold, async_sendrecv Tag_world average     : ${ASYNC_SENDRECV_FAIL_USEC} usec"

if [[ "${TIMING_LINE_COUNT}" -lt 1 ]]; then
    fail "Expected at least one aggregate timing line, got ${TIMING_LINE_COUNT}. See: ${fileOutPerf}"
fi

if [[ "${TAG_WORLD_TIMING_COUNT}" -lt 1 ]]; then
    fail "Expected at least one Tag_world timing line, got ${TAG_WORLD_TIMING_COUNT}. See: ${fileOutPerf}"
fi

if [[ "${MEMORY_REPORT_COUNT}" -lt 1 ]]; then
    fail "Expected at least one memory report line, got ${MEMORY_REPORT_COUNT}. See: ${fileOutPerf}"
fi

if [[ -z "${ASYNC_SENDRECV_TAG_WORLD_MAX_AVE_USEC}" ]]; then
    fail "Could not extract MPITestSendRecv Tag_world average timing. See: ${fileOutRun}"
fi

if compare_float_gt "${ELAPSED_TIME_SEC}" "${FAIL_TIME_SEC}"; then
    fail "test_gpu_mpi_comm elapsed time ${ELAPSED_TIME_SEC} sec exceeded failure threshold ${FAIL_TIME_SEC} sec. See: ${fileOutPerf}"
fi

if compare_float_gt "${ELAPSED_TIME_SEC}" "${WARN_TIME_SEC}"; then
    warn "test_gpu_mpi_comm elapsed time ${ELAPSED_TIME_SEC} sec exceeded warning threshold ${WARN_TIME_SEC} sec. See: ${fileOutPerf}"
fi

if compare_float_gt "${ASYNC_SENDRECV_TAG_WORLD_MAX_AVE_USEC}" "${ASYNC_SENDRECV_FAIL_USEC}"; then
    fail "MPITestSendRecv Tag_world max average ${ASYNC_SENDRECV_TAG_WORLD_MAX_AVE_USEC} usec exceeded failure threshold ${ASYNC_SENDRECV_FAIL_USEC} usec. See: ${fileOutPerf}"
fi

if compare_float_gt "${ASYNC_SENDRECV_TAG_WORLD_MAX_AVE_USEC}" "${ASYNC_SENDRECV_WARN_USEC}"; then
    warn "MPITestSendRecv Tag_world max average ${ASYNC_SENDRECV_TAG_WORLD_MAX_AVE_USEC} usec exceeded warning threshold ${ASYNC_SENDRECV_WARN_USEC} usec. See: ${fileOutPerf}"
fi

echo "Runtime reporting/performance check passed"

# The current program can emit MPICH communicator-reference diagnostics at shutdown.
# Treat those as warnings for now: they are visible, but they do not fail CI.
if grep -Eq "MPICH: Builtin communicator .* pending .* references" "${fileOutRun}"; then
    warn "test_gpu_mpi_comm emitted MPICH pending communicator reference diagnostics at shutdown. See: ${fileOutRun}"
fi

#--- Summary
echo
echo "=== Summary ==="

{
    echo "test_gpu_mpi_comm summary"
    echo "Executable: ${MPI_COMM_EXE}"
    echo "Arguments : ${MPI_COMM_ARGS}"
    echo "Ranks     : ${TOTAL_TASKS}"
    echo "OMP_NUM_THREADS=${OMP_NUM_THREADS}"
    echo "Elapsed time: ${ELAPSED_TIME_SEC} sec"
    echo
    echo "--- Metrics ---"
    cat "${fileOutPerf}"
    echo
    echo "--- Key runtime lines ---"
    grep -E "Starting job|Version:|MPI Comm world size|Core Binding|running .* test|MPI Comm=Tag_world|timing \[ave,std,min,max\]|Ending job" "${fileOutRun}" || true
    echo
    echo "--- Warning/error diagnostic lines ---"
    grep -E "WARNING|MPICH: Builtin communicator|MPICH ERROR|Fatal error|MPI_Abort|Invalid root|srun: error" "${fileOutRun}" || true
} | tee "${fileOutSummary}"

echo
echo "test_gpu_mpi_comm validation passed"
echo "Summary written to: ${fileOutSummary}"

pass
