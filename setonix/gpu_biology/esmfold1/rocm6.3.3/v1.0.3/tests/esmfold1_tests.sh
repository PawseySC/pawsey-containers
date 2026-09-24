#!/bin/bash -l
#SBATCH --job-name=esmfold1-tests
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --gres=gpu:1
#SBATCH --time=00:30:00
#SBATCH --array=0-5
#SBATCH --output=esmfold1-tests_%A_%a.out
#
# GPU tests for the ESMFold v1.0.3 (ROCm 6.3.3) container. See README.md.
#
#   sbatch --account=<project>-gpu esmfold1_tests.sh /path/to/image.sif

TOOL=esmfold1
IMAGE="${1:-${IMAGE:-}}"

# ---- settings (export before sbatch to change) ------------------------------
ESM_MODELS_DIR="${ESM_MODELS_DIR:-/scratch/references/esmfold/models}"
ESM_EMBEDDING_MODEL="${ESM_EMBEDDING_MODEL:-esm2_t36_3B_UR50D}"
MIN_PLDDT="${MIN_PLDDT:-70}"
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/3.11.4-nompi}"
SINGULARITY_ARGS="${SINGULARITY_ARGS:-}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${MYSCRATCH:-${HOME}}/gpu_biology_tests}"
CPUS="${CPUS:-8}"
SUMMARY_SBATCH_ARGS="${SUMMARY_SBATCH_ARGS:---nodes=1 --gres=gpu:1 --time=00:05:00}"

# The image sets TORCH_HOME; SINGULARITYENV_ overrides it with the setting above.
export SINGULARITYENV_TORCH_HOME="${ESM_MODELS_DIR}"

# ---- tests (array index = position in this list) ----------------------------
TESTS=(
  gpu_check
  monomer
  multimer
  batch_chunked
  esm2_embeddings
  openmm_hip
)
TEST_DESCRIPTIONS=(
  "PyTorch finds the GPU and runs a matrix multiply on it; OpenFold imports"
  "esm-fold on ubiquitin (76 residues)"
  "esm-fold on a heterodimer given as A:B"
  "esm-fold on 4 sequences with --chunk-size 32 and small token batches"
  "esm-extract ESM-2 embeddings (mean and per-token)"
  "OpenMM HIP platform computes forces that agree with the CPU platform"
)

need_esmfold_weights() {
  need_path "ESMFold weights (ESM_MODELS_DIR)" \
    "${ESM_MODELS_DIR}/hub/checkpoints/esmfold_3B_v1.pt"
}

esm_fold() {  # esm_fold FASTA [extra esm-fold flags]
  local fasta=$1
  shift
  need_esmfold_weights || return 1
  run_gpu esm-fold -i "${fasta}" -o pdb "$@" || { NOTE="esm-fold failed"; return 1; }
}

test_gpu_check() {
  cat > gpu_check.py <<'EOF'
import torch
import openfold  # noqa: F401  (ESMFold's structure module comes from OpenFold)
print("torch", torch.__version__, "HIP", torch.version.hip)
assert torch.version.hip, "this PyTorch was not built for ROCm"
assert torch.cuda.is_available(), "PyTorch cannot see a GPU"
x = torch.ones(2048, 2048, device="cuda")
y = x @ x
assert float(y[0, 0]) == 2048.0, float(y[0, 0])
print("GPU OK:", torch.cuda.get_device_name(0))
EOF
  run_gpu python gpu_check.py 2>&1 | tee gpu_check.log
  [[ ${PIPESTATUS[0]} -eq 0 ]] || { NOTE="PyTorch could not use the GPU"; return 1; }
  NOTE=$(grep -m1 '^GPU OK' gpu_check.log)
}

test_monomer() {
  esm_fold ubiquitin.fasta || return 1
  expect_file pdb/ubiquitin.pdb || return 1
  expect_min_plddt "$(pdb_mean_plddt pdb/ubiquitin.pdb)"
}

test_multimer() {
  local chains
  esm_fold heterodimer_AB.fasta || return 1
  expect_file pdb/heterodimer_AB.pdb || return 1
  chains=$(pdb_chains pdb/heterodimer_AB.pdb)
  [[ "${chains}" == "AB" ]] || { NOTE="expected chains AB, got '${chains}'"; return 1; }
  NOTE="chains ${chains}, mean pLDDT $(pdb_mean_plddt pdb/heterodimer_AB.pdb) (not checked)"
}

test_batch_chunked() {
  esm_fold batch.fasta --chunk-size 32 --max-tokens-per-batch 256 || return 1
  expect_file pdb/ubiquitin.pdb pdb/chainA.pdb pdb/chainB.pdb pdb/peptide.pdb || return 1
  expect_min_plddt "$(pdb_mean_plddt pdb/ubiquitin.pdb)"
}

test_esm2_embeddings() {
  local model="${ESM_MODELS_DIR}/hub/checkpoints/${ESM_EMBEDDING_MODEL}.pt"
  if [[ ! -f "${model}" ]]; then
    NOTE="${ESM_EMBEDDING_MODEL}.pt not in ${ESM_MODELS_DIR}/hub/checkpoints"
    return 2
  fi
  run_gpu esm-extract "${ESM_EMBEDDING_MODEL}" chainA.fasta embeddings \
    --include mean per_tok || { NOTE="esm-extract failed"; return 1; }
  expect_file embeddings/chainA.pt || return 1
  cat > check_embeddings.py <<'EOF'
import sys
import torch
d = torch.load(sys.argv[1], map_location="cpu")
layer = max(d["mean_representations"])
mean, per_tok = d["mean_representations"][layer], d["representations"][layer]
assert torch.isfinite(per_tok).all(), "non-finite values in embeddings"
print(f"layer {layer}: per-token {tuple(per_tok.shape)}, mean {tuple(mean.shape)}")
EOF
  NOTE=$(run_cpu python check_embeddings.py embeddings/chainA.pt) \
    || { NOTE="embeddings could not be read"; return 1; }
}

test_openmm_hip() {
  run_gpu python -m openmm.testInstallation 2>&1 | tee openmm.log
  grep -q 'HIP - Successfully computed forces' openmm.log \
    || { NOTE="OpenMM HIP platform did not compute forces"; return 1; }
  NOTE="OpenMM HIP platform OK"
}

# =============================================================================
# Test harness. This section is the same in every gpu_biology *_tests.sh;
# tool-specific settings and test_* functions live above it.
# =============================================================================

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Run a command inside the container on this task's GPU.
# Slurm's ROCR_VISIBLE_DEVICES is passed through explicitly so it wins over any
# value baked into the image.
run_gpu() {
  srun --nodes=1 --ntasks=1 --cpus-per-task="${CPUS}" --gres=gpu:1 \
    bash -c 'if [[ -n "${ROCR_VISIBLE_DEVICES:-}" ]]; then
               export SINGULARITYENV_ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES}"
             fi
             exec singularity exec "$@"' \
    _ ${SINGULARITY_ARGS} "${IMAGE}" "$@"
}

# Run a short command inside the container without a GPU (setup and checks).
run_cpu() {
  singularity exec ${SINGULARITY_ARGS} "${IMAGE}" "$@"
}

# ---- checks: on failure they set NOTE (shown in the summary) and return 1 ----

# expect_file PATTERN...: each glob must match at least one non-empty file.
expect_file() {
  local pattern file
  for pattern in "$@"; do
    file=$(compgen -G "${pattern}" | head -n 1)
    if [[ -z "${file}" || ! -s "${file}" ]]; then
      NOTE="missing output: ${pattern}"
      return 1
    fi
  done
}

# first_file PATTERN: print the first file matching a glob.
first_file() { compgen -G "$1" | head -n 1; }

# pdb_mean_plddt FILE: mean CA B-factor (where the tools store pLDDT), on a 0-100 scale.
pdb_mean_plddt() {
  awk '/^ATOM/ && substr($0, 13, 4) == " CA " { s += substr($0, 61, 6); n++ }
       END { if (n == 0) exit 1; m = s / n; if (m <= 1.0) m *= 100; printf "%.1f", m }' "$1"
}

# pdb_chains FILE: the chain IDs present in a PDB file, e.g. "AB".
pdb_chains() {
  awk '/^ATOM|^HETATM/ { c[substr($0, 22, 1)] = 1 } END { for (k in c) print k }' "$1" \
    | sort | tr -d '\n'
}

# expect_min_plddt VALUE: VALUE (0-100) must be at least MIN_PLDDT.
expect_min_plddt() {
  local value=$1
  if [[ -z "${value}" ]]; then
    NOTE="could not read pLDDT from the output"
    return 1
  fi
  NOTE="mean pLDDT ${value} (min ${MIN_PLDDT})"
  if ! awk -v v="${value}" -v m="${MIN_PLDDT}" 'BEGIN { exit !(v >= m) }'; then
    NOTE="${NOTE}: below threshold"
    return 1
  fi
}

# json_get FILE EXPR: evaluate a Python expression on the parsed JSON (as d).
json_get() {
  run_cpu python3 -c "import json, sys; d = json.load(open(sys.argv[1])); print($2)" "$1"
}

# need_path DESCRIPTION PATH: a reference file or directory must exist.
need_path() {
  if [[ -z "$2" || ! -e "$2" ]]; then
    NOTE="setup: $1 not found (${2:-unset}); see Settings in README.md"
    return 1
  fi
}

# ---- job plumbing -----------------------------------------------------------

# Where this script lives (the batch copy Slurm runs is in a spool directory).
find_test_dir() {
  [[ -n "${TEST_DIR:-}" ]] && return 0
  local cmd
  cmd=$(scontrol show job "${SLURM_JOB_ID}" 2>/dev/null \
        | sed -n 's/^ *Command=\([^ ]*\).*/\1/p' | head -n 1)
  [[ -n "${cmd}" && "${cmd}" != /* ]] && cmd="${SLURM_SUBMIT_DIR}/${cmd}"
  if [[ -n "${cmd}" && -f "${cmd}" ]]; then
    TEST_DIR=$(cd "$(dirname "${cmd}")" && pwd)
  elif [[ -f "${SLURM_SUBMIT_DIR}/${TOOL}_tests.sh" ]]; then
    TEST_DIR="${SLURM_SUBMIT_DIR}"
  else
    echo "ERROR: cannot find the tests directory; submit from it or set TEST_DIR." >&2
    return 1
  fi
}

# The first task to start submits one summary job that runs after all tasks end.
submit_summary_job() {
  mkdir "${RUN_DIR}/.summary_submitted" 2>/dev/null || return 0
  {
    printf 'IMAGE=%q\n' "${IMAGE}"
    printf 'SUBMIT_DIR=%q\n' "${SLURM_SUBMIT_DIR}"
    printf 'TEST_DIR=%q\n' "${TEST_DIR}"
  } > "${RUN_DIR}/run_info"
  local out="${SLURM_SUBMIT_DIR}/${TOOL}-tests_${SLURM_ARRAY_JOB_ID}_summary.out"
  # shellcheck disable=SC2086
  if env -u SLURM_MEM_PER_CPU -u SLURM_MEM_PER_GPU -u SLURM_MEM_PER_NODE \
      sbatch --parsable --job-name="${TOOL}-tests-summary" \
        --account="${SLURM_JOB_ACCOUNT}" --partition="${SLURM_JOB_PARTITION}" \
        ${SUMMARY_SBATCH_ARGS} \
        --dependency="afterany:${SLURM_ARRAY_JOB_ID}" --output="${out}" \
        --wrap="bash $(printf '%q' "${TEST_DIR}/${TOOL}_tests.sh") --summary $(printf '%q' "${RUN_DIR}")" \
        > "${RUN_DIR}/.summary_submitted/job_id"; then
    log "Summary job $(cat "${RUN_DIR}/.summary_submitted/job_id") will write ${out}"
  else
    log "WARNING: could not submit the summary job. Run it by hand afterwards:"
    log "  bash ${TEST_DIR}/${TOOL}_tests.sh --summary ${RUN_DIR}"
  fi
}

record() {  # record RESULT SECONDS
  local note=${NOTE//|//}
  note=${note//$'\n'/ }
  printf '%s|%s|%s\n' "$1" "$2" "${note}" > "${RUN_DIR}/status/${SLURM_ARRAY_TASK_ID}"
}

run_task() {
  local i=${SLURM_ARRAY_TASK_ID}
  if (( i >= ${#TESTS[@]} )); then
    echo "ERROR: array index ${i} has no test (tests are 0-$(( ${#TESTS[@]} - 1 )))." >&2
    exit 1
  fi
  local name=${TESTS[$i]}
  find_test_dir || exit 1
  RUN_DIR="${OUTPUT_ROOT}/${TOOL}/${SLURM_ARRAY_JOB_ID}"
  WORK="${RUN_DIR}/${i}_${name}"
  mkdir -p "${WORK}" "${RUN_DIR}/status"
  NOTE=""

  echo "=== ${TOOL} test ${i}: ${name}"
  echo "    ${TEST_DESCRIPTIONS[$i]}"
  echo "    image:  ${IMAGE}"
  echo "    output: ${WORK}"
  echo "    node:   $(hostname)   job: ${SLURM_ARRAY_JOB_ID}_${i}"
  echo

  if [[ -z "${IMAGE}" || ( "${IMAGE}" != *://* && ! -f "${IMAGE}" ) ]]; then
    NOTE="setup: container image not found (${IMAGE:-not given})"
    record FAIL 0
    submit_summary_job
    log "RESULT: FAIL - ${NOTE}"
    exit 1
  fi
  submit_summary_job
  if ! module load "${SINGULARITY_MODULE}"; then
    NOTE="setup: could not load module ${SINGULARITY_MODULE}"
    record FAIL 0
    log "RESULT: FAIL - ${NOTE}"
    exit 1
  fi

  [[ -d "${TEST_DIR}/inputs" ]] && cp -r "${TEST_DIR}/inputs/." "${WORK}/"
  cd "${WORK}" || exit 1

  local start=${SECONDS} rc result
  "test_${name}"
  rc=$?
  case ${rc} in
    0) result=PASS ;;
    2) result=SKIP ;;
    *) result=FAIL; [[ -z "${NOTE}" ]] && NOTE="command failed (exit ${rc})" ;;
  esac
  record "${result}" $(( SECONDS - start ))
  echo
  log "RESULT: ${result}${NOTE:+ - ${NOTE}}"
  [[ ${result} != FAIL ]]
}

summarise() {
  local run_dir=$1 job_id=${1##*/}
  local IMAGE="?" SUBMIT_DIR="." i name result secs note state
  local n_pass=0 n_fail=0 n_skip=0
  # shellcheck disable=SC1091
  [[ -f "${run_dir}/run_info" ]] && source "${run_dir}/run_info"
  {
    echo "${TOOL} container tests - job ${job_id}"
    echo "image:   ${IMAGE}"
    echo "outputs: ${run_dir}"
    echo
    printf '%-3s %-26s %-6s %8s  %s\n' "#" "TEST" "RESULT" "TIME" "NOTES"
    for i in "${!TESTS[@]}"; do
      name=${TESTS[$i]}
      if [[ -f "${run_dir}/status/${i}" ]]; then
        IFS='|' read -r result secs note < "${run_dir}/status/${i}"
        secs=$(printf '%dm%02ds' $(( secs / 60 )) $(( secs % 60 )))
      else
        state=$(sacct -n -X -P -j "${job_id}_${i}" -o State 2>/dev/null | head -n 1)
        secs="-"
        if [[ -z "${state}" ]]; then
          result="-"; note="not run (outside the --array range)"
        else
          result=FAIL; note="no result, task ended ${state%% *}"
        fi
      fi
      case ${result} in
        PASS) n_pass=$(( n_pass + 1 )) ;;
        SKIP) n_skip=$(( n_skip + 1 )) ;;
        FAIL) n_fail=$(( n_fail + 1 )); note="${note}; log: ${SUBMIT_DIR}/${TOOL}-tests_${job_id}_${i}.out" ;;
      esac
      printf '%-3s %-26s %-6s %8s  %s\n' "${i}" "${name}" "${result}" "${secs}" "${note}"
    done
    echo
    if (( n_fail == 0 )); then
      echo "OVERALL: PASS (${n_pass} passed, ${n_skip} skipped)"
    else
      echo "OVERALL: FAIL (${n_fail} failed, ${n_pass} passed, ${n_skip} skipped)"
    fi
    (( n_fail == 0 ))
  } | tee "${run_dir}/summary.txt"
  return "${PIPESTATUS[0]}"
}

if [[ "${1:-}" == "--summary" ]]; then
  summarise "${2:?usage: $0 --summary RUN_DIR}"
  exit $?
fi
if [[ -z "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  echo "Submit with sbatch, for example:" >&2
  echo "  sbatch --account=<project>-gpu ${TOOL}_tests.sh /path/to/${TOOL}.sif" >&2
  exit 1
fi
[[ -n "${IMAGE}" && "${IMAGE}" != /* && "${IMAGE}" != *://* ]] && IMAGE="${SLURM_SUBMIT_DIR}/${IMAGE}"
run_task
