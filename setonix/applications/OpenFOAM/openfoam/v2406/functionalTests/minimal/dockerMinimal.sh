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
echo "Will run minimal tests with docker image $imageFull"

# --- Step 1: Setting docker environment (STOP on fail)
#             Adapt process to your own system needs 
((++testNum))
echo "$thisScript: -----------------------------------------"
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
   exit 1
fi
echo "✓ Step $testNum PASS: Docker ready"
echo

# --- Step 2: Checking if docker is correctly set (STOP on fail)
#             Adapt checks to your own system needs
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking if docker is accessible."
dockerVersion=$(docker --version)
if [[ -z "$dockerVersion" ]]; then
   echo "✖ Step $testNum FAIL: Failed to execute: docker --version"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum dockerVersion=$dockerVersion"
echo "✓ Step $testNum PASS"
echo

# --- Step 3: Check if the image exists in the local Docker repository (STOP on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "$thisScript: Step $testNum - Verifying image $imageFull exists in docker registry"
if docker images -q "${imageFull}" | grep -q .; then
   imageRepo=$(docker image inspect "${imageFull}" --format '{{index .RepoTags 0}}')
   imageSize=$(docker images --format "{{.Size}}" "${imageFull}" | numfmt --to=iec)
   echo "✓ Step $testNum PASS: Image found!"
   echo "  Repository: $imageRepo"
   echo "  Size: $imageSize"
else
   echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in docker registry"
   docker images | grep "${imageFull}" || echo "  No matching images found"
   exit 1
fi
echo

# --- Step 4: Test OpenFOAM environment (STOP on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Testing recognition of OpenFOAM environment"

# Run command: stdout → variable, stderr → log
testLog="wm_version_test.log"
WM_PROJECT_VERSION=$(docker run --rm "$imageFull" bash -c 'echo $WM_PROJECT_VERSION')

# Check docker exit code
if [[ $? -ne 0 ]]; then
   echo "✖ Step $testNum FAIL: docker command failed (exit != 0)"
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
if ! docker run --rm "$imageFull" "$OF_TOOL" -help > "$toolLog" 2>&1; then
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