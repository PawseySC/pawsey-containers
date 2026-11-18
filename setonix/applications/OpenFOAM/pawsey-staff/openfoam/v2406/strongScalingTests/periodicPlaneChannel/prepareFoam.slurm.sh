#!/bin/bash --login
# =============================================================================
# Generic five-stage launcher contract
# =============================================================================
# This case-owned stage is coordinated through case.conf. The generic launcher
# supplies this script's documented native arguments from a declarative argument
# template, while this script remains responsible for its OpenFOAM-specific work,
# validation, artifacts, status record, and failure handling. The shared scratch
# contract is source-case/<case>, base-case/<case>, and jobs/<topology>/<case>.
# =============================================================================
# Prepare and validate the shared periodicPlaneChannel case after mesh generation
# and before any topology-specific decomposition.
#
# This Slurm job is stage 3 of the mandatory five-stage strong-scaling workflow:
#
#   extractCase.sh -> meshFoam.slurm.sh -> prepareFoam.slurm.sh
#       -> decomposeFoam.slurm.sh -> runFoam.slurm.sh
#
# Design
# ------
# The upstream tutorial stores nonuniform initial fields for its original
# 60,000-cell mesh. This stage restores 0/ from 0.orig/, expands compressed
# fields, and replaces those mesh-specific lists with the same uniform values
# formerly applied by meshFoam.slurm.sh. It also configures one common OpenFOAM
# physical-time interval for every topology. Moving both operations here creates
# one prepared serial case that every scaling point copies.
#
# The stage does not generate or decompose a mesh and does not run pimpleFoam.
# It validates the effective inputs, writes a preparation handoff record, and
# archives the prepared configuration under the campaign artifacts. Numerical
# values and solver controls are preserved from the authoritative uploaded
# baseline; only their workflow ownership changes.
#
# Inputs:
#   - the meshed base case and mesh-info.env created by meshFoam.slurm.sh;
#   - the selected OpenFOAM runtime and version configuration;
#   - the common OpenFOAM start and end times for every topology.
#
# Outputs:
#   - prepared initial fields and controlDict in the shared base case;
#   - <work-root>/base-case/prepare-info.env for stage handoff;
#   - prepared-case-details/ plus checksums in the artifact directory;
#   - prepareFoam.status.txt and prepareFoam.run.log.
#
# Exit status:
#   0  The shared case was prepared, validated, and archived successfully.
#   1  Invalid input, runtime failure, preparation failure, or validation failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

#SBATCH --job-name=prepareFoam-strongScaling
#SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:20:00

# Preserve the established failure model: unset variables are errors, while
# consequential command failures are checked explicitly with contextual messages.
set -u

# =============================================================================
# 1. Version-specific preparation policy
# =============================================================================
# These values reproduce the effective initial fields and define the physical-time
# benchmark window shared by every periodicPlaneChannel topology.
CASE_NAME="periodicPlaneChannel"
SOLVER="pimpleFoam"
DEFAULT_START_TIME="0"
DEFAULT_END_TIME="10.2"

# =============================================================================
# 2. Initial settings and command-line interface
# =============================================================================
thisScript=$(basename "$0")
imageInput=""
useSHPC=false
useBareMetal=false
workRootInput=""
recipeDirInput=""
configFileInput=""
testArtifactsDirInput=""
startTimeInput="$DEFAULT_START_TIME"
endTimeInput="$DEFAULT_END_TIME"
singularityModule="singularity/4.3.5-mpi"
singularityModuleSpecified=false

usage() {
   cat <<USAGE
Usage:
  sbatch $thisScript --image <file> --config <file> [options]
  sbatch $thisScript --shpc --config <file> [options]
  sbatch $thisScript --bare-metal --config <file> [options]
  sbatch $thisScript --image <file> --recipe-dir <directory> [options]
  sbatch $thisScript --shpc --recipe-dir <directory> [options]
  sbatch $thisScript --bare-metal --recipe-dir <directory> [options]
  $thisScript --help

Runtime selection (choose exactly one):
  --image, -i <file>          Use the supplied Singularity image directly
  --singularity-module <module>
                              Singularity module for --image mode, or an override
                              applied after loading the SHPC OpenFOAM module.
                              Default for --image: $singularityModule
  --shpc                      Load <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>
  --bare-metal                Load <OPENFOAM_FORK>/<OPENFOAM_VERSION> and use the
                              OpenFOAM tools directly

Configuration selection (choose exactly one):
  --recipe-dir, -r <directory>  OpenFOAM version directory containing the
                                buildAndValidationConfig configuration file
  --config <file>             Version configuration file defining OPENFOAM_FORK
                              and OPENFOAM_VERSION

Preparation and path options:
  --start-time <time>         OpenFOAM startTime for every topology
                              (default: $DEFAULT_START_TIME)
  --end-time <time>           OpenFOAM endTime for every topology
                              (default: $DEFAULT_END_TIME)
  --work-root, -w <directory> Override the shared host work root
  --test-artifacts-dir <directory>
                              Campaign artifact destination; defaults to
                              <work-root>/test-output
  --help, -h                  Show this help message and exit

Expected meshed base case:
  <work-root>/base-case/$CASE_NAME
USAGE
}

# --- Parse options without mutating the case.
while [[ $# -gt 0 ]]; do
   case "$1" in
      --image|-i)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --image requires <file>" >&2; usage >&2; exit 1; }
         imageInput="$2"; shift 2 ;;
      --singularity-module)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --singularity-module requires <module>" >&2; usage >&2; exit 1; }
         singularityModule="$2"; singularityModuleSpecified=true; shift 2 ;;
      --shpc)
         useSHPC=true; shift ;;
      --bare-metal)
         useBareMetal=true; shift ;;
      --start-time)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --start-time requires <time>" >&2; usage >&2; exit 1; }
         startTimeInput="$2"; shift 2 ;;
      --end-time)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --end-time requires <time>" >&2; usage >&2; exit 1; }
         endTimeInput="$2"; shift 2 ;;
      --work-root|-w)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --work-root requires <directory>" >&2; usage >&2; exit 1; }
         workRootInput="$2"; shift 2 ;;
      --recipe-dir|-r)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --recipe-dir requires <directory>" >&2; usage >&2; exit 1; }
         recipeDirInput="$2"; shift 2 ;;
      --config)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --config requires <file>" >&2; usage >&2; exit 1; }
         configFileInput="$2"; shift 2 ;;
      --test-artifacts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --test-artifacts-dir requires <directory>" >&2; usage >&2; exit 1; }
         testArtifactsDirInput="$2"; shift 2 ;;
      -h|--help)
         usage; exit 0 ;;
      *)
         echo "ERROR: Unknown option '$1'" >&2
         usage >&2
         exit 1 ;;
   esac
done

# =============================================================================
# 3. Input validation and shared path resolution
# =============================================================================
# Validate the common physical-time interval before mutating the shared case.
awk -v a="$startTimeInput" -v b="$endTimeInput" 'BEGIN {
   numeric = "^[-+]?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$"
   exit !(a ~ numeric && b ~ numeric && b + 0 > a + 0)
}' || {
   echo "ERROR: --start-time and --end-time must be numeric with end greater than start" >&2
   exit 1
}

# Exactly one version-configuration source is required.
locationSelectorCount=0
[[ -n "$recipeDirInput" ]] && ((locationSelectorCount += 1))
[[ -n "$configFileInput" ]] && ((locationSelectorCount += 1))
[[ $locationSelectorCount -eq 1 ]] || {
   echo "ERROR: Choose exactly one of --recipe-dir <directory> or --config <file>" >&2
   usage >&2
   exit 1
}
if [[ -n "$recipeDirInput" ]]; then
   [[ -d "$recipeDirInput" ]] || { echo "ERROR: Recipe directory not found: $recipeDirInput" >&2; exit 1; }
   recipeDir=$(realpath "$recipeDirInput")
   configFileInput="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
fi
[[ -r "$configFileInput" ]] || { echo "ERROR: Configuration is not readable: $configFileInput" >&2; exit 1; }
configFile=$(realpath "$configFileInput")
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || { echo "ERROR: $requiredSetting is not defined in $configFile" >&2; exit 1; }
done

# Exactly one runtime mode is required, matching every other case stage.
runtimeSelectorCount=0
[[ -n "$imageInput" ]] && ((runtimeSelectorCount += 1))
[[ "$useSHPC" == true ]] && ((runtimeSelectorCount += 1))
[[ "$useBareMetal" == true ]] && ((runtimeSelectorCount += 1))
[[ $runtimeSelectorCount -eq 1 ]] || {
   echo "ERROR: Choose exactly one of --image <file>, --shpc, or --bare-metal" >&2
   usage >&2
   exit 1
}
if [[ "$singularityModuleSpecified" == true && "$useBareMetal" == true ]]; then
   echo "ERROR: --singularity-module cannot be used with --bare-metal" >&2
   exit 1
fi
if [[ -n "$imageInput" ]]; then
   [[ -f "$imageInput" ]] || { echo "ERROR: Singularity image not found: $imageInput" >&2; exit 1; }
   SINGULARITY_IMAGE=$(realpath "$imageInput")
fi

if [[ -n "$workRootInput" ]]; then
   workRoot=$(realpath -m "$workRootInput")
else
   baseWorkDir=${MYSCRATCH:-${TMPDIR:-$HOME}}
   workRoot="${baseWorkDir}/OpenFOAM-strong-scaling/${USER}-${OPENFOAM_VERSION}"
fi
BASE_CASE_DIR="${workRoot}/base-case/${CASE_NAME}"
MESH_INFO_FILE="${workRoot}/base-case/mesh-info.env"
PREPARE_INFO_FILE="${workRoot}/base-case/prepare-info.env"

# =============================================================================
# 4. Persistent artifacts and reliable stage status
# =============================================================================
workOutputPath="${workRoot}/test-output"
if [[ -n "$testArtifactsDirInput" ]]; then
   outputDir=$(realpath -m "$testArtifactsDirInput")
   mkdir -p "$outputDir" || { echo "ERROR: Could not create test-artifact directory: $outputDir" >&2; exit 1; }
   mkdir -p "$workRoot"
   if [[ -e "$workOutputPath" && ! -L "$workOutputPath" ]]; then
      echo "ERROR: Refusing to replace non-symbolic-link output path: $workOutputPath" >&2
      exit 1
   fi
   ln -sfn "$outputDir" "$workOutputPath"
else
   outputDir="$workOutputPath"
   mkdir -p "$outputDir" || { echo "ERROR: Could not create default test-artifact directory: $outputDir" >&2; exit 1; }
fi

stageName="prepareFoam"
stageRunLog="${outputDir}/${stageName}.run.log"
stageStatusFile="${outputDir}/${stageName}.status.txt"
printf '%s\n' RUNNING > "$stageStatusFile"
record_stage_status() {
   local exitStatus=$?
   local result=FAILED
   trap - EXIT
   [[ $exitStatus -eq 0 ]] && result=SUCCESS
   printf '%s\n' "$result" > "$stageStatusFile"
   exit "$exitStatus"
}
trap record_stage_status EXIT
exec > >(tee "$stageRunLog") 2>&1

# =============================================================================
# 5. OpenFOAM runtime setup
# =============================================================================
# SHPC and bare-metal modes use their installed wrappers/tools directly. Explicit
# image mode prefixes each OpenFOAM command with singularity exec.
if [[ "$useSHPC" == true ]]; then
   runtimeMode="SHPC module"
   shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
   shpcExec="${OPENFOAM_FORK}-exec"
   openfoamCommandPrefix=()
   module load "$shpcModule" || { echo "ERROR: Failed to load SHPC module: $shpcModule" >&2; exit 1; }
   command -v "$shpcExec" >/dev/null 2>&1 || { echo "ERROR: SHPC execution wrapper is unavailable: $shpcExec" >&2; exit 1; }
   for openfoamTool in foamDictionary "$SOLVER"; do
      command -v "$openfoamTool" >/dev/null 2>&1 || { echo "ERROR: OpenFOAM wrapper is unavailable: $openfoamTool" >&2; exit 1; }
   done
   [[ -n "${SINGULARITY_CONTAINER:-}" && -r "$SINGULARITY_CONTAINER" ]] || {
      echo "ERROR: Invalid SHPC backing image" >&2
      exit 1
   }
   SINGULARITY_IMAGE=$(realpath "$SINGULARITY_CONTAINER")
   if [[ "$singularityModuleSpecified" == true ]]; then
      module load "$singularityModule" || { echo "ERROR: Failed to switch to Singularity module: $singularityModule" >&2; exit 1; }
   fi
   WM_PROJECT_VERSION=$("$shpcExec" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || {
      echo "ERROR: Failed to query WM_PROJECT_VERSION through $shpcExec" >&2
      exit 1
   }
elif [[ "$useBareMetal" == true ]]; then
   runtimeMode="Bare-metal module"
   bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
   openfoamCommandPrefix=()
   module load "$bareMetalModule" || { echo "ERROR: Failed to load bare-metal module: $bareMetalModule" >&2; exit 1; }
   for openfoamTool in foamDictionary "$SOLVER"; do
      command -v "$openfoamTool" >/dev/null 2>&1 || { echo "ERROR: OpenFOAM tool is unavailable: $openfoamTool" >&2; exit 1; }
   done
   WM_PROJECT_VERSION=${WM_PROJECT_VERSION:-}
else
   runtimeMode="Explicit Singularity image"
   openfoamCommandPrefix=(singularity exec "$SINGULARITY_IMAGE")
   module load "$singularityModule" || { echo "ERROR: Failed to load $singularityModule" >&2; exit 1; }
   command -v singularity >/dev/null 2>&1 || { echo "ERROR: singularity is unavailable" >&2; exit 1; }
   WM_PROJECT_VERSION=$(singularity exec "$SINGULARITY_IMAGE" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || {
      echo "ERROR: Failed to query WM_PROJECT_VERSION from the image" >&2
      exit 1
   }
fi
[[ "$WM_PROJECT_VERSION" == "$OPENFOAM_VERSION" ]] || {
   echo "ERROR: Runtime version '$WM_PROJECT_VERSION' does not match configured '$OPENFOAM_VERSION'" >&2
   exit 1
}

echo "Loaded modules:"
module list
echo "Execution mode: $runtimeMode"
echo "PASS: Runtime WM_PROJECT_VERSION matches OPENFOAM_VERSION='$OPENFOAM_VERSION'"
echo

# =============================================================================
# 6. Meshed base-case and handoff validation
# =============================================================================
# Preparation must never run against an unmeshed or mismatched case.
[[ -d "$BASE_CASE_DIR" ]] || { echo "ERROR: Meshed base case not found: $BASE_CASE_DIR" >&2; exit 1; }
[[ -r "$MESH_INFO_FILE" ]] || { echo "ERROR: Mesh metadata not found: $MESH_INFO_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$MESH_INFO_FILE"
[[ "${CASE_NAME:-}" == periodicPlaneChannel ]] || { echo "ERROR: mesh-info.env identifies an unexpected case" >&2; exit 1; }
[[ "${ACTUAL_CELLS:-}" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: mesh-info.env has invalid ACTUAL_CELLS" >&2; exit 1; }
[[ -d "${BASE_CASE_DIR}/constant/polyMesh" ]] || { echo "ERROR: Meshed case has no constant/polyMesh" >&2; exit 1; }
[[ -d "${BASE_CASE_DIR}/0.orig" ]] || { echo "ERROR: Meshed case has no 0.orig directory" >&2; exit 1; }
for requiredDictionary in controlDict decomposeParDict fvSchemes fvSolution; do
   [[ -f "${BASE_CASE_DIR}/system/${requiredDictionary}" ]] || {
      echo "ERROR: Missing dictionary: ${BASE_CASE_DIR}/system/${requiredDictionary}" >&2
      exit 1
   }
done

# =============================================================================
# 7. Mesh-independent initial fields
# =============================================================================
# Restore the authoritative tutorial initial state, then convert the four
# original 60,000-element lists into the same uniform values used previously.
cd "$BASE_CASE_DIR" || { echo "ERROR: Could not enter base case directory: $BASE_CASE_DIR" >&2; exit 1; }
rm -rf 0
cp -a 0.orig 0 || { echo "ERROR: Failed to restore 0 from 0.orig" >&2; exit 1; }

shopt -s nullglob
for gzFile in 0/*.gz; do
   gunzip -f "$gzFile" || { echo "ERROR: Failed to gunzip $gzFile" >&2; exit 1; }
done
shopt -u nullglob

setDictionaryEntry() {
   local dictionary=$1
   local entry=$2
   local value=$3

   srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
      foamDictionary "$dictionary" -entry "$entry" -set "$value" || {
         echo "ERROR: Failed to set $entry in $dictionary" >&2
         exit 1
      }
}

setDictionaryEntry 0/U internalField "uniform (0.1335 0 0)"
setDictionaryEntry 0/p internalField "uniform 0"
setDictionaryEntry 0/k internalField "uniform 5e-04"
setDictionaryEntry 0/nut internalField "uniform 5e-05"
echo "PASS: Initial fields configured with mesh-independent uniform values"
echo

# =============================================================================
# 8. Common physical-time solver controls and flow-only cleanup
# =============================================================================
# Configure the serial source once so every topology advances through the same
# OpenFOAM-time interval. Slurm walltime remains only a scheduler safety limit.
setDictionaryEntry system/controlDict startFrom startTime
setDictionaryEntry system/controlDict startTime "$startTimeInput"
setDictionaryEntry system/controlDict stopAt endTime
setDictionaryEntry system/controlDict endTime "$endTimeInput"
setDictionaryEntry system/controlDict writeControl adjustableRunTime
writeInterval=$(awk -v a="$startTimeInput" -v b="$endTimeInput" 'BEGIN { printf "%.15g", b - a }')
setDictionaryEntry system/controlDict writeInterval "$writeInterval"
setDictionaryEntry system/controlDict runTimeModifiable false

# Remove all function-object execution from the benchmark. meanVelocityForce in
# fvOptions is intentionally retained because it is part of the channel-flow
# solution rather than postprocessing or statistical averaging.
if "${openfoamCommandPrefix[@]}" foamDictionary system/controlDict -entry functions -value >/dev/null 2>&1; then
   "${openfoamCommandPrefix[@]}" foamDictionary system/controlDict -entry functions -remove || {
      echo "ERROR: Failed to remove functions from system/controlDict" >&2
      exit 1
   }
fi
rm -f system/postChannelDict system/controlDict.bak
rm -rf postProcessing

# Remove inherited averaging products and function-object state from both source
# field directories while preserving the primary flow fields U, p, k, and nut.
find 0 0.orig -maxdepth 1 -type f    \( -name '*Mean' -o -name '*Prime2Mean' -o -name '*Average*' \)    -delete 2>/dev/null || true
find 0 0.orig -maxdepth 1 -type d -name 'uniform' -exec rm -rf {} + 2>/dev/null || true

echo "PASS: controlDict configured for OpenFOAM time ($startTimeInput, $endTimeInput]"
echo "PASS: Function objects and inherited averaging artifacts removed"
echo

# =============================================================================
# 9. Effective-input validation
# =============================================================================
# Read values through foamDictionary so formatting and comments cannot fool the
# checks. This validates ownership transfer without changing numerical settings.
dictionaryValue() {
   "${openfoamCommandPrefix[@]}" foamDictionary "$1" -entry "$2" -value \
      | tr -d ';' | xargs
}

application=$(dictionaryValue system/controlDict application)
startFrom=$(dictionaryValue system/controlDict startFrom)
startTime=$(dictionaryValue system/controlDict startTime)
stopAt=$(dictionaryValue system/controlDict stopAt)
endTime=$(dictionaryValue system/controlDict endTime)
writeControl=$(dictionaryValue system/controlDict writeControl)
effectiveWriteInterval=$(dictionaryValue system/controlDict writeInterval)
runTimeModifiable=$(dictionaryValue system/controlDict runTimeModifiable)

[[ "$application" == "$SOLVER" ]] || { echo "ERROR: Expected application=$SOLVER, found '$application'" >&2; exit 1; }
[[ "$startFrom" == startTime ]] || { echo "ERROR: Expected startFrom=startTime, found '$startFrom'" >&2; exit 1; }
[[ "$startTime" == "$startTimeInput" ]] || { echo "ERROR: Expected startTime=$startTimeInput, found '$startTime'" >&2; exit 1; }
[[ "$stopAt" == endTime ]] || { echo "ERROR: Expected stopAt=endTime, found '$stopAt'" >&2; exit 1; }
[[ "$endTime" == "$endTimeInput" ]] || { echo "ERROR: Expected endTime=$endTimeInput, found '$endTime'" >&2; exit 1; }
[[ "$writeControl" == adjustableRunTime ]] || { echo "ERROR: Expected writeControl=adjustableRunTime, found '$writeControl'" >&2; exit 1; }
[[ "$effectiveWriteInterval" == "$writeInterval" ]] || { echo "ERROR: Expected writeInterval=$writeInterval, found '$effectiveWriteInterval'" >&2; exit 1; }
if "${openfoamCommandPrefix[@]}" foamDictionary system/controlDict -entry functions -value >/dev/null 2>&1; then
   echo "ERROR: controlDict still contains function objects" >&2
   exit 1
fi
[[ ! -e system/postChannelDict ]] || { echo "ERROR: system/postChannelDict was not removed" >&2; exit 1; }
case "${runTimeModifiable,,}" in
   false|no|off|0) ;;
   *) echo "ERROR: Expected runTimeModifiable to be disabled, found '$runTimeModifiable'" >&2; exit 1 ;;
esac
for field in U p k nut; do
   [[ -s "0/$field" ]] || { echo "ERROR: Prepared field is missing or empty: 0/$field" >&2; exit 1; }
done

# =============================================================================
# 10. Reproducible prepared-input snapshot
# =============================================================================
# Persist numerical inputs without copying constant/polyMesh. This keeps the
# campaign artifacts self-contained for later solver-setting comparisons while
# avoiding a second copy of the large mesh.
snapshot="${outputDir}/prepared-case-details"
rm -rf "$snapshot"
mkdir -p "$snapshot/0" "$snapshot/constant"
cp -a system "$snapshot/system"
find 0 -maxdepth 1 -type f -exec cp -a {} "$snapshot/0/" \;
find constant -maxdepth 1 -type f -exec cp -a {} "$snapshot/constant/" \;
(
   cd "$snapshot" || exit 1
   find 0 constant system -type f -print0 \
      | sort -z \
      | xargs -0 sha256sum > checksums.sha256
) || { echo "ERROR: Failed to create prepared-case checksums" >&2; exit 1; }

# =============================================================================
# 11. Stage handoff metadata and final summary
# =============================================================================
# Write the handoff atomically so decomposition never accepts a partial record.
prepareInfoTemporary="${PREPARE_INFO_FILE}.tmp.$$"
{
   printf 'CASE_NAME=%q\n' "$CASE_NAME"
   printf 'PREPARED_CASE=%q\n' "$BASE_CASE_DIR"
   printf 'SOLVER=%q\n' "$SOLVER"
   printf 'START_TIME=%q\n' "$startTimeInput"
   printf 'END_TIME=%q\n' "$endTimeInput"
   printf 'ACTUAL_CELLS=%q\n' "$ACTUAL_CELLS"
   printf 'OPENFOAM_FORK=%q\n' "$OPENFOAM_FORK"
   printf 'OPENFOAM_VERSION=%q\n' "$OPENFOAM_VERSION"
} > "$prepareInfoTemporary" || { echo "ERROR: Failed to write preparation metadata" >&2; exit 1; }
mv -f "$prepareInfoTemporary" "$PREPARE_INFO_FILE"
cp -f "$PREPARE_INFO_FILE" "${outputDir}/prepare-info.env"

echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Prepared case        : $BASE_CASE_DIR"
echo "Mesh cells           : $ACTUAL_CELLS"
echo "Solver               : $SOLVER"
echo "OpenFOAM-time range  : ($startTimeInput, $endTimeInput]"
echo "Preparation metadata : $PREPARE_INFO_FILE"
echo "Input snapshot       : $snapshot"
echo "ALL STEPS PASSED: Shared periodicPlaneChannel case prepared and validated."
exit 0
