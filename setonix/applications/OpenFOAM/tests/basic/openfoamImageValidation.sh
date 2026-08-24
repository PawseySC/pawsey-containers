#!/usr/bin/env bash
# General validation script for already-built OpenFOAM images.
#
# This script validates an existing OpenFOAM image without building or modifying
# it. Docker, Podman, and Singularity images are supported through one common
# workflow. The script checks that the selected engine and image are accessible,
# reads the OpenFOAM environment from the image, and inspects the build and
# functional-test logs stored inside it. Each tracked invocation stores its
# output and status under <recipe-dir>/artifacts/tests/image-validation/.
#
# OpenFOAM-version-specific settings are read from:
#
#   buildAndValidationConfig/openfoamBuildAndValidation.config
#
# The configuration can be selected by providing either the OpenFOAM version
# directory with --recipe-dir or the configuration file itself with --config.
# It defines the internal image-log paths used by the validation steps. Assign
# NO_CHECK to any log variable when that validation does not apply to a version
# or image type and the corresponding step should be skipped deliberately.
#
# The following settings must be defined in the configuration:
#   THIRDPARTY_BUILD_LOG  ThirdParty authoritative compilation summary.
#   PARAVIEW_BUILD_LOG    ParaView authoritative compilation summary.
#   OPENFOAM_BUILD_LOG    OpenFOAM authoritative compilation summary.
#   OPENFOAM_TOOL_LOG     OpenFOAM basic-functionality log created at build time.
#   OPENFOAM_FORK         Expected image repository and filename stem.
#   OPENFOAM_VERSION      Expected version in the image name and environment.
#
# Paths containing variables such as $WM_PROJECT_DIR are expanded inside the
# image, not in the calling environment. A setting containing NO_CHECK is not
# treated as a path and causes its associated validation step to be skipped.
#
# Examples:
#   openfoamImageValidation.sh --recipe-dir v2406 --engine podman \
#      --image openfoam:v2406-mpich4.2.2-ubuntu24.04
#
#   openfoamImageValidation.sh --config v2406/buildAndValidationConfig/openfoamBuildAndValidation.config \
#      --engine singularity --image /path/to/openfoam--v2406-mpich4.2.2-ubuntu24.04.sif
#
#   openfoamImageValidation.sh --help
#
# Exit status:
#   0  The image and all available internal validation logs passed.
#   1  Invalid input, setup failure, inaccessible image, or validation failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

# Treat any use of an unset variable as an error.
set -u

# --- Initial settings
thisScript=$(basename "$0")
testNum=0
failedTests=()
totalFailed=0
ENGINE=""
recipeDirInput=""
configFileInput=""
imageRef=""
recipeDir=""
configFile=""
validationArtifactsDir=""
runArtifactsDir=""
runLog=""
statusFile=""
validationDetailsFile=""
validationSummaryFile=""

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  $thisScript --recipe-dir <directory> --engine docker|podman|singularity --image <image>
  $thisScript --config <file> --engine docker|podman|singularity --image <image>
  $thisScript --help

Options:
  --recipe-dir, -r <directory>  OpenFOAM version directory containing the docker recipe and
                                 the buildAndValidationConfig/openfoamBuildAndValidation.config file
  --config, -c <file>           Explicit build-validation configuration file
  --engine, -b <engine>         Image engine: docker, podman, or singularity
  --image, -i <image>           Required Docker/Podman image name:tag or SIF path
  --help, -h                    Show this help message and exit
USAGE
}

# --- Helper: run a command inside the selected image
engine_run() {
   if [[ "$ENGINE" == "singularity" ]]; then
      singularity exec "$imageRef" "$@"
   else
      "$ENGINE" run --rm "$imageRef" "$@"
   fi
}

# --- Helper: expand and validate an internal log path
# The path expression is passed as data and expanded inside the image so OpenFOAM
# environment variables resolve in the environment where they are defined.
resolve_internal_path() {
   local pathExpression="$1"

   engine_run bash -c 'eval "resolvedPath=\"$1\""; printf "%s" "$resolvedPath"' bash "$pathExpression"
}

# --- Helper: record a validation failure and continue
record_failure() {
   local message="$1"

   failedTests+=("$testNum: $message")
   ((++totalFailed))
}

# --- Helper: inspect a compilation summary for unexpected Error messages
check_compilation_log() {
   local logLabel="$1"
   local pathExpression="$2"
   local resolvedPath=""
   local errorOutput=""
   local errorCount=0

   resolvedPath=$(resolve_internal_path "$pathExpression") || {
      echo "ERROR: Failed to resolve $logLabel path: $pathExpression" >&2
      record_failure "$logLabel path could not be resolved"
      return
   }

   if ! engine_run test -f "$resolvedPath"; then
      echo "FAIL: $logLabel is not available: $resolvedPath"
      echo "      This can be expected for a partial-stage image that does not contain"
      echo "      the final compilation summaries or initialize their environment paths."
      record_failure "$logLabel is not accessible"
      return
   fi

   errorOutput=$(engine_run grep -iE '\bError\b' "$resolvedPath" 2>/dev/null || true)
   if [[ -n "$errorOutput" ]]; then
      errorOutput=$(printf '%s\n' "$errorOutput" | grep -viE 'Error[./-]|ignor' || true)
   fi

   if [[ -n "$errorOutput" ]]; then
      errorCount=$(printf '%s\n' "$errorOutput" | wc -l)
      echo "FAIL: $errorCount unexpected 'Error' message(s) found in $resolvedPath"
      echo "First 5 errors:"
      printf '%s\n' "$errorOutput" | head -n 5
      record_failure "$logLabel contains $errorCount unexpected error message(s)"
   else
      echo "PASS: No unexpected Error messages found in $resolvedPath"
   fi
}

# --- Parse command-line arguments
while [[ $# -gt 0 ]]; do
   case "$1" in
      --recipe-dir|-r)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --recipe-dir requires <directory>" >&2
            usage >&2
            exit 1
         fi
         recipeDirInput="$2"; shift 2 ;;
      --config|-c)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --config requires <file>" >&2
            usage >&2
            exit 1
         fi
         configFileInput="$2"; shift 2 ;;
      --engine|-b)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --engine requires docker|podman|singularity" >&2
            usage >&2
            exit 1
         fi
         ENGINE="$2"; shift 2 ;;
      --image|-i)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --image requires <image>" >&2
            usage >&2
            exit 1
         fi
         imageRef="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "ERROR: Unknown option '$1'" >&2; usage >&2; exit 1 ;;
      *) echo "ERROR: Unexpected positional argument '$1'; use --image <image>" >&2; usage >&2; exit 1 ;;
   esac
done

# --- Validate the command-line arguments
[[ "$ENGINE" == "docker" || "$ENGINE" == "podman" || "$ENGINE" == "singularity" ]] || {
   echo "ERROR: --engine must be docker, podman, or singularity" >&2
   usage >&2
   exit 1
}
[[ -n "$imageRef" ]] || {
   echo "ERROR: --image <image> is required" >&2
   usage >&2
   exit 1
}
[[ -z "$recipeDirInput" || -z "$configFileInput" ]] || {
   echo "ERROR: Use either --recipe-dir or --config, not both" >&2
   usage >&2
   exit 1
}

# --- Locate the version-specific configuration
if [[ -n "$configFileInput" ]]; then
   [[ -f "$configFileInput" ]] || { echo "ERROR: Configuration file does not exist: $configFileInput" >&2; exit 1; }
   configFile=$(realpath "$configFileInput")
   configDir=$(dirname "$configFile")
   [[ $(basename "$configDir") == "buildAndValidationConfig" ]] || {
      echo "ERROR: Cannot derive the OpenFOAM version directory from config: $configFile" >&2
      echo "       Expected the config below a buildAndValidationConfig directory." >&2
      exit 1
   }
   recipeDir=$(dirname "$configDir")
elif [[ -n "$recipeDirInput" ]]; then
   [[ -d "$recipeDirInput" ]] || { echo "ERROR: Recipe directory does not exist: $recipeDirInput" >&2; exit 1; }
   recipeDir=$(realpath "$recipeDirInput")
   configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
else
   echo "ERROR: --recipe-dir or --config is required" >&2
   usage >&2
   exit 1
fi

# --- Create persistent artifacts for this validation invocation
validationArtifactsDir="${recipeDir}/artifacts/tests/image-validation"
mkdir -p "$validationArtifactsDir"
latestLink="${validationArtifactsDir}/latest"
if [[ -e "$latestLink" && ! -L "$latestLink" ]]; then
   echo "ERROR: Refusing to remove non-symbolic-link path: $latestLink" >&2
   exit 1
fi
if ! rm -f "$latestLink"; then
   echo "ERROR: Failed to remove latest link: $latestLink" >&2
   exit 1
fi
echo "This directory contains timestamped image-validation artifacts. The latest link identifies the most recent tracked validation invocation. If the link is absent, the most recent command failed before invocation tracking was established." > "${validationArtifactsDir}/README.txt"
validationTimestamp=$(date '+%Y%m%dT%H%M%S%z')
runArtifactsName="${validationTimestamp}_${ENGINE}"
runArtifactsDir="${validationArtifactsDir}/${runArtifactsName}"
if ! mkdir "$runArtifactsDir"; then
   echo "ERROR: Cannot create validation artifact directory: $runArtifactsDir" >&2
   exit 1
fi
ln -sfn "$runArtifactsName" "$latestLink"
runLog="${runArtifactsDir}/run.log"
statusFile="${runArtifactsDir}/status.txt"
validationDetailsFile="${runArtifactsDir}/validation-details.txt"
validationSummaryFile="${runArtifactsDir}/validation-summary.txt"
printf '%s\n' RUNNING > "$statusFile"
record_validation_status() {
   local exitStatus=$?
   trap - EXIT
   if [[ $exitStatus -eq 0 ]]; then
      printf '%s\n' SUCCESS > "$statusFile"
   else
      printf '%s\n' FAILED > "$statusFile"
   fi
   exit "$exitStatus"
}
trap record_validation_status EXIT
exec > >(tee "$runLog") 2>&1

echo "Validation artifacts: $runArtifactsDir"
echo "Complete run log: $runLog"
echo "Status file: $statusFile"
echo
[[ -r "$configFile" ]] || { echo "ERROR: Build-validation configuration is not readable: $configFile" >&2; exit 1; }
unset OPENFOAM_FORK OPENFOAM_VERSION THIRDPARTY_BUILD_LOG PARAVIEW_BUILD_LOG OPENFOAM_BUILD_LOG OPENFOAM_TOOL_LOG
# shellcheck source=/dev/null
source "$configFile"

# Require an explicit setting for every supported internal validation log. Use
# NO_CHECK in the configuration when a particular check is intentionally disabled.
for requiredSetting in \
   OPENFOAM_FORK \
   OPENFOAM_VERSION \
   THIRDPARTY_BUILD_LOG \
   PARAVIEW_BUILD_LOG \
   OPENFOAM_BUILD_LOG \
   OPENFOAM_TOOL_LOG
do
   [[ -n "${!requiredSetting:-}" ]] || {
      echo "ERROR: $requiredSetting is not defined in $configFile" >&2
      exit 1
   }
done

# Record and display the resolved validation inputs.
{
   echo "Validation timestamp: $validationTimestamp"
   echo "Engine: $ENGINE"
   echo "Image input: $imageRef"
   echo "Configuration: $configFile"
   echo "Recipe directory: $recipeDir"
   echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
   echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
} > "$validationDetailsFile"
echo "Will validate image: $imageRef"
echo "Engine: $ENGINE"
echo "Configuration: $configFile"
echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
echo

# --- Step 1: Set up the selected image engine
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Setting up the $ENGINE environment"
case "$ENGINE" in
   docker)
      if ! docker info >/dev/null 2>&1; then
         echo "Starting Docker Desktop..."
         open -a Docker
         for _ in {1..30}; do
            docker info >/dev/null 2>&1 && break
            sleep 1
         done
      fi
      docker info >/dev/null 2>&1 || { echo "ERROR: Docker failed to start" >&2; exit 1; }
      ;;
   podman)
      source /container/setup_podman.sh 2>/dev/null || { echo "ERROR: Failed to source /container/setup_podman.sh" >&2; exit 1; }
      ;;
   singularity)
      module load singularity/4.1.0-mpi 2>/dev/null || { echo "ERROR: Failed to load singularity/4.1.0-mpi" >&2; exit 1; }
      ;;
esac
echo "PASS: ${ENGINE^} environment ready"
echo

# --- Step 2: Confirm that the selected engine is accessible
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking if $ENGINE is accessible"
engineVersion=$("$ENGINE" --version 2>&1) || { echo "ERROR: Failed to execute $ENGINE --version" >&2; exit 1; }
[[ -n "$engineVersion" ]] || { echo "ERROR: Empty engine version" >&2; exit 1; }
echo "  $engineVersion"
echo "Engine version: $engineVersion" >> "$validationDetailsFile"
if [[ "$ENGINE" == "podman" ]]; then
   [[ -n "${XDG_DATA_HOME:-}" ]] || { echo "ERROR: XDG_DATA_HOME is not set" >&2; exit 1; }
   echo "  XDG_DATA_HOME=$XDG_DATA_HOME"
fi
echo "PASS: $ENGINE is accessible"
echo

# --- Step 3: Verify the requested image identity and existence
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Verifying the image identity and existence"
if [[ "$ENGINE" == "singularity" ]]; then
   imageFileName=$(basename "$imageRef")
   expectedImagePrefix="${OPENFOAM_FORK}--${OPENFOAM_VERSION}"
   if [[ "$imageFileName" != "${expectedImagePrefix}"*.sif ]]; then
      echo "ERROR: Singularity image filename does not match the configured OpenFOAM identity" >&2
      echo "       Image filename:   $imageFileName" >&2
      echo "       Required pattern: ${expectedImagePrefix}*.sif" >&2
      exit 1
   fi
   echo "PASS: Singularity filename matches configured identity '${expectedImagePrefix}*.sif'"
   [[ -f "$imageRef" ]] || { echo "ERROR: SIF image not found: $imageRef" >&2; exit 1; }
   imageRef=$(realpath "$imageRef")
   imageIdentity=$(sha256sum "$imageRef" | awk '{print $1}')
   echo "  Image: $imageRef"
   echo "  SHA256: $imageIdentity"
   echo "Resolved image: $imageRef" >> "$validationDetailsFile"
   echo "Image SHA256: $imageIdentity" >> "$validationDetailsFile"
else
   expectedImagePrefix="${OPENFOAM_FORK}:${OPENFOAM_VERSION}"
   if [[ "$imageRef" != "${expectedImagePrefix}"* ]]; then
      echo "ERROR: Container image reference does not match the configured OpenFOAM identity" >&2
      echo "       Image reference: $imageRef" >&2
      echo "       Required prefix: $expectedImagePrefix" >&2
      exit 1
   fi
   echo "PASS: Container image reference starts with '$expectedImagePrefix'"
   if [[ "$ENGINE" == "docker" ]]; then
      docker image inspect "$imageRef" >/dev/null 2>&1 || { echo "ERROR: Image not found in Docker image store: $imageRef" >&2; exit 1; }
      imageIdentity=$(docker image inspect "$imageRef" --format '{{.Id}}')
      docker images --format '  Size: {{.Size}}' "$imageRef" | head -n 1
   else
      podman image exists "$imageRef" || { echo "ERROR: Image not found in Podman image store: $imageRef" >&2; exit 1; }
      imageIdentity=$(podman image inspect "$imageRef" --format '{{.Id}}')
      podman images --format '  Size: {{.Size}}' "$imageRef" | head -n 1
   fi
   echo "  Image ID: $imageIdentity"
   echo "Resolved image: $imageRef" >> "$validationDetailsFile"
   echo "Image ID: $imageIdentity" >> "$validationDetailsFile"
fi
echo "Expected image prefix: $expectedImagePrefix" >> "$validationDetailsFile"
echo "PASS: Image found"
echo

# --- Step 4: Read and validate the OpenFOAM environment
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking the OpenFOAM environment"
WM_PROJECT_VERSION=$(engine_run bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || {
   echo "ERROR: Failed to read WM_PROJECT_VERSION from the image environment" >&2
   exit 1
}
[[ -n "$WM_PROJECT_VERSION" ]] || {
   echo "ERROR: WM_PROJECT_VERSION is empty in the image environment" >&2
   exit 1
}
[[ "$WM_PROJECT_VERSION" =~ ^v?[0-9][0-9A-Za-z.-]*$ ]] || {
   echo "ERROR: WM_PROJECT_VERSION has an invalid value in the image environment" >&2
   echo "       Reported value: '$WM_PROJECT_VERSION'" >&2
   exit 1
}
echo "PASS: Image environment provides a valid WM_PROJECT_VERSION='$WM_PROJECT_VERSION'"
if [[ "$WM_PROJECT_VERSION" != "$OPENFOAM_VERSION" ]]; then
   echo "ERROR: OpenFOAM version mismatch between the image and configuration" >&2
   echo "       Image environment: $WM_PROJECT_VERSION" >&2
   echo "       Configuration:     $OPENFOAM_VERSION" >&2
   exit 1
fi
echo "PASS: WM_PROJECT_VERSION matches OPENFOAM_VERSION='$OPENFOAM_VERSION'"
echo "Image OpenFOAM version: $WM_PROJECT_VERSION" >> "$validationDetailsFile"
echo

# --- Step 5: Check the configured ThirdParty compilation summary
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$THIRDPARTY_BUILD_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: THIRDPARTY_BUILD_LOG=NO_CHECK"
else
   echo "Step $testNum - Checking the ThirdParty compilation summary"
   check_compilation_log "ThirdParty compilation log" "$THIRDPARTY_BUILD_LOG"
fi
echo

# --- Step 6: Check the configured ParaView compilation summary
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$PARAVIEW_BUILD_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: PARAVIEW_BUILD_LOG=NO_CHECK"
else
   echo "Step $testNum - Checking the ParaView compilation summary"
   check_compilation_log "ParaView compilation log" "$PARAVIEW_BUILD_LOG"
fi
echo

# --- Step 7: Check the configured OpenFOAM compilation summary
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$OPENFOAM_BUILD_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: OPENFOAM_BUILD_LOG=NO_CHECK"
else
   echo "Step $testNum - Checking the OpenFOAM compilation summary"
   check_compilation_log "OpenFOAM compilation log" "$OPENFOAM_BUILD_LOG"
fi
echo

# --- Step 8: Check the configured OpenFOAM basic-functionality log
# The build-time test log must contain the standard Usage and Options headings
# and must identify the same OpenFOAM version reported by the image environment.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$OPENFOAM_TOOL_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: OPENFOAM_TOOL_LOG=NO_CHECK"
else
   echo "Step $testNum - Checking the OpenFOAM basic-functionality log"
   toolLogPath=$(resolve_internal_path "$OPENFOAM_TOOL_LOG") || {
      echo "ERROR: Failed to resolve OpenFOAM tool log path: $OPENFOAM_TOOL_LOG" >&2
      record_failure "OpenFOAM tool log path could not be resolved"
      toolLogPath=""
   }

   if [[ -n "$toolLogPath" ]]; then
      if ! engine_run test -f "$toolLogPath"; then
         echo "FAIL: OpenFOAM tool log is not available: $toolLogPath"
         echo "      This can be expected for a partial-stage image."
         record_failure "OpenFOAM tool log is not accessible"
      else
         missing=0
         engine_run grep -qE '^Usage:' "$toolLogPath" || { echo "  Missing: ^Usage:"; missing=1; }
         engine_run grep -qE '^Options:' "$toolLogPath" || { echo "  Missing: ^Options:"; missing=1; }
         engine_run grep -qF "Using: OpenFOAM-${WM_PROJECT_VERSION}" "$toolLogPath" || {
            echo "  Missing: Using: OpenFOAM-${WM_PROJECT_VERSION}"
            missing=1
         }

         if [[ $missing -eq 0 ]]; then
            echo "PASS: All required output signatures found in $toolLogPath"
            engine_run grep -E '^Usage:|^Options:' "$toolLogPath" || true
            engine_run grep -F "Using: OpenFOAM-${WM_PROJECT_VERSION}" "$toolLogPath" || true
         else
            echo "FAIL: Required output signatures were not found in $toolLogPath"
            record_failure "OpenFOAM tool basic output is incomplete"
         fi
      fi
   fi
fi
echo

# --- Final summary
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Image: $imageRef"
echo "Engine: $ENGINE"
echo "OpenFOAM version: $WM_PROJECT_VERSION"
echo "Total steps run: $testNum"

echo "Validation artifacts: $runArtifactsDir"
echo "Status file: $statusFile"
echo "Complete run log: $runLog"
echo "Validation summary: $validationSummaryFile"
if [[ $totalFailed -eq 0 ]]; then
   {
      echo "Result: SUCCESS"
      echo "Image: $imageRef"
      echo "Engine: $ENGINE"
      echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
      echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
      echo "Image OpenFOAM version: $WM_PROJECT_VERSION"
      echo "Total steps run: $testNum"
      echo "Validation checks failed: 0"
   } > "$validationSummaryFile"
   echo "ALL STEPS PASSED: Image '$imageRef' passed OpenFOAM image validation."
   exit 0
else
   {
      echo "Result: FAILED"
      echo "Image: $imageRef"
      echo "Engine: $ENGINE"
      echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
      echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
      echo "Image OpenFOAM version: $WM_PROJECT_VERSION"
      echo "Total steps run: $testNum"
      echo "Validation checks failed: $totalFailed"
      printf 'Failure: %s\n' "${failedTests[@]}"
   } > "$validationSummaryFile"
   echo "$totalFailed VALIDATION CHECK(S) FAILED:"
   for test in "${failedTests[@]}"; do echo "  - $test"; done
   exit 1
fi
