#!/bin/bash --login
#SBATCH --job-name=cavity3D-decompose
#SBATCH --cpus-per-task=1
#SBATCH --exclusive
# =============================================================================
# decomposeFoam.slurm.sh: OpenFOAM v2212 cavity3D, stage 4: topology-specific decomposition
# =============================================================================
# Purpose and design
# ------------------
# Copy the prepared serial case for one scaling point and configure scotch
# for its MPI rank count. decomposePar remains serial; the exclusive allocation
# provides memory for the complete mesh, not parallel decomposition.
#
# Workflow: extract -> mesh -> prepare -> decompose -> run.
# Inputs: prepared case, job case/artifacts, nodes and tasks per node.
# Outputs: decomposed job case, decomposePar.log, job-info.env and status.
#
# Dependencies: Bash, GNU file utilities, and the selected OpenFOAM module.
# The module defaults to openfoam-container/v2212 and must expose the commands
# used below. Scratch paths must be visible inside the SHPC container.
#
# Additional dependencies: foamDictionary and serial decomposePar.
# --exclusive is the agreed Pawsey allocation policy; no --mem override is added.
#
# Scope: preserve the supplied 64M/fixedIter numerical configuration. The
# installed tutorial is a reference, not an automatic compatibility converter.
# This documentation revision does not introduce new numerical adaptations.
# =============================================================================

set -euo pipefail


# =============================================================================
# 1. Command-line interface and diagnostics
# =============================================================================
# Keep decomposition topology separate from scientific benchmark controls.

usage() {
    echo 'Usage: decomposeFoam.slurm.sh --prepared-case DIR --job-case DIR --job-artifacts DIR --nodes N --tasks-per-node N [--foam-module MODULE]'
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
# Read the topology supplied by the launcher for this independent case copy.

prepared_case=""
job_case=""
job_artifacts=""
nodes=""
tasks_per_node=""
foam_module=openfoam-container/v2212

while (($#)); do
    case $1 in
        --prepared-case)
            need "$@"
            prepared_case=$2
            shift 2
            ;;
        --job-case)
            need "$@"
            job_case=$2
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
# 3. Case validation, status tracking, and environment
# =============================================================================
# Require the prepared mesh and preserve a durable stage result.

[[ -d $prepared_case/constant/polyMesh ]] || die 'prepared case missing'
[[ -n $job_case && -n $job_artifacts ]] || die 'job paths required'
cores=$((nodes * tasks_per_node))
mkdir -p "$job_artifacts" "$(dirname "$job_case")"
status=$job_artifacts/decomposeFoam.status.txt

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

# The launcher supplies one node and one task; --exclusive is retained here.
module load "$foam_module"
command -v foamDictionary >/dev/null
command -v decomposePar >/dev/null


# =============================================================================
# 4. Independent case copy and decomposition dictionary
# =============================================================================
# Only the rank count and decomposition method are changed in this stage.

staging=${job_case}.staging.${SLURM_JOB_ID:-$$}
rm -rf "$staging" "$job_case"

# Reflinks reduce copying where supported; GNU cp falls back to ordinary copying.
cp -a --reflink=auto "$prepared_case" "$staging"
dict=$staging/system/decomposeParDict
if [[ -f $dict ]]; then
    foamDictionary "$dict" -entry numberOfSubdomains -set "$cores"
    foamDictionary "$dict" -entry method -set scotch
else
    # Supply a minimal dictionary only when upstream did not include one.
    printf 'FoamFile { format ascii; class dictionary; object decomposeParDict; }\nnumberOfSubdomains %d;\nmethod scotch;\n' \
        "$cores" > "$dict"
fi
mv "$staging" "$job_case"


# =============================================================================
# 5. Serial decomposition and output-layout verification
# =============================================================================
# Accept the existing collated layout or the expected number of processor directories.

decomposePar -case "$job_case" -fileHandler collated -force 2>&1 | tee "$job_artifacts/decomposePar.log"

# Check the decomposition layout before the dependent parallel run starts.
uncollated=$(find "$job_case" -maxdepth 1 -type d -name 'processor[0-9]*' | wc -l)
collated=$(find "$job_case" -maxdepth 1 -type d -name "processors${cores}*" | wc -l)
((uncollated == cores || collated >= 1)) || die "decomposition does not represent $cores ranks"


# =============================================================================
# 6. Topology metadata
# =============================================================================
# Persist the allocation identity without calculating solver statistics.

printf 'NODES=%q\nTASKS_PER_NODE=%q\nCORES=%q\nDECOMPOSITION_METHOD=scotch\nCASE_DIRECTORY=%q\n' \
    "$nodes" "$tasks_per_node" "$cores" "$job_case" > "$job_artifacts/job-info.env"
