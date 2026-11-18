#!/bin/bash --login
# =============================================================================
# Generic five-stage launcher contract
# =============================================================================
# This case-owned stage is coordinated through case.conf. The generic launcher
# supplies this script's documented native arguments from a declarative argument
# template, while this script remains responsible for its OpenFOAM-specific work,
# validation, artifacts, status record, and failure handling. The shared scratch
# contract is source-case/<case>, base-case/<case>, and jobs/<topology>/<case>.
# =============================================================================
#SBATCH --job-name=cavity3D-prepare
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
# =============================================================================
# prepareFoam.slurm.sh: OpenFOAM v2212 cavity3D, stage 3: shared case validation
# =============================================================================
# Purpose and design
# ------------------
# Validate the existing fixed-iteration benchmark settings and archive the
# serial configuration used by every decomposition. This stage does not run
# icoFoam, calibrate iteration counts, or rewrite the scientific dictionaries.
#
# Workflow: extract -> mesh -> prepare -> decompose -> run.
# Inputs: meshed serial case, artifact directory, expected step count, module.
# Outputs: prepared-case-details snapshot/checksums, prepared-case.env, status.
#
# Dependencies: Bash, GNU file utilities, and the selected OpenFOAM module.
# The module defaults to openfoam-container/v2212 and must expose the commands
# used below. Scratch paths must be visible inside the SHPC container.
#
# Additional dependencies: foamDictionary, icoFoam, and sha256sum.
#
# Scope: preserve the supplied 64M/fixedIter numerical configuration. The
# installed tutorial is a reference, not an automatic compatibility converter.
# This documentation revision does not introduce new numerical adaptations.
# =============================================================================

set -euo pipefail


# =============================================================================
# 1. Command-line interface and diagnostics
# =============================================================================
# Expose preparation controls without introducing topology-specific arguments.

usage() {
    echo 'Usage: prepareFoam.slurm.sh --case-dir DIR --artifacts-dir DIR [--expected-steps 15] [--foam-module MODULE]'
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
# The supplied benchmark uses 15 steps; the dictionary remains the source of times.

case_dir=""
artifacts_dir=""
expected_steps=15
foam_module=openfoam-container/v2212

while (($#)); do
    case $1 in
        --case-dir)
            need "$@"
            case_dir=$2
            shift 2
            ;;
        --artifacts-dir)
            need "$@"
            artifacts_dir=$2
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
# 3. Input validation and environment
# =============================================================================
# Require a meshed serial case and make stage failures visible to the launcher.

[[ -d $case_dir/constant/polyMesh && -n $artifacts_dir ]] || die 'meshed case or artifact directory missing'
mkdir -p "$artifacts_dir"
status=$artifacts_dir/prepareFoam.status.txt

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
command -v foamDictionary >/dev/null || die 'foamDictionary unavailable'
command -v icoFoam >/dev/null || die 'icoFoam unavailable'

# Read an OpenFOAM entry and normalize its printed value for shell comparisons.
value() {
    foamDictionary "$1" -entry "$2" -value | tr -d ';' | xargs
}


# =============================================================================
# 4. Read and validate benchmark controls
# =============================================================================
# Preserve the original checks: icoFoam, disabled predictor, fixed pressure work, 15 steps.

control=$case_dir/system/controlDict
solution=$case_dir/system/fvSolution
application=$(value "$control" application)
start_time=$(value "$control" startTime)
end_time=$(value "$control" endTime)
delta_t=$(value "$control" deltaT)
momentum_predictor=$(value "$solution" PISO/momentumPredictor)
p_max_iter=$(value "$solution" solvers/p/maxIter)
p_tolerance=$(value "$solution" solvers/p/tolerance)
p_rel_tol=$(value "$solution" solvers/p/relTol)

# Zero tolerances retain the benchmark's maxIter-controlled pressure workload.
[[ $application == icoFoam ]] || die "expected icoFoam, found $application"
# OpenFOAM Switch accepts several equivalent disabled spellings. Validate the
# meaning without rewriting the authoritative benchmark dictionary.
case ${momentum_predictor,,} in
    false|off|no|none|0|f|n)
        ;;
    *)
        die "PISO/momentumPredictor must be disabled; found '$momentum_predictor'"
        ;;
esac
awk -v n="$p_max_iter" 'BEGIN{exit !(n==int(n)&&n>0)}' || die 'p/maxIter must be positive'
awk -v x="$p_tolerance" 'BEGIN{exit !(x==0)}' || die 'p/tolerance must be zero'
awk -v x="$p_rel_tol" 'BEGIN{exit !(x==0)}' || die 'p/relTol must be zero'

# Retain the established nominal step-count calculation for this revision.
steps=$(awk -v a="$start_time" -v b="$end_time" -v d="$delta_t" 'BEGIN{printf "%.0f",(b-a)/d}')
[[ $steps == "$expected_steps" ]] || die "controlDict describes $steps steps, expected $expected_steps"


# =============================================================================
# 5. Archive the common serial configuration
# =============================================================================
# Remove stale decompositions, then snapshot dictionaries and initial field files.

find "$case_dir" -maxdepth 1 -type d \
    \( -name 'processor*' -o -name 'processors*' \) -exec rm -rf {} +

# The snapshot excludes the large mesh but preserves the configured input files.
snapshot=$artifacts_dir/prepared-case-details
rm -rf "$snapshot"
mkdir -p "$snapshot/0" "$snapshot/constant"
cp -a "$case_dir/system" "$snapshot/system"
find "$case_dir/0" -maxdepth 1 -type f -exec cp -a {} "$snapshot/0/" \;
find "$case_dir/constant" -maxdepth 1 -type f -exec cp -a {} "$snapshot/constant/" \;

# Relative paths make the archived checksum manifest independently verifiable.
(
    cd "$snapshot"
    find 0 constant system -type f -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
)


# =============================================================================
# 6. Preparation metadata
# =============================================================================
# Record the validated settings without replacing the raw dictionaries.

printf 'APPLICATION=%q\nSTART_TIME=%q\nEND_TIME=%q\nDELTA_T=%q\nTIMESTEPS=%q\nP_MAX_ITER=%q\nPISO_MOMENTUM_PREDICTOR=%q\nPREPARED_CASE=%q\n' \
    "$application" "$start_time" "$end_time" "$delta_t" "$steps" \
    "$p_max_iter" "$momentum_predictor" "$case_dir" > "$artifacts_dir/prepared-case.env"
