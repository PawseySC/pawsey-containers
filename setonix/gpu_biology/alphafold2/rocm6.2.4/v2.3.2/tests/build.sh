#!/bin/bash -l
#
# Build the AlphaFold2 v2.3.2 (ROCm 6.2.4) container with podman, convert it to
# a Singularity image and run quick checks inside it (no GPU needed).
# Run on a Pawsey podman build node, from anywhere:
#
#   ./build.sh
#
# See README.md in this directory.
source /container/setup_podman.sh 

TOOL=alphafold2
TAG=v2.3.2-rocm6.2.4
EXPECTED_TITLE=alphafold2_v2.3.2_rocm6.2.4_ubuntu24.04

# Commands run inside the new image; each must succeed.
SMOKE_CHECKS=(
  "cd /app/alphafold && python3 -c 'import alphafold.model.model, jax, haiku, openmm, pdbfixer'"
  "python3 /app/alphafold/run_predict.py --helpshort | grep -q msa_path"
  "python3 /app/alphafold/run_msa.py --helpshort | grep -q fasta_paths"
  "python3 /app/alphafold/run_alphafold.py --helpshort | grep -q fasta_paths"
  "command -v jackhmmer hhblits hhsearch hmmsearch hmmbuild kalign"
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
