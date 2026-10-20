#!/usr/bin/env bash

# =============================================================================
# OpenFOAM SHPC alias generator
# =============================================================================
#
# Purpose
# -------
# Generate deterministic SHPC alias YAML files from the executable commands
# provided by selected OpenFOAM Singularity images.
#
# Default safety policy
# ---------------------
# Before generating aliases, the script verifies that the current SIF passed
# all required Singularity-oriented tests and that every recorded test checksum
# matches the current SIF. Use --skip-test-validation only for controlled
# development or troubleshooting when this promotion gate must be bypassed.
#
# Inputs
# ------
# - Selected recipe directories listed in recipeDirectories.
# - One current SIF under each recipe's artifacts/singularity/latest directory.
# - Test status and checksum artifacts unless --skip-test-validation is used.
#
# Outputs
# -------
# - Timestamped generation artifacts under each recipe's artifacts/aliases tree.
# - A latest symbolic link updated only after successful alias generation.
# - A sorted <version>.yaml file suitable for use as an SHPC override file.
#
# Execution model
# ---------------
# Recipes are processed independently. A failure skips only the affected recipe;
# remaining selected recipes are still attempted. The script exits nonzero when
# any selected recipe fails or is ineligible.
#
# Note: This script was originally designed by Alexis Espinosa at Pawsey
# Supercomputing Research Centre and built with the aid of M365 Copilot
# (GPT 5.6). This script has been fully reviewed and tested by Alexis Espinosa.
# =============================================================================

# Fail on unhandled command errors, unset variables, and failed pipeline stages.
# Expected per-recipe failures are handled explicitly so processing can continue.
set -euo pipefail

# =============================================================================
# User configuration: OpenFOAM recipes to process
# =============================================================================
# This indexed Bash array is the primary user-editable selection. Comment out an
# entry to exclude that OpenFOAM version without changing the processing logic.
recipeDirectories=(
    # "openfoam/v2412"
    # "openfoam/v2406"
    # "openfoam/v2212"
    # "openfoam/v2206"
    # "openfoam/v2012"
    "openfoam/v2606"
    # "openfoam-org/10"
    # "openfoam-org/12"
    # "openfoam-org/14"
)

# =============================================================================
# Command-line interface
# =============================================================================
# Start with the standard Pawsey repository layout while allowing either path
# to be overridden explicitly on the command line.
repositoryRoot="${REPOSITORY_ROOT:-${MYSCRATCH:-}/pawsey-containers}"
openfoamRoot=""

# Test validation is enabled by default. The bypass must be requested explicitly
# for each invocation and is intentionally not available as an environment default.
skipTestValidation=false

usage() {
    cat <<USAGE
Usage:
  $(basename "$0") [--repository-root <directory>] [--skip-test-validation]
  $(basename "$0") [--openfoam-root <directory>] [--skip-test-validation]

Options:
  --repository-root <directory>
      Repository root containing setonix/applications/OpenFOAM.
      Default: \${REPOSITORY_ROOT:-\${MYSCRATCH}/pawsey-containers}

  --openfoam-root <directory>
      Explicit OpenFOAM project root. This overrides --repository-root.

  --skip-test-validation
      Bypass all test-status and SIF-checksum eligibility checks and generate
      aliases directly from the current SIF. Use only for controlled development
      or troubleshooting. SIF discovery and alias validation remain mandatory.

  --help, -h
      Show this help message and exit.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repository-root)
            [[ $# -ge 2 && -n "$2" ]] || {
                echo "ERROR: --repository-root requires <directory>." >&2
                exit 1
            }
            repositoryRoot="$2"
            shift 2
            ;;
        --openfoam-root)
            [[ $# -ge 2 && -n "$2" ]] || {
                echo "ERROR: --openfoam-root requires <directory>." >&2
                exit 1
            }
            openfoamRoot="$2"
            shift 2
            ;;
        --skip-test-validation)
            skipTestValidation=true
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

# Resolve the OpenFOAM project root. An explicit --openfoam-root value has
# authority; otherwise derive it from the configured repository root.
if [[ -z "$openfoamRoot" ]]; then
    [[ -n "$repositoryRoot" ]] || {
        echo "ERROR: MYSCRATCH is unset and no repository path was supplied." >&2
        exit 1
    }
    openfoamRoot="${repositoryRoot}/setonix/applications/OpenFOAM"
fi
openfoamRoot=$(realpath "$openfoamRoot")

# Validate the host-side prerequisites before any recipe is processed.
[[ -d "$openfoamRoot" ]] || {
    echo "ERROR: OpenFOAM project root does not exist: $openfoamRoot" >&2
    exit 1
}
command -v singularity >/dev/null 2>&1 || {
    echo "ERROR: singularity is not available in PATH." >&2
    exit 1
}
command -v sha256sum >/dev/null 2>&1 || {
    echo "ERROR: sha256sum is not available in PATH." >&2
    exit 1
}

# =============================================================================
# Shared state and reusable validation helpers
# =============================================================================
# Successful and failed recipes are retained separately for the final summary.
successfulRecipes=()
failedRecipes=()
declare -A failedStages=()

# Record a per-recipe failure without terminating processing of later recipes.
recordFailure() {
    local recipeDirectory="$1"
    local failedStage="$2"

    failedRecipes+=("$recipeDirectory")
    failedStages["$recipeDirectory"]="$failedStage"
    echo "SKIP: $recipeDirectory: $failedStage" >&2
}

# Read the first line of a required status file without trimming its content.
readSingleLine() {
    local filePath="$1"
    local value=""

    [[ -r "$filePath" ]] || return 1
    IFS= read -r value < "$filePath" || true
    printf '%s' "$value"
}

# Extract a 64-character SHA-256 checksum from supported test detail formats.
extractRecordedChecksum() {
    local detailsFile="$1"
    local checksum=""

    [[ -r "$detailsFile" ]] || return 1
    checksum=$(sed -n -E \
        -e 's/^Image SHA256:[[:space:]]*([[:xdigit:]]{64})[[:space:]]*$/\1/p' \
        -e 's/^SIF SHA256:[[:space:]]*([[:xdigit:]]{64})[[:space:]]*$/\1/p' \
        "$detailsFile" | head -n 1)
    [[ "$checksum" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s' "${checksum,,}"
}

# Select the most recently modified timestamped Singularity invocation directory.
# Generic latest links are not used here because Podman and Singularity tests can
# share the same category root.
newestSingularityInvocation() {
    local categoryRoot="$1"
    local invocation=""

    [[ -d "$categoryRoot" ]] || return 1
    invocation=$(find "$categoryRoot" -mindepth 1 -maxdepth 1 -type d \
        -name '*_singularity*' -printf '%T@\t%p\n' 2>/dev/null | \
        sort -nr | head -n 1 | cut -f2-)
    [[ -n "$invocation" && -d "$invocation" ]] || return 1
    printf '%s' "$invocation"
}

# Require one test stage to report SUCCESS against the current SIF checksum.
requireSuccessfulTest() {
    local testName="$1"
    local invocationDir="$2"
    local statusFileName="$3"
    local detailsFileName="$4"
    local expectedChecksum="$5"
    local status=""
    local recordedChecksum=""

    [[ -d "$invocationDir" ]] || {
        echo "  FAIL: $testName invocation is unavailable: $invocationDir" >&2
        return 1
    }

    status=$(readSingleLine "${invocationDir}/${statusFileName}") || {
        echo "  FAIL: $testName status file is missing: ${invocationDir}/${statusFileName}" >&2
        return 1
    }
    [[ "$status" == "SUCCESS" ]] || {
        echo "  FAIL: $testName status is '$status', expected 'SUCCESS'." >&2
        return 1
    }

    recordedChecksum=$(extractRecordedChecksum "${invocationDir}/${detailsFileName}") || {
        echo "  FAIL: $testName has no readable SIF checksum in ${invocationDir}/${detailsFileName}" >&2
        return 1
    }
    [[ "$recordedChecksum" == "$expectedChecksum" ]] || {
        echo "  FAIL: $testName was run against a different SIF." >&2
        echo "        Current SIF SHA256: $expectedChecksum" >&2
        echo "        Tested SIF SHA256:  $recordedChecksum" >&2
        return 1
    }

    echo "  PASS: $testName"
}

# Resolve exactly one readable SIF through artifacts/singularity/latest and
# calculate the immutable checksum used to correlate all test evidence.
resolveCurrentSif() {
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
    [[ -r "$singularityImage" ]] || {
        echo "ERROR: SIF is not readable: $singularityImage" >&2
        return 1
    }
    singularityChecksum=$(sha256sum "$singularityImage" | awk '{print tolower($1)}')
}

# Apply the complete promotion gate for the current image. All five required
# Singularity-oriented stages must succeed against the exact current SIF.
checkTestEligibility() {
    local recipePath="$1"
    local checksum="$2"
    local imageValidationInvocation=""
    local basicInvocation=""
    local compileInvocation="${recipePath}/artifacts/tests/compile-tool/latest"
    local tutorialInvocation="${recipePath}/artifacts/tests/tutorial/latest"
    local failed=0

    imageValidationInvocation=$(newestSingularityInvocation \
        "${recipePath}/artifacts/tests/image-validation") || {
            echo "  FAIL: No Singularity image-validation invocation was found." >&2
            failed=1
        }
    basicInvocation=$(newestSingularityInvocation \
        "${recipePath}/artifacts/tests/basic") || {
            echo "  FAIL: No Singularity basic-test invocation was found." >&2
            failed=1
        }

    if [[ -n "$imageValidationInvocation" ]]; then
        requireSuccessfulTest \
            "Singularity image validation" \
            "$imageValidationInvocation" \
            "status.txt" \
            "validation-details.txt" \
            "$checksum" || failed=1
    fi

    if [[ -n "$basicInvocation" ]]; then
        requireSuccessfulTest \
            "Singularity basic test" \
            "$basicInvocation" \
            "status.txt" \
            "test-details.txt" \
            "$checksum" || failed=1
    fi

    requireSuccessfulTest \
        "Compile-tool test" \
        "$compileInvocation" \
        "compileTool.status.txt" \
        "compileTool-details.txt" \
        "$checksum" || failed=1

    requireSuccessfulTest \
        "Tutorial preparation" \
        "$tutorialInvocation" \
        "prepareFoam.status.txt" \
        "test-details.txt" \
        "$checksum" || failed=1

    requireSuccessfulTest \
        "Tutorial solver" \
        "$tutorialInvocation" \
        "runFoam.status.txt" \
        "test-details.txt" \
        "$checksum" || failed=1

    (( failed == 0 ))
}

# Discover project scripts and compiled applications from the image. Compiled
# applications take precedence if the same alias name also exists in the project
# script directory.
# Execute a self-contained discovery program inside the SIF. The container emits
# tab-separated alias, priority, and absolute executable-path records to stdout.
discoverAliases() {
    local imagePath="$1"
    local recordsFile="$2"

    singularity exec "$imagePath" bash -s > "$recordsFile" <<'CONTAINER_SCRIPT'
set -euo pipefail

[[ -n "${WM_PROJECT_DIR:-}" ]] || {
    echo "ERROR: WM_PROJECT_DIR is unset in the image." >&2
    exit 1
}
[[ -n "${FOAM_APPBIN:-}" ]] || {
    echo "ERROR: FOAM_APPBIN is unset in the image." >&2
    exit 1
}

emitExecutables() {
    local priority="$1"
    local directory="$2"
    local executable=""

    [[ -d "$directory" ]] || return 0
    while IFS= read -r -d '' executable; do
        printf '%s\t%s\t%s\n' \
            "$(basename "$executable")" \
            "$priority" \
            "$executable"
    done < <(find "$directory" -mindepth 1 -maxdepth 1 \
        -type f -executable -print0)
}

emitExecutables 10 "${WM_PROJECT_DIR}/bin"
emitExecutables 20 "$FOAM_APPBIN"
CONTAINER_SCRIPT

    [[ -s "$recordsFile" ]] || {
        echo "ERROR: No executable aliases were discovered in $imagePath" >&2
        return 1
    }
}

# Convert raw discovery records into a deterministic SHPC aliases YAML file.
# Compiled applications have higher priority than project-level command scripts.
writeAliasYaml() {
    local recordsFile="$1"
    local outputFile="$2"
    local selectedFile="${outputFile}.selected.$$"
    local aliasName=""
    local executablePath=""

    # Sort by alias and then priority. Keep the highest-priority path for each
    # alias while reporting conflicting paths for traceability.
    sort -t $'\t' -k1,1 -k2,2nr -k3,3 "$recordsFile" | \
        awk -F '\t' '
            NF != 3 { exit 2 }
            !seen[$1]++ {
                selectedPath[$1] = $3
                print $1 "\t" $3
                next
            }
            selectedPath[$1] != $3 {
                print "NOTICE: duplicate alias " $1 " also maps to " $3 > "/dev/stderr"
            }
        ' > "$selectedFile"

    [[ -s "$selectedFile" ]] || {
        rm -f "$selectedFile"
        echo "ERROR: Alias selection produced no records." >&2
        return 1
    }

    {
        echo "aliases:"
        while IFS=$'\t' read -r aliasName executablePath; do
            [[ "$aliasName" =~ ^[A-Za-z0-9_.+-]+$ ]] || {
                echo "ERROR: Unsupported YAML alias name: $aliasName" >&2
                rm -f "$selectedFile"
                return 1
            }
            [[ "$executablePath" == /* ]] || {
                echo "ERROR: Alias path is not absolute: $executablePath" >&2
                rm -f "$selectedFile"
                return 1
            }
            printf '  %s: %s\n' "$aliasName" "$executablePath"
        done < "$selectedFile"
    } > "$outputFile"

    rm -f "$selectedFile"
    [[ $(head -n 1 "$outputFile") == "aliases:" ]] || return 1
    (( $(wc -l < "$outputFile") > 1 )) || return 1
}

# =============================================================================
# Main workflow: validate and generate aliases for each selected recipe
# =============================================================================
echo "============================================================"
echo "OpenFOAM SHPC alias generation"
echo "OpenFOAM root: $openfoamRoot"
if [[ "$skipTestValidation" == true ]]; then
    echo "Test validation: BYPASSED"
    echo "WARNING: Test status and SIF checksum evidence will not be checked."
else
    echo "Test validation: REQUIRED"
fi
echo "============================================================"

# Process each selected recipe independently so one failure does not suppress
# eligibility checks or alias generation for the remaining versions.
for recipeDirectory in "${recipeDirectories[@]}"; do
    recipePath="${openfoamRoot}/${recipeDirectory}"
    versionName="${recipeDirectory##*/}"
    singularityImage=""
    singularityChecksum=""

    echo
    echo "================================================================"
    echo "Processing OpenFOAM recipe: $recipeDirectory"
    echo "Recipe path: $recipePath"
    echo "================================================================"

    if [[ ! -d "$recipePath" ]]; then
        recordFailure "$recipeDirectory" "recipe directory does not exist"
        continue
    fi

    if ! resolveCurrentSif "$recipePath"; then
        recordFailure "$recipeDirectory" "could not resolve the current SIF"
        continue
    fi
    echo "Current SIF: $singularityImage"
    echo "Current SIF SHA256: $singularityChecksum"

    # Enforce the promotion gate unless the caller explicitly selected the
    # development bypass. The bypass does not relax SIF or YAML validation.
    if [[ "$skipTestValidation" == true ]]; then
        echo "WARNING: Bypassing test-result validation for $recipeDirectory."
    else
        echo "Checking required test results."
        if ! checkTestEligibility "$recipePath" "$singularityChecksum"; then
            recordFailure "$recipeDirectory"                 "required tests are missing, failed, incomplete, or stale"
            continue
        fi
    fi

    # Create a new timestamped artifact transaction. The latest link is not
    # changed until discovery, YAML generation, and metadata writing all succeed.
    aliasesRoot="${recipePath}/artifacts/aliases"
    invocationTimestamp=$(date '+%Y%m%dT%H%M%S%z')
    invocationName="${invocationTimestamp}_singularity"
    invocationDir="${aliasesRoot}/${invocationName}"
    latestLink="${aliasesRoot}/latest"
    temporaryRecords="${invocationDir}/alias-records.tsv"
    aliasFile="${invocationDir}/${versionName}.yaml"
    detailsFile="${invocationDir}/generation-details.txt"
    statusFile="${invocationDir}/status.txt"

    # Protect unrelated user content by refusing to replace a non-symlink
    # object at the reserved latest path.
    mkdir -p "$aliasesRoot"
    [[ ! -e "$latestLink" || -L "$latestLink" ]] || {
        recordFailure "$recipeDirectory" "aliases/latest exists and is not a symbolic link"
        continue
    }
    mkdir "$invocationDir" || {
        recordFailure "$recipeDirectory" "could not create alias artifact directory"
        continue
    }
    printf '%s\n' RUNNING > "$statusFile"

    # Discover executable commands inside the current image and retain the raw
    # records only until the final YAML has been validated.
    if ! discoverAliases "$singularityImage" "$temporaryRecords"; then
        printf '%s\n' FAILED > "$statusFile"
        recordFailure "$recipeDirectory" "executable discovery failed"
        continue
    fi

    # Transform the discovery records into a stable, sorted SHPC override file.
    if ! writeAliasYaml "$temporaryRecords" "$aliasFile"; then
        printf '%s\n' FAILED > "$statusFile"
        recordFailure "$recipeDirectory" "alias YAML generation failed"
        continue
    fi

    # Record provenance for the generated file before atomically promoting this
    # invocation as the latest successful alias artifact.
    aliasCount=$(( $(wc -l < "$aliasFile") - 1 ))
    {
        echo "Result: SUCCESS"
        echo "Recipe: $recipeDirectory"
        echo "SIF image: $singularityImage"
        echo "SIF SHA256: $singularityChecksum"
        echo "Alias file: $aliasFile"
        echo "Alias count: $aliasCount"
        echo "Test validation bypassed: $skipTestValidation"
        echo "Generated: $invocationTimestamp"
    } > "$detailsFile"
    printf '%s\n' SUCCESS > "$statusFile"
    ln -sfn "$invocationName" "$latestLink"

    rm -f "$temporaryRecords"
    successfulRecipes+=("$recipeDirectory")
    echo "PASS: Generated $aliasCount aliases at $aliasFile"
done

# =============================================================================
# Final summary and process exit status
# =============================================================================
# A nonzero final status makes skipped or failed recipes visible to automation,
# while the complete summary preserves the outcome for every selected version.
echo
echo "================================================================"
echo "OpenFOAM SHPC alias-generation summary"
echo "================================================================"
if [[ "$skipTestValidation" == true ]]; then
    echo "Test validation: BYPASSED"
else
    echo "Test validation: REQUIRED"
fi
echo "Successful recipes: ${#successfulRecipes[@]}"
for recipeDirectory in "${successfulRecipes[@]}"; do
    echo "  PASS: $recipeDirectory"
done

echo "Failed or ineligible recipes: ${#failedRecipes[@]}"
for recipeDirectory in "${failedRecipes[@]}"; do
    echo "  SKIP: $recipeDirectory: ${failedStages[$recipeDirectory]}"
done

if (( ${#failedRecipes[@]} > 0 )); then
    echo "One or more selected recipes were not eligible for alias generation." >&2
    exit 1
fi

echo "All selected OpenFOAM SHPC alias files were generated successfully."
