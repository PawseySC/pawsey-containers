#!/bin/bash -l
#SBATCH --job-name=rfdiffusion-tests
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --gres=gpu:1
#SBATCH --time=00:30:00
#SBATCH --array=0-9
#SBATCH --output=rfdiffusion-tests_%A_%a.out
#
# GPU tests for the RFdiffusion v1.1.0 (ROCm 7.0.0, DGL 2.4.0) container.
# See README.md.
#
#   sbatch --account=<project>-gpu rfdiffusion_tests.sh /path/to/image.sif

TOOL=rfdiffusion
IMAGE="${1:-${IMAGE:-}}"

# ---- settings (export before sbatch to change) ------------------------------
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/3.11.4-nompi}"
SINGULARITY_ARGS="${SINGULARITY_ARGS:-}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${MYSCRATCH:-${HOME}}/gpu_biology_tests}"
CPUS="${CPUS:-8}"
SUMMARY_SBATCH_ARGS="${SUMMARY_SBATCH_ARGS:---nodes=1 --gres=gpu:1 --time=00:05:00}"

# Example inputs shipped in the image.
EX=/app/RFdiffusion/examples

# ---- tests (array index = position in this list) ----------------------------
TESTS=(
  gpu_check
  unconditional
  motif_scaffolding
  motif_inpaint_seq
  partial_diffusion
  binder_design
  fold_conditioned_binder
  symmetric_oligomer
  enzyme_active_site
  cyclic_peptide_binder
)
TEST_DESCRIPTIONS=(
  "PyTorch and DGL use the GPU; SE(3)-Transformer and RFdiffusion import"
  "unconditional 60-residue monomer (Base model)"
  "scaffold the 5TPN motif A163-181 (Base model)"
  "motif scaffolding with the motif sequence partly masked (InpaintSeq model)"
  "partial diffusion of 2KL8, partial_T=10"
  "40-residue binder to the insulin receptor with hotspots (Complex model)"
  "binder built on fold-conditioning scaffolds (Complex_Fold model)"
  "C3 symmetric oligomer, 3 x 30 residues, with oligomer contact potentials"
  "enzyme active-site scaffolding with a substrate potential (ActiveSite model)"
  "cyclic peptide binder to GABARAP (inference.cyclic)"
)

# design NAME [--config-name=...] OVERRIDES...: one design with run_inference.py.
design() {
  local name=$1 config=()
  shift
  if [[ "${1:-}" == --config-name=* ]]; then
    config=("$1")
    shift
  fi
  run_gpu run_inference.py "${config[@]}" inference.output_prefix="out/${name}" \
    inference.num_designs=1 "$@" || { NOTE="run_inference.py failed"; return 1; }
  expect_file "out/${name}_0.pdb" "out/${name}_0.trb" || return 1
  NOTE="design out/${name}_0.pdb: $(ca_count "out/${name}_0.pdb") residues, chains $(pdb_chains "out/${name}_0.pdb")"
}

ca_count() { awk '/^ATOM/ && substr($0, 13, 4) == " CA "' "$1" | wc -l | tr -d ' '; }

# expect_design NAME RESIDUES CHAINS: the design has this many residues and chains.
expect_design() {
  local n chains
  n=$(ca_count "out/$1_0.pdb")
  chains=$(pdb_chains "out/$1_0.pdb")
  if [[ "${n}" != "$2" || "${chains}" != "$3" ]]; then
    NOTE="expected $2 residues in chains $3, got ${n} in '${chains}'"
    return 1
  fi
}

test_gpu_check() {
  cat > gpu_check.py <<'EOF'
import dgl
import torch
import se3_transformer  # noqa: F401
import rfdiffusion  # noqa: F401
print("torch", torch.__version__, "HIP", torch.version.hip, "dgl", dgl.__version__)
assert torch.version.hip, "this PyTorch was not built for ROCm"
assert torch.cuda.is_available(), "PyTorch cannot see a GPU"
x = torch.ones(2048, 2048, device="cuda")
assert float((x @ x)[0, 0]) == 2048.0
g = dgl.graph(([0, 1, 2], [1, 2, 0])).to("cuda")
g.ndata["h"] = torch.ones(3, 4, device="cuda")
g.update_all(dgl.function.copy_u("h", "m"), dgl.function.sum("m", "h"))
assert g.ndata["h"].device.type == "cuda"
print("GPU OK:", torch.cuda.get_device_name(0))
EOF
  run_gpu python gpu_check.py 2>&1 | tee gpu_check.log
  [[ ${PIPESTATUS[0]} -eq 0 ]] || { NOTE="PyTorch/DGL could not use the GPU"; return 1; }
  NOTE=$(grep -m1 '^GPU OK' gpu_check.log)
}

test_unconditional() {
  design unconditional 'contigmap.contigs=[60-60]' || return 1
  expect_design unconditional 60 A
}

test_motif_scaffolding() {
  design motif_scaffolding inference.input_pdb="${EX}/input_pdbs/5TPN.pdb" \
    'contigmap.contigs=[10-20/A163-181/10-20]'
}

test_motif_inpaint_seq() {
  design motif_inpaint_seq inference.input_pdb="${EX}/input_pdbs/5TPN.pdb" \
    'contigmap.contigs=[10-20/A163-181/10-20]' \
    'contigmap.inpaint_seq=[A163-168/A170-171/A179]'
}

test_partial_diffusion() {
  design partial_diffusion inference.input_pdb="${EX}/input_pdbs/2KL8.pdb" \
    'contigmap.contigs=[79-79]' diffuser.partial_T=10 || return 1
  expect_design partial_diffusion 79 A
}

test_binder_design() {
  design binder_design inference.input_pdb="${EX}/input_pdbs/insulin_target.pdb" \
    'contigmap.contigs=[A1-150/0 40-40]' 'ppi.hotspot_res=[A59,A83,A91]' \
    denoiser.noise_scale_ca=0 denoiser.noise_scale_frame=0 || return 1
  expect_design binder_design 190 AB
}

test_fold_conditioned_binder() {
  design fold_conditioned_binder scaffoldguided.scaffoldguided=True \
    scaffoldguided.target_path="${EX}/input_pdbs/insulin_target.pdb" \
    scaffoldguided.target_pdb=True \
    scaffoldguided.target_ss="${EX}/target_folds/insulin_target_ss.pt" \
    scaffoldguided.target_adj="${EX}/target_folds/insulin_target_adj.pt" \
    scaffoldguided.scaffold_dir="${EX}/ppi_scaffolds/" \
    'ppi.hotspot_res=[A59,A83,A91]' \
    denoiser.noise_scale_ca=0 denoiser.noise_scale_frame=0 || return 1
  [[ $(pdb_chains out/fold_conditioned_binder_0.pdb) == AB ]] \
    || { NOTE="expected target and binder chains AB (${NOTE})"; return 1; }
}

test_symmetric_oligomer() {
  design symmetric_oligomer --config-name=symmetry inference.symmetry=C3 \
    'contigmap.contigs=[90-90]' \
    'potentials.guiding_potentials=["type:olig_contacts,weight_intra:1,weight_inter:0.1"]' \
    potentials.olig_intra_all=True potentials.olig_inter_all=True \
    potentials.guide_scale=2.0 potentials.guide_decay=quadratic || return 1
  expect_design symmetric_oligomer 90 ABC
}

test_enzyme_active_site() {
  design enzyme_active_site inference.input_pdb="${EX}/input_pdbs/5an7.pdb" \
    'contigmap.contigs=[10-20/A1083-1083/10-20/A1051-1051/10-20/A1180-1180/10-20]' \
    potentials.guide_scale=1 \
    'potentials.guiding_potentials=["type:substrate_contacts,s:1,r_0:8,rep_r_0:5.0,rep_s:2,rep_r_min:1"]' \
    potentials.substrate=LLK \
    inference.ckpt_override_path=/app/RFdiffusion/models/ActiveSite_ckpt.pt
}

test_cyclic_peptide_binder() {
  design cyclic_peptide_binder inference.input_pdb="${EX}/input_pdbs/7zkr_GABARAP.pdb" \
    'contigmap.contigs=[12-18 A3-117/0]' inference.cyclic=True inference.cyc_chains=a \
    'ppi.hotspot_res=[A51,A52,A50,A48,A62,A65]' || return 1
  [[ $(pdb_chains out/cyclic_peptide_binder_0.pdb) == AB ]] \
    || { NOTE="expected peptide and target chains AB (${NOTE})"; return 1; }
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
