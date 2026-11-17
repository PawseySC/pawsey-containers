#!/bin/bash --login
# =============================================================================
# OpenFOAM strong-scaling launcher: one mandatory five-stage workflow
# =============================================================================
# Design
# ------
# Each case must supply all five scripts under:
#   <recipe-dir>/strongScalingTests/<case>/
#
#   extractCase.sh -> meshFoam.slurm.sh -> prepareFoam.slurm.sh
#       -> decomposeFoam.slurm.sh -> runFoam.slurm.sh
#
# Extraction runs directly. Mesh and preparation run once per campaign. Each
# topology then receives its own decomposition and solver jobs. Dependencies are
# always mesh -> prepare -> decompose -> run; preparation is never optional.
# Missing scripts stop validation before extraction or Slurm submission.
# An explicit --resume-from-mesh reuses completed extraction/mesh stages after
# validating their evidence, then copies the serial case into a new campaign.
# Preparation remains mandatory and the source case is never modified.
#
# The launcher owns paths, resource requests, dependencies and status reporting.
# Case scripts own mesh construction, numerical settings and solver execution.
# This revision uses the --foam-module interface of the delivered cavity3D
# scripts. Image-mode arguments remain recognized but are rejected explicitly:
# those case scripts do not implement direct-image execution.
#
# Persistent evidence lives under:
#   <recipe-dir>/artifacts/tests/strong-scaling/<case>/<campaign>/
# Scratch working cases are separate. Raw logs remain the analysis authority.
# Postprocessing runs only when BOTH physical-time endpoints are supplied; no
# interval from another case is silently applied to a 15-step cavity benchmark.
#
# Based on the user's .100 launcher: retain its editable scalingJobsTable,
# recipe/config selection, runtime validation, clean Slurm submission environment,
# campaign namespace, submit-only mode and queue reporting.
# =============================================================================

set -u

# =============================================================================
# 1. Campaign defaults and editable scaling topology
# =============================================================================
DEFAULT_CELLS_MILLIONS="64"
DEFAULT_MESH_WALLTIME="01:00:00"
DEFAULT_PREPARE_WALLTIME="00:20:00"

# Each entry defines one strong-scaling job:
#   "NODES  TASKS_PER_NODE  DECOMPOSE_WALLTIME  RUN_WALLTIME"
scalingJobsTable=(
#   "1  16   02:00:00  00:20:00"
#   "1  32   02:00:00  00:20:00"
#   "1  64   02:00:00  00:20:00"
   "1  128  02:00:00  00:30:00"
#   "2  128  02:00:00  00:20:00"
#   "4  128  02:00:00  00:20:00"
   "8  128  02:00:00  00:20:00"
#   "16  128  02:00:00  00:20:00"
)

# =============================================================================
# 2. Repository location
# =============================================================================
# Resolve paths independently of the current working directory.
findPawseyStaffRoot() {
   local dir=$1
   while [[ -n "$dir" && "$dir" != "/" ]]; do
      if [[ "$(basename "$dir")" == "pawsey-staff" ]] || \
         [[ -d "${dir}/buildingScripts" && -d "${dir}/openfoam" ]]; then
         printf '%s\n' "$dir"
         return 0
      fi
      dir=$(dirname "$dir")
   done
   local gitRoot
   if gitRoot=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null); then
      if [[ -d "${gitRoot}/setonix/applications/OpenFOAM/pawsey-staff" ]]; then
         printf '%s\n' "${gitRoot}/setonix/applications/OpenFOAM/pawsey-staff"
         return 0
      fi
   fi
   return 1
}

# =============================================================================
# 3. Launcher state
# =============================================================================
# Keep command-line inputs separate from resolved campaign paths.
thisScript=$(basename "$0")
scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pawseyStaffRoot=$(findPawseyStaffRoot "$scriptDir" || printf '%s' "$PWD")
postProcessScript="${scriptDir}/openfoamStrongScalingPostProcess.py"
recipeDirInput=""
scalingCase=""
configFileInput=""
scriptsDirInput=""
imageInput=""
singularityModule="singularity/4.3.5-mpi"
singularityModuleSpecified=false
useSHPC=false
useBareMetal=false
workRootInput=""
cellsMillions="$DEFAULT_CELLS_MILLIONS"
statsStartTime=""
statsEndTime=""
meshWalltime="$DEFAULT_MESH_WALLTIME"
prepareWalltime="$DEFAULT_PREPARE_WALLTIME"
benchmarkSourceInput=""
dryRun=false
resumeMeshInput=""
meshArtifactsInput=""
runWalltimeOverride=""
partitionInput="${PARTITION:-}"
reservationInput="${RESERVATION:-}"
pollInterval=${POLL_INTERVAL_SECONDS:-20}
submitOnly=false

# =============================================================================
# 4. Command-line documentation
# =============================================================================
# Describe the public interface used for repeatable campaign submission.

usage() {
   cat <<USAGE
Usage:
  $thisScript --recipe-dir <directory> --case <name> --image <file> [options]
  $thisScript --recipe-dir <directory> --case <name> --shpc [options]
  $thisScript --recipe-dir <directory> --case <name> --bare-metal [options]
  $thisScript --config <file> --scripts-dir <directory> --image <file> [options]
  $thisScript --config <file> --scripts-dir <directory> --shpc [options]
  $thisScript --config <file> --scripts-dir <directory> --bare-metal [options]
  $thisScript --help

Test-location selection (choose one complete mode):
  --recipe-dir, -r <directory>  OpenFOAM version directory containing
                                buildAndValidationConfig/ and strongScalingTests/<case>/
  --case <name>                 Strong-scaling case directory under strongScalingTests/
  --config <file>               Explicit version configuration file; requires
                                --scripts-dir and cannot be used with --recipe-dir
  --scripts-dir <directory>     Directory containing extractCase.sh,
                                meshFoam.slurm.sh, prepareFoam.slurm.sh,
                                decomposeFoam.slurm.sh, and
                                runFoam.slurm.sh

Runtime selection (choose exactly one):
  --image, -i <file>            Recognized but unsupported by the supplied case stages
  --singularity-module <module> Recognized but unsupported by the supplied case stages
  --shpc                        Use <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>
  --bare-metal                  Use <OPENFOAM_FORK>/<OPENFOAM_VERSION>

Strong-scaling benchmark options:
  --cells-millions <number>     Target total mesh cells in millions
                                (default: $DEFAULT_CELLS_MILLIONS)
  --stats-start-time <time>     Post-processing reference (requires --stats-end-time)
  --stats-end-time <time>       Final included time (requires --stats-start-time)
  --prepare-walltime <HH:MM:SS> Shared preparation walltime (default: $DEFAULT_PREPARE_WALLTIME)
  --resume-from-mesh <dir>      Reuse an existing successful serial meshed case
  --mesh-artifacts-dir <dir>    Source campaign with mesh-info.env and PASS status;
                                required with --resume-from-mesh
  --benchmark-source <dir>      Local authoritative cavity3D benchmark source
  --dry-run                     Validate and report without creating a campaign
  --mesh-walltime <HH:MM:SS>    Slurm walltime limit for meshFoam.slurm.sh
                                (default: $DEFAULT_MESH_WALLTIME)
  --run-walltime <HH:MM:SS>     Override the table's RUN_WALLTIME column for
                                all solver jobs

Optional settings:
  --work-root, -w <directory>   Host work root shared by all stages
  --partition, -p <name>        Override the partition in all Slurm jobs
  --reservation <name>          Submit all Slurm jobs using this reservation
  --submit-only                 Submit all jobs and return without waiting
  --help, -h                    Show this help message and exit
USAGE
}

# =============================================================================
# 5. Command-line parsing
# =============================================================================
# Read selectors and overrides without performing work.
while [[ $# -gt 0 ]]; do
   case "$1" in
      --recipe-dir|-r)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --recipe-dir requires <directory>" >&2; usage >&2; exit 1; }
         recipeDirInput="$2"; shift 2 ;;
      --case)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --case requires <name>" >&2; usage >&2; exit 1; }
         scalingCase="$2"; shift 2 ;;
      --config)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --config requires <file>" >&2; usage >&2; exit 1; }
         configFileInput="$2"; shift 2 ;;
      --scripts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --scripts-dir requires <directory>" >&2; usage >&2; exit 1; }
         scriptsDirInput="$2"; shift 2 ;;
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
      --cells-millions)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --cells-millions requires <number>" >&2; usage >&2; exit 1; }
         cellsMillions="$2"; shift 2 ;;
      --stats-start-time)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --stats-start-time requires <time>" >&2; usage >&2; exit 1; }
         statsStartTime="$2"; shift 2 ;;
      --stats-end-time)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --stats-end-time requires <time>" >&2; usage >&2; exit 1; }
         statsEndTime="$2"; shift 2 ;;
      --prepare-walltime)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --prepare-walltime requires a value" >&2; exit 1; }
         prepareWalltime="$2"; shift 2 ;;
      --resume-from-mesh)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --resume-from-mesh requires a directory" >&2; exit 1; }
         resumeMeshInput=$2
         shift 2
         ;;
      --mesh-artifacts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --mesh-artifacts-dir requires a directory" >&2; exit 1; }
         meshArtifactsInput=$2
         shift 2
         ;;
      --benchmark-source)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --benchmark-source requires a directory" >&2; exit 1; }
         benchmarkSourceInput="$2"; shift 2 ;;
      --dry-run)
         dryRun=true; shift ;;
      --mesh-walltime)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --mesh-walltime requires <HH:MM:SS>" >&2; usage >&2; exit 1; }
         meshWalltime="$2"; shift 2 ;;
      --run-walltime)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --run-walltime requires <HH:MM:SS>" >&2; usage >&2; exit 1; }
         runWalltimeOverride="$2"; shift 2 ;;
      --work-root|-w)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --work-root requires <directory>" >&2; usage >&2; exit 1; }
         workRootInput="$2"; shift 2 ;;
      --partition|-p)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --partition requires <name>" >&2; usage >&2; exit 1; }
         partitionInput="$2"; shift 2 ;;
      --reservation)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --reservation requires <name>" >&2; usage >&2; exit 1; }
         reservationInput="$2"; shift 2 ;;
      --submit-only)
         submitOnly=true; shift ;;
      -h|--help)
         usage; exit 0 ;;
      *)
         echo "ERROR: Unknown option '$1'" >&2; usage >&2; exit 1 ;;
   esac
done

awk -v m="$cellsMillions" 'BEGIN { exit (m ~ /^[0-9]+([.][0-9]+)?$/ && m + 0 > 0 ? 0 : 1) }' || {
   echo "ERROR: --cells-millions must be a positive number; got '$cellsMillions'" >&2
   exit 1
}
# An analysis interval is explicit and independent of the solver's end time.
if [[ -n "$statsStartTime" || -n "$statsEndTime" ]]; then
   awk -v a="$statsStartTime" -v b="$statsEndTime" 'BEGIN { exit !(a ~ /^[0-9]+([.][0-9]+)?$/ && b ~ /^[0-9]+([.][0-9]+)?$/ && b+0>a+0) }' || {
      echo "ERROR: Supply both numeric statistics endpoints with end greater than start" >&2
      exit 1
   }
fi

# =============================================================================
# 6. Version and configuration resolution
# =============================================================================
# Resolve one recipe and load its OpenFOAM identity.
if [[ -n "$recipeDirInput" ]]; then
   [[ -z "$configFileInput" && -z "$scriptsDirInput" ]] || {
      echo "ERROR: --recipe-dir cannot be used with --config or --scripts-dir" >&2
      usage >&2
      exit 1
   }
   if [[ ! -d "$recipeDirInput" && -d "${pawseyStaffRoot}/${recipeDirInput}" ]]; then
      recipeDirInput="${pawseyStaffRoot}/${recipeDirInput}"
   fi
   [[ -d "$recipeDirInput" ]] || { echo "ERROR: Recipe directory not found: $recipeDirInput" >&2; exit 1; }
   recipeDir=$(realpath "$recipeDirInput")
   [[ -n "$scalingCase" ]] || { echo "ERROR: --case <name> is required with --recipe-dir" >&2; exit 1; }
   [[ "$scalingCase" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "ERROR: Invalid --case name: $scalingCase" >&2; exit 1; }
   configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
   scalingScriptDir="${recipeDir}/strongScalingTests/${scalingCase}"
elif [[ -n "$configFileInput" || -n "$scriptsDirInput" ]]; then
   [[ -n "$configFileInput" && -n "$scriptsDirInput" ]] || {
      echo "ERROR: --config and --scripts-dir must be provided together" >&2
      usage >&2
      exit 1
   }
   [[ -r "$configFileInput" ]] || { echo "ERROR: Configuration is not readable: $configFileInput" >&2; exit 1; }
   [[ -d "$scriptsDirInput" ]] || { echo "ERROR: Scripts directory not found: $scriptsDirInput" >&2; exit 1; }
   configFile=$(realpath "$configFileInput")
   scalingScriptDir=$(realpath "$scriptsDirInput")
   recipeDir=$(dirname "$(dirname "$configFile")")
   detectedCase=$(basename "$scalingScriptDir")
   if [[ -n "$scalingCase" && "$scalingCase" != "$detectedCase" ]]; then
      echo "ERROR: --case '$scalingCase' does not match scripts directory case '$detectedCase'" >&2
      exit 1
   fi
   scalingCase=$detectedCase
   [[ "$(basename "$(dirname "$scalingScriptDir")")" == "strongScalingTests" ]] || {
      echo "ERROR: Scripts directory must be strongScalingTests/<case>: $scalingScriptDir" >&2
      exit 1
   }
else
   echo "ERROR: Provide --recipe-dir, or provide --config and --scripts-dir together" >&2
   usage >&2
   exit 1
fi
[[ -r "$configFile" ]] || { echo "ERROR: Configuration is not readable: $configFile" >&2; exit 1; }
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || { echo "ERROR: $requiredSetting is not defined in $configFile" >&2; exit 1; }
done

# =============================================================================
# 7. Runtime selection
# =============================================================================
# Resolve the configured SHPC or bare-metal module consistently for every stage.

runtimeSelectorCount=0
[[ -n "$imageInput" ]] && ((runtimeSelectorCount += 1))
[[ "$useSHPC" == true ]] && ((runtimeSelectorCount += 1))
[[ "$useBareMetal" == true ]] && ((runtimeSelectorCount += 1))
[[ $runtimeSelectorCount -eq 1 ]] || { echo "ERROR: Choose exactly one of --image <file>, --shpc, or --bare-metal" >&2; exit 1; }

if [[ "$singularityModuleSpecified" == true && "$useBareMetal" == true ]]; then
   echo "ERROR: --singularity-module cannot be used with --bare-metal" >&2
   exit 1
fi

SINGULARITY_IMAGE=""
imageChecksum=""
shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
if [[ -n "$imageInput" ]]; then
   [[ -f "$imageInput" ]] || { echo "ERROR: Image not found: $imageInput" >&2; exit 1; }
   SINGULARITY_IMAGE=$(realpath "$imageInput")
   imageChecksum=$(sha256sum "$SINGULARITY_IMAGE" | awk '{print $1}')
   runtimeMode="Explicit Singularity image"
   runtimeOption=(--image "$SINGULARITY_IMAGE" --singularity-module "$singularityModule")
   artifactRuntimeName="singularity"
elif [[ "$useSHPC" == true ]]; then
   runtimeMode="SHPC module"
   runtimeOption=(--shpc)
   if [[ "$singularityModuleSpecified" == true ]]; then
      runtimeOption+=(--singularity-module "$singularityModule")
   fi
   artifactRuntimeName="shpc"
else
   runtimeMode="Bare-metal module"
   runtimeOption=(--bare-metal)
   artifactRuntimeName="bare-metal"
fi

# =============================================================================
# 8. Mandatory stage validation
# =============================================================================
# All five scripts are required before extraction or submission.
extractScript="${scalingScriptDir}/extractCase.sh"
meshScript="${scalingScriptDir}/meshFoam.slurm.sh"
prepareScript="${scalingScriptDir}/prepareFoam.slurm.sh"
decomposeScript="${scalingScriptDir}/decomposeFoam.slurm.sh"
runScript="${scalingScriptDir}/runFoam.slurm.sh"

for requiredScript in "$extractScript" "$meshScript" "$prepareScript" "$decomposeScript" "$runScript"; do
   [[ -r "$requiredScript" ]] || { echo "ERROR: Required strong-scaling script not found: $requiredScript" >&2; exit 1; }
   bash -n "$requiredScript" || { echo "ERROR: Bash syntax check failed: $requiredScript" >&2; exit 1; }
done
[[ -x "$extractScript" ]] || { echo "ERROR: Extraction script is not executable: $extractScript" >&2; exit 1; }
# All stages use the same module-based interface. Reject unsupported requests
# rather than forwarding flags that the delivered stage scripts cannot accept.
if [[ -n "$imageInput" || "$singularityModuleSpecified" == true ]]; then
   echo "ERROR: These five-stage scripts accept --foam-module, not direct images or Singularity overrides" >&2
   exit 1
fi
caseFoamModule=$shpcModule
[[ "$useBareMetal" == false ]] || caseFoamModule=$bareMetalModule
if [[ -n "$benchmarkSourceInput" ]]; then
   [[ -d "$benchmarkSourceInput" ]] || { echo "ERROR: Benchmark source not found" >&2; exit 1; }
   benchmarkSourceInput=$(realpath "$benchmarkSourceInput")
fi
# The supplied cavity3D stages currently implement exactly 64M/fixedIter.
if [[ "$scalingCase" == cavity3D && "$cellsMillions" != 64 ]]; then
   echo "ERROR: The supplied cavity3D stages support --cells-millions 64" >&2
   exit 1
fi
targetCells=$(awk -v m="$cellsMillions" 'BEGIN { printf "%.0f",m*1000000 }')
actualCells=$targetCells

# Validate every table row before any filesystem or scheduler mutation.
for row in "${scalingJobsTable[@]}"; do
   read -r n t dw rw extra <<< "$row"
   [[ "$n" =~ ^[1-9][0-9]*$ && "$t" =~ ^[1-9][0-9]*$ && -z "$extra" ]] || {
      echo "ERROR: Invalid scalingJobsTable row: $row" >&2; exit 1;
   }
   for walltime in "$dw" "$rw" "$meshWalltime" "$prepareWalltime" "${runWalltimeOverride:-$rw}"; do
      [[ "$walltime" =~ ^[0-9]+:[0-5][0-9]:[0-5][0-9]$ ]] || {
         echo "ERROR: Invalid walltime: $walltime" >&2; exit 1;
      }
   done
done
[[ "$pollInterval" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: Invalid poll interval" >&2; exit 1; }

# --- Validate completed mesh evidence before creating a resumed campaign
# The metadata files are trusted artifacts generated by these project scripts.
# Read them in a subshell so their variables cannot replace launcher state.
if [[ -n "$resumeMeshInput" || -n "$meshArtifactsInput" ]]; then
   [[ -n "$resumeMeshInput" && -n "$meshArtifactsInput" ]] || {
      echo "ERROR: Supply --resume-from-mesh and --mesh-artifacts-dir together" >&2
      exit 1
   }
   [[ -z "$benchmarkSourceInput" ]] || {
      echo "ERROR: --benchmark-source cannot be combined with mesh reuse" >&2
      exit 1
   }
   resumeMeshInput=$(realpath -e "$resumeMeshInput") || exit 1
   meshArtifactsInput=$(realpath -e "$meshArtifactsInput") || exit 1
   for file in mesh-info.env meshFoam.status.txt; do
      [[ -r "$meshArtifactsInput/$file" ]] || {
         echo "ERROR: Missing mesh evidence: $meshArtifactsInput/$file" >&2
         exit 1
      }
   done
   grep -qx 'STATUS=PASS' "$meshArtifactsInput/meshFoam.status.txt" &&
      grep -qx 'EXIT_CODE=0' "$meshArtifactsInput/meshFoam.status.txt" || {
         echo "ERROR: Source mesh stage has no successful completion record" >&2
         exit 1
      }
   meshEvidence=$(bash -c '
      set -eu
      source "$1"
      printf "%s\t%s\t%s\t%s" "$CASE_DIRECTORY" "$ACTUAL_CELLS" "$EXPECTED_CELLS" "$OPENFOAM_MODULE"
   ' bash "$meshArtifactsInput/mesh-info.env") || exit 1
   IFS=$'\t' read -r evidenceCase evidenceCells evidenceExpected evidenceModule <<< "$meshEvidence"
   [[ "$(realpath -e "$evidenceCase")" == "$resumeMeshInput" &&
      "$evidenceCells" == "$targetCells" && "$evidenceExpected" == "$targetCells" &&
      "$evidenceModule" == "$caseFoamModule" ]] || {
         echo "ERROR: Reused mesh path, cell count, or OpenFOAM module does not match this campaign" >&2
         exit 1
      }
   # Check the required serial inputs, including compressed OpenFOAM mesh files.
   for file in points faces owner neighbour boundary; do
      [[ -s "$resumeMeshInput/constant/polyMesh/$file" || -s "$resumeMeshInput/constant/polyMesh/$file.gz" ]] || {
         echo "ERROR: Missing mesh component: $file" >&2
         exit 1
      }
   done
   for file in 0/U 0/p system/controlDict system/fvSolution system/fvSchemes; do
      [[ -s "$resumeMeshInput/$file" ]] || {
         echo "ERROR: Missing serial input: $file" >&2
         exit 1
      }
   done
   # Decomposed or evolved cases are not accepted as pristine serial inputs.
   while IFS= read -r directory; do
      name=$(basename "$directory")
      if [[ "$name" == processor* || ( "$name" =~ ^[0-9]+([.][0-9]+)?$ && "$name" != 0 ) ]]; then
         echo "ERROR: Reused case contains generated results: $directory" >&2
         exit 1
      fi
   done < <(find "$resumeMeshInput" -mindepth 1 -maxdepth 1 -type d)
fi

# --- Report the fixed workflow without extracting or submitting anything
if [[ "$dryRun" == true ]]; then
   echo "Workflow: extract -> mesh -> prepare -> decompose -> run"
   if [[ -n "$resumeMeshInput" ]]; then
      echo "Resume: reuse completed extraction/mesh; submit prepare -> decompose -> run"
      echo "Source serial case: $resumeMeshInput"
      echo "Source mesh evidence: $meshArtifactsInput"
   fi
   echo "Case scripts: $scalingScriptDir"
   echo "Artifacts root: ${recipeDir}/artifacts/tests/strong-scaling/${scalingCase}"
   echo "OpenFOAM module: $caseFoamModule"
   printf 'Scaling point: %s\n' "${scalingJobsTable[@]}"
   exit 0
fi

# =============================================================================
# 9. Persistent campaign initialization
# =============================================================================
# Keep durable evidence separate from the shared scratch case.
runTimestamp=$(date '+%Y%m%dT%H%M%S%z')
runId="${CI_PIPELINE_ID:-${runTimestamp}_$$}"
scalingArtifactsDir="${recipeDir}/artifacts/tests/strong-scaling/${scalingCase}"
if [[ -n "$workRootInput" ]]; then
   workRoot=$(realpath -m "$workRootInput")
else
   baseWorkDir=${MYSCRATCH:-${TMPDIR:-$HOME}}
   workRoot="${baseWorkDir}/OpenFOAM-strong-scaling/${USER}-${OPENFOAM_VERSION}/${runId}"
fi

# A resumed campaign must never overwrite its source or source artifacts.
if [[ -n "$resumeMeshInput" ]]; then
   resolvedWork=$(realpath -m "$workRoot")
   for sourcePath in "$resumeMeshInput" "$meshArtifactsInput"; do
      if [[ "$resolvedWork" == "$sourcePath" || "$resolvedWork" == "$sourcePath/"* || "$sourcePath" == "$resolvedWork/"* ]]; then
         echo "ERROR: Work root overlaps mesh-reuse source: $sourcePath" >&2
         exit 1
      fi
   done
fi
mkdir -p "$scalingArtifactsDir"
latestLink="${scalingArtifactsDir}/latest"
if [[ -e "$latestLink" && ! -L "$latestLink" ]]; then
   echo "ERROR: Refusing to remove non-symbolic-link path: $latestLink" >&2
   exit 1
fi
rm -f "$latestLink"
runArtifactsName="${runId}_${artifactRuntimeName}_${cellsMillions}M"
runArtifactsDir="${scalingArtifactsDir}/${runArtifactsName}"
mkdir -p "${runArtifactsDir}/jobs" || exit 1
ln -sfn "$runArtifactsName" "$latestLink"

runLog="${runArtifactsDir}/launcher.run.log"
statusFile="${runArtifactsDir}/status.txt"
testDetailsFile="${runArtifactsDir}/test-details.txt"
testSummaryFile="${runArtifactsDir}/test-summary.txt"
printf '%s\n' RUNNING > "$statusFile"
record_test_status() {
   local exitStatus=$?
   trap - EXIT
   if [[ $exitStatus -eq 0 ]]; then
      printf '%s\n' SUCCESS > "$statusFile"
   else
      printf '%s\n' FAILED > "$statusFile"
   fi
   exit "$exitStatus"
}
trap record_test_status EXIT
exec > >(tee "$runLog") 2>&1

mkdir -p "$workRoot"

# =============================================================================
# 10. Campaign plan
# =============================================================================
# Report the unchanged editable topology table before extraction.
echo "================================================================================"
echo "OpenFOAM Strong-Scaling Test Launcher"
echo "================================================================================"
echo "Version directory         : $recipeDir"
echo "Strong-scaling case       : $scalingCase"
echo "Configuration             : $configFile"
echo "Strong-scaling scripts    : $scalingScriptDir"
echo "OpenFOAM identity         : ${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
echo "Runtime mode              : $runtimeMode"
[[ -n "$SINGULARITY_IMAGE" ]] && echo "SIF image                 : $SINGULARITY_IMAGE"
echo "Work root                 : $workRoot"
echo "Artifacts directory       : $runArtifactsDir"
echo "Target mesh size          : ${cellsMillions}M ($targetCells cells)"
echo "Expected mesh cells       : $actualCells (verified by mesh stage)"
echo "Solver procedure          : owned by the case runFoam.slurm.sh"
echo "Preparation walltime      : $prepareWalltime"
echo "Partition override        : ${partitionInput:-none}"
echo "Reservation               : ${reservationInput:-none}"
echo "Launcher mode             : $([[ "$submitOnly" == true ]] && echo "submit only" || echo "submit and wait")"
echo "--------------------------------------------------------------------------------"
printf "%-6s  %-6s  %-10s  %-12s  %-14s  %-14s  %-12s  %-12s\n" \
   "Job#" "Nodes" "Tasks/Node" "Total Cores" "X-Axis Label" "Cells/Core" "Decomp Time" "Run Time"
printf "%-6s  %-6s  %-10s  %-12s  %-14s  %-14s  %-12s  %-12s\n" \
   "------" "------" "----------" "------------" "--------------" "--------------" "------------" "------------"

jobIndex=0
for row in "${scalingJobsTable[@]}"; do
   ((++jobIndex))
   read -r jNodes jTpn jDecompTime jRunTime <<< "$row"
   [[ -n "$runWalltimeOverride" ]] && jRunTime="$runWalltimeOverride"
   jCores=$((jNodes * jTpn))
   jCellsPerCore=$(awk -v c="$actualCells" -v p="$jCores" 'BEGIN { printf "%.1f", c / p }')
   printf "%-6d  %-6d  %-10d  %-12d  %-14s  %-14s  %-12s  %-12s\n" \
      "$jobIndex" "$jNodes" "$jTpn" "$jCores" "${jCores} (${jNodes})" "$jCellsPerCore" "$jDecompTime" "$jRunTime"
done
echo "================================================================================"
echo

cp -f "$runLog" "$testDetailsFile" 2>/dev/null || true
{
   printf 'SCALING_CASE=%s\n' "$scalingCase"
   printf 'CASE_SCRIPT_DIRECTORY=%s\n' "$scalingScriptDir"
   printf 'ARTIFACT_CASE_DIRECTORY=%s\n' "$scalingArtifactsDir"
} >> "$testDetailsFile"

# =============================================================================
# 11. Scheduler setup
# =============================================================================
# Pass partition and reservation overrides to every submitted job.
command -v sbatch >/dev/null 2>&1 || { echo "ERROR: sbatch not found." >&2; exit 1; }

submissionOverrides=()
[[ -n "$partitionInput" ]] && submissionOverrides+=(--partition="$partitionInput")
[[ -n "$reservationInput" ]] && submissionOverrides+=(--reservation="$reservationInput")

# =============================================================================
# 12. Direct extraction of the authoritative case
# =============================================================================
# Extraction materializes the benchmark and version reference before requesting
# compute resources. All following stages consume explicit absolute paths.

sourceCaseDir="${workRoot}/source-case/${scalingCase}"
baseCaseDir="${workRoot}/base-case/${scalingCase}"
extractArgs=(
   --campaign-dir "$workRoot"
   --artifacts-dir "$runArtifactsDir"
   --foam-module "$caseFoamModule"
   --mesh "${cellsMillions}M"
   --mode fixedIter
)
[[ -z "$benchmarkSourceInput" ]] || extractArgs+=(--benchmark-source "$benchmarkSourceInput")
if [[ -z "$resumeMeshInput" ]]; then
   echo "Stage 1 - Extracting case source"
   "$extractScript" "${extractArgs[@]}" 2>&1 | tee "${runArtifactsDir}/extractCase.run.log"
   [[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "ERROR: Extraction failed" >&2; exit 1; }
else
   # Copy rather than link: preparation may remove stale directories or later
   # modify configuration. Reflinks are used only when the filesystem supports them.
   echo "Stages 1-2 - Reusing validated serial mesh in a new campaign copy"
   [[ ! -e "$baseCaseDir" ]] || {
      echo "ERROR: Resume destination already exists" >&2
      exit 1
   }
   mkdir -p "$(dirname "$baseCaseDir")" || exit 1
   cp -a --reflink=auto "$resumeMeshInput" "$baseCaseDir" || exit 1

   # Preserve original evidence separately; do not invent a new mesh job ID.
   mkdir -p "$runArtifactsDir/reused-mesh-source" || exit 1
   cp -p "$meshArtifactsInput/mesh-info.env" "$meshArtifactsInput/meshFoam.status.txt" \
      "$runArtifactsDir/reused-mesh-source/" || exit 1
   for file in checkMesh.log source-provenance.env; do
      if [[ -r "$meshArtifactsInput/$file" ]]; then
         cp -p "$meshArtifactsInput/$file" "$runArtifactsDir/reused-mesh-source/" || exit 1
      fi
   done
   printf 'EXPECTED_CELLS=%q\nACTUAL_CELLS=%q\nCASE_DIRECTORY=%q\nOPENFOAM_MODULE=%q\n' \
      "$targetCells" "$evidenceCells" "$baseCaseDir" "$caseFoamModule" > "$runArtifactsDir/mesh-info.env"
   printf 'STATUS=PASS\nEXIT_CODE=0\nREUSED=true\n' > "$runArtifactsDir/meshFoam.status.txt"
   {
      printf 'MESH_REUSED=true\nMESH_SOURCE_CASE=%q\nMESH_SOURCE_ARTIFACTS=%q\n' "$resumeMeshInput" "$meshArtifactsInput"
   } >> "$testDetailsFile"
fi

# Submit from a clean memory-request environment while retaining the original
# export policy. Parse sbatch's optional cluster suffix in one place.
submitStage() {
   local submission jobId
   submission=$(env -u SLURM_MEM_PER_CPU -u SLURM_MEM_PER_GPU -u SLURM_MEM_PER_NODE \
      SLURM_EXPORT_ENV=ALL sbatch --export=NONE --parsable \
      "${submissionOverrides[@]}" "$@") || return 1
   IFS=';' read -r jobId _ <<< "$submission"
   [[ "$jobId" =~ ^[0-9]+$ ]] || { echo "ERROR: Invalid sbatch response: $submission" >&2; return 1; }
   printf '%s\n' "$jobId"
}


# =============================================================================
# 13. Shared mesh and mandatory preparation jobs
# =============================================================================
# Fresh campaigns require mesh success; resumed campaigns validate completed
# mesh evidence before submission. Every decomposition depends on preparation.

meshJobId=""
allSubmittedJobIds=()
prepareDependency=()
if [[ -z "$resumeMeshInput" ]]; then
   echo "Stage 2 - Submitting mesh generation"
   meshJobId=$(submitStage \
      --nodes=1 --ntasks=1 --time="$meshWalltime" \
      --output="${runArtifactsDir}/slurm-meshFoam-%j.out" \
      "$meshScript" \
      --source-case "$sourceCaseDir" --case-dir "$baseCaseDir" \
      --artifacts-dir "$runArtifactsDir" --expected-cells "$targetCells" \
      --foam-module "$caseFoamModule") || exit 1
   allSubmittedJobIds+=("$meshJobId")
   prepareDependency=(--dependency="afterok:${meshJobId}" --kill-on-invalid-dep=yes)
fi

# Reused meshes have already passed; preparation can start without a fictitious
# scheduler dependency. Fresh campaigns still depend on their actual mesh job.
echo "Stage 3 - Submitting mandatory case preparation"
prepareJobId=$(submitStage \
   "${prepareDependency[@]}" \
   --nodes=1 --ntasks=1 --time="$prepareWalltime" \
   --output="${runArtifactsDir}/slurm-prepareFoam-%j.out" \
   "$prepareScript" \
   --case-dir "$baseCaseDir" --artifacts-dir "$runArtifactsDir" \
   --expected-steps 15 --foam-module "$caseFoamModule") || exit 1
allSubmittedJobIds+=("$prepareJobId")
decomposeJobIds=()
runJobIds=()
jobTags=()
echo "Mesh job: ${meshJobId:-reused}; mandatory preparation job: $prepareJobId"


# =============================================================================
# 14. Per-topology decomposition and solver chains
# =============================================================================
# Keep the supplied scalingJobsTable intact. Each row receives an independent
# working case and artifact directory, but the same prepared serial input.

for row in "${scalingJobsTable[@]}"; do
   read -r jNodes jTpn jDecompTime jRunTime <<< "$row"
   [[ -z "$runWalltimeOverride" ]] || jRunTime=$runWalltimeOverride
   jCores=$((jNodes * jTpn))
   jobTag="N${jNodes}_tpn${jTpn}_cores${jCores}"
   jobArtifactsDir="${runArtifactsDir}/jobs/${jobTag}"
   jobCaseDir="${workRoot}/run/case_${jobTag}/${scalingCase}"
   mkdir -p "$jobArtifactsDir" || exit 1

   # Decomposition is a serial utility with a memory-heavy shared mesh input.
   decompJobId=$(submitStage \
      --dependency="afterok:${prepareJobId}" --kill-on-invalid-dep=yes \
      --nodes=1 --ntasks=1 --job-name="decomp-${jobTag}" \
      --time="$jDecompTime" --output="${jobArtifactsDir}/slurm-decomposeFoam-%j.out" \
      "$decomposeScript" \
      --prepared-case "$baseCaseDir" --job-case "$jobCaseDir" \
      --job-artifacts "$jobArtifactsDir" --nodes "$jNodes" \
      --tasks-per-node "$jTpn" --foam-module "$caseFoamModule") || exit 1

   # Allocate the exact rank topology; the case script owns its solver duration.
   runJobId=$(submitStage \
      --dependency="afterok:${decompJobId}" --kill-on-invalid-dep=yes \
      --job-name="run-${jobTag}" --nodes="$jNodes" --ntasks="$jCores" \
      --ntasks-per-node="$jTpn" --cpus-per-task=1 --exclusive \
      --time="$jRunTime" --output="${jobArtifactsDir}/slurm-runFoam-%j.out" \
      "$runScript" \
      --case-dir "$jobCaseDir" --job-artifacts "$jobArtifactsDir" \
      --nodes "$jNodes" --tasks-per-node "$jTpn" \
      --expected-steps 15 --foam-module "$caseFoamModule") || exit 1

   jobTags+=("$jobTag")
   decomposeJobIds+=("$decompJobId")
   runJobIds+=("$runJobId")
   allSubmittedJobIds+=("$decompJobId" "$runJobId")
   echo "$jobTag: decompose=$decompJobId (afterok:$prepareJobId); run=$runJobId (afterok:$decompJobId)"
done

# Persist the dependency evidence independently of the human-readable run log.
{
   printf 'MESH_JOB_ID=%s\nPREPARE_JOB_ID=%s\n' "$meshJobId" "$prepareJobId"
   printf 'RUN_JOB_IDS=%s\nOPENFOAM_MODULE=%s\n' "${runJobIds[*]}" "$caseFoamModule"
} >> "$testDetailsFile"


# =============================================================================
# 15. Submit-only reporting
# =============================================================================
# Submission is not execution success. Leave the campaign marked SUBMITTED and
# preserve the complete dependency chain for subsequent inspection.

if [[ "$submitOnly" == true ]]; then
   printf '%s\n' SUBMITTED > "$statusFile"
   trap - EXIT
   {
      echo "Result: SUBMITTED"
      echo "Artifacts directory: $runArtifactsDir"
      echo "Mesh job: ${meshJobId:-reused from validated source}"
      echo "Preparation job: $prepareJobId"
      for ((i=0; i<${#jobTags[@]}; i++)); do
         echo "${jobTags[$i]}: decompose=${decomposeJobIds[$i]} run=${runJobIds[$i]}"
      done
      echo "Analysis: select a common interval from the completed raw logs."
   } > "$testSummaryFile"
   cat "$testSummaryFile"
   exit 0
fi


# =============================================================================
# 16. Queue monitoring and mandatory stage-status verification
# =============================================================================
# An empty queue does not establish success. Check every stage's durable status
# before invoking analysis or marking the campaign successful.

while true; do
   runningJobs=0
   pendingJobs=0
   otherActiveJobs=0
   for jobId in "${allSubmittedJobIds[@]}"; do
      jobState=$(squeue --noheader --jobs="$jobId" --format="%T") || {
         echo "ERROR: Cannot query Slurm job $jobId" >&2; exit 1;
      }
      case "$jobState" in
         '') ;;
         RUNNING|COMPLETING) ((++runningJobs)) ;;
         PENDING) ((++pendingJobs)) ;;
         *) ((++otherActiveJobs)) ;;
      esac
   done
   activeJobs=$((runningJobs + pendingJobs + otherActiveJobs))
   ((activeJobs > 0)) || break
   echo "Slurm queue: running=$runningJobs pending=$pendingJobs other=$otherActiveJobs"
   sleep "$pollInterval"
done

# The supplied stage scripts write STATUS=PASS and EXIT_CODE=0.
checkStageStatus() {
   local path=$1
   [[ -r "$path" ]] && grep -qx 'STATUS=PASS' "$path" && grep -qx 'EXIT_CODE=0' "$path"
}
stagesFailed=false
for stage in meshFoam prepareFoam; do
   if checkStageStatus "${runArtifactsDir}/${stage}.status.txt"; then
      echo "$stage: PASS"
   else
      echo "ERROR: $stage failed or has no successful status record" >&2
      stagesFailed=true
   fi
done
for jobTag in "${jobTags[@]}"; do
   for stage in decomposeFoam runFoam; do
      if ! checkStageStatus "${runArtifactsDir}/jobs/${jobTag}/${stage}.status.txt"; then
         echo "ERROR: $jobTag/$stage failed or has no successful status record" >&2
         stagesFailed=true
      fi
   done
done
[[ "$stagesFailed" == false ]] || exit 1


# =============================================================================
# 17. Independent Python analysis and final result
# =============================================================================
# Do not guess physical times for a new case. Raw artifacts are sufficient for a
# later analysis. Explicit endpoints enable automatic analysis after completion.

if [[ -n "$statsStartTime" ]]; then
   [[ -r "$postProcessScript" ]] || { echo "ERROR: Missing Python postprocessor" >&2; exit 1; }
   module load python/3.11.6 || exit 1
   python3 -c 'import sys, matplotlib; assert sys.version_info >= (3, 11)' || exit 1
   python3 "$postProcessScript" \
      --artifacts-dir "$runArtifactsDir" --case "$scalingCase" \
      --start-time "$statsStartTime" --end-time "$statsEndTime" || exit 1
   echo "Analysis completed; interval-specific outputs remain in the artifact tree."
fi
printf 'Result: PASS\nArtifacts directory: %s\n' "$runArtifactsDir" > "$testSummaryFile"
echo "RESULT: PASS"
exit 0
