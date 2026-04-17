#!/bin/bash
# --- Initial settings
thisScript=$(basename "$0")
testNum=0
OF_TOOL="icoFoam"

# --- Parse & validate command line arguments (exactly 1 required)
if [[ $# -ne 1 ]]; then
   echo "ERROR: Exactly 1 argument required (imageFull)" >&2
   echo "Usage: $0 <imageFull>" >&2
   exit 1
fi
imageFull="$1"
echo "Will run minimal tests with podman image $imageFull"

# --- Step 1: Setting podman environment (STOP on fail)
#             Adapt process to your own system needs 
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Sourcing the podman settings"
# Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
if ! source /container/setup_podman.sh 2>/dev/null; then
   echo "✖ Step $testNum FAIL: Failed to: source /container/setup_podman.sh"
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
   exit 1
fi
echo "✓ Step $testNum podmanVersion=$podmanVersion"
# Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
if [[ -z "$XDG_DATA_HOME" ]]; then
   echo "✖ Step $testNum FAIL: Failed to check existance of: XDG_DATA_HOME"
   echo "  Probably forgot to: source /container/setup_podman.sh"
   exit 1
fi
echo "✓ Step $testNum XDG_DATA_HOME=$XDG_DATA_HOME"
echo "✓ Step $testNum PASS"
echo

# --- Step 3: Check if the image exists in the local Podman repository (STOP on fail)
((++testNum))
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
   exit 1
fi
echo

# --- Step 4: Test OpenFOAM environment (STOP on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Testing recognition of OpenFOAM environment"

# Run command: stdout → variable, stderr → log
testLog="wm_version_test.log"
WM_PROJECT_VERSION=$(podman run --rm "$imageFull" bash -c 'echo $WM_PROJECT_VERSION')

# Check podman exit code
if [[ $? -ne 0 ]]; then
   echo "✖ Step $testNum FAIL: podman command failed (exit != 0)"
   exit 1
fi

# Check if variable is empty
if [[ -z "$WM_PROJECT_VERSION" ]]; then
   echo "✖ Step $testNum FAIL: WM_PROJECT_VERSION empty"
   exit 1
fi

# Check version format
if [[ ! "$WM_PROJECT_VERSION" =~ ^(v)?[0-9][0-9a-zA-Z-]*$ ]]; then
   echo "✖ Step $testNum FAIL: WM_PROJECT_VERSION='$WM_PROJECT_VERSION' invalid"
   exit 1
fi

echo "✓ Step $testNum PASS: WM_PROJECT_VERSION='$WM_PROJECT_VERSION' ✓"
echo

# --- Step 5: Test the OF_TOOL binary works (STOP on fail)  
((++testNum))
toolLog="${OF_TOOL}.log"
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Testing '$OF_TOOL -help' output from OpenFOAM tool in $imageFull"

# Run test & capture ALL output (stdout+stderr)
if ! podman run --rm "$imageFull" "$OF_TOOL" -help > "$toolLog" 2>&1; then
   echo "✖ Step $testNum FAIL: $OF_TOOL -help failed (non-zero exit)"
   echo "Check: $toolLog"
   exit 1
fi

# Check OpenFOAM version string exists
if ! (grep -qE "^Usage:" "$toolLog" &&
 grep -qE "^Options:" "$toolLog" &&
 grep -qE "^Using: OpenFOAM-${WM_PROJECT_VERSION}" "$toolLog"
) ; then
   echo "✖ Step $testNum FAIL: Missing required output lines."
   echo "Missing patterns:"
   [[ $(grep -cE "^Usage:" $toolLog) -eq 0 ]] && echo "   - ^Usage:"
   [[ $(grep -cE "^Options:" $toolLog) -eq 0 ]] && echo "   - ^Options:"
   [[ $(grep -cE "^Using: OpenFOAM-${WM_PROJECT_VERSION}" $toolLog) -eq 0 ]] && echo "  - ^Using: OpenFOAM-${WM_PROJECT_VERSION}"
   echo "Check: $toolLog"
   exit 1
fi

cat "$toolLog"
echo "✓ Step $testNum PASS: '$OF_TOOL -help' works + OpenFOAM signature found"
rm -f "$toolLog"
echo

# --- Final Summary
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Total steps run: $testNum"
if [[ $totalFailed -eq 0 ]]; then
   echo "✓ ALL STEPS PASSED! Image '$imageFull' looks good at minimal testing."
   echo " Image is ready for singularity build"
   exit 0
else
   echo "✖ $totalFailed STEP(S) FAILED:"
   for test in "${failedTests[@]}"; do
      echo "  - $test"
   done
   exit 1
fi