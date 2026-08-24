#!/usr/bin/env bash
# General build and validation script for OpenFOAM container images.
#
# This script builds an OpenFOAM image with Docker or Podman and then performs
# a sequence of checks on the build result. The OpenFOAM version directory is
# supplied with --recipe-dir and is used as the container build context. It must
# contain the following version-specific configuration file:
#
#   buildAndValidationConfig/openfoamBuildAndValidation.config
#
# The build-validation configuration defines the paths of the compilation and
# functional-test logs to inspect inside the completed image. The following
# settings must be defined:
#
#   THIRDPARTY_BUILD_LOG  ThirdParty authoritative compilation summary.
#   PARAVIEW_BUILD_LOG    ParaView authoritative compilation summary.
#   OPENFOAM_BUILD_LOG    OpenFOAM authoritative compilation summary.
#   OPENFOAM_TOOL_LOG     OpenFOAM basic-functionality log created at build time.
#   OPENFOAM_FORK         Expected image repository and recipe-name stem.
#   OPENFOAM_VERSION      Expected OpenFOAM version and recipe-name version.
#
# Internal paths may contain OpenFOAM environment variables such as
# $WM_THIRD_PARTY_DIR and $WM_PROJECT_DIR. These variables are preserved when
# the configuration is loaded and are expanded inside the completed image,
# where the OpenFOAM environment is available.
#
# Assign NO_CHECK to an individual log setting when that validation does not
# apply to a particular OpenFOAM version, image type, or partial build stage.
# The corresponding validation step will then be reported as skipped rather
# than failed. For example:
#
#   PARAVIEW_BUILD_LOG='NO_CHECK'
#
# The script reads the OpenFOAM fork, OpenFOAM version, operating-system version,
# and MPICH version from Dockerfile ARG instructions. These values define the
# generated image name. Repeated --build-arg NAME=VALUE options can override
# Dockerfile ARG values, including values used in the generated image name.
#
# A complete image is built by default. For development and troubleshooting,
# --target builds a named Dockerfile stage. The optional --targetFrom setting
# temporarily changes the base of that selected stage without modifying the
# original Dockerfile. Any generated Dockerfile is kept under the version's
# tmp/ directory. Persistent output is grouped under a timestamped artifacts/
# directory for each invocation.
#
# After the build, the script verifies that the image exists in the local
# container-engine registry. It then checks the engine build log and the
# configured compilation and functional-test logs stored inside the image.
#
# Argument, setup, build, and image-registry failures stop the script
# immediately. The later diagnostic and internal-log checks continue after a
# failure so that all detected validation problems can be included in the final
# summary.
#
# Examples:
#   openfoamContainerBuild.sh --recipe-dir v2406 --engine podman
#
#   openfoamContainerBuild.sh --recipe-dir v2406 --engine docker \
#      --build-arg OF_COMPILE_TASKS=16
#
#   openfoamContainerBuild.sh --recipe-dir v2406 --engine podman \
#      --target openfoam-development
#
#   openfoamContainerBuild.sh --recipe-dir v2406 --engine podman \
#      --target openfoam-development --targetFrom openfoam-base
#
#   openfoamContainerBuild.sh --help
#
# Exit status:
#   0  The image build and all enabled validation checks passed.
#   1  Invalid input, setup failure, build failure, or validation failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

# --- Initial settings
# Runtime state is initialized before command-line values are parsed.
thisScript=$(basename "$0")
scriptDir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
testNum=0
failedTests=()
totalFailed=0
stageName=""
buildArgs=()
declare -A buildArgValues=()
recipeDirInput=""
recipeDir=""
recipeFile=""
tmpDir=""
artifactsDir=""
runArtifactsDir=""
runLog=""
buildLog=""
buildCommandFile=""
imageDetailsFile=""
configFile=""

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  $thisScript --recipe-dir <directory> --engine docker|podman [--build-arg NAME=VALUE]... [--target <stageName>] [--targetFrom <startingStage>]
  $thisScript --help

Options:
  --recipe-dir, -r <directory>  OpenFOAM build-context directory containing the docker recipe and
                                 the buildAndValidationConfig/openfoamBuildAndValidation.config file
  --engine, -b <engine>         Container engine: docker or podman (required)
  --build-arg NAME=VALUE        Override a Dockerfile ARG; may be repeated
  --target <stageName>          Build a specific named Dockerfile stage
  --targetFrom <startingStage>  Replace the selected target stage base; requires --target
  --help, -h                    Show this help message and exit
USAGE
}

# --- Parse and validate command-line arguments
ENGINE=""
stageName=""
stageFrom=""
while [[ $# -gt 0 ]]; do
   case $1 in
      --recipe-dir|-r)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --recipe-dir requires <directory>" >&2
            exit 1
         fi
         recipeDirInput="$2"
         shift 2
         ;;
      --engine|-b)
         ENGINE="$2"
         if [[ -z "$ENGINE" ]]; then
            echo "ERROR: --engine requires docker|podman" >&2
            usage
            exit 1
         fi
         shift 2
         ;;
      --build-arg)
         if [[ $# -lt 2 || "$2" != *=* ]]; then
            echo "ERROR: --build-arg requires NAME=VALUE" >&2
            exit 1
         fi
         buildArgName="${2%%=*}"
         buildArgValue="${2#*=}"
         if [[ ! "$buildArgName" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "ERROR: Invalid build-argument name: '$buildArgName'" >&2
            exit 1
         fi
         buildArgs+=(--build-arg "$2")
         buildArgValues["$buildArgName"]="$buildArgValue"
         shift 2
         ;;
      --target)
         stageName="$2"
         if [[ -z "$stageName" ]]; then
            echo "ERROR: --target requires <stageName>" >&2
            usage
            exit 1
         fi
         shift 2
         ;;
      --targetFrom)
         stageFrom="$2"
         if [[ -z "$stageFrom" ]]; then
            echo "ERROR: --targetFrom requires <startingStage>" >&2
            usage
            exit 1
         fi
         shift 2
         ;;
      -h|--help)
         usage
         exit 0
         ;;
      *)
         echo "ERROR: Unknown option '$1'" >&2
         usage
         exit 1
         ;;
   esac
done

# --- Validate and prepare the OpenFOAM version directory
# The selected directory is the build context. Temporary Dockerfiles are kept
# under tmp/, while build logs intended for later inspection go to artifacts/.
if [[ -z "$recipeDirInput" ]]; then
   echo "ERROR: --recipe-dir <directory> is required" >&2
   usage
   exit 1
fi
if [[ ! -d "$recipeDirInput" ]]; then
   echo "ERROR: Recipe directory does not exist: $recipeDirInput" >&2
   exit 1
fi
recipeDir=$(cd -- "$recipeDirInput" && pwd)
recipeFile=""
tmpDir="${recipeDir}/tmp"
artifactsRootDir="${recipeDir}/artifacts"
artifactsDir="${artifactsRootDir}/container"
configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
if [[ ! -r "$configFile" ]]; then
   echo "ERROR: Build-validation configuration is not readable: $configFile" >&2
   exit 1
fi
mkdir -p "$tmpDir" "$artifactsDir"
latestLink="${artifactsDir}/latest"
if [[ -e "$latestLink" && ! -L "$latestLink" ]]; then
   echo "ERROR: Refusing to remove non-symbolic-link path: $latestLink" >&2
   exit 1
fi
if ! rm -f "$latestLink"; then
   echo "ERROR: Failed to remove latest link: $latestLink" >&2
   exit 1
fi
echo "This directory contains disposable temporary files only. It can be removed anytime." > "${tmpDir}/README.txt"
echo "This directory contains timestamped build artifacts. The latest link identifies the most recent tracked build invocation. If the link is absent, the most recent command failed before invocation tracking was established." > "${artifactsDir}/README.txt"

# --- Create the persistent artifact directory for this invocation
# Use one timestamped directory for all output from the invocation. The engine
# and selected build stages make the directory identifiable without inspecting
# its contents. The latest symbolic link points to the most recent invocation.
buildTimestamp=$(date '+%Y%m%dT%H%M%S%z')
if [[ -n "$stageName" && -n "$stageFrom" ]]; then
   buildKind="${stageName}_from-${stageFrom}"
elif [[ -n "$stageName" ]]; then
   buildKind="$stageName"
else
   buildKind="full"
fi
runArtifactsName="${buildTimestamp}_${ENGINE}_${buildKind}"
runArtifactsDir="${artifactsDir}/${runArtifactsName}"
mkdir -p "$runArtifactsDir"
ln -sfn "$runArtifactsName" "${artifactsDir}/latest"

runLog="${runArtifactsDir}/run.log"
buildLog="${runArtifactsDir}/build.log"
buildCommandFile="${runArtifactsDir}/build-command.txt"
imageDetailsFile="${runArtifactsDir}/image-details.txt"

# Preserve the complete script output while continuing to display it.
exec > >(tee "$runLog") 2>&1

echo "Invocation artifacts: $runArtifactsDir"
echo "Complete run log: $runLog"
echo

# --- Load the version-specific build-validation settings
# Clear inherited values first so the four internal log paths must come from the
# selected version configuration. A value of NO_CHECK explicitly disables its
# corresponding validation step.
unset OPENFOAM_FORK OPENFOAM_VERSION THIRDPARTY_BUILD_LOG PARAVIEW_BUILD_LOG OPENFOAM_BUILD_LOG OPENFOAM_TOOL_LOG
# shellcheck source=/dev/null
source "$configFile"

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

recipeFile="${recipeDir}/${OPENFOAM_FORK}--${OPENFOAM_VERSION}.dockerfile"
if [[ ! -f "$recipeFile" ]]; then
   echo "ERROR: OpenFOAM docker recipe not found: $recipeFile" >&2
   exit 1
fi
echo "OpenFOAM docker recipe: $recipeFile"

# --- Validate the selected container engine
if [[ -z "$ENGINE" ]]; then
   echo "ERROR: --engine docker|podman is required" >&2
   echo "Usage: $0 --recipe-dir <directory> --engine docker|podman [--build-arg NAME=VALUE]... [--target <stageName>] [--targetFrom <startingStage>]" >&2
   exit 1
fi
if [[ "$ENGINE" != "docker" && "$ENGINE" != "podman" ]]; then
   echo "ERROR: --engine must be 'docker' or 'podman', got '$ENGINE'" >&2
   exit 1
fi

# --- Validate the relationship between partial-build options
# --targetFrom only has meaning when a target stage has also been selected.
if [[ -n "$stageFrom" && -z "$stageName" ]]; then
   echo "ERROR: --targetFrom requires --target" >&2
   exit 1
fi

echo "Parsed: recipeDir='$recipeDir' ENGINE='$ENGINE' stageName='$stageName' stageFrom='$stageFrom'"
echo "Build-validation configuration: $configFile"
if [[ ${#buildArgs[@]} -gt 0 ]]; then
   echo "Build-argument overrides:"
   for ((i=0; i<${#buildArgs[@]}; i+=2)); do
      echo "  ${buildArgs[$((i + 1))]}"
   done
else
   echo "Build-argument overrides: none; Dockerfile defaults will be used"
fi
echo

# --- Step 1: Set up the selected container engine environment
# Docker Desktop is started when Docker is not responsive. On Pawsey container
# build nodes, the site Podman setup script initializes the required settings.
# This step stops the script immediately on failure.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Setting up $ENGINE environment"
if [[ "$ENGINE" == "docker" ]]; then
   echo "Step $testNum - Starting Docker engine"
   if ! docker info >/dev/null 2>&1; then
      echo "Starting Docker Desktop..."
      open -a Docker
      # Wait max 30s
      for i in {1..30}; do
         if docker info >/dev/null 2>&1; then
            break
         fi
         sleep 1
      done
   fi
   if ! docker info >/dev/null 2>&1; then
      echo "✖ Step $testNum FAIL: Docker failed to start"
      ((totalFailed++))
      exit 1
   fi
else
   echo "Step $testNum - Sourcing the podman settings"
   # Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
   if ! source /container/setup_podman.sh 2>/dev/null; then
      echo "✖ Step $testNum FAIL: Failed to: source /container/setup_podman.sh"
      ((totalFailed++))
      exit 1
   fi
fi
echo "✓ Step $testNum PASS: ${ENGINE^} ready"
echo

# --- Step 2: Confirm that the container engine is accessible
# A nonempty version response confirms that the command can be executed. Podman
# also requires XDG_DATA_HOME from the Pawsey setup script.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking if $ENGINE is accessible."
ENGINEVersion=$($ENGINE --version)
if [[ -z "$ENGINEVersion" ]]; then
   echo "✖ Step $testNum FAIL: Failed to execute: $ENGINE --version"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum ${ENGINE}Version=$ENGINEVersion"
if [[ "$ENGINE" == "podman" ]]; then
   # Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
   if [[ -z "$XDG_DATA_HOME" ]]; then
      echo "✖ Step $testNum FAIL: Failed to check existance of: XDG_DATA_HOME"
      echo "  Probably forgot to: source /container/setup_podman.sh"
      ((totalFailed++))
      exit 1
   fi
   echo "✓ Step $testNum XDG_DATA_HOME=$XDG_DATA_HOME"
fi
echo "✓ Step $testNum PASS"
echo

# --- Step 3: Read the values used to construct the image name
# Start with Dockerfile ARG defaults, then apply matching command-line build-arg
# overrides. The final values form the repository and tag used by this script.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Setting the variables for defining names"
OF_FORK=$(grep '^ARG OF_FORK=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
OF_VERSION=$(grep '^ARG OF_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
OS_VERSION=$(grep '^ARG BASE_IMAGE_OS_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
MPICH_VERSION=$(grep '^ARG BASE_IMAGE_MPICH_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)

# Apply command-line overrides that affect the generated image reference.
# The last repeated --build-arg value wins.
OF_FORK="${buildArgValues[OF_FORK]:-$OF_FORK}"
OF_VERSION="${buildArgValues[OF_VERSION]:-$OF_VERSION}"
OS_VERSION="${buildArgValues[BASE_IMAGE_OS_VERSION]:-$OS_VERSION}"
MPICH_VERSION="${buildArgValues[BASE_IMAGE_MPICH_VERSION]:-$MPICH_VERSION}"

echo "OF_FORK: '$OF_FORK'"
echo "OF_VERSION: '$OF_VERSION'"
echo "OS_VERSION: '$OS_VERSION'"
echo "MPICH_VERSION: '$MPICH_VERSION'"

if [[ -z "$OF_FORK" || -z "$OF_VERSION" || -z "$OS_VERSION" || -z "$MPICH_VERSION" ]]; then
   echo "✖ Step $testNum FAIL: Failed to extract required variables from docker recipe"
   ((totalFailed++))
   exit 1
fi
if [[ "$OF_FORK" != "$OPENFOAM_FORK" ]]; then
   echo "✖ Step $testNum FAIL: OpenFOAM fork mismatch between recipe settings and configuration"
   echo "  Recipe/build setting: $OF_FORK"
   echo "  Configuration:        $OPENFOAM_FORK"
   ((totalFailed++)); exit 1
fi
if [[ "$OF_VERSION" != "$OPENFOAM_VERSION" ]]; then
   echo "✖ Step $testNum FAIL: OpenFOAM version mismatch between recipe settings and configuration"
   echo "  Recipe/build setting: $OF_VERSION"
   echo "  Configuration:        $OPENFOAM_VERSION"
   ((totalFailed++)); exit 1
fi
echo "✓ Step $testNum PASS: Recipe identity matches OPENFOAM_FORK='$OPENFOAM_FORK' and OPENFOAM_VERSION='$OPENFOAM_VERSION'"
echo

# --- Step 4: Validate the optional target stage
# When --target is supplied, the Dockerfile must define the requested named stage.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Validating if stage name exists in the Dockerfile"
if [[ -n "$stageName" ]]; then
   if ! grep -qiE "^FROM .* AS[[:space:]]+$stageName[[:space:]]*" "$recipeFile"; then
      echo "✖ Step $testNum FAIL: Stage '$stageName' not found in $recipeFile"
      echo "  Looking for line: FROM ... as $stageName"
      ((totalFailed++))
      exit 1
   fi
   echo "✓ Step $testNum PASS: Stage '$stageName' found"
else
   echo "Step $testNum skipped. Not needed"
fi
echo

# --- Step 5: Validate the optional replacement base stage
# The --targetFrom stage must also be a named stage in the original Dockerfile.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Validating if stageFrom name exists in the Dockerfile"
if [[ -n "$stageFrom" ]]; then
   if ! grep -qiE "^FROM .* AS[[:space:]]+$stageFrom[[:space:]]*" "$recipeFile"; then
      echo "✖ Step $testNum FAIL: Stage '$stageFrom' not found in $recipeFile"
      echo "  Looking for line: FROM ... as $stageFrom"
      echo "  Can't be used as a stageFrom value"
      ((totalFailed++))
      exit 1
   fi
   echo "✓ Step $testNum PASS: Stage '$stageFrom' found"
else
   echo "Step $testNum skipped. Not needed"
fi
echo

# --- Step 6: Create a temporary Dockerfile when --targetFrom is used
# The selected target stage is rewritten as "FROM <stageFrom> AS <stageName>" in
# a temporary copy. The original version-specific Dockerfile remains unchanged.
((++testNum))
tempRecipeFile=""
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Creating temp Dockerfile: FROM $stageFrom AS $stageName"
if [[ -n "$stageFrom" && -n "$stageName" ]]; then
   recipeName=$(basename $recipeFile)
   tempRecipeFile="${tmpDir}/${recipeName}.$$.tmp"
   cp "$recipeFile" "$tempRecipeFile"

   # Pass 1: Comment line starting with FROM, ending with AS $stageName
   sed "/^FROM .* AS[[:space:]]*$stageName$/s/^/#-ha-#/" "$tempRecipeFile" > "${tempRecipeFile}.new.tmp"

   # Pass 2: Insert new line after commented one
   sed "/^#-ha-#FROM .* AS[[:space:]]*$stageName$/a\\
FROM $stageFrom AS $stageName" "${tempRecipeFile}.new.tmp" > "$tempRecipeFile" && rm "${tempRecipeFile}.new.tmp"

   # Verify EXACT line exists
   if ! grep -q "^FROM[[:space:]]\+$stageFrom[[:space:]]\+AS[[:space:]]\+$stageName" "$tempRecipeFile"; then
      echo "✖ Step $testNum FAIL: No 'FROM $stageFrom AS $stageName' in $tempRecipeFile"
      ((totalFailed++))
      exit 1
   fi

   recipeFile="$tempRecipeFile"
   echo "✓ Step $testNum PASS: temporal $recipeFile created (1 line replaced)"
   echo "                      It will be used for the build with:"
   grep -iE "^FROM .* AS[[:space:]]+$stageName[[:space:]]*" $recipeFile
else
   echo "Step $testNum skipped no temporary Dockefile needed (no --targetFrom)"
fi
echo

# --- Step 7: Build the image and record the complete output
# Build options are held in arrays so every argument is passed safely. The build
# runs from the selected context and its combined output is saved in artifacts/.
((++testNum))
imageName="${OF_FORK}"
imageTag="${OF_VERSION}-mpich${MPICH_VERSION}-ubuntu${OS_VERSION}"
buildOptions=()
if [[ -n "$stageName" ]]; then
   imageTag="${imageTag}-${stageName}"
   buildOptions+=(--target "$stageName")
fi
if [[ -n "$stageFrom" ]]; then
   imageTag="${imageTag}-from-${stageFrom}"
fi
imageFull="${imageName}:${imageTag}"
expectedImagePrefix="${OPENFOAM_FORK}:${OPENFOAM_VERSION}"
if [[ "$imageFull" != "${expectedImagePrefix}"* ]]; then
   echo "✖ Step $testNum FAIL: Generated image name does not match the configured OpenFOAM identity"
   echo "  Generated image: $imageFull"
   echo "  Required prefix: $expectedImagePrefix"
   ((totalFailed++)); exit 1
fi
echo "✓ Step $testNum: Generated image name starts with '$expectedImagePrefix'"
logFileBuild="$buildLog"
if [[ "$ENGINE" == "docker" ]]; then
   buildOptions+=(--progress=plain)
else
   buildOptions+=(--format=docker)
fi
buildOptions+=(--ulimit nofile=16384:16384)
if [[ ${#buildArgs[@]} -gt 0 ]]; then
   buildOptions+=("${buildArgs[@]}")
fi

# Pass the recipe relative to the build context.
recipeRelative=$(realpath --relative-to="$recipeDir" "$recipeFile")
buildCommand=(
   "$ENGINE" build
   "${buildOptions[@]}"
   -t "$imageFull"
   -f "$recipeRelative"
   .
)

echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Building with $ENGINE the image $imageFull"
printf 'Recorded build command:'
printf ' %q' "${buildCommand[@]}"
printf '\n'
{
   printf 'cd %q &&' "$recipeDir"
   printf ' %q' "${buildCommand[@]}"
   printf '\n'
} > "$buildCommandFile"

# Run from the selected build-context directory.
echo "=== BUILD START: $(date)" | tee "$logFileBuild"
(
   cd "$recipeDir"
   time "${buildCommand[@]}"
) |& tee -a "$logFileBuild"
statusAll=("${PIPESTATUS[@]}")
buildExit="${statusAll[0]}"
echo "=== BUILD END: $(date)" | tee -a "$logFileBuild"

if [[ $buildExit -ne 0 ]]; then
   echo "✖ Step $testNum FAIL: $ENGINE build failed (check $logFileBuild)"
   echo "buildExit=$buildExit"
   echo "statusAll=${statusAll[*]}"
   exit 1
fi
echo "✓ Step $testNum PASS: Build completed"
echo

# --- Step 8: Verify that the image exists in the local registry
# Podman normally records unqualified image names below localhost/, while Docker
# uses the generated image reference directly. This check stops on failure.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Verifying image $imageFull exists in $ENGINE local registry"
if [[ $ENGINE == "podman" ]]; then
   imageLocal="localhost/${imageFull}"
else
   imageLocal="${imageFull}"
fi
imageExists=false
if $ENGINE images -q "${imageLocal}" | grep -q .; then
   imageExists=true
fi
if [[ "$imageExists" == true ]]; then
   imageReference=$($ENGINE images "${imageLocal}" --format '{{.Repository}}:{{.Tag}}' | grep "${imageLocal}")
   imageSize=$($ENGINE images --format "{{.Size}}" "${imageLocal}" | head -n1)
   echo "✓ Step $testNum PASS: Image found!"
   echo "  Local Reference: $imageReference"
   echo "  Size: $imageSize"
   {
      echo "Engine: $ENGINE"
      echo "Image: $imageFull"
      echo "Local reference: $imageReference"
      echo "Size: $imageSize"
      echo "Build timestamp: $buildTimestamp"
      echo "Build kind: $buildKind"
      echo "Recipe directory: $recipeDir"
      echo "Build command file: $buildCommandFile"
      echo "Build log: $buildLog"
      echo "Complete run log: $runLog"
   } > "$imageDetailsFile"
else
   if [[ $ENGINE == "podman" ]]; then
      echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in $ENGINE \"localhost/\" local registry"
   else
      echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in $ENGINE local registry"
   fi
   ((totalFailed++))
   exit 1
fi
echo

# --- Step 9: Look for the engine-specific build success line
# This supplementary log check reports a problem but allows later checks to run.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking build success line"

if [[ "$ENGINE" == "docker" ]]; then
   successPattern="naming to.*${imageFull}.*done"
else
   successPattern="Successfully tagged.*${imageFull}"
fi
if tail -10 "$logFileBuild" | grep -qE "$successPattern"; then
   echo "✓ Step $testNum PASS: Success line found in $logFileBuild"
   tail -10 "$logFileBuild" | grep -E "$successPattern"
else
   failedTests+=("$testNum: Build success line not found in $logFileBuild")
   ((++totalFailed))
   echo "Last 10 lines:"
   tail -10 "$logFileBuild"
fi
echo

# --- Step 10: Scan the container-engine build log for additional error messages
# This is a supplementary diagnostic check. The exit status returned by the
# container-engine build command remains the authoritative indication of build
# success or failure.
#
# Podman STEP lines are excluded because they reproduce complete Dockerfile
# instructions that may contain the word "Error" in comments while not being a real error.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Scanning $logFileBuild for additional error messages"
echo "Checking the file: $logFileBuild"

if [[ -f "$logFileBuild" ]]; then
   errorOutput=$(
      grep -iE '\bError\b' "$logFileBuild" |
         grep -vE '^\[[0-9]+/[0-9]+\][[:space:]]+STEP[[:space:]]+[0-9]+/[0-9]+:' |
         grep -viE 'Error[./-]|ignor' ||
         true
   )

   if [[ -z "$errorOutput" ]]; then
      echo "✓ Step $testNum PASS: No additional error messages found in $logFileBuild"
   else
      errorCount=$(printf '%s\n' "$errorOutput" | wc -l)

      echo "✖ Step $testNum FAIL: $errorCount additional error message(s) found in $logFileBuild"
      echo "First 5 errors:"
      printf '%s\n' "$errorOutput" | head -n 5

      failedTests+=("$testNum: $logFileBuild has $errorCount additional error message(s)")
      ((++totalFailed))
   fi
else
   echo "✖ Step $testNum FAIL: Build log does not exist: $logFileBuild"
   failedTests+=("$testNum: Build log does not exist: $logFileBuild")
   ((++totalFailed))
fi
echo

# --- Step 11: Check the configured ThirdParty compilation summary
# The internal path comes from THIRDPARTY_BUILD_LOG. Set it to NO_CHECK in the
# version configuration when this image is not expected to contain that log.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$THIRDPARTY_BUILD_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: THIRDPARTY_BUILD_LOG=NO_CHECK"
else
   logFile="$THIRDPARTY_BUILD_LOG"
   echo "Step $testNum - Checking that ThirdParty compilation finalised without 'Error'"
   echo "Checking the file $logFile"
   if "$ENGINE" run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
      errorOutput=$("$ENGINE" run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viE 'Error[./-]|ignor' || true)
      if [[ -z "$errorOutput" ]]; then
         echo "✓ Step $testNum PASS: Clean $logFile"
      else
         errorCount=$(printf '%s\n' "$errorOutput" | wc -l)
         echo "✖ Step $testNum FAIL: $errorCount 'Error'(s) found in $logFile"
         echo "First 5 errors:"
         printf '%s\n' "$errorOutput" | head -n 5
         failedTests+=("$testNum: ThirdParty log has $errorCount errors")
         ((++totalFailed))
      fi
   else
      echo "⚠ Step $testNum FAIL: $logFile cannot be read from image $imageFull"
      echo "This may happen when a partial stage does not contain the log or"
      echo "does not initialize the environment variable used in its path."
      failedTests+=("$testNum: ThirdParty log file not accessible")
      ((++totalFailed))
   fi
fi
echo

# --- Step 12: Check the configured ParaView compilation summary
# The internal path comes from PARAVIEW_BUILD_LOG. Set it to NO_CHECK to skip.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$PARAVIEW_BUILD_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: PARAVIEW_BUILD_LOG=NO_CHECK"
else
   logFile="$PARAVIEW_BUILD_LOG"
   echo "Step $testNum - Checking that ParaView compilation finalised without 'Error'"
   echo "Checking the file $logFile"
   if "$ENGINE" run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
      errorOutput=$("$ENGINE" run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viE 'Error[./-]|ignor' || true)
      if [[ -z "$errorOutput" ]]; then
         echo "✓ Step $testNum PASS: Clean $logFile"
      else
         errorCount=$(printf '%s\n' "$errorOutput" | wc -l)
         echo "✖ Step $testNum FAIL: $errorCount 'Error'(s) found in $logFile"
         echo "First 5 errors:"
         printf '%s\n' "$errorOutput" | head -n 5
         failedTests+=("$testNum: ParaView log has $errorCount errors")
         ((++totalFailed))
      fi
   else
      echo "⚠ Step $testNum FAIL: $logFile cannot be read from image $imageFull"
      echo "This may happen when a partial stage does not contain the log or"
      echo "does not initialize the environment variable used in its path."
      failedTests+=("$testNum: ParaView log file not accessible")
      ((++totalFailed))
   fi
fi
echo

# --- Step 13: Check the configured OpenFOAM compilation summary
# The internal path comes from OPENFOAM_BUILD_LOG. Set it to NO_CHECK to skip.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$OPENFOAM_BUILD_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: OPENFOAM_BUILD_LOG=NO_CHECK"
else
   logFile="$OPENFOAM_BUILD_LOG"
   echo "Step $testNum - Checking that OpenFOAM compilation finalised without 'Error'"
   echo "Checking the file $logFile"
   if "$ENGINE" run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
      errorOutput=$("$ENGINE" run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viE 'Error[./-]|ignor' || true)
      if [[ -z "$errorOutput" ]]; then
         echo "✓ Step $testNum PASS: Clean $logFile"
      else
         errorCount=$(printf '%s\n' "$errorOutput" | wc -l)
         echo "✖ Step $testNum FAIL: $errorCount 'Error'(s) found in $logFile"
         echo "First 5 errors:"
         printf '%s\n' "$errorOutput" | head -n 5
         failedTests+=("$testNum: OpenFOAM log has $errorCount errors")
         ((++totalFailed))
      fi
   else
      echo "⚠ Step $testNum FAIL: $logFile cannot be read from image $imageFull"
      echo "This may happen when a partial stage does not contain the log or"
      echo "does not initialize the environment variable used in its path."
      failedTests+=("$testNum: OpenFOAM log file not accessible")
      ((++totalFailed))
   fi
fi
echo

# --- Step 14: Check the configured OpenFOAM basic-functionality log
# The internal path comes from OPENFOAM_TOOL_LOG. Set it to NO_CHECK to skip.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$OPENFOAM_TOOL_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: OPENFOAM_TOOL_LOG=NO_CHECK"
else
   logFile="$OPENFOAM_TOOL_LOG"
   echo "Step $testNum - Checking that OpenFOAM tool basic output is correct"
   echo "Checking the file $logFile"
   if "$ENGINE" run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
      if "$ENGINE" run --rm "$imageFull" bash -c "
         grep -qE '^Usage:' \"$logFile\" &&
         grep -qE '^Options:' \"$logFile\" &&
         grep -qF 'Using: OpenFOAM-${OF_VERSION}' \"$logFile\"
      "; then
         echo "✓ Step $testNum PASS: All required output lines found in $logFile"
         "$ENGINE" run --rm "$imageFull" bash -c "
            grep -E '^Usage:' \"$logFile\";
            grep -E '^Options:' \"$logFile\";
            grep -F 'Using: OpenFOAM-${OF_VERSION}' \"$logFile\"
         "
      else
         echo "✖ Step $testNum FAIL: Missing required output lines in $logFile"
         echo "Missing patterns:"
         "$ENGINE" run --rm "$imageFull" bash -c "
            grep -qE '^Usage:' \"$logFile\" || echo '  - ^Usage:';
            grep -qE '^Options:' \"$logFile\" || echo '  - ^Options:';
            grep -qF 'Using: OpenFOAM-${OF_VERSION}' \"$logFile\" || echo '  - Using: OpenFOAM-${OF_VERSION}'
         "
         failedTests+=("$testNum: OpenFOAM tool basic output incomplete")
         ((++totalFailed))
      fi
   else
      echo "⚠ Step $testNum FAIL: $logFile cannot be read from image $imageFull"
      echo "This may happen when a partial stage does not contain the log or"
      echo "does not initialize the environment variable used in its path."
      failedTests+=("$testNum: OpenFOAM tool basic test log file not accessible")
      ((++totalFailed))
   fi
fi
echo

# --- Final summary
# Return success only when every required build and validation step passed.
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Total steps run: $testNum"
echo "Invocation artifacts: $runArtifactsDir"
echo "Build log: $buildLog"
echo "Complete run log: $runLog"
if [[ $totalFailed -eq 0 ]]; then
   echo "✓ ALL STEPS PASSED! Image '$imageFull' was built successfully."
   exit 0
else
   echo "✖ $totalFailed STEPS(S) FAILED:"
   for test in "${failedTests[@]}"; do
      echo "  - $test"
   done
   exit 1
fi
