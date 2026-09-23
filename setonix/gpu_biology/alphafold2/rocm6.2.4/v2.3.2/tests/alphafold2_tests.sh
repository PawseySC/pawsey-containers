#!/bin/bash -l
#SBATCH --job-name=alphafold2-tests
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --gres=gpu:1
#SBATCH --time=00:45:00
#SBATCH --array=0-4
#SBATCH --output=alphafold2-tests_%A_%a.out
#
# GPU tests for the AlphaFold2 v2.3.2 (ROCm 6.2.4) container. See README.md.
#
#   sbatch --account=<project>-gpu alphafold2_tests.sh /path/to/image.sif
#
# Tests 0-4 only need the model parameters. Tests 5-6 also search the reference
# databases, take a few hours and are opt-in:
#   sbatch --account=<project>-gpu --array=0-6 --time=04:00:00 alphafold2_tests.sh IMAGE

TOOL=alphafold2
IMAGE="${1:-${IMAGE:-}}"

# ---- settings (export before sbatch to change) ------------------------------
AF2_DATA_DIR="${AF2_DATA_DIR:-/scratch/references/alphafold_feb2024/databases}"
MIN_PLDDT="${MIN_PLDDT:-70}"
RELAX_ON_GPU="${RELAX_ON_GPU:-True}"
MAX_TEMPLATE_DATE="${MAX_TEMPLATE_DATE:-2023-05-14}"
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/3.11.4-nompi}"
SINGULARITY_ARGS="${SINGULARITY_ARGS:-}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${MYSCRATCH:-${HOME}}/gpu_biology_tests}"
CPUS="${CPUS:-8}"
SUMMARY_SBATCH_ARGS="${SUMMARY_SBATCH_ARGS:---nodes=1 --gres=gpu:1 --time=00:05:00}"

# ---- tests (array index = position in this list) ----------------------------
TESTS=(
  gpu_check
  monomer
  monomer_ptm
  multimer
  amber_relax
  msa_pipeline
  full_pipeline
)
TEST_DESCRIPTIONS=(
  "JAX finds the GPU and runs a matrix multiply on it"
  "run_predict.py, monomer preset (5 models), precomputed MSA"
  "run_predict.py, monomer_ptm preset with --benchmark, precomputed MSA"
  "run_predict.py, multimer preset (5 models), heterodimer with paired MSA"
  "Amber relaxation of a test structure with OpenMM (RELAX_ON_GPU)"
  "run_msa.py database search (reduced_dbs) -> features.pkl [database test]"
  "run_alphafold.py end to end (reduced_dbs, relax best model) [database test]"
)

predict() {  # predict PRESET FEATURES FASTA [extra run_predict.py flags]
  local preset=$1 features=$2 fasta=$3
  shift 3
  run_gpu python3 /app/alphafold/run_predict.py \
    --fasta_paths="${fasta}" --msa_path="${features}" --output_dir=out \
    --data_dir="${AF2_DATA_DIR}" --model_preset="${preset}" \
    --random_seed=0 --run_relax=False "$@"
}

make_features() {  # make_features ARGS...: build features.pkl from the a3m inputs
  run_cpu env PYTHONPATH=/app/alphafold python3 make_features.py "$@" \
    || { NOTE="make_features.py failed"; return 1; }
}

database_flags() {
  DB_FLAGS=(
    --data_dir="${AF2_DATA_DIR}"
    --db_preset=reduced_dbs
    --uniref90_database_path="${AF2_DATA_DIR}/uniref90/uniref90.fasta"
    --mgnify_database_path="${AF2_DATA_DIR}/mgnify/mgy_clusters_2022_05.fa"
    --small_bfd_database_path="${AF2_DATA_DIR}/small_bfd/bfd-first_non_consensus_sequences.fasta"
    --pdb70_database_path="${AF2_DATA_DIR}/pdb70/pdb70"
    --template_mmcif_dir="${AF2_DATA_DIR}/pdb_mmcif/mmcif_files"
    --obsolete_pdbs_path="${AF2_DATA_DIR}/pdb_mmcif/obsolete.dat"
    --max_template_date="${MAX_TEMPLATE_DATE}"
  )
}

test_gpu_check() {
  cat > gpu_check.py <<'EOF'
import jax
import jax.numpy as jnp
devices = jax.devices()
print("jax", jax.__version__, "devices:", devices)
assert devices[0].platform in ("gpu", "rocm"), f"JAX is not using a GPU: {devices}"
x = jnp.ones((2048, 2048), dtype=jnp.float32)
y = (x @ x).block_until_ready()
assert float(y[0, 0]) == 2048.0, float(y[0, 0])
print("GPU OK:", devices[0].device_kind)
EOF
  run_gpu python3 gpu_check.py 2>&1 | tee gpu_check.log
  [[ ${PIPESTATUS[0]} -eq 0 ]] || { NOTE="JAX could not use the GPU"; return 1; }
  NOTE=$(grep -m1 '^GPU OK' gpu_check.log)
}

test_monomer() {
  need_path "AlphaFold2 parameters" "${AF2_DATA_DIR}/params" || return 1
  make_features --out features.pkl --a3m chainA.a3m || return 1
  predict monomer features.pkl chainA.fasta || { NOTE="run_predict.py failed"; return 1; }
  expect_file out/chainA/ranked_0.pdb out/chainA/ranking_debug.json || return 1
  expect_min_plddt "$(pdb_mean_plddt out/chainA/ranked_0.pdb)"
}

test_monomer_ptm() {
  need_path "AlphaFold2 parameters" "${AF2_DATA_DIR}/params" || return 1
  make_features --out features.pkl --a3m chainA.a3m || return 1
  predict monomer_ptm features.pkl chainA.fasta --benchmark=True \
    || { NOTE="run_predict.py failed"; return 1; }
  expect_file out/chainA/ranked_0.pdb out/chainA/timings.json || return 1
  grep -q predict_benchmark out/chainA/timings.json \
    || { NOTE="no benchmark timings in timings.json"; return 1; }
  expect_min_plddt "$(pdb_mean_plddt out/chainA/ranked_0.pdb)"
}

test_multimer() {
  local out=out/heterodimer_AB chains
  need_path "AlphaFold2 parameters" "${AF2_DATA_DIR}/params" || return 1
  make_features --out features.pkl --multimer \
    --a3m chainA.a3m --paired-a3m chainA_paired.a3m \
    --a3m chainB.a3m --paired-a3m chainB_paired.a3m || return 1
  predict multimer features.pkl heterodimer_AB.fasta \
    --num_multimer_predictions_per_model=1 || { NOTE="run_predict.py failed"; return 1; }
  expect_file "${out}/ranked_0.pdb" "${out}/ranking_debug.json" || return 1
  chains=$(pdb_chains "${out}/ranked_0.pdb")
  [[ "${chains}" == "AB" ]] || { NOTE="expected chains AB, got '${chains}'"; return 1; }
  grep -q 'iptm+ptm' "${out}/ranking_debug.json" \
    || { NOTE="ranking_debug.json has no iptm+ptm scores"; return 1; }
  expect_min_plddt "$(pdb_mean_plddt "${out}/ranked_0.pdb")"
}

test_amber_relax() {
  cat > relax_check.py <<'EOF'
import sys
import openmm
from alphafold.common import protein
from alphafold.relax import relax

use_gpu = sys.argv[1].lower() == "true"
platforms = [openmm.Platform.getPlatform(i).getName()
             for i in range(openmm.Platform.getNumPlatforms())]
print("OpenMM", openmm.__version__, "platforms:", platforms, "use_gpu:", use_gpu)
with open("/app/alphafold/alphafold/relax/testdata/model_output.pdb") as f:
    prot = protein.from_pdb_string(f.read())
# Same settings as run_alphafold.py / run_predict.py.
relaxer = relax.AmberRelaxation(max_iterations=0, tolerance=2.39, stiffness=10.0,
                                exclude_residues=[], max_outer_iterations=3,
                                use_gpu=use_gpu)
pdb, debug, violations = relaxer.process(prot=prot)
with open("relaxed.pdb", "w") as f:
    f.write(pdb)
print("energy", debug["initial_energy"], "->", debug["final_energy"])
assert debug["final_energy"] < debug["initial_energy"], "energy did not decrease"
EOF
  run_gpu env PYTHONPATH=/app/alphafold python3 relax_check.py "${RELAX_ON_GPU}" \
    || { NOTE="Amber relax failed (RELAX_ON_GPU=${RELAX_ON_GPU})"; return 1; }
  expect_file relaxed.pdb || return 1
  NOTE="relaxed with RELAX_ON_GPU=${RELAX_ON_GPU}"
}

test_msa_pipeline() {
  need_path "AlphaFold2 databases" "${AF2_DATA_DIR}/uniref90/uniref90.fasta" || return 1
  database_flags
  run_gpu python3 /app/alphafold/run_msa.py --fasta_paths=chainA.fasta \
    --output_dir=out --model_preset=monomer "${DB_FLAGS[@]}" \
    || { NOTE="run_msa.py failed"; return 1; }
  expect_file out/chainA/features.pkl out/chainA/msas/uniref90_hits.sto
}

test_full_pipeline() {
  need_path "AlphaFold2 databases" "${AF2_DATA_DIR}/uniref90/uniref90.fasta" || return 1
  database_flags
  run_gpu python3 /app/alphafold/run_alphafold.py --fasta_paths=chainA.fasta \
    --output_dir=out --model_preset=monomer "${DB_FLAGS[@]}" \
    --use_gpu_relax="${RELAX_ON_GPU}" --models_to_relax=best --random_seed=0 \
    || { NOTE="run_alphafold.py failed"; return 1; }
  expect_file out/chainA/ranked_0.pdb out/chainA/relaxed_*.pdb || return 1
  expect_min_plddt "$(pdb_mean_plddt out/chainA/ranked_0.pdb)"
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
