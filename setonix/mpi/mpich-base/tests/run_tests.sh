#!/usr/bin/env bash
set -euo pipefail

# Master test launcher for mpich-base.
#
# Intended to be run by Git CI or manually from anywhere:
#
#   ./setonix/mpi/mpich-base/tests/run_tests.sh
#
# This script submits Slurm tests from the tests directory so that
# SLURM_SUBMIT_DIR is predictable.

# Note:
# This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
# This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(realpath "${SCRIPT_DIR}")"

if [[ "$(basename "${TESTS_DIR}")" != "tests" ]]; then
    echo "ERROR: Could not determine tests directory." >&2
    echo "       SCRIPT_DIR=${SCRIPT_DIR}" >&2
    echo "       TESTS_DIR=${TESTS_DIR}" >&2
    exit 1
fi

MPICH_BASE_DIR="$(realpath "${TESTS_DIR}/..")"
MPI_DIR="$(realpath "${MPICH_BASE_DIR}/..")"
SETONIX_DIR="$(realpath "${MPI_DIR}/..")"
REPO_ROOT="$(realpath "${SETONIX_DIR}/..")"

ARTIFACTS_DIR="${TESTS_DIR}/artifacts"
BUILD_DIR="${ARTIFACTS_DIR}/build"
OUTPUT_DIR="${ARTIFACTS_DIR}/output"

mkdir -p "${ARTIFACTS_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"

echo "============================================================"
echo "mpich-base Slurm test launcher"
echo "============================================================"
echo "Repository root : ${REPO_ROOT}"
echo "Tests directory : ${TESTS_DIR}"
echo "Build directory : ${BUILD_DIR}"
echo "Output directory: ${OUTPUT_DIR}"
echo

if ! command -v sbatch >/dev/null 2>&1; then
    echo "ERROR: sbatch not found. These tests must be run on a Slurm login node." >&2
    exit 1
fi

cd "${TESTS_DIR}"

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
    local test_name
    test_name="$(basename "${test_script}")"

    echo
    echo "============================================================"
    echo "Running ${test_name}"
    echo "============================================================"

    if [[ ! -f "${test_script}" ]]; then
        echo "FAIL: test script not found: ${test_script}" >&2
        FAILED=1
        return
    fi

    if [[ ! -r "${test_script}" ]]; then
        echo "FAIL: test script is not readable: ${test_script}" >&2
        FAILED=1
        return
    fi

    local warn_before
    local warn_after

    warn_before="$(mktemp)"
    warn_after="$(mktemp)"

    find "${OUTPUT_DIR}" -maxdepth 1 -type f -name "*.WARN" | sort > "${warn_before}"

    set +e
    sbatch --wait "${test_script}"
    local rc=$?
    set -e

    find "${OUTPUT_DIR}" -maxdepth 1 -type f -name "*.WARN" | sort > "${warn_after}"

    print_test_warnings "${warn_before}" "${warn_after}"

    rm -f "${warn_before}" "${warn_after}"

    if [[ "${rc}" -ne 0 ]]; then
        echo "FAIL: ${test_name} failed with exit code ${rc}" >&2
        FAILED=1
        return
    fi

    echo "PASS: ${test_name}"
}

# Run all tests:
run_slurm_test "test_01_compile+run_2nodes.slurm"
run_slurm_test "test_02_osu_2nodes.slurm"
run_slurm_test "test_03_metal_vs_container.slurm"
run_slurm_test "test_04_mpi4py_2nodes.slurm"
run_slurm_test "test_05_profileUtil_2nodes.slurm"

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
