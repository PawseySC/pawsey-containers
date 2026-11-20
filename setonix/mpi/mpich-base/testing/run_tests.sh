#!/usr/bin/env bash
set -euo pipefail

TEST_SELECTION_FILTER=()
case "${1:-}" in
    "")
        ;;
    image_testing)
        TEST_SELECTION_FILTER+=( -E "container_image.mode == 'image_testing'" )
        ;;
    framework_testing)
        TEST_SELECTION_FILTER+=( -E "container_image.mode == 'framework_testing'" )
        ;;
    *)
        echo "Usage: $0 [image_testing|framework_testing]" >&2
        exit 1
        ;;
esac

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
mkdir -p "${ARTIFACTS_DIR}"
printf '%s\n' "${ARTIFACTS_DIR}" > "${ARTIFACTS_ROOT_DIR}/latest_run.txt"

# Load reframe
module load reframe/4.7.3

# Reframe files
RFM_TEST_FILE="${SHARED_TESTS_DIR}/mpich-base_tests.py"
RFM_SETTINGS_FILE="${TESTS_SUPPORT_DIR}/rfm_settings.py"

# Run tests# Run tests - store stage and output directories under $ARTIFACTS_DIR
reframe -C "${RFM_SETTINGS_FILE}" -c "${RFM_TEST_FILE}" "${TEST_SELECTION_FILTER[@]}" -r --prefix="${ARTIFACTS_DIR}"

# Move output and log to directory for this run
mv reframe.out "${ARTIFACTS_DIR}"
mv reframe.log "${ARTIFACTS_DIR}"