#!/bin/bash --login
# Run and benchmark the version-specific OpenFOAM strong-scaling case in parallel.
#
# This Slurm job is the fourth stage of the version-specific strong-scaling
# workflow. It expects decomposeFoam.slurm.sh to have copied and decomposed the
# job-specific case. It optimizes local subdomain cell bandwidth with
# renumberMesh -parallel, configures system/controlDict with stopAt=nextWrite,
# writeControl=clockTime, writeInterval=<solverSeconds>, and
# runTimeModifiable=false so pimpleFoam stops natively after the configured
# wall-clock window (--solver-minutes, default 10 minutes) without per-step
# dictionary polling, and extracts per-time-step ExecutionTime statistics for
# strong-scaling analysis.
#
# Usage:
#   sbatch runFoam.slurm.sh --image <file> --config <file> [options]
#   sbatch runFoam.slurm.sh --shpc --config <file> [options]
#   sbatch runFoam.slurm.sh --bare-metal --config <file> [options]
#   sbatch runFoam.slurm.sh --image <file> --recipe-dir <directory> [options]
#   sbatch runFoam.slurm.sh --shpc --recipe-dir <directory> [options]
#   sbatch runFoam.slurm.sh --bare-metal --recipe-dir <directory> [options]
#
# Exit status:
#   0  The solver ran for the configured window and step-time metrics were recorded.
#   1  Invalid input, missing decomposition output, solver failure, or metric failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

#SBATCH --job-name=runFoam-strongScaling
#SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=32
#SBATCH --cpus-per-task=1
#SBATCH --exclusive
#SBATCH --time=00:20:00

set -u

# --- Version-specific strong-scaling solver settings
CASE_NAME="periodicPlaneChannel"
SOLVER="pimpleFoam"
DEFAULT_SOLVER_MINUTES="10"
mGroup=0 # 0 means auto-select one collated I/O group per node (TASKS_PER_NODE)

# --- Initial settings
thisScript=$(basename "$0")
imageInput=""
useSHPC=false
useBareMetal=false
workRootInput=""
recipeDirInput=""
configFileInput=""
testArtifactsDirInput=""
caseDirInput=""
solverMinutesInput="$DEFAULT_SOLVER_MINUTES"
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
  --bare-metal                Load <OPENFOAM_FORK>/<OPENFOAM_VERSION> and run the
                              solver directly

Configuration selection (choose exactly one):
  --recipe-dir, -r <directory>  OpenFOAM version directory containing the
                                buildAndValidationConfig configuration file
  --config <file>             Version configuration file defining runtime identity

Solver and path options:
  --solver-minutes <minutes>  Target wall-clock execution window in minutes for
                              the solver configured via writeControl=clockTime
                              and stopAt=nextWrite (default: $DEFAULT_SOLVER_MINUTES)
  --io-group <g>              Group size for collated file handling (default: tasks-per-node)
  --case-dir <directory>      Explicit decomposed case directory
  --work-root, -w <directory> Override the shared host work root
  --test-artifacts-dir <directory>
                              Job-specific artifact destination
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
      --solver-minutes)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --solver-minutes requires <minutes>" >&2; usage >&2; exit 1; }
         solverMinutesInput="$2"; shift 2 ;;
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

awk -v m="$solverMinutesInput" 'BEGIN { exit (m ~ /^[0-9]+([.][0-9]+)?$/ && m + 0 > 0 ? 0 : 1) }' || {
   echo "ERROR: --solver-minutes must be a positive number; got '$solverMinutesInput'" >&2
   exit 1
}
solverSeconds=$(awk -v m="$solverMinutesInput" 'BEGIN { printf "%d", int(m * 60 + 0.5) }')
(( solverSeconds >= 5 )) || solverSeconds=5

# --- Validate common inputs and load version identity
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

# --- Derive Slurm allocation parameters
NODES=${SLURM_JOB_NUM_NODES:-1}
if [[ -n "${SLURM_NTASKS_PER_NODE:-}" ]]; then
   TASKS_PER_NODE=${SLURM_NTASKS_PER_NODE%%[(,]*}
elif [[ -n "${SLURM_NTASKS:-}" ]]; then
   TASKS_PER_NODE=$((SLURM_NTASKS / NODES))
else
   TASKS_PER_NODE=32
fi
nProcs=$((NODES * TASKS_PER_NODE))
if (( mGroup <= 0 )); then
   mGroup=$TASKS_PER_NODE
fi
jobTag="N${NODES}_tpn${TASKS_PER_NODE}_cores${nProcs}"

if [[ -n "$caseDirInput" ]]; then
   TEST_CASE=$(realpath -m "$caseDirInput")
else
   TEST_CASE="${workRoot}/run/case_${jobTag}/${CASE_NAME}"
fi

if [[ -n "$testArtifactsDirInput" ]]; then
   outputDir=$(realpath -m "$testArtifactsDirInput")
else
   outputDir="${workRoot}/test-output/${jobTag}"
fi
mkdir -p "$outputDir" || { echo "ERROR: Could not create test-artifact directory: $outputDir" >&2; exit 1; }

stageName="runFoam"
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

# --- Load mesh / job metadata to report cells per core
MESH_INFO_FILE="${workRoot}/run/baseCase/mesh-info.env"
if [[ -r "$MESH_INFO_FILE" ]]; then
   # shellcheck source=/dev/null
   source "$MESH_INFO_FILE"
fi
ACTUAL_CELLS=${ACTUAL_CELLS:-0}
TARGET_CELLS_MILLIONS=${TARGET_CELLS_MILLIONS:-unknown}
cellsPerCore=$(awk -v c="$ACTUAL_CELLS" -v p="$nProcs" 'BEGIN { printf "%.1f", (p > 0 ? c / p : 0) }')

echo "======================================================"
echo "Strong-Scaling Solver Execution ($jobTag)"
echo "======================================================"
echo "Job tag               : $jobTag"
echo "Case directory        : $TEST_CASE"
echo "Job artifacts         : $outputDir"
echo "Target mesh (millions): ${TARGET_CELLS_MILLIONS}M"
echo "Actual mesh cells     : $ACTUAL_CELLS"
echo "Allocated nodes       : $NODES"
echo "Tasks per node        : $TASKS_PER_NODE"
echo "Total MPI cores       : $nProcs"
echo "Cells per core        : $cellsPerCore"
echo "Solver time window    : ${solverMinutesInput} min (${solverSeconds}s)"
echo "======================================================"
echo

# --- Set up and validate the selected OpenFOAM runtime
if [[ "$useSHPC" == true ]]; then
   runtimeMode="SHPC module"
   runtimeKey="shpc"
   shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
   shpcExec="${OPENFOAM_FORK}-exec"
   solverCommandPrefix=()
   module load "$shpcModule" || { echo "ERROR: Failed to load $shpcModule" >&2; exit 1; }
   for tool in "$SOLVER" renumberMesh foamDictionary; do
      command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: Missing wrapper: $tool" >&2; exit 1; }
   done
   SINGULARITY_IMAGE=$(realpath "$SINGULARITY_CONTAINER")
   if [[ "$singularityModuleSpecified" == true ]]; then
      module load "$singularityModule" || exit 1
   fi
elif [[ "$useBareMetal" == true ]]; then
   runtimeMode="Bare-metal module"
   runtimeKey="bare-metal"
   bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
   solverCommandPrefix=()
   module load "$bareMetalModule" || { echo "ERROR: Failed to load bare-metal module: $bareMetalModule" >&2; exit 1; }
   for tool in "$SOLVER" renumberMesh foamDictionary; do
      command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: Missing tool: $tool" >&2; exit 1; }
   done
else
   runtimeMode="Explicit Singularity image"
   runtimeKey="singularity"
   solverCommandPrefix=(singularity exec "$SINGULARITY_IMAGE")
   module load "$singularityModule" || { echo "ERROR: Failed to load $singularityModule" >&2; exit 1; }
   command -v singularity >/dev/null 2>&1 || { echo "ERROR: singularity unavailable" >&2; exit 1; }
fi

# --- Set the I/O ranks for collated file handling
of_ioRanks="0"
iC=$mGroup
while (( iC < nProcs )); do
   of_ioRanks="$of_ioRanks $iC"
   ((iC += mGroup))
done
export FOAM_IORANKS="($of_ioRanks)"
echo "FOAM_IORANKS=$FOAM_IORANKS"
echo

# --- Validate decomposed case
[[ -d "$TEST_CASE" ]] || { echo "ERROR: Case directory not found: $TEST_CASE" >&2; exit 1; }
cd "$TEST_CASE" || { echo "ERROR: Could not enter case directory: $TEST_CASE" >&2; exit 1; }

# --- Run parallel renumberMesh to optimize intra-rank matrix bandwidth after scotch decomposition
renumberLog="${outputDir}/renumberMesh-parallel.log"
echo "Running parallel renumberMesh across $nProcs MPI ranks ..."
srun -l -u \
   -N "$NODES" \
   -n "$nProcs" \
   -c "${SLURM_CPUS_PER_TASK:-1}" \
   --ntasks-per-node="$TASKS_PER_NODE" \
   "${solverCommandPrefix[@]}" \
   renumberMesh -parallel -fileHandler collated -overwrite -constant 2>&1 | tee "$renumberLog"
renumberStatus=${PIPESTATUS[0]}
[[ $renumberStatus -eq 0 ]] || {
   echo "ERROR: Parallel renumberMesh failed with exit status $renumberStatus" >&2
   exit 1
}
echo "PASS: Parallel renumberMesh completed"
echo

# --- Configure system/controlDict for native wall-clock bounded execution
# Configure OpenFOAM from the start to stop after solverSeconds of wall-clock
# time using stopAt=nextWrite, writeControl=clockTime, and
# writeInterval=solverSeconds, with runTimeModifiable=false so OpenFOAM never
# polls dictionary modification timestamps on Lustre at each time step.
cp -f system/controlDict system/controlDict.bak
srun -N 1 -n 1 -c 1 "${solverCommandPrefix[@]}" \
   foamDictionary system/controlDict -entry stopAt -set nextWrite >/dev/null
srun -N 1 -n 1 -c 1 "${solverCommandPrefix[@]}" \
   foamDictionary system/controlDict -entry endTime -set 1000000 >/dev/null
srun -N 1 -n 1 -c 1 "${solverCommandPrefix[@]}" \
   foamDictionary system/controlDict -entry writeControl -set clockTime >/dev/null
srun -N 1 -n 1 -c 1 "${solverCommandPrefix[@]}" \
   foamDictionary system/controlDict -entry writeInterval -set "$solverSeconds" >/dev/null
srun -N 1 -n 1 -c 1 "${solverCommandPrefix[@]}" \
   foamDictionary system/controlDict -entry runTimeModifiable -set false >/dev/null
echo "PASS: controlDict configured with stopAt=nextWrite, writeControl=clockTime, writeInterval=${solverSeconds}s, runTimeModifiable=false"
echo

# --- Execute pimpleFoam in parallel
LOGFILE="${outputDir}/${SOLVER}.log"
echo "Starting $SOLVER on $NODES node(s), $TASKS_PER_NODE tasks/node ($nProcs total cores, $cellsPerCore cells/core) ..."
srun -l -u \
   -N "$NODES" \
   -n "$nProcs" \
   -c "${SLURM_CPUS_PER_TASK:-1}" \
   --ntasks-per-node="$TASKS_PER_NODE" \
   "${solverCommandPrefix[@]}" \
   "$SOLVER" -parallel -fileHandler collated 2>&1 | tee "$LOGFILE"
solverStatus=${PIPESTATUS[0]}

[[ $solverStatus -eq 0 ]] || {
   echo "ERROR: $SOLVER returned exit status $solverStatus" >&2
   exit 1
}
[[ -s "$LOGFILE" ]] || { echo "ERROR: Solver log is empty: $LOGFILE" >&2; exit 1; }
grep -qE 'FOAM FATAL (ERROR|IO ERROR)' "$LOGFILE" && {
   echo "ERROR: $SOLVER reported an OpenFOAM fatal error" >&2
   exit 1
}

# --- Compute per-time-step ExecutionTime metrics from $LOGFILE
# OpenFOAM prints cumulative ExecutionTime at the end of every time step.
# To exclude both start-up transient / initial caching overhead and any final
# write / teardown effects at the end of the run, the steady strong-scaling
# average skips the first 10% of completed steps (at least step 1) and the
# final 5 steps whenever sufficient steps were completed.
metricsFile="${outputDir}/scaling-metrics.env"
awk -v ofFork="$OPENFOAM_FORK" \
    -v ofVersion="$OPENFOAM_VERSION" \
    -v runtimeKey="$runtimeKey" \
    -v nodes="$NODES" \
    -v tpn="$TASKS_PER_NODE" \
    -v cores="$nProcs" \
    -v cells="$ACTUAL_CELLS" \
    -v cellsPerCore="$cellsPerCore" \
    -v targetMillions="$TARGET_CELLS_MILLIONS" \
    -v metricsOut="$metricsFile" '
/ExecutionTime =/ {
   for (i = 1; i <= NF; i++) {
      if ($i == "ExecutionTime" && $(i+1) == "=") {
         cumTime[++nSteps] = $(i+2) + 0.0
      }
      if ($i == "ClockTime" && $(i+1) == "=") {
         clockTime[nSteps] = $(i+2) + 0.0
      }
   }
}
END {
   if (nSteps == 0) {
      print "ERROR: No completed time steps (ExecutionTime lines) found in solver log." > "/dev/stderr"
      exit 1
   }
   step1Time = cumTime[1]
   totalExecTime = cumTime[nSteps]
   totalClockTime = clockTime[nSteps]

   skipFirst = int(nSteps * 0.10 + 0.5)
   if (skipFirst < 1) skipFirst = 1
   skipLast = 5

   startStep = skipFirst + 1
   endStep = nSteps - skipLast

   # Fallback if the run was very short and skipping both leaves no steps:
   if (startStep > endStep) {
      if (nSteps >= 2) {
         startStep = 2
         endStep = nSteps
      } else {
         startStep = 1
         endStep = 1
      }
   }

   if (startStep >= 2) {
      statSteps = endStep - startStep + 1
      sum = 0.0; sumSq = 0.0
      minDt = 1e30; maxDt = 0.0
      for (s = startStep; s <= endStep; s++) {
         dt = cumTime[s] - cumTime[s-1]
         sum += dt
         sumSq += dt * dt
         if (dt < minDt) minDt = dt
         if (dt > maxDt) maxDt = dt
      }
      meanDt = sum / statSteps
      variance = (sumSq / statSteps) - (meanDt * meanDt)
      if (variance < 0) variance = 0
      stdDt = sqrt(variance)
   } else {
      statSteps = 1
      meanDt = step1Time
      minDt = step1Time
      maxDt = step1Time
      stdDt = 0.0
   }

   printf "======================================================\n"
   printf "Strong-Scaling Step-Timing Summary (%d cores on %d nodes)\n", cores, nodes
   printf "======================================================\n"
   printf "Mesh cells                   : %d (~%sM)\n", cells, targetMillions
   printf "Nodes x Tasks/node           : %d x %d = %d cores\n", nodes, tpn, cores
   printf "Cells per core               : %s\n", cellsPerCore
   printf "Total time steps completed   : %d\n", nSteps
   printf "Step 1 ExecutionTime (s)     : %.4f\n", step1Time
   printf "Skipped initial steps (10%%)  : %d\n", startStep - 1
   printf "Skipped final steps          : %d\n", nSteps - endStep
   printf "Steps used for average       : %d (steps %d..%d)\n", statSteps, startStep, endStep
   printf "Mean ExecutionTime/step (s)  : %.4f\n", meanDt
   printf "Std  ExecutionTime/step (s)  : %.4f\n", stdDt
   printf "Min  ExecutionTime/step (s)  : %.4f\n", minDt
   printf "Max  ExecutionTime/step (s)  : %.4f\n", maxDt
   printf "Final cumulative ExecTime (s): %.2f (ClockTime: %.0fs)\n", totalExecTime, totalClockTime
   printf "======================================================\n"

   printf "OPENFOAM_FORK=%s\n", ofFork > metricsOut
   printf "OPENFOAM_VERSION=%s\n", ofVersion >> metricsOut
   printf "RUNTIME_KEY=%s\n", runtimeKey >> metricsOut
   printf "NODES=%d\n", nodes >> metricsOut
   printf "TASKS_PER_NODE=%d\n", tpn >> metricsOut
   printf "CORES=%d\n", cores >> metricsOut
   printf "X_LABEL=\"%d (%d)\"\n", cores, nodes >> metricsOut
   printf "TARGET_CELLS_MILLIONS=%s\n", targetMillions >> metricsOut
   printf "ACTUAL_CELLS=%d\n", cells >> metricsOut
   printf "CELLS_PER_CORE=%s\n", cellsPerCore >> metricsOut
   printf "TOTAL_STEPS=%d\n", nSteps >> metricsOut
   printf "STAT_START_STEP=%d\n", startStep >> metricsOut
   printf "STAT_END_STEP=%d\n", endStep >> metricsOut
   printf "STAT_STEPS=%d\n", statSteps >> metricsOut
   printf "STEP1_TIME_S=%.6f\n", step1Time >> metricsOut
   printf "MEAN_STEP_TIME_S=%.6f\n", meanDt >> metricsOut
   printf "STD_STEP_TIME_S=%.6f\n", stdDt >> metricsOut
   printf "MIN_STEP_TIME_S=%.6f\n", minDt >> metricsOut
   printf "MAX_STEP_TIME_S=%.6f\n", maxDt >> metricsOut
   printf "TOTAL_EXEC_TIME_S=%.2f\n", totalExecTime >> metricsOut
   printf "TOTAL_CLOCK_TIME_S=%.0f\n", totalClockTime >> metricsOut
}' "$LOGFILE" || {
   echo "ERROR: Failed to extract step-timing metrics from $LOGFILE" >&2
   exit 1
}

echo
echo "Metrics saved to: $metricsFile"
echo "ALL STEPS PASSED: Strong-scaling solver benchmark completed successfully."
exit 0

