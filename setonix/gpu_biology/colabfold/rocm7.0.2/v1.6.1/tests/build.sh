#!/bin/bash -l
#
# Build the ColabFold v1.6.1 (ROCm 7.0.2) container with podman, convert it to
# a Singularity image and run quick checks inside it (no GPU needed).
# Run on a Pawsey podman build node, from anywhere:
#
#   ./build.sh
#
# See README.md in this directory.
source /container/setup_podman.sh 
TOOL=colabfold
TAG=v1.6.1-rocm7.0.2
EXPECTED_TITLE=colabfold_v1.6.1_rocm7.0.2_ubuntu24.04

# Commands run inside the new image; each must succeed.
SMOKE_CHECKS=(
  "python3 -c 'import colabfold, jax, openmm, alphafold'"
  "colabfold_batch --help | grep -q msa-mode"
  "colabfold_search --help | grep -q db1"
  "grep -q HIP /opt/miniforge3/lib/python3.12/site-packages/alphafold/relax/amber_minimize.py"
  "command -v mmseqs hhblits kalign"
)

# ---- settings (export before running to change) -----------------------------
BUILD_DIR="${BUILD_DIR:-/container/${USER}/pawsey-containers/setonix/gpu_biology/gpu_biology_builds}"
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
