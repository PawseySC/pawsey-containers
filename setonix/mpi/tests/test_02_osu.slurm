#!/bin/bash --login
#SBATCH --job-name=test_02_osu
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:15:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-%x-%j.out

# Focus:
# This test checks that selected OSU MPI benchmarks are available,
# correctly linked, and runnable with user-selected job resources.

# Note:
# This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
# This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.

# Normally this script is submitted by one of the product-specific launchers:
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
#   export SINGULARITY_MODULE="singularity/4.1.0-mpi"
#   sbatch --export=REPO_MPI_DIR,SINGULARITY_IMAGE,SINGULARITY_MODULE \
#       /path/to/repo/pawsey-containers/setonix/mpi/tests/test_02_osu.slurm
#
# REPO_MPI_DIR must point to the repository's pawsey-containers/setonix/mpi directory.
# SINGULARITY_IMAGE must point to the container image being tested.
# SINGULARITY_MODULE defaults to singularity/4.1.0-mpi when not exported.

#--- Strict mode
set -euo pipefail

#--- Name used for output files and markers
: "${SLURM_JOB_NAME:?SLURM_JOB_NAME is not set}"
TEST_NAME="${SLURM_JOB_NAME}"

#--- Important variables to be provided as environment variable
# The singularity image to use:
: "${SINGULARITY_IMAGE:?SINGULARITY_IMAGE is not set}"
# The Singularity module to load (default supports direct submission):
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/4.1.0-mpi}"
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

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

rm -f "$PASS_MARKER" "$FAIL_MARKER"

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

pass() {
    echo
    echo "${TEST_NAME}: PASS"
    {
        echo "${TEST_NAME}: PASS"
    } > "${PASS_MARKER}"
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
export MPICH_OFI_STARTUP_CONNECT=1
export MPICH_OFI_VERBOSE=1

export FI_CXI_DEFAULT_VNI
FI_CXI_DEFAULT_VNI="$(od -vAn -N4 -tu < /dev/urandom)"

echo "MPICH_OFI_STARTUP_CONNECT=${MPICH_OFI_STARTUP_CONNECT}"
echo "MPICH_OFI_VERBOSE=${MPICH_OFI_VERBOSE}"
echo "FI_CXI_DEFAULT_VNI=${FI_CXI_DEFAULT_VNI}"

#--- Output files
fileOutBinaries="${OUTPUT_DIR}/res_${TEST_NAME}.osu_binaries.out"
fileOutLinkage="${OUTPUT_DIR}/res_${TEST_NAME}.linkage.out"
fileOutLatency="${OUTPUT_DIR}/res_${TEST_NAME}.osu_latency.out"
fileOutBW="${OUTPUT_DIR}/res_${TEST_NAME}.osu_bw.out"
fileOutReduce="${OUTPUT_DIR}/res_${TEST_NAME}.osu_allreduce.out"

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

if ! grep -Fq "osu_latency" "${fileOutBinaries}"; then
    fail "osu_latency was not found in OSU binary check output. See: ${fileOutBinaries}"
fi

if ! grep -Fq "osu_bw" "${fileOutBinaries}"; then
    fail "osu_bw was not found in OSU binary check output. See: ${fileOutBinaries}"
fi

if ! grep -Fq "osu_allreduce" "${fileOutBinaries}"; then
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

if ! grep -Fq "/opt/cray/pe/mpich" "${fileOutLinkage}"; then
    fail "Expected osu_latency to link against /opt/cray/pe/mpich. See: ${fileOutLinkage}"
fi

if ! grep -Fq "/opt/cray/libfabric" "${fileOutLinkage}"; then
    fail "Expected osu_latency to link against /opt/cray/libfabric. See: ${fileOutLinkage}"
fi

echo "Linkage check passed"

#--- Point-to-point placement
# osu_latency and osu_bw require exactly two MPI ranks. Use one allocated
# node when the job has one node; otherwise use two nodes from the allocation.
if [[ "${SLURM_JOB_NUM_NODES}" -eq 1 ]]; then
    OSU_P2P_NODES=1
    OSU_P2P_TASKS_PER_NODE=2
    echo "WARNING: One node was allocated. osu_latency and osu_bw will run with two ranks on the same node."
else
    OSU_P2P_NODES=2
    OSU_P2P_TASKS_PER_NODE=1

    if [[ "${SLURM_JOB_NUM_NODES}" -gt 2 ]]; then
        echo "WARNING: ${SLURM_JOB_NUM_NODES} nodes were allocated. osu_latency and osu_bw will use only two allocated nodes."
    fi
fi

#--- OSU latency test
echo
echo "=== OSU latency: ${OSU_P2P_NODES} node(s), 2 total ranks ==="

if ! srun -N "${OSU_P2P_NODES}" -n 2 --ntasks-per-node="${OSU_P2P_TASKS_PER_NODE}" \
    singularity exec "${SINGULARITY_IMAGE}" osu_latency \
    | tee "${fileOutLatency}"; then
    fail "osu_latency failed. See: ${fileOutLatency}"
fi

if ! grep -Fq "# OSU MPI Latency Test" "${fileOutLatency}"; then
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
echo "=== OSU bandwidth: ${OSU_P2P_NODES} node(s), 2 total ranks ==="

if ! srun -N "${OSU_P2P_NODES}" -n 2 --ntasks-per-node="${OSU_P2P_TASKS_PER_NODE}" \
    singularity exec "${SINGULARITY_IMAGE}" osu_bw \
    | tee "${fileOutBW}"; then
    fail "osu_bw failed. See: ${fileOutBW}"
fi

if ! grep -Fq "# OSU MPI Bandwidth Test" "${fileOutBW}"; then
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

if ! grep -Fq "# OSU MPI Allreduce Latency Test" "${fileOutReduce}"; then
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
