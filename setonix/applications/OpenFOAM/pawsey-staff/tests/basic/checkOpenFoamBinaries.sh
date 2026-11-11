#!/usr/bin/env bash
# ==============================================================================
# OpenFOAM installation completeness checker
# ==============================================================================
#
# Purpose
# -------
# Audit the OpenFOAM environment currently active in this shell and compare the
# application targets declared by its source tree with the executable applications
# present in FOAM_APPBIN.
#
# The script is deliberately independent of any module system or container engine.
# Run it after the OpenFOAM environment has been initialized, for example:
#
#   module load openfoam/2312
#   ./checkOpenFoamBinaries.sh -o openfoam-installation-check
#
#   singularity shell openfoam.sif
#   ./checkOpenFoamBinaries.sh -o openfoam-installation-check
#
#   podman run --rm -it openfoam:v2312
#   ./checkOpenFoamBinaries.sh -o openfoam-installation-check
#
# Output
# ------
# The required -o option names a new output directory. Reusing an existing directory
# requires --overwrite, which removes only known audit files before running.
# Relative paths are interpreted from the caller's current working directory.
# The directory contains only the human-readable report. Intermediate inventories
# and evidence files are kept in a temporary workspace and removed on exit.
#
# Targets declared under applications/test are excluded from production-health
# totals and reported separately as informational source-tree test targets. Targets
# named Test-* outside that directory are classified the same way for compatibility.
#
# Exit status
# -----------
#   0  All solver targets and core applications are installed.
#   1  Invalid input/environment, audit failure, missing solver, or missing core app.
#
# Missing non-test, non-solver applications are reported as warnings because some
# targets can depend on optional components or build choices.
#
# Note:
#   The initial version of this script was developed at the Pawsey Supercomputing
#   Research Centre by Alexis Espinosa, with support from Microsoft 365 Copilot
#   (GPT-5.6 Sol). Alexis Espinosa subsequently reviewed and tested the
#   complete script.

set -euo pipefail

# Use one deterministic locale for all child commands. The checker relies on sorted
# inventories being ordered consistently for sort and comm set operations.
export LC_ALL=C

# ------------------------------------------------------------------------------
# Initial settings
# ------------------------------------------------------------------------------
thisScript=$(basename "$0")
outputDir=""
overwrite=false

# Keep progress diagnostics separate from the report written to stdout/output files.
progress() {
   printf '%s\n' "$*" >&2
}

# These established applications provide a small cross-category operational check.
# The complete solver comparison below remains the authoritative solver check.
coreApplications=(
   blockMesh
   snappyHexMesh
   decomposePar
   reconstructPar
   postProcess
   foamToVTK
)

# Verified source-only executable targets that cannot be classified reliably from
# the source/build orchestration itself. Keep this as a conservative escape hatch.
sourceOnlyApplications=()

# Verified optional-dependency targets that cannot yet be classified reliably from
# source/build orchestration. Keep this as a conservative fallback only.
optionalDependencyApplications=()

# ------------------------------------------------------------------------------
# Command-line help
# ------------------------------------------------------------------------------
usage() {
   cat <<USAGE
Usage:
  $thisScript -o <output-directory> [--overwrite]
  $thisScript --output <output-directory> [--overwrite]
  $thisScript --help

Options:
  -o, --output <directory>  Directory in which the audit report is written.
                            Relative paths are resolved from the current directory.
  --overwrite               Allow an existing output directory; remove previous
                            audit files only, preserving unrelated files.
  -h, --help                Show this help message and exit.

Prerequisite:
  Run this script only after the OpenFOAM environment has been initialized.
  WM_PROJECT_DIR and FOAM_APPBIN must both be defined.
USAGE
}

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
   case "$1" in
      -o|--output)
         [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a directory argument" >&2; usage >&2; exit 1; }
         outputDir=$2
         shift 2
         ;;
      --overwrite)
         overwrite=true
         shift
         ;;
      -h|--help)
         usage
         exit 0
         ;;
      *)
         echo "ERROR: Unknown argument: $1" >&2
         usage >&2
         exit 1
         ;;
   esac
done

[[ -n "$outputDir" ]] || { echo "ERROR: -o or --output is required" >&2; usage >&2; exit 1; }
if [[ -e "$outputDir" || -L "$outputDir" ]]; then
   [[ -d "$outputDir" ]] || { echo "ERROR: Output path is not a directory: $outputDir" >&2; exit 1; }
   [[ "$overwrite" == true ]] || {
      echo "ERROR: Output directory already exists: $outputDir. Use --overwrite to reuse it." >&2
      exit 1
   }
fi

# ------------------------------------------------------------------------------
# Validate the active OpenFOAM environment
# ------------------------------------------------------------------------------
[[ -n "${WM_PROJECT_DIR:-}" ]] || { echo "ERROR: WM_PROJECT_DIR is not set. Initialize OpenFOAM first." >&2; exit 1; }
[[ -n "${FOAM_APPBIN:-}" ]] || { echo "ERROR: FOAM_APPBIN is not set. Initialize OpenFOAM first." >&2; exit 1; }
[[ -d "$WM_PROJECT_DIR/applications" ]] || { echo "ERROR: OpenFOAM applications tree not found: $WM_PROJECT_DIR/applications" >&2; exit 1; }
[[ -d "$FOAM_APPBIN" ]] || { echo "ERROR: FOAM_APPBIN directory not found: $FOAM_APPBIN" >&2; exit 1; }

mkdir -p -- "$outputDir"
outputDir=$(cd "$outputDir" && pwd -P)

# ------------------------------------------------------------------------------
# Output report and disposable working files
# ------------------------------------------------------------------------------
# The requested output directory contains only the final human-readable report.
# Sorted inventories and evidence files are implementation details kept in a private
# temporary workspace and removed automatically when the checker exits.
reportFile="${outputDir}/openfoam-installation-report.txt"
workDir=$(mktemp -d "${TMPDIR:-/tmp}/checkOpenFoamBinaries.XXXXXX")
trap 'rm -rf -- "$workDir"' EXIT

expectedApplicationsFile="${workDir}/expected-applications.txt"
targetSourceMapFile="${workDir}/target-source-map.txt"
installedApplicationsFile="${workDir}/installed-applications.txt"
expectedProductionApplicationsFile="${workDir}/expected-production-applications.txt"
missingProductionApplicationsFile="${workDir}/missing-production-applications.txt"
sourceOnlyApplicationsFile="${workDir}/source-only-applications.txt"
optionalDependencyApplicationsFile="${workDir}/optional-dependency-applications.txt"
buildIntentionEvidenceFile="${workDir}/build-intention-evidence.txt"
optionalDependencyEvidenceFile="${workDir}/optional-dependency-evidence.txt"
buildGateEvidenceFile="${workDir}/build-gate-evidence.txt"
authoritativeBuildEvidenceFile="${workDir}/authoritative-build-evidence.txt"
expectedSolversFile="${workDir}/expected-solvers.txt"
installedSolversFile="${workDir}/installed-solvers.txt"
missingSolversFile="${workDir}/missing-solvers.txt"
expectedTestTargetsFile="${workDir}/expected-test-targets.txt"
installedTestTargetsFile="${workDir}/installed-test-targets.txt"
notInstalledTestTargetsFile="${workDir}/not-installed-test-targets.txt"
coreApplicationsFile="${workDir}/core-application-checks.txt"

if [[ "$overwrite" == true ]]; then
   [[ ! -d "$reportFile" ]] || {
      echo "ERROR: Refusing to remove a directory at the report file path: $reportFile" >&2
      exit 1
   }
   rm -f -- "$reportFile"
fi

# ------------------------------------------------------------------------------
# Helper: extract executable names declared by OpenFOAM Make/files files
# ------------------------------------------------------------------------------
# OpenFOAM application targets normally declare an EXE assignment in Make/files.
# The final basename is the executable name expected in FOAM_APPBIN. sort -u keeps
# aliases or duplicate declarations from inflating the counts.
extract_expected_targets() {
   local sourceRoot=$1

   find "$sourceRoot" -type f -path '*/Make/files' -print0 \
      | xargs -0 -r grep -hE '^[[:space:]]*EXE[[:space:]]*=' \
      | sed -E 's/^[[:space:]]*EXE[[:space:]]*=[[:space:]]*//' \
      | while IFS= read -r target; do
           basename "$target"
        done \
      | sort -u
}

# ------------------------------------------------------------------------------
# Helpers: supporting build-intention and optional historical evidence
# ------------------------------------------------------------------------------
# Map each EXE target to the source directory that declares it.
extract_target_source_map() {
   local root=$1
   find "$root" -type f -path '*/Make/files' -print0 \
      | xargs -0 awk -v project="$WM_PROJECT_DIR/" '
         FNR == 1 { source=FILENAME; sub(/\/Make\/files$/, "", source); sub("^" project, "", source) }
         /^[[:space:]]*EXE[[:space:]]*=/ {
            target=$0; sub(/^[^=]*=[[:space:]]*/, "", target); sub(/^.*\//, "", target); gsub(/[[:space:]]+$/, "", target)
            if (target != "") print target "\t" source
         }
      ' | sort -u
}

# Trace only missing production targets. Direct build commands take precedence. If a
# target has no direct invocation, walk upwards from its source directory and inspect
# parent Allwmake files for active or commented recursive subtree selection.
collect_build_intention_evidence() {
   local missingFile=$1 sourceMap=$2
   local application sourcePath allwmake line trimmed command lineNo ancestor parent base
   local directFound pathFound

   local investigationCount investigationIndex
   investigationCount=$(wc -l < "$missingFile")
   investigationIndex=0

   : > "$buildIntentionEvidenceFile"
   while IFS= read -r application; do
      ((investigationIndex += 1))
      progress "      [${investigationIndex}/${investigationCount}] Investigating ${application}..."
      sourcePath=$(awk -F '\t' -v t="$application" '$1 == t {print $2; exit}' "$sourceMap")
      directFound=false
      pathFound=false

      while IFS= read -r -d '' allwmake; do
         lineNo=0
         while IFS= read -r line || [[ -n "$line" ]]; do
            ((lineNo += 1))
            grep -qwF -- "$application" <<< "$line" || continue
            trimmed=${line#"${line%%[![:space:]]*}"}
            if [[ "$trimmed" == \#* ]]; then
               command=${trimmed#\#}; command=${command#"${command%%[![:space:]]*}"}
               if [[ "$command" =~ (^|[[:space:]])wmake([[:space:]]|$) ]] || [[ "$command" == *"$application"* && "$command" == *"Allwmake"* ]]; then
                  printf 'DIRECT-COMMENTED\t%s\t%s\t%s:%d\t%s\n' "$application" "$sourcePath" "${allwmake#$WM_PROJECT_DIR/}" "$lineNo" "$trimmed" >> "$buildIntentionEvidenceFile"
                  directFound=true
               fi
            elif [[ "$trimmed" =~ (^|[[:space:]])wmake([[:space:]]|$) ]] || [[ "$trimmed" == *"$application"* && "$trimmed" == *"Allwmake"* ]]; then
               printf 'DIRECT-ACTIVE\t%s\t%s\t%s:%d\t%s\n' "$application" "$sourcePath" "${allwmake#$WM_PROJECT_DIR/}" "$lineNo" "$trimmed" >> "$buildIntentionEvidenceFile"
               directFound=true
            fi
         done < "$allwmake"
      done < <(find "$WM_PROJECT_DIR" -type f -name Allwmake -print0)

      if [[ "$directFound" == false && -n "$sourcePath" ]]; then
         ancestor=$sourcePath
         while [[ "$ancestor" == */* ]]; do
            base=${ancestor##*/}; parent=${ancestor%/*}; allwmake="$WM_PROJECT_DIR/$parent/Allwmake"
            if [[ -f "$allwmake" ]]; then
               lineNo=0
               while IFS= read -r line || [[ -n "$line" ]]; do
                  ((lineNo += 1))
                  grep -qwF -- "$base" <<< "$line" || continue
                  trimmed=${line#"${line%%[![:space:]]*}"}
                  if [[ "$trimmed" == \#* ]]; then
                     command=${trimmed#\#}; command=${command#"${command%%[![:space:]]*}"}
                     if [[ "$command" =~ wmake[[:space:]].*-all ]] || [[ "$command" == *"$base/Allwmake"* ]]; then
                        printf 'SUBTREE-COMMENTED\t%s\t%s\t%s:%d\t%s\n' "$application" "$sourcePath" "${allwmake#$WM_PROJECT_DIR/}" "$lineNo" "$trimmed" >> "$buildIntentionEvidenceFile"
                        pathFound=true; break
                     fi
                  elif [[ "$trimmed" =~ wmake[[:space:]].*-all ]] || [[ "$trimmed" == *"$base/Allwmake"* ]]; then
                     printf 'SUBTREE-ACTIVE\t%s\t%s\t%s:%d\t%s\n' "$application" "$sourcePath" "${allwmake#$WM_PROJECT_DIR/}" "$lineNo" "$trimmed" >> "$buildIntentionEvidenceFile"
                     pathFound=true; break
                  fi
               done < "$allwmake"
            fi
            [[ "$pathFound" == true ]] && break
            ancestor=$parent
         done
      fi

      if [[ "$directFound" == false && "$pathFound" == false ]]; then
         printf 'UNRESOLVED\t%s\t%s\t-\tNo static direct or parent-subtree selection identified\n' "$application" "$sourcePath" >> "$buildIntentionEvidenceFile"
      fi
   done < "$missingFile"
}

# Expand only the OpenFOAM path variables supported by the safe filesystem-gate
# analysis. Never eval arbitrary expressions from Allwmake.
expand_safe_openfoam_path() {
   local expression=$1
   expression=${expression%\"}; expression=${expression#\"}
   expression=${expression//\$FOAM_EXT_LIBBIN/${FOAM_EXT_LIBBIN:-}}
   expression=${expression//\$\{FOAM_EXT_LIBBIN\}/${FOAM_EXT_LIBBIN:-}}
   expression=${expression//\$FOAM_LIBBIN/${FOAM_LIBBIN:-}}
   expression=${expression//\$\{FOAM_LIBBIN\}/${FOAM_LIBBIN:-}}
   expression=${expression//\$WM_THIRD_PARTY_DIR/${WM_THIRD_PARTY_DIR:-}}
   expression=${expression//\$\{WM_THIRD_PARTY_DIR\}/${WM_THIRD_PARTY_DIR:-}}
   printf '%s\n' "$expression"
}

# Recognize simple build gates without executing source code:
#   [ -e PATH ] / [ -d PATH ] around a local wmake
#   [ -n "$VAR" ] around invocation of the target's parent Allwmake.
collect_simple_build_gate_evidence() {
   local missingFile=$1 sourceMap=$2
   local application sourcePath localAllwmake parentDir childName parentAllwmake
   local buildLine condition record testType expression expanded lineNo variableName value

   : > "$buildGateEvidenceFile"
   while IFS= read -r application; do
      sourcePath=$(awk -F '\t' -v t="$application" '$1 == t {print $2; exit}' "$sourceMap")
      [[ -n "$sourcePath" ]] || continue

      # Check both an application-local Allwmake (eg foamToTecplot360) and the
      # immediate parent Allwmake (eg Optional/Allwmake for ccm26ToFoam).
      for localAllwmake in "$WM_PROJECT_DIR/$sourcePath/Allwmake" "$WM_PROJECT_DIR/${sourcePath%/*}/Allwmake"; do
         [[ -f "$localAllwmake" ]] || continue
         if [[ "$localAllwmake" == "$WM_PROJECT_DIR/$sourcePath/Allwmake" ]]; then
            buildLine=$(grep -nE "^[[:space:]]*wmake([[:space:]].*)?([[:space:]]${application}([[:space:]]|$)|[[:space:]]\\\$targetType[[:space:]]*$)" "$localAllwmake" | head -n1 | cut -d: -f1 || true)
         else
            buildLine=$(grep -nE "^[[:space:]]*wmake([[:space:]].*)?[[:space:]]${application}([[:space:]]|$)" "$localAllwmake" | head -n1 | cut -d: -f1 || true)
         fi
         [[ -n "$buildLine" ]] || continue

         condition=$(sed -n "1,${buildLine}p" "$localAllwmake" | grep -nE '^[[:space:]]*if[[:space:]]+\[[[:space:]]+-(e|d)[[:space:]]+[^]]+[[:space:]]*\]' | tail -n1 || true)
         [[ -n "$condition" ]] || continue
         lineNo=${condition%%:*}; record=${condition#*:}
         testType=$(sed -E 's/.*\[[[:space:]]+-([ed])[[:space:]].*/\1/' <<< "$record")
         expression=$(sed -E 's/.*\[[[:space:]]+-[ed][[:space:]]+([^]]+)[[:space:]]*\].*/\1/' <<< "$record")
         expression=${expression% }; expanded=$(expand_safe_openfoam_path "$expression")
         if [[ "$expanded" == /* ]] && { { [[ "$testType" == e ]] && [[ ! -e "$expanded" ]]; } || { [[ "$testType" == d ]] && [[ ! -d "$expanded" ]]; }; }; then
            printf 'DEPENDENCY-GATE-FALSE\t%s\t%s\t%s\t%s:%s\t%s\n' "$application" "$sourcePath" "$expanded" "${localAllwmake#$WM_PROJECT_DIR/}" "$lineNo" "-$testType" >> "$buildGateEvidenceFile"
            break
         fi
      done

      # Recognize the OpenFOAM isDarwin platform predicate around a direct build.
      localAllwmake="$WM_PROJECT_DIR/${sourcePath%/*}/Allwmake"
      if [[ -f "$localAllwmake" ]]; then
         buildLine=$(grep -nE "^[[:space:]]*wmake([[:space:]].*)?[[:space:]]${application}([[:space:]]|$)" "$localAllwmake" | head -n1 | cut -d: -f1 || true)
         if [[ -n "$buildLine" ]]; then
            condition=$(sed -n "1,${buildLine}p" "$localAllwmake" | grep -nE '^[[:space:]]*if[[:space:]]+isDarwin([[:space:]]|$)' | tail -n1 || true)
            if [[ -n "$condition" && "${WM_ARCH:-}" != darwin* ]]; then
               lineNo=${condition%%:*}
               printf 'PLATFORM-GATE-FALSE\t%s\t%s\tisDarwin\t%s:%s\tWM_ARCH=%s\n' "$application" "$sourcePath" "${localAllwmake#$WM_PROJECT_DIR/}" "$lineNo" "${WM_ARCH:-unset}" >> "$buildGateEvidenceFile"
            fi
         fi
      fi

      parentDir=${sourcePath%/*}; childName=${parentDir##*/}; parentAllwmake="$WM_PROJECT_DIR/${parentDir%/*}/Allwmake"
      if [[ -f "$parentAllwmake" ]]; then
         buildLine=$(grep -nF "$childName/Allwmake" "$parentAllwmake" | grep -vE '^[^:]+:[[:space:]]*#' | head -n1 | cut -d: -f1 || true)
         if [[ -n "$buildLine" ]]; then
            condition=$(sed -n "1,${buildLine}p" "$parentAllwmake" | grep -nE '^[[:space:]]*if[[:space:]]+\[[[:space:]]+-n[[:space:]]+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[[:space:]]*\]' | tail -n1 || true)
            if [[ -n "$condition" ]]; then
               lineNo=${condition%%:*}; record=${condition#*:}
               variableName=$(sed -E 's/.*\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?.*/\1/' <<< "$record")
               value=${!variableName-}
               if [[ -z "$value" ]]; then
                  printf 'ENV-GATE-FALSE\t%s\t%s\t%s\t%s:%s\tempty\n' "$application" "$sourcePath" "$variableName" "${parentAllwmake#$WM_PROJECT_DIR/}" "$lineNo" >> "$buildGateEvidenceFile"
               fi
            fi
         fi
      fi
   done < "$missingFile"
}

# Recognize the conservative optional-dependency pattern used by OpenFOAM CCM:
# an active target build inside an "if findLibrary $FOAM_LIBBIN/<library>" block.
# Only this safely testable pattern is auto-classified; anything less explicit remains
# a production target requiring review.
collect_optional_dependency_evidence() {
   local missingFile=$1 sourceMap=$2
   local application sourcePath allwmake dependency conditionLine buildLine

   : > "$optionalDependencyEvidenceFile"
   [[ -n "${FOAM_LIBBIN:-}" ]] || return 0
   while IFS= read -r application; do
      sourcePath=$(awk -F '\t' -v t="$application" '$1 == t {print $2; exit}' "$sourceMap")
      [[ -n "$sourcePath" ]] || continue
      allwmake="$WM_PROJECT_DIR/${sourcePath%/*}/Allwmake"
      [[ -f "$allwmake" ]] || continue

      buildLine=$(grep -nE "^[[:space:]]*wmake([[:space:]].*)?[[:space:]]${application}([[:space:]]|$)" "$allwmake" | head -n1 | cut -d: -f1 || true)
      [[ -n "$buildLine" ]] || continue
      conditionLine=$(sed -n "1,${buildLine}p" "$allwmake" | grep -nE '^[[:space:]]*if[[:space:]]+findLibrary[[:space:]]+"?\$FOAM_LIBBIN/' | tail -n1 || true)
      [[ -n "$conditionLine" ]] || continue
      dependency=$(sed -E 's@.*\$FOAM_LIBBIN/([^"[:space:]]+).*@\1@' <<< "$conditionLine")
      [[ -n "$dependency" ]] || continue

      if ! compgen -G "$FOAM_LIBBIN/${dependency}*" > /dev/null; then
         printf 'OPTIONAL-MISSING\t%s\t%s\t%s\t%s:%s\n' "$application" "$sourcePath" "$dependency" "${allwmake#$WM_PROJECT_DIR/}" "${conditionLine%%:*}" >> "$optionalDependencyEvidenceFile"
      else
         printf 'OPTIONAL-AVAILABLE\t%s\t%s\t%s\t%s:%s\n' "$application" "$sourcePath" "$dependency" "${allwmake#$WM_PROJECT_DIR/}" "${conditionLine%%:*}" >> "$optionalDependencyEvidenceFile"
      fi
   done < "$missingFile"
}

# Locate an optional authoritative build summary. Its absence never changes the
# core audit, and its presence is used only to add historical evidence to the report.
find_authoritative_build_summary() {
   local candidate
   authoritativeBuildSummary=""

   # Prefer the summary stored with the OpenFOAM installation being audited.
   # Fall back to WM_PROJECT_USER_DIR only when no installation-local summary exists.
   for candidate in \
      "${WM_PROJECT_DIR}/log.Allwmake.AuthoritativeSummary" \
      "${WM_PROJECT_DIR}/log.Allwmake.AuthoritativeSummary.txt"; do
      if [[ -r "$candidate" ]]; then
         authoritativeBuildSummary=$candidate
         return 0
      fi
   done

   [[ -n "${WM_PROJECT_USER_DIR:-}" && -d "${WM_PROJECT_USER_DIR}" ]] || return 0
   for candidate in \
      "${WM_PROJECT_USER_DIR}/log.Allwmake.AuthoritativeSummary" \
      "${WM_PROJECT_USER_DIR}/log.Allwmake.AuthoritativeSummary.txt"; do
      if [[ -r "$candidate" ]]; then
         authoritativeBuildSummary=$candidate
         return 0
      fi
   done
}

# ------------------------------------------------------------------------------
# Build the expected and installed application inventories
# ------------------------------------------------------------------------------
progress "[1/6] Discovering source and installed OpenFOAM applications..."
extract_expected_targets "$WM_PROJECT_DIR/applications" > "$expectedApplicationsFile"
extract_target_source_map "$WM_PROJECT_DIR/applications" > "$targetSourceMapFile"
[[ -s "$expectedApplicationsFile" ]] || { echo "ERROR: No EXE targets were discovered under $WM_PROJECT_DIR/applications" >&2; exit 1; }


find "$FOAM_APPBIN" -maxdepth 1 \( -type f -o -type l \) -executable -printf '%f\n' \
   | sort -u > "$installedApplicationsFile"

progress "[2/6] Classifying tests and known optional targets..."

# Classify tests by source-tree location before comparing executable names. This
# avoids treating descriptive test names such as foamCellZoneToVTK as production
# applications merely because they do not begin with Test-.
if [[ -d "$WM_PROJECT_DIR/applications/test" ]]; then
   extract_expected_targets "$WM_PROJECT_DIR/applications/test" > "$expectedTestTargetsFile"
else
   : > "$expectedTestTargetsFile"
fi

# Retain support for explicitly named Test-* targets declared elsewhere.
{ grep '^Test-' "$expectedApplicationsFile" || true; } \
   | cat "$expectedTestTargetsFile" - \
   | sort -u > "${expectedTestTargetsFile}.tmp"
mv -- "${expectedTestTargetsFile}.tmp" "$expectedTestTargetsFile"

# Build the cumulative informational-policy pools. Only pool targets declared by
# the active source tree and absent from FOAM_APPBIN are reported for this audit.
printf '%s\n' "${sourceOnlyApplications[@]}" | sort -u > "${sourceOnlyApplicationsFile}.pool"
printf '%s\n' "${optionalDependencyApplications[@]}" | sort -u > "${optionalDependencyApplicationsFile}.pool"

comm -12 "${sourceOnlyApplicationsFile}.pool" "$expectedApplicationsFile" \
   | comm -23 - "$installedApplicationsFile" > "$sourceOnlyApplicationsFile"
comm -12 "${optionalDependencyApplicationsFile}.pool" "$expectedApplicationsFile" \
   | comm -23 - "$installedApplicationsFile" > "$optionalDependencyApplicationsFile"

# Production expectations exclude test, source-only, and optional-dependency
# targets. Any remaining absent production target requires review.
comm -23 "$expectedApplicationsFile" "$expectedTestTargetsFile" \
   | comm -23 - "${sourceOnlyApplicationsFile}.pool" \
   | comm -23 - "${optionalDependencyApplicationsFile}.pool" \
   > "$expectedProductionApplicationsFile"

rm -f -- "${sourceOnlyApplicationsFile}.pool" "${optionalDependencyApplicationsFile}.pool"

comm -23 "$expectedProductionApplicationsFile" "$installedApplicationsFile" > "$missingProductionApplicationsFile"

initialReviewCount=$(wc -l < "$missingProductionApplicationsFile")
progress "[3/6] Initial production targets requiring review: ${initialReviewCount}"
: > "$buildIntentionEvidenceFile"
: > "$optionalDependencyEvidenceFile"
: > "$buildGateEvidenceFile"
if (( initialReviewCount > 0 )); then
   progress "[4/6] Tracing standard-build intention and optional dependencies for ${initialReviewCount} unresolved target(s)..."
   collect_build_intention_evidence "$missingProductionApplicationsFile" "$targetSourceMapFile"
   collect_simple_build_gate_evidence "$missingProductionApplicationsFile" "$targetSourceMapFile"
   collect_optional_dependency_evidence "$missingProductionApplicationsFile" "$targetSourceMapFile"
else
   progress "[4/6] No unresolved production targets require build-intention tracing."
fi

{
   awk -F '\t' '$1 == "DIRECT-COMMENTED" || $1 == "SUBTREE-COMMENTED" {print $2}' "$buildIntentionEvidenceFile"
   awk -F '\t' '$1 == "ENV-GATE-FALSE" || $1 == "PLATFORM-GATE-FALSE" {print $2}' "$buildGateEvidenceFile"
} | sort -u > "${sourceOnlyApplicationsFile}.auto"
cat "$sourceOnlyApplicationsFile" "${sourceOnlyApplicationsFile}.auto" | sort -u > "${sourceOnlyApplicationsFile}.merged"
mv -- "${sourceOnlyApplicationsFile}.merged" "$sourceOnlyApplicationsFile"

{
   awk -F '\t' '$1 == "OPTIONAL-MISSING" {print $2}' "$optionalDependencyEvidenceFile"
   awk -F '\t' '$1 == "DEPENDENCY-GATE-FALSE" {print $2}' "$buildGateEvidenceFile"
} | sort -u > "${optionalDependencyApplicationsFile}.auto"
cat "$optionalDependencyApplicationsFile" "${optionalDependencyApplicationsFile}.auto" | sort -u > "${optionalDependencyApplicationsFile}.merged"
mv -- "${optionalDependencyApplicationsFile}.merged" "$optionalDependencyApplicationsFile"

comm -23 "$missingProductionApplicationsFile" "$sourceOnlyApplicationsFile" | comm -23 - "$optionalDependencyApplicationsFile" > "${missingProductionApplicationsFile}.refined"
mv -- "${missingProductionApplicationsFile}.refined" "$missingProductionApplicationsFile"
rm -f -- "${sourceOnlyApplicationsFile}.auto" "${optionalDependencyApplicationsFile}.auto"
finalReviewCount=$(wc -l < "$missingProductionApplicationsFile")
progress "[5/6] Production targets still requiring review after build tracing: ${finalReviewCount}"
find_authoritative_build_summary

comm -12 "$expectedTestTargetsFile" "$installedApplicationsFile" > "$installedTestTargetsFile"
comm -23 "$expectedTestTargetsFile" "$installedApplicationsFile" > "$notInstalledTestTargetsFile"

# ------------------------------------------------------------------------------
# Compare solver targets using identical populations
# ------------------------------------------------------------------------------
# Installed solvers are defined as the intersection of the solver targets declared
# under applications/solvers and the executables in FOAM_APPBIN. This avoids the
# invalid comparison of source solver counts with every installed name ending Foam.
if [[ -d "$WM_PROJECT_DIR/applications/solvers" ]]; then
   extract_expected_targets "$WM_PROJECT_DIR/applications/solvers" > "$expectedSolversFile"
else
   : > "$expectedSolversFile"
fi

comm -12 "$expectedSolversFile" "$installedApplicationsFile" > "$installedSolversFile"
comm -23 "$expectedSolversFile" "$installedApplicationsFile" > "$missingSolversFile"

# ------------------------------------------------------------------------------
# Check representative core applications
# ------------------------------------------------------------------------------
missingCoreCount=0
: > "$coreApplicationsFile"
for application in "${coreApplications[@]}"; do
   # Foundation releases may declare foamPostProcess instead of postProcess.
   if [[ "$application" == postProcess ]] &&
      ! grep -qxF postProcess "$expectedApplicationsFile" &&
      grep -qxF foamPostProcess "$expectedApplicationsFile"; then
      application=foamPostProcess
   fi
   if [[ -x "$FOAM_APPBIN/$application" ]]; then
      printf 'FOUND    %s\n' "$application" >> "$coreApplicationsFile"
   else
      printf 'MISSING  %s\n' "$application" >> "$coreApplicationsFile"
      ((missingCoreCount += 1))
   fi
done

# ------------------------------------------------------------------------------
# Calculate report totals and installation status
# ------------------------------------------------------------------------------
productionDeclaredCount=$(wc -l < "$expectedProductionApplicationsFile")
productionSourceOnlyCount=$(wc -l < "$sourceOnlyApplicationsFile")
productionOptionalDependencyCount=$(wc -l < "$optionalDependencyApplicationsFile")
productionExpectedCount=$(( productionDeclaredCount - productionSourceOnlyCount - productionOptionalDependencyCount ))
productionInstalledCount=$(comm -23 "$expectedProductionApplicationsFile" "$sourceOnlyApplicationsFile"    | comm -23 - "$optionalDependencyApplicationsFile"    | comm -12 - "$installedApplicationsFile" | wc -l)
missingProductionCount=$(wc -l < "$missingProductionApplicationsFile")

: > "$authoritativeBuildEvidenceFile"
if [[ -n "${authoritativeBuildSummary:-}" && -s "$missingProductionApplicationsFile" ]]; then
   while IFS= read -r application; do
      if grep -qF -- "$application" "$authoritativeBuildSummary"; then
         printf 'MENTIONED %s\n' "$application"
      else
         printf 'NO-MENTION %s\n' "$application"
      fi
   done < "$missingProductionApplicationsFile" > "$authoritativeBuildEvidenceFile"
fi
solverDeclaredCount=$(wc -l < "$expectedSolversFile")
solverSourceOnlyCount=$(comm -12 "$expectedSolversFile" "$sourceOnlyApplicationsFile" | wc -l)
solverOptionalDependencyCount=$(comm -12 "$expectedSolversFile" "$optionalDependencyApplicationsFile" | wc -l)
solverExpectedCount=$(( solverDeclaredCount - solverSourceOnlyCount - solverOptionalDependencyCount ))
solverInstalledCount=$(comm -23 "$expectedSolversFile" "$sourceOnlyApplicationsFile"    | comm -23 - "$optionalDependencyApplicationsFile"    | comm -12 - "$installedApplicationsFile" | wc -l)
comm -23 "$expectedSolversFile" "$optionalDependencyApplicationsFile" | comm -23 - "$sourceOnlyApplicationsFile" | comm -23 - "$installedApplicationsFile" > "$missingSolversFile"
missingSolverCount=$(wc -l < "$missingSolversFile")
expectedTestTargetCount=$(wc -l < "$expectedTestTargetsFile")
installedTestTargetCount=$(wc -l < "$installedTestTargetsFile")
notInstalledTestTargetCount=$(wc -l < "$notInstalledTestTargetsFile")
sourceOnlyApplicationCount=$(wc -l < "$sourceOnlyApplicationsFile")
optionalDependencyApplicationCount=$(wc -l < "$optionalDependencyApplicationsFile")

if (( missingSolverCount > 0 || missingCoreCount > 0 )); then
   auditStatus="FAILED"
   auditExitStatus=1
elif (( missingProductionCount > 0 )); then
   auditStatus="PASSED WITH WARNINGS"
   auditExitStatus=0
else
   auditStatus="PASSED"
   auditExitStatus=0
fi

# ------------------------------------------------------------------------------
# Write the human-readable report
# ------------------------------------------------------------------------------
progress "[6/6] Writing audit report..."
{
   echo "============================================================"
   echo "OpenFOAM Installation Report"
   echo "============================================================"
   echo
   echo "Status: $auditStatus"
   echo
   echo "Date: $(date)"
   echo "WM_PROJECT_DIR: $WM_PROJECT_DIR"
   echo "FOAM_APPBIN: $FOAM_APPBIN"
   echo "WM_PROJECT_VERSION: ${WM_PROJECT_VERSION:-not set}"
   echo
   echo "------------------------------------------------------------"
   echo "Installation completeness"
   echo "------------------------------------------------------------"
   echo "Production executable targets:"
   printf '  Declared in source:                         %5d\n' "$productionDeclaredCount"
   printf '  Application targets not selected by standard build:            %5d\n' "$productionSourceOnlyCount"
   printf '  Optional dependency application targets:    %5d\n' "$productionOptionalDependencyCount"
   printf '  Expected to be installed:                   %5d\n' "$productionExpectedCount"
   printf '  Installed:                                  %5d\n' "$productionInstalledCount"
   printf '  Production targets requiring review:        %5d\n' "$missingProductionCount"
   echo
   echo "  Standalone solver executables (subset of production targets):"
   printf '    Declared in source:                         %5d\n' "$solverDeclaredCount"
   printf '    Application targets not selected by standard build:            %5d\n' "$solverSourceOnlyCount"
   printf '    Optional dependency application targets:    %5d\n' "$solverOptionalDependencyCount"
   printf '    Expected to be installed:                   %5d\n' "$solverExpectedCount"
   printf '    Installed:                                  %5d\n' "$solverInstalledCount"
   printf '    Solver targets requiring review:             %5d\n' "$missingSolverCount"
   echo
   echo "Selected core utilities (checker-defined validation set):"
   printf '  Selected:   %5d\n' "${#coreApplications[@]}"
   printf '  Available:  %5d\n' "$(( ${#coreApplications[@]} - missingCoreCount ))"
   printf '  Missing:    %5d\n' "$missingCoreCount"
   echo
   echo "Standalone solver executables are a subset of the production executable"
   echo "inventory above; their counts must not be added to the production totals."
   echo
   echo "Application targets not selected by standard build and optional dependency application targets"
   echo "are informational categories and are excluded from the number expected to be"
   echo "installed. Production targets requiring review remain part of that expectation."
   echo
   echo "The selected core utilities are a checker-defined representative set used for"
   echo "an additional operational check; they are not a complete inventory of OpenFOAM"
   echo "utilities."
   echo
   echo "Internal/developer tests, known targets not selected by the standard build, and known optional"
   echo "dependency targets are reported separately and do not affect audit status."
   echo
   echo "------------------------------------------------------------"
   echo "Selected core utility checks"
   echo "------------------------------------------------------------"
   cat "$coreApplicationsFile"
   echo
   echo "------------------------------------------------------------"
   echo "Missing solvers"
   echo "------------------------------------------------------------"
   if (( missingSolverCount == 0 )); then echo "None"; else cat "$missingSolversFile"; fi
   echo
   echo "------------------------------------------------------------"
   echo "Production targets requiring review"
   echo "------------------------------------------------------------"
   echo "These non-test source targets were not found in FOAM_APPBIN. They may"
   echo "depend on optional components, be disabled by release build logic, or"
   echo "represent deprecated targets. Review them when this section is non-empty."
   echo
   if (( missingProductionCount == 0 )); then
      echo "None"
   else
      cat "$missingProductionApplicationsFile"
      echo
      echo "Source-tree standard-build intention evidence:"
      while IFS= read -r application; do
         awk -F '	' -v target="$application" '
            $2 == target {
               if ($1 == "DIRECT-ACTIVE") printf "  Active direct build invocation: %s [%s]\n", target, $4
               else if ($1 == "SUBTREE-ACTIVE") printf "  Active parent-subtree selection: %s [%s]\n", target, $4
               else if ($1 == "UNRESOLVED") printf "  Build intention unresolved: %s\n", target
            }
         ' "$buildIntentionEvidenceFile"
      done < "$missingProductionApplicationsFile"
      echo
      echo "Explicitly commented direct builds or parent-subtree selections are moved to"
      echo "the informational source-only section. Active or unresolved targets remain."
      echo
      if [[ -n "${authoritativeBuildSummary:-}" ]]; then
         echo "Optional authoritative build-summary evidence:"
         echo "  Summary: $authoritativeBuildSummary"
         while IFS=' ' read -r evidence application; do
            case "$evidence" in
               MENTIONED)  printf '  Mention found:    %s\n' "$application" ;;
               NO-MENTION) printf '  No mention found: %s\n' "$application" ;;
            esac
         done < "$authoritativeBuildEvidenceFile"
      else
         echo "Optional authoritative build summary: not available; core audit unchanged."
      fi
   fi
   echo
   echo "------------------------------------------------------------"
   echo "Application targets not selected by standard build (informational only)"
   echo "------------------------------------------------------------"
   echo "These executable targets are declared by the active OpenFOAM source tree but"
   echo "have been positively identified as not selected by the standard production"
   echo "build for the current environment or release."
   echo "Their absence does not indicate an incomplete build and does not affect"
   echo "audit status."
   echo
   if (( sourceOnlyApplicationCount == 0 )); then
      echo "None"
   else
      cat "$sourceOnlyApplicationsFile"
      echo
      echo "Build-selection evidence:"
      while IFS= read -r application; do
         awk -F '	' -v target="$application" '
            $2 == target && ($1 == "DIRECT-COMMENTED" || $1 == "SUBTREE-COMMENTED") {
               if ($1 == "DIRECT-COMMENTED") printf "  Commented-out direct build: %s [%s]\n", target, $4
               else printf "  Commented-out parent subtree: %s [%s]\n", target, $4
            }
         ' "$buildIntentionEvidenceFile"
         awk -F '\t' -v target="$application" '$1 == "ENV-GATE-FALSE" && $2 == target {printf "  Disabled opt-in build flag: %s -> %s is empty [%s]\n", target, $4, $5}' "$buildGateEvidenceFile"
         awk -F '\t' -v target="$application" '$1 == "PLATFORM-GATE-FALSE" && $2 == target {printf "  Platform build condition not satisfied: %s -> %s false (%s) [%s]\n", target, $4, $6, $5}' "$buildGateEvidenceFile"
      done < "$sourceOnlyApplicationsFile"
   fi
   echo
   echo "------------------------------------------------------------"
   echo "Optional dependency application targets (informational only)"
   echo "------------------------------------------------------------"
   echo "These executable targets are conditional on optional dependencies and were"
   echo "not found in FOAM_APPBIN. Their absence does not by itself indicate an"
   echo "incomplete build and does not affect audit status."
   echo
   if (( optionalDependencyApplicationCount == 0 )); then
      echo "None"
   else
      cat "$optionalDependencyApplicationsFile"
      echo
      echo "Dependency evidence:"
      while IFS= read -r application; do
         awk -F '\t' -v target="$application" '$1 == "OPTIONAL-MISSING" && $2 == target {printf "  Required dependency unavailable: %s -> %s [%s]\n", target, $4, $5}' "$optionalDependencyEvidenceFile"
         awk -F '\t' -v target="$application" '$1 == "DEPENDENCY-GATE-FALSE" && $2 == target {printf "  Required path unavailable: %s -> %s (%s) [%s]\n", target, $4, $6, $5}' "$buildGateEvidenceFile"
      done < "$optionalDependencyApplicationsFile"
   fi
   echo
   echo "------------------------------------------------------------"
   echo "Internal and developer test targets (informational only)"
   echo "------------------------------------------------------------"
   echo "These targets are declared under applications/test, or use a Test-* name."
   echo "They are not expected in a normal production installation. Their absence"
   echo "does not indicate an incomplete build and does not affect audit status."
   echo
   printf 'Test targets declared in source: %d\n' "$expectedTestTargetCount"
   printf 'Test targets installed:          %d\n' "$installedTestTargetCount"
   printf 'Test targets not installed:      %d\n' "$notInstalledTestTargetCount"
   echo
   echo "Individual test target names are intentionally omitted from this report."
} > "$reportFile"

progress "Audit complete: ${auditStatus}"
cat "$reportFile"
echo
echo "Audit report: $reportFile"
exit "$auditExitStatus"
