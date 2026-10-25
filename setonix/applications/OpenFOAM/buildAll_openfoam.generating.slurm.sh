#!/bin/bash -l
#SBATCH --job-name=buildAll_openfoam
#SBATCH --partition=podman
#SBATCH --nodelist=setonix-podman02
#SBATCH --nodes=1
#SBATCH --ntasks=16
#SBATCH --time=24:00:00

# =============================================================================
# OpenFOAM multi-image build and test orchestrator
# =============================================================================
#
# Purpose
# -------
# Build, validate, and test a selected set of OpenFOAM container recipes on a
# Pawsey Podman build node. Each recipe is handled independently so a failure in
# one version does not prevent later selected versions from being attempted.
#
# Normal workflow
# ---------------
# For every selected recipe, the script:
#   1. Cleans and validates the Podman build node.
#   2. Builds the Podman image.
#   3. Converts the Podman image into a Singularity SIF.
#   4. Runs image validation and basic tests with Podman.
#   5. Runs image validation and basic tests with Singularity.
#   6. Submits the compile-tool and tutorial tests to the Setonix work partition.
#
# Tests-only workflow
# -------------------
# With --tests-only, image creation is skipped. The script uses the existing
# Podman image and the SIF referenced by artifacts/singularity/latest, then runs
# the same validation and test stages.
#
# Per-invocation recipe selection
# -------------------------------
# By default, the script processes the recipeDirectories array defined below.
# Use --only-directories with a comma-separated list to override that array for
# one submission without editing this file. The supplied order is preserved.
#
# Failure model
# -------------
# A failed stage skips the remaining stages for that recipe. Processing continues
# with the next selected recipe. The final process status is nonzero if any recipe
# failed, making the workflow suitable for automation and monitoring.
#
# Experimental integration copy: this file is intentionally limited to
# openfoam/v2606 and routes tutorial tests to the .generating prototype.
# =============================================================================

# Fail on unhandled command errors, unset variables, and failed pipeline stages.
# Expected per-recipe failures are caught explicitly so processing can continue.
set -euo pipefail

# =============================================================================
# Command-line mode
# =============================================================================
# Build-and-test mode is the default. Tests-only mode must be requested explicitly
# for each submission and cannot be enabled implicitly through the environment.
testsOnly=false

# Empty means the configured recipeDirectories array remains authoritative.
onlyDirectoriesInput=""

usage() {
    cat <<USAGE
Usage:
  sbatch $(basename "$0") [--tests-only] [--only-directories <list>]
  $(basename "$0") [--tests-only] [--only-directories <list>]

Examples:
  sbatch $(basename "$0") \
      --only-directories openfoam/v2412,openfoam/v2406

  sbatch $(basename "$0") \
      --tests-only \
      --only-directories openfoam-org/12,openfoam-org/14

Options:
  --tests-only
      Skip Podman and Singularity image creation. Use the existing Podman image
      and the SIF referenced by each recipe's artifacts/singularity/latest
      directory, then run all validation and test stages.

  --only-directories <list>
      Process only the comma-separated recipe directories in <list>, overriding
      the recipeDirectories array for this invocation. Surrounding whitespace is
      ignored and the supplied order is preserved. Example:

        --only-directories openfoam/v2412,openfoam-org/12

  --help, -h
      Show this help message and exit.
USAGE
}

# Parse only the explicitly supported options. Unknown arguments are rejected so
# misspelled modes cannot silently trigger a full build.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tests-only)
            testsOnly=true
            shift
            ;;
        --only-directories)
            [[ $# -ge 2 && -n "$2" ]] || {
                echo "ERROR: --only-directories requires a comma-separated list." >&2
                exit 1
            }
            [[ -z "$onlyDirectoriesInput" ]] || {
                echo "ERROR: --only-directories may be specified only once." >&2
                exit 1
            }
            onlyDirectoriesInput="$2"
            shift 2
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
# User configuration: build parameters and recipe selection
# =============================================================================
# The image builders use Podman as their source container engine on this node.
engineToUse="podman"

# Setonix compile-tool and tutorial jobs are submitted asynchronously to this
# partition by the two test launchers.
setonixTestPartition="work"

# Optional NAME=VALUE overrides passed to both builders as repeated --build-arg
# options. Leave all entries commented to use each recipe's configured defaults.
buildArguments=(
    # "BASE_IMAGE_MPICH_VERSION=3.4.3"
    # "WM_LABEL_SIZE=64"
    # "TP_COMPILE_TASKS=8"
)

# This indexed array defines the persistent default selection. For temporary
# selections, prefer --only-directories instead of editing this file.
recipeDirectories=(
    "openfoam/v2606"
)

# Parse and validate a comma-separated command-line override. Recipe paths are
# restricted to one version directory below either supported OpenFOAM fork. This
# prevents absolute paths and parent-directory traversal from entering path joins.
applyOnlyDirectoriesOverride() {
    local input="$1"
    local rawDirectory=""
    local recipeDirectory=""
    local -a requestedDirectories=()
    local -A seenDirectories=()

    # Reject leading, trailing, and adjacent separators explicitly. Bash array
    # parsing can otherwise discard a trailing empty field.
    [[ "$input" != ,* && "$input" != *, && "$input" != *,,* ]] || {
        echo "ERROR: --only-directories contains an empty directory entry." >&2
        return 1
    }

    IFS=',' read -r -a requestedDirectories <<< "$input"
    recipeDirectories=()

    for rawDirectory in "${requestedDirectories[@]}"; do
        # Remove leading and trailing shell whitespace around each list item.
        recipeDirectory="${rawDirectory#"${rawDirectory%%[!$' \t\r\n']*}"}"
        recipeDirectory="${recipeDirectory%"${recipeDirectory##*[!$' \t\r\n']}"}"

        [[ -n "$recipeDirectory" ]] || {
            echo "ERROR: --only-directories contains an empty directory entry." >&2
            return 1
        }
        [[ "$recipeDirectory" =~ ^(openfoam|openfoam-org)/[^/,[:space:]]+$ ]] || {
            echo "ERROR: Invalid recipe directory in --only-directories: $recipeDirectory" >&2
            echo "ERROR: Expected openfoam/<version> or openfoam-org/<version>." >&2
            return 1
        }
        [[ -z "${seenDirectories[$recipeDirectory]+x}" ]] || {
            echo "ERROR: Duplicate recipe directory in --only-directories: $recipeDirectory" >&2
            return 1
        }

        seenDirectories["$recipeDirectory"]=1
        recipeDirectories+=("$recipeDirectory")
    done

    (( ${#recipeDirectories[@]} > 0 )) || {
        echo "ERROR: --only-directories did not provide any recipe directories." >&2
        return 1
    }
}

# Apply the per-invocation override after defining the complete default array.
if [[ -n "$onlyDirectoriesInput" ]]; then
    applyOnlyDirectoriesOverride "$onlyDirectoriesInput" || exit 1
fi

# This copy deliberately routes only the v2606 OpenFOAM recipe through the
# generating prototype. Reject other selections before any build activity.
for recipeDirectory in "${recipeDirectories[@]}"; do
    [[ "$recipeDirectory" == "openfoam/v2606" ]] || {
        echo "ERROR: buildAll_openfoam.generating.slurm.sh supports only openfoam/v2606; got $recipeDirectory." >&2
        exit 1
    }
done

# =============================================================================
# Repository layout and shared tool paths
# =============================================================================
# REPOSITORY_ROOT can override the standard Pawsey location. The default derives
# the repository from MYSCRATCH, which must therefore be available when no
# explicit override is supplied.
repositoryRoot="${REPOSITORY_ROOT:-${MYSCRATCH}/pawsey-containers}"
openfoamRoot="${repositoryRoot}/setonix/applications/OpenFOAM"
buildingScriptsDir="${openfoamRoot}/buildingScripts"
basicTestsDir="${openfoamRoot}/tests/basic"
setonixTestsDir="${openfoamRoot}/tests/setonix"

# Image creation and Podman-node management tools.
containerBuilder="${buildingScriptsDir}/openfoamContainerBuild.sh"
singularityBuilder="${buildingScriptsDir}/openfoamSingularityBuild.sh"
nodeCleaner="${buildingScriptsDir}/cleanPodmanNode.sh"
nodeChecker="${buildingScriptsDir}/checkPodmanNode.sh"

# Local validation tools and asynchronous Setonix launchers.
imageValidation="${basicTestsDir}/openfoamImageValidation.sh"
basicTests="${basicTestsDir}/openfoamBasicTests.sh"
compileLauncher="${setonixTestsDir}/openfoamCompileToolTestLauncher.sh"
tutorialLauncher="${setonixTestsDir}/openfoamTutorialTestLauncher.generating.sh"

# Validate the complete directory layout before changing Podman state or starting
# any image operation.
requiredDirectories=(
    "$repositoryRoot"
    "$openfoamRoot"
    "$buildingScriptsDir"
    "$basicTestsDir"
    "$setonixTestsDir"
)

for directory in "${requiredDirectories[@]}"; do
    [[ -d "$directory" ]] || {
        echo "ERROR: Missing directory: $directory" >&2
        exit 1
    }
done

# Tests-only mode does not require the two builders, but all cleanup, validation,
# and launcher scripts remain mandatory.
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
    [[ -x "$script" ]] || {
        echo "ERROR: Script is not executable: $script" >&2
        exit 1
    }
done

# This parent script invokes Podman cleanup commands directly. Initialize the
# Podman-node environment once before any cleanup, build, or Podman test stage.
if ! source /container/setup_podman.sh; then
    echo "ERROR: Failed to source /container/setup_podman.sh." >&2
    exit 1
fi

command -v podman >/dev/null 2>&1 || {
    echo "ERROR: podman is unavailable after sourcing /container/setup_podman.sh." >&2
    exit 1
}

# Convert each configured NAME=VALUE entry into the repeated option format
# accepted by both image builders.
buildArgumentOptions=()
for argument in "${buildArguments[@]}"; do
    buildArgumentOptions+=(--build-arg "$argument")
done

# Display the selected operating mode before processing any recipe.
echo "============================================================"
if [[ "$testsOnly" == true ]]; then
    echo "Execution mode: TESTS ONLY"
    echo "Podman and Singularity image creation will be skipped."
    echo "Existing Podman images and latest Singularity SIF artifacts will be tested."
else
    echo "Execution mode: BUILD AND TEST"
fi
echo "Setonix test partition: $setonixTestPartition"
if [[ -n "$onlyDirectoriesInput" ]]; then
    echo "Recipe selection: --only-directories override"
else
    echo "Recipe selection: configured recipeDirectories array"
fi
printf 'Selected recipes:'
printf ' %s' "${recipeDirectories[@]}"
printf '\n'
echo "============================================================"

# =============================================================================
# Per-recipe status tracking
# =============================================================================
# Successful and failed recipes are retained separately for the final summary.
successfulRecipes=()
failedRecipes=()
declare -A failedStages=()

# Record one failed stage and its exit status without terminating the full job.
# The caller remains responsible for continuing immediately to the next recipe.
recordFailure() {
    local recipeDirectory="$1"
    local failedStage="$2"
    local exitStatus="$3"

    failedRecipes+=("$recipeDirectory")
    failedStages["$recipeDirectory"]="${failedStage} (exit status ${exitStatus})"

    echo "ERROR: $recipeDirectory failed during $failedStage (exit status $exitStatus)." >&2
    echo "ERROR: Later stages for this recipe are skipped." >&2
}

# =============================================================================
# Podman-node cleanup and readiness validation
# =============================================================================
# Return the node to a consistent state before every selected recipe. The
# dedicated cleaner handles services, processes, and mounts. The explicit Podman
# operations below remove persisted objects that are outside that cleaner's
# intentionally limited scope.
prepareNode() {
    local output=""
    local -a ids=()

    # Remove transient build services, matching user processes, and stale FUSE
    # overlay mounts according to the dedicated cleaner's production policy.
    "$nodeCleaner" --clean || return $?

    # Remove exited ordinary containers and their associated anonymous volumes.
    output=$(podman ps -aq --filter status=exited) || return $?
    if [[ -n "$output" ]]; then
        mapfile -t ids <<< "$output"
        podman rm --volumes "${ids[@]}" || return $?
    else
        echo "No exited ordinary containers found."
    fi

    # Remove all external Buildah storage container records. These can remain
    # after interrupted or failed image builds and interfere with later work.
    output=$(podman ps -aq --external --no-trunc) || return $?
    if [[ -n "$output" ]]; then
        mapfile -t ids <<< "$output"
        podman rm --storage --force "${ids[@]}" || return $?
    else
        echo "No external Buildah storage containers found."
    fi

    # Querying a large Podman image store can be quiet for several minutes. Print
    # an explicit progress notice so the expected delay is not mistaken for a hang.
    echo "Checking for dangling Podman images."
    echo "This storage scan may take a couple of minutes; no output is expected while it runs."
    output=$(podman images -q --filter dangling=true) || return $?
    if [[ -n "$output" ]]; then
        mapfile -t ids <<< "$output"
        podman rmi "${ids[@]}" || return $?
    else
        echo "No dangling images found."
    fi

    # Perform the final readiness check only after cleanup has completed.
    "$nodeChecker"
}

# =============================================================================
# Existing image resolution
# =============================================================================
# Resolve exactly one SIF through the latest successful Singularity conversion
# artifact. The canonical path is used by all Singularity tests and launchers.
resolveSingularityImage() {
    local recipePath="$1"
    local latestDir="${recipePath}/artifacts/singularity/latest"
    local -a candidates=()

    [[ -d "$latestDir" ]] || {
        echo "ERROR: Missing latest Singularity artifact directory: $latestDir" >&2
        return 1
    }

    mapfile -t candidates < <(
        find -L "$latestDir" -maxdepth 1 -type f -name '*.sif' -print
    )

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
# For example, openfoam-org--12-configuration.sif maps to
# openfoam-org:12-configuration. Do not probe Podman here: both builders already
# validate the source image, and each Podman test initializes and validates its
# own engine environment.
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
# Main workflow: build, test, and submit Setonix jobs
# =============================================================================
# Process every selected recipe independently. Each stage gates the stages that
# follow it for the same recipe, but a failure does not stop later recipes.
for recipeDirectory in "${recipeDirectories[@]}"; do
    recipePath="${openfoamRoot}/${recipeDirectory}"
    podmanImage=""
    singularityImage=""

    echo
    echo "================================================================"
    echo "Processing OpenFOAM recipe: $recipeDirectory"
    echo "Recipe path: $recipePath"
    echo "================================================================"

    # A missing recipe cannot be built or tested, but should not suppress later
    # selected versions.
    if [[ ! -d "$recipePath" ]]; then
        recordFailure "$recipeDirectory" "recipe-directory validation" 1
        continue
    fi

    # Establish a clean and responsive Podman environment before each recipe.
    if prepareNode; then
        echo "PASS: Podman node is ready for $recipeDirectory."
    else
        status=$?
        recordFailure "$recipeDirectory" "Podman-node preparation" "$status"
        continue
    fi

    # In normal mode, build both image formats. Tests-only mode deliberately uses
    # the existing Podman image and current latest SIF without rebuilding either.
    if [[ "$testsOnly" == true ]]; then
        echo "TESTS-ONLY: Skipping Podman image creation for $recipeDirectory."
        echo "TESTS-ONLY: Skipping Singularity SIF creation for $recipeDirectory."
    else
        if "$containerBuilder" \
            --engine "$engineToUse" \
            --recipe-dir "$recipePath" \
            "${buildArgumentOptions[@]}"; then
            echo "PASS: Podman image build completed for $recipeDirectory."
        else
            status=$?
            recordFailure "$recipeDirectory" "Podman image build" "$status"
            continue
        fi

        if "$singularityBuilder" \
            --engine "$engineToUse" \
            --recipe-dir "$recipePath" \
            "${buildArgumentOptions[@]}"; then
            echo "PASS: Singularity image build completed for $recipeDirectory."
        else
            status=$?
            recordFailure "$recipeDirectory" "Singularity image build" "$status"
            continue
        fi
    fi

    # Resolve the current SIF first, then derive the corresponding unqualified
    # Podman reference used by the two Podman-specific test scripts.
    if resolveSingularityImage "$recipePath"; then
        :
    else
        status=$?
        recordFailure "$recipeDirectory" "Singularity image resolution" "$status"
        continue
    fi

    if resolvePodmanImageReference; then
        :
    else
        status=$?
        recordFailure "$recipeDirectory" "Podman image-reference resolution" "$status"
        continue
    fi

    # Validate the Podman image before running broader functional checks.
    if "$imageValidation" \
        --recipe-dir "$recipePath" \
        --engine podman \
        --image "$podmanImage"; then
        :
    else
        status=$?
        recordFailure "$recipeDirectory" "Podman image validation" "$status"
        continue
    fi

    # Run the common basic test suite against the local Podman image.
    if "$basicTests" \
        --recipe-dir "$recipePath" \
        --engine podman \
        --image "$podmanImage"; then
        :
    else
        status=$?
        recordFailure "$recipeDirectory" "Podman basic tests" "$status"
        continue
    fi

    # Validate the exact SIF resolved from artifacts/singularity/latest.
    if "$imageValidation" \
        --recipe-dir "$recipePath" \
        --engine singularity \
        --image "$singularityImage"; then
        :
    else
        status=$?
        recordFailure "$recipeDirectory" "Singularity image validation" "$status"
        continue
    fi

    # Run the common basic test suite against the current SIF.
    if "$basicTests" \
        --recipe-dir "$recipePath" \
        --engine singularity \
        --image "$singularityImage"; then
        :
    else
        status=$?
        recordFailure "$recipeDirectory" "Singularity basic tests" "$status"
        continue
    fi

    # Submit the compile-tool test asynchronously. Successful launcher return
    # confirms submission only; the child job writes the authoritative result.
    if "$compileLauncher" \
        --submit-only \
        --recipe-dir "$recipePath" \
        --image "$singularityImage" \
        --partition "$setonixTestPartition"; then
        :
    else
        status=$?
        recordFailure "$recipeDirectory" "compile-tool test submission" "$status"
        continue
    fi

    # Submit the dependent tutorial preparation and solver jobs asynchronously.
    # The launcher manages their afterok dependency and persistent artifacts.
    if "$tutorialLauncher" \
        --submit-only \
        --recipe-dir "$recipePath" \
        --image "$singularityImage" \
        --partition "$setonixTestPartition"; then
        :
    else
        status=$?
        recordFailure "$recipeDirectory" "tutorial-test submission" "$status"
        continue
    fi

    # Reaching this point means all synchronous stages passed and both asynchronous
    # Setonix test workflows were accepted for submission.
    successfulRecipes+=("$recipeDirectory")
    echo "Completed synchronous stages and Setonix submissions: $recipeDirectory"
done

# =============================================================================
# Final summary and process exit status
# =============================================================================
# A PASS below means all synchronous stages passed and both Setonix workflows
# were submitted. It does not claim that the asynchronous child jobs completed.
echo
echo "================================================================"
echo "OpenFOAM multi-image build and test summary"
echo "================================================================"

echo "Successful recipes: ${#successfulRecipes[@]}"
for recipe in "${successfulRecipes[@]}"; do
    echo "  PASS: $recipe"
done

echo "Failed recipes: ${#failedRecipes[@]}"
for recipe in "${failedRecipes[@]}"; do
    echo "  FAIL: $recipe: ${failedStages[$recipe]}"
done

# Return a nonzero overall status when any selected recipe failed, while retaining
# the complete per-recipe summary above.
if (( ${#failedRecipes[@]} > 0 )); then
    echo "One or more recipes failed." >&2
    exit 1
fi

if [[ "$testsOnly" == true ]]; then
    echo "All local tests and Setonix test submissions completed successfully in tests-only mode."
else
    echo "All builds, local tests, and Setonix test submissions completed successfully."
fi
