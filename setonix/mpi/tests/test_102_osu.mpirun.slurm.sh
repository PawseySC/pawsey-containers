#!/bin/bash --login
#SBATCH --job-name=test_102_osu
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=1
#SBATCH --time=00:15:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-%x-%j.out

# Focus:
# This test verifies that selected precompiled OSU MPI benchmarks are available
# in an MPI container image, dynamically linked to MPI, and executable using
# the container's internal mpirun.
#
# This test is intentionally limited to one Slurm node. Slurm allocates one
# task and one CPU for each MPI rank. The container's mpirun is invoked directly
# from the batch script. osu_latency and osu_bw run with two ranks, while
# osu_allreduce runs with all allocated Slurm tasks.
#
# The detected MPI implementation is reported for diagnostics, but the test is
# not restricted to a particular MPI implementation.
#
# Note:
# This script has been developed by Alexis Espinosa with the help of Microsoft 360 Copilot - GPT 5.5.
# This script has been fully reviewed by Alexis Espinosa at Pawsey Supercomputing Centre.
#
# Normally this script is submitted by a product-specific launcher such as:
#
#   pawsey-containers/setonix/mpi/openmpi-base/testing/run_tests.sh
#
# The launcher defines the required environment variables and submits this
# script with sbatch.
#
# Manual submission example, from the relevant product testing directory:
#
#   export REPO_MPI_DIR="/path/to/repo/pawsey-containers/setonix/mpi"
#   export SINGULARITY_IMAGE="/path/to/image.sif"
#   export SINGULARITY_MODULE="singularity/4.1.0-nohost"
#   sbatch --export=REPO_MPI_DIR,SINGULARITY_IMAGE,SINGULARITY_MODULE \
#       /path/to/repo/pawsey-containers/setonix/mpi/tests/test_102_osu.mpirun.slurm.sh
#
# REPO_MPI_DIR must point to the repository's pawsey-containers/setonix/mpi directory.
# SINGULARITY_IMAGE must point to the container image being tested.
# SINGULARITY_MODULE defaults to singularity/4.1.0-nohost when not exported.

#--- Strict mode
set -euo pipefail

#--- Name used for output files and markers
: "${SLURM_JOB_NAME:?SLURM_JOB_NAME is not set}"
TEST_NAME="${SLURM_JOB_NAME}"

#--- Important variables to be provided as environment variables
: "${SINGULARITY_IMAGE:?SINGULARITY_IMAGE is not set}"
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/4.1.0-nohost}"
: "${REPO_MPI_DIR:?REPO_MPI_DIR is not set. Submit this test through a run_tests.sh script or export REPO_MPI_DIR manually.}"

#--- Basic path setup
LAUNCH_DIR="${SLURM_SUBMIT_DIR:-$PWD}"

ARTIFACTS_ROOT_DIR="${LAUNCH_DIR}/artifacts"
RUN_ID="${CI_PIPELINE_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${ARTIFACTS_ROOT_DIR}/singleruns/${TEST_NAME}/${RUN_ID}}"
OUTPUT_DIR="${OUTPUT_DIR:-${ARTIFACTS_DIR}/output}"
PASS_MARKER="${OUTPUT_DIR}/${TEST_NAME}.PASS"
FAIL_MARKER="${OUTPUT_DIR}/${TEST_NAME}.FAIL"

mkdir -p "${OUTPUT_DIR}"
rm -f "${PASS_MARKER}" "${FAIL_MARKER}"

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
    echo "${TEST_NAME}: PASS" > "${PASS_MARKER}"
}

#--- Resolve and validate inputs
if ! REPO_MPI_DIR="$(cd "${REPO_MPI_DIR}" && pwd)"; then
    fail "REPO_MPI_DIR does not exist or is not accessible: ${REPO_MPI_DIR}"
fi

if [[ ! -f "${SINGULARITY_IMAGE}" ]]; then
    fail "Singularity image not found: ${SINGULARITY_IMAGE}"
fi

#--- Validate the single-node pure-MPI Slurm allocation
: "${SLURM_JOB_NUM_NODES:?SLURM_JOB_NUM_NODES is not set}"
: "${SLURM_NTASKS:?SLURM_NTASKS is not set}"
: "${SLURM_CPUS_PER_TASK:?SLURM_CPUS_PER_TASK is not set}"

if [[ "${SLURM_JOB_NUM_NODES}" != "1" ]]; then
    fail "This test supports exactly one Slurm node; allocated nodes: ${SLURM_JOB_NUM_NODES}"
fi

if ! [[ "${SLURM_NTASKS}" =~ ^[1-9][0-9]*$ ]]; then
    fail "SLURM_NTASKS must be a positive integer: ${SLURM_NTASKS}"
fi

if [[ "${SLURM_NTASKS}" -lt 2 ]]; then
    fail "This test requires at least two MPI ranks; allocated tasks: ${SLURM_NTASKS}"
fi

if [[ "${SLURM_CPUS_PER_TASK}" != "1" ]]; then
    fail "This pure-MPI test requires one CPU per MPI rank; CPUs per task: ${SLURM_CPUS_PER_TASK}"
fi

P2P_RANKS=2
ALLREDUCE_RANKS="${SLURM_NTASKS}"

#--- Modules and selected configuration
echo "Using image: ${SINGULARITY_IMAGE}"
echo "Using Singularity module: ${SINGULARITY_MODULE}"
echo "Launch directory: ${LAUNCH_DIR}"
echo "MPI directory: ${REPO_MPI_DIR}"
echo "Output directory: ${OUTPUT_DIR}"
echo "Slurm nodes: ${SLURM_JOB_NUM_NODES}"
echo "Slurm tasks: ${SLURM_NTASKS}"
echo "CPUs per task: ${SLURM_CPUS_PER_TASK}"
echo "Point-to-point ranks: ${P2P_RANKS}"
echo "Allreduce ranks: ${ALLREDUCE_RANKS}"

module load "${SINGULARITY_MODULE}"
module list

#--- Output files
fileOutMPI="${OUTPUT_DIR}/res_${TEST_NAME}.mpi_info.out"
fileOutBinaries="${OUTPUT_DIR}/res_${TEST_NAME}.osu_binaries.out"
fileOutLinkage="${OUTPUT_DIR}/res_${TEST_NAME}.linkage.out"
fileOutLatency="${OUTPUT_DIR}/res_${TEST_NAME}.osu_latency.out"
fileOutBW="${OUTPUT_DIR}/res_${TEST_NAME}.osu_bw.out"
fileOutReduce="${OUTPUT_DIR}/res_${TEST_NAME}.osu_allreduce.out"

#--- Report the MPI implementation
echo
echo "=== Container MPI information ==="

{
    echo "mpirun version:"
    singularity exec "${SINGULARITY_IMAGE}" mpirun --version || true
} | tee "${fileOutMPI}"

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

for osu_binary in osu_latency osu_bw osu_allreduce; do
    if ! grep -Fq "${osu_binary}" "${fileOutBinaries}"; then
        fail "${osu_binary} was not found in OSU binary check output. See: ${fileOutBinaries}"
    fi
done

echo "OSU binary check passed"

#--- Dynamic linkage test
echo
echo "=== Linkage check ==="

if ! singularity exec "${SINGULARITY_IMAGE}" bash -lc '
    set -euo pipefail
    for osu_binary in osu_latency osu_bw osu_allreduce; do
        osu_path="$(command -v "${osu_binary}")"
        echo "=== ${osu_binary}: ${osu_path} ==="
        ldd "${osu_path}"
        echo
    done
' > "${fileOutLinkage}" 2>&1; then
    cat "${fileOutLinkage}" >&2 || true
    fail "Linkage check failed. See: ${fileOutLinkage}"
fi

cat "${fileOutLinkage}"

if grep -Fq "not found" "${fileOutLinkage}"; then
    fail "One or more OSU binaries have unresolved shared-library dependencies. See: ${fileOutLinkage}"
fi

LIBMPI_COUNT="$(grep -Ec 'libmpi\.so([.[:space:]]|$)' "${fileOutLinkage}" || true)"
if [[ "${LIBMPI_COUNT}" -lt 3 ]]; then
    fail "Expected all three OSU binaries to link dynamically to libmpi. See: ${fileOutLinkage}"
fi

echo "Linkage check passed"

#--- OSU latency test
echo
echo "=== OSU latency: one node, ${P2P_RANKS} ranks ==="

if ! singularity exec "${SINGULARITY_IMAGE}" \
    mpirun -n "${P2P_RANKS}" osu_latency \
    | tee "${fileOutLatency}"; then
    fail "osu_latency failed. See: ${fileOutLatency}"
fi

if ! grep -Fq "# OSU MPI Latency Test" "${fileOutLatency}"; then
    fail "osu_latency output did not contain expected header. See: ${fileOutLatency}"
fi

if ! grep -Eq '^4[[:space:]]+[0-9]' "${fileOutLatency}"; then
    fail "osu_latency output did not contain expected size=4 data row. See: ${fileOutLatency}"
fi

if ! grep -Eq '^1048576[[:space:]]+[0-9]' "${fileOutLatency}"; then
    fail "osu_latency output did not contain expected size=1048576 data row. See: ${fileOutLatency}"
fi

echo "OSU latency check passed"

#--- OSU bandwidth test
echo
echo "=== OSU bandwidth: one node, ${P2P_RANKS} ranks ==="

if ! singularity exec "${SINGULARITY_IMAGE}" \
    mpirun -n "${P2P_RANKS}" osu_bw \
    | tee "${fileOutBW}"; then
    fail "osu_bw failed. See: ${fileOutBW}"
fi

if ! grep -Fq "# OSU MPI Bandwidth Test" "${fileOutBW}"; then
    fail "osu_bw output did not contain expected header. See: ${fileOutBW}"
fi

if ! grep -Eq '^1048576[[:space:]]+[0-9]' "${fileOutBW}"; then
    fail "osu_bw output did not contain expected size=1048576 data row. See: ${fileOutBW}"
fi

echo "OSU bandwidth check passed"

#--- OSU allreduce test
echo
echo "=== OSU allreduce: one node, ${ALLREDUCE_RANKS} ranks ==="

if ! singularity exec "${SINGULARITY_IMAGE}" \
    mpirun -n "${ALLREDUCE_RANKS}" osu_allreduce \
    | tee "${fileOutReduce}"; then
    fail "osu_allreduce failed. See: ${fileOutReduce}"
fi

if ! grep -Fq "# OSU MPI Allreduce Latency Test" "${fileOutReduce}"; then
    fail "osu_allreduce output did not contain expected header. See: ${fileOutReduce}"
fi

if ! grep -Eq '^4[[:space:]]+[0-9]' "${fileOutReduce}"; then
    fail "osu_allreduce output did not contain expected size=4 data row. See: ${fileOutReduce}"
fi

if ! grep -Eq '^1048576[[:space:]]+[0-9]' "${fileOutReduce}"; then
    fail "osu_allreduce output did not contain expected size=1048576 data row. See: ${fileOutReduce}"
fi

echo "OSU allreduce check passed"

pass
