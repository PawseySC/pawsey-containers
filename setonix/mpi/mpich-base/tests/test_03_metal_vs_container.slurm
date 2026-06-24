#!/bin/bash --login
#SBATCH --job-name=T03_metal-vs-cntr
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --time=00:20:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=artifacts/output/slurm-test_03-%j.out

# Focus:
# This test focuses on comparing the execution of bare-metal compiled binary
# vs compiled&run from the container

#--- Strict mode
set -euo pipefail

#--- Helper functions
fail() {
    echo
    echo "TEST_03: FAIL"
    echo "Reason: $*" >&2

    if [[ -n "${OUTPUT_DIR:-}" ]]; then
        mkdir -p "${ARTIFACTS_DIR:-${OUTPUT_DIR}/..}" "${OUTPUT_DIR}"
        echo "$*" > "${OUTPUT_DIR}/test_03.FAIL"
    fi

    exit 1
}

warn() {
    local msg="$*"

    echo "WARNING: ${msg}" >&2

    WARN_COUNT=$((WARN_COUNT + 1))

    if [[ -n "${OUTPUT_DIR:-}" ]]; then
        mkdir -p "${ARTIFACTS_DIR}" "${OUTPUT_DIR}"
        echo "WARNING: ${msg}" >> "${OUTPUT_DIR}/test_03.WARN"
    fi
}

pass() {
    echo

    if [[ "${WARN_COUNT}" -gt 0 ]]; then
        echo "TEST_03: PASS with ${WARN_COUNT} warning(s)"
        echo "PASS_WITH_WARNINGS" > "${OUTPUT_DIR}/test_03.PASS"
    else
        echo "TEST_03: PASS"
        echo "PASS" > "${OUTPUT_DIR}/test_03.PASS"
    fi

    exit 0
}

compare_metric_ratio() {
    local label="$1"
    local metal_value="$2"
    local container_value="$3"
    local lower_ratio="$4"
    local upper_ratio="$5"

    awk -v label="${label}" \
        -v metal="${metal_value}" \
        -v container="${container_value}" \
        -v lower="${lower_ratio}" \
        -v upper="${upper_ratio}" '
        BEGIN {
            if (metal <= 0 || container <= 0) {
                printf("WARNING_NODATA %s metal=%s container=%s\n", label, metal, container);
                exit 10;
            }

            ratio = container / metal;

            printf("METRIC %s metal=%g container=%g ratio=%g\n", label, metal, container, ratio);

            if (ratio < lower || ratio > upper) {
                exit 20;
            }

            exit 0;
        }'
}

extract_pingpong_latency() {
    local file="$1"
    local msg_size="$2"

    awk -v msg_size="${msg_size}" '
        $1 == "PINGPONG" && $2 == "msg_size=" msg_size {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^one_way_latency_us=/) {
                    split($i, a, "=");
                    print a[2];
                    exit;
                }
            }
        }' "${file}"
}

extract_pingpong_bandwidth() {
    local file="$1"
    local msg_size="$2"

    awk -v msg_size="${msg_size}" '
        $1 == "PINGPONG" && $2 == "msg_size=" msg_size {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^bandwidth_MBps=/) {
                    split($i, a, "=");
                    print a[2];
                    exit;
                }
            }
        }' "${file}"
}

extract_allreduce_latency() {
    local file="$1"

    awk '
        $1 == "ALLREDUCE_DOUBLE" {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^avg_latency_us=/) {
                    split($i, a, "=");
                    print a[2];
                    exit;
                }
            }
        }' "${file}"
}

compare_and_warn() {
    local label="$1"
    local metal_value="$2"
    local container_value="$3"
    local compare_file="$4"

    local lower_ratio="0.5"
    local upper_ratio="2.0"

    set +e
    local result
    result="$(compare_metric_ratio "${label}" "${metal_value}" "${container_value}" "${lower_ratio}" "${upper_ratio}")"
    local rc=$?
    set -e

    echo "${result}" | tee -a "${compare_file}"

    if [[ "${rc}" -eq 10 ]]; then
        warn "Could not compare ${label}; missing or invalid metric. metal=${metal_value}, container=${container_value}"
    elif [[ "${rc}" -eq 20 ]]; then
        warn "${label} differs by more than 2x. metal=${metal_value}, container=${container_value}"
    elif [[ "${rc}" -ne 0 ]]; then
        fail "Unexpected comparison failure for ${label}"
    fi
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
FIXTURE_DIR="${TESTS_DIR}/fixtures"
ARTIFACTS_DIR="${TESTS_DIR}/artifacts"
BUILD_DIR="${ARTIFACTS_DIR}/build"
OUTPUT_DIR="${ARTIFACTS_DIR}/output"

mkdir -p "${ARTIFACTS_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"

# Remove stale PASS/FAIL/WARN markers from previous runs
rm -f "${OUTPUT_DIR}/test_03.PASS" \
      "${OUTPUT_DIR}/test_03.FAIL" \
      "${OUTPUT_DIR}/test_03.WARN"

WARN_COUNT=0

#--- Names and version settings
MPICH_VERSION="${MPICH_VERSION:-4.2.2}"
OS_VERSION="${OS_VERSION:-24.04}"
IMAGE_NAME="${IMAGE_NAME:-mpich-base}"

IMAGE_DIR="${IMAGE_DIR:-${ARTIFACTS_DIR}/singularityImages}"
AUX_DIR="${AUX_DIR:-${MPI_DIR}/auxiliary}"

#--- Canonical paths
FIXTURE_DIR="$(realpath "${FIXTURE_DIR}")"
ARTIFACTS_DIR="$(realpath "${ARTIFACTS_DIR}")"
BUILD_DIR="$(realpath "${BUILD_DIR}")"
OUTPUT_DIR="$(realpath "${OUTPUT_DIR}")"
IMAGE_DIR="$(realpath "${IMAGE_DIR}")"
AUX_DIR="$(realpath "${AUX_DIR}")"

#--- Defining image to use
IMAGE_TAG="${MPICH_VERSION}-ubuntu${OS_VERSION}"
IMAGE_FULL="${IMAGE_NAME}--${IMAGE_TAG}.sif"
SINGULARITY_IMAGE="${IMAGE_DIR}/${IMAGE_FULL}"

if [[ ! -f "${SINGULARITY_IMAGE}" ]]; then
    fail "Singularity image not found: ${SINGULARITY_IMAGE}"
fi

echo "Using image: ${SINGULARITY_IMAGE}"
echo "Repository root: ${REPO_ROOT}"
echo "Tests directory: ${TESTS_DIR}"
echo "Fixtures directory: ${FIXTURE_DIR}"
echo "Artifacts directory: ${ARTIFACTS_DIR}"
echo "Build directory: ${BUILD_DIR}"
echo "Output directory: ${OUTPUT_DIR}"

#--- Modules and settings
module load singularity/4.1.0-mpi

if [[ "${PAWSEY_CLUSTER:-}" == "joey" ]]; then
    source "${AUX_DIR}/common.Joey.settings.sh"
fi

module list

#--- Input/output files
src="${FIXTURE_DIR}/mpi_perf_compare.c"

theMetalExe="${BUILD_DIR}/mpi_perf_compare.metal.exe"
theImageExe="${BUILD_DIR}/mpi_perf_compare.image.exe"

fileOutMetalCompile="${OUTPUT_DIR}/res_test_03.compile_metal.out"
fileOutImageCompile="${OUTPUT_DIR}/res_test_03.compile_container.out"
fileOutLinkage="${OUTPUT_DIR}/res_test_03.linkage.out"

fileOutMetal1Node="${OUTPUT_DIR}/res_test_03.metal_1node.out"
fileOutCtnr1Node="${OUTPUT_DIR}/res_test_03.container_1node.out"
fileOutMetal2Node="${OUTPUT_DIR}/res_test_03.metal_2node.out"
fileOutCtnr2Node="${OUTPUT_DIR}/res_test_03.container_2node.out"
fileOutSummary="${OUTPUT_DIR}/res_test_03.summary.out"
fileOutCompare="${OUTPUT_DIR}/res_test_03.performance_compare.out"

rm -f "${fileOutCompare}"

if [[ ! -f "${src}" ]]; then
    fail "Fixture source file not found: ${src}"
fi

#--- Build native binary
echo
echo "=== Build native binary with Cray wrapper cc ==="

cc -O3 "${src}" -o "${theMetalExe}" \
    > "${fileOutMetalCompile}" 2>&1 \
    || fail "Native compilation with cc failed. See: ${fileOutMetalCompile}"

if [[ ! -x "${theMetalExe}" ]]; then
    fail "Expected native executable was not created or is not executable: ${theMetalExe}"
fi

echo "Native compilation succeeded: ${theMetalExe}"

#--- Build container binary
echo
echo "=== Build container binary with container mpicc ==="

singularity exec "${SINGULARITY_IMAGE}" \
    mpicc -O3 "${src}" -o "${theImageExe}" \
    > "${fileOutImageCompile}" 2>&1 \
    || fail "Container compilation with mpicc failed. See: ${fileOutImageCompile}"

if [[ ! -x "${theImageExe}" ]]; then
    fail "Expected container executable was not created or is not executable: ${theImageExe}"
fi

echo "Container compilation succeeded: ${theImageExe}"

#--- Container binary linkage
echo
echo "=== Container binary linkage ==="

singularity exec "${SINGULARITY_IMAGE}" bash -lc \
    "ldd '${theImageExe}' | grep -E 'mpi|fabric|cxi|pmi|pmix|pals|xpmem' || true" \
    | tee "${fileOutLinkage}"

if ! grep -q "/opt/cray/pe/mpich" "${fileOutLinkage}"; then
    fail "Expected container binary to link against /opt/cray/pe/mpich. See: ${fileOutLinkage}"
fi

if ! grep -q "/opt/cray/libfabric" "${fileOutLinkage}"; then
    fail "Expected container binary to link against /opt/cray/libfabric. See: ${fileOutLinkage}"
fi

echo "Container linkage check passed"

#--- Run native single-node test
echo
echo "============================================================"
echo "METAL_1NODE: 1 node, 8 ranks"
echo "============================================================"

srun -N 1 -n 8 \
    "${theMetalExe}" \
    | tee "${fileOutMetal1Node}" \
    || fail "Native single-node run failed. See: ${fileOutMetal1Node}"

#--- Run container single-node test
echo
echo "============================================================"
echo "CONTAINER_1NODE: 1 node, 8 ranks"
echo "============================================================"

srun -N 1 -n 8 \
    singularity exec "${SINGULARITY_IMAGE}" "${theImageExe}" \
    | tee "${fileOutCtnr1Node}" \
    || fail "Container single-node run failed. See: ${fileOutCtnr1Node}"

#--- Run native two-node test
echo
echo "============================================================"
echo "METAL_2NODE: 2 nodes, 8 ranks per node"
echo "============================================================"

srun -N 2 --ntasks-per-node=8 \
    "${theMetalExe}" \
    | tee "${fileOutMetal2Node}" \
    || fail "Native two-node run failed. See: ${fileOutMetal2Node}"

#--- Run container two-node test
echo
echo "============================================================"
echo "CONTAINER_2NODE: 2 nodes, 8 ranks per node"
echo "============================================================"

srun -N 2 --ntasks-per-node=8 \
    singularity exec "${SINGULARITY_IMAGE}" "${theImageExe}" \
    | tee "${fileOutCtnr2Node}" \
    || fail "Container two-node run failed. See: ${fileOutCtnr2Node}"

#--- Validate successful runs
echo
echo "=== Validate successful runs ==="

grep -q "MPI_PERF_TEST_SUCCESS size=8" "${fileOutMetal1Node}" \
    || fail "Native single-node output missing success line for size=8. See: ${fileOutMetal1Node}"

grep -q "MPI_PERF_TEST_SUCCESS size=8" "${fileOutCtnr1Node}" \
    || fail "Container single-node output missing success line for size=8. See: ${fileOutCtnr1Node}"

grep -q "MPI_PERF_TEST_SUCCESS size=16" "${fileOutMetal2Node}" \
    || fail "Native two-node output missing success line for size=16. See: ${fileOutMetal2Node}"

grep -q "MPI_PERF_TEST_SUCCESS size=16" "${fileOutCtnr2Node}" \
    || fail "Container two-node output missing success line for size=16. See: ${fileOutCtnr2Node}"

#--- Validate rank counts
metal_1node_ranks="$(awk '/^RANK_HOST / {c++} END {print c+0}' "${fileOutMetal1Node}")"
ctnr_1node_ranks="$(awk '/^RANK_HOST / {c++} END {print c+0}' "${fileOutCtnr1Node}")"
metal_2node_ranks="$(awk '/^RANK_HOST / {c++} END {print c+0}' "${fileOutMetal2Node}")"
ctnr_2node_ranks="$(awk '/^RANK_HOST / {c++} END {print c+0}' "${fileOutCtnr2Node}")"

[[ "${metal_1node_ranks}" -eq 8 ]] \
    || fail "Expected 8 RANK_HOST lines for native single-node run, got ${metal_1node_ranks}. See: ${fileOutMetal1Node}"

[[ "${ctnr_1node_ranks}" -eq 8 ]] \
    || fail "Expected 8 RANK_HOST lines for container single-node run, got ${ctnr_1node_ranks}. See: ${fileOutCtnr1Node}"

[[ "${metal_2node_ranks}" -eq 16 ]] \
    || fail "Expected 16 RANK_HOST lines for native two-node run, got ${metal_2node_ranks}. See: ${fileOutMetal2Node}"

[[ "${ctnr_2node_ranks}" -eq 16 ]] \
    || fail "Expected 16 RANK_HOST lines for container two-node run, got ${ctnr_2node_ranks}. See: ${fileOutCtnr2Node}"

#--- Validate benchmark lines exist
for f in \
    "${fileOutMetal1Node}" \
    "${fileOutCtnr1Node}" \
    "${fileOutMetal2Node}" \
    "${fileOutCtnr2Node}"
do
    grep -q "PINGPONG msg_size=0 bytes" "${f}" \
        || fail "Missing PINGPONG msg_size=0 line. See: ${f}"

    grep -q "PINGPONG msg_size=8 bytes" "${f}" \
        || fail "Missing PINGPONG msg_size=8 line. See: ${f}"

    grep -q "PINGPONG msg_size=1048576 bytes" "${f}" \
        || fail "Missing PINGPONG msg_size=1048576 line. See: ${f}"

    grep -q "ALLREDUCE_DOUBLE" "${f}" \
        || fail "Missing ALLREDUCE_DOUBLE line. See: ${f}"
done

echo "Successful-run validation passed"

#--- Summary
echo
echo "=== Summary ==="

{
    echo "--- native single node ---"
    grep -E "PINGPONG|ALLREDUCE" "${fileOutMetal1Node}"

    echo
    echo "--- container single node ---"
    grep -E "PINGPONG|ALLREDUCE" "${fileOutCtnr1Node}"

    echo
    echo "--- native two node ---"
    grep -E "PINGPONG|ALLREDUCE" "${fileOutMetal2Node}"

    echo
    echo "--- container two node ---"
    grep -E "PINGPONG|ALLREDUCE" "${fileOutCtnr2Node}"
} | tee "${fileOutSummary}"

#--- Performance comparison
echo
echo "=== Metal vs container performance comparison ==="

{
    echo "Performance comparison policy:"
    echo "  PASS with warning if container/metal ratio is outside [0.5, 2.0]."
    echo "  These warnings do not fail CI."
    echo
} | tee "${fileOutCompare}"

for scope in 1node 2node; do
    if [[ "${scope}" == "1node" ]]; then
        metal_file="${fileOutMetal1Node}"
        ctnr_file="${fileOutCtnr1Node}"
    else
        metal_file="${fileOutMetal2Node}"
        ctnr_file="${fileOutCtnr2Node}"
    fi

    echo "--- ${scope} ---" | tee -a "${fileOutCompare}"

    for msg_size in 0 8 1048576; do
        metal_latency="$(extract_pingpong_latency "${metal_file}" "${msg_size}")"
        ctnr_latency="$(extract_pingpong_latency "${ctnr_file}" "${msg_size}")"

        compare_and_warn \
            "${scope}.pingpong.${msg_size}B.one_way_latency_us" \
            "${metal_latency}" \
            "${ctnr_latency}" \
            "${fileOutCompare}"

        if [[ "${msg_size}" -ne 0 ]]; then
            metal_bw="$(extract_pingpong_bandwidth "${metal_file}" "${msg_size}")"
            ctnr_bw="$(extract_pingpong_bandwidth "${ctnr_file}" "${msg_size}")"

            compare_and_warn \
                "${scope}.pingpong.${msg_size}B.bandwidth_MBps" \
                "${metal_bw}" \
                "${ctnr_bw}" \
                "${fileOutCompare}"
        fi
    done

    metal_allreduce="$(extract_allreduce_latency "${metal_file}")"
    ctnr_allreduce="$(extract_allreduce_latency "${ctnr_file}")"

    compare_and_warn \
        "${scope}.allreduce.avg_latency_us" \
        "${metal_allreduce}" \
        "${ctnr_allreduce}" \
        "${fileOutCompare}"

    echo | tee -a "${fileOutCompare}"
done

echo
echo "Performance comparison written to: ${fileOutCompare}"

if [[ "${WARN_COUNT}" -gt 0 ]]; then
    echo "Warnings written to: ${OUTPUT_DIR}/test_03.WARN"
fi

pass