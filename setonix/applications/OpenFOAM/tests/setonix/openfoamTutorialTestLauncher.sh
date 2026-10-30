#!/bin/bash --login
# General launcher for version-specific OpenFOAM tutorial functional tests.
#
# This script provides one entry point for a complete tutorial test associated
# with an OpenFOAM version. The version-specific behavior remains in three stage
# scripts selected through --recipe-dir or the explicit --scripts-dir option:
#
#   1. extractCase.sh extracts and validates a clean tutorial case.
#   2. preFoam.slurm.sh prepares and decomposes the case in a Slurm job.
#   3. runFoam.slurm.sh runs and validates the solver in a dependent Slurm job.
#
# The launcher accepts exactly one runtime mode and passes the corresponding
# runtime arguments to all three stages. Explicit-image mode also passes the
# selected Singularity module:
#
#   --image <file>  uses an explicit Singularity image;
#   --shpc          uses <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>;
#   --bare-metal    uses <OPENFOAM_FORK>/<OPENFOAM_VERSION>.
#
# The launcher does not load the selected OpenFOAM module itself. Extraction
# loads its runtime in the current launcher process, while each submitted Slurm
# script loads the same selected runtime independently inside its own job.
#
# The launcher creates one persistent artifact directory for the invocation and
# passes it to every stage. It also supplies one shared host work root, submits
# the solver with an afterok dependency on preparation, waits for both jobs
# unless --submit-only is used, and reports one overall PASS or FAIL result.
# Each version-specific script remains responsible for validating its own stage
# and returning a nonzero exit status when that stage fails.
#
# Expected version-directory layout:
#
#   <recipe-dir>/
#       |-- buildAndValidationConfig/
#       |   `-- openfoamBuildAndValidation.config
#       `-- tutorialTest/
#           |-- extractCase.sh
#           |-- preFoam.slurm.sh
#           `-- runFoam.slurm.sh
#
# Examples:
#
# Explicit Singularity image:
#   ./openfoamTutorialTestLauncher.sh \
#      --recipe-dir openfoam/v2406 \
#      --image /path/to/openfoam--v2406-image.sif
#
# SHPC container module:
#   ./openfoamTutorialTestLauncher.sh \
#      --recipe-dir openfoam/v2406 \
#      --shpc
#
# Bare-metal OpenFOAM module with an explicit reusable work root:
#   ./openfoamTutorialTestLauncher.sh \
#      --recipe-dir openfoam/v2406 \
#      --bare-metal \
#      --work-root "$MYSCRATCH/OpenFOAM-functional-tests/v2406-manual" \
#      --overwrite
#
# Exit status:
#   0  Extraction, preparation, and solver execution all passed, or both Slurm
#      jobs were accepted successfully when --submit-only was requested.
#   1  Invalid input, extraction failure, submission failure, accounting
#      failure, or any version-specific tutorial stage failed.

# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

# Treat any use of an unset variable as an error.
set -u

# --- Initial settings
thisScript=$(basename "$0")
scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
recipeDirInput=""
configFileInput=""
scriptsDirInput=""
imageInput=""
singularityModule="singularity/4.3.5-mpi"
singularityModuleSpecified=false
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
  $thisScript --config <file> --scripts-dir <directory> --image <file> [options]
  $thisScript --config <file> --scripts-dir <directory> --shpc [options]
  $thisScript --config <file> --scripts-dir <directory> --bare-metal [options]
  $thisScript --help

Test-location selection (choose one complete mode):
  --recipe-dir, -r <directory>  OpenFOAM version directory containing
                                buildAndValidationConfig/ and tutorialTest/
  --config <file>               Explicit version configuration file; requires
                                --scripts-dir and cannot be used with --recipe-dir
  --scripts-dir <directory>     Directory containing the three stage scripts;
                                requires --config and cannot be used with
                                --recipe-dir

Runtime selection (choose exactly one):
  --image, -i <file>            Use the supplied Singularity image
  --singularity-module <module>  Singularity module for --image mode, or an
                                explicit override applied after loading the
                                SHPC OpenFOAM module. Plain --shpc retains the
                                SHPC-provided Singularity module.
                                Default for --image: singularity/4.3.5-mpi
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
extractCase.sh, preFoam.slurm.sh, and runFoam.slurm.sh:
  --work-root <directory>
  --config <file>
  --test-artifacts-dir <directory>

The launcher does not load an OpenFOAM module. Each stage establishes its own
runtime environment. Slurm resources remain defined by the version-specific
preFoam.slurm.sh and runFoam.slurm.sh scripts.
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
   [[ -z "$configFileInput" && -z "$scriptsDirInput" ]] || {
      echo "ERROR: --recipe-dir cannot be used with --config or --scripts-dir" >&2
      usage >&2
      exit 1
   }
   [[ -d "$recipeDirInput" ]] || { echo "ERROR: Recipe directory not found: $recipeDirInput" >&2; exit 1; }
   recipeDir=$(realpath "$recipeDirInput")
   configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
   tutorialScriptDir="${recipeDir}/tutorialTest"
elif [[ -n "$configFileInput" || -n "$scriptsDirInput" ]]; then
   [[ -n "$configFileInput" && -n "$scriptsDirInput" ]] || {
      echo "ERROR: --config and --scripts-dir must be provided together" >&2
      usage >&2
      exit 1
   }
   [[ -r "$configFileInput" ]] || { echo "ERROR: Configuration is not readable: $configFileInput" >&2; exit 1; }
   [[ -d "$scriptsDirInput" ]] || { echo "ERROR: Scripts directory not found: $scriptsDirInput" >&2; exit 1; }
   configFile=$(realpath "$configFileInput")
   tutorialScriptDir=$(realpath "$scriptsDirInput")
   recipeDir=$(dirname "$tutorialScriptDir")
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

runtimeSelectorCount=0
[[ -n "$imageInput" ]] && ((runtimeSelectorCount += 1))
[[ "$useSHPC" == true ]] && ((runtimeSelectorCount += 1))
[[ "$useBareMetal" == true ]] && ((runtimeSelectorCount += 1))
[[ $runtimeSelectorCount -eq 1 ]] || { echo "ERROR: Choose exactly one of --image <file>, --shpc, or --bare-metal" >&2; exit 1; }

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

# --- Locate and validate the version-specific stage scripts
extractScript="${tutorialScriptDir}/extractCase.sh"
preScript="${tutorialScriptDir}/preFoam.slurm.sh"
runScript="${tutorialScriptDir}/runFoam.slurm.sh"

[[ -d "$tutorialScriptDir" ]] || {
   echo "ERROR: Tutorial-test directory not found: $tutorialScriptDir" >&2
   exit 1
}
if [[ "$singularityModuleSpecified" == true && "$useBareMetal" == true ]]; then
   echo "ERROR: --singularity-module cannot be used with --bare-metal" >&2
   usage >&2
   exit 1
fi

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
tutorialArtifactsDir="${recipeDir}/artifacts/tests/tutorial"
mkdir -p "$tutorialArtifactsDir"
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
   workRoot="${baseWorkDir}/OpenFOAM-functional-tests/${USER}-${OPENFOAM_VERSION}/${runId}"
fi
outputDir="$runArtifactsDir"
mkdir -p "$workRoot"

# Report the complete resolved test context consistently in persistent details,
# submission summaries, and final success or failure summaries.
emitResolvedContext() {
   echo "Version directory: $recipeDir"
   echo "Configuration: $configFile"
   echo "Tutorial scripts: $tutorialScriptDir"
   echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
   echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
   echo "Runtime mode: $runtimeMode"

   if [[ -n "$SINGULARITY_IMAGE" ]]; then
      echo "SIF image: $SINGULARITY_IMAGE"
      echo "SIF SHA256: $imageChecksum"
      echo "Singularity module: $singularityModule"
   elif [[ "$useSHPC" == true ]]; then
      echo "SHPC module: $shpcModule"
      if [[ "$singularityModuleSpecified" == true ]]; then
         echo "SHPC Singularity override: $singularityModule"
      else
         echo "SHPC Singularity override: none"
      fi
   else
      echo "Bare-metal module: $bareMetalModule"
   fi

   echo "Work root: $workRoot"
   echo "Output directory: $outputDir"
   echo "Launcher mode: $([[ "$submitOnly" == true ]] && echo "submit only" || echo "submit and wait")"
   echo "Overwrite case: $([[ "$overwriteCase" == true ]] && echo "yes" || echo "no")"
   echo "Partition override: ${partitionInput:-none}"
   echo "Reservation: ${reservationInput:-none}"
}

workOutputPath="${workRoot}/test-output"
if [[ -e "$workOutputPath" && ! -L "$workOutputPath" ]]; then
   echo "ERROR: Refusing to replace non-symbolic-link output path: $workOutputPath" >&2
   echo "       Select another --work-root or remove the existing path deliberately." >&2
   exit 1
fi
ln -sfn "$outputDir" "$workOutputPath"
{
   echo "Test timestamp: $runTimestamp"
   emitResolvedContext
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
# Resource options are intentionally absent. Nodes, tasks, CPUs, memory, and time
# remain in the version-specific Slurm scripts.
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
echo "Launcher directory: $scriptDir"
emitResolvedContext
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
# The version-specific script controls its own Slurm resources. The launcher only
# supplies shared inputs and optional partition or reservation overrides.
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
   {
      echo "Result: SUBMITTED"
      emitResolvedContext
      echo "Preparation job: $preJobId"
      echo "Solver job: $runJobId"
      echo "Solver dependency: afterok:$preJobId"
   } > "$testSummaryFile"
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
# A job can leave squeue before sacct has updated its parent record to a terminal
# state. Retry both missing and nonterminal accounting records for up to 12
# attempts using the configured polling interval.
getJobResult() {
   local jobId="$1"
   local attempt
   local result=""
   local state=""
   local exitCode=""
   local baseState=""

   for ((attempt = 1; attempt <= 12; attempt++)); do
      result=$(sacct --noheader --parsable2 --jobs="$jobId" \
         --format=JobIDRaw,State,ExitCode 2>/dev/null | \
         awk -F'|' -v id="$jobId" '$1 == id { print $2 "|" $3; exit }')

      if [[ -n "$result" ]]; then
         IFS='|' read -r state exitCode <<< "$result"
         baseState=${state%%+}

         case "$baseState" in
            PENDING|RUNNING|CONFIGURING|COMPLETING|RESIZING|SUSPENDED|REQUEUED|REQUEUE_FED|REQUEUE_HOLD|SIGNALING|STAGE_OUT)
               ;;
            *)
               printf '%s\n' "$result"
               return 0
               ;;
         esac
      fi

      if ((attempt < 12)); then
         sleep "$pollInterval"
      fi
   done

   return 1
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
emitResolvedContext
echo "Extraction: exitStatus=$extractStatus"
echo "Preparation job: $preJobId ($preState, $preExitCode)"
echo "Solver job: $runJobId ($runState, $runExitCode)"

if [[ $FAILED -ne 0 ]]; then
   {
      echo "Result: FAILED"
      emitResolvedContext
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
   emitResolvedContext
   echo "Extraction exit status: $extractStatus"
   echo "Preparation job: $preJobId ($preState, $preExitCode)"
   echo "Solver job: $runJobId ($runState, $runExitCode)"
} > "$testSummaryFile"
echo "Result summary: $testSummaryFile"
echo "RESULT: PASS"
echo "ALL STAGES PASSED: OpenFOAM tutorial functional test completed successfully."
exit 0
