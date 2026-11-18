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
# Copy the prepared base case into a job-specific directory, decompose it with
# scotch for the requested (nodes x tasks-per-node) core count, report the
# cells-per-core and scotch 3D partition statistics, and validate the collated
# processor directories.
#
# This Slurm job is stage 4 of the mandatory five-stage strong-scaling workflow.
# It expects prepareFoam.slurm.sh to have validated and prepared the shared case
# under <work-root>/base-case/<CASE_NAME>. Each topology receives an isolated
# copy, a scotch decomposition, and a reproducible run-input snapshot.
#
# Inputs: the prepared serial case, mesh/preparation metadata, target nodes and
# tasks per node, runtime identity, and an isolated job-artifact path.
# Outputs: the decomposed job case, decomposePar.log, job-info.env, run-inputs/
# checksums, and a strict stage status record.
#
# Usage:
#   sbatch decomposeFoam.slurm.sh --image <file> --config <file> [options]
#   sbatch decomposeFoam.slurm.sh --shpc --config <file> [options]
#   sbatch decomposeFoam.slurm.sh --bare-metal --config <file> [options]
#   sbatch decomposeFoam.slurm.sh --image <file> --recipe-dir <directory> [options]
#   sbatch decomposeFoam.slurm.sh --shpc --recipe-dir <directory> [options]
#   sbatch decomposeFoam.slurm.sh --bare-metal --recipe-dir <directory> [options]
#
# Exit status:
#   0  The prepared case was copied, decomposed with scotch, and validated.
#   1  Invalid input, missing base mesh, command failure, or validation failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

#SBATCH --job-name=decomposeFoam-strongScaling
#SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=64GB
#SBATCH --time=00:45:00

set -u

# =============================================================================
# 1. Topology-specific decomposition policy
# =============================================================================
CASE_NAME="periodicPlaneChannel"
targetNodes=1
tasksPerNode=32
mGroup=0 # 0 means auto-select one collated I/O group per node (tasksPerNode)

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
caseDirInput=""
singularityModule="singularity/4.3.5-mpi"
singularityModuleSpecified=false

# --- Command-line help
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
                              Default for --image: singularity/4.3.5-mpi
  --shpc                      Load <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>
  --bare-metal                Load <OPENFOAM_FORK>/<OPENFOAM_VERSION> and use the
                              OpenFOAM tools directly

Configuration selection (choose exactly one):
  --recipe-dir, -r <directory>  OpenFOAM version directory containing the
                                buildAndValidationConfig configuration file
  --config <file>             Version configuration file defining OPENFOAM_FORK
                              and OPENFOAM_VERSION

Decomposition and path options:
  --nodes <N>                 Number of compute nodes for the target solver job (default: $targetNodes)
  --tasks-per-node <n>        MPI tasks per node for the target solver job (default: $tasksPerNode)
  --io-group <g>              Group size for collated file handling (default: tasks-per-node)
  --case-dir <directory>      Explicit job-specific case directory. By default:
                              <work-root>/run/case_N<N>_tpn<n>_cores<N*n>/$CASE_NAME
  --work-root, -w <directory> Override the shared host work root.
  --test-artifacts-dir <directory>
                              Job-specific artifact destination.
  --help, -h                  Show this help message and exit
USAGE
}

# --- Parse command-line arguments
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
      --nodes)
         [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --nodes requires a positive integer" >&2; exit 1; }
         targetNodes="$2"; shift 2 ;;
      --tasks-per-node)
         [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --tasks-per-node requires a positive integer" >&2; exit 1; }
         tasksPerNode="$2"; shift 2 ;;
      --io-group)
         [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --io-group requires a positive integer" >&2; exit 1; }
         mGroup="$2"; shift 2 ;;
      --case-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --case-dir requires <directory>" >&2; exit 1; }
         caseDirInput="$2"; shift 2 ;;
      --work-root|-w)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --work-root requires <directory>" >&2; exit 1; }
         workRootInput="$2"; shift 2 ;;
      --recipe-dir|-r)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --recipe-dir requires <directory>" >&2; exit 1; }
         recipeDirInput="$2"; shift 2 ;;
      --config)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --config requires <file>" >&2; exit 1; }
         configFileInput="$2"; shift 2 ;;
      --test-artifacts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --test-artifacts-dir requires <directory>" >&2; exit 1; }
         testArtifactsDirInput="$2"; shift 2 ;;
      -h|--help)
         usage; exit 0 ;;
      *)
         echo "ERROR: Unknown option '$1'" >&2; usage >&2; exit 1 ;;
   esac
done

nProcs=$((targetNodes * tasksPerNode))
if (( mGroup <= 0 )); then
   mGroup=$tasksPerNode
fi

# =============================================================================
# 3. Input validation and version identity
# =============================================================================
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

runtimeSelectorCount=0
[[ -n "$imageInput" ]] && ((runtimeSelectorCount += 1))
[[ "$useSHPC" == true ]] && ((runtimeSelectorCount += 1))
[[ "$useBareMetal" == true ]] && ((runtimeSelectorCount += 1))
[[ $runtimeSelectorCount -eq 1 ]] || {
   echo "ERROR: Choose exactly one of --image <file>, --shpc, or --bare-metal" >&2
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
jobTag="N${targetNodes}_tpn${tasksPerNode}_cores${nProcs}"

if [[ -n "$caseDirInput" ]]; then
   TEST_CASE=$(realpath -m "$caseDirInput")
else
   TEST_CASE="${workRoot}/jobs/${jobTag}/${CASE_NAME}"
fi

if [[ -n "$testArtifactsDirInput" ]]; then
   outputDir=$(realpath -m "$testArtifactsDirInput")
else
   outputDir="${workRoot}/test-output/${jobTag}"
fi
mkdir -p "$outputDir" || { echo "ERROR: Could not create artifact directory: $outputDir" >&2; exit 1; }

stageName="decomposeFoam"
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

# =============================================================================
# 4. Prepared-case handoff validation
# =============================================================================
# Both mesh and preparation records are required. This prevents accidental
# decomposition of a mesh whose fields or solver controls were not prepared.
[[ -d "$BASE_CASE_DIR" ]] || { echo "ERROR: Prepared base case not found: $BASE_CASE_DIR" >&2; exit 1; }
[[ -r "$MESH_INFO_FILE" ]] || { echo "ERROR: Base mesh metadata file not found: $MESH_INFO_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$MESH_INFO_FILE"
[[ -r "$PREPARE_INFO_FILE" ]] || { echo "ERROR: Preparation metadata file not found: $PREPARE_INFO_FILE" >&2; exit 1; }
configuredFork=$OPENFOAM_FORK
configuredVersion=$OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$PREPARE_INFO_FILE"
[[ "${PREPARED_CASE:-}" == "$BASE_CASE_DIR" ]] || {
   echo "ERROR: Preparation metadata identifies a different base case: ${PREPARED_CASE:-missing}" >&2
   exit 1
}
[[ "${SOLVER:-}" == pimpleFoam ]] || { echo "ERROR: Prepared solver is not pimpleFoam" >&2; exit 1; }
awk -v a="${START_TIME:-}" -v b="${END_TIME:-}" 'BEGIN {
   numeric = "^[-+]?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$"
   exit !(a ~ numeric && b ~ numeric && b + 0 > a + 0)
}' || { echo "ERROR: Prepared OpenFOAM-time interval is invalid" >&2; exit 1; }
[[ "$OPENFOAM_FORK" == "$configuredFork" && "$OPENFOAM_VERSION" == "$configuredVersion" ]] || {
   echo "ERROR: Prepared OpenFOAM identity does not match the selected configuration" >&2
   exit 1
}

cellsPerCore=$(awk -v c="$ACTUAL_CELLS" -v p="$nProcs" 'BEGIN { printf "%.1f", c / p }')

echo "======================================================"
echo "Strong-Scaling Decomposition Configuration ($jobTag)"
echo "======================================================"
echo "Base meshed case      : $BASE_CASE_DIR"
echo "Job case directory    : $TEST_CASE"
echo "Job artifacts         : $outputDir"
echo "Target mesh (millions): ${TARGET_CELLS_MILLIONS}M ($TARGET_CELLS cells)"
echo "Actual mesh cells     : $ACTUAL_CELLS (${SCALED_NX} x ${SCALED_NY_TOTAL} x ${SCALED_NZ})"
echo "Target solver nodes   : $targetNodes"
echo "Tasks per node        : $tasksPerNode"
echo "Total MPI cores       : $nProcs"
echo "Cells per core        : $cellsPerCore"
echo "Collated I/O group    : $mGroup"
echo "Decomposition method  : scotch"
echo "======================================================"
echo

# =============================================================================
# 5. OpenFOAM runtime setup
# =============================================================================
if [[ "$useSHPC" == true ]]; then
   runtimeMode="SHPC module"
   shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
   shpcExec="${OPENFOAM_FORK}-exec"
   openfoamCommandPrefix=()
   module load "$shpcModule" || { echo "ERROR: Failed to load SHPC module: $shpcModule" >&2; exit 1; }
   for openfoamTool in foamDictionary decomposePar; do
      command -v "$openfoamTool" >/dev/null 2>&1 || { echo "ERROR: OpenFOAM wrapper is unavailable: $openfoamTool" >&2; exit 1; }
   done
   SINGULARITY_IMAGE=$(realpath "$SINGULARITY_CONTAINER")
   if [[ "$singularityModuleSpecified" == true ]]; then
      module load "$singularityModule" || exit 1
   fi
elif [[ "$useBareMetal" == true ]]; then
   runtimeMode="Bare-metal module"
   bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
   openfoamCommandPrefix=()
   module load "$bareMetalModule" || { echo "ERROR: Failed to load bare-metal module: $bareMetalModule" >&2; exit 1; }
   for openfoamTool in foamDictionary decomposePar; do
      command -v "$openfoamTool" >/dev/null 2>&1 || { echo "ERROR: OpenFOAM tool is unavailable: $openfoamTool" >&2; exit 1; }
   done
else
   runtimeMode="Explicit Singularity image"
   openfoamCommandPrefix=(singularity exec "$SINGULARITY_IMAGE")
   module load "$singularityModule" || { echo "ERROR: Failed to load $singularityModule" >&2; exit 1; }
fi

# =============================================================================
# 6. Isolated topology-specific case
# =============================================================================
echo "Copying prepared base case to job directory: $TEST_CASE"
rm -rf "$TEST_CASE"
mkdir -p "$(dirname "$TEST_CASE")" || exit 1
cp -a "$BASE_CASE_DIR" "$TEST_CASE" || {
   echo "ERROR: Failed to copy meshed base case to $TEST_CASE" >&2
   exit 1
}

cd "$TEST_CASE" || { echo "ERROR: Could not enter $TEST_CASE" >&2; exit 1; }
rm -rf "processors${nProcs}"*

# =============================================================================
# 7. Collated-I/O rank groups
# =============================================================================
of_ioRanks="0"
iC=$mGroup
while (( iC < nProcs )); do
   of_ioRanks="$of_ioRanks $iC"
   ((iC += mGroup))
done
export FOAM_IORANKS="($of_ioRanks)"
echo "FOAM_IORANKS=$FOAM_IORANKS"
echo

# =============================================================================
# 8. Scotch dictionary configuration and decomposition
# =============================================================================
echo "Updating system/decomposeParDict for $nProcs subdomains using method=scotch"
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary system/decomposeParDict \
   -entry numberOfSubdomains -set "$nProcs" || {
      echo "ERROR: Failed to set numberOfSubdomains=$nProcs" >&2
      exit 1
   }
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary system/decomposeParDict \
   -entry method -set scotch || {
      echo "ERROR: Failed to set method=scotch" >&2
      exit 1
   }

# Run the serial decomposition utility inside the one-task allocation.
decomposeLog="${outputDir}/decomposePar.log"
echo "Running: decomposePar -fileHandler collated -cellDist -force"
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   decomposePar -fileHandler collated -cellDist -force 2>&1 | tee "$decomposeLog"
decomposeStatus=${PIPESTATUS[0]}

[[ $decomposeStatus -eq 0 ]] || {
   echo "ERROR: decomposePar failed with exit status $decomposeStatus" >&2
   exit 1
}
grep -qE 'FOAM FATAL (ERROR|IO ERROR)' "$decomposeLog" && {
   echo "ERROR: decomposePar reported an OpenFOAM fatal error" >&2
   exit 1
}
echo "PASS: decomposePar completed successfully"
echo

# =============================================================================
# 9. Partition statistics and collated-layout validation
# =============================================================================
echo "======================================================"
echo "Scotch Partitioning Report ($nProcs subdomains)"
echo "======================================================"
echo "Target cells per core (ideal) : $cellsPerCore"
if [[ -f constant/cellDecomposition ]]; then
   awk '
   /^[0-9]+[[:space:]]*$/ && !inList { count = $1; inList = 1; next }
   inList && /^\(/ { reading = 1; next }
   reading && /^\)/ { reading = 0; exit }
   reading && /^[0-9]+$/ {
      proc[$1]++
      total++
   }
   END {
      if (total > 0) {
         minC = total; maxC = 0; nP = 0
         for (p in proc) {
            nP++
            if (proc[p] < minC) minC = proc[p]
            if (proc[p] > maxC) maxC = proc[p]
         }
         avgC = total / nP
         imbalance = (avgC > 0) ? ((maxC - avgC) / avgC) * 100.0 : 0.0
         printf "Subdomains populated          : %d\n", nP
         printf "Min cells on a core           : %d\n", minC
         printf "Avg cells per core            : %.1f\n", avgC
         printf "Max cells on a core           : %d\n", maxC
         printf "Max cell load imbalance       : %.2f%%\n", imbalance
      }
   }' constant/cellDecomposition
fi
echo "======================================================"
echo

# Verify every expected collated I/O group before the dependent run starts.
echo "Checking collated processor directories ..."
IORANKS_ARRAY=($of_ioRanks)
for rank in "${IORANKS_ARRAY[@]}"; do
   start=$rank
   (( start >= nProcs )) && break
   end=$((rank + mGroup - 1))
   (( end >= nProcs )) && end=$((nProcs - 1))
   if (( start == end )); then
      dir="processors${nProcs}_${start}"
   else
      dir="processors${nProcs}_${start}-${end}"
   fi

   if [[ ! -d "$dir" && -d "processors${nProcs}" ]]; then
      dir="processors${nProcs}"
   fi

   [[ -d "$dir" ]] || {
      echo "ERROR: Missing collated processor directory: $dir" >&2
      exit 1
   }
   echo "  $dir exists"
done
echo "PASS: Collated processor directories verified"
echo

# =============================================================================
# 10. Effective run-input snapshot
# =============================================================================
# Archive the topology-specific system dictionary after decomposeParDict edits,
# plus configuration-only constant/ and 0/ files. Exclude constant/polyMesh and
# processor directories so artifacts remain small and scientifically auditable.
runInputSnapshot="${outputDir}/run-inputs"
rm -rf "$runInputSnapshot"
mkdir -p "$runInputSnapshot/0" "$runInputSnapshot/constant"
cp -a system "$runInputSnapshot/system"
find 0 -maxdepth 1 -type f -exec cp -a {} "$runInputSnapshot/0/" \;
find constant -maxdepth 1 -type f -exec cp -a {} "$runInputSnapshot/constant/" \;
(
   cd "$runInputSnapshot" || exit 1
   find 0 constant system -type f -print0 \
      | sort -z \
      | xargs -0 sha256sum > checksums.sha256
) || { echo "ERROR: Failed to create run-input checksums" >&2; exit 1; }

# =============================================================================
# 11. Decomposition metadata and final summary
# =============================================================================
# Save topology and prepared-input provenance for runFoam and post-processing.
cat > "${outputDir}/job-info.env" <<EOF
JOB_TAG=${jobTag}
CASE_NAME=${CASE_NAME}
TEST_CASE=${TEST_CASE}
NODES=${targetNodes}
TASKS_PER_NODE=${tasksPerNode}
CORES=${nProcs}
IO_GROUP=${mGroup}
TARGET_CELLS_MILLIONS=${TARGET_CELLS_MILLIONS}
TARGET_CELLS=${TARGET_CELLS}
ACTUAL_CELLS=${ACTUAL_CELLS}
CELLS_PER_CORE=${cellsPerCore}
SOLVER=${SOLVER}
START_TIME=${START_TIME}
END_TIME=${END_TIME}
PREPARE_INFO_FILE=${PREPARE_INFO_FILE}
EOF

echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Job tag          : $jobTag"
echo "Case directory   : $TEST_CASE"
echo "Nodes x TPN      : ${targetNodes} x ${tasksPerNode} = ${nProcs} cores"
echo "Actual mesh cells: $ACTUAL_CELLS"
echo "Cells per core   : $cellsPerCore"
echo "Run-input snapshot: $runInputSnapshot"
echo "ALL STEPS PASSED: Scotch decomposition completed successfully."
exit 0
