#!/bin/bash -l
#SBATCH --job-name=buildAll_openfoam
#SBATCH --nodes=1
#SBATCH --ntasks=16
#SBATCH --time=24:00:00

# =============================================================================
# OpenFOAM multi-image build and test orchestrator
# =============================================================================
#
# Purpose
# -------
# Build, validate, and test a selected set of OpenFOAM container recipes in one
# Slurm allocation. Workflows that build, read, or test a Podman image require the
# Setonix Podman node. Existing-SIF-only testing does not require Podman. Recipe
# failures are isolated so later selected versions are still attempted.
#
# Execution layers and option prefixes
# ------------------------------------
# This script controls two distinct execution layers:
#
#   building-* options
#       Configure SIF creation performed synchronously inside this main Slurm job.
#       They do not affect later validation or functional testing.
#
#   testing-* options
#       Configure every Singularity-based validation/test of the resulting SIF
#       and the separate compile/tutorial jobs submitted by the test launchers.
#       The testing partition and reservation apply only to those child Slurm jobs,
#       not to this main build allocation.
#
# Main Slurm allocation
# ---------------------
# This script intentionally does not fix a partition or node in #SBATCH directives.
# Select the main allocation with sbatch according to the effective stage matrix.
#
# Workflows that build, read, or test a Podman image require the Podman node:
#
#   sbatch --partition=podman --nodelist=setonix-podman02 \
#      buildAll_openfoam.slurm.sh [script options]
#
# Existing-SIF-only testing can run in a suitable work reservation:
#
#   sbatch --partition=work --reservation=<reservation> \
#      buildAll_openfoam.slurm.sh --tests-only \
#      --workflow singularity-only [other script options]
#
# The --testing-partition and --testing-reservation options configure only the
# separate compile/tutorial jobs submitted later. They never select this main job.
#
# Normal workflow
# ---------------
# For every selected recipe, the script:
#   1. Cleans and validates the Podman build node.
#   2. Builds the Podman image.
#   3. Creates the SIF with --building-singularity-module.
#   4. Runs Podman validation and basic tests.
#   5. Runs SIF validation and basic tests with --testing-singularity-module.
#   6. Submits compile and tutorial tests with the configured testing partition,
#      reservation, and Singularity module. Submission success is not job success.
#
# Tests-only workflow
# -------------------
# With --tests-only, build stages are disabled within the selected workflow scope.
# The default full scope tests both existing images; container-only tests only the
# existing Podman image; singularity-only tests only the existing SIF. A building
# module override is rejected whenever the effective matrix does not build a SIF.
#
# Per-invocation recipe selection
# -------------------------------
# By default, the script processes the recipeDirectories array below. Use
# --only-directories with a comma-separated list to replace that selection for one
# submission while preserving the supplied order.
#
# Failure model
# -------------
# A failed stage skips the remaining stages for that recipe. Processing continues
# with the next selected recipe. The final process status is nonzero if any recipe
# failed, making the workflow suitable for automation and monitoring.
#
# Note: This script was originally designed by Alexis Espinosa at Pawsey
# Supercomputing Research Centre and built with the aid of M365 Copilot
# (GPT 5.6). This script has been fully reviewed and tested by Alexis Espinosa.
# =============================================================================

# Fail on unhandled command errors, unset variables, and failed pipeline stages.
# Expected per-recipe failures are caught explicitly so processing can continue.
set -euo pipefail

# =============================================================================
# Command-line mode
# =============================================================================
# Build-and-test mode is the default. Tests-only mode must be requested explicitly
# for each submission and cannot be enabled implicitly through the environment.
workflow="full"
workflowSpecified=false
testsOnly=false

# Empty means the configured recipeDirectories array remains authoritative.
onlyDirectoriesInput=""

# Building and testing settings are intentionally separate. This permits, for
# example, creating a SIF with one Singularity release and validating it with
# another without changing the main Slurm allocation.
buildingSingularityModule="singularity/4.3.5-mpi"
buildingSingularityModuleSpecified=false
testingSingularityModule="singularity/4.3.5-mpi"
testingPartition="work"
testingReservation=""

usage() {
    cat <<USAGE
Usage:
  sbatch $(basename "$0") [options]
  $(basename "$0") [options]

Recipe and mode options:
  --workflow <mode>
      Select the participating image types. Default: full

      full
          Podman image and Singularity SIF participate.

      container-only
          Only the Podman image participates. Singularity tests and functional
          compile/tutorial submissions are skipped.

      singularity-only
          Only the Singularity SIF participates. Podman validation/basic tests are
          skipped. Without --tests-only, the SIF is built from the existing
          Podman image before Singularity tests and functional submissions.

  --tests-only
      Disable every build stage within the selected workflow. If --workflow is
      omitted, this means full-scope testing of the existing Podman image and SIF.
      This modifier may be combined with --workflow container-only or
      --workflow singularity-only.

  --only-directories <list>
      Replace recipeDirectories for this invocation with a comma-separated list.
      Surrounding whitespace is ignored and the supplied order is preserved.

Building option:
  --building-singularity-module <module>
      Singularity module passed to openfoamSingularityBuild.sh for SIF creation.
      Default: singularity/4.3.5-mpi
      Used only by full and singularity-only workflows.

Testing options:
  --testing-singularity-module <module>
      Singularity module used for local SIF validation/basic tests and passed to
      both functional-test launchers.
      Default: singularity/4.3.5-mpi

  --testing-partition <name>
      Partition used by the separately submitted compile and tutorial jobs.
      Default: work

  --testing-reservation <name>
      Optional reservation used by the separately submitted compile and tutorial
      jobs. The option is omitted from launcher calls when no value is supplied.
      Default: none

General:
  --help, -h
      Show this help message and exit.

Examples:
  sbatch $(basename "$0") \
      --only-directories openfoam/v2412,openfoam-org/12 \
      --building-singularity-module singularity/4.3.5-mpi \
      --testing-singularity-module singularity/4.3.5-other \
      --testing-partition work \
      --testing-reservation PAWSEY_CPE26.03_CPU_TESTING

  sbatch $(basename "$0") \
      --tests-only \
      --only-directories openfoam-org/12 \
      --testing-singularity-module singularity/4.3.5-other
USAGE
}

# Parse only the explicitly supported options. Unknown arguments are rejected so
# misspelled modes cannot silently trigger a full build.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workflow)
            [[ $# -ge 2 && -n "$2" ]] || {
                echo "ERROR: --workflow requires full, container-only, or singularity-only." >&2
                exit 1
            }
            [[ "$workflowSpecified" == false ]] || {
                echo "ERROR: --workflow may be specified only once." >&2
                exit 1
            }
            workflow="$2"
            workflowSpecified=true
            shift 2
            ;;
        --tests-only)
            [[ "$testsOnly" == false ]] || {
                echo "ERROR: --tests-only may be specified only once." >&2
                exit 1
            }
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
        --building-singularity-module)
            [[ $# -ge 2 && -n "$2" ]] || {
                echo "ERROR: --building-singularity-module requires <module>." >&2
                exit 1
            }
            buildingSingularityModule="$2"
            buildingSingularityModuleSpecified=true
            shift 2
            ;;
        --testing-singularity-module)
            [[ $# -ge 2 && -n "$2" ]] || {
                echo "ERROR: --testing-singularity-module requires <module>." >&2
                exit 1
            }
            testingSingularityModule="$2"
            shift 2
            ;;
        --testing-partition)
            [[ $# -ge 2 && -n "$2" ]] || {
                echo "ERROR: --testing-partition requires <name>." >&2
                exit 1
            }
            testingPartition="$2"
            shift 2
            ;;
        --testing-reservation)
            [[ $# -ge 2 && -n "$2" ]] || {
                echo "ERROR: --testing-reservation requires <name>." >&2
                exit 1
            }
            testingReservation="$2"
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

# A build-only setting would otherwise be silently ignored in tests-only mode.
case "$workflow" in
    full|container-only|singularity-only)
        ;;
    *)
        echo "ERROR: Unsupported workflow '$workflow'." >&2
        echo "Valid workflows: full, container-only, singularity-only" >&2
        exit 1
        ;;
esac

# Derive the effective stages from the image scope first, then let --tests-only
# disable every build stage without changing which image types are tested.
buildContainer=false
buildSingularity=false
testContainer=false
testSingularity=false
submitFunctionalTests=false
case "$workflow" in
    full)
        buildContainer=true; buildSingularity=true
        testContainer=true; testSingularity=true; submitFunctionalTests=true
        ;;
    container-only)
        buildContainer=true; testContainer=true
        ;;
    singularity-only)
        buildSingularity=true; testSingularity=true; submitFunctionalTests=true
        ;;
esac
if [[ "$testsOnly" == true ]]; then
    buildContainer=false
    buildSingularity=false
fi

# Podman is required when the effective matrix builds a Podman image, builds a SIF
# from the existing local Podman image, or validates/tests a Podman image. The sole
# Podman-independent combination is --tests-only --workflow singularity-only.
requiresPodman=false
if [[ "$buildContainer" == true ||
      "$buildSingularity" == true ||
      "$testContainer" == true ]]; then
    requiresPodman=true
fi

# Reject a build-module override whenever the effective stage matrix does not
# create a SIF; otherwise the option would be accepted but silently ignored.
if [[ "$buildingSingularityModuleSpecified" == true && "$buildSingularity" != true ]]; then
    echo "ERROR: --building-singularity-module requires an active SIF build stage." >&2
    exit 1
fi

# =============================================================================
# User configuration: build parameters and recipe selection
# =============================================================================
# The image builders use Podman as their source container engine on this node.
engineToUse="podman"

# Setonix compile-tool and tutorial jobs are submitted asynchronously to this
# partition by the two test launchers.

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
    "openfoam/v2412"
    "openfoam/v2406"
    "openfoam/v2212"
    "openfoam/v2206"
    "openfoam/v2012"
    "openfoam-org/14"
    "openfoam-org/12"
    "openfoam-org/10"
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
tutorialLauncher="${setonixTestsDir}/openfoamTutorialTestLauncher.sh"

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

# Require only the scripts reached by the effective stage matrix. Podman cleanup
# and readiness tools are not prerequisites for existing-SIF-only testing.
requiredScripts=()
if [[ "$requiresPodman" == true ]]; then
    requiredScripts+=("$nodeCleaner" "$nodeChecker")
fi
[[ "$buildContainer" == true ]] && requiredScripts+=("$containerBuilder")
[[ "$buildSingularity" == true ]] && requiredScripts+=("$singularityBuilder")
if [[ "$testContainer" == true || "$testSingularity" == true ]]; then
    requiredScripts+=("$imageValidation" "$basicTests")
fi
if [[ "$submitFunctionalTests" == true ]]; then
    requiredScripts+=("$compileLauncher" "$tutorialLauncher")
fi

for script in "${requiredScripts[@]}"; do
    [[ -x "$script" ]] || {
        echo "ERROR: Script is not executable: $script" >&2
        exit 1
    }
done

# Initialize Podman only when the effective stage matrix uses it. Existing-SIF-only
# testing can therefore run on a normal work node without /container/setup_podman.sh.
if [[ "$requiresPodman" == true ]]; then
    if ! source /container/setup_podman.sh; then
        echo "ERROR: Failed to source /container/setup_podman.sh." >&2
        exit 1
    fi
    command -v podman >/dev/null 2>&1 || {
        echo "ERROR: podman is unavailable after sourcing /container/setup_podman.sh." >&2
        exit 1
    }
fi

# Convert each configured NAME=VALUE entry into the repeated option format
# accepted by both image builders.
buildArgumentOptions=()
for argument in "${buildArguments[@]}"; do
    buildArgumentOptions+=(--build-arg "$argument")
done

# Display both control axes and the effective stage matrix before processing.
echo "============================================================"
echo "Workflow scope: $workflow"
echo "Tests-only modifier: $([[ "$testsOnly" == true ]] && echo "yes" || echo "no")"
echo "Podman required: $requiresPodman"
echo "Build Podman image: $buildContainer"
echo "Build Singularity SIF: $buildSingularity"
echo "Test Podman image: $testContainer"
echo "Test Singularity SIF: $testSingularity"
echo "Submit compile/tutorial tests: $submitFunctionalTests"
echo "Building Singularity module: $([[ "$buildSingularity" == true ]] && echo "$buildingSingularityModule" || echo "not used")"
echo "Testing Singularity module: $([[ "$testSingularity" == true ]] && echo "$testingSingularityModule" || echo "not used")"
echo "Testing partition: $([[ "$submitFunctionalTests" == true ]] && echo "$testingPartition" || echo "not used")"
echo "Testing reservation: $([[ "$submitFunctionalTests" == true ]] && echo "${testingReservation:-none}" || echo "not used")"
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
declare -A recipeResultDetails=()

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

# Resolve exactly one existing Podman image for the selected recipe. The validated
# recipe path defines the repository and OpenFOAM-version tag prefix. Podman then
# supplies the complete existing tag, avoiding assumptions about configuration
# variable names or compiler, precision, label-size, MPI, and operating-system
# suffixes. More than one match is rejected rather than selecting an arbitrary
# image for validation.
resolvePodmanImageReference() {
    local recipePath="$1"
    local imageRepository=""
    local imageVersion=""
    local imagePrefix=""
    local -a matchingImages=()

    imageRepository=$(basename "$(dirname "$recipePath")")
    imageVersion=$(basename "$recipePath")
    imagePrefix="localhost/${imageRepository}:${imageVersion}-"

    mapfile -t matchingImages < <(
        podman images --format '{{.Repository}}:{{.Tag}}' |
            awk -v prefix="$imagePrefix" '
                index($0, prefix) == 1 && !seen[$0]++ {
                    print
                }
            '
    )

    case "${#matchingImages[@]}" in
        0)
            echo "ERROR: No existing Podman image matches '${imagePrefix}*'." >&2
            return 1
            ;;
        1)
            # Podman lists locally tagged images with a localhost/ prefix, but the
            # validation scripts compare the supplied reference with the configured
            # OpenFOAM repository name (for example openfoam:v2406-...). Podman
            # resolves that unqualified reference back to localhost automatically.
            podmanImage="${matchingImages[0]#localhost/}"
            ;;
        *)
            echo "ERROR: Multiple existing Podman images match '${imagePrefix}*':" >&2
            printf '  %s\n' "${matchingImages[@]}" >&2
            echo "ERROR: Remove the ambiguity before rerunning the workflow." >&2
            return 1
            ;;
    esac

    echo "Podman test reference: $podmanImage"
}

# =============================================================================
# Main workflow: build and test according to the selected stage matrix
# =============================================================================
testingLauncherArgs=(
    --partition "$testingPartition"
    --singularity-module "$testingSingularityModule"
    --submit-only
)
if [[ -n "$testingReservation" ]]; then
    testingLauncherArgs+=(--reservation "$testingReservation")
fi

for recipeDirectory in "${recipeDirectories[@]}"; do
    recipePath="${openfoamRoot}/${recipeDirectory}"
    podmanImage=""
    singularityImage=""
    recipeStageResults=()

    echo
    echo "================================================================"
    echo "Processing OpenFOAM recipe: $recipeDirectory"
    echo "Recipe path: $recipePath"
    echo "Workflow scope: $workflow"
    echo "Tests-only modifier: $testsOnly"
    echo "================================================================"

    if [[ ! -d "$recipePath" ]]; then
        recordFailure "$recipeDirectory" "recipe-directory validation" 1
        continue
    fi

    echo
    echo "$(basename "$0"): -----------------------------------------"
    echo "Podman build-node preparation"
    if [[ "$requiresPodman" == true ]]; then
        echo "Podman is required by the effective stage matrix."
        if ! prepareNode; then
            status=1
            recordFailure "$recipeDirectory" "Podman-node preparation" "$status"
            continue
        fi
    else
        echo "SKIP: Podman is not required by the effective stage matrix."
    fi

    echo
    echo "$(basename "$0"): -----------------------------------------"
    echo "Build-stage selection and execution"

    if [[ "$buildContainer" == true ]]; then
        if ! "$containerBuilder" --engine "$engineToUse" --recipe-dir "$recipePath"             "${buildArgumentOptions[@]}"; then
            status=1; recordFailure "$recipeDirectory" "Podman image build" "$status"; continue
        fi
        recipeStageResults+=("Podman image build: completed")
    else
        echo "SKIP: Podman image creation ($workflow workflow)."
    fi

    if [[ "$buildSingularity" == true ]]; then
        if ! "$singularityBuilder" --engine "$engineToUse" --recipe-dir "$recipePath"             --singularity-module "$buildingSingularityModule"             "${buildArgumentOptions[@]}"; then
            status=1; recordFailure "$recipeDirectory" "Singularity image build" "$status"; continue
        fi
        recipeStageResults+=("Singularity SIF build: completed")
    else
        echo "SKIP: Singularity SIF creation ($workflow workflow)."
    fi

    echo
    echo "$(basename "$0"): -----------------------------------------"
    echo "Podman image validation and basic tests"

    if [[ "$testContainer" == true ]]; then
        if ! resolvePodmanImageReference "$recipePath"; then
            status=1; recordFailure "$recipeDirectory" "Podman image reference resolution" "$status"; continue
        fi
        if ! "$imageValidation" --recipe-dir "$recipePath" --engine "$engineToUse" --image "$podmanImage"; then
            status=1; recordFailure "$recipeDirectory" "Podman image validation" "$status"; continue
        fi
        recipeStageResults+=("Podman image validation: passed")
        if ! "$basicTests" --recipe-dir "$recipePath" --engine "$engineToUse" --image "$podmanImage"; then
            status=1; recordFailure "$recipeDirectory" "Podman basic tests" "$status"; continue
        fi
        recipeStageResults+=("Podman basic tests: passed")
    else
        echo "SKIP: Podman validation and basic tests ($workflow workflow)."
    fi

    echo
    echo "$(basename "$0"): -----------------------------------------"
    echo "Singularity image validation and basic tests"

    if [[ "$testSingularity" == true ]]; then
        if ! resolveSingularityImage "$recipePath"; then
            status=1; recordFailure "$recipeDirectory" "Singularity image resolution" "$status"; continue
        fi
        if ! "$imageValidation" --recipe-dir "$recipePath" --engine singularity             --image "$singularityImage" --singularity-module "$testingSingularityModule"; then
            status=1; recordFailure "$recipeDirectory" "Singularity image validation" "$status"; continue
        fi
        recipeStageResults+=("Singularity image validation: passed")
        if ! "$basicTests" --recipe-dir "$recipePath" --engine singularity             --image "$singularityImage" --singularity-module "$testingSingularityModule"; then
            status=1; recordFailure "$recipeDirectory" "Singularity basic tests" "$status"; continue
        fi
        recipeStageResults+=("Singularity basic tests: passed")
    else
        echo "SKIP: Singularity validation and basic tests ($workflow workflow)."
    fi

    echo
    echo "$(basename "$0"): -----------------------------------------"
    echo "Compile-tool and tutorial workflow submission"

    if [[ "$submitFunctionalTests" == true ]]; then
        if ! "$compileLauncher" --recipe-dir "$recipePath" --image "$singularityImage"             "${testingLauncherArgs[@]}"; then
            status=1; recordFailure "$recipeDirectory" "compile-tool test submission" "$status"; continue
        fi
        recipeStageResults+=("Compile-tool workflow: submitted")
        if ! "$tutorialLauncher" --recipe-dir "$recipePath" --image "$singularityImage"             "${testingLauncherArgs[@]}"; then
            status=1; recordFailure "$recipeDirectory" "tutorial-test submission" "$status"; continue
        fi
        recipeStageResults+=("Tutorial workflow: submitted")
    else
        echo "SKIP: Compile and tutorial test submissions ($workflow workflow)."
    fi

    successfulRecipes+=("$recipeDirectory")
    recipeResultDetails["$recipeDirectory"]=$(printf '%s\n' "${recipeStageResults[@]}")
    if [[ "$submitFunctionalTests" == true ]]; then
        echo "Completed synchronous stages and Setonix submissions: $recipeDirectory"
    else
        echo "Completed synchronous stages: $recipeDirectory"
    fi
done

# =============================================================================
# Final summary and process exit status
# =============================================================================
# COMPLETED means every synchronous stage selected for that recipe succeeded.
# A submitted workflow is listed separately and is never presented as a pass.
echo
echo "================================================================"
echo "OpenFOAM multi-image build and test summary"
echo "================================================================"

echo "Recipes completed without synchronous failures: ${#successfulRecipes[@]}"
for recipe in "${successfulRecipes[@]}"; do
    echo "  COMPLETED: $recipe"
    while IFS= read -r stageResult; do
        [[ -n "$stageResult" ]] && echo "    - $stageResult"
    done <<< "${recipeResultDetails[$recipe]}"
done

echo
echo "Recipes with synchronous failures: ${#failedRecipes[@]}"
for recipe in "${failedRecipes[@]}"; do
    echo "  FAILED: $recipe"
    echo "    - ${failedStages[$recipe]}"
    echo "    - Later stages were skipped"
done

# Return a nonzero overall status when any selected recipe failed, while retaining
# the complete per-recipe summary above.
if (( ${#failedRecipes[@]} > 0 )); then
    echo
    echo "RESULT: One or more recipes had a synchronous build, validation, test, or submission failure." >&2
    exit 1
fi

if [[ "$submitFunctionalTests" == true ]]; then
    echo
    echo "RESULT: All selected synchronous stages completed successfully."
    echo "The compile-tool and tutorial workflows were submitted successfully, but their"
    echo "final Slurm results were not collected by this job and must be reviewed later."
else
    echo
    echo "RESULT: All selected synchronous build and local-test stages completed successfully."
fi
