#!/usr/bin/env bash
set -euo pipefail

# Master test launcher for openmpi-base.
#
# Intended to be run by Git CI or manually from anywhere:
#
#   ./setonix/mpi/openmpi-base/testing/run_tests.sh
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

REPO_OPENMPI_BASE_DIR="$(cd "${TESTING_DIR}/.." && pwd)"
REPO_MPI_DIR="$(cd "${REPO_OPENMPI_BASE_DIR}/.." && pwd)"
REPO_SETONIX_DIR="$(cd "${REPO_MPI_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${REPO_SETONIX_DIR}/.." && pwd)"

SHARED_TESTS_DIR="${REPO_MPI_DIR}/tests"
FIXTURES_DIR="${SHARED_TESTS_DIR}/fixtures"
TESTS_SUPPORT_DIR="${SHARED_TESTS_DIR}/tests-support"

ARTIFACTS_DIR="${TESTING_DIR}/artifacts"
BUILD_DIR="${ARTIFACTS_DIR}/build"
OUTPUT_DIR="${ARTIFACTS_DIR}/output"

IMAGE_DIR="${REPO_MPI_DIR}/artifacts/singularityImages"

OPENMPI_VERSION="${OPENMPI_VERSION:-4.2.2}"
OS_VERSION="${OS_VERSION:-24.04}"
IMAGE_NAME="openmpi-base"
IMAGE_TAG="openmpi${OPENMPI_VERSION}-ubuntu${OS_VERSION}"
SINGULARITY_IMAGE="${IMAGE_DIR}/${IMAGE_NAME}--${IMAGE_TAG}.sif"

mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"

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
echo "openmpi-base Slurm test launcher"
echo "============================================================"
echo "Repository root      : ${REPO_ROOT}"
echo "MPI directory        : ${REPO_MPI_DIR}"
echo "Launcher directory   : ${TESTING_DIR}"
echo "Shared tests directory: ${SHARED_TESTS_DIR}"
echo "Fixtures directory   : ${FIXTURES_DIR}"
echo "Tests support dir    : ${TESTS_SUPPORT_DIR}"
echo "Image                : ${SINGULARITY_IMAGE}"
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

FAILED=0

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
    local test_script_abs
    local test_file
    local test_name
    local job_id
    local marker_pass
    local marker_fail
    local marker_warn
    local slurm_output

    test_script_abs="$(realpath "${test_script}")"
    test_file="$(basename "${test_script_abs}")"
    test_name="${test_file%.slurm}"

    marker_pass="${OUTPUT_DIR}/${test_name}.PASS"
    marker_fail="${OUTPUT_DIR}/${test_name}.FAIL"
    marker_warn="${OUTPUT_DIR}/${test_name}.WARN"
    slurm_output="${OUTPUT_DIR}/slurm-${test_name}-%j.out"

    rm -f "${marker_pass}" "${marker_fail}" "${marker_warn}"

    if [[ ! -f "${test_script_abs}" ]]; then
        echo "ERROR: Test script not found: ${test_script_abs}" >&2
        FAILED=1
        return
    fi

    echo ""
    echo "Submitting: ${test_script_abs}"
    echo "Test name : ${test_name}"

    job_id="$(sbatch --parsable \
        --job-name="${test_name}" \
        --output="${slurm_output}" \
        --export=SINGULARITY_IMAGE,REPO_MPI_DIR \
        "${test_script_abs}")"

    echo "Submitted job: ${job_id}"
    echo "Output directory: ${OUTPUT_DIR}"
    echo "Slurm output file: ${OUTPUT_DIR}/slurm-${test_name}-${job_id}.out"
    echo "Waiting for job completion..."

    while squeue -j "${job_id}" -h >/dev/null 2>&1 && [[ -n "$(squeue -j "${job_id}" -h)" ]]; do
        sleep 5
    done

    if [[ -f "${marker_pass}" ]]; then
        echo "PASS: ${test_file}"

        if [[ -f "${marker_warn}" ]]; then
            echo "Warnings:"
            echo "------------------------------------------------------------"
            cat "${marker_warn}"
            echo "------------------------------------------------------------"
        fi
        return
    fi

    echo "FAIL: ${test_file}" >&2

    if [[ -f "${marker_fail}" ]]; then
        echo "Failure marker: ${marker_fail}" >&2
        cat "${marker_fail}" >&2 || true
    else
        echo "No PASS marker found: ${marker_pass}" >&2
        echo "No FAIL marker found: ${marker_fail}" >&2
    fi

    FAILED=1
}


# Run all tests:
run_slurm_test "${SHARED_TESTS_DIR}/test_01_compile+run_2nodes.slurm"
run_slurm_test "${SHARED_TESTS_DIR}/test_02_osu_2nodes.slurm"
run_slurm_test "${SHARED_TESTS_DIR}/test_03_mpi4py_2nodes.slurm"
run_slurm_test "${SHARED_TESTS_DIR}/test_04_mpi-comm_2nodes.slurm"

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
