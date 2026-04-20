#!/bin/bash
# Unified basic test script for Docker, Podman, or Singularity
# Usage: basicTests.sh --engine docker|podman|singularity [--tool TOOL] <image>

# --- Initial settings
thisScript=$(basename "$0")
testNum=0
failedTests=()
totalFailed=0
DEFAULT_TOOL="icoFoam"

# --- Helper: run a command inside the container image (for the different engines)
engine_run() {
   if [[ "$ENGINE" == "singularity" ]]; then
      singularity exec "$imageRef" "$@"
   else
      $ENGINE run --rm "$imageRef" "$@"
   fi
}

# --- Parse & validate command line arguments
ENGINE=""
positionalArgs=()
while [[ $# -gt 0 ]]; do
   case $1 in
      --engine)
         ENGINE="$2"
         if [[ -z "$ENGINE" ]]; then
            echo "ERROR: --engine requires docker|podman|singularity" >&2
            echo "Usage: $0 --engine docker|podman|singularity <image> [--tool OF_TOOL] <image>" >&2
            exit 1
         fi
         shift 2
         ;;
      --tool)
         if [[ -z "$2" ]]; then
            echo "ERROR: --tool requires an OpenFOAM tool name" >&2
            echo "Usage: $0 --engine docker|podman|singularity [--tool OF_TOOL] <image>" >&2
            exit 1
         fi
         USER_TOOL="$2"
         shift 2
         ;;
      -h|--help)
         echo "Usage: $0 --engine docker|podman|singularity [--tool OF_TOOL] <image>"
         echo "  --engine docker|podman|singularity   Container engine to use (required)"
         echo "  <image>   Image name:tag (docker/podman) or .sif path (singularity)"
         exit 0
         ;;
      -*)
         echo "ERROR: Unknown option '$1'" >&2
         echo "Usage: $0 --engine docker|podman|singularity [--tool OF_TOOL] <image>" >&2
         exit 1
         ;;
      *)
         positionalArgs+=("$1")
         shift
         ;;
   esac
done

# Engine validation
if [[ -z "$ENGINE" ]]; then
   echo "ERROR: --engine docker|podman|singularity is required" >&2
   echo "Usage: $0 --engine docker|podman|singularity [--tool OF_TOOL] <image>" >&2
   exit 1
fi
if [[ "$ENGINE" != "docker" && "$ENGINE" != "podman" && "$ENGINE" != "singularity" ]]; then
   echo "ERROR: --engine must be 'docker', 'podman', or 'singularity', got '$ENGINE'" >&2
   exit 1
fi

# Positional argument validation
if [[ ${#positionalArgs[@]} -ne 1 ]]; then
   echo "ERROR: Exactly 1 positional argument required (image)" >&2
   echo "Usage: $0 --engine docker|podman|singularity [--tool OF_TOOL] <image>" >&2
   exit 1
fi
imageRef="${positionalArgs[0]}"
echo "Will run minimal tests with $ENGINE image $imageRef"

# Tool to use for the minimal test
if [[ -n "$USER_TOOL" ]]; then
   OF_TOOL="$USER_TOOL"
   echo "Will use the indicated tool ${OF_TOOL} for the minimal functional test"
else
   OF_TOOL="$DEFAULT_TOOL"
   echo "Will use the default tool ${OF_TOOL} for the minimal functional test"
fi


# --- Step 1: Setting container engine environment (STOP on fail)
#             Adapt process to your own system needs 
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Setting up $ENGINE environment"
case "$ENGINE" in
   docker)
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
      ;;
   podman)
      echo "Step $testNum - Sourcing the podman settings"
      # Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
      if ! source /container/setup_podman.sh 2>/dev/null; then
         echo "✖ Step $testNum FAIL: Failed to: source /container/setup_podman.sh"
         exit 1
      fi
      ;;
   singularity)
      echo "Step $testNum - Loading Singularity module"
      # Check for use only on restricted singularity nodes at Pawsey. Adapt the check to your own system needs.
      if ! module load singularity/4.1.0-mpi 2>/dev/null; then
         echo "✖ Step $testNum FAIL: Failed to: module load singularity/4.1.0-mpi"
         ((totalFailed++))
         exit 1
      fi
      ;;
esac
echo "✓ Step $testNum PASS: ${ENGINE^} ready"
echo

# --- Step 2: Checking if container engine is correctly set (STOP on fail)
#             Adapt checks to your own system needs
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking if $ENGINE is accessible."
if [[ "$ENGINE" == "singularity" ]]; then
   engineVersion=$(singularity --version)
else
   engineVersion=$($ENGINE --version)
fi
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
      exit 1
   fi
   echo "✓ Step $testNum XDG_DATA_HOME=$XDG_DATA_HOME"
fi
echo "✓ Step $testNum PASS"
echo

# --- Step 3: Check if the image exists
((++testNum))

# Helper function: check image and print repo + size
checkImageExistance() {
   local engine="$1"        # docker or podman
   local img="$2"

   if "$engine" images -q "$img" | grep -q .; then
      imageRepo=$("$engine" image inspect "$img" --format '{{index .RepoTags 0}}')
      imageSize=$("$engine" images --format "{{.Size}}" "$img" | numfmt --to=iec)
      echo "✓ Step $testNum PASS: Image found in $engine registry."
      echo "  Repository: $imageRepo"
      echo "  Size: $imageSize"
   else
      echo "✖ Step $testNum FAIL: Image '$img' not found in $engine registry"
      "$engine" images | grep "$img" || echo "  No matching images found"
      exit 1
   fi
}

echo "$thisScript: -----------------------------------------"
echo "$thisScript: Step $testNum - Verifying image $imageRef exists"
case "$ENGINE" in
   docker|podman)
      checkImageExistance "$ENGINE" "$imageRef"
      ;;
   singularity)
      if [[ -f "$imageRef" ]]; then
         echo "✓ Step $testNum PASS: Image found in ${imageRef}"
      else
         echo "✖ Step $testNum FAIL: Image '${imageRef}' not found in the given path"
         exit 1
      fi
      ;;
   *)
      echo "ERROR: --engine must be docker, podman, or singularity" >&2
      exit 1
      ;;
esac
echo

# --- Step 4: Test OpenFOAM environment (STOP on fail)
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Testing recognition of OpenFOAM environment"

# Run command: stdout → variable, stderr → log
testLog="wm_version_test.log"
WM_PROJECT_VERSION=$(engine_run bash -c 'echo $WM_PROJECT_VERSION')

# Check exit code
if [[ $? -ne 0 ]]; then
   echo "✖ Step $testNum FAIL: $ENGINE command failed (exit != 0)"
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
echo "Step $testNum - Testing '$OF_TOOL -help' output from OpenFOAM tool in $imageRef"

# Run test & capture ALL output (stdout+stderr)
if ! engine_run "$OF_TOOL" -help > "$toolLog" 2>&1; then
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
   echo "✓ ALL STEPS PASSED! Image '$imageRef' with $ENGINE looks good at minimal testing."
   exit 0
else
   echo "✖ $totalFailed STEP(S) FAILED:"
   for test in "${failedTests[@]}"; do
      echo "  - $test"
   done
   exit 1
fi
