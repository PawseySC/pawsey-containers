#!/bin/bash --login
# Experimental v2606/Singularity Bash tutorial generator. Generated jobs are
# self-contained; only their image, shared work directory and artifact directory
# are runtime inputs.
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CONFIG=""
RECIPE_DIR=""
IMAGE=""
WORK_ROOT=""
ARTIFACTS=""
PARTITION="${PARTITION:-work}"
RESERVATION="${RESERVATION:-}"
OVERWRITE=false
GENERATE_ONLY=false
SUBMIT_ONLY=false
PUBLISH=false
POLL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"

usage() {
    cat <<'USAGE'
Usage:
  openfoamTutorialTestLauncher.generating.sh --recipe-dir <v2606-dir> --image <image> [options]
  openfoamTutorialTestLauncher.generating.sh --config <*.generating.config> --image <image> [options]
  openfoamTutorialTestLauncher.generating.sh --finalize <artifacts-dir> [--publish-examples]

Options:
  --work-root <dir>            Shared case work root (default: isolated under MYSCRATCH/HOME)
  --artifacts-dir <dir>         Invocation artifacts (default: isolated under MYSCRATCH/HOME)
  --partition <name>            Slurm partition (default: work)
  --reservation <name>          Optional Slurm reservation
  --overwrite                   Replace only the existing periodicPlaneChannel case
  --generate-only               Generate, syntax-check and checksum; do not execute or submit
  --submit-only                 Submit and return with SUBMITTED status
  --publish-examples            After successful completed validation, atomically publish
                                the tested triplet under tutorialTest/singularity-generating
  --finalize <artifacts-dir>    Run the same saved external acceptance/finalization step
  --help

Generated scripts have resolved defaults, overridable with --image, --work-root
and --test-artifacts-dir. They do not read the recipe or shared libraries.
Image content is pinned by SHA-256.

Preparation commands come from TUTORIAL_PRE_STEPS, an ordered array of names.
Each name refers to a TUTORIAL_PRE_<name> argument array in the trusted Bash
config; no functions or shell command strings belong in the config.
Dictionary setup currently uses the scalar tutorial settings.

Extraction runs locally, then preparation and solver are submitted with afterok.
An independent afterany finalizer verifies Slurm completion, checksums, stage
statuses, mesh, final time and residual. Execution time above the threshold is
a warning. Failed candidates remain in artifacts. Publication is opt-in and
refuses existing example directories; it never commits or pushes.

This first prototype supports exactly OpenFOAM v2606, periodicPlaneChannel,
pimpleFoam and Singularity. SHPC, bare metal and other versions are not enabled.
USAGE
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"; }
FINALIZE=""
while (($#)); do
    case "$1" in
        --recipe-dir) need_value "$@"; RECIPE_DIR=$2; shift 2 ;;
        --config) need_value "$@"; CONFIG=$2; shift 2 ;;
        --image) need_value "$@"; IMAGE=$2; shift 2 ;;
        --work-root) need_value "$@"; WORK_ROOT=$2; shift 2 ;;
        --artifacts-dir|--test-artifacts-dir) need_value "$@"; ARTIFACTS=$2; shift 2 ;;
        --partition) need_value "$@"; PARTITION=$2; shift 2 ;;
        --reservation) need_value "$@"; RESERVATION=$2; shift 2 ;;
        --overwrite) OVERWRITE=true; shift ;;
        --generate-only) GENERATE_ONLY=true; shift ;;
        --submit-only) SUBMIT_ONLY=true; shift ;;
        --publish-examples) PUBLISH=true; shift ;;
        --finalize) need_value "$@"; FINALIZE=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done

if [[ -n "$FINALIZE" ]]; then
    [[ -d "$FINALIZE" ]] || fail "artifact directory not found: $FINALIZE"
    [[ -x "$FINALIZE/validate.generating.sh" ]] || fail "saved validator missing in $FINALIZE"
    if [[ "$PUBLISH" == true ]]; then
        "$FINALIZE/validate.generating.sh" --artifacts-dir "$FINALIZE" --publish
    else
        "$FINALIZE/validate.generating.sh" --artifacts-dir "$FINALIZE"
    fi
    exit $?
fi

[[ -z "$RECIPE_DIR" || -z "$CONFIG" ]] || fail "use either --recipe-dir or --config"
[[ -n "$RECIPE_DIR" || -n "$CONFIG" ]] || fail "provide --recipe-dir or --config"
if [[ -n "$RECIPE_DIR" ]]; then
    [[ -d "$RECIPE_DIR" ]] || fail "recipe directory not found: $RECIPE_DIR"
    RECIPE_DIR=$(cd -- "$RECIPE_DIR" && pwd -P)
    CONFIG="$RECIPE_DIR/buildAndValidationConfig/openfoamBuildAndValidation.generating.config"
fi
[[ "$CONFIG" == *.generating.config ]] || fail "only a .generating.config recipe is supported"
[[ -r "$CONFIG" ]] || fail "configuration not readable: $CONFIG"
# shellcheck disable=SC1090
source "$CONFIG"
[[ "${OPENFOAM_FORK:-}" == openfoam && "${OPENFOAM_VERSION:-}" == v2606 ]] ||
    fail "only OPENFOAM_FORK=openfoam and OPENFOAM_VERSION=v2606 are supported"
[[ -n "${TUTORIAL_CASE_NAME:-}" && -n "${TUTORIAL_CASE_SEARCH_NAME:-}" &&
   -n "${TUTORIAL_NPROCS:-}" && -n "${TUTORIAL_IO_GROUP_SIZE:-}" &&
   -n "${TUTORIAL_DECOMPOSITION:-}" && -n "${TUTORIAL_SOLVER:-}" &&
   -n "${TUTORIAL_END_TIME:-}" && -n "${TUTORIAL_WRITE_INTERVAL:-}" &&
   -n "${TUTORIAL_MAX_EXECUTION_TIME:-}" && -n "${TUTORIAL_MAX_UX_INITIAL_RESIDUAL:-}" &&
   -n "${TUTORIAL_PRE_NODES:-}" && -n "${TUTORIAL_PRE_TASKS:-}" &&
   -n "${TUTORIAL_PRE_CPUS_PER_TASK:-}" && -n "${TUTORIAL_PRE_MEMORY:-}" &&
   -n "${TUTORIAL_PRE_TIME:-}" && -n "${TUTORIAL_RUN_NODES:-}" &&
   -n "${TUTORIAL_RUN_TASKS:-}" && -n "${TUTORIAL_RUN_TASKS_PER_NODE:-}" &&
   -n "${TUTORIAL_RUN_CPUS_PER_TASK:-}" && -n "${TUTORIAL_RUN_TIME:-}" ]] ||
    fail "recipe is missing one or more required tutorial settings"
[[ "$TUTORIAL_CASE_NAME" == periodicPlaneChannel &&
   "$TUTORIAL_CASE_SEARCH_NAME" == periodicPlaneChannel &&
   "$TUTORIAL_SOLVER" == pimpleFoam ]] || fail "only the periodicPlaneChannel/pimpleFoam workflow is supported"
[[ "$TUTORIAL_NPROCS" =~ ^[1-9][0-9]*$ && "$TUTORIAL_IO_GROUP_SIZE" =~ ^[1-9][0-9]*$ ]] ||
    fail "processor and I/O group counts must be positive integers"
for setting in TUTORIAL_PRE_NODES TUTORIAL_PRE_TASKS TUTORIAL_PRE_CPUS_PER_TASK \
    TUTORIAL_RUN_NODES TUTORIAL_RUN_TASKS TUTORIAL_RUN_TASKS_PER_NODE TUTORIAL_RUN_CPUS_PER_TASK; do
    [[ "${!setting}" =~ ^[1-9][0-9]*$ ]] || fail "$setting must be a positive integer"
done
(( TUTORIAL_RUN_TASKS == TUTORIAL_NPROCS &&
   TUTORIAL_RUN_NODES * TUTORIAL_RUN_TASKS_PER_NODE == TUTORIAL_NPROCS )) ||
    fail "run resources must match decomposition and tasks per node"
[[ "$TUTORIAL_PRE_NODES" == 1 && "$TUTORIAL_PRE_TASKS" == 1 ]] ||
    fail "preparation requires one node and one task"
for setting in TUTORIAL_END_TIME TUTORIAL_WRITE_INTERVAL TUTORIAL_MAX_EXECUTION_TIME TUTORIAL_MAX_UX_INITIAL_RESIDUAL; do
    [[ "${!setting}" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "$setting must be a nonnegative decimal"
done
for setting in TUTORIAL_PRE_TIME TUTORIAL_RUN_TIME; do
    [[ "${!setting}" =~ ^[0-9]+:[0-5][0-9]:[0-5][0-9]$ ]] || fail "invalid time: $setting"
done
[[ "$TUTORIAL_PRE_MEMORY" =~ ^[1-9][0-9]*[GMK]B?$ ]] || fail "invalid preparation memory"
[[ "$TUTORIAL_DECOMPOSITION" =~ ^\(([1-9][0-9]*)[[:space:]]+([1-9][0-9]*)[[:space:]]+([1-9][0-9]*)\)$ ]] ||
    fail "invalid decomposition vector"
(( BASH_REMATCH[1] * BASH_REMATCH[2] * BASH_REMATCH[3] == TUTORIAL_NPROCS )) ||
    fail "decomposition product must match processor count"
[[ "${TUTORIAL_EXTRACT_STEPS[*]}" == "locate_unique copy validate" &&
   "${TUTORIAL_RUN_STEPS[*]}" == parallel_pimpleFoam ]] ||
    fail "unsupported extraction or solver workflow in this prototype"
declare -p TUTORIAL_PRE_STEPS 2>/dev/null | grep -q '^declare -a ' ||
    fail "TUTORIAL_PRE_STEPS must be an ordered array"
((${#TUTORIAL_PRE_STEPS[@]})) || fail "preparation steps cannot be empty"
for step in "${TUTORIAL_PRE_STEPS[@]}"; do
    [[ "$step" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] || fail "invalid preparation step name"
    declare -p "TUTORIAL_PRE_$step" 2>/dev/null | grep -q '^declare -a ' ||
        fail "preparation step $step must be an argument array"
done
[[ "$GENERATE_ONLY" == false || "$SUBMIT_ONLY" == false ]] ||
    fail "--generate-only and --submit-only cannot be combined"
[[ "$GENERATE_ONLY" == false || "$PUBLISH" == false ]] ||
    fail "--publish-examples requires a completed validation, not --generate-only"
[[ -n "$IMAGE" && -f "$IMAGE" ]] || fail "--image must name an existing Singularity image"
command -v sha256sum >/dev/null || fail "sha256sum is required"
command -v bash >/dev/null || fail "bash is required"
if [[ "$GENERATE_ONLY" == false ]]; then
    command -v module >/dev/null || fail "module command is unavailable"
    command -v sbatch >/dev/null || fail "sbatch is unavailable"
    command -v sacct >/dev/null || fail "sacct is required for final acceptance"
    if [[ "$SUBMIT_ONLY" == false ]]; then
        command -v squeue >/dev/null || fail "squeue is required in wait mode"
    fi
fi

IMAGE=$(cd -- "$(dirname -- "$IMAGE")" && printf '%s/%s\n' "$PWD" "$(basename -- "$IMAGE")")
CONFIG=$(cd -- "$(dirname -- "$CONFIG")" && printf '%s/%s\n' "$PWD" "$(basename -- "$CONFIG")")
for value in "$CONFIG" "$IMAGE"; do
    [[ "$value" != *$'\n'* ]] || fail "newlines are not supported in image/config paths"
done
CONFIG_PARENT=$(cd -- "$(dirname -- "$CONFIG")" && pwd -P)
if [[ "${CONFIG_PARENT##*/}" == buildAndValidationConfig ]]; then
    PUBLISH_RECIPE_DIR=$(dirname -- "$CONFIG_PARENT")
else
    PUBLISH_RECIPE_DIR=$CONFIG_PARENT
    [[ "$PUBLISH" == false ]] || fail "publication requires a config under buildAndValidationConfig"
fi
[[ "$PUBLISH_RECIPE_DIR" != *$'\n'* ]] || fail "newlines are not supported in recipe paths"
BASE=${MYSCRATCH:-${HOME:?HOME is required}}
STAMP="$(date '+%Y%m%dT%H%M%S%z')-$$"
if [[ -z "$WORK_ROOT" ]]; then WORK_ROOT="$BASE/openfoam-tutorial.generating/$STAMP.generating/work.generating"; fi
if [[ -z "$ARTIFACTS" ]]; then ARTIFACTS="$BASE/openfoam-tutorial.generating/$STAMP.generating/tests/tutorial-generating.generating"; fi
mkdir -p -- "$WORK_ROOT" "$ARTIFACTS"
WORK_ROOT=$(cd -- "$WORK_ROOT" && pwd -P)
ARTIFACTS=$(cd -- "$ARTIFACTS" && pwd -P)
for value in "$WORK_ROOT" "$ARTIFACTS"; do
    [[ "$value" != *$'\n'* ]] || fail "newlines are not supported in work/artifact paths"
done
CASE_DIR="$WORK_ROOT/run/$TUTORIAL_CASE_NAME"
IMAGE_Q=$(printf '%q' "$IMAGE")
WORK_Q=$(printf '%q' "$WORK_ROOT")
ART_Q=$(printf '%q' "$ARTIFACTS")
VERSION_Q=$(printf '%q' "$OPENFOAM_VERSION")
CASE_Q_NAME=$(printf '%q' "$TUTORIAL_CASE_NAME")
SEARCH_Q_NAME=$(printf '%q' "$TUTORIAL_CASE_SEARCH_NAME")
SOLVER_Q=$(printf '%q' "$TUTORIAL_SOLVER")
NPROCS_Q=$(printf '%q' "$TUTORIAL_NPROCS")
IO_GROUP_Q=$(printf '%q' "$TUTORIAL_IO_GROUP_SIZE")
of_ioRanks=0
for ((rank=TUTORIAL_IO_GROUP_SIZE; rank<TUTORIAL_NPROCS; rank+=TUTORIAL_IO_GROUP_SIZE)); do
    of_ioRanks+=" $rank"
done
IO_RANKS_Q=$(printf '%q' "($of_ioRanks)")
END_TIME_Q=$(printf '%q' "$TUTORIAL_END_TIME")
WRITE_INTERVAL_Q=$(printf '%q' "$TUTORIAL_WRITE_INTERVAL")
DECOMPOSITION_Q=$(printf '%q' "$TUTORIAL_DECOMPOSITION")
IMAGE_HASH=$(sha256sum -- "$IMAGE" | awk '{print $1}')
CONFIG_HASH=$(sha256sum -- "$CONFIG" | awk '{print $1}')
IMAGE_HASH_Q=$(printf '%q' "$IMAGE_HASH")

shopt -s nullglob dotglob
existing_artifacts=("$ARTIFACTS"/*)
shopt -u nullglob dotglob
(( ${#existing_artifacts[@]} == 0 )) || fail "artifact directory must be empty: $ARTIFACTS"

cat > "$ARTIFACTS/extractCase.generating.sh" <<SCRIPT
#!/bin/bash --login
set -Eeuo pipefail
image=$IMAGE_Q
work_root=$WORK_Q
artifacts=$ART_Q
version=$VERSION_Q
case_name=$CASE_Q_NAME
search_name=$SEARCH_Q_NAME
nprocs=$NPROCS_Q
expected_image_sha256=$IMAGE_HASH_Q
SCRIPT
cat >> "$ARTIFACTS/extractCase.generating.sh" <<'SCRIPT'
while (($#)); do
    if [[ "$1" == --image || "$1" == --work-root || "$1" == --test-artifacts-dir ]]; then
        [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
    fi
    case "$1" in
        --image) image=$2; shift 2 ;;
        --work-root) work_root=$2; shift 2 ;;
        --test-artifacts-dir) artifacts=$2; shift 2 ;;
        --overwrite) OVERWRITE_CASE=true; shift ;;
        *) echo "ERROR: unknown extract option: $1" >&2; exit 2 ;;
    esac
done
[[ -f "$image" ]] || { echo "ERROR: Singularity image not found: $image" >&2; exit 2; }
[[ "$(sha256sum -- "$image" | awk '{print $1}')" == "$expected_image_sha256" ]] ||
    { echo "ERROR: image digest differs from generated candidate" >&2; exit 1; }
mkdir -p -- "$work_root/run" "$artifacts"
status="$artifacts/extract.status.generating"
trap 'rc=$?; printf "%s\n" "$rc" > "$status"' EXIT
log="$artifacts/extract.generating.log"
exec > >(tee -a "$log") 2>&1
case_dir="$work_root/run/$case_name"
if [[ -e "$case_dir" || -L "$case_dir" ]]; then
    [[ "${OVERWRITE_CASE:-false}" == true ]] || { echo "ERROR: case exists; use --overwrite"; exit 1; }
    rm -rf -- "$case_dir"
fi
module load "${SINGULARITY_MODULE:-singularity/4.3.5-mpi}"
command -v singularity >/dev/null || { echo "ERROR: singularity is unavailable" >&2; exit 1; }
runtime_version=$(singularity exec "$image" bash -c 'printf "%s" "$WM_PROJECT_VERSION"')
[[ "$runtime_version" == "$version" ]] || { echo "ERROR: image runtime version '$runtime_version' does not match '$version'"; exit 1; }
found=$(singularity exec "$image" bash -c 'find "$FOAM_TUTORIALS" -type d -name "$1" -print' bash "$search_name")
mapfile -t matches <<< "$found"
[[ ${#matches[@]} -eq 1 && -n "${matches[0]}" ]] || { echo "ERROR: expected one tutorial match"; exit 1; }
mkdir -p -- "$(dirname -- "$case_dir")"
singularity exec "$image" bash -c 'tar -C "$(dirname "$1")" -cf - "$(basename "$1")"' bash "${matches[0]}" |
    tar -xf - -C "$(dirname -- "$case_dir")"
for required in system constant 0.orig; do
    [[ -d "$case_dir/$required" ]] || { echo "ERROR: missing case directory: $required"; exit 1; }
done
for required in system/controlDict system/decomposeParDict 0.orig/U; do
    [[ -f "$case_dir/$required" ]] || { echo "ERROR: missing case file: $required"; exit 1; }
done
echo "PASS: extracted $case_name for $version"
SCRIPT

cat > "$ARTIFACTS/preFoam.generating.slurm.sh" <<SCRIPT
#!/bin/bash --login
#SBATCH --job-name=preFoam-v2606-generating
#SBATCH --nodes=$TUTORIAL_PRE_NODES
#SBATCH --ntasks=$TUTORIAL_PRE_TASKS
#SBATCH --cpus-per-task=$TUTORIAL_PRE_CPUS_PER_TASK
#SBATCH --mem=$TUTORIAL_PRE_MEMORY
#SBATCH --time=$TUTORIAL_PRE_TIME
set -Eeuo pipefail
image=$IMAGE_Q
work_root=$WORK_Q
artifacts=$ART_Q
version=$VERSION_Q
case_name=$CASE_Q_NAME
nprocs=$NPROCS_Q
io_group=$IO_GROUP_Q
io_ranks=$IO_RANKS_Q
end_time=$END_TIME_Q
write_interval=$WRITE_INTERVAL_Q
decomposition=$DECOMPOSITION_Q
expected_nodes=$TUTORIAL_PRE_NODES
expected_tasks=$TUTORIAL_PRE_TASKS
expected_cpus=$TUTORIAL_PRE_CPUS_PER_TASK
expected_image_sha256=$IMAGE_HASH_Q
SCRIPT
cat >> "$ARTIFACTS/preFoam.generating.slurm.sh" <<'SCRIPT'
while (($#)); do
    [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
    case "$1" in
        --image) image=$2; shift 2 ;;
        --work-root) work_root=$2; shift 2 ;;
        --test-artifacts-dir) artifacts=$2; shift 2 ;;
        *) echo "ERROR: unknown preFoam option: $1" >&2; exit 2 ;;
    esac
done
[[ -f "$image" ]] || { echo "ERROR: Singularity image not found: $image" >&2; exit 2; }
[[ "$(sha256sum -- "$image" | awk '{print $1}')" == "$expected_image_sha256" ]] ||
    { echo "ERROR: image digest differs from generated candidate" >&2; exit 1; }
status="$artifacts/pre.status.generating"
mkdir -p -- "$artifacts"
trap 'rc=$?; printf "%s\n" "$rc" > "$status"' EXIT
log="$artifacts/pre.generating.log"
case_dir="$work_root/run/$case_name"
module load "${SINGULARITY_MODULE:-singularity/4.3.5-mpi}"
command -v singularity >/dev/null || { echo "ERROR: singularity is unavailable" >&2; exit 1; }
singularity exec "$image" bash -c 'test "$WM_PROJECT_VERSION" = "$1"' bash "$version" ||
    { echo "ERROR: image runtime version mismatch" >&2; exit 1; }
[[ "${SLURM_JOB_NUM_NODES:-0}" == "$expected_nodes" &&
   "${SLURM_NTASKS:-0}" == "$expected_tasks" &&
   "${SLURM_CPUS_PER_TASK:-0}" == "$expected_cpus" ]] || {
    echo "ERROR: allocation does not match preparation resources" >&2; exit 1;
}
[[ -d "$case_dir/0.orig" && -f "$case_dir/system/controlDict" && -f "$case_dir/system/decomposeParDict" ]] ||
    { echo "ERROR: incomplete extracted tutorial case" >&2; exit 1; }
cd -- "$case_dir"
exec > >(tee "$log") 2>&1
export FOAM_IORANKS="$io_ranks"
rm -rf -- 0
for ((i=0; i<nprocs; i+=io_group)); do
    end=$((i+io_group-1))
    ((end<nprocs)) || end=$((nprocs-1))
    rm -rf -- "$case_dir/processors${nprocs}_${i}-${end}"
done
cp -a 0.orig 0
srun -N 1 -n 1 -c "$expected_cpus" singularity exec "$image" foamDictionary system/controlDict -entry endTime -set "$end_time"
srun -N 1 -n 1 -c "$expected_cpus" singularity exec "$image" foamDictionary system/controlDict -entry writeInterval -set "$write_interval"
srun -N 1 -n 1 -c "$expected_cpus" singularity exec "$image" foamDictionary system/decomposeParDict -entry numberOfSubdomains -set "$nprocs"
srun -N 1 -n 1 -c "$expected_cpus" singularity exec "$image" foamDictionary system/decomposeParDict -entry method -set simple
srun -N 1 -n 1 -c "$expected_cpus" singularity exec "$image" foamDictionary system/decomposeParDict -entry coeffs/n -set "$decomposition"
[[ "$(singularity exec "$image" foamDictionary system/controlDict -entry endTime -value)" == "$end_time" ]] ||
    { echo "ERROR: endTime read-back mismatch"; exit 1; }
[[ "$(singularity exec "$image" foamDictionary system/controlDict -entry writeInterval -value)" == "$write_interval" ]] ||
    { echo "ERROR: writeInterval read-back mismatch"; exit 1; }
[[ "$(singularity exec "$image" foamDictionary system/decomposeParDict -entry numberOfSubdomains -value)" == "$nprocs" ]] ||
    { echo "ERROR: numberOfSubdomains read-back mismatch"; exit 1; }
[[ "$(singularity exec "$image" foamDictionary system/decomposeParDict -entry method -value)" == simple ]] ||
    { echo "ERROR: decomposition method read-back mismatch"; exit 1; }
actual=$(singularity exec "$image" foamDictionary system/decomposeParDict -entry coeffs/n -value)
[[ "${actual//[[:space:]]/}" == "${decomposition//[[:space:]]/}" ]] ||
    { echo "ERROR: decomposition vector read-back mismatch"; exit 1; }
SCRIPT
for step in "${TUTORIAL_PRE_STEPS[@]}"; do
    declare -n step_args="TUTORIAL_PRE_$step"
    ((${#step_args[@]})) || fail "empty preparation command: $step"
    printf 'srun -N 1 -n 1 -c "$expected_cpus" singularity exec "$image" ' >> "$ARTIFACTS/preFoam.generating.slurm.sh"
    printf '%q ' "${step_args[@]}" >> "$ARTIFACTS/preFoam.generating.slurm.sh"
    printf '|& tee "$artifacts/%s.generating.log"\n' "$step" >> "$ARTIFACTS/preFoam.generating.slurm.sh"
    printf 'if grep -E %q "$artifacts/%s.generating.log"; then echo %q >&2; exit 1; fi\n' \
        'FOAM FATAL (ERROR|IO ERROR)' "$step" "ERROR: fatal OpenFOAM error in $step" >> "$ARTIFACTS/preFoam.generating.slurm.sh"
    unset -n step_args
done
cat >> "$ARTIFACTS/preFoam.generating.slurm.sh" <<'SCRIPT'
for ((i=0; i<nprocs; i+=io_group)); do
    end=$((i+io_group-1))
    ((end<nprocs)) || end=$((nprocs-1))
    [[ -d "$case_dir/processors${nprocs}_${i}-${end}" ]] ||
        { echo "ERROR: missing collated decomposition group $i-$end"; exit 1; }
done
SCRIPT

cat > "$ARTIFACTS/runFoam.generating.slurm.sh" <<SCRIPT
#!/bin/bash --login
#SBATCH --job-name=runFoam-v2606-generating
#SBATCH --nodes=$TUTORIAL_RUN_NODES
#SBATCH --ntasks=$TUTORIAL_RUN_TASKS
#SBATCH --ntasks-per-node=$TUTORIAL_RUN_TASKS_PER_NODE
#SBATCH --cpus-per-task=$TUTORIAL_RUN_CPUS_PER_TASK
#SBATCH --time=$TUTORIAL_RUN_TIME
set -Eeuo pipefail
image=$IMAGE_Q
work_root=$WORK_Q
artifacts=$ART_Q
version=$VERSION_Q
case_name=$CASE_Q_NAME
solver=$SOLVER_Q
nprocs=$NPROCS_Q
io_group=$IO_GROUP_Q
io_ranks=$IO_RANKS_Q
expected_nodes=$TUTORIAL_RUN_NODES
expected_tasks=$TUTORIAL_RUN_TASKS
expected_cpus=$TUTORIAL_RUN_CPUS_PER_TASK
tasks_per_node=$TUTORIAL_RUN_TASKS_PER_NODE
expected_image_sha256=$IMAGE_HASH_Q
SCRIPT
cat >> "$ARTIFACTS/runFoam.generating.slurm.sh" <<'SCRIPT'
while (($#)); do
    [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
    case "$1" in
        --image) image=$2; shift 2 ;;
        --work-root) work_root=$2; shift 2 ;;
        --test-artifacts-dir) artifacts=$2; shift 2 ;;
        *) echo "ERROR: unknown runFoam option: $1" >&2; exit 2 ;;
    esac
done
[[ -f "$image" ]] || { echo "ERROR: Singularity image not found: $image" >&2; exit 2; }
[[ "$(sha256sum -- "$image" | awk '{print $1}')" == "$expected_image_sha256" ]] ||
    { echo "ERROR: image digest differs from generated candidate" >&2; exit 1; }
status="$artifacts/run.status.generating"
mkdir -p -- "$artifacts"
trap 'rc=$?; printf "%s\n" "$rc" > "$status"' EXIT
log="$artifacts/solver.generating.log"
case_dir="$work_root/run/$case_name"
module load "${SINGULARITY_MODULE:-singularity/4.3.5-mpi}"
command -v singularity >/dev/null || { echo "ERROR: singularity is unavailable" >&2; exit 1; }
singularity exec "$image" bash -c 'test "$WM_PROJECT_VERSION" = "$1"' bash "$version" ||
    { echo "ERROR: image runtime version mismatch" >&2; exit 1; }
[[ "${SLURM_JOB_NUM_NODES:-0}" == "$expected_nodes" &&
   "${SLURM_NTASKS:-0}" == "$expected_tasks" &&
   "${SLURM_CPUS_PER_TASK:-0}" == "$expected_cpus" ]] || {
    echo "ERROR: allocation does not match solver resources" >&2; exit 1;
}
for ((i=0; i<nprocs; i+=io_group)); do
    end=$((i+io_group-1))
    ((end<nprocs)) || end=$((nprocs-1))
    [[ -d "$case_dir/processors${nprocs}_${i}-${end}" ]] ||
        { echo "ERROR: missing collated decomposition group $i-$end"; exit 1; }
done
cd -- "$case_dir"
export FOAM_IORANKS="$io_ranks"
srun -N "$expected_nodes" -n "$expected_tasks" -c "$expected_cpus" --ntasks-per-node="$tasks_per_node" \
    singularity exec "$image" "$solver" -parallel |& tee "$log"
if grep -E 'FOAM FATAL (ERROR|IO ERROR)' "$log"; then
    echo "ERROR: fatal OpenFOAM solver error" >&2
    exit 1
fi
SCRIPT

for f in "$ARTIFACTS"/{extractCase.generating.sh,preFoam.generating.slurm.sh,runFoam.generating.slurm.sh}; do
    chmod 755 "$f"
    bash -n "$f" || fail "generated Bash syntax check failed: $f"
done
sha256sum -- "$ARTIFACTS"/{extractCase.generating.sh,preFoam.generating.slurm.sh,runFoam.generating.slurm.sh} > "$ARTIFACTS/candidates.generating.sha256"
cp -- "$CONFIG" "$ARTIFACTS/openfoamBuildAndValidation.generating.config"
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$IMAGE" "$IMAGE_HASH" "$CONFIG_HASH" "$CASE_DIR" "$WORK_ROOT" \
    "$(awk 'NR==1{print $1}' "$ARTIFACTS/candidates.generating.sha256")" \
    "$(awk 'NR==2{print $1}' "$ARTIFACTS/candidates.generating.sha256")" \
    "$(awk 'NR==3{print $1}' "$ARTIFACTS/candidates.generating.sha256")" > "$ARTIFACTS/manifest.generating"
printf '%s\n' "$PUBLISH_RECIPE_DIR" >> "$ARTIFACTS/manifest.generating"
cp "$HERE/openfoamTutorialTestValidate.generating.sh" "$ARTIFACTS/validate.generating.sh"
chmod 755 "$ARTIFACTS/validate.generating.sh"

if [[ "$GENERATE_ONLY" == true ]]; then
    printf 'GENERATED: %s\n' "$ARTIFACTS"
    exit 0
fi

EXTRACT_ARGS=(--image "$IMAGE" --work-root "$WORK_ROOT" --test-artifacts-dir "$ARTIFACTS")
if [[ "$OVERWRITE" == true ]]; then EXTRACT_ARGS+=(--overwrite); fi
"$ARTIFACTS/extractCase.generating.sh" "${EXTRACT_ARGS[@]}"
PRE_ARGS=(--image "$IMAGE" --work-root "$WORK_ROOT" --test-artifacts-dir "$ARTIFACTS")
RUN_ARGS=("${PRE_ARGS[@]}")
SBATCH=(env -u SLURM_MEM_PER_CPU -u SLURM_MEM_PER_GPU -u SLURM_MEM_PER_NODE
    SLURM_EXPORT_ENV=ALL sbatch --export=NONE --parsable)
SBATCH+=(--partition "$PARTITION")
if [[ -n "$RESERVATION" ]]; then SBATCH+=(--reservation "$RESERVATION"); fi
PRE_ID=$("${SBATCH[@]}" --output "$ARTIFACTS/pre-%j.generating.log" "$ARTIFACTS/preFoam.generating.slurm.sh" "${PRE_ARGS[@]}")
[[ "$PRE_ID" =~ ^[0-9]+([;][^;]+)?$ ]] || fail "invalid sbatch job ID for pre stage: $PRE_ID"
PRE_ID=${PRE_ID%%;*}
RUN_ID=$("${SBATCH[@]}" --output "$ARTIFACTS/run-%j.generating.log" --dependency="afterok:$PRE_ID" --kill-on-invalid-dep=yes \
    "$ARTIFACTS/runFoam.generating.slurm.sh" "${RUN_ARGS[@]}")
[[ "$RUN_ID" =~ ^[0-9]+([;][^;]+)?$ ]] || fail "invalid sbatch job ID for solver: $RUN_ID"
RUN_ID=${RUN_ID%%;*}
FINAL="$ARTIFACTS/finalize.generating.slurm.sh"
cat > "$FINAL" <<SCRIPT
#!/bin/bash --login
#SBATCH --job-name=finalize-v2606-generating
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:05:00
set -Eeuo pipefail
$(printf '%q ' "$ARTIFACTS/validate.generating.sh" --artifacts-dir "$ARTIFACTS" --jobs "$PRE_ID" "$RUN_ID")$( [[ "$PUBLISH" == true ]] && printf '%s' '--publish' )
SCRIPT
chmod 755 "$FINAL"
FINAL_ID=$("${SBATCH[@]}" --output "$ARTIFACTS/finalize-%j.generating.log" --dependency="afterany:$PRE_ID:$RUN_ID" "$FINAL")
[[ "$FINAL_ID" =~ ^[0-9]+([;][^;]+)?$ ]] || fail "invalid finalizer job ID: $FINAL_ID"
FINAL_ID=${FINAL_ID%%;*}
printf '%s\n%s\n%s\n' "$PRE_ID" "$RUN_ID" "$FINAL_ID" > "$ARTIFACTS/jobs.generating"
printf 'SUBMITTED: pre=%s run=%s finalize=%s artifacts=%s\n' "$PRE_ID" "$RUN_ID" "$FINAL_ID" "$ARTIFACTS"
if [[ "$SUBMIT_ONLY" == true ]]; then exit 0; fi

while :; do
    state=$(squeue -h -j "$FINAL_ID" -o '%T') || fail "cannot query finalizer queue state"
    if [[ -z "$state" ]]; then break; fi
    sleep "$POLL_SECONDS"
done
for ((attempt=0; attempt<12; attempt++)); do
    final_result=$(sacct -n -P -j "$FINAL_ID" --format=JobIDRaw,State,ExitCode) ||
        fail "cannot query finalizer accounting"
    if printf '%s\n' "$final_result" | awk -F'|' -v id="$FINAL_ID" '$1==id {found=1} END {exit !found}'; then break; fi
    sleep "$POLL_SECONDS"
done
printf '%s\n' "$final_result" | awk -F'|' -v id="$FINAL_ID" \
    '$1==id && $2=="COMPLETED" && $3=="0:0" {ok=1} END {exit !ok}' ||
    fail "finalizer did not complete successfully; inspect $ARTIFACTS"
[[ -f "$ARTIFACTS/final.status.generating" &&
   "$(cat "$ARTIFACTS/final.status.generating")" == 0 ]] ||
    fail "final acceptance checks did not pass"
printf 'PASS: completed tutorial workflow; artifacts=%s\n' "$ARTIFACTS"
