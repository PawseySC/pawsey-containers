#!/bin/bash --login
# Extract and validate an OpenFOAM tutorial case from an explicit
# Singularity image, the installed SHPC container module, or the corresponding
# bare-metal OpenFOAM module.
#
# This script is the first stage of the version-specific OpenFOAM tutorial
# functional test. It locates exactly one selected tutorial inside the active
# container runtime, copies a clean case tree to the host, and verifies the files
# required by the preparation and solver stages.
#
# Runtime modes
# -------------
# Explicit-image mode receives --image and executes generic container commands
# with Singularity. SHPC mode receives --shpc, derives the installed module from
# OPENFOAM_FORK and OPENFOAM_VERSION in the required configuration file, and
# executes generic container commands through the module-provided <fork>-exec
# wrapper. Bare-metal mode loads <OPENFOAM_FORK>/<OPENFOAM_VERSION> and runs
# directly in the host environment. The three modes are mutually exclusive.
#
# The script runs directly and does not submit a Slurm job. The general tutorial
# launcher normally supplies the runtime selection, configuration file, isolated
# work root, test-artifact directory, and overwrite policy. The script can also
# be run independently with the same arguments.
#
# Usage:
#   ./extractCase.sh --image <file> --config <file> [options]
#   ./extractCase.sh --shpc --config <file> [options]
#   ./extractCase.sh --bare-metal --config <file> [options]
#
# Exit status:
#   0  The tutorial case was uniquely located, copied, and validated.
#   1  Invalid input, runtime setup failure, copy failure, or validation failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

# Treat any use of an unset variable as an error.
set -u

# --- Version-specific tutorial settings
# This extraction script belongs to the same version-specific workflow as preFoam.slurm.sh
# and runFoam.slurm.sh, so all three scripts intentionally use the same case.
CASE_NAME="channel395"

# --- Initial settings
thisScript=$(basename "$0")
imageInput=""
useSHPC=false
useBareMetal=false
workRootInput=""
configFileInput=""
testArtifactsDirInput=""
overwriteCase=false
SINGULARITY_MODULE=${SINGULARITY_MODULE:-singularity/4.3.5-mpi}

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  $thisScript --image <file> --config <file> [options]
  $thisScript --shpc --config <file> [options]
  $thisScript --bare-metal --config <file> [options]
  $thisScript --help

Runtime selection (choose exactly one):
  --image, -i <file>          Use the supplied Singularity image directly
  --shpc                      Load <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>
  --bare-metal                Load <OPENFOAM_FORK>/<OPENFOAM_VERSION> and use the
                              host OpenFOAM environment directly

Required in both modes:
  --config <file>             Version configuration file defining OPENFOAM_FORK
                              and OPENFOAM_VERSION

Optional settings:
  --work-root, -w <directory> Override the host work root. By default, use:
                              MYSCRATCH/OpenFOAM/<user>-<configured-version>
  --test-artifacts-dir <directory>
                              Test-artifact destination; defaults to
                              <work-root>/test-output
  --overwrite                 Remove and replace only the existing target case
  --help, -h                  Show this help message and exit

The target case is created as:
  <work-root>/run/$CASE_NAME

In SHPC mode, the module provides SINGULARITY_CONTAINER for provenance and the
<OPENFOAM_FORK>-exec wrapper used for generic commands inside its backing image.
USAGE
}

# --- Parse command-line arguments
while [[ $# -gt 0 ]]; do
   case "$1" in
      --image|-i)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --image requires <file>" >&2; usage >&2; exit 1; }
         imageInput="$2"
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
      --work-root|-w)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --work-root requires <directory>" >&2; usage >&2; exit 1; }
         workRootInput="$2"
         shift 2
         ;;
      --overwrite)
         overwriteCase=true
         shift
         ;;
      --config)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --config requires <file>" >&2; usage >&2; exit 1; }
         configFileInput="$2"; shift 2 ;;
      --test-artifacts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --test-artifacts-dir requires <directory>" >&2; usage >&2; exit 1; }
         testArtifactsDirInput="$2"; shift 2 ;;
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

# --- Validate common inputs and load version identity
# The configuration is the authoritative source of OpenFOAM fork and version in
# both runtime modes. The image filename is never used to derive that identity.
[[ -n "$configFileInput" ]] || {
   echo "ERROR: --config is required" >&2
   usage >&2
   exit 1
}
[[ -r "$configFileInput" ]] || {
   echo "ERROR: Configuration is not readable: $configFileInput" >&2
   usage >&2
   exit 1
}
configFile=$(realpath "$configFileInput")
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || {
      echo "ERROR: $requiredSetting is not defined in $configFile" >&2
      exit 1
   }
done

# Exactly one runtime selector is required.
runtimeSelectorCount=0
[[ -n "$imageInput" ]] && ((runtimeSelectorCount += 1))
[[ "$useSHPC" == true ]] && ((runtimeSelectorCount += 1))
[[ "$useBareMetal" == true ]] && ((runtimeSelectorCount += 1))
[[ $runtimeSelectorCount -eq 1 ]] || {
   echo "ERROR: Choose exactly one of --image <file>, --shpc, or --bare-metal" >&2
   usage >&2
   exit 1
}

if [[ -n "$imageInput" ]]; then
   [[ -f "$imageInput" ]] || {
      echo "ERROR: Singularity image not found: $imageInput" >&2
      exit 1
   }
   SINGULARITY_CONTAINER=$(realpath "$imageInput")

fi

if [[ -n "$workRootInput" ]]; then
   workRoot=$(realpath -m "$workRootInput")
else
   baseWorkDir=${MYSCRATCH:-${TMPDIR:-$HOME}}
   workRoot="${baseWorkDir}/OpenFOAM/${USER}-${OPENFOAM_VERSION}"
fi
hostRunDir="${workRoot}/run"

# --- Resolve the persistent test-artifact directory
# The launcher passes its timestamped invocation directory. When this stage is
# run independently, the default is the stable <work-root>/test-output path.
workOutputPath="${workRoot}/test-output"
if [[ -n "$testArtifactsDirInput" ]]; then
   outputDir=$(realpath -m "$testArtifactsDirInput")
   mkdir -p "$outputDir" || { echo "ERROR: Could not create test-artifact directory: $outputDir" >&2; exit 1; }
   mkdir -p "$workRoot"
   if [[ -e "$workOutputPath" && ! -L "$workOutputPath" ]]; then
      echo "ERROR: Refusing to replace non-symbolic-link output path: $workOutputPath" >&2
      echo "       Remove it deliberately or omit --test-artifacts-dir to use it directly." >&2
      exit 1
   fi
   ln -sfn "$outputDir" "$workOutputPath"
else
   outputDir="$workOutputPath"
   mkdir -p "$outputDir" || { echo "ERROR: Could not create default test-artifact directory: $outputDir" >&2; exit 1; }
fi
stageName="extractCase"
stageRunLog="${outputDir}/${stageName}.run.log"
stageStatusFile="${outputDir}/${stageName}.status.txt"
printf '%s\n' RUNNING > "$stageStatusFile"
record_stage_status() {
   local exitStatus=$?
   trap - EXIT
   if [[ $exitStatus -eq 0 ]]; then
      printf '%s\n' SUCCESS > "$stageStatusFile"
   else
      printf '%s\n' FAILED > "$stageStatusFile"
   fi
   exit "$exitStatus"
}
trap record_stage_status EXIT
exec > >(tee "$stageRunLog") 2>&1

echo "Test artifacts: $outputDir"
echo "Stage run log: $stageRunLog"
echo "Stage status: $stageStatusFile"
echo
testCase="${hostRunDir}/${CASE_NAME}"

# --- Container execution helper
# Select the execution interface for generic commands. SHPC mode uses its
# generic execution wrapper, bare-metal mode runs directly in the loaded host
# environment, and explicit-image mode uses singularity exec.
runInOpenFOAMRuntime() {
   if [[ "$useSHPC" == true ]]; then
      "$shpcExec" "$@"
   elif [[ "$useBareMetal" == true ]]; then
      "$@"
   else
      singularity exec "$SINGULARITY_CONTAINER" "$@"
   fi
}

# --- Step 1: Set up and validate the selected OpenFOAM runtime
echo "$thisScript: -----------------------------------------"
echo "Step 1 - Setting up the OpenFOAM container runtime"
if [[ "$useSHPC" == true ]]; then
   runtimeMode="SHPC module"
   shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
   shpcExec="${OPENFOAM_FORK}-exec"

   module load "$shpcModule" || {
      echo "ERROR: Failed to load SHPC module: $shpcModule" >&2
      exit 1
   }

   command -v "$shpcExec" >/dev/null 2>&1 || {
      echo "ERROR: SHPC execution wrapper is unavailable: $shpcExec" >&2
      exit 1
   }
   [[ -n "${SINGULARITY_CONTAINER:-}" ]] || {
      echo "ERROR: $shpcModule did not set SINGULARITY_CONTAINER" >&2
      exit 1
   }
   [[ -r "$SINGULARITY_CONTAINER" ]] || {
      echo "ERROR: SHPC backing image is not readable: $SINGULARITY_CONTAINER" >&2
      exit 1
   }
   SINGULARITY_CONTAINER=$(realpath "$SINGULARITY_CONTAINER")

   echo "SHPC module: $shpcModule"
   echo "SHPC execution wrapper: $shpcExec"
elif [[ "$useBareMetal" == true ]]; then
   runtimeMode="Bare-metal module"
   bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
   shpcModule=""
   shpcExec=""

   module load "$bareMetalModule" || {
      echo "ERROR: Failed to load bare-metal module: $bareMetalModule" >&2
      exit 1
   }
   [[ -n "${FOAM_TUTORIALS:-}" && -d "$FOAM_TUTORIALS" ]] || {
      echo "ERROR: FOAM_TUTORIALS is unavailable after loading $bareMetalModule" >&2
      exit 1
   }
   echo "Bare-metal module: $bareMetalModule"
else
   runtimeMode="Explicit Singularity image"
   bareMetalModule=""
   shpcModule=""
   shpcExec=""

   module load "$SINGULARITY_MODULE" || {
      echo "ERROR: Failed to load $SINGULARITY_MODULE" >&2
      exit 1
   }
   command -v singularity >/dev/null 2>&1 || {
      echo "ERROR: singularity is unavailable after loading $SINGULARITY_MODULE" >&2
      exit 1
   }

   echo "Singularity module: $SINGULARITY_MODULE"
fi

# Print the final module state once all modules required by the selected runtime
# have been loaded. In SHPC mode this also shows dependencies loaded by the
# OpenFOAM container module, including its Singularity runtime module.
echo "Loaded modules:"
module list

echo "Execution mode: $runtimeMode"
if [[ "$useBareMetal" != true ]]; then
   echo "Backing image: $SINGULARITY_CONTAINER"
fi

# Query the selected runtime instead of trusting either an image filename or a
# module name. The reported OpenFOAM version must match the configuration.
WM_PROJECT_VERSION=$(runInOpenFOAMRuntime \
   bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || {
      echo "ERROR: Failed to read WM_PROJECT_VERSION from the runtime environment" >&2
      exit 1
   }
[[ -n "$WM_PROJECT_VERSION" ]] || {
   echo "ERROR: WM_PROJECT_VERSION is empty in the runtime environment" >&2
   exit 1
}
[[ "$WM_PROJECT_VERSION" =~ ^v?[0-9][0-9A-Za-z.-]*$ ]] || {
   echo "ERROR: Invalid WM_PROJECT_VERSION='$WM_PROJECT_VERSION'" >&2
   exit 1
}
[[ "$WM_PROJECT_VERSION" == "$OPENFOAM_VERSION" ]] || {
   echo "ERROR: OpenFOAM version mismatch between the runtime and configuration" >&2
   echo "       Runtime environment: $WM_PROJECT_VERSION" >&2
   echo "       Configuration:       $OPENFOAM_VERSION" >&2
   exit 1
}
echo "PASS: Runtime WM_PROJECT_VERSION matches OPENFOAM_VERSION='$OPENFOAM_VERSION'"
echo "PASS: OpenFOAM container runtime ready"
echo

# --- Step 2: Prepare a clean host destination
# Do not overwrite an existing case. The launcher must use an isolated work root
# or remove a previous test run explicitly before starting this stage.
echo "$thisScript: -----------------------------------------"
echo "Step 2 - Preparing the host destination"
mkdir -p "$hostRunDir" || {
   echo "ERROR: Could not create host run directory: $hostRunDir" >&2
   exit 1
}

if [[ -e "$testCase" ]]; then
   if [[ "$overwriteCase" == "true" ]]; then
      echo "Removing existing target case: $testCase"
      rm -rf "$testCase" || {
         echo "ERROR: Failed to remove existing target case: $testCase" >&2
         exit 1
      }
   else
      echo "ERROR: Target case already exists: $testCase" >&2
      echo "       Use --overwrite to replace it, or select another --work-root." >&2
      exit 1
   fi
fi

echo "Host run directory: $hostRunDir"
echo "Target case: $testCase"
echo "PASS: Host destination ready"
echo

# --- Step 3: Locate the tutorial case inside the image
# Exactly one match is required. Multiple matches would make case selection
# ambiguous and could cause a different tutorial to be tested across versions.
echo "$thisScript: -----------------------------------------"
echo "Step 3 - Finding the '$CASE_NAME' tutorial inside the image"
internalCaseOutput=$(runInOpenFOAMRuntime \
   bash -c 'find "$FOAM_TUTORIALS" -type d -name "$1" -print' bash "$CASE_NAME") || {
      echo "ERROR: Failed to search FOAM_TUTORIALS inside the image" >&2
      exit 1
   }

internalCases=()
if [[ -n "$internalCaseOutput" ]]; then
   mapfile -t internalCases <<< "$internalCaseOutput"
fi

[[ ${#internalCases[@]} -eq 1 ]] || {
   echo "ERROR: Expected exactly one tutorial directory named '$CASE_NAME'; found ${#internalCases[@]}" >&2
   printf '  %s\n' "${internalCases[@]}" >&2
   exit 1
}
internalCase=${internalCases[0]}

echo "Tutorial source: $internalCase"
echo "PASS: Unique tutorial case found"
echo

# --- Step 4: Copy the tutorial case to the host
# Pawsey scratch filesystems are available in all three runtime modes. Use the
# common runtime helper without an additional bind: SHPC mode invokes
# <OPENFOAM_FORK>-exec, bare-metal mode runs cp directly, and explicit-image mode
# invokes singularity exec with the selected SIF.
echo "$thisScript: -----------------------------------------"
echo "Step 4 - Copying the tutorial case to the host"
runInOpenFOAMRuntime cp -a --no-preserve=timestamps "$internalCase" "$testCase" || {
   echo "ERROR: Failed to copy the tutorial case" >&2
   exit 1
}

echo "PASS: Tutorial case copied"
echo

# --- Step 5: Validate the extracted case
# These checks establish the minimum case structure required by preFoam.slurm.sh
# and runFoam.slurm.sh. Version-specific scripts may perform additional checks themselves.
echo "$thisScript: -----------------------------------------"
echo "Step 5 - Validating the extracted tutorial case"
[[ -d "$testCase" ]] || { echo "ERROR: Extracted case directory not found: $testCase" >&2; exit 1; }
[[ -d "${testCase}/system" ]] || { echo "ERROR: Missing directory: ${testCase}/system" >&2; exit 1; }
[[ -d "${testCase}/constant" ]] || { echo "ERROR: Missing directory: ${testCase}/constant" >&2; exit 1; }
[[ -d "${testCase}/0" || -d "${testCase}/0.orig" ]] || {
   echo "ERROR: Missing initial-condition directory: ${testCase}/0 or ${testCase}/0.orig" >&2
   exit 1
}
[[ -f "${testCase}/system/controlDict" ]] || {
   echo "ERROR: Missing dictionary: ${testCase}/system/controlDict" >&2
   exit 1
}
[[ -f "${testCase}/system/decomposeParDict" ]] || {
   echo "ERROR: Missing dictionary: ${testCase}/system/decomposeParDict" >&2
   exit 1
}

echo "Extracted case: $testCase"
echo "PASS: Extracted tutorial case is complete"
echo

# --- Final summary
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Tutorial case: $CASE_NAME"
echo "Execution mode: $runtimeMode"
if [[ "$useSHPC" == true ]]; then
   echo "SHPC module: $shpcModule"
   echo "SHPC execution wrapper: $shpcExec"
elif [[ "$useBareMetal" == true ]]; then
   echo "Bare-metal module: $bareMetalModule"
else
   echo "Backing image: $SINGULARITY_CONTAINER"
fi
echo "Extracted case: $testCase"
echo "ALL STEPS PASSED: OpenFOAM tutorial case extracted successfully."

# Return success to the caller.
exit 0
