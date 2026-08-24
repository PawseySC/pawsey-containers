#!/usr/bin/env bash
# General basic functional tests for OpenFOAM container images.
#
# This script runs a small set of functional checks against an OpenFOAM image
# using Docker, Podman, or Singularity. The common test procedure is kept in
# this central script, while OpenFOAM-version-specific values are read from a
# buildAndValidationConfig/openfoamBuildAndValidation.config file stored under the corresponding version directory.
#
# The configuration can be selected in either of the following ways:
#   1. Use --recipe-dir to identify an OpenFOAM version directory. The script
#      then reads <recipe-dir>/buildAndValidationConfig/openfoamBuildAndValidation.config.
#   2. Use --config to provide the configuration-file path explicitly.
#
# The configuration must define DEFAULT_TOOL, OPENFOAM_FORK, and
# OPENFOAM_VERSION. The configured tool can be overridden for an individual run
# with --tool. The required --image option identifies a Docker/Podman image
# reference or a path to a Singularity SIF image.
#
# Examples:
#   openfoamBasicTests.sh --recipe-dir v2406 --engine podman \
#      --image openfoam:v2406
#   openfoamBasicTests.sh --config v2406/buildAndValidationConfig/openfoamBuildAndValidation.config \
#      --engine singularity --tool icoFoam --image openfoam--v2406.sif
#
# The script stops at the first failed check and returns a nonzero exit status.
# A successful run confirms that the engine and image are accessible, the
# OpenFOAM environment is initialized, and the selected OpenFOAM tool responds
# with the expected help-output signatures. Each tracked invocation stores its
# output and status under <recipe-dir>/artifacts/tests/basic/.
#
# Exit status:
#   0  All functional tests passed.
#   1  Invalid input, setup failure, or functional-test failure.
#
# CI/CD systems can use this exit status to determine whether the test job
# should pass or fail.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

# Treat any use of an unset variable as an error.
set -u

# --- Initial settings
thisScript=$(basename "$0")
testNum=0
ENGINE=""
USER_TOOL=""
recipeDirInput=""
configFileInput=""
imageRef=""
recipeDir=""
configFile=""
basicTestsArtifactsDir=""
runArtifactsDir=""
runLog=""
statusFile=""
testDetailsFile=""
toolLog=""

# --- Command-line help
usage() {
   cat <<USAGE
Usage: $thisScript --recipe-dir <directory> --engine docker|podman|singularity --image <image> [--tool TOOL]
       $thisScript --config <file> --engine docker|podman|singularity --image <image> [--tool TOOL]
       $thisScript --help

  --recipe-dir, -r <directory>  OpenFOAM version directory containing the docker recipe and
                                 the buildAndValidationConfig/openfoamBuildAndValidation.config file
  --config, -c <file>           Explicit openfoamBuildAndValidation configuration file
  --engine, -b <engine>         docker, podman, or singularity
  --image, -i <image>           Required image name:tag or path to a .sif image
  --tool <tool>                 Override DEFAULT_TOOL from the configuration
  --help, -h                    Show this help message and exit
USAGE
}

# --- Helper: run a command inside the selected image
# Docker and Podman use "run --rm", while Singularity uses "exec".
engine_run() {
   if [[ "$ENGINE" == "singularity" ]]; then
      singularity exec "$imageRef" "$@"
   else
      "$ENGINE" run --rm "$imageRef" "$@"
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
         recipeDirInput="$2"
         shift 2
         ;;
      --config|-c)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --config requires <file>" >&2
            usage >&2
            exit 1
         fi
         configFileInput="$2"
         shift 2
         ;;
      --engine|-b)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --engine requires docker|podman|singularity" >&2
            usage >&2
            exit 1
         fi
         ENGINE="$2"
         shift 2
         ;;
      --image|-i)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --image requires <image>" >&2
            usage >&2
            exit 1
         fi
         imageRef="$2"
         shift 2
         ;;
      --tool)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --tool requires an OpenFOAM tool name" >&2
            usage >&2
            exit 1
         fi
         USER_TOOL="$2"
         shift 2
         ;;
      -h|--help)
         usage
         exit 0
         ;;
      -*)
         echo "ERROR: Unknown option '$1'" >&2
         usage >&2
         exit 1
         ;;
      *)
         echo "ERROR: Unexpected positional argument '$1'; use --image <image>" >&2
         usage >&2
         exit 1
         ;;
   esac
done

# --- Validate command-line arguments
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

# --- Locate the version-specific openfoamBuildAndValidation configuration
# Exactly one of --recipe-dir and --config must identify the configuration.
# When --config is used, it must retain the documented version-directory layout
# so that persistent test artifacts can be placed under the correct recipe tree.
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

# --- Create the persistent artifact directory for this test invocation
basicTestsArtifactsDir="${recipeDir}/artifacts/tests/basic"
mkdir -p "$basicTestsArtifactsDir"

latestLink="${basicTestsArtifactsDir}/latest"
if [[ -e "$latestLink" && ! -L "$latestLink" ]]; then
   echo "ERROR: Refusing to remove non-symbolic-link path: $latestLink" >&2
   exit 1
fi
if ! rm -f "$latestLink"; then
   echo "ERROR: Failed to remove latest link: $latestLink" >&2
   exit 1
fi

echo "This directory contains timestamped basic-test artifacts. The latest link identifies the most recent tracked test invocation. If the link is absent, the most recent command failed before invocation tracking was established." > "${basicTestsArtifactsDir}/README.txt"

testTimestamp=$(date '+%Y%m%dT%H%M%S%z')
runArtifactsName="${testTimestamp}_${ENGINE}"
runArtifactsDir="${basicTestsArtifactsDir}/${runArtifactsName}"
if ! mkdir "$runArtifactsDir"; then
   echo "ERROR: Cannot create test artifact directory: $runArtifactsDir" >&2
   exit 1
fi
ln -sfn "$runArtifactsName" "$latestLink"

runLog="${runArtifactsDir}/run.log"
statusFile="${runArtifactsDir}/status.txt"
testDetailsFile="${runArtifactsDir}/test-details.txt"
toolLog="${runArtifactsDir}/tool-help.log"
printf '%s\n' "RUNNING" > "$statusFile"

record_test_status() {
   local exitStatus=$?
   trap - EXIT
   if [[ $exitStatus -eq 0 ]]; then
      printf '%s\n' "SUCCESS" > "$statusFile"
   else
      printf '%s\n' "FAILED" > "$statusFile"
   fi
   exit "$exitStatus"
}
trap record_test_status EXIT

# Preserve the complete script output while continuing to display it.
exec > >(tee "$runLog") 2>&1

echo "Test artifacts: $runArtifactsDir"
echo "Complete run log: $runLog"
echo "Status file: $statusFile"
echo

# --- Load and validate the version-specific settings
# DEFAULT_TOOL selects the test command. OPENFOAM_FORK and OPENFOAM_VERSION
# define the expected external image name and internal OpenFOAM version.
[[ -r "$configFile" ]] || { echo "ERROR: openfoamBuildAndValidation configuration is not readable: $configFile" >&2; exit 1; }
unset DEFAULT_TOOL OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in DEFAULT_TOOL OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || {
      echo "ERROR: $requiredSetting is not defined in $configFile" >&2
      exit 1
   }
done

# Use the command-line tool when supplied; otherwise use the configured default.
if [[ -n "$USER_TOOL" ]]; then
   OF_TOOL="$USER_TOOL"
   toolSource="command-line override"
else
   OF_TOOL="$DEFAULT_TOOL"
   toolSource="$configFile"
fi

# Record and display the resolved test inputs before changing the engine environment.
{
   echo "Test timestamp: $testTimestamp"
   echo "Engine: $ENGINE"
   echo "Image input: $imageRef"
   echo "Configuration: $configFile"
   echo "Recipe directory: $recipeDir"
   echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
   echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
   echo "OpenFOAM tool: $OF_TOOL"
   echo "Tool source: $toolSource"
} > "$testDetailsFile"

echo "Will test image: $imageRef"
echo "Engine: $ENGINE"
echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
echo "OpenFOAM tool: $OF_TOOL"
echo "Tool source: $toolSource"

# --- Step 1: Set up the selected container engine environment
# These actions are specific to the systems on which the tests are run:
#   - Docker Desktop is started when Docker is not already responsive.
#   - Pawsey's Podman environment setup script is sourced.
#   - Pawsey's Singularity module is loaded.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Setting up $ENGINE environment"
case "$ENGINE" in
   docker)
      if ! docker info >/dev/null 2>&1; then
         echo "Starting Docker Desktop..."
         open -a Docker
         for _ in {1..30}; do docker info >/dev/null 2>&1 && break; sleep 1; done
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
echo "PASS: ${ENGINE^} ready"

# --- Step 2: Check that the selected engine is accessible
# A nonempty version response confirms that the engine command can be executed.
# Podman also requires XDG_DATA_HOME from the Pawsey setup script.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking if $ENGINE is accessible"
engineVersion=$($ENGINE --version 2>&1) || { echo "ERROR: Failed to execute $ENGINE --version" >&2; exit 1; }
[[ -n "$engineVersion" ]] || { echo "ERROR: Empty engine version" >&2; exit 1; }
echo "  $engineVersion"
echo "Engine version: $engineVersion" >> "$testDetailsFile"
if [[ "$ENGINE" == "podman" ]]; then
   [[ -n "${XDG_DATA_HOME:-}" ]] || { echo "ERROR: XDG_DATA_HOME is not set" >&2; exit 1; }
   echo "  XDG_DATA_HOME=$XDG_DATA_HOME"
fi
echo "PASS"

# --- Step 3: Verify the requested image identity and existence
# The configured fork and version define the required external image-name prefix.
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
   echo "Resolved image: $imageRef" >> "$testDetailsFile"
   echo "Image SHA256: $imageIdentity" >> "$testDetailsFile"
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
   echo "Resolved image: $imageRef" >> "$testDetailsFile"
   echo "Image ID: $imageIdentity" >> "$testDetailsFile"
fi
echo "Expected image prefix: $expectedImagePrefix" >> "$testDetailsFile"
echo "PASS: Image found"

# --- Step 4: Verify the OpenFOAM environment and configured version
# First validate that WM_PROJECT_VERSION is available and structurally valid.
# Then verify that it matches OPENFOAM_VERSION from the selected configuration.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Testing the OpenFOAM environment"
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
echo "Image OpenFOAM version: $WM_PROJECT_VERSION" >> "$testDetailsFile"

# --- Step 5: Verify that the selected OpenFOAM tool runs
# Capture all help output persistently, then check for the standard Usage,
# Options, and OpenFOAM version signatures.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Testing '$OF_TOOL -help'"
# toolLog was assigned when the invocation artifact directory was created.
engine_run "$OF_TOOL" -help >"$toolLog" 2>&1 || { echo "ERROR: $OF_TOOL -help returned nonzero" >&2; cat "$toolLog"; exit 1; }
missing=0
grep -qE '^Usage:' "$toolLog" || { echo "  Missing: ^Usage:"; missing=1; }
grep -qE '^Options:' "$toolLog" || { echo "  Missing: ^Options:"; missing=1; }
grep -qF "Using: OpenFOAM-${WM_PROJECT_VERSION}" "$toolLog" || { echo "  Missing: Using: OpenFOAM-${WM_PROJECT_VERSION}"; missing=1; }
[[ $missing -eq 0 ]] || { echo "ERROR: Required output signatures were not found" >&2; cat "$toolLog"; exit 1; }
cat "$toolLog"
echo "PASS: '$OF_TOOL -help' works"

# --- Final summary
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Total steps run: $testNum"
echo "Test artifacts: $runArtifactsDir"
echo "Status file: $statusFile"
echo "Complete run log: $runLog"
echo "Tool output log: $toolLog"
echo "ALL STEPS PASSED: Image '$imageRef' with $ENGINE passed basic OpenFOAM testing."
# Return success to the caller.
exit 0
