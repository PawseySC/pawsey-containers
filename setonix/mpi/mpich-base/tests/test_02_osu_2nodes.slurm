#!/bin/bash --login
#SBATCH --job-name=T02-osu-2nodes
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:15:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=artifacts/output/slurm-test_02-%j.out

# Focus:
# This test focuses on proper execution of some OSU tests

# Note:
# This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
# This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.s

#--- Strict mode
set -euo pipefail

#--- Helper functions
fail() {
    echo
    echo "TEST_02: FAIL"
    echo "Reason: $*" >&2

    if [[ -n "${OUTPUT_DIR:-}" ]]; then
        mkdir -p "${OUTPUT_DIR}"
        echo "$*" > "${OUTPUT_DIR}/test_02.FAIL"
    fi

    exit 1
}

pass() {
    echo
    echo "TEST_02: PASS"

    mkdir -p "${OUTPUT_DIR}"
    echo "PASS" > "${OUTPUT_DIR}/test_02.PASS"

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

# Remove stale PASS/FAIL markers from previous runs
rm -f "${OUTPUT_DIR}/test_02.PASS" "${OUTPUT_DIR}/test_02.FAIL"

#--- Names and version settings
MPICH_VERSION="${MPICH_VERSION:-4.2.2}"
OS_VERSION="${OS_VERSION:-24.04}"
IMAGE_NAME="${IMAGE_NAME:-mpich-base}"

IMAGE_DIR="${IMAGE_DIR:-${ARTIFACTS_DIR}/singularityImages}"
TESTS_SUPPORT_DIR="${TESTS_SUPPORT_DIR:-${MPI_DIR}/repo-support/tests-support}"

#--- Canonical paths
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
echo "Artifacts directory: ${ARTIFACTS_DIR}"
echo "Build directory: ${BUILD_DIR}"
echo "Output directory: ${OUTPUT_DIR}"

#--- Modules and settings
module load singularity/4.1.0-mpi

if [[ "${PAWSEY_CLUSTER:-}" == "joey" ]]; then
    source "${TESTS_SUPPORT_DIR}/common.Joey.settings.sh"
fi

module list

#--- Output files
fileOutBinaries="${OUTPUT_DIR}/res_test_02.osu_binaries.out"
fileOutLinkage="${OUTPUT_DIR}/res_test_02.linkage.out"
fileOutLatency="${OUTPUT_DIR}/res_test_02.osu_latency.out"
fileOutBW="${OUTPUT_DIR}/res_test_02.osu_bw.out"
fileOutReduce="${OUTPUT_DIR}/res_test_02.osu_allreduce.out"

#--- OSU binary availability test
echo
echo "=== OSU binaries ==="

if ! singularity exec "${SINGULARITY_IMAGE}" bash -lc '
    set -euo pipefail
    command -v osu_latency
    command -v osu_bw
    command -v osu_allreduce
' | tee "${fileOutBinaries}"; then
    fail "One or more OSU binaries were not found in the container. See: ${fileOutBinaries}"
fi

if ! grep -q "osu_latency" "${fileOutBinaries}"; then
    fail "osu_latency was not found in OSU binary check output. See: ${fileOutBinaries}"
fi

if ! grep -q "osu_bw" "${fileOutBinaries}"; then
    fail "osu_bw was not found in OSU binary check output. See: ${fileOutBinaries}"
fi

if ! grep -q "osu_allreduce" "${fileOutBinaries}"; then
    fail "osu_allreduce was not found in OSU binary check output. See: ${fileOutBinaries}"
fi

echo "OSU binary check passed"

#--- Linkage test
echo
echo "=== Linkage check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "ldd \"\$(command -v osu_latency)\" | grep -E 'mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true" \
    | tee "${fileOutLinkage}"; then
    fail "Linkage command failed. See: ${fileOutLinkage}"
fi

if ! grep -q "/opt/cray/pe/mpich" "${fileOutLinkage}"; then
    fail "Expected osu_latency to link against /opt/cray/pe/mpich. See: ${fileOutLinkage}"
fi

if ! grep -q "/opt/cray/libfabric" "${fileOutLinkage}"; then
    fail "Expected osu_latency to link against /opt/cray/libfabric. See: ${fileOutLinkage}"
fi

echo "Linkage check passed"

#--- OSU latency test
echo
echo "=== OSU latency: 2 nodes, 1 rank per node ==="

if ! srun -N 2 -n 2 --ntasks-per-node=1 \
    singularity exec "${SINGULARITY_IMAGE}" osu_latency \
    | tee "${fileOutLatency}"; then
    fail "osu_latency failed. See: ${fileOutLatency}"
fi

if ! grep -q "# OSU MPI Latency Test" "${fileOutLatency}"; then
    fail "osu_latency output did not contain expected header. See: ${fileOutLatency}"
fi

if ! grep -Eq "^4[[:space:]]+[0-9]" "${fileOutLatency}"; then
    fail "osu_latency output did not contain expected size=4 data row. See: ${fileOutLatency}"
fi

if ! grep -Eq "^1048576[[:space:]]+[0-9]" "${fileOutLatency}"; then
    fail "osu_latency output did not contain expected size=1048576 data row. See: ${fileOutLatency}"
fi

echo "OSU latency check passed"

#--- OSU bandwidth test
echo
echo "=== OSU bandwidth: 2 nodes, 1 rank per node ==="

if ! srun -N 2 -n 2 --ntasks-per-node=1 \
    singularity exec "${SINGULARITY_IMAGE}" osu_bw \
    | tee "${fileOutBW}"; then
    fail "osu_bw failed. See: ${fileOutBW}"
fi

if ! grep -q "# OSU MPI Bandwidth Test" "${fileOutBW}"; then
    fail "osu_bw output did not contain expected header. See: ${fileOutBW}"
fi

if ! grep -Eq "^1048576[[:space:]]+[0-9]" "${fileOutBW}"; then
    fail "osu_bw output did not contain expected size=1048576 data row. See: ${fileOutBW}"
fi

echo "OSU bandwidth check passed"

#--- OSU allreduce test
echo
echo "=== OSU allreduce: ${SLURM_JOB_NUM_NODES} nodes, ${SLURM_NTASKS_PER_NODE} ranks per node ==="

if ! srun -N "${SLURM_JOB_NUM_NODES}" \
     --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
     singularity exec "${SINGULARITY_IMAGE}" osu_allreduce \
     | tee "${fileOutReduce}"; then
    fail "osu_allreduce failed. See: ${fileOutReduce}"
fi

if ! grep -q "# OSU MPI Allreduce Latency Test" "${fileOutReduce}"; then
    fail "osu_allreduce output did not contain expected header. See: ${fileOutReduce}"
fi

if ! grep -Eq "^4[[:space:]]+[0-9]" "${fileOutReduce}"; then
    fail "osu_allreduce output did not contain expected size=4 data row. See: ${fileOutReduce}"
fi

if ! grep -Eq "^1048576[[:space:]]+[0-9]" "${fileOutReduce}"; then
    fail "osu_allreduce output did not contain expected size=1048576 data row. See: ${fileOutReduce}"
fi

echo "OSU allreduce check passed"

pass
