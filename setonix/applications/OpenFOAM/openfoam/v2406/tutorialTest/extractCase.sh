#!/bin/bash --login
# Extract and validate an OpenFOAM tutorial case from a Singularity image.
#
# This script performs the first stage of the version-specific OpenFOAM tutorial
# functional test. It locates exactly one version-selected tutorial case inside
# supplied image, copies a clean case tree to the host, and verifies that the
# files required by the preparation and solver stages are present.
#
# The script runs directly on a login node and does not submit a Slurm job. The
# general tutorial-test launcher is expected to call this script before it
# submits preFoam.slurm.sh and runFoam.slurm.sh. The image is supplied by the caller. The host work root may be supplied by the
# launcher or omitted when running directly, in which case a stable v2406 default
# is used.
#
# Usage:
#   ./extractCase.sh --image <file> [--work-root <directory>] [--overwrite]
#
# Exit status:
#   0  The tutorial case was uniquely located, copied, and validated.
#   1  Invalid input, environment setup failure, copy failure, or validation
#      failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

# Treat any use of an unset variable as an error.
set -u

# --- Version-specific tutorial settings
# This extraction script belongs to the same v2406 workflow as preFoam.slurm.sh
# and runFoam.slurm.sh, so all three scripts intentionally use the same case.
CASE_NAME="periodicPlaneChannel"

# --- Initial settings
thisScript=$(basename "$0")
imageInput=""
workRootInput=""
configFileInput=""
testArtifactsDirInput=""
overwriteCase=false
SINGULARITY_MODULE=${SINGULARITY_MODULE:-singularity/4.1.0-mpi}

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  $thisScript --image <file> --config <file> [--work-root <directory>] [--test-artifacts-dir <directory>] [--overwrite]
  $thisScript --help

Options:
  --image, -i <file>          Singularity image containing the tutorial case
  --work-root, -w <directory>
                             Override the host work root. By default, the script
                             uses MYSCRATCH/OpenFOAM/$USER-v2406.
  --overwrite                  Remove the existing target case before copying
  --config <file>                Version configuration file; required for direct execution
  --test-artifacts-dir <directory>      Test-artifact destination; defaults to <work-root>/test-output
  --help, -h                 Show this help message and exit

The target case is created as:
  <work-root>/run/$CASE_NAME

Default work root:
  ${MYSCRATCH:-${TMPDIR:-$HOME}}/OpenFOAM/${USER}-v2406

By default, the target case must not already exist. Use --overwrite to remove
and replace only the target case directory.
USAGE
}

# --- Parse command-line arguments
while [[ $# -gt 0 ]]; do
   case "$1" in
      --image|-i)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --image requires <file>" >&2; usage >&2; exit 1; }
         imageInput="$2"
         shift 2
         ;;
      --work-root|-w)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --work-root requires <directory>" >&2; usage >&2; exit 1; }
         workRootInput="$2"
         shift 2
         ;;
      --overwrite)
         overwriteCase=true
         shift
         ;;
      --config)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --config requires <file>" >&2; usage >&2; exit 1; }
         configFileInput="$2"; shift 2 ;;
      --test-artifacts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --test-artifacts-dir requires <directory>" >&2; usage >&2; exit 1; }
         testArtifactsDirInput="$2"; shift 2 ;;
      -h|--help)
         usage
         exit 0
         ;;
      *)
         echo "ERROR: Unknown option '$1'" >&2
         usage >&2
         exit 1
         ;;
   esac
done

# --- Validate and resolve inputs
[[ -n "$imageInput" ]] || { echo "ERROR: --image is required" >&2; usage >&2; exit 1; }
[[ -f "$imageInput" ]] || { echo "ERROR: Singularity image not found: $imageInput" >&2; usage >&2; exit 1; }
SINGULARITY_CONTAINER=$(realpath "$imageInput")
[[ -n "$configFileInput" ]] || {
   echo "ERROR: --config is required when this stage is executed independently" >&2
   usage >&2
   exit 1
}
[[ -r "$configFileInput" ]] || {
   echo "ERROR: Configuration is not readable: $configFileInput" >&2
   usage >&2
   exit 1
}
configFile=$(realpath "$configFileInput")
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || { echo "ERROR: $requiredSetting is not defined in $configFile" >&2; exit 1; }
done
imageFileName=$(basename "$SINGULARITY_CONTAINER")
expectedSifPrefix="${OPENFOAM_FORK}--${OPENFOAM_VERSION}"
[[ "$imageFileName" == "${expectedSifPrefix}"*.sif ]] || {
   echo "ERROR: Singularity image filename does not match the configured OpenFOAM identity" >&2
   echo "       Image filename:   $imageFileName" >&2
   echo "       Required pattern: ${expectedSifPrefix}*.sif" >&2
   exit 1
}


if [[ -n "$workRootInput" ]]; then
   workRoot=$(realpath -m "$workRootInput")
else
   baseWorkDir=${MYSCRATCH:-${TMPDIR:-$HOME}}
   workRoot="${baseWorkDir}/OpenFOAM/${USER}-v2406"
fi
hostRunDir="${workRoot}/run"

# --- Resolve the persistent test-artifact directory
# The launcher passes its timestamped invocation directory. When this stage is
# run independently, the default is the stable <work-root>/test-output path.
workOutputPath="${workRoot}/test-output"
if [[ -n "$testArtifactsDirInput" ]]; then
   outputDir=$(realpath -m "$testArtifactsDirInput")
   mkdir -p "$outputDir" || { echo "ERROR: Could not create test-artifact directory: $outputDir" >&2; exit 1; }
   mkdir -p "$workRoot"
   if [[ -e "$workOutputPath" && ! -L "$workOutputPath" ]]; then
      echo "ERROR: Refusing to replace non-symbolic-link output path: $workOutputPath" >&2
      echo "       Remove it deliberately or omit --test-artifacts-dir to use it directly." >&2
      exit 1
   fi
   ln -sfn "$outputDir" "$workOutputPath"
else
   outputDir="$workOutputPath"
   mkdir -p "$outputDir" || { echo "ERROR: Could not create default test-artifact directory: $outputDir" >&2; exit 1; }
fi
stageName="extractCase"
stageRunLog="${outputDir}/${stageName}.run.log"
stageStatusFile="${outputDir}/${stageName}.status.txt"
printf '%s\n' RUNNING > "$stageStatusFile"
record_stage_status() {
   local exitStatus=$?
   trap - EXIT
   if [[ $exitStatus -eq 0 ]]; then
      printf '%s\n' SUCCESS > "$stageStatusFile"
   else
      printf '%s\n' FAILED > "$stageStatusFile"
   fi
   exit "$exitStatus"
}
trap record_stage_status EXIT
exec > >(tee "$stageRunLog") 2>&1

echo "Test artifacts: $outputDir"
echo "Stage run log: $stageRunLog"
echo "Stage status: $stageStatusFile"
echo
testCase="${hostRunDir}/${CASE_NAME}"

# --- Step 1: Set up the Singularity environment
echo "$thisScript: -----------------------------------------"
echo "Step 1 - Setting up the Singularity environment"
module load "$SINGULARITY_MODULE" || {
   echo "ERROR: Failed to load $SINGULARITY_MODULE" >&2
   exit 1
}
module list
command -v singularity >/dev/null 2>&1 || {
   echo "ERROR: singularity is unavailable after loading $SINGULARITY_MODULE" >&2
   exit 1
}
echo "Image: $SINGULARITY_CONTAINER"
WM_PROJECT_VERSION=$(singularity exec "$SINGULARITY_CONTAINER" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || { echo "ERROR: Failed to read WM_PROJECT_VERSION from the image environment" >&2; exit 1; }
[[ -n "$WM_PROJECT_VERSION" ]] || { echo "ERROR: WM_PROJECT_VERSION is empty in the image environment" >&2; exit 1; }
[[ "$WM_PROJECT_VERSION" =~ ^v?[0-9][0-9A-Za-z.-]*$ ]] || { echo "ERROR: Invalid WM_PROJECT_VERSION='$WM_PROJECT_VERSION'" >&2; exit 1; }
[[ "$WM_PROJECT_VERSION" == "$OPENFOAM_VERSION" ]] || {
   echo "ERROR: OpenFOAM version mismatch between the image and configuration" >&2
   echo "       Image environment: $WM_PROJECT_VERSION" >&2
   echo "       Configuration:     $OPENFOAM_VERSION" >&2
   exit 1
}
echo "PASS: Image filename and WM_PROJECT_VERSION match OPENFOAM_FORK='$OPENFOAM_FORK' and OPENFOAM_VERSION='$OPENFOAM_VERSION'"
echo "PASS: Singularity environment ready"
echo

# --- Step 2: Prepare a clean host destination
# Do not overwrite an existing case. The launcher must use an isolated work root
# or remove a previous test run explicitly before starting this stage.
echo "$thisScript: -----------------------------------------"
echo "Step 2 - Preparing the host destination"
mkdir -p "$hostRunDir" || {
   echo "ERROR: Could not create host run directory: $hostRunDir" >&2
   exit 1
}

if [[ -e "$testCase" ]]; then
   if [[ "$overwriteCase" == "true" ]]; then
      echo "Removing existing target case: $testCase"
      rm -rf "$testCase" || {
         echo "ERROR: Failed to remove existing target case: $testCase" >&2
         exit 1
      }
   else
      echo "ERROR: Target case already exists: $testCase" >&2
      echo "       Use --overwrite to replace it, or select another --work-root." >&2
      exit 1
   fi
fi

echo "Host run directory: $hostRunDir"
echo "Target case: $testCase"
echo "PASS: Host destination ready"
echo

# --- Step 3: Locate the tutorial case inside the image
# Exactly one match is required. Multiple matches would make case selection
# ambiguous and could cause a different tutorial to be tested across versions.
echo "$thisScript: -----------------------------------------"
echo "Step 3 - Finding the '$CASE_NAME' tutorial inside the image"
internalCaseOutput=$(singularity exec "$SINGULARITY_CONTAINER" \
   bash -c 'find "$FOAM_TUTORIALS" -type d -name "$1" -print' bash "$CASE_NAME") || {
      echo "ERROR: Failed to search FOAM_TUTORIALS inside the image" >&2
      exit 1
   }

internalCases=()
if [[ -n "$internalCaseOutput" ]]; then
   mapfile -t internalCases <<< "$internalCaseOutput"
fi

[[ ${#internalCases[@]} -eq 1 ]] || {
   echo "ERROR: Expected exactly one tutorial directory named '$CASE_NAME'; found ${#internalCases[@]}" >&2
   printf '  %s\n' "${internalCases[@]}" >&2
   exit 1
}
internalCase=${internalCases[0]}

echo "Tutorial source: $internalCase"
echo "PASS: Unique tutorial case found"
echo

# --- Step 4: Copy the tutorial case to the host
# The host run directory is bound explicitly so the destination remains outside
# the image and is available to the later Slurm preparation and solver jobs.
echo "$thisScript: -----------------------------------------"
echo "Step 4 - Copying the tutorial case to the host"
singularity exec -B "${hostRunDir}:${hostRunDir}" "$SINGULARITY_CONTAINER" \
   cp -a "$internalCase" "$testCase" || {
      echo "ERROR: Failed to copy the tutorial case" >&2
      exit 1
   }

echo "PASS: Tutorial case copied"
echo

# --- Step 5: Validate the extracted case
# These checks establish the minimum case structure required by preFoam.slurm.sh
# and runFoam.slurm.sh. Version-specific scripts may perform additional checks themselves.
echo "$thisScript: -----------------------------------------"
echo "Step 5 - Validating the extracted tutorial case"
[[ -d "$testCase" ]] || { echo "ERROR: Extracted case directory not found: $testCase" >&2; exit 1; }
[[ -d "${testCase}/system" ]] || { echo "ERROR: Missing directory: ${testCase}/system" >&2; exit 1; }
[[ -d "${testCase}/constant" ]] || { echo "ERROR: Missing directory: ${testCase}/constant" >&2; exit 1; }
[[ -d "${testCase}/0" || -d "${testCase}/0.orig" ]] || {
   echo "ERROR: Missing initial-condition directory: ${testCase}/0 or ${testCase}/0.orig" >&2
   exit 1
}
[[ -f "${testCase}/system/controlDict" ]] || {
   echo "ERROR: Missing dictionary: ${testCase}/system/controlDict" >&2
   exit 1
}
[[ -f "${testCase}/system/decomposeParDict" ]] || {
   echo "ERROR: Missing dictionary: ${testCase}/system/decomposeParDict" >&2
   exit 1
}

echo "Extracted case: $testCase"
echo "PASS: Extracted tutorial case is complete"
echo

# --- Final summary
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Tutorial case: $CASE_NAME"
echo "Image: $SINGULARITY_CONTAINER"
echo "Extracted case: $testCase"
echo "ALL STEPS PASSED: OpenFOAM tutorial case extracted successfully."

# Return success to the caller.
exit 0
