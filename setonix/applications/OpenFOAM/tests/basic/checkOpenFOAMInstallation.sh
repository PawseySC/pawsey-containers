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
#   ./checkOpenFOAMInstallation.sh -o openfoam-installation-check
#
#   singularity shell openfoam.sif
#   ./checkOpenFOAMInstallation.sh -o openfoam-installation-check
#
#   podman run --rm -it openfoam:v2312
#   ./checkOpenFOAMInstallation.sh -o openfoam-installation-check
#
# Output
# ------
# The required -o option names a new output directory. Reusing an existing directory
# requires --overwrite, which removes only known audit files before running.
# Relative paths are interpreted from the caller's current working directory.
# The directory contains a human-readable report and the sorted audit lists.
#
# Developer Test-* targets are excluded from the installation-health totals and
# reported separately as informational targets that are commonly not compiled.
#
# Exit status
# -----------
#   0  All solver targets and core applications are installed.
#   1  Invalid input/environment, audit failure, missing solver, or missing core app.
#
# Missing non-test, non-solver applications are reported as warnings because some
# targets can depend on optional components or build choices.

set -euo pipefail

# ------------------------------------------------------------------------------
# Initial settings
# ------------------------------------------------------------------------------
thisScript=$(basename "$0")
outputDir=""
overwrite=false

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
  -o, --output <directory>  Directory in which the audit files are written.
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
# Output files
# ------------------------------------------------------------------------------
reportFile="${outputDir}/openfoam-installation-report.txt"
expectedApplicationsFile="${outputDir}/expected-applications.txt"
installedApplicationsFile="${outputDir}/installed-applications.txt"
expectedNonTestApplicationsFile="${outputDir}/expected-non-test-applications.txt"
missingNonTestApplicationsFile="${outputDir}/missing-non-test-applications.txt"
expectedSolversFile="${outputDir}/expected-solvers.txt"
installedSolversFile="${outputDir}/installed-solvers.txt"
missingSolversFile="${outputDir}/missing-solvers.txt"
expectedDeveloperTestsFile="${outputDir}/expected-developer-tests.txt"
installedDeveloperTestsFile="${outputDir}/installed-developer-tests.txt"
missingDeveloperTestsFile="${outputDir}/missing-developer-tests.txt"
coreApplicationsFile="${outputDir}/core-application-checks.txt"

if [[ "$overwrite" == true ]]; then
   auditFiles=(
      "$reportFile"
      "$expectedApplicationsFile"
      "$installedApplicationsFile"
      "$expectedNonTestApplicationsFile"
      "$missingNonTestApplicationsFile"
      "$expectedSolversFile"
      "$installedSolversFile"
      "$missingSolversFile"
      "$expectedDeveloperTestsFile"
      "$installedDeveloperTestsFile"
      "$missingDeveloperTestsFile"
      "$coreApplicationsFile"
   )
   for auditFile in "${auditFiles[@]}"; do
      [[ ! -d "$auditFile" ]] || {
         echo "ERROR: Refusing to remove a directory at an audit file path: $auditFile" >&2
         exit 1
      }
   done
   rm -f -- "${auditFiles[@]}"
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
      | LC_ALL=C sort -u
}

# ------------------------------------------------------------------------------
# Build the expected and installed application inventories
# ------------------------------------------------------------------------------
extract_expected_targets "$WM_PROJECT_DIR/applications" > "$expectedApplicationsFile"
[[ -s "$expectedApplicationsFile" ]] || { echo "ERROR: No EXE targets were discovered under $WM_PROJECT_DIR/applications" >&2; exit 1; }

find "$FOAM_APPBIN" -maxdepth 1 \( -type f -o -type l \) -executable -printf '%f\n' \
   | LC_ALL=C sort -u > "$installedApplicationsFile"

# Test-* developer targets are intentionally excluded from primary health totals.
grep -v '^Test-' "$expectedApplicationsFile" > "$expectedNonTestApplicationsFile" || true
grep '^Test-' "$expectedApplicationsFile" > "$expectedDeveloperTestsFile" || true

LC_ALL=C comm -23 "$expectedNonTestApplicationsFile" "$installedApplicationsFile" > "$missingNonTestApplicationsFile"
LC_ALL=C comm -12 "$expectedDeveloperTestsFile" "$installedApplicationsFile" > "$installedDeveloperTestsFile"
LC_ALL=C comm -23 "$expectedDeveloperTestsFile" "$installedApplicationsFile" > "$missingDeveloperTestsFile"

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

LC_ALL=C comm -12 "$expectedSolversFile" "$installedApplicationsFile" > "$installedSolversFile"
LC_ALL=C comm -23 "$expectedSolversFile" "$installedApplicationsFile" > "$missingSolversFile"

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
expectedNonTestCount=$(wc -l < "$expectedNonTestApplicationsFile")
installedExpectedNonTestCount=$(LC_ALL=C comm -12 "$expectedNonTestApplicationsFile" "$installedApplicationsFile" | wc -l)
missingNonTestCount=$(wc -l < "$missingNonTestApplicationsFile")
expectedSolverCount=$(wc -l < "$expectedSolversFile")
installedSolverCount=$(wc -l < "$installedSolversFile")
missingSolverCount=$(wc -l < "$missingSolversFile")
expectedDeveloperTestCount=$(wc -l < "$expectedDeveloperTestsFile")
installedDeveloperTestCount=$(wc -l < "$installedDeveloperTestsFile")
missingDeveloperTestCount=$(wc -l < "$missingDeveloperTestsFile")

if (( missingSolverCount > 0 || missingCoreCount > 0 )); then
   auditStatus="FAILED"
   auditExitStatus=1
elif (( missingNonTestCount > 0 )); then
   auditStatus="PASSED WITH WARNINGS"
   auditExitStatus=0
else
   auditStatus="PASSED"
   auditExitStatus=0
fi

# ------------------------------------------------------------------------------
# Write the human-readable report
# ------------------------------------------------------------------------------
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
   echo "Production applications (excluding developer Test-* targets):"
   printf '  Expected:   %5d\n' "$expectedNonTestCount"
   printf '  Installed:  %5d\n' "$installedExpectedNonTestCount"
   printf '  Missing:    %5d\n' "$missingNonTestCount"
   echo
   echo "Solvers (subset of production applications):"
   printf '  Expected:   %5d\n' "$expectedSolverCount"
   printf '  Installed:  %5d\n' "$installedSolverCount"
   printf '  Missing:    %5d\n' "$missingSolverCount"
   echo
   echo "Core utilities:"
   printf '  Missing:    %5d\n' "$missingCoreCount"
   echo
   echo "Installed counts include only applications declared by the source tree."
   echo "Developer Test-* targets are reported separately at the end for"
   echo "information only. They are commonly not compiled for user installations."
   echo
   echo "------------------------------------------------------------"
   echo "Core utility checks"
   echo "------------------------------------------------------------"
   cat "$coreApplicationsFile"
   echo
   echo "------------------------------------------------------------"
   echo "Missing solvers"
   echo "------------------------------------------------------------"
   if (( missingSolverCount == 0 )); then echo "None"; else cat "$missingSolversFile"; fi
   echo
   echo "------------------------------------------------------------"
   echo "Missing production applications (including solvers)"
   echo "------------------------------------------------------------"
   echo "These entries may reflect optional dependencies, deprecated targets, or"
   echo "intentional build choices. Review them even when the overall audit passes."
   echo
   if (( missingNonTestCount == 0 )); then echo "None"; else cat "$missingNonTestApplicationsFile"; fi
   echo
   echo "------------------------------------------------------------"
   echo "Additional developer test targets (informational only)"
   echo "------------------------------------------------------------"
   printf 'Developer Test-* targets declared in source: %d\n' "$expectedDeveloperTestCount"
   printf 'Developer Test-* targets installed:          %d\n' "$installedDeveloperTestCount"
   printf 'Developer Test-* targets not installed:      %d\n' "$missingDeveloperTestCount"
   echo
   echo "These counts do not affect the audit status. Detailed lists are available"
   echo "in expected-developer-tests.txt, installed-developer-tests.txt, and"
   echo "missing-developer-tests.txt."
} > "$reportFile"

cat "$reportFile"
echo
echo "Detailed audit files: $outputDir"
exit "$auditExitStatus"
