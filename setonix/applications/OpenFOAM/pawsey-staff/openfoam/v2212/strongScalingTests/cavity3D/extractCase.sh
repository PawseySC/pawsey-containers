#!/bin/bash --login
# =============================================================================
# extractCase.sh: OpenFOAM v2212 cavity3D, stage 1: source materialization
# =============================================================================
# Purpose and design
# ------------------
# Materialize the authoritative exaFOAM-derived benchmark before Slurm
# submission. Keep the installed v2212 cavity tutorial in a separate reference
# directory. Never merge tutorial settings into the benchmark silently.
#
# Workflow: extract -> mesh -> prepare -> decompose -> run.
# Inputs: campaign/artifact paths; local benchmark or repository/ref; module.
# Outputs: source-case/cavity3D, version-reference/cavity, provenance and status.
#
# Dependencies: Bash, GNU file utilities, and the selected OpenFOAM module.
# The module defaults to openfoam-container/v2212 and must expose the commands
# used below. Scratch paths must be visible inside the SHPC container.
#
# Additional dependencies: Git for remote acquisition and openfoam-exec for
# reading the installed tutorial. A local source avoids network acquisition.
#
# Scope: preserve the supplied 64M/fixedIter numerical configuration. The
# installed tutorial is a reference, not an automatic compatibility converter.
# This documentation revision does not introduce new numerical adaptations.
# =============================================================================

set -euo pipefail


# =============================================================================
# 1. Command-line interface and diagnostics
# =============================================================================
# Keep option documentation and error handling independent of source acquisition.

usage() {
    cat <<'USAGE'
Usage: extractCase.sh --campaign-dir DIR --artifacts-dir DIR [options]
  --benchmark-source DIR     Existing cavity3D, 64M, or fixedIter directory
  --benchmark-repository URL Default: https://develop.openfoam.com/committees/hpc.git
  --benchmark-ref REF        Default: develop
  --foam-module MODULE      Default: openfoam-container/v2212
  --mesh LABEL              Supported: 64M
  --mode NAME               Supported: fixedIter
USAGE
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
# Select one source and preserve the established launcher argument interface.

campaign_dir=""
artifacts_dir=""
benchmark_source=""
benchmark_repository=https://develop.openfoam.com/committees/hpc.git
benchmark_ref=develop
foam_module=openfoam-container/v2212
mesh=64M
mode=fixedIter

while (($#)); do
    case $1 in
        --campaign-dir)
            need "$@"
            campaign_dir=$2
            shift 2
            ;;
        --artifacts-dir)
            need "$@"
            artifacts_dir=$2
            shift 2
            ;;
        --benchmark-source)
            need "$@"
            benchmark_source=$2
            shift 2
            ;;
        --benchmark-repository)
            need "$@"
            benchmark_repository=$2
            shift 2
            ;;
        --benchmark-ref)
            need "$@"
            benchmark_ref=$2
            shift 2
            ;;
        --foam-module)
            need "$@"
            foam_module=$2
            shift 2
            ;;
        --mesh)
            need "$@"
            mesh=$2
            shift 2
            ;;
        --mode)
            need "$@"
            mode=$2
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
# 3. Path validation and OpenFOAM environment
# =============================================================================
# Resolve host paths before invoking container-side tutorial extraction.

[[ -n $campaign_dir && -n $artifacts_dir ]] || die 'campaign and artifact directories are required'
[[ $mesh == 64M && $mode == fixedIter ]] || die 'this implementation supports only 64M/fixedIter'

# Create and canonicalize the two campaign-owned roots.
campaign_dir=$(mkdir -p "$campaign_dir" && cd "$campaign_dir" && pwd -P)
artifacts_dir=$(mkdir -p "$artifacts_dir" && cd "$artifacts_dir" && pwd -P)

# openfoam-exec provides access to the installed tutorial inside the image.
module load "$foam_module"
command -v openfoam-exec >/dev/null || die "$foam_module did not provide openfoam-exec"


# =============================================================================
# 4. Benchmark acquisition and source validation
# =============================================================================
# Use a local tree when supplied; otherwise clone the requested upstream branch.

source_revision=local
if [[ -z $benchmark_source ]]; then
    checkout=$campaign_dir/upstream/hpc

    # Replace only this campaign's checkout. The resolved commit is recorded below.
    rm -rf "$checkout"
    git clone --branch "$benchmark_ref" --depth 1 "$benchmark_repository" "$checkout"
    benchmark_source=$checkout/incompressible/icoFoam/cavity3D
    source_revision=$(git -C "$checkout" rev-parse HEAD)
else
    benchmark_source=$(cd "$benchmark_source" && pwd -P)
    if git -C "$benchmark_source" rev-parse --show-toplevel >/dev/null 2>&1; then
        source_revision=$(git -C "$benchmark_source" rev-parse HEAD) || true
    fi
fi

# Accept the same three source layouts as the original implementation.
for candidate in "$benchmark_source/$mesh/$mode" "$benchmark_source/cavity3D/$mesh/$mode" "$benchmark_source"; do
    if [[ -f $candidate/system/controlDict && -f $candidate/system/fvSolution ]]; then
        benchmark_case=$candidate
        break
    fi
done
[[ -n ${benchmark_case:-} ]] || die "cannot locate $mesh/$mode below $benchmark_source"

# Fail before copying an incomplete benchmark tree.
for file in 0/U 0/p system/controlDict system/fvSchemes system/fvSolution system/blockMeshDict; do
    [[ -f $benchmark_case/$file ]] || die "benchmark is missing $file"
done


# =============================================================================
# 5. Clean benchmark copy and separate version reference
# =============================================================================
# Discard old decompositions and nonzero time directories only in the new copy.

source_case=$campaign_dir/source-case/cavity3D
rm -rf "$campaign_dir/source-case"
mkdir -p "$(dirname "$source_case")"
cp -a "$benchmark_case" "$source_case"

# Retain time zero but remove copied results and processor directories.
find "$source_case" -maxdepth 1 -type d \
    \( -name 'processor*' -o -name 'processors*' \) -exec rm -rf {} +
find "$source_case" -mindepth 1 -maxdepth 1 -type d \
    -regex '.*/[0-9]+\(\.[0-9]+\)?' ! -name 0 -exec rm -rf {} +

# Archive the installed tutorial separately; it does not modify the benchmark.
reference_parent=$campaign_dir/version-reference
rm -rf "$reference_parent"
mkdir -p "$reference_parent"
openfoam-exec bash -lc '
    set -e
    src="$FOAM_TUTORIALS/incompressible/icoFoam/cavity/cavity"
    test -d "$src"
    cp -a "$src" "$1/cavity"
' bash "$reference_parent"
foam_version=$(openfoam-exec bash -lc 'printf "%s" "$WM_PROJECT_VERSION"')


# =============================================================================
# 6. Provenance and completion record
# =============================================================================
# Record the exact source revision when available and the selected installation.

printf 'STATUS=PASS\nSOURCE_CASE=%s\nVERSION_REFERENCE=%s\n' \
    "$source_case" "$reference_parent/cavity" > "$artifacts_dir/extractCase.status.txt"
{
    printf 'BENCHMARK_REPOSITORY=%q\n' "$benchmark_repository"
    printf 'BENCHMARK_REF_REQUESTED=%q\n' "$benchmark_ref"
    printf 'BENCHMARK_REVISION=%q\n' "$source_revision"
    printf 'BENCHMARK_SOURCE=%q\n' "$benchmark_case"
    printf 'OPENFOAM_MODULE=%q\nOPENFOAM_VERSION=%q\n' "$foam_module" "$foam_version"
    printf 'MESH_LABEL=%q\nBENCHMARK_MODE=%q\n' "$mesh" "$mode"
} > "$artifacts_dir/source-provenance.env"
