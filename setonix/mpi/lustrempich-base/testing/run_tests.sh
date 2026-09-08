#!/usr/bin/env bash
set -euo pipefail

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
printf '%s\n' "${ARTIFACTS_DIR}" > "${ARTIFACTS_ROOT_DIR}/latest_run.txt"

# MODULEPATH additions needed in 2026.09 stack on joey
export MODULEPATH=/software/setonix/2026.09/modules/x86_64/gcc/14.2.0/dependencies/:/software/setonix/2026.09/modules/zen3/Core/programming-languages:/software/setonix/2026.09/modules/zen3/Core/dependencies:/software/setonix/2026.09/modules/x86_64/Core/dependencies:$MODULEPATH

# Load reframe and disable database results storage
module load reframe/4.7.3
export RFM_ENABLE_RESULTS_STORAGE=0

# Reframe files
RFM_TEST_FILE="${SHARED_TESTS_DIR}/lustre-mpich-base_tests.py"
RFM_SETTINGS_FILE="${TESTS_SUPPORT_DIR}/rfm_settings.py"

# Run tests - store stage and output directories under $ARTIFACTS_DIR
reframe -C "${RFM_SETTINGS_FILE}" -c "${RFM_TEST_FILE}" -r --prefix="${ARTIFACTS_DIR}"

# Move output and log to directory for this run
mv reframe.out "${ARTIFACTS_DIR}"
mv reframe.log "${ARTIFACTS_DIR}"