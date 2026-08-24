#!/bin/bash
# General script for building OpenFOAM Singularity images.
#
# This script creates a Singularity SIF image from one of three source types:
#   1. An image held in the local Docker image store.
#   2. An image held in the local Podman image store.
#   3. An image available from a remote Docker-compatible registry.
#
# In local mode, --engine selects Docker or Podman. A local image name:tag may
# be supplied as the final positional argument. If it is omitted, --recipe-dir
# is required and the script derives the local image name from ARG instructions
# in that version directory's Dockerfile.
#
# In registry mode, --fromRegistryImage supplies the complete remote image
# reference. The docker:// prefix is optional and is added automatically when
# missing. Registry mode does not require Docker or Podman.
#
# Docker images are read directly through docker-daemon://. Podman images are
# first saved as an OCI archive because Singularity reads that archive through
# oci-archive://. Remote images are read directly from their docker:// source.
# Temporary and persistent conversion artifacts are stored under the required
# recipe directory. The docker recipe filename is constructed from
# OPENFOAM_FORK and OPENFOAM_VERSION in the version configuration.
#
# By default, each resulting SIF and its logs are stored together under a
# timestamped artifacts/singularity/ directory. The latest symbolic link is
# updated only after a successful default-location SIF build. --output-dir
# overrides only the SIF destination; the timestamped directory still retains
# logs and metadata without changing the development-candidate latest link.
#
# Examples:
#   openfoamSingularityBuild.sh --recipe-dir v2406 --engine podman
#   openfoamSingularityBuild.sh --recipe-dir v2406 --engine docker \
#      openfoam:v2406-mpich4.2.2-ubuntu24.04
#   openfoamSingularityBuild.sh --recipe-dir v2406 --output-dir /path/to/images \
#      --fromRegistryImage quay.io/example/openfoam:v2406
#   openfoamSingularityBuild.sh --help
#
# Exit status:
#   0  The Singularity image was built successfully.
#   1  Invalid input, setup failure, source-image failure, or build failure.
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
imageFull=""
recipeDirInput=""
recipeDir=""
recipeFile=""
tmpDir=""
artifactsDir=""
singularityArtifactsDir=""
runArtifactsDir=""
runLog=""
buildLog=""
saveLog=""
buildCommandFile=""
imageDetailsFile=""
outputDirInput=""
configFile=""

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  $thisScript --recipe-dir <directory> [--output-dir <directory>] --engine docker|podman [<imageFull>]
  $thisScript --recipe-dir <directory> [--output-dir <directory>] --fromRegistryImage <registry/imageName:imageTag>
  $thisScript --help

Options:
  --recipe-dir, -r <directory>  OpenFOAM version directory containing the configuration and docker recipe
  --output-dir, -o <directory>  Explicit SIF destination; does not validate or promote for production use
  --engine, -b <engine>         Local source-image engine: docker or podman
  --fromRegistryImage <image>   Remote registry image; docker:// is optional
  --help, -h                    Show this help message and exit
  <imageFull>                   Optional local image name:tag, including target-built image tags
USAGE
}

# --- Parse and validate command-line arguments
ENGINE=""
REGO_IMAGE=""
positionalArgs=()
while [[ $# -gt 0 ]]; do
   case $1 in
      --recipe-dir|-r)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --recipe-dir requires <directory>" >&2
            usage >&2
            exit 1
         fi
         recipeDirInput="$2"
         shift 2
         ;;
      --output-dir|-o)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --output-dir requires <directory>" >&2
            usage >&2
            exit 1
         fi
         outputDirInput="$2"
         shift 2
         ;;
      --engine|-b)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --engine requires docker|podman" >&2
            usage >&2
            exit 1
         fi
         ENGINE="$2"
         shift 2
         ;;
      --fromRegistryImage)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --fromRegistryImage requires <registry/imageName:imageTag>" >&2
            usage >&2
            exit 1
         fi
         REGO_IMAGE="$2"
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
         positionalArgs+=("$1")
         shift
         ;;
   esac
done

# --- Require and resolve the recipe directory
if [[ -z "$recipeDirInput" ]]; then
   echo "ERROR: --recipe-dir <directory> is required" >&2
   usage >&2
   exit 1
fi
if [[ ! -d "$recipeDirInput" ]]; then
   echo "ERROR: Recipe directory does not exist: $recipeDirInput" >&2
   exit 1
fi
recipeDir=$(cd -- "$recipeDirInput" && pwd)
configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
if [[ ! -r "$configFile" ]]; then
   echo "ERROR: Build-validation configuration is not readable: $configFile" >&2
   exit 1
fi
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
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

tmpDir="${recipeDir}/tmp"
artifactsDir="${recipeDir}/artifacts"
singularityArtifactsDir="${artifactsDir}/singularity"
mkdir -p "$tmpDir" "$singularityArtifactsDir"
latestLink="${singularityArtifactsDir}/latest"
if [[ -e "$latestLink" && ! -L "$latestLink" ]]; then
   echo "ERROR: Refusing to remove non-symbolic-link path: $latestLink" >&2
   exit 1
fi
if ! rm -f "$latestLink"; then
   echo "ERROR: Failed to remove latest link: $latestLink" >&2
   exit 1
fi
echo "This directory contains disposable temporary files only. It can be removed anytime." > "${tmpDir}/README.txt"
echo "This directory contains timestamped build artifacts. The latest link identifies the most recent tracked build invocation. If the link is absent, the most recent command failed before invocation tracking was established." > "${singularityArtifactsDir}/README.txt"

# --- Select and validate the source-image mode
# Registry mode uses --fromRegistryImage. Otherwise, local mode requires Docker
# or Podman and accepts at most one positional local image reference.
if [[ -n "$REGO_IMAGE" ]]; then
   MODE="registry"
else
   MODE="local"
fi

if [[ "$MODE" == "registry" ]]; then
   # Warn and ignore --engine if provided
   if [[ -n "$ENGINE" ]]; then
      echo "WARNING: --engine '$ENGINE' ignored when using --fromRegistryImage"
      ENGINE=""
   fi

   # Error if positional arguments were provided
if [[ ${#positionalArgs[@]} -gt 0 ]]; then
      echo "ERROR: --fromRegistryImage is in use. The full 'registry/imageName:imageTag'" >&2
      echo "       must be provided immediately after. No additional positional arguments are allowed." >&2
      usage >&2
      exit 1
   fi
else
   # Local mode: --engine is required
   if [[ -z "$ENGINE" ]]; then
      echo "ERROR: --engine docker|podman is required" >&2
      usage >&2
      exit 1
   fi
   if [[ "$ENGINE" != "docker" && "$ENGINE" != "podman" ]]; then
      echo "ERROR: --engine must be 'docker' or 'podman', got '$ENGINE'" >&2
      usage >&2
      exit 1
   fi

   # Positional argument validation
   if [[ ${#positionalArgs[@]} -gt 1 ]]; then
      echo "ERROR: At most 1 positional argument allowed (imageFull)" >&2
      usage >&2
      exit 1
   fi
   if [[ ${#positionalArgs[@]} -eq 1 ]]; then
      imageFull="${positionalArgs[0]}"
      echo "Will build singularity image from: $imageFull"
   else
      echo "No imageFull provided, using docker recipe defaults from: $recipeFile"
   fi
fi

# --- Create the persistent artifact directory for this invocation
# The source mode identifies the invocation without requiring inspection of its
# contents. The latest link is deliberately updated only after a successful SIF
# build, so automated tests never default to a failed candidate.
if [[ "$MODE" == "registry" ]]; then
   sourceKind="registry"
else
   sourceKind="$ENGINE"
fi
buildTimestamp=$(date '+%Y%m%dT%H%M%S%z')
runArtifactsName="${buildTimestamp}_${sourceKind}"
runArtifactsDir="${singularityArtifactsDir}/${runArtifactsName}"
if ! mkdir "$runArtifactsDir"; then
   echo "ERROR: Cannot create invocation artifact directory: $runArtifactsDir" >&2
   exit 1
fi

ln -sfn "$runArtifactsName" "${singularityArtifactsDir}/latest"
runLog="${runArtifactsDir}/run.log"
buildLog="${runArtifactsDir}/build.log"
saveLog="${runArtifactsDir}/save.log"
buildCommandFile="${runArtifactsDir}/build-command.txt"
imageDetailsFile="${runArtifactsDir}/image-details.txt"

# Preserve the complete script output while continuing to display it.
exec > >(tee "$runLog") 2>&1

echo "Invocation artifacts: $runArtifactsDir"
echo "Complete run log: $runLog"
echo

# --- Step 1: Resolve the source and output image names
# Registry and explicit local references provide their own name and tag. When a
# local reference is omitted, derive both from the recipe Dockerfile defaults.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Resolving image naming"
if [[ "$MODE" == "registry" ]]; then
   # Normalize: ensure docker:// prefix
   if [[ "$REGO_IMAGE" != docker://* ]]; then
      REGO_IMAGE="docker://${REGO_IMAGE}"
   fi
   # Derive imageName and imageTag from the registry path
   # Strip docker:// prefix, then extract name and tag
   regoPath="${REGO_IMAGE#docker://}"
   if [[ "$regoPath" == *:* ]]; then
      imageTag="${regoPath##*:}"
      imageNamePath="${regoPath%:*}"
   else
      imageTag="latest"
      imageNamePath="$regoPath"
   fi
   # Use the last component of the path as imageName (e.g. "quay.io/org/myimage" -> "myimage")
   imageName="${imageNamePath##*/}"
   echo "  Source: --fromRegistryImage"
   echo "  REGO_IMAGE: $REGO_IMAGE"
elif [[ -n "$imageFull" ]]; then
   if [[ "$imageFull" != *:* ]]; then
      echo "ERROR: Local image must include a tag: $imageFull" >&2
      usage >&2
      exit 1
   fi
   imageTag="${imageFull##*:}"
   imageNamePath="${imageFull%:*}"
   imageName="${imageNamePath##*/}"
   echo "  Source: positional argument"
   echo "  imageFull: $imageFull"
else
   OF_FORK=$(grep '^ARG OF_FORK=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   OF_VERSION=$(grep '^ARG OF_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   OS_VERSION=$(grep '^ARG BASE_IMAGE_OS_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   MPICH_VERSION=$(grep '^ARG BASE_IMAGE_MPICH_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   echo "  Source: Dockerfile defaults"
   echo "  OF_FORK: '$OF_FORK'"
   echo "  OF_VERSION: '$OF_VERSION'"
   echo "  OS_VERSION: '$OS_VERSION'"
   echo "  MPICH_VERSION: '$MPICH_VERSION'"
   if [[ -z "$OF_FORK" || -z "$OF_VERSION" || -z "$OS_VERSION" || -z "$MPICH_VERSION" ]]; then
      echo "✖ Step $testNum FAIL: Failed to extract required variables from Dockerfile"
      ((totalFailed++))
      exit 1
   fi
   imageName="${OF_FORK}"
   imageTag="${OF_VERSION}-mpich${MPICH_VERSION}-ubuntu${OS_VERSION}"
   imageFull="${imageName}:${imageTag}"
fi
echo "  imageName: $imageName"
echo "  imageTag:  $imageTag"
expectedSourcePrefix="${OPENFOAM_FORK}:${OPENFOAM_VERSION}"
resolvedSourceName="${imageName}:${imageTag}"
if [[ "$resolvedSourceName" != "${expectedSourcePrefix}"* ]]; then
   echo "✖ Step $testNum FAIL: Source image name does not match the configured OpenFOAM identity"
   echo "  Source image name: $resolvedSourceName"
   echo "  Required prefix:  $expectedSourcePrefix"
   ((totalFailed++)); exit 1
fi
echo "✓ Step $testNum PASS: Source image name starts with '$expectedSourcePrefix'"
echo

# --- Step 2: Set up the local source-image engine
# This step is skipped for registry mode. Docker Desktop is started when needed,
# while Pawsey Podman builds source the site container setup script.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   echo "Step $testNum skipped. Not needed for --fromRegistryImage (no local engine required)"
else
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
fi
echo

# --- Step 3: Confirm that the local container engine is accessible
# Registry mode does not need a local engine. Podman also requires XDG_DATA_HOME
# to have been initialized by the Pawsey setup script.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   echo "Step $testNum skipped. Not needed for --fromRegistryImage (no local engine required)"
else
   echo "Step $testNum - Checking if $ENGINE is accessible."
   engineVersion=$($ENGINE --version)
   if [[ -z "$engineVersion" ]]; then
      echo "✖ Step $testNum FAIL: Failed to execute: $ENGINE --version"
      ((totalFailed++))
      exit 1
   fi
   echo "✓ Step $testNum ${ENGINE}Version=$engineVersion"
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
fi
echo

# --- Step 4: Set up the Singularity environment
# Docker-hosted conversion uses the local setup_singularity.sh environment.
# Podman and remote-registry conversion use Pawsey's Singularity module.
((++testNum))
echo "$thisScript: Step $testNum - Loading Singularity Environment"
if [[ "$ENGINE" == "docker" ]]; then
   # Adapt the check to your own system needs.
   if ! source "${HOME}/setup_singularity.sh" 2>/dev/null; then
      echo "✖ Step $testNum FAIL: Failed to: source ${HOME}/setup_singularity.sh"
      ((totalFailed++))
      exit 1
   fi
else
   # Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
   # This branch is also used for --fromRegistryImage mode (no local engine).
   if ! module load singularity/4.1.0-mpi 2>/dev/null; then
      echo "✖ Step $testNum FAIL: Failed to: module load singularity/4.1.0-mpi"
      ((totalFailed++))
      exit 1
   fi
fi
echo "✓ Step $testNum PASS"
echo

# --- Step 5: Confirm that Singularity is accessible
# A nonempty version response confirms that the Singularity command is ready.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking if singularity is accessible."
singularityVersion=$(singularity --version)
if [[ -z "$singularityVersion" ]]; then
   echo "✖ Step $testNum FAIL: Failed to execute: singularity --version"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum singularityVersion=$singularityVersion"
echo "✓ Step $testNum PASS"
echo

# --- Step 6: Verify the source image in the local image store
# This check is skipped for remote registry sources. Podman normally stores an
# unqualified image below localhost/, while Docker uses the reference directly.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   echo "Step $testNum skipped. Not needed for --fromRegistryImage (image is in a remote registry)"
else
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
   else
      if [[ $ENGINE == "podman" ]]; then
         echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in $ENGINE \"localhost/\" local registry"
      else
         echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in $ENGINE local registry"
      fi
      ((totalFailed++))
      exit 1
   fi
fi
echo

# --- Step 7: Export a Podman source image as an OCI archive
# Singularity can read Docker directly, but the Podman path uses an OCI archive.
# Registry mode also skips this step because Singularity pulls the image itself.
((++testNum))
imageTar=""
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   echo "Step $testNum skipped. Not needed for --fromRegistryImage (singularity pulls directly)"
elif [[ "$ENGINE" == "podman" ]]; then
   imageTar="${tmpDir}/${imageName}--${imageTag}.${buildTimestamp}.$$.tar"
   logFile="$saveLog"
   echo "Step $testNum - Saving the podman image ${imageFull} in oci-archive format"
   echo "Log of the process in $logFile"
   "$ENGINE" save --format=oci-archive "localhost/${imageFull}" -o "$imageTar" |& tee "$logFile"
   statusAll=(${PIPESTATUS[@]})
   saveExit="${statusAll[0]}"
   #echo "saveExit=$saveExit"
   #echo "statusAll=${statusAll[*]}"
   if [[ -f "$imageTar" && $saveExit -eq 0 ]]; then
      echo "✓ Step $testNum PASS: $imageTar was created successfully"
   else
      echo "✖ Step $testNum FAIL: $imageTar was NOT created, or an error was detected during the save command"
      echo "saveExit=$saveExit"
      echo "statusAll=${statusAll[*]}"
      ((totalFailed++))
      exit 1
   fi
else
   echo "Step $testNum skipped. Not needed for docker (singularity reads from docker-daemon directly)"
fi
echo

# --- Step 8: Build the Singularity SIF image
# Select docker://, docker-daemon://, or oci-archive:// according to the source
# mode. The default SIF destination is the invocation artifact directory.
((++testNum))
if [[ -n "$outputDirInput" ]]; then
   mkdir -p "$outputDirInput"
   directorySif=$(cd -- "$outputDirInput" && pwd)
else
   directorySif="$runArtifactsDir"
fi
imageSif="${directorySif}/${imageName}--${imageTag}.sif"
imageSifName=$(basename "$imageSif")
expectedSifPrefix="${OPENFOAM_FORK}--${OPENFOAM_VERSION}"
if [[ "$imageSifName" != "${expectedSifPrefix}"*.sif ]]; then
   echo "✖ Step $testNum FAIL: Generated SIF filename does not match the configured OpenFOAM identity"
   echo "  Generated filename: $imageSifName"
   echo "  Required pattern:   ${expectedSifPrefix}*.sif"
   ((totalFailed++)); exit 1
fi
echo "✓ Step $testNum: Generated SIF filename matches '${expectedSifPrefix}*.sif'"
logFile="$buildLog"
if [[ -f "$imageSif" ]]; then mv "$imageSif" "${imageSif}.bak"; fi
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   singularitySource="$REGO_IMAGE"
elif [[ "$ENGINE" == "docker" ]]; then
   singularitySource="docker-daemon://${imageFull}"
else
   singularitySource="oci-archive://${imageTar}"
fi
buildCommand=(singularity build "$imageSif" "$singularitySource")
echo "Step $testNum - Building the singularity image ${imageSif} from ${singularitySource}"
echo "Log of the process in $logFile"
printf 'Recorded build command:'
printf ' %q' "${buildCommand[@]}"
printf '\n'
printf '%q ' "${buildCommand[@]}" > "$buildCommandFile"
printf '\n' >> "$buildCommandFile"
"${buildCommand[@]}" |& tee "$logFile"
statusAll=(${PIPESTATUS[@]})
buildExit="${statusAll[0]}"
#echo "buildExit=$buildExit"
#echo "statusAll=${statusAll[*]}"
if [[ -f "$imageSif" && $buildExit -eq 0 ]]; then
   echo "✓ Step $testNum PASS: $imageSif was created successfully"
   echo "The singularity image is:"
   ls -lath "$imageSif"
   imageChecksum=$(sha256sum "$imageSif" | awk '{print $1}')
   {
      echo "Mode: $MODE"
      echo "Source kind: $sourceKind"
      echo "Source image: $singularitySource"
      echo "SIF image: $imageSif"
      echo "SIF SHA256: $imageChecksum"
      echo "Build timestamp: $buildTimestamp"
      echo "Recipe directory: ${recipeDir:-none}"
      echo "Singularity version: $singularityVersion"
      echo "Build command file: $buildCommandFile"
      echo "Build log: $buildLog"
      echo "Complete run log: $runLog"
   } > "$imageDetailsFile"
   if [[ -n "$imageTar" ]]; then
      rm -f "$imageTar"
   fi
   echo "Latest invocation: ${singularityArtifactsDir}/latest"
   echo "Note: Once you test it, promote it into the correct permanent directory for production"
else
   echo "✖ Step $testNum FAIL: $imageSif was NOT created, or an error was detected during the build command"
   echo "buildExit=$buildExit"
   echo "statusAll=${statusAll[*]}"
   ((totalFailed++))
   exit 1
fi
echo

# --- Final summary
# Return success only after the requested SIF exists and singularity build exits
# successfully. All earlier setup and source-image failures return status 1.
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Total steps run: $testNum"
echo "Invocation artifacts: $runArtifactsDir"
echo "SIF image: $imageSif"
echo "Build log: $buildLog"
echo "Complete run log: $runLog"
if [[ $totalFailed -eq 0 ]]; then
   echo "✓ ALL STEPS PASSED! Image '$imageSif' was built successfully."
   exit 0
else
   echo "✖ $totalFailed STEP(S) FAILED:"
   for test in "${failedTests[@]}"; do
      echo "  - $test"
   done
   exit 1
fi
