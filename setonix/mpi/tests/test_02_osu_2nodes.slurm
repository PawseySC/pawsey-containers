#!/bin/bash --login
#SBATCH --job-name=test_02_osu_2nodes
#SBATCH --nodes=2
#SBATCH --ntasks=8
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:15:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-%x-%j.out

# Focus:
# This test checks that selected OSU MPI benchmarks are available,
# correctly linked, and runnable across two nodes.

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
#   sbatch --export=REPO_MPI_DIR,SINGULARITY_IMAGE \
#       /path/to/repo/pawsey-containers/setonix/mpi/tests/test_02_osu_2nodes.slurm
#
# REPO_MPI_DIR must point to the repository's pawsey-containers/setonix/mpi directory.
# SINGULARITY_IMAGE must point to the container image being tested.

#--- Strict mode
set -euo pipefail

#--- Name used for output files and markers
: "${SLURM_JOB_NAME:?SLURM_JOB_NAME is not set}"
TEST_NAME="${SLURM_JOB_NAME}"

#--- Important variables to be provided as environment variable
# The singularity image to use:
: "${SINGULARITY_IMAGE:?SINGULARITY_IMAGE is not set}"
# The path of the mpi subdirectory in the repository (needed as reference to find the rest of the stuff):
: "${REPO_MPI_DIR:?REPO_MPI_DIR is not set. Submit this test through a run_tests.sh script or export REPO_MPI_DIR manually.}"

#--- Basic path setup
LAUNCH_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
SHARED_TESTS_DIR="$REPO_MPI_DIR/tests"
FIXTURES_DIR="$SHARED_TESTS_DIR/fixtures"
TESTS_SUPPORT_DIR="$SHARED_TESTS_DIR/tests-support"
ARTIFACTS_DIR="$LAUNCH_DIR/artifacts"
BUILD_DIR="$ARTIFACTS_DIR/build"
OUTPUT_DIR="$ARTIFACTS_DIR/output"
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
echo "Launch directory: $LAUNCH_DIR"
echo "MPI directory: $REPO_MPI_DIR"
echo "Shared tests directory: $SHARED_TESTS_DIR"
echo "Fixtures directory: $FIXTURES_DIR"
echo "Build directory: $BUILD_DIR"
echo "Output directory: $OUTPUT_DIR"

#--- Modules and settings
module load singularity/4.1.0-mpi

if [[ "${PAWSEY_CLUSTER:-}" == "joey" ]]; then
    source "${TESTS_SUPPORT_DIR}/common.Joey.settings.sh"
fi

module list

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

#--- OSU latency test
echo
echo "=== OSU latency: 2 nodes, 1 rank per node ==="

if ! srun -N 2 -n 2 --ntasks-per-node=1 \
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
echo "=== OSU bandwidth: 2 nodes, 1 rank per node ==="

if ! srun -N 2 -n 2 --ntasks-per-node=1 \
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
