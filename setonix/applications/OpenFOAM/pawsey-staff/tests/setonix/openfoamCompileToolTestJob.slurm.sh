#!/bin/bash --login
# Slurm job for the OpenFOAM compile-tool functional test.
#
# This job validates a user application-development workflow with exactly one
# OpenFOAM runtime: an explicit Singularity image, an SHPC container module, or a
# bare-metal module. It locates a configured installed application, copies the
# source into the same isolated host workspace in every mode, renames and updates
# the application, compiles it with wclean and wmake, verifies the executable,
# and validates its help output.
#
# Runtime-specific setup is deliberately limited:
#
#   * Image mode binds the host workspace onto the image WM_PROJECT_USER_DIR.
#   * SHPC mode loads <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>, uses the
#     generic <OPENFOAM_FORK>-exec wrapper, and applies the same bind mapping.
#   * Bare-metal mode loads <OPENFOAM_FORK>/<OPENFOAM_VERSION>, assigns the host
#     workspace directly to WM_PROJECT_USER_DIR, and explicitly realigns
#     FOAM_USER_APPBIN and FOAM_USER_LIBBIN before running commands directly.
#
# The source transformation, compilation, binary checks, functional test, logs,
# status handling, and summaries are otherwise shared by all runtime modes.
#
# Examples:
#   sbatch openfoamCompileToolTestJob.slurm.sh \
#      --recipe-dir openfoam/v2406 --shpc
#
#   sbatch openfoamCompileToolTestJob.slurm.sh \
#      --config openfoam/v2406/buildAndValidationConfig/openfoamBuildAndValidation.config \
#      --bare-metal

#SBATCH --job-name=openfoam-compile-tool-test
##SBATCH --partition=debug
#SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --mem=14GB
#SBATCH --time=00:10:00

# Treat any use of an unset variable as an error.
set -u

# In explicit-image mode, SINGULARITY_IMAGE is resolved from --image. In SHPC
# mode, SINGULARITY_CONTAINER is validated and canonicalized into
# SINGULARITY_IMAGE. All subsequent container operations use SINGULARITY_IMAGE.
#
# --- Initial settings
thisScript=$(basename "$0")
recipeDirInput=""
configFileInput=""
imageInput=""
singularityModule="singularity/4.3.5-mpi"
singularityModuleSpecified=false
useSHPC=false
useBareMetal=false
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
  sbatch $thisScript --recipe-dir <directory> --shpc [--work-root <directory>] [--test-artifacts-dir <directory>]
  sbatch $thisScript --recipe-dir <directory> --bare-metal [--work-root <directory>] [--test-artifacts-dir <directory>]
  sbatch $thisScript --config <file> --image <file> [--work-root <directory>] [--test-artifacts-dir <directory>]
  sbatch $thisScript --config <file> --shpc [--work-root <directory>] [--test-artifacts-dir <directory>]
  sbatch $thisScript --config <file> --bare-metal [--work-root <directory>] [--test-artifacts-dir <directory>]
  $thisScript --help

Options:
  --recipe-dir, -r <directory>  OpenFOAM version directory containing the docker recipe and
                                 the buildAndValidationConfig/openfoamBuildAndValidation.config file
  --config, -c <file>           Explicit openfoamBuildAndValidation configuration file
  --image, -i <file>            Use the supplied Singularity SIF image
  --singularity-module <module>  Singularity module for --image or --shpc mode
                                (default: singularity/4.3.5-mpi)
  --shpc                        Use <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>
  --bare-metal                  Use <OPENFOAM_FORK>/<OPENFOAM_VERSION>
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
      --singularity-module)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --singularity-module requires <module>" >&2; usage >&2; exit 1; }
         singularityModule="$2"
         singularityModuleSpecified=true
         shift 2
         ;;
      --shpc)
         useSHPC=true
         shift
         ;;
      --bare-metal)
         useBareMetal=true
         shift
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
runtimeSelectorCount=0
[[ -n "$imageInput" ]] && ((runtimeSelectorCount += 1))
[[ "$useSHPC" == true ]] && ((runtimeSelectorCount += 1))
[[ "$useBareMetal" == true ]] && ((runtimeSelectorCount += 1))
[[ $runtimeSelectorCount -eq 1 ]] || { echo "ERROR: Choose exactly one of --image <file>, --shpc, or --bare-metal" >&2; usage >&2; exit 1; }
if [[ -n "$imageInput" ]]; then
   [[ -f "$imageInput" ]] || { echo "ERROR: Singularity image not found: $imageInput" >&2; exit 1; }
   [[ -r "$imageInput" ]] || { echo "ERROR: Singularity image is not readable: $imageInput" >&2; exit 1; }
   SINGULARITY_IMAGE=$(realpath "$imageInput")
fi
if [[ "$useSHPC" == true ]]; then
   artifactRuntimeName="shpc"
elif [[ "$useBareMetal" == true ]]; then
   artifactRuntimeName="bare-metal"
else
   artifactRuntimeName="singularity"
fi

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
   runArtifactsName="${testTimestamp}_${artifactRuntimeName}_${jobIdentifier}"
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
if [[ "$singularityModuleSpecified" == true && "$useBareMetal" == true ]]; then
   echo "ERROR: --singularity-module cannot be used with --bare-metal" >&2
   usage >&2
   exit 1
fi
trap record_test_status EXIT
exec > >(tee "$runLog") 2>&1

echo "Test artifacts: $runArtifactsDir"
echo "Complete job log: $runLog"
echo "Job status file: $statusFile"
echo

# --- Load the version-specific test settings
# Clear inherited values first so that all settings come from this invocation.
# Clear only values that must come from the selected version configuration.
# Do not clear SINGULARITY_IMAGE here: explicit-image mode has already set it
# from --image, while SHPC mode sets it later when its module is loaded.
unset OPENFOAM_FORK OPENFOAM_VERSION DEFAULT_TOOL COMPILE_TEMPLATE_TOOL COMPILED_TEST_TOOL
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

# --- Step 1: Load and validate the selected OpenFOAM runtime
if [[ "$useSHPC" == true ]]; then
   runtimeMode="SHPC module"
   shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
   bareMetalModule=""
   shpcExec="${OPENFOAM_FORK}-exec"
   module load "$shpcModule" || { echo "ERROR: Failed to load $shpcModule" >&2; exit 1; }
   SINGULARITY_IMAGE=$SINGULARITY_CONTAINER
   command -v "$shpcExec" >/dev/null 2>&1 || { echo "ERROR: Missing SHPC wrapper: $shpcExec" >&2; exit 1; }
   [[ -n "${SINGULARITY_CONTAINER:-}" ]] || { echo "ERROR: $shpcModule did not set SINGULARITY_CONTAINER" >&2; exit 1; }
   [[ -r "$SINGULARITY_CONTAINER" ]] || { echo "ERROR: SHPC backing image is not readable: $SINGULARITY_CONTAINER" >&2; exit 1; }
   SINGULARITY_IMAGE=$(realpath "$SINGULARITY_CONTAINER")
   if [[ "$singularityModuleSpecified" == true ]]; then
      module load "$singularityModule" || { echo "ERROR: Failed to switch to Singularity module: $singularityModule" >&2; exit 1; }
      command -v singularity >/dev/null 2>&1 || { echo "ERROR: singularity unavailable after loading $singularityModule" >&2; exit 1; }
   fi
   runtimeExec=("$shpcExec")
elif [[ "$useBareMetal" == true ]]; then
   runtimeMode="Bare-metal module"
   bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
   shpcModule=""
   shpcExec=""
   module load "$bareMetalModule" || { echo "ERROR: Failed to load $bareMetalModule" >&2; exit 1; }
   for requiredCommand in find cp sed wclean wmake; do
      command -v "$requiredCommand" >/dev/null 2>&1 || { echo "ERROR: Missing command: $requiredCommand" >&2; exit 1; }
   done
   runtimeExec=()
else
   runtimeMode="Explicit Singularity image"
   bareMetalModule=""
   shpcModule=""
   shpcExec=""
   # The supplied filename is not used as runtime identity. The authoritative
   # version check reads WM_PROJECT_VERSION from inside the image below.
   module load "$singularityModule" || { echo "ERROR: Failed to load $singularityModule" >&2; exit 1; }
   runtimeExec=(singularity exec "$SINGULARITY_IMAGE")
fi
imageChecksum=""
if [[ "$useBareMetal" != true ]]; then
   imageChecksum=$(sha256sum "$SINGULARITY_IMAGE" | awk '{print $1}')
fi
echo "Loaded modules:"
module list
echo "Execution mode: $runtimeMode"
[[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"
[[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"
[[ "$useBareMetal" != true ]] && echo "Backing image: $SINGULARITY_IMAGE"

if [[ "$useBareMetal" == true ]]; then
   WM_PROJECT_VERSION=${WM_PROJECT_VERSION:-}
   wmpudInside=""
else
   WM_PROJECT_VERSION=$("${runtimeExec[@]}" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || { echo "ERROR: Failed to read WM_PROJECT_VERSION" >&2; exit 1; }
   wmpudInside=$("${runtimeExec[@]}" bash -c 'printf "%s" "$WM_PROJECT_USER_DIR"') || { echo "ERROR: Failed to read WM_PROJECT_USER_DIR" >&2; exit 1; }
fi
[[ "$WM_PROJECT_VERSION" == "$OPENFOAM_VERSION" ]] || { echo "ERROR: Runtime version '$WM_PROJECT_VERSION' does not match '$OPENFOAM_VERSION'" >&2; exit 1; }
if [[ "$useBareMetal" != true && -z "$wmpudInside" ]]; then
   echo "ERROR: WM_PROJECT_USER_DIR is empty in the selected container runtime" >&2
   exit 1
fi

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

# Use the SHPC generic wrapper in module mode. Explicit-image mode binds the
# writable host development tree to WM_PROJECT_USER_DIR inside the selected runtime.
if [[ "$useBareMetal" == true ]]; then
   # The bare-metal module calculates its user paths when it is loaded. Repoint
   # the complete user-development environment to the isolated host workspace,
   # then update the executable and library search paths to match those values.
   wmpudInside="$wmpudOutside"
   export WM_PROJECT_USER_DIR="$wmpudOutside"
   export FOAM_USER_APPBIN="${WM_PROJECT_USER_DIR}/platforms/${WM_OPTIONS}/bin"
   export FOAM_USER_LIBBIN="${WM_PROJECT_USER_DIR}/platforms/${WM_OPTIONS}/lib"
   export PATH="${FOAM_USER_APPBIN}:${PATH}"
   export LD_LIBRARY_PATH="${FOAM_USER_LIBBIN}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

   mkdir -p \
      "${WM_PROJECT_USER_DIR}/applications" \
      "$FOAM_USER_APPBIN" \
      "$FOAM_USER_LIBBIN"

   # An empty command prefix makes the shared workflow execute find, copy,
   # wclean, wmake, and the compiled application directly on the host.
   runtimeExecBound=()
elif [[ "$useSHPC" == true ]]; then
   # The SHPC wrapper consumes the standard Singularity bind environment. This
   # presents the writable host development tree at WM_PROJECT_USER_DIR for all
   # generic wrapper calls and for the OpenFOAM command wrappers they launch.
   export SINGULARITY_BIND="${wmpudOutside}:${wmpudInside}"
   runtimeExecBound=("$shpcExec")
else
   runtimeExecBound=(
      singularity exec
      -B "${wmpudOutside}:${wmpudInside}"
      "$SINGULARITY_IMAGE"
   )
fi

# --- Step 4: Find the template application inside the selected runtime
# Exactly one matching source directory is required. Multiple matches would make
# the source selection ambiguous and could cause the wrong application to be used.
echo "$thisScript: -----------------------------------------"
echo "Step 4 - Finding the '$COMPILE_TEMPLATE_TOOL' source directory"
mapfile -t toolPaths < <("${runtimeExec[@]}" bash -c \
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
# The destination is expressed using the runtime-visible path. Container modes use the host-to-container mapping;
# bare-metal mode uses the same host path directly.
echo "$thisScript: -----------------------------------------"
echo "Step 5 - Copying the template source to the host"
"${runtimeExecBound[@]}" \
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

# --- Step 7: Compile the new application inside the selected runtime
# wclean and wmake run in the selected runtime while reading and writing the
# same host development directory. The resulting source and binary therefore remain on the host.
echo "$thisScript: -----------------------------------------"
echo "Step 7 - Compiling '$COMPILED_TEST_TOOL' with wclean and wmake"
"${runtimeExecBound[@]}" \
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
# Resolve FOAM_USER_APPBIN in the selected runtime. Container modes translate the
# mapped prefix to the host workspace; bare-metal mode already returns a host path.
echo "$thisScript: -----------------------------------------"
echo "Step 8 - Verifying the compiled binary"
myToolBinaryInside=$("${runtimeExecBound[@]}" \
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
# Container runtimes already expose FOAM_USER_APPBIN on their internal PATH.
# Bare-metal setup explicitly prepends the reassigned FOAM_USER_APPBIN above.
# Invoking the application by name therefore verifies both the executable and
# the complete user-development environment in every runtime mode.
echo "$thisScript: -----------------------------------------"
echo "Step 9 - Testing '$COMPILED_TEST_TOOL -help'"
"${runtimeExecBound[@]}" \
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
grep -qiE '^options:' "$toolLog" || {
   echo "ERROR: No Options (or options) line found in $toolLog" >&2
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
   echo "Runtime mode: $runtimeMode"
   [[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"
   [[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"
   [[ "$useBareMetal" != true ]] && echo "Backing image: $SINGULARITY_IMAGE"
   [[ "$useBareMetal" != true ]] && echo "SIF SHA256: $imageChecksum"
   echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
   echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
   echo "Runtime OpenFOAM version: $WM_PROJECT_VERSION"
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
