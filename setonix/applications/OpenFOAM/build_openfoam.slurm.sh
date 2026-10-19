#!/bin/bash -l
#SBATCH --job-name=buildAll_openfoam
#SBATCH --partition=podman
#SBATCH --nodelist=setonix-podman02
#SBATCH --nodes=1
#SBATCH --ntasks=16
#SBATCH --time=24:00:00

set -euo pipefail

# =============================================================================
# Command-line mode
# =============================================================================
testsOnly=false

usage() {
    cat <<USAGE
Usage:
  sbatch $(basename "$0") [--tests-only]
  $(basename "$0") [--tests-only]

Options:
  --tests-only  Skip Podman and Singularity image creation. Use the existing
                Podman image and the SIF referenced by each recipe's
                artifacts/singularity/latest directory, then run all tests.
  --help, -h    Show this help message and exit.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tests-only)
            testsOnly=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# Build and test selection
# =============================================================================
engineToUse="podman"
setonixTestPartition="work"
buildArguments=(
    # "BASE_IMAGE_MPICH_VERSION=4.2.2"
    # "WM_LABEL_SIZE=64"
    # "TP_COMPILE_TASKS=8"
)
recipeDirectories=(
    "openfoam/v2412"
    "openfoam/v2406"
    "openfoam/v2212"
    "openfoam/v2206"
    "openfoam/v2012"
    "openfoam/v2606"
    "openfoam-org/10"
    "openfoam-org/12"
    "openfoam-org/14"
)

# =============================================================================
# Repository paths and tools
# =============================================================================
repositoryRoot="${REPOSITORY_ROOT:-${MYSCRATCH}/pawsey-containers}"
openfoamRoot="${repositoryRoot}/setonix/applications/OpenFOAM"
buildingScriptsDir="${openfoamRoot}/buildingScripts"
basicTestsDir="${openfoamRoot}/tests/basic"
setonixTestsDir="${openfoamRoot}/tests/setonix"
containerBuilder="${buildingScriptsDir}/openfoamContainerBuild.sh"
singularityBuilder="${buildingScriptsDir}/openfoamSingularityBuild.sh"
nodeCleaner="${buildingScriptsDir}/cleanPodmanNode.sh"
nodeChecker="${buildingScriptsDir}/checkPodmanNode.sh"
imageValidation="${basicTestsDir}/openfoamImageValidation.sh"
basicTests="${basicTestsDir}/openfoamBasicTests.sh"
compileLauncher="${setonixTestsDir}/openfoamCompileToolTestLauncher.sh"
tutorialLauncher="${setonixTestsDir}/openfoamTutorialTestLauncher.sh"

for directory in "$repositoryRoot" "$openfoamRoot" "$buildingScriptsDir" "$basicTestsDir" "$setonixTestsDir"; do
    [[ -d "$directory" ]] || { echo "ERROR: Missing directory: $directory" >&2; exit 1; }
done
requiredScripts=(
    "$nodeCleaner"
    "$nodeChecker"
    "$imageValidation"
    "$basicTests"
    "$compileLauncher"
    "$tutorialLauncher"
)
if [[ "$testsOnly" != true ]]; then
    requiredScripts+=("$containerBuilder" "$singularityBuilder")
fi
for script in "${requiredScripts[@]}"; do
    [[ -x "$script" ]] || { echo "ERROR: Script is not executable: $script" >&2; exit 1; }
done

# This parent script invokes Podman cleanup commands directly. Initialize the
# Podman-node environment once before any cleanup or build stage is attempted.
if ! source /container/setup_podman.sh; then
    echo "ERROR: Failed to source /container/setup_podman.sh." >&2
    exit 1
fi
command -v podman >/dev/null 2>&1 || {
    echo "ERROR: podman is unavailable after sourcing /container/setup_podman.sh." >&2
    exit 1
}

buildArgumentOptions=()
for argument in "${buildArguments[@]}"; do buildArgumentOptions+=(--build-arg "$argument"); done

echo "============================================================"
if [[ "$testsOnly" == true ]]; then
    echo "Execution mode: TESTS ONLY"
    echo "Podman and Singularity image creation will be skipped."
    echo "Existing Podman images and latest Singularity SIF artifacts will be tested."
else
    echo "Execution mode: BUILD AND TEST"
fi
echo "Setonix test partition: $setonixTestPartition"
echo "============================================================"

# =============================================================================
# Status tracking
# =============================================================================
successfulRecipes=()
failedRecipes=()
declare -A failedStages=()
recordFailure() {
    failedRecipes+=("$1")
    failedStages["$1"]="$2 (exit status $3)"
    echo "ERROR: $1 failed during $2 (exit status $3). Later stages are skipped." >&2
}

# =============================================================================
# Clean and verify the Podman node before every recipe
# =============================================================================
prepareNode() {
    local output=""
    local -a ids=()
    "$nodeCleaner" --clean || return $?

    output=$(podman ps -aq --filter status=exited) || return $?
    if [[ -n "$output" ]]; then mapfile -t ids <<< "$output"; podman rm --volumes "${ids[@]}" || return $?; else echo "No exited ordinary containers found."; fi

    output=$(podman ps -aq --external --no-trunc) || return $?
    if [[ -n "$output" ]]; then mapfile -t ids <<< "$output"; podman rm --storage --force "${ids[@]}" || return $?; else echo "No external Buildah storage containers found."; fi

    echo "Checking for dangling Podman images."
    echo "This storage scan may take a couple of minutes; no output is expected while it runs."
    output=$(podman images -q --filter dangling=true) || return $?
    if [[ -n "$output" ]]; then mapfile -t ids <<< "$output"; podman rmi "${ids[@]}" || return $?; else echo "No dangling images found."; fi

    "$nodeChecker"
}

# Resolve the SIF from the latest successful Singularity conversion. This is the
# only image path passed to Singularity tests and Setonix Slurm launchers.
resolveSingularityImage() {
    local latestDir="${1}/artifacts/singularity/latest"
    local -a candidates=()

    [[ -d "$latestDir" ]] || {
        echo "ERROR: Missing latest Singularity artifact directory: $latestDir" >&2
        return 1
    }
    mapfile -t candidates < <(find -L "$latestDir" -maxdepth 1 -type f -name '*.sif' -print)
    (( ${#candidates[@]} == 1 )) || {
        echo "ERROR: Expected exactly one SIF in $latestDir; found ${#candidates[@]}." >&2
        return 1
    }

    singularityImage=$(realpath "${candidates[0]}")
    [[ -f "$singularityImage" ]] || {
        echo "ERROR: Resolved Singularity image does not exist: $singularityImage" >&2
        return 1
    }
    echo "Singularity image: $singularityImage"
}

# Derive the unqualified Podman test reference from the canonical SIF filename.
# Do not probe Podman here. Both builders already validate the image, and each
# Podman test initializes its own environment and validates this reference.
resolvePodmanImageReference() {
    local sifFileName=""
    local imageStem=""

    [[ -n "$singularityImage" && -f "$singularityImage" ]] || {
        echo "ERROR: Cannot derive the Podman reference before resolving the SIF." >&2
        return 1
    }
    sifFileName=$(basename "$singularityImage")
    imageStem="${sifFileName%.sif}"
    [[ "$imageStem" == *--* ]] || {
        echo "ERROR: Cannot derive the Podman reference from SIF filename: $sifFileName" >&2
        return 1
    }

    podmanImage="${imageStem/--/:}"
    echo "Podman test reference: $podmanImage"
}

# =============================================================================
# Build, test locally, and submit asynchronous Setonix tests
# =============================================================================
for recipeDirectory in "${recipeDirectories[@]}"; do
    recipePath="${openfoamRoot}/${recipeDirectory}"
    podmanImage=""; singularityImage=""
    echo; echo "================================================================"
    echo "Processing $recipeDirectory"; echo "Recipe path: $recipePath"
    echo "================================================================"

    if [[ ! -d "$recipePath" ]]; then recordFailure "$recipeDirectory" "recipe-directory validation" 1; continue; fi
    if prepareNode; then :; else status=$?; recordFailure "$recipeDirectory" "Podman-node preparation" "$status"; continue; fi
    if [[ "$testsOnly" == true ]]; then
        echo "TESTS-ONLY: Skipping Podman image creation for $recipeDirectory."
        echo "TESTS-ONLY: Skipping Singularity SIF creation for $recipeDirectory."
    else
        if "$containerBuilder" --engine "$engineToUse" --recipe-dir "$recipePath" "${buildArgumentOptions[@]}"; then :; else status=$?; recordFailure "$recipeDirectory" "Podman image build" "$status"; continue; fi
        if "$singularityBuilder" --engine "$engineToUse" --recipe-dir "$recipePath" "${buildArgumentOptions[@]}"; then :; else status=$?; recordFailure "$recipeDirectory" "Singularity image build" "$status"; continue; fi
    fi
    if resolveSingularityImage "$recipePath"; then :; else status=$?; recordFailure "$recipeDirectory" "Singularity image resolution" "$status"; continue; fi
    if resolvePodmanImageReference; then :; else status=$?; recordFailure "$recipeDirectory" "Podman image-reference resolution" "$status"; continue; fi
    if "$imageValidation" --recipe-dir "$recipePath" --engine podman --image "$podmanImage"; then :; else status=$?; recordFailure "$recipeDirectory" "Podman image validation" "$status"; continue; fi
    if "$basicTests" --recipe-dir "$recipePath" --engine podman --image "$podmanImage"; then :; else status=$?; recordFailure "$recipeDirectory" "Podman basic tests" "$status"; continue; fi
    if "$imageValidation" --recipe-dir "$recipePath" --engine singularity --image "$singularityImage"; then :; else status=$?; recordFailure "$recipeDirectory" "Singularity image validation" "$status"; continue; fi
    if "$basicTests" --recipe-dir "$recipePath" --engine singularity --image "$singularityImage"; then :; else status=$?; recordFailure "$recipeDirectory" "Singularity basic tests" "$status"; continue; fi
    if "$compileLauncher" --submit-only --recipe-dir "$recipePath" --image "$singularityImage" --partition "$setonixTestPartition"; then :; else status=$?; recordFailure "$recipeDirectory" "compile-tool test submission" "$status"; continue; fi
    if "$tutorialLauncher" --submit-only --recipe-dir "$recipePath" --image "$singularityImage" --partition "$setonixTestPartition"; then :; else status=$?; recordFailure "$recipeDirectory" "tutorial-test submission" "$status"; continue; fi

    successfulRecipes+=("$recipeDirectory")
    echo "Completed synchronous stages and Setonix submissions: $recipeDirectory"
done

# =============================================================================
# Final summary
# =============================================================================
echo; echo "================================================================"
echo "OpenFOAM multi-image build and test summary"; echo "================================================================"
echo "Successful recipes: ${#successfulRecipes[@]}"
for recipe in "${successfulRecipes[@]}"; do echo "  PASS: $recipe"; done
echo "Failed recipes: ${#failedRecipes[@]}"
for recipe in "${failedRecipes[@]}"; do echo "  FAIL: $recipe: ${failedStages[$recipe]}"; done
(( ${#failedRecipes[@]} == 0 )) || { echo "One or more recipes failed." >&2; exit 1; }
if [[ "$testsOnly" == true ]]; then
    echo "All local tests and Setonix test submissions completed successfully in tests-only mode."
else
    echo "All builds, local tests, and Setonix test submissions completed successfully."
fi
