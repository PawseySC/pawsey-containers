#!/bin/bash --login
# General launcher for version-specific OpenFOAM tutorial functional tests.
#
# This script provides one friendly entry point for running the tutorial test
# associated with an OpenFOAM version directory. The tutorial itself remains
# fully version-specific: its case selection, OpenFOAM commands, Slurm resources,
# case adjustments, solver settings, and validation criteria are defined by the
# three scripts stored under <recipe-dir>/tutorialTest:
#
#   1. extractCase.sh runs directly and extracts a clean tutorial case.
#   2. preFoam.slurm.sh is submitted to prepare and decompose the case.
#   3. runFoam.slurm.sh is submitted with an afterok dependency on preparation.
#
# The launcher supplies only the selected image and a shared host work root. It
# waits for both Slurm jobs, obtains their final states and exit codes from Slurm
# accounting, and returns one overall PASS or FAIL result. Each version-specific
# script remains responsible for validating its own OpenFOAM stage and returning
# a nonzero exit status whenever that stage fails.
#
# Expected version-directory layout:
#
#   <recipe-dir>/
#       |-- tutorialTest/
#           |-- extractCase.sh
#           |-- preFoam.slurm.sh
#           `-- runFoam.slurm.sh
#
# Examples:
#   tests/setonix/openfoamTutorialTestsLauncher.sh \
#      --recipe-dir v2406 --image /path/to/openfoam-v2406.sif
#
#   tests/setonix/openfoamTutorialTestsLauncher.sh \
#      --recipe-dir v2406 --image /path/to/openfoam-v2406.sif \
#      --work-root "$MYSCRATCH/OpenFOAM-functional-tests/v2406-manual"
#
# Exit status:
#   0  Extraction, preparation, and solver execution all passed.
#   1  Invalid input, submission failure, accounting failure, or any tutorial
#      stage failed.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

# Treat any use of an unset variable as an error.
set -u

# --- Initial settings
thisScript=$(basename "$0")
scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
recipeDirInput=""
imageInput=""
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

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  $thisScript --recipe-dir <directory> --image <file> [options]
  $thisScript --help

Required options:
  --recipe-dir, -r <directory>  OpenFOAM version directory containing tutorialTest/
  --image, -i <file>            Singularity image to test

Optional settings:
  --work-root, -w <directory>   Host work root shared by all three test stages.
                                 By default, an isolated directory is created
                                 under MYSCRATCH, TMPDIR, or HOME.
  --partition, -p <name>        Override the partition in both Slurm scripts
  --reservation <name>          Submit both Slurm jobs using this reservation
  --overwrite                   Replace an existing extracted case. This is useful
                                 when intentionally reusing --work-root.
  --help, -h                    Show this help message and exit

The launcher calls each version-specific script with:
  --image <file> --work-root <directory> --config <file>
  --test-artifacts-dir <directory>

The Slurm resources remain defined by preFoam.slurm.sh and runFoam.slurm.sh.
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
      --image|-i)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --image requires <file>" >&2; usage >&2; exit 1; }
         imageInput="$2"
         shift 2
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

# --- Resolve and validate the required inputs
[[ -n "$recipeDirInput" ]] || { echo "ERROR: --recipe-dir is required" >&2; usage >&2; exit 1; }
[[ -d "$recipeDirInput" ]] || { echo "ERROR: Recipe directory not found: $recipeDirInput" >&2; exit 1; }
recipeDir=$(realpath "$recipeDirInput")
configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
[[ -r "$configFile" ]] || { echo "ERROR: Configuration is not readable: $configFile" >&2; exit 1; }
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || { echo "ERROR: $requiredSetting is not defined in $configFile" >&2; exit 1; }
done

[[ -n "$imageInput" ]] || { echo "ERROR: --image is required" >&2; usage >&2; exit 1; }
[[ -f "$imageInput" ]] || { echo "ERROR: Singularity image not found: $imageInput" >&2; exit 1; }
SINGULARITY_CONTAINER=$(realpath "$imageInput")
imageFileName=$(basename "$SINGULARITY_CONTAINER")
expectedSifPrefix="${OPENFOAM_FORK}--${OPENFOAM_VERSION}"
[[ "$imageFileName" == "${expectedSifPrefix}"*.sif ]] || {
   echo "ERROR: Singularity image filename does not match the configured OpenFOAM identity" >&2
   echo "       Image filename:   $imageFileName" >&2
   echo "       Required pattern: ${expectedSifPrefix}*.sif" >&2
   exit 1
}
imageChecksum=$(sha256sum "$SINGULARITY_CONTAINER" | awk '{print $1}')

# --- Locate the version-specific tutorial scripts
tutorialScriptDir="${recipeDir}/tutorialTest"
extractScript="${tutorialScriptDir}/extractCase.sh"
preScript="${tutorialScriptDir}/preFoam.slurm.sh"
runScript="${tutorialScriptDir}/runFoam.slurm.sh"

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

# --- Create persistent artifacts and an isolated case workspace
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
runArtifactsName="${runId}_singularity"
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
workOutputPath="${workRoot}/test-output"
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
   echo "SIF image: $SINGULARITY_CONTAINER"
   echo "SIF SHA256: $imageChecksum"
   echo "Work root: $workRoot"
} > "$testDetailsFile"

# --- Verify the Slurm client commands
for commandName in sbatch squeue sacct; do
   command -v "$commandName" >/dev/null 2>&1 || {
      echo "ERROR: $commandName not found. Run this launcher on a Slurm login node." >&2
      exit 1
   }
done

# --- Build optional site-level submission arguments
# Resource options are intentionally absent. Nodes, tasks, CPUs, memory, and time
# remain in the version-specific Slurm scripts.
submissionOverrides=()
if [[ -n "$partitionInput" ]]; then
   submissionOverrides+=(--partition="$partitionInput")
fi
if [[ -n "$reservationInput" ]]; then
   submissionOverrides+=(--reservation="$reservationInput")
fi

# --- Display the resolved test plan
echo "============================================================"
echo "OpenFOAM tutorial functional-test launcher"
echo "============================================================"
echo "Launcher directory : $scriptDir"
echo "Version directory  : $recipeDir"
echo "Tutorial scripts   : $tutorialScriptDir"
echo "Image              : $SINGULARITY_CONTAINER"
echo "Work root          : $workRoot"
echo "Output directory   : $outputDir"
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

# --- Stage 1: Extract and validate the tutorial case
# The extraction script records its complete output in extractCase.run.log.
# Its output is also inherited by the launcher and recorded in launcher.run.log.
extractArgs=(
   --image "$SINGULARITY_CONTAINER"
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

# --- Stage 2: Submit the preparation job
# The version-specific script controls its own Slurm resources. The launcher only
# supplies shared inputs and optional partition or reservation overrides.
preOutput="${outputDir}/slurm-preFoam-%j.out"
echo "$thisScript: -----------------------------------------"
echo "Stage 2 - Submitting tutorial preparation"
preSubmission=$(sbatch --parsable \
   "${submissionOverrides[@]}" \
   --output="$preOutput" \
   "$preScript" \
   --image "$SINGULARITY_CONTAINER" \
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

# --- Stage 3: Submit the dependent solver job
# afterok prevents solver execution after a failed preparation. The invalid
# dependency option prevents the solver job from remaining pending indefinitely.
runOutput="${outputDir}/slurm-runFoam-%j.out"
echo "$thisScript: -----------------------------------------"
echo "Stage 3 - Submitting tutorial solver execution"
runSubmission=$(sbatch --parsable \
   "${submissionOverrides[@]}" \
   --dependency="afterok:${preJobId}" \
   --kill-on-invalid-dep=yes \
   --output="$runOutput" \
   "$runScript" \
   --image "$SINGULARITY_CONTAINER" \
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

# --- Stage 4: Wait for both Slurm jobs
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

# --- Obtain a parent job's final Slurm state and exit code
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

# --- Stage 5: Evaluate the final Slurm results
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

# --- Final summary
echo "============================================================"
echo "$thisScript: FINAL SUMMARY"
echo "============================================================"
echo "Version directory: $recipeDir"
echo "Image: $SINGULARITY_CONTAINER"
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
   echo "SIF image: $SINGULARITY_CONTAINER"
   echo "SIF SHA256: $imageChecksum"
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
