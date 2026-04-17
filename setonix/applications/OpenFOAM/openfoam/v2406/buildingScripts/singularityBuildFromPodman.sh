#!/bin/bash
# --- Initial settings
thisScript=$(basename "$0")
testNum=0
failedTests=()
totalFailed=0
imageFull=""
recipeDir=".."
recipeFile="${recipeDir}/Dockerfile"

# --- Parse & validate command line arguments
if [[ $# -gt 1 ]]; then
   echo "ERROR: At most 1 argument allowed (imageFull)" >&2
   echo "Usage: $0 [<imageFull>]" >&2
   exit 1
fi
if [[ $# -eq 1 ]]; then
   imageFull="$1"
   echo "Will build singularity image from: $imageFull"
else
   echo "No imageFull provided, using default"
fi

# --- Step 1: Setting podman environment (STOP on fail)
#             Adapt process to your own system needs 
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Sourcing the podman settings"
# Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
if ! source /container/setup_podman.sh 2>/dev/null; then
   echo "✖ Step $testNum FAIL: Failed to: source /container/setup_podman.sh"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum PASS"
echo

# --- Step 2: Checking if podman is correctly set (STOP on fail)
#             Adapt checks to your own system needs
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking if podman is accessible."
podmanVersion=$(podman --version)
if [[ -z "$podmanVersion" ]]; then
   echo "✖ Step $testNum FAIL: Failed to execute: podman --version"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum podmanVersion=$podmanVersion"
# Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
if [[ -z "$XDG_DATA_HOME" ]]; then
   echo "✖ Step $testNum FAIL: Failed to check existance of: XDG_DATA_HOME"
   echo "  Probably forgot to: source /container/setup_podman.sh"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum XDG_DATA_HOME=$XDG_DATA_HOME"
echo "✓ Step $testNum PASS"
echo

# --- Step 3: Setting Singularity environment (STOP on fail)
#             Adapt process to your own system needs 
((++testNum))
echo "$thisScript: Step $testNum - Loading Singularity Environment"
# Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
if ! module load singularity/4.1.0-mpi 2>/dev/null; then
   echo "✖ Step $testNum FAIL: Failed to: module load singularity/4.1.0-mpi"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum PASS"
echo

# --- Step 4: Checking if singularity is correctly set (STOP on fail)
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

# --- Step 5: Settings for defining image names (STOP on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Setting the variables for defining names"
if [[ -z $imageFull ]]; then
   OF_FORK=$(grep '^ARG OF_FORK=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   OF_VERSION=$(grep '^ARG OF_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   OS_VERSION=$(grep '^ARG BASE_IMAGE_OS_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)

   echo "OF_FORK: '$OF_FORK'"
   echo "OF_VERSION: '$OF_VERSION'" 
   echo "OS_VERSION: '$OS_VERSION'"

   if [[ -z "$OF_FORK" || -z "$OF_VERSION" || -z "$OS_VERSION" ]]; then
      echo "✖ Step $testNum FAIL: Failed to extract required variables from Dockerfile"
      ((totalFailed++))
      exit 1
   fi
   echo "✓ Step $testNum PASS"
else
   echo "Step $testNum Skipped, as docker image name was provided as argument: $imageFull"
fi
echo

# --- Step 6: Check if the image exists in the local Podman repository (STOP on fail)
((++testNum))
if [[ -z $imageFull ]]; then
   imageName="${OF_FORK}"
   imageTag="${OF_VERSION}-ubuntu${OS_VERSION}"
   imageFull="${imageName}:${imageTag}"
else
   imageName=$(echo $imageFull | cut -d: -f1)
   imageTag=$(echo $imageFull | cut -d: -f2)
fi
echo "$thisScript: -----------------------------------------"
echo "$thisScript: Step $testNum - Verifying image $imageFull exists in podman registry"
if podman image exists "${imageFull}"; then
   imageRepo=$(podman image inspect "${imageFull}" --format '{{index .RepoTags 0}}')
   imageSize=$(podman images --format "{{.Size}}" "${imageFull}" | numfmt --to=iec)
   echo "✓ Step $testNum PASS: Image found!"
   echo "  Repository: $imageRepo"
   echo "  Size: $imageSize"
else
   echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in podman registry"
   podman images | grep "${imageFull}" || echo "  No matching images found"
   ((totalFailed++))
   exit 1
fi
echo

# --- Step 7: Save the image in oci-archive format (STOP on fail)
((++testNum))
imageTar="oci_${imageName}_${imageTag}.tar"
logFile="savePodman.log"
if [[ -f "$imageTar" ]]; then mv $imageTar $imageTar.bak; fi
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Saving the podman image ${imageFull} in oci-archive format"
echo "Log of the process in $logFile"
podman save --format=oci-archive "${imageFull}" -o $imageTar |& tee $logFile
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
echo

# --- Step 8: Build the image in singularity (STOP on fail)
((++testNum))
#Path defined for use on restricted Container-Building nodes at Pawsey. Adapt settings to your own system needs.
directorySif="$MYSCRATCH/singularity/images"
mkdir -p $directorySif
imageSif="${imageName}_${imageTag}.sif"
logFile="buildSingularity.log"
if [[ -f "$imageSif" ]]; then mv "${imageSif}" "${imageSif}.bak"; fi
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Building the singularity image ${imageSif} from podman image ${imageTar}"
echo "Log of the process in $logFile"
singularity build $imageSif oci-archive://${imageTar} |& tee $logFile
statusAll=(${PIPESTATUS[@]})
buildExit="${statusAll[0]}"
#echo "buildExit=$buildExit"
#echo "statusAll=${statusAll[*]}"
if [[ -f "$imageSif" && $buildExit -eq 0 ]]; then
   echo "✓ Step $testNum PASS: $imageSif was created successfully"
   if [[ -f "${directorySif}/${imageSif}" ]]; then mv "${directorySif}/${imageSif}" "${directorySif}/${imageSif}.bak"; fi
   mv $imageSif $directorySif
   echo "The singularity image is:"
   ls -lath "$directorySif/$imageSif"
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
   echo "✓ ALL STEPS PASSED! Image '$imageFull' was built succesfully."
   echo " Apply all "setonix" functional tests to it for approval"
   exit 0
else
   echo "✖ $totalFailed STEP(S) FAILED:"
   for test in "${failedTests[@]}"; do
      echo "  - $test"
   done
   exit 1
fi
