#!/bin/bash -l
#
# Build the RFdiffusion v1.1.0 (ROCm 7.0.0, DGL 2.4.0) container with podman,
# convert it to a Singularity image and run quick checks inside it (no GPU
# needed). Run on a Pawsey podman build node, from anywhere:
#
#   ./build.sh
#
# See README.md in this directory.

TOOL=rfdiffusion
TAG=v1.1.0-rocm7.0.0
EXPECTED_TITLE=rfdiffusion_v1.1.0_rocm7.0.0_ubuntu22.04

# Commands run inside the new image; each must succeed.
SMOKE_CHECKS=(
  "python -c 'import rfdiffusion, se3_transformer, dgl, torch; assert torch.version.hip, \"PyTorch is not a ROCm build\"'"
  "test \$(ls /app/RFdiffusion/models/*.pt | wc -l) -eq 9"
  "cd /tmp && run_inference.py --help | grep -q contigmap"
  "test -d /app/RFdiffusion/examples/ppi_scaffolds && test -d /app/RFdiffusion/examples/target_folds"
)

# ---- settings (export before running to change) -----------------------------
BUILD_DIR="${BUILD_DIR:-${MYSCRATCH:-${PWD}}/gpu_biology_builds}"
PODMAN_JOBS="${PODMAN_JOBS:-4}"
KEEP_OCI_ARCHIVE="${KEEP_OCI_ARCHIVE:-0}"
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/3.11.4-nompi}"

# =============================================================================
# Build steps. This section is the same in every gpu_biology build.sh.
# =============================================================================
set -o pipefail
RECIPE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAME="${TOOL}_${TAG}"
ARCHIVE="${BUILD_DIR}/${NAME}.tar"
SIF="${BUILD_DIR}/${NAME}.sif"
RESULTS=()
FAILED=0

step() {  # step NAME COMMAND...: run a step and record PASS/FAIL
  local name=$1
  shift
  echo
  echo "=== ${name}"
  if "$@"; then
    RESULTS+=("PASS  ${name}")
  else
    RESULTS+=("FAIL  ${name}")
    FAILED=1
    return 1
  fi
}

finish() {
  echo
  echo "=== ${TOOL} build summary"
  printf '  %s\n' "${RESULTS[@]}"
  if (( FAILED )); then
    echo "OVERALL: FAIL"
    exit 1
  fi
  echo "OVERALL: PASS"
  echo
  echo "Image: ${SIF}"
  echo "Next, run the GPU tests from a Setonix login node:"
  echo "  sbatch --account=<project>-gpu ${RECIPE_DIR}/tests/${TOOL}_tests.sh ${SIF}"
}

check_label() {
  local title
  title=$(singularity inspect --labels "${SIF}" | sed -n 's/^org\.opencontainers\.image\.title: *//p')
  echo "image title label: ${title:-<missing>}"
  [[ "${title}" == "${EXPECTED_TITLE}" ]]
}

if [[ -f /container/setup_podman.sh ]]; then
  # shellcheck disable=SC1091
  source /container/setup_podman.sh
fi
if ! command -v singularity >/dev/null 2>&1; then
  module load "${SINGULARITY_MODULE}" || { echo "ERROR: cannot load ${SINGULARITY_MODULE}" >&2; exit 1; }
fi
command -v podman >/dev/null 2>&1 || { echo "ERROR: podman not found; run this on a podman build node" >&2; exit 1; }
mkdir -p "${BUILD_DIR}"
echo "Building ${TOOL}:${TAG} from ${RECIPE_DIR}/Dockerfile into ${BUILD_DIR}"

step "podman build" bash -c "cd '${RECIPE_DIR}' && podman build --jobs=${PODMAN_JOBS} --format=docker -f Dockerfile -t '${TOOL}:${TAG}' ." || finish
step "podman save (OCI archive)" podman save --format oci-archive "localhost/${TOOL}:${TAG}" -o "${ARCHIVE}" || finish
step "singularity build" singularity build --force "${SIF}" "oci-archive://${ARCHIVE}" || finish
if [[ "${KEEP_OCI_ARCHIVE}" != 1 ]]; then
  rm -f "${ARCHIVE}"
fi
step "image title label is ${EXPECTED_TITLE}" check_label
for check in "${SMOKE_CHECKS[@]}"; do
  step "in image: ${check}" singularity exec "${SIF}" bash -c "${check}"
done
finish
