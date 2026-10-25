#!/bin/bash --login
# Launcher for the side-by-side central OpenFOAM tutorial workflows.
#
# This script provides one entry point for a complete tutorial test associated
# with an OpenFOAM version. Version-specific behavior is declared in the central
# config; stage implementations are shared under tutorial/:
#
#   1. extractCase.central.sh extracts and validates a clean tutorial case.
#   2. preFoam.central.slurm.sh prepares the case in a Slurm job.
#   3. runFoam.central.slurm.sh executes the configured run workflow.
#
# The launcher accepts exactly one runtime selection and passes it unchanged to
# all three stages:
#
#   --image <file>  uses an explicit Singularity image;
#   --shpc          uses <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>;
#   --bare-metal    uses <OPENFOAM_FORK>/<OPENFOAM_VERSION>.
#
# The launcher does not load the selected OpenFOAM module itself. Extraction
# loads its runtime in a child process, while each submitted Slurm
# script loads the same selected runtime independently inside its own job.
#
# The launcher creates one persistent artifact directory for the invocation and
# passes it to every stage. It also supplies one shared host work root, submits
# the solver with an afterok dependency on preparation, waits for both jobs
# unless --submit-only is used, and reports one overall PASS or FAIL result.
# Each shared stage remains responsible for validating its configured operations
# and returning a nonzero exit status when that stage fails.
#
# Expected version-directory layout:
#
#   <recipe-dir>/
#       `-- buildAndValidationConfig/
#       `-- openfoamBuildAndValidation.central.config
#
# Examples:
#
# Explicit Singularity image:
#   ./openfoamTutorialTestLauncher.central.sh \
#      --recipe-dir openfoam/v2406 \
#      --image /path/to/openfoam--v2406-image.sif
#
# SHPC container module:
#   ./openfoamTutorialTestLauncher.central.sh \
#      --recipe-dir openfoam/v2406 \
#      --shpc
#
# Bare-metal OpenFOAM module with an explicit reusable work root:
#   ./openfoamTutorialTestLauncher.central.sh \
#      --recipe-dir openfoam/v2406 \
#      --bare-metal \
#      --work-root "$MYSCRATCH/OpenFOAM-functional-tests-central/v2406-manual" \
#      --overwrite
#
# Exit status:
#   0  Extraction, preparation, and solver execution all passed, or both Slurm
#      jobs were accepted successfully when --submit-only was requested.
#   1  Invalid input, extraction failure, submission failure, accounting
#      failure, or any configured tutorial stage failed.

# Central development variant: validate with mocks before site-level Slurm tests.

# Treat any use of an unset variable as an error.
set -u

# --- Initial settings
thisScript=$(basename "$0")
scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
recipeDirInput=""
configFileInput=""
scriptsDirInput=""
artifactsDirInput=""
recipeDir=""
imageInput=""
useSHPC=false
useBareMetal=false
workRootInput=""
configFile=""
tutorialArtifactsDir=""
runArtifactsDir=""
runLog=""
statusFile=""
testDetailsFile=""
testSummaryFile=""
overwriteCase=false
partitionInput="${PARTITION:-}"
reservationInput="${RESERVATION:-}"
pollInterval=${POLL_INTERVAL_SECONDS:-20}
submitOnly=false

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  $thisScript --recipe-dir <directory> --image <file> [options]
  $thisScript --recipe-dir <directory> --shpc [options]
  $thisScript --recipe-dir <directory> --bare-metal [options]
  $thisScript --config <file> --image <file> [options]
  $thisScript --config <file> --shpc [options]
  $thisScript --config <file> --bare-metal [options]
  $thisScript --help

Test-location selection (choose one complete mode):
  --recipe-dir, -r <directory>  OpenFOAM version directory containing
                                buildAndValidationConfig/openfoamBuildAndValidation.central.config
  --config <file>               Explicit central workflow config; cannot be
                                combined with --recipe-dir
  --scripts-dir <directory>     Override the shared tutorial/ script directory.
                                Only .central stage/library names are used.
  --artifacts-dir <directory>   Override artifact root (relative to launch directory).
                                Required for configs outside the recipe layout.

Runtime selection (choose exactly one):
  --image, -i <file>            Use the supplied Singularity image
  --shpc                        Use the container module derived from the config:
                                <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>
  --bare-metal                  Use the bare-metal module derived from the config:
                                <OPENFOAM_FORK>/<OPENFOAM_VERSION>

Optional settings:
  --work-root, -w <directory>   Host work root shared by all three stages. By
                                default, an isolated directory is created under
                                MYSCRATCH, TMPDIR, or HOME.
  --partition, -p <name>        Override the partition in both Slurm scripts
  --reservation <name>          Submit both Slurm jobs using this reservation
  --submit-only                 Submit both jobs and return without waiting
  --overwrite                   Replace an existing extracted case when
                                intentionally reusing --work-root
  --help, -h                    Show this help message and exit

The launcher passes the selected runtime option and these common settings to
extractCase.central.sh, preFoam.central.slurm.sh, and runFoam.central.slurm.sh:
  --work-root <directory>
  --config <file>
  --test-artifacts-dir <directory>

The launcher does not load an OpenFOAM module. Each stage establishes its own
runtime environment. Configured Slurm resources are passed explicitly to sbatch.
Defaults are isolated under artifacts/tests/tutorial-central and
OpenFOAM-functional-tests-central; original tutorial outputs are not replaced.
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
      --config)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --config requires <file>" >&2; usage >&2; exit 1; }
         configFileInput="$2"
         shift 2
         ;;
      --scripts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --scripts-dir requires <directory>" >&2; usage >&2; exit 1; }
         scriptsDirInput="$2"
         shift 2
         ;;
      --artifacts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --artifacts-dir requires <directory>" >&2; usage >&2; exit 1; }
         artifactsDirInput="$2"
         shift 2
         ;;
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
      --partition|-p)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --partition requires <name>" >&2; usage >&2; exit 1; }
         partitionInput="$2"
         shift 2
         ;;
      --submit-only)
         submitOnly=true
         shift
         ;;
      --reservation)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --reservation requires <name>" >&2; usage >&2; exit 1; }
         reservationInput="$2"
         shift 2
         ;;
      --overwrite)
         overwriteCase=true
         shift
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

# --- Resolve and validate the test location and configuration
if [[ -n "$recipeDirInput" ]]; then
   [[ -z "$configFileInput" ]] || {
      echo "ERROR: --recipe-dir cannot be used with --config" >&2
      usage >&2
      exit 1
   }
   [[ -d "$recipeDirInput" ]] || { echo "ERROR: Recipe directory not found: $recipeDirInput" >&2; exit 1; }
   recipeDir=$(realpath "$recipeDirInput")
   configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.central.config"
elif [[ -n "$configFileInput" ]]; then
   [[ -r "$configFileInput" ]] || { echo "ERROR: Configuration is not readable: $configFileInput" >&2; exit 1; }
   configFile=$(realpath "$configFileInput")
   configDir=$(dirname "$configFile")
   if [[ $(basename "$configDir") == buildAndValidationConfig ]]; then
      recipeDir=$(dirname "$configDir")
   elif [[ -z "$artifactsDirInput" ]]; then
      echo "ERROR: Config outside recipe layout requires --artifacts-dir" >&2
      exit 1
   fi
else
   echo "ERROR: Provide --recipe-dir or --config" >&2
   usage >&2
   exit 1
fi
[[ -r "$configFile" ]] || { echo "ERROR: Configuration is not readable: $configFile" >&2; exit 1; }
configFile=$(realpath "$configFile")
tutorialScriptDir="${scriptsDirInput:-${scriptDir}/tutorial}"
[[ -d "$tutorialScriptDir" ]] || { echo "ERROR: Scripts directory not found: $tutorialScriptDir" >&2; exit 1; }
tutorialScriptDir=$(realpath "$tutorialScriptDir")
commonLibrary="${tutorialScriptDir}/tutorialTestCommon.central.sh"
[[ -r "$commonLibrary" ]] || { echo "ERROR: Central library not found: $commonLibrary" >&2; exit 1; }
# shellcheck source=/dev/null
source "$commonLibrary"
central_load_config "$configFile" || exit 1

runtimeSelectorCount=0
[[ -n "$imageInput" ]] && ((runtimeSelectorCount += 1))
[[ "$useSHPC" == true ]] && ((runtimeSelectorCount += 1))
[[ "$useBareMetal" == true ]] && ((runtimeSelectorCount += 1))
[[ $runtimeSelectorCount -eq 1 ]] || { echo "ERROR: Choose exactly one of --image <file>, --shpc, or --bare-metal" >&2; exit 1; }

SINGULARITY_CONTAINER=""
imageChecksum=""
shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
if [[ -n "$imageInput" ]]; then
   [[ -f "$imageInput" ]] || { echo "ERROR: Image not found: $imageInput" >&2; exit 1; }
   SINGULARITY_CONTAINER=$(realpath "$imageInput")
   imageChecksum=$(sha256sum "$SINGULARITY_CONTAINER" | awk '{print $1}')
   runtimeMode="Explicit Singularity image"
   runtimeOption=(--image "$SINGULARITY_CONTAINER")
   artifactRuntimeName="singularity"
elif [[ "$useSHPC" == true ]]; then
   runtimeMode="SHPC module"
   runtimeOption=(--shpc)
   artifactRuntimeName="shpc"
else
   runtimeMode="Bare-metal module"
   runtimeOption=(--bare-metal)
   artifactRuntimeName="bare-metal"
fi

# --- Locate and validate the version-specific stage scripts
extractScript="${tutorialScriptDir}/extractCase.central.sh"
preScript="${tutorialScriptDir}/preFoam.central.slurm.sh"
runScript="${tutorialScriptDir}/runFoam.central.slurm.sh"

[[ -d "$tutorialScriptDir" ]] || {
   echo "ERROR: Tutorial-test directory not found: $tutorialScriptDir" >&2
   exit 1
}

for requiredScript in "$extractScript" "$preScript" "$runScript"; do
   [[ -f "$requiredScript" ]] || {
      echo "ERROR: Required tutorial script not found: $requiredScript" >&2
      exit 1
   }
   bash -n "$requiredScript" || {
      echo "ERROR: Bash syntax check failed: $requiredScript" >&2
      exit 1
   }
done

[[ -x "$extractScript" ]] || {
   echo "ERROR: Extraction script is not executable: $extractScript" >&2
   exit 1
}

# --- Create persistent artifacts and the shared case workspace
runTimestamp=$(date '+%Y%m%dT%H%M%S%z')
runId="${CI_PIPELINE_ID:-${runTimestamp}_$$}"
if [[ -n "$artifactsDirInput" ]]; then
   tutorialArtifactsDir=$(realpath -m "$artifactsDirInput")
else
   tutorialArtifactsDir="${recipeDir}/artifacts/tests/tutorial-central"
fi
mkdir -p "$tutorialArtifactsDir" || { echo "ERROR: Could not create artifact root: $tutorialArtifactsDir" >&2; exit 1; }
latestLink="${tutorialArtifactsDir}/latest"
if [[ -e "$latestLink" && ! -L "$latestLink" ]]; then
   echo "ERROR: Refusing to remove non-symbolic-link path: $latestLink" >&2
   exit 1
fi
rm -f "$latestLink" || { echo "ERROR: Failed to remove latest link: $latestLink" >&2; exit 1; }
echo "This directory contains timestamped tutorial-test artifacts. The latest link identifies the most recent tracked test invocation. If the link is absent, the most recent command failed before invocation tracking was established." > "${tutorialArtifactsDir}/README.txt"
# Include the runtime type in the invocation directory without embedding module
# names or image paths in filesystem names.
runArtifactsName="${runId}_${artifactRuntimeName}"
runArtifactsDir="${tutorialArtifactsDir}/${runArtifactsName}"
mkdir "$runArtifactsDir" || { echo "ERROR: Could not create artifact directory: $runArtifactsDir" >&2; exit 1; }
ln -sfn "$runArtifactsName" "$latestLink"
runLog="${runArtifactsDir}/launcher.run.log"
statusFile="${runArtifactsDir}/status.txt"
testDetailsFile="${runArtifactsDir}/test-details.txt"
testSummaryFile="${runArtifactsDir}/test-summary.txt"
printf '%s
' RUNNING > "$statusFile"
record_test_status() {
   local exitStatus=$?
   trap - EXIT
   if [[ $exitStatus -eq 0 ]]; then printf '%s
' SUCCESS > "$statusFile"; else printf '%s
' FAILED > "$statusFile"; fi
   exit "$exitStatus"
}
trap record_test_status EXIT
exec > >(tee "$runLog") 2>&1

if [[ -n "$workRootInput" ]]; then
   workRoot=$(realpath -m "$workRootInput")
else
   baseWorkDir=${MYSCRATCH:-${TMPDIR:-$HOME}}
   workRoot="${baseWorkDir}/OpenFOAM-functional-tests-central/${USER}-${OPENFOAM_VERSION}/${runId}"
fi
outputDir="$runArtifactsDir"
mkdir -p "$workRoot" || { echo "ERROR: Could not create work root: $workRoot" >&2; exit 1; }
workOutputPath="${workRoot}/test-output.central"
if [[ -e "$workOutputPath" && ! -L "$workOutputPath" ]]; then
   echo "ERROR: Refusing to replace non-symbolic-link output path: $workOutputPath" >&2
   echo "       Select another --work-root or remove the existing path deliberately." >&2
   exit 1
fi
ln -sfn "$outputDir" "$workOutputPath"
{
   echo "Test timestamp: $runTimestamp"
   echo "Configuration: $configFile"
   echo "Recipe directory: $recipeDir"
   echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
   echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
   echo "Runtime mode: $runtimeMode"
   [[ -n "$SINGULARITY_CONTAINER" ]] && { echo "Runtime mode: $runtimeMode"; [[ -n "$SINGULARITY_CONTAINER" ]] && { echo "SIF image: $SINGULARITY_CONTAINER"; echo "SIF SHA256: $imageChecksum"; }; [[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"; [[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"; }
   [[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"
   [[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"
   echo "Work root: $workRoot"
} > "$testDetailsFile"

# --- Verify the Slurm commands required by the launcher
requiredSlurmCommands=(sbatch)
if [[ "$submitOnly" != true ]]; then requiredSlurmCommands+=(squeue sacct); fi
for commandName in "${requiredSlurmCommands[@]}"; do
   command -v "$commandName" >/dev/null 2>&1 || {
      echo "ERROR: $commandName not found. Run this launcher on a Slurm login node." >&2
      exit 1
   }
done

# --- Build optional site-level Slurm submission overrides
# Resource settings are validated from the same config used by each job.
submissionOverrides=()
if [[ -n "$partitionInput" ]]; then
   submissionOverrides+=(--partition="$partitionInput")
fi
if [[ -n "$reservationInput" ]]; then
   submissionOverrides+=(--reservation="$reservationInput")
fi

# --- Display the fully resolved test plan
echo "============================================================"
echo "OpenFOAM tutorial functional-test launcher"
echo "============================================================"
echo "Launcher directory : $scriptDir"
echo "Version directory  : $recipeDir"
echo "Tutorial scripts   : $tutorialScriptDir"
echo "Runtime mode       : $runtimeMode"
[[ -n "$SINGULARITY_CONTAINER" ]] && echo "Image              : $SINGULARITY_CONTAINER"
[[ "$useSHPC" == true ]] && echo "SHPC module        : $shpcModule"
[[ "$useBareMetal" == true ]] && echo "Bare-metal module  : $bareMetalModule"
echo "Work root          : $workRoot"
echo "Output directory   : $outputDir"
echo "Launcher mode      : $([[ "$submitOnly" == true ]] && echo "submit only" || echo "submit and wait")"
if [[ "$overwriteCase" == "true" ]]; then
   echo "Overwrite case     : yes"
else
   echo "Overwrite case     : no"
fi
if [[ -n "$partitionInput" ]]; then
   echo "Partition override : $partitionInput"
else
   echo "Partition override : none"
fi
if [[ -n "$reservationInput" ]]; then
   echo "Reservation        : $reservationInput"
else
   echo "Reservation        : none"
fi
echo

# --- Stage 1: Extract and validate the tutorial case in the selected runtime
# The extraction script records its complete output in extractCase.run.log.
# Its output is also inherited by the launcher and recorded in launcher.run.log.
# Build the extraction arguments from the common runtime-selection array so the
# extraction stage receives exactly the mode selected for this invocation.
extractArgs=(
   "${runtimeOption[@]}"
   --work-root "$workRoot"
   --config "$configFile"
   --test-artifacts-dir "$outputDir"
)

if [[ "$overwriteCase" == "true" ]]; then
   extractArgs+=(--overwrite)
fi

echo "$thisScript: -----------------------------------------"
echo "Stage 1 - Extracting the version-specific tutorial case"

"$extractScript" "${extractArgs[@]}"
extractStatus=$?

if [[ $extractStatus -ne 0 ]]; then
   echo "RESULT: FAIL" >&2
   echo "Extraction failed with exit status $extractStatus" >&2
   echo "Log: ${outputDir}/extractCase.run.log" >&2
   exit 1
fi

echo "PASS: Tutorial extraction completed"
echo

# --- Stage 2: Submit preparation with the same runtime selection
# The launcher requests the config's resources as explicit sbatch options.
preOutput="${outputDir}/slurm-preFoam-%j.out"
echo "$thisScript: -----------------------------------------"
echo "Stage 2 - Submitting tutorial preparation"
# The Slurm job starts with a clean exported environment and receives the same
# runtime selector, work root, configuration, and artifact directory.
preSubmission=$(env \
   -u SLURM_MEM_PER_CPU \
   -u SLURM_MEM_PER_GPU \
   -u SLURM_MEM_PER_NODE \
   SLURM_EXPORT_ENV=ALL \
   sbatch --export=NONE --parsable \
   --nodes="$TUTORIAL_PRE_NODES" \
   --ntasks="$TUTORIAL_PRE_TASKS" \
   --cpus-per-task="$TUTORIAL_PRE_CPUS_PER_TASK" \
   --mem="$TUTORIAL_PRE_MEMORY" \
   --time="$TUTORIAL_PRE_TIME" \
   "${submissionOverrides[@]}" \
   --output="$preOutput" \
   "$preScript" \
   "${runtimeOption[@]}" \
   --work-root "$workRoot" \
   --config "$configFile" \
   --test-artifacts-dir "$outputDir") || {
      echo "ERROR: Failed to submit $preScript" >&2
      exit 1
   }
IFS=';' read -r preJobId _ <<< "$preSubmission"
[[ "$preJobId" =~ ^[0-9]+$ ]] || {
   echo "ERROR: Invalid preparation job ID returned by sbatch: $preSubmission" >&2
   exit 1
}
echo "Preparation job: $preJobId"
echo "Preparation log: ${outputDir}/slurm-preFoam-${preJobId}.out"
echo

# --- Stage 3: Submit the solver with the same runtime selection
# afterok prevents solver execution after a failed preparation. The invalid
# dependency option prevents the solver job from remaining pending indefinitely.
runOutput="${outputDir}/slurm-runFoam-%j.out"
echo "$thisScript: -----------------------------------------"
echo "Stage 3 - Submitting tutorial solver execution"
# The solver receives the identical runtime selector and starts only after the
# preparation job completes successfully.
runSubmission=$(env \
   -u SLURM_MEM_PER_CPU \
   -u SLURM_MEM_PER_GPU \
   -u SLURM_MEM_PER_NODE \
   SLURM_EXPORT_ENV=ALL \
   sbatch --export=NONE --parsable \
   --nodes="$TUTORIAL_RUN_NODES" \
   --ntasks="$TUTORIAL_RUN_TASKS" \
   --ntasks-per-node="$((TUTORIAL_RUN_TASKS / TUTORIAL_RUN_NODES))" \
   --cpus-per-task="$TUTORIAL_RUN_CPUS_PER_TASK" \
   --time="$TUTORIAL_RUN_TIME" \
   "${submissionOverrides[@]}" \
   --dependency="afterok:${preJobId}" \
   --kill-on-invalid-dep=yes \
   --output="$runOutput" \
   "$runScript" \
   "${runtimeOption[@]}" \
   --work-root "$workRoot" \
   --config "$configFile" \
   --test-artifacts-dir "$outputDir") || {
      echo "ERROR: Failed to submit $runScript" >&2
      exit 1
   }
IFS=';' read -r runJobId _ <<< "$runSubmission"
[[ "$runJobId" =~ ^[0-9]+$ ]] || {
   echo "ERROR: Invalid solver job ID returned by sbatch: $runSubmission" >&2
   exit 1
}
echo "Solver job: $runJobId"
echo "Solver dependency: afterok:$preJobId"
echo "Solver log: ${outputDir}/slurm-runFoam-${runJobId}.out"
echo

# Return immediately after both dependent jobs are accepted when requested.
if [[ "$submitOnly" == true ]]; then
   printf '%s
' SUBMITTED > "$statusFile"
   trap - EXIT
   { echo "Result: SUBMITTED"; echo "Runtime mode: $runtimeMode"; [[ -n "$SINGULARITY_CONTAINER" ]] && { echo "SIF image: $SINGULARITY_CONTAINER"; echo "SIF SHA256: $imageChecksum"; }; [[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"; [[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"; echo "Preparation job: $preJobId"; echo "Solver job: $runJobId"; echo "Solver dependency: afterok:$preJobId"; } > "$testSummaryFile"
   echo "RESULT: SUBMITTED"
   echo "The launcher will not wait for Slurm jobs $preJobId and $runJobId."
   exit 0
fi

# --- Stage 4: Wait for both Slurm jobs unless submission-only mode was requested
# A job remains active while squeue reports it as pending or running.
echo "$thisScript: -----------------------------------------"
echo "Stage 4 - Waiting for submitted jobs"
echo "Job IDs: $preJobId $runJobId"
echo "Polling Slurm every ${pollInterval} seconds"
while true; do
   activeJobs=0

   for jobId in "$preJobId" "$runJobId"; do
      if [[ -n "$(squeue --noheader --jobs="$jobId" 2>/dev/null)" ]]; then
         activeJobs=$((activeJobs + 1))
      fi
   done

   [[ $activeJobs -gt 0 ]] || break
   echo "Jobs still pending or running: $activeJobs"
   sleep "$pollInterval"
done

echo "All submitted jobs have left the queue."
echo

# --- Read a parent job's final Slurm state and exit code
# Accounting data may appear shortly after a job leaves squeue. Retry for one
# minute by default before treating the accounting result as unavailable.
getJobResult() {
   local jobId="$1"
   local attempt
   local result=""

   for ((attempt = 1; attempt <= 12; attempt++)); do
      result=$(sacct --noheader --parsable2 --jobs="$jobId" \
         --format=JobIDRaw,State,ExitCode 2>/dev/null | \
         awk -F'|' -v id="$jobId" '$1 == id { print $2 "|" $3; exit }')

      [[ -n "$result" ]] && break
      sleep "$pollInterval"
   done

   [[ -n "$result" ]] || return 1
   printf '%s\n' "$result"
}

# --- Stage 5: Evaluate preparation and solver results
FAILED=0
preResult=$(getJobResult "$preJobId") || preResult="UNAVAILABLE|UNAVAILABLE"
runResult=$(getJobResult "$runJobId") || runResult="UNAVAILABLE|UNAVAILABLE"
IFS='|' read -r preState preExitCode <<< "$preResult"
IFS='|' read -r runState runExitCode <<< "$runResult"

# Remove an optional suffix such as COMPLETED+ before comparing the state.
preBaseState=${preState%%+}
runBaseState=${runState%%+}

echo "$thisScript: -----------------------------------------"
echo "Stage 5 - Evaluating tutorial-test results"
echo "Preparation job $preJobId: state=$preState, exitCode=$preExitCode"
echo "Solver job      $runJobId: state=$runState, exitCode=$runExitCode"

if [[ "$preBaseState" != "COMPLETED" || "$preExitCode" != "0:0" ]]; then
   echo "FAIL: Tutorial preparation did not complete successfully" >&2
   FAILED=1
else
   echo "PASS: Tutorial preparation completed successfully"
fi

if [[ "$runBaseState" != "COMPLETED" || "$runExitCode" != "0:0" ]]; then
   echo "FAIL: Tutorial solver execution did not complete successfully" >&2
   FAILED=1
else
   echo "PASS: Tutorial solver execution completed successfully"
fi
echo

# --- Report the overall tutorial-test result
echo "============================================================"
echo "$thisScript: FINAL SUMMARY"
echo "============================================================"
echo "Version directory: $recipeDir"
echo "Runtime mode: $runtimeMode"
[[ -n "$SINGULARITY_CONTAINER" ]] && echo "Image: $SINGULARITY_CONTAINER"
[[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"
[[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"
echo "Work root: $workRoot"
echo "Output directory: $outputDir"
echo "Extraction: exitStatus=$extractStatus"
echo "Preparation job: $preJobId ($preState, $preExitCode)"
echo "Solver job: $runJobId ($runState, $runExitCode)"

if [[ $FAILED -ne 0 ]]; then
   {
      echo "Result: FAILED"
      echo "Extraction exit status: $extractStatus"
      echo "Preparation job: $preJobId ($preState, $preExitCode)"
      echo "Solver job: $runJobId ($runState, $runExitCode)"
   } > "$testSummaryFile"
   echo "RESULT: FAIL"
   echo "Inspect the logs under: $outputDir" >&2
   exit 1
fi
{
   echo "Result: SUCCESS"
   echo "Runtime mode: $runtimeMode"
   [[ -n "$SINGULARITY_CONTAINER" ]] && { echo "SIF image: $SINGULARITY_CONTAINER"; echo "SIF SHA256: $imageChecksum"; }
   [[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"
   [[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"
   echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
   echo "Extraction exit status: $extractStatus"
   echo "Preparation job: $preJobId ($preState, $preExitCode)"
   echo "Solver job: $runJobId ($runState, $runExitCode)"
   echo "Work root: $workRoot"
} > "$testSummaryFile"
echo "Result summary: $testSummaryFile"
echo "RESULT: PASS"
echo "ALL STAGES PASSED: OpenFOAM tutorial functional test completed successfully."
exit 0
