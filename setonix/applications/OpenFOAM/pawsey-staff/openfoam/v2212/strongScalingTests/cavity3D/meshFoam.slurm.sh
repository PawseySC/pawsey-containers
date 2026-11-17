#!/bin/bash --login
#SBATCH --job-name=cavity3D-mesh
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --exclusive
# =============================================================================
# meshFoam.slurm.sh: OpenFOAM v2212 cavity3D, stage 2: serial mesh generation
# =============================================================================
# Purpose and design
# ------------------
# Copy the benchmark source into the shared serial base case, rebuild the
# mesh, and verify its topology and exact cell count. Preparation and solver
# execution belong to later stages; no solver settings are changed here.
#
# Workflow: extract -> mesh -> prepare -> decompose -> run.
# Inputs: source case, destination case, artifact directory, expected cells.
# Outputs: base-case mesh, blockMesh/checkMesh logs, mesh-info.env and status.
#
# Dependencies: Bash, GNU file utilities, and the selected OpenFOAM module.
# The module defaults to openfoam-container/v2212 and must expose the commands
# used below. Scratch paths must be visible inside the SHPC container.
#
# Additional dependencies: blockMesh and checkMesh exposed by the SHPC module.
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
# Expose the same mesh-stage options used by the mandatory five-stage launcher.

usage() {
    echo 'Usage: meshFoam.slurm.sh --source-case DIR --case-dir DIR --artifacts-dir DIR [--expected-cells N] [--foam-module MODULE]'
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
# Keep the fixed 64M default explicit; the mesh is verified rather than rescaled.

source_case=""
case_dir=""
artifacts_dir=""
expected_cells=64000000
foam_module=openfoam-container/v2212

while (($#)); do
    case $1 in
        --source-case)
            need "$@"
            source_case=$2
            shift 2
            ;;
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
        --expected-cells)
            need "$@"
            expected_cells=$2
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
# 3. Validation, status tracking, and environment
# =============================================================================
# Run serially on an exclusive node as agreed for the memory-heavy mesh build.

[[ -d $source_case && -n $case_dir && -n $artifacts_dir ]] || die 'required directories are missing'
[[ $expected_cells =~ ^[1-9][0-9]*$ ]] || die 'expected cells must be positive'
mkdir -p "$artifacts_dir"
status=$artifacts_dir/meshFoam.status.txt

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

# The SHPC module exposes blockMesh and checkMesh as host-callable wrappers.
module load "$foam_module"
for command in blockMesh checkMesh; do
    command -v "$command" >/dev/null || die "$command unavailable"
done


# =============================================================================
# 4. Materialize a fresh serial working case
# =============================================================================
# Replace the campaign destination, not the authoritative benchmark source.

staging=${case_dir}.staging.${SLURM_JOB_ID:-$$}
rm -rf "$staging" "$case_dir"
mkdir -p "$(dirname "$case_dir")"
cp -a "$source_case" "$staging"

# Remove any supplied mesh so blockMesh constructs it from the benchmark dictionary.
rm -rf "$staging/constant/polyMesh"
mv "$staging" "$case_dir"


# =============================================================================
# 5. Mesh construction and validation
# =============================================================================
# Keep full utility logs and propagate failures through pipefail.

blockMesh -case "$case_dir" 2>&1 | tee "$artifacts_dir/blockMesh.log"
checkMesh -case "$case_dir" -allGeometry -allTopology 2>&1 | tee "$artifacts_dir/checkMesh.log"

# Verify the actual mesh count before any preparation or decomposition can run.
actual_cells=$(awk '/^[[:space:]]*cells:[[:space:]]+[0-9]+/ {print $2; exit}' "$artifacts_dir/checkMesh.log")
[[ $actual_cells == "$expected_cells" ]] || die "expected $expected_cells cells, found ${actual_cells:-unknown}"


# =============================================================================
# 6. Mesh metadata
# =============================================================================
# Persist mesh identity for later campaign inspection; the EXIT trap records status.

printf 'EXPECTED_CELLS=%q\nACTUAL_CELLS=%q\nCASE_DIRECTORY=%q\nOPENFOAM_MODULE=%q\n' \
    "$expected_cells" "$actual_cells" "$case_dir" "$foam_module" > "$artifacts_dir/mesh-info.env"
