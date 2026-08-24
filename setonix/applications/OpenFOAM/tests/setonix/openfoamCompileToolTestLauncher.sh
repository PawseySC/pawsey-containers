#!/usr/bin/env bash
# General launcher for the OpenFOAM compile-tool Slurm functional test.
#
# This script provides one user-facing entry point for submitting and monitoring
# openfoamCompileToolTestJob.slurm.sh. The Slurm job verifies that a selected
# OpenFOAM Singularity image can support a normal user-development workflow by
# copying an application source tree to host storage, compiling it with wmake,
# locating the resulting executable, and running its help command.
#
# The launcher is responsible for orchestration and persistent test evidence. It:
#
#   1. Resolves the version-specific OpenFOAM configuration.
#   2. Validates the supplied SIF filename against OPENFOAM_FORK and
#      OPENFOAM_VERSION from that configuration.
#   3. Records the SIF SHA-256 checksum.
#   4. Creates one timestamped artifact directory and updates the latest link.
#   5. Submits the Slurm job and directs its scheduler output into that directory.
#   6. Waits for the job to leave the queue and obtains its final accounting data.
#   7. Records one overall SUCCESS or FAILED result for the complete invocation.
#
# The launcher and job script must be stored in the same directory:
#
#   openfoamCompileToolTestLauncher.sh
#   openfoamCompileToolTestJob.slurm.sh
#
# Expected version-directory layout:
#
#   <recipe-dir>/
#       |-- buildAndValidationConfig/
#       |   `-- openfoamBuildAndValidation.config
#       `-- artifacts/
#
# The configuration must define OPENFOAM_FORK and OPENFOAM_VERSION. The Slurm job
# also uses COMPILE_TEMPLATE_TOOL and COMPILED_TEST_TOOL when available, with the
# existing DEFAULT_TOOL fallback documented in the job script.
#
# Each invocation stores its output under:
#
#   <recipe-dir>/artifacts/tests/compile-tool/<timestamp>_singularity/
#
# including launcher.run.log, status.txt, test details, the scheduler-native
# slurm-<job-id>.out file, and all artifacts produced by the Slurm job.
#
# Examples:
#
#   ./openfoamCompileToolTestLauncher.sh \
#      --recipe-dir openfoam/v2412 \
#      --image /path/to/openfoam--v2412-mpich4.2.2-ubuntu24.04.sif
#
#   ./openfoamCompileToolTestLauncher.sh \
#      --config openfoam/v2412/buildAndValidationConfig/openfoamBuildAndValidation.config \
#      --image /path/to/openfoam--v2412-mpich4.2.2-ubuntu24.04.sif \
#      --work-root "$MYSCRATCH/OpenFOAM-functional-tests/manual-v2412" \
#      --partition work
#
# Exit status:
#   0  The Slurm job completed successfully with exit code 0:0.
#   1  Invalid input, setup failure, submission failure, accounting failure, or
#      compile-tool functional-test failure.
#
# NOTE: This script was developed under the supervision of Alexis Espinosa at
#       Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot
#       (GPT-5 reasoning model).
#       This script has been fully reviewed, understood and tested by Alexis
#       Espinosa at Pawsey Supercomputing Centre.

# Treat any use of an unset variable as an error.
set -u

# --- Initial settings
thisScript=$(basename "$0")
scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
recipeDirInput=""
configFileInput=""
imageInput=""
workRootInput=""
partitionInput="${PARTITION:-}"
reservationInput="${RESERVATION:-}"
pollInterval=${POLL_INTERVAL_SECONDS:-20}

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  $thisScript --recipe-dir <directory> --image <file> [options]
  $thisScript --config <file> --image <file> [options]
  $thisScript --help

Required inputs:
  --recipe-dir, -r <directory>  OpenFOAM version directory
    or
  --config, -c <file>           Explicit version configuration file
  --image, -i <file>            Singularity SIF image to test

Optional settings:
  --work-root <directory>       Host OpenFOAM user-development directory
  --partition, -p <name>        Override the Slurm job partition
  --reservation <name>          Submit the Slurm job using this reservation
  --help, -h                    Show this help message and exit

Run this launcher directly. It submits openfoamCompileToolTestJob.slurm.sh with
sbatch, waits for the job, and returns the final test result to the caller.
USAGE
}

# --- Parse command-line arguments
while [[ $# -gt 0 ]]; do
   case "$1" in
      --recipe-dir|-r)
         [[ $# -ge 2 && -n "$2" ]] || {
            echo "ERROR: --recipe-dir requires <directory>" >&2
            usage >&2
            exit 1
         }
         recipeDirInput="$2"
         shift 2
         ;;
      --config|-c)
         [[ $# -ge 2 && -n "$2" ]] || {
            echo "ERROR: --config requires <file>" >&2
            usage >&2
            exit 1
         }
         configFileInput="$2"
         shift 2
         ;;
      --image|-i)
         [[ $# -ge 2 && -n "$2" ]] || {
            echo "ERROR: --image requires <file>" >&2
            usage >&2
            exit 1
         }
         imageInput="$2"
         shift 2
         ;;
      --work-root)
         [[ $# -ge 2 && -n "$2" ]] || {
            echo "ERROR: --work-root requires <directory>" >&2
            usage >&2
            exit 1
         }
         workRootInput="$2"
         shift 2
         ;;
      --partition|-p)
         [[ $# -ge 2 && -n "$2" ]] || {
            echo "ERROR: --partition requires <name>" >&2
            usage >&2
            exit 1
         }
         partitionInput="$2"
         shift 2
         ;;
      --reservation)
         [[ $# -ge 2 && -n "$2" ]] || {
            echo "ERROR: --reservation requires <name>" >&2
            usage >&2
            exit 1
         }
         reservationInput="$2"
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

# --- Step 1: Resolve the version configuration and required inputs
# Use either the version directory or an explicit configuration path, not both.
echo "$thisScript: -----------------------------------------"
echo "Step 1 - Resolving the test configuration and inputs"
[[ -z "$recipeDirInput" || -z "$configFileInput" ]] || {
   echo "ERROR: Use either --recipe-dir or --config, not both" >&2
   usage >&2
   exit 1
}

if [[ -n "$configFileInput" ]]; then
   [[ -f "$configFileInput" ]] || {
      echo "ERROR: Configuration file does not exist: $configFileInput" >&2
      usage >&2
      exit 1
   }
   configFile=$(realpath "$configFileInput")
   configDir=$(dirname "$configFile")
   [[ $(basename "$configDir") == "buildAndValidationConfig" ]] || {
      echo "ERROR: Cannot derive the OpenFOAM version directory from config: $configFile" >&2
      echo "       Expected the config below a buildAndValidationConfig directory." >&2
      exit 1
   }
   recipeDir=$(dirname "$configDir")
elif [[ -n "$recipeDirInput" ]]; then
   [[ -d "$recipeDirInput" ]] || {
      echo "ERROR: Recipe directory does not exist: $recipeDirInput" >&2
      usage >&2
      exit 1
   }
   recipeDir=$(realpath "$recipeDirInput")
   configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
else
   echo "ERROR: --recipe-dir or --config is required" >&2
   usage >&2
   exit 1
fi

[[ -r "$configFile" ]] || {
   echo "ERROR: Configuration is not readable: $configFile" >&2
   exit 1
}
[[ -n "$imageInput" ]] || {
   echo "ERROR: --image is required" >&2
   usage >&2
   exit 1
}
[[ -f "$imageInput" ]] || {
   echo "ERROR: SIF image not found: $imageInput" >&2
   usage >&2
   exit 1
}
image=$(realpath "$imageInput")
echo "PASS: Configuration and required inputs resolved"
echo

# --- Step 2: Validate the configured OpenFOAM image identity
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || {
      echo "ERROR: $requiredSetting is not defined in $configFile" >&2
      exit 1
   }
done

imageFileName=$(basename "$image")
expectedSifPrefix="${OPENFOAM_FORK}--${OPENFOAM_VERSION}"
[[ "$imageFileName" == "${expectedSifPrefix}"*.sif ]] || {
   echo "ERROR: Singularity image filename does not match the configured OpenFOAM identity" >&2
   echo "       Image filename:   $imageFileName" >&2
   echo "       Required pattern: ${expectedSifPrefix}*.sif" >&2
   exit 1
}
imageChecksum=$(sha256sum "$image" | awk '{print $1}')

echo "$thisScript: -----------------------------------------"
echo "Step 2 - Validating the Singularity image identity"
echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
echo "Image: $image"
echo "Image SHA256: $imageChecksum"
echo "PASS: Singularity filename matches '${expectedSifPrefix}*.sif'"
echo

# --- Step 3: Verify the Slurm client and job script
jobScript="${scriptDir}/openfoamCompileToolTestJob.slurm.sh"
for commandName in sbatch squeue sacct; do
   command -v "$commandName" >/dev/null 2>&1 || {
      echo "ERROR: $commandName not found. Run this launcher on a Slurm login node." >&2
      exit 1
   }
done
[[ -f "$jobScript" ]] || {
   echo "ERROR: Slurm job script not found: $jobScript" >&2
   exit 1
}
bash -n "$jobScript" || {
   echo "ERROR: Bash syntax check failed: $jobScript" >&2
   exit 1
}

echo "$thisScript: -----------------------------------------"
echo "Step 3 - Verifying the Slurm client and compile-tool job script"
echo "Slurm job script: $jobScript"
echo "PASS: Slurm submission environment is ready"
echo

# --- Step 4: Create persistent artifacts for this launcher invocation
artifactsRoot="${recipeDir}/artifacts/tests/compile-tool"
mkdir -p "$artifactsRoot"
latestLink="${artifactsRoot}/latest"
if [[ -e "$latestLink" && ! -L "$latestLink" ]]; then
   echo "ERROR: Refusing to remove non-symbolic-link path: $latestLink" >&2
   exit 1
fi
rm -f "$latestLink" || {
   echo "ERROR: Failed to remove latest link: $latestLink" >&2
   exit 1
}
echo "This directory contains timestamped compile-tool test artifacts. The latest link identifies the most recent launcher invocation." > "${artifactsRoot}/README.txt"

timestamp=$(date '+%Y%m%dT%H%M%S%z')
runName="${timestamp}_singularity"
runDir="${artifactsRoot}/${runName}"
mkdir "$runDir" || {
   echo "ERROR: Cannot create artifact directory: $runDir" >&2
   exit 1
}
ln -sfn "$runName" "$latestLink"

launcherLog="${runDir}/launcher.run.log"
statusFile="${runDir}/status.txt"
detailsFile="${runDir}/test-details.txt"
summaryFile="${runDir}/test-summary.txt"
printf '%s\n' RUNNING > "$statusFile"

record_status() {
   local exitStatus=$?
   trap - EXIT
   if [[ $exitStatus -eq 0 ]]; then
      printf '%s\n' SUCCESS > "$statusFile"
   else
      printf '%s\n' FAILED > "$statusFile"
   fi
   exit "$exitStatus"
}
trap record_status EXIT

# Preserve all subsequent launcher output while continuing to display it.
exec > >(tee "$launcherLog") 2>&1

echo "$thisScript: -----------------------------------------"
echo "Step 4 - Creating the compile-tool test artifact directory"
echo "Artifacts: $runDir"
echo "Launcher log: $launcherLog"
echo "Overall status: $statusFile"
echo "PASS: Persistent test artifacts are ready"
echo

# --- Display the resolved test plan
cat <<PLAN
============================================================
OpenFOAM compile-tool functional-test launcher
============================================================
Recipe directory   : $recipeDir
Configuration      : $configFile
Image              : $image
Image SHA256       : $imageChecksum
Slurm job script   : $jobScript
Work-root override : ${workRootInput:-none}
Partition override : ${partitionInput:-none}
Reservation        : ${reservationInput:-none}
Artifact directory : $runDir
============================================================
PLAN

# --- Step 5: Submit the compile-tool Slurm job
submissionOptions=()
if [[ -n "$partitionInput" ]]; then
   submissionOptions+=(--partition="$partitionInput")
fi
if [[ -n "$reservationInput" ]]; then
   submissionOptions+=(--reservation="$reservationInput")
fi
jobArgs=(
   --config "$configFile"
   --image "$image"
   --test-artifacts-dir "$runDir"
)
if [[ -n "$workRootInput" ]]; then
   jobArgs+=(--work-root "$workRootInput")
fi

echo "$thisScript: -----------------------------------------"
echo "Step 5 - Submitting the compile-tool Slurm job"
submission=$(sbatch --parsable \
   "${submissionOptions[@]}" \
   --output="${runDir}/slurm-%j.out" \
   "$jobScript" \
   "${jobArgs[@]}") || {
      echo "ERROR: Failed to submit $jobScript" >&2
      exit 1
   }
IFS=';' read -r jobId _ <<< "$submission"
[[ "$jobId" =~ ^[0-9]+$ ]] || {
   echo "ERROR: Invalid job ID returned by sbatch: $submission" >&2
   exit 1
}
slurmOutput="${runDir}/slurm-${jobId}.out"

{
   echo "Launcher timestamp: $timestamp"
   echo "Configuration: $configFile"
   echo "Recipe directory: $recipeDir"
   echo "Configured OpenFOAM fork: $OPENFOAM_FORK"
   echo "Configured OpenFOAM version: $OPENFOAM_VERSION"
   echo "SIF image: $image"
   echo "SIF SHA256: $imageChecksum"
   echo "Slurm job ID: $jobId"
   echo "Slurm output: $slurmOutput"
} > "$detailsFile"

echo "Submitted compile-tool test job: $jobId"
echo "Slurm output: $slurmOutput"
echo "PASS: Slurm job submitted successfully"
echo

# --- Step 6: Wait for the Slurm job to finish
# A job remains active while squeue reports it as pending or running.
echo "$thisScript: -----------------------------------------"
echo "Step 6 - Waiting for compile-tool test job $jobId"
echo "Polling Slurm every ${pollInterval} seconds"
while [[ -n "$(squeue --noheader --jobs="$jobId" 2>/dev/null)" ]]; do
   jobState=$(squeue --noheader --jobs="$jobId" --format='%T' 2>/dev/null | head -n 1)
   if [[ -n "$jobState" ]]; then
      echo "Job $jobId is still active: $jobState"
   else
      echo "Job $jobId is still present in the Slurm queue"
   fi
   sleep "$pollInterval"
done
echo "Job $jobId has left the Slurm queue."
echo "Waiting for the final accounting record..."
echo

# --- Obtain the parent job's final Slurm state and exit code
# Accounting data may appear shortly after the job leaves squeue. Retry for one
# minute by default before treating the result as unavailable.
result=""
for ((attempt = 1; attempt <= 12; attempt++)); do
   result=$(sacct --noheader --parsable2 --jobs="$jobId" \
      --format=JobIDRaw,State,ExitCode 2>/dev/null | \
      awk -F'|' -v id="$jobId" '$1 == id { print $2 "|" $3; exit }')
   [[ -n "$result" ]] && break
   sleep "$pollInterval"
done
[[ -n "$result" ]] || result="UNAVAILABLE|UNAVAILABLE"
IFS='|' read -r state exitCode <<< "$result"
baseState=${state%%+}

# --- Step 7: Evaluate and record the final result
if [[ "$baseState" == "COMPLETED" && "$exitCode" == "0:0" ]]; then
   resultWord="SUCCESS"
   finalStatus=0
else
   resultWord="FAILED"
   finalStatus=1
fi

{
   echo "Result: $resultWord"
   echo "Slurm job ID: $jobId"
   echo "Slurm state: $state"
   echo "Slurm exit code: $exitCode"
   echo "SIF image: $image"
   echo "SIF SHA256: $imageChecksum"
   echo "Job status file: ${runDir}/compileTool.status.txt"
   echo "Slurm output: $slurmOutput"
} > "$summaryFile"

echo "$thisScript: -----------------------------------------"
echo "Step 7 - Evaluating the final compile-tool test result"
echo "Job $jobId: state=$state, exitCode=$exitCode"
if [[ $finalStatus -eq 0 ]]; then
   echo "PASS: Compile-tool Slurm job completed successfully"
else
   echo "FAIL: Compile-tool Slurm job did not complete successfully" >&2
fi
echo

# --- Final summary
echo "============================================================"
echo "$thisScript: FINAL SUMMARY"
echo "============================================================"
echo "Result: $resultWord"
echo "Slurm job: $jobId ($state, $exitCode)"
echo "Image: $image"
echo "Artifact directory: $runDir"
echo "Slurm output: $slurmOutput"
echo "Job run log: ${runDir}/compileTool.run.log"
echo "Test summary: $summaryFile"
echo "Overall status: $statusFile"
if [[ $finalStatus -eq 0 ]]; then
   echo "ALL STEPS PASSED: OpenFOAM compile-tool functional test completed successfully."
else
   echo "COMPILE-TOOL TEST FAILED: Inspect the recorded artifacts above." >&2
fi
exit "$finalStatus"
