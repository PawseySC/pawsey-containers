#!/usr/bin/env bash
set -euo pipefail

# Master Slurm test launcher for the mpich-base container image.
#
# The launcher:
#   1. Resolves the repository and shared MPI test directories.
#   2. Selects the container image, Singularity module, partition, optional
#      reservation, and test execution mode.
#   3. Creates an isolated artifact directory for this suite run.
#   4. Submits all enabled Slurm tests with their configured node and task counts.
#   5. Runs tests sequentially by default using afterany dependencies, or allows
#      concurrent execution when requested.
#   6. Waits for every submitted job, evaluates PASS, FAIL, and WARN markers,
#      and exits with the global suite result.
#
# Run from anywhere:
#
#   ./setonix/mpi/mpich-base/testing/run_tests.sh
#
# Configuration values can be overridden for one invocation. Examples:
#
#   PARTITION=debug ./setonix/mpi/mpich-base/testing/run_tests.sh
#   RESERVATION=PAWSEY_XXX_TEST ./setonix/mpi/mpich-base/testing/run_tests.sh
#   EXECUTION_MODE=concurrent ./setonix/mpi/mpich-base/testing/run_tests.sh
#   SINGULARITY_IMAGE=/path/to/image.sif ./setonix/mpi/mpich-base/testing/run_tests.sh
#
# EXECUTION_MODE accepts sequential or concurrent. Sequential is the default.
# Each run writes to testing/artifacts/runs/<run-id>. The latest run directory
# is recorded in testing/artifacts/latest_run.txt.
#
# Note:
# This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
# This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_DIR="${SCRIPT_DIR}"

if [[ "$(basename "${TESTING_DIR}")" != "testing" ]]; then
    echo "ERROR: Could not determine launcher testing directory." >&2
    echo "       SCRIPT_DIR=${SCRIPT_DIR}" >&2
    echo "       TESTING_DIR=${TESTING_DIR}" >&2
    exit 1
fi

REPO_MPICH_BASE_DIR="$(cd "${TESTING_DIR}/.." && pwd)"
REPO_MPI_DIR="$(cd "${REPO_MPICH_BASE_DIR}/.." && pwd)"
REPO_SETONIX_DIR="$(cd "${REPO_MPI_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${REPO_SETONIX_DIR}/.." && pwd)"

SHARED_TESTS_DIR="${REPO_MPI_DIR}/tests"
FIXTURES_DIR="${SHARED_TESTS_DIR}/fixtures"
TESTS_SUPPORT_DIR="${SHARED_TESTS_DIR}/tests-support"

RUN_ID="${CI_PIPELINE_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

ARTIFACTS_ROOT_DIR="${TESTING_DIR}/artifacts"
ARTIFACTS_DIR="${ARTIFACTS_ROOT_DIR}/runs/${RUN_ID}"
BUILD_DIR="${ARTIFACTS_DIR}/build"
OUTPUT_DIR="${ARTIFACTS_DIR}/output"

IMAGE_DIR="${REPO_MPI_DIR}/artifacts/singularityImages"

MPICH_VERSION="${MPICH_VERSION:-4.2.2}"
OS_VERSION="${OS_VERSION:-24.04}"
IMAGE_NAME="mpich-base"
IMAGE_TAG="mpich${MPICH_VERSION}-ubuntu${OS_VERSION}"
SINGULARITY_IMAGE="${SINGULARITY_IMAGE:-${IMAGE_DIR}/${IMAGE_NAME}--${IMAGE_TAG}.sif}"
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/4.1.0-mpi}"

# Override with PARTITION=<name>; the default is work.
PARTITION="${PARTITION:-work}"

# Override with RESERVATION=<name>; empty means no reservation.
RESERVATION="${RESERVATION:-}"

# Override with EXECUTION_MODE=concurrent; valid values are sequential and concurrent.
EXECUTION_MODE="${EXECUTION_MODE:-sequential}"

if [[ "${EXECUTION_MODE}" != "sequential" && "${EXECUTION_MODE}" != "concurrent" ]]; then
    echo "ERROR: EXECUTION_MODE must be sequential or concurrent." >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"
printf '%s\n' "${ARTIFACTS_DIR}" > "${ARTIFACTS_ROOT_DIR}/latest_run.txt"

if [[ ! -d "${SHARED_TESTS_DIR}" ]]; then
    echo "ERROR: Shared MPI tests directory not found: ${SHARED_TESTS_DIR}" >&2
    exit 1
fi

if [[ ! -d "${FIXTURES_DIR}" ]]; then
    echo "ERROR: Fixtures directory not found: ${FIXTURES_DIR}" >&2
    exit 1
fi

if [[ ! -d "${TESTS_SUPPORT_DIR}" ]]; then
    echo "ERROR: Tests-support directory not found: ${TESTS_SUPPORT_DIR}" >&2
    exit 1
fi

if [[ ! -f "${SINGULARITY_IMAGE}" ]]; then
    echo "ERROR: Singularity image not found: ${SINGULARITY_IMAGE}" >&2
    exit 1
fi

echo "============================================================"
echo "mpich-base Slurm test launcher"
echo "============================================================"
echo "Repository root      : ${REPO_ROOT}"
echo "Run ID               : ${RUN_ID}"
echo "Artifacts directory  : ${ARTIFACTS_DIR}"
echo "MPI directory        : ${REPO_MPI_DIR}"
echo "Launcher directory   : ${TESTING_DIR}"
echo "Shared tests directory: ${SHARED_TESTS_DIR}"
echo "Fixtures directory   : ${FIXTURES_DIR}"
echo "Tests support dir    : ${TESTS_SUPPORT_DIR}"
echo "Image                : ${SINGULARITY_IMAGE}"
echo "Singularity module   : ${SINGULARITY_MODULE}"
echo "Partition            : ${PARTITION}"
echo "Execution mode       : ${EXECUTION_MODE}"
if [[ -n "${RESERVATION:-}" ]]; then
    echo "Reservation          : ${RESERVATION}"
else
    echo "Reservation          : none"
fi
echo "Build directory      : ${BUILD_DIR}"
echo "Output directory     : ${OUTPUT_DIR}"
echo ""

if ! command -v sbatch >/dev/null 2>&1; then
    echo "ERROR: sbatch not found. These tests must be run on a Slurm login node." >&2
    exit 1
fi

cd "${TESTING_DIR}"
export SINGULARITY_IMAGE="${SINGULARITY_IMAGE}"
export REPO_MPI_DIR="${REPO_MPI_DIR}"
export SINGULARITY_MODULE="${SINGULARITY_MODULE}"
export ARTIFACTS_DIR="${ARTIFACTS_DIR}"
export BUILD_DIR="${BUILD_DIR}"
export OUTPUT_DIR="${OUTPUT_DIR}"

FAILED=0
declare -a TEST_JOB_IDS=()
PREVIOUS_JOB_ID=""

print_test_warnings() {
    local before_file="$1"
    local after_file="$2"

    comm -13 "${before_file}" "${after_file}" | while read -r warn_file; do
        if [[ -f "${warn_file}" ]]; then
            echo
            echo "WARNING FILE: ${warn_file}"
            echo "------------------------------------------------------------"
            cat "${warn_file}"
            echo "------------------------------------------------------------"
        fi
    done
}

run_slurm_test() {
    local test_script="$1"
    local number_of_nodes="$2"
    local tasks_per_node="$3"
    local test_file
    local test_name
    local job_id
    local marker_pass
    local marker_fail
    local marker_warn
    local slurm_output
    local slurm_error

    if ! [[ "${number_of_nodes}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Number of nodes must be a positive integer: ${number_of_nodes}" >&2
        FAILED=1
        return
    fi

    if ! [[ "${tasks_per_node}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Tasks per node must be a positive integer: ${tasks_per_node}" >&2
        FAILED=1
        return
    fi

    test_script_abs="$(realpath "${test_script}")"
    test_file="$(basename "${test_script_abs}")"
    test_name="${test_file%.slurm.sh}"

    marker_pass="${OUTPUT_DIR}/${test_name}.PASS"
    marker_fail="${OUTPUT_DIR}/${test_name}.FAIL"
    marker_warn="${OUTPUT_DIR}/${test_name}.WARN"
    slurm_output="${OUTPUT_DIR}/slurm-${test_name}-%j.out"
    slurm_error="${OUTPUT_DIR}/slurm-${test_name}-%j.err"

    rm -f "${marker_pass}" "${marker_fail}" "${marker_warn}"

    if [[ ! -f "${test_script_abs}" ]]; then
        echo "ERROR: Test script not found: ${test_script_abs}" >&2
        FAILED=1
        return
    fi

    echo ""
    echo "Submitting: ${test_script_abs}"
    echo "Test name : ${test_name}"
    echo "Nodes     : ${number_of_nodes}"
    echo "Tasks/node: ${tasks_per_node}"

    local -a reservation_args=()
    local -a dependency_args=()

    if [[ -n "${RESERVATION:-}" ]]; then
        reservation_args+=(--reservation="${RESERVATION}")
    fi

    if [[ "${EXECUTION_MODE}" == "sequential" && -n "${PREVIOUS_JOB_ID}" ]]; then
        dependency_args+=(--dependency="afterany:${PREVIOUS_JOB_ID}")
    fi

    job_id="$(sbatch --parsable \
        --job-name="${test_name}" \
        --nodes="${number_of_nodes}" \
        --ntasks-per-node="${tasks_per_node}" \
        --partition="${PARTITION}" \
        "${reservation_args[@]}" \
        "${dependency_args[@]}" \
        --output="${slurm_output}" \
        --error="${slurm_error}" \
        --export=SINGULARITY_IMAGE,REPO_MPI_DIR,SINGULARITY_MODULE,ARTIFACTS_DIR,BUILD_DIR,OUTPUT_DIR \
        "${test_script_abs}")"

    IFS=';' read -r job_id _ <<< "${job_id}"
    TEST_JOB_IDS+=("${job_id}")
    PREVIOUS_JOB_ID="${job_id}"

    echo "Submitted job: ${job_id}"
    echo "Output directory: ${OUTPUT_DIR}"
    echo "Slurm output file: ${OUTPUT_DIR}/slurm-${test_name}-${job_id}.out"
    echo "Slurm error file: ${OUTPUT_DIR}/slurm-${test_name}-${job_id}.err"
}


# Run all tests:
# Use: run_slurm_test <test_script> <number_of_nodes> <tasks_per_node>
run_slurm_test "${SHARED_TESTS_DIR}/test_01_compile+run.slurm.sh" 2 4
run_slurm_test "${SHARED_TESTS_DIR}/test_02_osu.slurm.sh" 2 4
run_slurm_test "${SHARED_TESTS_DIR}/test_03_mpi4py.slurm.sh" 2 4
run_slurm_test "${SHARED_TESTS_DIR}/test_04_mpi-comm.slurm.sh" 2 8

job_id_list="$(IFS=,; echo "${TEST_JOB_IDS[@]}")"

echo
echo "Waiting for all submitted tests to finish..."
echo "Job IDs: ${job_id_list}"

while true; do
    active_jobs=0

    for job_id in "${TEST_JOB_IDS[@]}"; do
        if [[ -n "$(squeue --noheader --jobs="${job_id}" 2>/dev/null)" ]]; then
            active_jobs=$((active_jobs + 1))
        fi
    done

    if [[ "${active_jobs}" -eq 0 ]]; then
        break
    fi

    echo "Tests still pending or running: ${active_jobs}"
    sleep 5
done

echo "All submitted tests have finished."

for test_name in \
    "test_01_compile+run" \
    "test_02_osu" \
    "test_03_mpi4py" \
    "test_04_mpi-comm"
do
    marker_pass="${OUTPUT_DIR}/${test_name}.PASS"
    marker_fail="${OUTPUT_DIR}/${test_name}.FAIL"
    marker_warn="${OUTPUT_DIR}/${test_name}.WARN"

    echo

    if [[ -f "${marker_pass}" ]]; then
        echo "PASS: ${test_name}"

        if [[ -f "${marker_warn}" ]]; then
            echo "Warnings:"
            echo "------------------------------------------------------------"
            cat "${marker_warn}"
            echo "------------------------------------------------------------"
        fi

        continue
    fi

    echo "FAIL: ${test_name}" >&2

    if [[ -f "${marker_fail}" ]]; then
        echo "Failure marker: ${marker_fail}" >&2
        cat "${marker_fail}" >&2 || true
    else
        echo "No PASS marker found: ${marker_pass}" >&2
        echo "No FAIL marker found: ${marker_fail}" >&2
    fi

    FAILED=1
done

echo
echo "============================================================"
echo "Test summary"
echo "============================================================"

if [[ "${FAILED}" -ne 0 ]]; then
    echo "RESULT: FAIL"
    echo "See output files under: ${OUTPUT_DIR}" >&2
    exit 1
fi

echo "RESULT: PASS"
echo "All enabled tests passed."
exit 0
