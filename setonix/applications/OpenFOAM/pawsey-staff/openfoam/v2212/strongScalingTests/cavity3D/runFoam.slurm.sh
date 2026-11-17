#!/bin/bash --login
#SBATCH --job-name=cavity3D-run
#SBATCH --cpus-per-task=1
# =============================================================================
# runFoam.slurm.sh: OpenFOAM v2212 cavity3D, stage 5: parallel renumbering and solver execution
# =============================================================================
# Purpose and design
# ------------------
# Use the launcher-provided MPI allocation for parallel renumberMesh and
# then icoFoam, in separate srun steps. Renumbering consumes job walltime but is
# not part of icoFoam's own cumulative ExecutionTime sequence. Preserve raw logs
# and execution facts; statistical interval selection belongs to postprocessing.
#
# Workflow: extract -> mesh -> prepare -> decompose -> run.
# Inputs: decomposed job case, artifact path, topology, expected steps, module.
# Outputs: renumberMesh-parallel.log, icoFoam.log, execution metadata and status.
#
# Dependencies: Bash, GNU file utilities, and the selected OpenFOAM module.
# The module defaults to openfoam-container/v2212 and must expose the commands
# used below. Scratch paths must be visible inside the SHPC container.
#
# Additional dependencies: Slurm srun, foamDictionary, renumberMesh, icoFoam.
#
# Scope: preserve the supplied 64M/fixedIter numerical configuration. The
# installed tutorial is a reference, not an automatic compatibility converter.
# This documentation revision does not introduce new numerical adaptations.
# =============================================================================

set -euo pipefail


# =============================================================================
# 1. Command-line interface and diagnostics
# =============================================================================
# Keep the existing solver-stage interface unchanged for the five-stage launcher.

usage() {
    echo 'Usage: runFoam.slurm.sh --case-dir DIR --job-artifacts DIR --nodes N --tasks-per-node N [--expected-steps 15] [--foam-module MODULE]'
}

# Report one actionable error and terminate with a nonzero exit status.
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Require a nonempty value after a command-line option.
need() {
    [[ $# -ge 2 && -n $2 ]] || die "missing value for $1"
}


# =============================================================================
# 2. Defaults and option parsing
# =============================================================================
# Read the allocated topology and the expected fixed-step completion count.

case_dir=""
job_artifacts=""
nodes=""
tasks_per_node=""
expected_steps=15
foam_module=openfoam-container/v2212

while (($#)); do
    case $1 in
        --case-dir)
            need "$@"
            case_dir=$2
            shift 2
            ;;
        --job-artifacts)
            need "$@"
            job_artifacts=$2
            shift 2
            ;;
        --nodes)
            need "$@"
            nodes=$2
            shift 2
            ;;
        --tasks-per-node)
            need "$@"
            tasks_per_node=$2
            shift 2
            ;;
        --expected-steps)
            need "$@"
            expected_steps=$2
            shift 2
            ;;
        --foam-module)
            need "$@"
            foam_module=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done


# =============================================================================
# 3. Input validation, status tracking, and solver selection
# =============================================================================
# The benchmark must select icoFoam; no solver dictionary is rewritten here.

[[ -d $case_dir && -n $job_artifacts ]] || die 'case or artifact directory missing'
cores=$((nodes * tasks_per_node))
mkdir -p "$job_artifacts"
status=$job_artifacts/runFoam.status.txt

# Preserve the original exit code while recording success or failure. The
# launcher reads this artifact after Slurm has finished the stage.
record_status() {
    local rc=$?
    local result=FAIL
    if [[ $rc -eq 0 ]]; then
        result=PASS
    fi
    printf 'STATUS=%s\nEXIT_CODE=%d\n' "$result" "$rc" > "$status"
    exit "$rc"
}
trap record_status EXIT

module load "$foam_module"
solver=$(foamDictionary "$case_dir/system/controlDict" -entry application -value | tr -d ';' | xargs)
[[ $solver == icoFoam ]] || die "expected icoFoam, found $solver"
command -v "$solver" >/dev/null


# =============================================================================
# 4. Parallel I/O and MPI environment
# =============================================================================
# Select one collated I/O rank per node using the requested rank distribution.

io_ranks=()
for ((rank=0; rank<cores; rank+=tasks_per_node)); do
    io_ranks+=("$rank")
done
export FOAM_IORANKS="(${io_ranks[*]})"
export MPICH_OFI_STARTUP_CONNECT=1


# =============================================================================
# 5. Parallel renumbering before solver startup
# =============================================================================
# Reuse the solver allocation; keep renumbering output separate from solver timing.

srun --nodes="$nodes" --ntasks="$cores" \
    --ntasks-per-node="$tasks_per_node" --cpus-per-task=1 \
    renumberMesh -case "$case_dir" -parallel -fileHandler collated \
    -overwrite -constant 2>&1 | tee "$job_artifacts/renumberMesh-parallel.log"


# =============================================================================
# 6. Run the fixed-step solver and verify completion
# =============================================================================
# Capture the solver exit status before any other command changes PIPESTATUS.

# Temporarily disable errexit so the solver status can be captured after tee.
set +e
srun --nodes="$nodes" --ntasks="$cores" \
    --ntasks-per-node="$tasks_per_node" --cpus-per-task=1 \
    "$solver" -case "$case_dir" -parallel -fileHandler collated \
    2>&1 | tee "$job_artifacts/${solver}.log"
solver_rc=${PIPESTATUS[0]}
set -e
((solver_rc == 0)) || die "$solver exited with status $solver_rc"

# Retain the established Time-line count and End-marker completion checks.
completed_steps=$(grep -Ec '^[[:space:]]*([0-9]+:[[:space:]]*)?Time = [-+0-9.eE]+[[:space:]]*$' "$job_artifacts/${solver}.log" || true)
[[ $completed_steps == "$expected_steps" ]] || die "expected $expected_steps steps, found $completed_steps"
grep -Eq '^[[:space:]]*([0-9]+:[[:space:]]*)?End[[:space:]]*$' "$job_artifacts/${solver}.log" || die 'no End marker'


# =============================================================================
# 7. Execution metadata without statistical policy
# =============================================================================
# Retain the existing metadata filename for compatibility; it contains no timing averages.

# The existing 64M default is retained; meshFoam separately verifies the mesh.
actual_cells=${ACTUAL_CELLS:-64000000}
{
    printf 'OPENFOAM_FORK=openfoam\nOPENFOAM_VERSION=v2212\nRUNTIME_KEY=shpc\nTARGET_CELLS_MILLIONS=64\n'
    printf 'SOLVER=%q\nCOMPLETED_STEPS=%q\nNODES=%q\nTASKS_PER_NODE=%q\nCORES=%q\n' \
        "$solver" "$completed_steps" "$nodes" "$tasks_per_node" "$cores"
    printf 'ACTUAL_CELLS=%q\nCELLS_PER_CORE=%q\nRAW_LOG=%q\n' \
        "$actual_cells" \
        "$(awk -v c="$actual_cells" -v p="$cores" 'BEGIN{printf "%.6f",c/p}')" \
        "$job_artifacts/${solver}.log"
} > "$job_artifacts/scaling-metrics.env"
printf 'ALL STEPS PASSED: cavity3D fixedIter benchmark completed successfully.\n'
