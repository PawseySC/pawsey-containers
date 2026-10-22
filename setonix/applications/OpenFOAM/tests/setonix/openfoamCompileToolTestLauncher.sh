#!/usr/bin/env bash
# General launcher for the OpenFOAM compile-tool Slurm functional test.
#
# This launcher submits and monitors openfoamCompileToolTestJob.slurm.sh. The job
# verifies that one selected OpenFOAM runtime supports a normal user-development
# workflow: locate an installed application, copy its source into an isolated
# host workspace, rename it, compile it with wmake, locate the new executable,
# and validate its help output.
#
# Exactly one runtime must be selected:
#
#   --image <file>  uses an explicit Singularity image;
#   --shpc          uses <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>;
#   --bare-metal    uses <OPENFOAM_FORK>/<OPENFOAM_VERSION>.
#
# The launcher reads the version identity from the selected configuration,
# creates persistent artifacts, passes the runtime selection to the Slurm job,
# waits for completion, reads Slurm accounting, and reports one final result.
# The job script loads the selected runtime and performs all compilation steps.
#
# The launcher and job script must be stored in the same directory:
#
#   openfoamCompileToolTestLauncher.sh
#   openfoamCompileToolTestJob.slurm.sh
#
# Expected recipe layout:
#
#   <recipe-dir>/
#       |-- buildAndValidationConfig/
#       |   `-- openfoamBuildAndValidation.config
#       `-- artifacts/
#
# The configuration defines OPENFOAM_FORK and OPENFOAM_VERSION. It may also
# define COMPILE_TEMPLATE_TOOL and COMPILED_TEST_TOOL; the job retains its
# documented DEFAULT_TOOL fallback.
#
# Each invocation stores evidence below:
#
#   <recipe-dir>/artifacts/tests/compile-tool/<timestamp>_<runtime>/
#
# Examples:
#
# Explicit image using a recipe directory:
#   ./openfoamCompileToolTestLauncher.sh \
#      --recipe-dir openfoam/v2406 \
#      --image /path/to/openfoam--v2406-image.sif
#
# SHPC module using a recipe directory:
#   ./openfoamCompileToolTestLauncher.sh \
#      --recipe-dir openfoam/v2406 \
#      --shpc
#
# Bare-metal module using an explicit configuration:
#   ./openfoamCompileToolTestLauncher.sh \
#      --config openfoam/v2406/buildAndValidationConfig/openfoamBuildAndValidation.config \
#      --bare-metal
#
# Exit status:
#   0  The compile-tool test completed successfully.
#   1  Input validation, submission, accounting, compilation, or validation failed.

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
useSHPC=false
useBareMetal=false
workRootInput=""
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

Required inputs:
  --recipe-dir, -r <directory>  OpenFOAM version directory
    or
  --config, -c <file>           Explicit version configuration file
  --image, -i <file>            Use the supplied Singularity SIF image
  --shpc                        Use <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>
  --bare-metal                  Use <OPENFOAM_FORK>/<OPENFOAM_VERSION>

Optional settings:
  --work-root <directory>       Host OpenFOAM user-development directory
  --partition, -p <name>        Override the Slurm job partition
  --reservation <name>          Submit the Slurm job using this reservation
  --submit-only                 Submit the job and return without waiting
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
      --shpc)
         useSHPC=true
         shift
         ;;
      --bare-metal)
         useBareMetal=true
         shift
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
      --submit-only)
         submitOnly=true
         shift
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
runtimeSelectorCount=0
[[ -n "$imageInput" ]] && ((runtimeSelectorCount += 1))
[[ "$useSHPC" == true ]] && ((runtimeSelectorCount += 1))
[[ "$useBareMetal" == true ]] && ((runtimeSelectorCount += 1))
[[ $runtimeSelectorCount -eq 1 ]] || {
   echo "ERROR: Choose exactly one of --image <file>, --shpc, or --bare-metal" >&2
   usage >&2
   exit 1
}

# The configuration is authoritative for fork and version in both modes.
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || { echo "ERROR: $requiredSetting is not defined in $configFile" >&2; exit 1; }
done

image=""
imageChecksum=""
shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
if [[ -n "$imageInput" ]]; then
   [[ -f "$imageInput" ]] || { echo "ERROR: SIF image not found: $imageInput" >&2; exit 1; }
   image=$(realpath "$imageInput")
   imageFileName=$(basename "$image")
   expectedSifPrefix="${OPENFOAM_FORK}--${OPENFOAM_VERSION}"
   [[ "$imageFileName" == "${expectedSifPrefix}"*.sif ]] || { echo "ERROR: Image filename does not match ${expectedSifPrefix}*.sif" >&2; exit 1; }
   imageChecksum=$(sha256sum "$image" | awk '{print $1}')
   runtimeMode="Explicit Singularity image"
   runtimeOption=(--image "$image")
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

echo "PASS: Configuration and runtime selection resolved"
echo

# --- Step 2: Record the configured runtime identity
echo "$thisScript: -----------------------------------------"
echo "Step 2 - Recording configured runtime identity"
echo "Configured fork: $OPENFOAM_FORK"
echo "Configured version: $OPENFOAM_VERSION"
echo "Runtime mode: $runtimeMode"
[[ -n "$image" ]] && { echo "Runtime mode: $runtimeMode"
[[ -n "$image" ]] && echo "Image: $image"
[[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"
[[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"; echo "Image SHA256: $imageChecksum"; }
[[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"
[[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"
echo

# --- Step 3: Verify the Slurm client and job script
jobScript="${scriptDir}/openfoamCompileToolTestJob.slurm.sh"
requiredSlurmCommands=(sbatch)
if [[ "$submitOnly" != true ]]; then requiredSlurmCommands+=(squeue sacct); fi
for commandName in "${requiredSlurmCommands[@]}"; do
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
Launcher mode      : $([[ "$submitOnly" == true ]] && echo "submit only" || echo "submit and wait")
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
   "${runtimeOption[@]}"
   --test-artifacts-dir "$runDir"
)
if [[ -n "$workRootInput" ]]; then
   jobArgs+=(--work-root "$workRootInput")
fi

echo "$thisScript: -----------------------------------------"
echo "Step 5 - Submitting the compile-tool Slurm job"
submission=$(env \
   -u SLURM_MEM_PER_CPU \
   -u SLURM_MEM_PER_GPU \
   -u SLURM_MEM_PER_NODE \
   SLURM_EXPORT_ENV=ALL \
   sbatch --export=NONE --parsable \
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
   echo "Runtime mode: $runtimeMode"
   [[ -n "$image" ]] && { echo "SIF image: $image"; echo "SIF SHA256: $imageChecksum"; }
   [[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"
[[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"
   echo "Slurm job ID: $jobId"
   echo "Slurm output: $slurmOutput"
} > "$detailsFile"

echo "Submitted compile-tool test job: $jobId"
echo "Slurm output: $slurmOutput"
echo "PASS: Slurm job submitted successfully"
echo

# Return immediately after a successful submission when requested.
if [[ "$submitOnly" == true ]]; then
   printf '%s
' SUBMITTED > "$statusFile"
   trap - EXIT
   { echo "Result: SUBMITTED"; echo "Slurm job ID: $jobId"; echo "Runtime mode: $runtimeMode"; [[ -n "$image" ]] && { echo "SIF image: $image"; echo "SIF SHA256: $imageChecksum"; }; [[ "$useSHPC" == true ]] && echo "SHPC module: $shpcModule"
[[ "$useBareMetal" == true ]] && echo "Bare-metal module: $bareMetalModule"; echo "Slurm output: $slurmOutput"; } > "$summaryFile"
   echo "RESULT: SUBMITTED"
   echo "The launcher will not wait for Slurm job $jobId."
   exit 0
fi

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
