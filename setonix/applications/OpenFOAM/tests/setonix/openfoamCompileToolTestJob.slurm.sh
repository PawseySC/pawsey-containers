#!/bin/bash --login
# Slurm job for the OpenFOAM compile-tool functional test.
#
# This job verifies that an OpenFOAM Singularity image can support a typical
# user-development workflow. It locates the source of an existing OpenFOAM
# application inside the image, copies that source to a host directory, renames
# it as a test application, compiles it inside the container, and checks that
# the resulting executable runs correctly.
#
# Source files and compilation products remain on the host. The OpenFOAM build
# tools and runtime environment are provided by the Singularity image through a
# bind mount of the host work directory onto WM_PROJECT_USER_DIR in the image.
#
# OpenFOAM-version-specific values are read from buildAndValidationConfig/openfoamBuildAndValidation.config. The
# configuration should define:
#   COMPILE_TEMPLATE_TOOL  Existing OpenFOAM application to copy and compile.
#   COMPILED_TEST_TOOL     Name assigned to the copied test application.
#
# If COMPILE_TEMPLATE_TOOL is not set, DEFAULT_TOOL is used. If
# COMPILED_TEST_TOOL is not set, a name based on COMPILE_TEMPLATE_TOOL is used.
# The Singularity image may be supplied with --image or defined as
# SINGULARITY_CONTAINER in the configuration file. Each tracked invocation
# stores its logs, status, details, and summary under
# <recipe-dir>/artifacts/tests/compile-tool/.
#
# Examples:
#   sbatch openfoamCompileToolTestJob.slurm.sh \
#      --recipe-dir v2406 --image /path/to/openfoam-v2406.sif
#
#   sbatch openfoamCompileToolTestJob.slurm.sh \
#      --config v2406/buildAndValidationConfig/openfoamBuildAndValidation.config \
#      --image /path/to/openfoam-v2406.sif \
#      --work-root "$MYSCRATCH/OpenFOAM-functional-tests/$USER-v2406"
#
# Exit status:
#   0  The application was copied, compiled, found, and executed successfully.
#   1  Invalid input, setup failure, compilation failure, or test failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

#SBATCH --job-name=openfoam-compile-tool-test
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --mem=14GB
#SBATCH --time=00:10:00

# Treat any use of an unset variable as an error.
set -u

# --- Initial settings
thisScript=$(basename "$0")
recipeDirInput=""
configFileInput=""
imageInput=""
workRootInput=""
recipeDir=""
configFile=""
compileTestArtifactsDir=""
runArtifactsDir=""
runLog=""
statusFile=""
testDetailsFile=""
testSummaryFile=""
compileLog=""
toolLog=""
testArtifactsDirInput=""

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  sbatch $thisScript --recipe-dir <directory> --image <file> [--work-root <directory>] [--test-artifacts-dir <directory>]
  sbatch $thisScript --config <file> --image <file> [--work-root <directory>] [--test-artifacts-dir <directory>]
  $thisScript --help

Options:
  --recipe-dir, -r <directory>  OpenFOAM version directory containing the docker recipe and
                                 the buildAndValidationConfig/openfoamBuildAndValidation.config file
  --config, -c <file>           Explicit openfoamBuildAndValidation configuration file
  --image, -i <file>            Required Singularity SIF image
  --work-root <directory>       Override the host work root. The test defaults to MYSCRATCH.
  --test-artifacts-dir <dir>    Use a launcher-managed test artifact directory
  --help, -h                    Show this help message and exit

Submit this script as a Slurm batch job using sbatch.
Use '$thisScript --help' directly to display this help without submitting a job.
USAGE
}

# --- Parse command-line arguments
while [[ $# -gt 0 ]]; do
   case "$1" in
      --recipe-dir|-r)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --recipe-dir requires <directory>" >&2; usage >&2; exit 1; }
         recipeDirInput="$2"
         shift 2
         ;;
      --config|-c)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --config requires <file>" >&2; usage >&2; exit 1; }
         configFileInput="$2"
         shift 2
         ;;
      --image|-i)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --image requires <file>" >&2; usage >&2; exit 1; }
         imageInput="$2"
         shift 2
         ;;
      --work-root)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --work-root requires <directory>" >&2; usage >&2; exit 1; }
         workRootInput="$2"
         shift 2
         ;;
      --test-artifacts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --test-artifacts-dir requires <directory>" >&2; usage >&2; exit 1; }
         testArtifactsDirInput="$2"
         shift 2
         ;;
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

# --- Locate the version-specific openfoamBuildAndValidation configuration
# Use either the version directory or an explicit configuration path, not both.
[[ -z "$recipeDirInput" || -z "$configFileInput" ]] || {
   echo "ERROR: Use either --recipe-dir or --config, not both" >&2
   usage >&2
   exit 1
}

if [[ -n "$configFileInput" ]]; then
   [[ -f "$configFileInput" ]] || { echo "ERROR: Missing config: $configFileInput" >&2; exit 1; }
   configFile=$(realpath "$configFileInput")
   configDir=$(dirname "$configFile")
   [[ $(basename "$configDir") == "buildAndValidationConfig" ]] || {
      echo "ERROR: Cannot derive the OpenFOAM version directory from config: $configFile" >&2
      echo "       Expected the config below a buildAndValidationConfig directory." >&2
      exit 1
   }
   recipeDir=$(dirname "$configDir")
elif [[ -n "$recipeDirInput" ]]; then
   [[ -d "$recipeDirInput" ]] || { echo "ERROR: Missing recipe directory: $recipeDirInput" >&2; exit 1; }
   recipeDir=$(realpath "$recipeDirInput")
   configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
else
   echo "ERROR: --recipe-dir or --config is required" >&2
   usage >&2
   exit 1
fi

[[ -r "$configFile" ]] || { echo "ERROR: Configuration is not readable: $configFile" >&2; usage >&2; exit 1; }
[[ -n "$imageInput" ]] || { echo "ERROR: --image is required" >&2; usage >&2; exit 1; }
[[ -f "$imageInput" ]] || { echo "ERROR: SIF image not found: $imageInput" >&2; usage >&2; exit 1; }

# --- Resolve persistent artifacts for this test invocation
compileTestArtifactsDir="${recipeDir}/artifacts/tests/compile-tool"
mkdir -p "$compileTestArtifactsDir"
if [[ -n "$testArtifactsDirInput" ]]; then
   runArtifactsDir=$(realpath -m "$testArtifactsDirInput")
   mkdir -p "$runArtifactsDir" || { echo "ERROR: Cannot create test artifact directory: $runArtifactsDir" >&2; exit 1; }
   testTimestamp=$(date '+%Y%m%dT%H%M%S%z')
else
   latestLink="${compileTestArtifactsDir}/latest"
   [[ ! -e "$latestLink" || -L "$latestLink" ]] || { echo "ERROR: Refusing to replace non-symbolic-link: $latestLink" >&2; exit 1; }
   rm -f "$latestLink"
   echo "This directory contains timestamped compile-tool test artifacts. The latest link identifies the most recent tracked invocation." > "${compileTestArtifactsDir}/README.txt"
   testTimestamp=$(date '+%Y%m%dT%H%M%S%z')
   jobIdentifier=${SLURM_JOB_ID:-manual-$$}
   runArtifactsName="${testTimestamp}_singularity_${jobIdentifier}"
   runArtifactsDir="${compileTestArtifactsDir}/${runArtifactsName}"
   mkdir "$runArtifactsDir" || { echo "ERROR: Cannot create test artifact directory: $runArtifactsDir" >&2; exit 1; }
   ln -sfn "$runArtifactsName" "$latestLink"
fi
runLog="${runArtifactsDir}/compileTool.run.log"
statusFile="${runArtifactsDir}/compileTool.status.txt"
testDetailsFile="${runArtifactsDir}/compileTool-details.txt"
testSummaryFile="${runArtifactsDir}/compileTool-summary.txt"
compileLog="${runArtifactsDir}/compile.log"
toolLog="${runArtifactsDir}/tool-help.log"
printf '%s\n' RUNNING > "$statusFile"
record_test_status() {
   local exitStatus=$?
   trap - EXIT
   if [[ $exitStatus -eq 0 ]]; then printf '%s\n' SUCCESS > "$statusFile"; else printf '%s\n' FAILED > "$statusFile"; fi
   exit "$exitStatus"
}
trap record_test_status EXIT
exec > >(tee "$runLog") 2>&1

echo "Test artifacts: $runArtifactsDir"
echo "Complete job log: $runLog"
echo "Job status file: $statusFile"
echo

# --- Load the version-specific test settings
# Clear inherited values first so that all settings come from this invocation.
unset OPENFOAM_FORK OPENFOAM_VERSION DEFAULT_TOOL COMPILE_TEMPLATE_TOOL COMPILED_TEST_TOOL SINGULARITY_CONTAINER
# shellcheck source=/dev/null
source "$configFile"

COMPILE_TEMPLATE_TOOL=${COMPILE_TEMPLATE_TOOL:-${DEFAULT_TOOL:-}}
COMPILED_TEST_TOOL=${COMPILED_TEST_TOOL:-my${COMPILE_TEMPLATE_TOOL^}}

for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || {
      echo "ERROR: $requiredSetting is not defined in $configFile" >&2
      exit 1
   }
done
[[ -n "$COMPILE_TEMPLATE_TOOL" ]] || {
   echo "ERROR: Define COMPILE_TEMPLATE_TOOL or DEFAULT_TOOL in $configFile" >&2
   exit 1
}

# --- Resolve and validate the Singularity image
SINGULARITY_CONTAINER=$(realpath "$imageInput")
imageFileName=$(basename "$SINGULARITY_CONTAINER")
expectedSifPrefix="${OPENFOAM_FORK}--${OPENFOAM_VERSION}"
if [[ "$imageFileName" != "${expectedSifPrefix}"*.sif ]]; then
   echo "ERROR: Singularity image filename does not match the configured OpenFOAM identity" >&2
   echo "       Image filename:   $imageFileName" >&2
   echo "       Required pattern: ${expectedSifPrefix}*.sif" >&2
   exit 1
fi
imageChecksum=$(sha256sum "$SINGULARITY_CONTAINER" | awk '{print $1}')
echo "PASS: Singularity filename matches configured identity '${expectedSifPrefix}*.sif'"
{
   echo "Test timestamp: $testTimestamp"
   echo "Slurm job ID: ${SLURM_JOB_ID:-manual}"
   echo "Configuration: $configFile"
   echo "Recipe directory: $recipeDir"
   echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
   echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
   echo "SIF image: $SINGULARITY_CONTAINER"
   echo "SIF SHA256: $imageChecksum"
   echo "Template tool: $COMPILE_TEMPLATE_TOOL"
   echo "Compiled test tool: $COMPILED_TEST_TOOL"
} > "$testDetailsFile"

# --- Step 1: Set up the Singularity environment
# The test assumes that the image is supplied directly and is not part of a
# software module. Only the Singularity runtime module is loaded here.
echo "$thisScript: -----------------------------------------"
echo "Step 1 - Setting up the Singularity environment"
module load singularity/4.1.0-mpi || { echo "ERROR: Failed to load singularity/4.1.0-mpi" >&2; exit 1; }
module list
echo "PASS: Singularity environment ready"
echo

# --- Step 2: Read the OpenFOAM user environment from the image
# WM_PROJECT_USER_DIR is the path that OpenFOAM expects for user applications
# inside the container. A host directory will be bound to this location.
echo "$thisScript: -----------------------------------------"
echo "Step 2 - Reading the OpenFOAM environment from the image"
WM_PROJECT_VERSION=$(singularity exec "$SINGULARITY_CONTAINER" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || {
   echo "ERROR: Failed to read WM_PROJECT_VERSION" >&2
   exit 1
}
[[ -n "$WM_PROJECT_VERSION" ]] || { echo "ERROR: WM_PROJECT_VERSION is empty in the image environment" >&2; exit 1; }
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

wmpudInside=$(singularity exec "$SINGULARITY_CONTAINER" bash -c 'printf "%s" "$WM_PROJECT_USER_DIR"') || {
   echo "ERROR: Failed to read WM_PROJECT_USER_DIR" >&2
   exit 1
}
[[ -n "$wmpudInside" ]] || { echo "ERROR: WM_PROJECT_USER_DIR is empty" >&2; exit 1; }

echo "OpenFOAM version: $WM_PROJECT_VERSION"
echo "Container user directory: $wmpudInside"
echo "PASS: OpenFOAM environment found"
echo

# --- Step 3: Prepare the host development directory
# Functional-test products are temporary, so MYSCRATCH is preferred by default.
# For persistent development files, specify a MYSOFTWARE location explicitly:
#
#   --work-root "$MYSOFTWARE/OpenFOAM/$USER-$WM_PROJECT_VERSION"
#
# The OpenFOAM-functional-tests directory distinguishes disposable test files
# from normal user-development files.
echo "$thisScript: -----------------------------------------"
echo "Step 3 - Preparing the host development directory"
if [[ -n "$workRootInput" ]]; then
   wmpudOutside=$(realpath -m "$workRootInput")
else
   baseWorkDir=${MYSCRATCH:-${TMPDIR:-$HOME}}
   invocationName=$(basename "$runArtifactsDir")
   wmpudOutside="${baseWorkDir}/OpenFOAM-functional-tests/${USER}-${WM_PROJECT_VERSION}/${invocationName}"
fi

myToolPath="${wmpudOutside}/applications/${COMPILED_TEST_TOOL}"
rm -rf "$myToolPath"
mkdir -p "$myToolPath"

echo "Host user directory: $wmpudOutside"
echo "New tool directory: $myToolPath"
echo "PASS: Clean development directory created"
echo

# --- Step 4: Find the template application inside the image
# Exactly one matching source directory is required. Multiple matches would make
# the source selection ambiguous and could cause the wrong application to be used.
echo "$thisScript: -----------------------------------------"
echo "Step 4 - Finding the '$COMPILE_TEMPLATE_TOOL' source directory"
mapfile -t toolPaths < <(singularity exec "$SINGULARITY_CONTAINER" bash -c \
   'find "$FOAM_APP" -type d -name "$1" -print' bash "$COMPILE_TEMPLATE_TOOL")

[[ ${#toolPaths[@]} -eq 1 ]] || {
   echo "ERROR: Expected exactly one source directory for $COMPILE_TEMPLATE_TOOL; found ${#toolPaths[@]}" >&2
   printf '  %s\n' "${toolPaths[@]}"
   exit 1
}
templatePath=${toolPaths[0]}

echo "Template source: $templatePath"
echo "PASS: Unique template source found"
echo

# --- Step 5: Copy the template source to the host
# The destination is expressed using the container-side path because the copy
# runs inside Singularity. The bind mount stores the copied files on the host.
echo "$thisScript: -----------------------------------------"
echo "Step 5 - Copying the template source to the host"
singularity exec -B "${wmpudOutside}:${wmpudInside}" "$SINGULARITY_CONTAINER" \
   bash -c 'cp -a "$1"/. "$2"/' bash "$templatePath" "${wmpudInside}/applications/${COMPILED_TEST_TOOL}" || {
      echo "ERROR: Failed to copy the template source" >&2
      exit 1
   }

echo "PASS: Template source copied"
echo

# --- Step 6: Rename and configure the copied application
# Rename the main source file and update Make/files so that wmake creates the
# requested test executable under FOAM_USER_APPBIN.
echo "$thisScript: -----------------------------------------"
echo "Step 6 - Renaming and configuring the copied application"
sourceFile="${myToolPath}/${COMPILE_TEMPLATE_TOOL}.C"
[[ -f "$sourceFile" ]] || { echo "ERROR: Expected source file not found: $sourceFile" >&2; exit 1; }

mv "$sourceFile" "${myToolPath}/${COMPILED_TEST_TOOL}.C"
[[ -f "${myToolPath}/Make/files" ]] || { echo "ERROR: Make/files not found" >&2; exit 1; }
sed -i "s/${COMPILE_TEMPLATE_TOOL}/${COMPILED_TEST_TOOL}/g" "${myToolPath}/Make/files"
sed -i 's/FOAM_APPBIN/FOAM_USER_APPBIN/g' "${myToolPath}/Make/files"

echo "Template tool: $COMPILE_TEMPLATE_TOOL"
echo "New tool: $COMPILED_TEST_TOOL"
echo "PASS: Source and build settings updated"
echo

# --- Step 7: Compile the new application inside the image
# wclean and wmake run in the image while reading and writing the bind-mounted
# host directory. The resulting source and binary therefore remain on the host.
echo "$thisScript: -----------------------------------------"
echo "Step 7 - Compiling '$COMPILED_TEST_TOOL' with wclean and wmake"
singularity exec -B "${wmpudOutside}:${wmpudInside}" "$SINGULARITY_CONTAINER" \
   bash -c 'cd "$1" && wclean && wmake' bash "${wmpudInside}/applications/${COMPILED_TEST_TOOL}" \
   2>&1 | tee "$compileLog"
compileStatus=${PIPESTATUS[0]}
if [[ $compileStatus -ne 0 ]]; then
   echo "ERROR: Compilation failed for $COMPILED_TEST_TOOL with exit status $compileStatus" >&2
   exit 1
fi

echo "PASS: Compilation completed"
echo

# --- Step 8: Verify that the compiled binary exists on the host
# FOAM_USER_APPBIN is returned as a container path. Translate the bind-mounted
# WM_PROJECT_USER_DIR prefix into its corresponding host path before checking it.
echo "$thisScript: -----------------------------------------"
echo "Step 8 - Verifying the compiled binary"
myToolBinaryInside=$(singularity exec -B "${wmpudOutside}:${wmpudInside}" "$SINGULARITY_CONTAINER" \
   bash -c 'printf "%s/%s" "$FOAM_USER_APPBIN" "$1"' bash "$COMPILED_TEST_TOOL") || {
      echo "ERROR: Failed to determine FOAM_USER_APPBIN" >&2
      exit 1
   }

case "$myToolBinaryInside" in
   "$wmpudInside"/*)
      myToolBinary="${wmpudOutside}${myToolBinaryInside#"$wmpudInside"}"
      ;;
   *)
      echo "ERROR: FOAM_USER_APPBIN is not below WM_PROJECT_USER_DIR" >&2
      echo "       FOAM_USER_APPBIN binary: $myToolBinaryInside" >&2
      echo "       WM_PROJECT_USER_DIR:     $wmpudInside" >&2
      exit 1
      ;;
esac

[[ -f "$myToolBinary" ]] || {
   echo "ERROR: Compiled binary does not exist on the host" >&2
   echo "       Container path: $myToolBinaryInside" >&2
   echo "       Host path:      $myToolBinary" >&2
   exit 1
}

echo "Compiled binary:"
ls -l "$myToolBinary"
echo "PASS: Compiled binary found"
echo

# --- Step 9: Run a basic functional test of the new application
# WM_PROJECT_USER_DIR places FOAM_USER_APPBIN on PATH inside the image, so the
# executable can be invoked by name. Preserve the command output in the
# invocation artifact directory and check its exit status and output signatures.
echo "$thisScript: -----------------------------------------"
echo "Step 9 - Testing '$COMPILED_TEST_TOOL -help'"
singularity exec -B "${wmpudOutside}:${wmpudInside}" "$SINGULARITY_CONTAINER" \
   "$COMPILED_TEST_TOOL" -help 2>&1 | tee "$toolLog"
status=${PIPESTATUS[0]}

[[ $status -eq 0 ]] || {
   echo "ERROR: $COMPILED_TEST_TOOL -help returned $status" >&2
   exit 1
}
grep -qE '^Usage:' "$toolLog" || {
   echo "ERROR: No Usage line found in $toolLog" >&2
   exit 1
}
grep -qE '^Options:' "$toolLog" || {
   echo "ERROR: No Options line found in $toolLog" >&2
   exit 1
}
grep -qF "Using: OpenFOAM-${WM_PROJECT_VERSION}" "$toolLog" || {
   echo "ERROR: No matching OpenFOAM version line found in $toolLog" >&2
   exit 1
}

echo "PASS: '$COMPILED_TEST_TOOL -help' works"
echo

# --- Final summary
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Template tool: $COMPILE_TEMPLATE_TOOL"
echo "Compiled tool: $COMPILED_TEST_TOOL"
echo "Compiled binary: $myToolBinary"
echo "Compile log: $compileLog"
echo "Tool output log: $toolLog"
echo "Test artifacts: $runArtifactsDir"
echo "Status file: $statusFile"
echo "Complete run log: $runLog"
{
   echo "Result: SUCCESS"
   echo "SIF image: $SINGULARITY_CONTAINER"
   echo "SIF SHA256: $imageChecksum"
   echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
   echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
   echo "Image OpenFOAM version: $WM_PROJECT_VERSION"
   echo "Template tool: $COMPILE_TEMPLATE_TOOL"
   echo "Compiled tool: $COMPILED_TEST_TOOL"
   echo "Compiled binary: $myToolBinary"
   echo "Compile log: $compileLog"
   echo "Tool output log: $toolLog"
} > "$testSummaryFile"
echo "Test summary: $testSummaryFile"
echo "ALL STEPS PASSED: OpenFOAM application compilation test completed successfully."

# Return success to the caller.
exit 0
