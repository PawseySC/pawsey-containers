#!/bin/bash
# Unified script that builds a Singularity image from a Docker or Podman source image
# Usage: singularityBuild.sh --engine docker|podman [<imageFull>]
#        singularityBuild.sh --fromRegistryImage <docker://registry/imageName:imageTag>

# --- Initial settings
thisScript=$(basename "$0")
testNum=0
failedTests=()
totalFailed=0
imageFull=""
recipeDir=".."
recipeFile="${recipeDir}/Dockerfile"
tmpDir="./tmp"
mkdir -p $tmpDir
echo "This directory contains temporary and log files only. It can be removed anytime." > "${tmpDir}/README.txt"

# --- Parse & validate command line arguments
ENGINE=""
REGO_IMAGE=""
positionalArgs=()
while [[ $# -gt 0 ]]; do
   case $1 in
      --engine)
         ENGINE="$2"
         if [[ -z "$ENGINE" ]]; then
            echo "ERROR: --engine requires docker|podman" >&2
            echo "Usage: $0 --engine docker|podman [<imageFull>]" >&2
            echo "       $0 --fromRegistryImage <docker://registry/imageName:imageTag>" >&2
            exit 1
         fi
         shift 2
         ;;
      --fromRegistryImage)
         REGO_IMAGE="$2"
         if [[ -z "$REGO_IMAGE" ]]; then
            echo "ERROR: --fromRegistryImage requires <docker://registry/imageName:imageTag>" >&2
            echo "Usage: $0 --engine docker|podman [<imageFull>]" >&2
            echo "       $0 --fromRegistryImage <docker://registry/imageName:imageTag>" >&2
            exit 1
         fi
         shift 2
         ;;
      -h|--help)
         echo "Usage: $0 --engine docker|podman [<imageFull>]"
         echo "       $0 --fromRegistryImage <docker://registry/imageName:imageTag>"
         echo ""
         echo "  --engine docker|podman   Container engine to use (required for local builds)"
         echo "  <imageFull>              Optional image name:tag to convert from local engine"
         echo "  --fromRegistryImage    Build singularity image directly from a remote registry."
         echo "                           The docker:// prefix is optional and will be added if missing."
         echo "                           When used, --engine is not needed and will be ignored."
         exit 0
         ;;
      -*)
         echo "ERROR: Unknown option '$1'" >&2
         echo "Usage: $0 --engine docker|podman [<imageFull>]" >&2
         echo "       $0 --fromRegistryImage <docker://registry/imageName:imageTag>" >&2
         exit 1
         ;;
      *)
         positionalArgs+=("$1")
         shift
         ;;
   esac
done

# Determine mode: registry or local
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
      echo "       must be provided immediately after. And NO additional positional arguments are allowed afterwards." >&2
      exit 1
   fi
else
   # Local mode: --engine is required
   if [[ -z "$ENGINE" ]]; then
      echo "ERROR: --engine docker|podman is required" >&2
      echo "Usage: $0 --engine docker|podman [<imageFull>]" >&2
      exit 1
   fi
   if [[ "$ENGINE" != "docker" && "$ENGINE" != "podman" ]]; then
      echo "ERROR: --engine must be 'docker' or 'podman', got '$ENGINE'" >&2
      exit 1
   fi

   # Positional argument validation
   if [[ ${#positionalArgs[@]} -gt 1 ]]; then
      echo "ERROR: At most 1 positional argument allowed (imageFull)" >&2
      echo "Usage: $0 --engine docker|podman [<imageFull>]" >&2
      exit 1
   fi
   if [[ ${#positionalArgs[@]} -eq 1 ]]; then
      imageFull="${positionalArgs[0]}"
      echo "Will build singularity image from: $imageFull"
   else
      echo "No imageFull provided, using default"
   fi
fi

# --- Step 1: Resolve image naming (STOP on fail)
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
   imageName=$(echo $imageFull | cut -d: -f1)
   imageTag=$(echo $imageFull | cut -d: -f2)
   echo "  Source: positional argument"
   echo "  imageFull: $imageFull"
else
   OF_FORK=$(grep '^ARG OF_FORK=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   OF_VERSION=$(grep '^ARG OF_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   OS_VERSION=$(grep '^ARG BASE_IMAGE_OS_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   echo "  Source: Dockerfile defaults"
   echo "  OF_FORK: '$OF_FORK'"
   echo "  OF_VERSION: '$OF_VERSION'"
   echo "  OS_VERSION: '$OS_VERSION'"
   if [[ -z "$OF_FORK" || -z "$OF_VERSION" || -z "$OS_VERSION" ]]; then
      echo "✖ Step $testNum FAIL: Failed to extract required variables from Dockerfile"
      ((totalFailed++))
      exit 1
   fi
   imageName="${OF_FORK}"
   imageTag="${OF_VERSION}-ubuntu${OS_VERSION}"
   imageFull="${imageName}:${imageTag}"
fi
echo "  imageName: $imageName"
echo "  imageTag:  $imageTag"
echo "✓ Step $testNum PASS"
echo

# --- Step 2: Setting container engine environment (STOP on fail)
#             Adapt process to your own system needs 
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

# --- Step 3: Checking if container engine is correctly set (STOP on fail)
#             Adapt checks to your own system needs
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

# --- Step 4: Setting Singularity environment (STOP on fail)
#             Adapt process to your own system needs 
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

# --- Step 5: Checking if singularity is correctly set (STOP on fail)
#             Adapt checks to your own system needs
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

# --- Step 6: Check if the image exists in the local registry (STOP on fail)
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

# --- Step 7: Save the image into oci-archive format (STOP on fail)
((++testNum))
imageTar=""
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   echo "Step $testNum skipped. Not needed for --fromRegistryImage (singularity pulls directly)"
elif [[ "$ENGINE" == "podman" ]]; then
   imageTar="${tmpDir}/oci_${imageName}_${imageTag}.tar"
   logFile="${tmpDir}/savePodman.log"
   if [[ -f "$imageTar" ]]; then mv $imageTar $imageTar.bak; fi
   echo "Step $testNum - Saving the podman image ${imageFull} in oci-archive format"
   echo "Log of the process in $logFile"
   podman save --format=oci-archive "localhost/${imageFull}" -o $imageTar |& tee $logFile
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

# --- Step 8: Build the image in singularity (STOP on fail)
((++testNum))
#Path defined for use on restricted Container-Building nodes at Pawsey. Adapt settings to your own system needs.
if [[ -n "$MYSCRATCH" ]]; then
   directorySif="$MYSCRATCH/singularity/images"
else
   directorySif="$HOME/singularity/images"
fi
mkdir -p $directorySif
imageSif="${directorySif}/${imageName}_${imageTag}.sif"
logFile="${tmpDir}/buildSingularity.log"
if [[ -f "$imageSif" ]]; then mv "${imageSif}" "${imageSif}.bak"; fi
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   singularitySource="$REGO_IMAGE"
elif [[ "$ENGINE" == "docker" ]]; then
   singularitySource="docker-daemon://${imageFull}"
else
   singularitySource="oci-archive://${imageTar}"
fi
echo "Step $testNum - Building the singularity image ${imageSif} from ${singularitySource}"
echo "Log of the process in $logFile"
singularity build $imageSif $singularitySource |& tee $logFile
statusAll=(${PIPESTATUS[@]})
buildExit="${statusAll[0]}"
#echo "buildExit=$buildExit"
#echo "statusAll=${statusAll[*]}"
if [[ -f "$imageSif" && $buildExit -eq 0 ]]; then
   echo "✓ Step $testNum PASS: $imageSif was created successfully"
   echo "The singularity image is:"
   ls -lath "$imageSif"
   echo "Note: Once you test it, save it into the correct permanent directory for production"
else
   echo "✖ Step $testNum FAIL: $imageSif was NOT created, or an error was detected during the build command"
   echo "buildExit=$buildExit"
   echo "statusAll=${statusAll[*]}"
   ((totalFailed++))
   exit 1
fi
echo

# --- Final Summary
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Total steps run: $testNum"
if [[ $totalFailed -eq 0 ]]; then
   echo "✓ ALL STEPS PASSED! Image '$imageSif' was built succesfully."
   exit 0
else
   echo "✖ $totalFailed STEP(S) FAILED:"
   for test in "${failedTests[@]}"; do
      echo "  - $test"
   done
   exit 1
fi
