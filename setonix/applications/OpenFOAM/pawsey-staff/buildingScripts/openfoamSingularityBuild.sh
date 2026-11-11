#!/bin/bash
# General script for building OpenFOAM Singularity images.
#
# This script creates a Singularity SIF image from one of three source types:
#   1. An image held in the local Docker image store.
#   2. An image held in the local Podman image store.
#   3. An image available from a remote Docker-compatible registry.
#
# In local mode, --engine selects Docker or Podman. A local image name:tag may
# be supplied as the final positional argument. If it is omitted, --recipe-dir
# is required and the script derives the local image name from ARG instructions
# in that version directory's Dockerfile. Repeated --build-arg NAME=VALUE options
# can select supported source-image variants. Only Dockerfile ARG instructions
# marked with USER_BUILD_ARG are accepted as user overrides. Overrides that form
# the image tag are used to identify the local source image. Other accepted
# overrides are recorded but are not applied during the Singularity conversion.
#
# In registry mode, --fromRegistryImage supplies the complete remote image
# reference. The docker:// prefix is optional and is added automatically when
# missing. Registry mode does not require Docker or Podman.
#
# Docker images are read directly through docker-daemon://. Podman images are
# first saved as an OCI archive because Singularity reads that archive through
# oci-archive://. Remote images are read directly from their docker:// source.
# Temporary and persistent conversion artifacts are stored under the required
# recipe directory. The docker recipe filename is constructed from
# OPENFOAM_FORK and OPENFOAM_VERSION in the version configuration. The complete
# source image tag, including compiler and OpenFOAM build-variant settings, is
# preserved in the resulting SIF filename.
#
# By default, each resulting SIF and its logs are stored together under a
# timestamped artifacts/singularity/ directory. The latest symbolic link is
# updated only after a successful default-location SIF build. --output-dir
# overrides only the SIF destination; the timestamped directory still retains
# logs and metadata without changing the development-candidate latest link.
#
# Examples:
#   openfoamSingularityBuild.sh --recipe-dir openfoam/v2606 --engine podman
#
#   openfoamSingularityBuild.sh --recipe-dir openfoam/v2606 --engine podman \
#      --build-arg WM_LABEL_SIZE=64
#
#   openfoamSingularityBuild.sh --recipe-dir openfoam/v2606 --engine docker \
#      openfoam:v2606-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04
#   openfoamSingularityBuild.sh --recipe-dir openfoam/v2406 --output-dir /path/to/images \
#      --fromRegistryImage quay.io/example/openfoam:v2406
#   openfoamSingularityBuild.sh --help
#
# Exit status:
#   0  The Singularity image was built successfully.
#   1  Invalid input, setup failure, source-image failure, or build failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

# Singularity runtime selection
# -----------------------------
# Podman-source and registry-source builds load a configurable Singularity module.
# The default remains singularity/4.3.5-mpi for compatibility with the established
# build workflow. Use --singularity-module to select another module explicitly.
# Docker-source builds retain their existing host-specific setup through
# ~/setup_singularity.sh; an explicit module override is rejected in that mode.
# The requested module name and effective `singularity --version` are recorded in
# the invocation artifacts and final summary.
#
# =============================================================================
# Initial settings
# =============================================================================
# Runtime state is initialized before command-line values are parsed.
thisScript=$(basename "$0")
scriptDir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
testNum=0
failedTests=()
totalFailed=0
imageFull=""
recipeDirInput=""
recipeDir=""
recipeFile=""
tmpDir=""
artifactsDir=""
singularityArtifactsDir=""
runArtifactsDir=""
runLog=""
buildLog=""
saveLog=""
buildCommandFile=""
imageDetailsFile=""
sourceBuildArgumentsFile=""
outputDirInput=""
buildArgs=()
declare -A buildArgValues=()
configFile=""


# =============================================================================
# Isolated-operation cleanup and stall supervision
# =============================================================================
# Long operations run in uniquely named transient systemd user services.
# This cgroup boundary contains Podman, Buildah, FUSE helpers, compilers,
# and other descendants without targeting unrelated work owned by the user.
#
# The subsystem validates configurable timeouts, transfers the required
# environment, monitors log activity, captures stall diagnostics, requests
# orderly Podman cleanup, and verifies storage health before returning.
# Broad process killing, global unmounting, pruning, and storage reset are
# deliberately excluded from automatic cleanup.
# Each long container operation runs in its own transient systemd user service.
# Cleanup therefore targets only this invocation, not unrelated container builds.
# All supported builders use this generic systemd service family.
# The script name and operation label remain in each unit for diagnostics.
CONTAINER_BUILD_SERVICE_PREFIX="container-build"
activeOperationUnit=""
operationRunnerPid=""
watchdogPid=""
operationCounter=0
# Production defaults can be overridden through the environment for controlled tests.
STALL_SILENCE_SECONDS=${STALL_SILENCE_SECONDS:-1800}
STALL_CONFIRMATION_SECONDS=${STALL_CONFIRMATION_SECONDS:-180}
STALL_CHECK_INTERVAL=${STALL_CHECK_INTERVAL:-60}
STORAGE_SETTLE_SECONDS=${STORAGE_SETTLE_SECONDS:-90}
STORAGE_CHECK_INTERVAL=${STORAGE_CHECK_INTERVAL:-5}
PODMAN_MAIN_TERM_GRACE_SECONDS=${PODMAN_MAIN_TERM_GRACE_SECONDS:-60}
PODMAN_CGROUP_TERM_GRACE_SECONDS=${PODMAN_CGROUP_TERM_GRACE_SECONDS:-10}
PODMAN_TERM_STATUS_INTERVAL=${PODMAN_TERM_STATUS_INTERVAL:-10}
serviceEnvironment=()
podmanEnvironmentReady=false
podmanGraphRoot=""
operationWasStarted=false
storageVerifiedAfterOperation=false
# -----------------------------------------------------------------------------
# Helper: prepare the transient-service environment
# -----------------------------------------------------------------------------

build_service_environment() {
   local variableName
   local -a variableNames=(
      HOME USER LOGNAME PATH SHELL TMPDIR
      XDG_DATA_HOME XDG_CONFIG_HOME XDG_RUNTIME_DIR
      CONTAINERS_CONF CONTAINERS_STORAGE_CONF REGISTRY_AUTH_FILE
      DBUS_SESSION_BUS_ADDRESS SSH_AUTH_SOCK
   )

   serviceEnvironment=()
   for variableName in "${variableNames[@]}"; do
      if [[ -v "$variableName" ]]; then
         serviceEnvironment+=(--setenv="${variableName}=${!variableName}")
      fi
   done
}
# -----------------------------------------------------------------------------
# Helper: probe Podman storage health
# -----------------------------------------------------------------------------

podman_storage_healthy() {
   local mountTarget

   # Bound every metadata query so unhealthy storage cannot block cleanup forever.
   timeout 30 podman images --no-trunc >/dev/null 2>&1 || return 1
   timeout 30 podman ps -a >/dev/null 2>&1 || return 1
   timeout 30 podman ps --all --external --no-trunc >/dev/null 2>&1 || return 1

   # Probe visible FUSE overlay mountpoints below this Podman GraphRoot. Healthy
   # mounts are allowed, including mounts belonging to unrelated concurrent builds.
   # Only an inaccessible or disconnected endpoint makes the check fail.
   while IFS= read -r mountTarget; do
      [[ -n "$mountTarget" ]] || continue
      [[ "$mountTarget" == "$podmanGraphRoot"/overlay/*/merged ]] || continue
      timeout 5 stat "$mountTarget" >/dev/null 2>&1 || return 1
   done < <(
      {
         findmnt -rn -t fuse.fuse-overlayfs,fuse-overlayfs -o TARGET 2>/dev/null || true
         podman unshare findmnt -rn -t fuse.fuse-overlayfs,fuse-overlayfs -o TARGET 2>/dev/null || true
      } | sort -u
   )

   return 0
}
# -----------------------------------------------------------------------------
# Helper: write Podman storage diagnostics
# -----------------------------------------------------------------------------

write_podman_storage_diagnostics() {
   local diagnosticsFile=$1
   {
      echo "Timestamp: $(date --iso-8601=seconds)"
      echo "Podman GraphRoot: $podmanGraphRoot"
      echo
      echo "===== relevant processes ====="
      ps -u "$USER" -o pid,ppid,stat,%cpu,%mem,etime,wchan:32,cmd --sort=-%cpu 2>&1 || true
      echo
      echo "===== container-build transient services ====="
      systemctl --user list-units --all "${CONTAINER_BUILD_SERVICE_PREFIX}-*.service" 2>&1 || true
      echo
      echo "===== visible FUSE overlay mounts ====="
      findmnt -rn -t fuse.fuse-overlayfs,fuse-overlayfs -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 || true
      podman unshare findmnt -rn -t fuse.fuse-overlayfs,fuse-overlayfs -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 || true
      echo
      echo "===== Podman storage probes ====="
      timeout 30 podman images --no-trunc 2>&1 || true
      timeout 30 podman ps -a 2>&1 || true
      echo
      echo "===== external Buildah containers ====="
      timeout 30 podman ps --all --external --no-trunc 2>&1 || true
   } > "$diagnosticsFile"
}
# -----------------------------------------------------------------------------
# Helper: wait for Podman storage recovery
# -----------------------------------------------------------------------------

wait_for_podman_storage() {
   local reason=$1
   local maximumWait=${2:-$STORAGE_SETTLE_SECONDS}
   local deadline=$(( $(date +%s) + maximumWait ))
   local diagnosticsFile

   [[ "$podmanEnvironmentReady" == true ]] || return 0
   [[ "${ENGINE:-}" == "podman" ]] || return 0

   echo "$reason"
   echo "Waiting up to ${maximumWait} seconds for Podman storage to become healthy."
   while (( $(date +%s) <= deadline )); do
      if podman_storage_healthy; then
         echo "Podman storage cleanup verification passed."
         echo "It is safe to start another operation using this Podman storage."
         return 0
      fi
      sleep "$STORAGE_CHECK_INTERVAL"
   done

   diagnosticsFile="${runArtifactsDir:-$PWD}/podman-storage-unhealthy.txt"
   write_podman_storage_diagnostics "$diagnosticsFile"
   echo "ERROR: Podman storage did not become healthy within ${maximumWait} seconds." >&2
   echo "       Do not start another build on this node yet." >&2
   echo "       Diagnostics: $diagnosticsFile" >&2
   return 1
}
# -----------------------------------------------------------------------------
# Helper: require systemd user-service support
# -----------------------------------------------------------------------------

require_operation_scope_support() {
   if ! command -v systemd-run >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
      echo "ERROR: systemd-run and systemctl are required for isolated service cleanup." >&2
      return 1
   fi
   if ! systemctl --user show-environment >/dev/null 2>&1; then
      echo "ERROR: The systemd user manager is not accessible." >&2
      echo "       Refusing to start a long operation without isolated cleanup." >&2
      return 1
   fi
}
# -----------------------------------------------------------------------------
# Helper: create a unique transient-service name
# -----------------------------------------------------------------------------

new_operation_unit() {
   local operationLabel=$1
   ((++operationCounter))
   activeOperationUnit="${CONTAINER_BUILD_SERVICE_PREFIX}-${thisScript//[^A-Za-z0-9_.-]/-}-$$-${operationCounter}-${operationLabel}.service"
}
# -----------------------------------------------------------------------------
# Helper: stop and reap the watchdog
# -----------------------------------------------------------------------------

stop_watchdog() {
   if [[ -n "${watchdogPid:-}" ]]; then
      kill -TERM "$watchdogPid" 2>/dev/null || true
      wait "$watchdogPid" 2>/dev/null || true
      watchdogPid=""
   fi
}
# -----------------------------------------------------------------------------
# Helper: terminate one supervised operation
# -----------------------------------------------------------------------------

# Stop one transient service in stages so Podman can run its own cleanup first.
# SIGTERM initially targets only MainPID. Descendants remain alive while Podman
# unwinds Buildah working containers and FUSE mounts. The entire cgroup is touched
# only if the service remains active after the main-process grace period.
terminate_operation_unit() {
   local unit=$1
   local elapsed=0
   local nextStatus=$PODMAN_TERM_STATUS_INTERVAL

   [[ -n "$unit" ]] || return 0

   echo
   echo "Requesting orderly Podman cleanup through the service main process: $unit" >&2
   # Signal only MainPID first so Podman can unwind its own Buildah and FUSE state.
   systemctl --user kill --kill-whom=main --signal=TERM "$unit" 2>/dev/null || true

   while (( elapsed < PODMAN_MAIN_TERM_GRACE_SECONDS )); do
      if ! systemctl --user is-active --quiet "$unit" 2>/dev/null; then
         return 0
      fi
      sleep 1
      ((++elapsed))
      if (( elapsed >= nextStatus )); then
         echo "Waiting for Podman cleanup: ${elapsed}/${PODMAN_MAIN_TERM_GRACE_SECONDS} seconds" >&2
         nextStatus=$((nextStatus + PODMAN_TERM_STATUS_INTERVAL))
      fi
   done

   echo "Podman did not finish cleanup; sending SIGTERM to the complete operation cgroup." >&2
   # Escalate to all cgroup processes only after Podman exhausts its cleanup window.
   systemctl --user kill --kill-whom=all --signal=TERM "$unit" 2>/dev/null || true
   elapsed=0
   while (( elapsed < PODMAN_CGROUP_TERM_GRACE_SECONDS )); do
      if ! systemctl --user is-active --quiet "$unit" 2>/dev/null; then
         return 0
      fi
      sleep 1
      ((++elapsed))
   done

   echo "The operation still remains active; sending SIGKILL to the complete cgroup: $unit" >&2
   # SIGKILL is the bounded final fallback for a service that still cannot stop.
   systemctl --user kill --kill-whom=all --signal=KILL "$unit" 2>/dev/null || true
   systemctl --user stop "$unit" 2>/dev/null || true
}
# -----------------------------------------------------------------------------
# Helper: stop the tracked active operation
# -----------------------------------------------------------------------------

stop_active_operation() {
   local unit="${activeOperationUnit:-}"
   [[ -n "$unit" ]] || return 0
   terminate_operation_unit "$unit"
   activeOperationUnit=""
}
# -----------------------------------------------------------------------------
# Helper: capture one stall diagnostic snapshot
# -----------------------------------------------------------------------------

capture_stall_diagnostics() {
   local unit=$1
   local diagnosticsFile=$2
   {
      echo "Timestamp: $(date --iso-8601=seconds)"
      echo "Operation service: $unit"
      echo
      echo "===== systemctl status ====="
      systemctl --user status "$unit" --no-pager 2>&1 || true
      echo
      echo "===== service properties ====="
      systemctl --user show "$unit" \
         -p ActiveState -p SubState -p ControlGroup -p CPUUsageNSec \
         -p MemoryCurrent -p TasksCurrent 2>&1 || true
      echo
      echo "===== user processes ====="
      ps -u "$USER" -o pid,ppid,stat,%cpu,%mem,etime,wchan:32,cmd --sort=-%cpu 2>&1 || true
      echo
      echo "===== load and memory ====="
      uptime 2>&1 || true
      free -h 2>&1 || true
   } >> "$diagnosticsFile"
}
# -----------------------------------------------------------------------------
# Helper: monitor operation progress
# -----------------------------------------------------------------------------

monitor_operation_progress() {
   local unit=$1
   local runnerPid=$2
   local monitoredLog=$3
   local stallMarker=$4
   local diagnosticsFile=$5
   local previousSize=-1
   local lastProgress
   local currentSize
   local now
   local confirmationDeadline

   previousSize=$(stat -c %s "$monitoredLog" 2>/dev/null || printf '0')
   lastProgress=$(date +%s)

   while kill -0 "$runnerPid" 2>/dev/null; do
      sleep "$STALL_CHECK_INTERVAL"
      kill -0 "$runnerPid" 2>/dev/null || return 0

      currentSize=$(stat -c %s "$monitoredLog" 2>/dev/null || printf '0')
      now=$(date +%s)
      if [[ "$currentSize" != "$previousSize" ]]; then
         previousSize=$currentSize
         lastProgress=$now
         continue
      fi

      if (( now - lastProgress < STALL_SILENCE_SECONDS )); then
         continue
      fi

      {
         echo "ERROR: The operation has produced no new log output for ${STALL_SILENCE_SECONDS} seconds."
         echo "A bounded ${STALL_CONFIRMATION_SECONDS}-second confirmation and diagnostics period has started."
         echo "The operation will be stopped when that period expires, even if its state remains ambiguous."
         echo "Operation service: $unit"
         echo "Diagnostics file: $diagnosticsFile"
      } | tee -a "$monitoredLog" >&2

      : > "$diagnosticsFile"
      confirmationDeadline=$((now + STALL_CONFIRMATION_SECONDS))
      while kill -0 "$runnerPid" 2>/dev/null && (( $(date +%s) < confirmationDeadline )); do
         capture_stall_diagnostics "$unit" "$diagnosticsFile"
         sleep "$STALL_CHECK_INTERVAL"
      done
      kill -0 "$runnerPid" 2>/dev/null || return 0

      {
         echo "ERROR: The operation remained silent throughout the ${STALL_CONFIRMATION_SECONDS}-second confirmation period."
         echo "Stopping the isolated operation service and failing this script."
      } | tee -a "$monitoredLog" >&2
      printf '%s\n' "stalled" > "$stallMarker"
      terminate_operation_unit "$unit"
      return 0
   done
}
# -----------------------------------------------------------------------------
# Helper: perform centralized exit cleanup
# -----------------------------------------------------------------------------

cleanup_on_exit() {
   local exitStatus=$?
   trap - EXIT HUP INT TERM
   stop_watchdog
   stop_active_operation
   if [[ -n "${operationRunnerPid:-}" ]]; then
      kill -TERM "$operationRunnerPid" 2>/dev/null || true
      wait "$operationRunnerPid" 2>/dev/null || true
   fi
   if [[ "$operationWasStarted" == true && "$storageVerifiedAfterOperation" != true ]]; then
      if wait_for_podman_storage \
         "Verifying Podman storage after the interrupted or failed operation."; then
         storageVerifiedAfterOperation=true
      else
         exitStatus=1
      fi
   fi
   exit "$exitStatus"
}

# EXIT covers normal and error returns. HUP, INT, and TERM cover terminal
# loss, Ctrl-C, and ordinary kill requests; SIGKILL cannot be trapped.
trap cleanup_on_exit EXIT HUP INT TERM

# =============================================================================
# Command-line help
# =============================================================================
# -----------------------------------------------------------------------------
# Helper: print command-line usage
# -----------------------------------------------------------------------------
usage() {
   cat <<USAGE
Usage:
  $thisScript --recipe-dir <directory> [options] --engine docker|podman [<imageFull>]
  $thisScript --recipe-dir <directory> [options] --fromRegistryImage <registry/imageName:imageTag>
  $thisScript --help

Required source selection:
  --engine, -b <engine>         Local source-image engine: docker or podman.
  --fromRegistryImage <image>   Remote registry image; docker:// is optional.

Recipe and output options:
  --recipe-dir, -r <directory>  OpenFOAM version directory containing the
                                configuration and Docker recipe.
  --output-dir, -o <directory>  Explicit SIF destination. This does not validate
                                or promote the image for production use.
  --build-arg NAME=VALUE        Supported source-image override; may be repeated.
  <imageFull>                   Optional local image name:tag.

Singularity runtime option:
  --singularity-module <module> Module used to create the SIF for Podman and
                                registry sources.
                                Default: singularity/4.3.5-mpi
                                Docker mode uses ~/setup_singularity.sh and does
                                not accept an explicit module override.

General:
  --help, -h                    Show this help message and exit.
USAGE
}

# =============================================================================
# Parse and validate command-line arguments
# =============================================================================
ENGINE=""
REGO_IMAGE=""
singularityModule="singularity/4.3.5-mpi"
singularityModuleSpecified=false
positionalArgs=()
while [[ $# -gt 0 ]]; do
   case $1 in
      --recipe-dir|-r)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --recipe-dir requires <directory>" >&2
            usage >&2
            exit 1
         fi
         recipeDirInput="$2"
         shift 2
         ;;
      --output-dir|-o)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --output-dir requires <directory>" >&2
            usage >&2
            exit 1
         fi
         outputDirInput="$2"
         shift 2
         ;;
      --engine|-b)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --engine requires docker|podman" >&2
            usage >&2
            exit 1
         fi
         ENGINE="$2"
         shift 2
         ;;
      --build-arg)
         if [[ $# -lt 2 || "$2" != *=* ]]; then
            echo "ERROR: --build-arg requires NAME=VALUE" >&2
            exit 1
         fi
         buildArgName="${2%%=*}"
         buildArgValue="${2#*=}"
         if [[ ! "$buildArgName" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "ERROR: Invalid build-argument name: '$buildArgName'" >&2
            exit 1
         fi
         buildArgs+=(--build-arg "$2")
         buildArgValues["$buildArgName"]="$buildArgValue"
         shift 2
         ;;
      --singularity-module)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --singularity-module requires <module>" >&2
            usage >&2
            exit 1
         fi
         singularityModule="$2"
         singularityModuleSpecified=true
         shift 2
         ;;
      --fromRegistryImage)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --fromRegistryImage requires <registry/imageName:imageTag>" >&2
            usage >&2
            exit 1
         fi
         REGO_IMAGE="$2"
         shift 2
         ;;
      -h|--help)
         usage
         exit 0
         ;;
      -*)
         echo "ERROR: Unknown option '$1'" >&2
         usage >&2
         exit 1
         ;;
      *)
         positionalArgs+=("$1")
         shift
         ;;
   esac
done

# Docker-source builds use the host-specific setup script rather than a Pawsey
# module. Reject an explicit module option instead of silently ignoring it.
if [[ "$singularityModuleSpecified" == true && "$ENGINE" == "docker" && -z "$REGO_IMAGE" ]]; then
   echo "ERROR: --singularity-module cannot be used with --engine docker" >&2
   usage >&2
   exit 1
fi

# =============================================================================
# Require and resolve the recipe directory
# =============================================================================
if [[ -z "$recipeDirInput" ]]; then
   echo "ERROR: --recipe-dir <directory> is required" >&2
   usage >&2
   exit 1
fi
if [[ ! -d "$recipeDirInput" ]]; then
   echo "ERROR: Recipe directory does not exist: $recipeDirInput" >&2
   exit 1
fi
recipeDir=$(cd -- "$recipeDirInput" && pwd)
configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
if [[ ! -r "$configFile" ]]; then
   echo "ERROR: Build-validation configuration is not readable: $configFile" >&2
   exit 1
fi
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || {
      echo "ERROR: $requiredSetting is not defined in $configFile" >&2
      exit 1
   }
done
recipeFile="${recipeDir}/${OPENFOAM_FORK}--${OPENFOAM_VERSION}.dockerfile"
if [[ ! -f "$recipeFile" ]]; then
   echo "ERROR: OpenFOAM docker recipe not found: $recipeFile" >&2
   exit 1
fi

# =============================================================================
# Validate build-argument names against the selected recipe
# =============================================================================
# Every Dockerfile ARG is recorded as declared. Only an ARG immediately preceded
# by a USER_BUILD_ARG marker is exposed as a supported command-line override.
# This catches misspelled names and prevents fixed recipe settings from being
# changed through this builder.
declare -A declaredBuildArgs=()
declare -A supportedBuildArgs=()
pendingUserBuildArg=false
while IFS= read -r recipeLine; do
   if [[ "$recipeLine" =~ ^[[:space:]]*#[[:space:]]*USER_BUILD_ARG[[:space:]]*$ ]]; then
      pendingUserBuildArg=true
      continue
   fi

   if [[ "$recipeLine" =~ ^[[:space:]]*ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; then
      declaredArgumentName="${BASH_REMATCH[1]}"
      declaredBuildArgs["$declaredArgumentName"]=1
      if [[ "$pendingUserBuildArg" == true ]]; then
         supportedBuildArgs["$declaredArgumentName"]=1
      fi
      pendingUserBuildArg=false
      continue
   fi

   if [[ "$pendingUserBuildArg" == true && ! "$recipeLine" =~ ^[[:space:]]*$ ]]; then
      echo "ERROR: USER_BUILD_ARG marker is not followed by an ARG instruction in: $recipeFile" >&2
      echo "       Unexpected line: $recipeLine" >&2
      exit 1
   fi
done < "$recipeFile"

if [[ "$pendingUserBuildArg" == true ]]; then
   echo "ERROR: USER_BUILD_ARG marker at the end of $recipeFile has no following ARG instruction" >&2
   exit 1
fi
if (( ${#declaredBuildArgs[@]} == 0 )); then
   echo "ERROR: No ARG instructions were found in: $recipeFile" >&2
   exit 1
fi

for argumentName in "${!buildArgValues[@]}"; do
   if [[ ! -v "declaredBuildArgs[$argumentName]" ]]; then
      echo "ERROR: Unknown build argument: $argumentName" >&2
      echo "       No ARG named '$argumentName' is declared in: $recipeFile" >&2
      exit 1
   fi
   if [[ ! -v "supportedBuildArgs[$argumentName]" ]]; then
      echo "ERROR: Build argument '$argumentName' is fixed by the selected recipe" >&2
      echo "       and is not exposed as a supported user override." >&2
      exit 1
   fi
done

tmpDir="${recipeDir}/tmp"
artifactsDir="${recipeDir}/artifacts"
singularityArtifactsDir="${artifactsDir}/singularity"
mkdir -p "$tmpDir" "$singularityArtifactsDir"
latestLink="${singularityArtifactsDir}/latest"
if [[ -e "$latestLink" && ! -L "$latestLink" ]]; then
   echo "ERROR: Refusing to remove non-symbolic-link path: $latestLink" >&2
   exit 1
fi
if ! rm -f "$latestLink"; then
   echo "ERROR: Failed to remove latest link: $latestLink" >&2
   exit 1
fi
echo "This directory contains disposable temporary files only. It can be removed anytime." > "${tmpDir}/README.txt"
echo "This directory contains timestamped build artifacts. The latest link identifies the most recent tracked build invocation. If the link is absent, the most recent command failed before invocation tracking was established." > "${singularityArtifactsDir}/README.txt"

# =============================================================================
# Select and validate the source-image mode
# =============================================================================
# Registry mode uses --fromRegistryImage. Otherwise, local mode requires Docker
# or Podman and accepts at most one positional local image reference.
if [[ -n "$REGO_IMAGE" ]]; then
   MODE="registry"
else
   MODE="local"
fi

if [[ "$MODE" == "registry" ]]; then
   if [[ ${#buildArgs[@]} -gt 0 ]]; then
      echo "ERROR: --build-arg cannot be used with --fromRegistryImage" >&2
      echo "       The explicit registry image reference already selects the source image." >&2
      exit 1
   fi
   # Warn and ignore --engine if provided
   if [[ -n "$ENGINE" ]]; then
      echo "WARNING: --engine '$ENGINE' ignored when using --fromRegistryImage"
      ENGINE=""
   fi

   # Error if positional arguments were provided
if [[ ${#positionalArgs[@]} -gt 0 ]]; then
      echo "ERROR: --fromRegistryImage is in use. The full 'registry/imageName:imageTag'" >&2
      echo "       must be provided immediately after. No additional positional arguments are allowed." >&2
      usage >&2
      exit 1
   fi
else
   # Local mode: --engine is required
   if [[ -z "$ENGINE" ]]; then
      echo "ERROR: --engine docker|podman is required" >&2
      usage >&2
      exit 1
   fi
   if [[ "$ENGINE" != "docker" && "$ENGINE" != "podman" ]]; then
      echo "ERROR: --engine must be 'docker' or 'podman', got '$ENGINE'" >&2
      usage >&2
      exit 1
   fi

   # Positional argument validation
   if [[ ${#positionalArgs[@]} -gt 1 ]]; then
      echo "ERROR: At most 1 positional argument allowed (imageFull)" >&2
      usage >&2
      exit 1
   fi
   if [[ ${#positionalArgs[@]} -eq 1 ]]; then
      if [[ ${#buildArgs[@]} -gt 0 ]]; then
         echo "ERROR: --build-arg cannot be used with an explicit local image reference" >&2
         echo "       The positional image name and tag already select the source image." >&2
         exit 1
      fi
      imageFull="${positionalArgs[0]}"
      echo "Will build singularity image from: $imageFull"
   else
      echo "No imageFull provided, using docker recipe defaults from: $recipeFile"
   fi
fi

# =============================================================================
# Create the persistent artifact directory for this invocation
# =============================================================================
# The source mode identifies the invocation without requiring inspection of its
# contents. The latest link is deliberately updated only after a successful SIF
# build, so automated tests never default to a failed candidate.
if [[ "$MODE" == "registry" ]]; then
   sourceKind="registry"
else
   sourceKind="$ENGINE"
fi
buildTimestamp=$(date '+%Y%m%dT%H%M%S%z')
runArtifactsName="${buildTimestamp}_${sourceKind}"
runArtifactsDir="${singularityArtifactsDir}/${runArtifactsName}"
if ! mkdir "$runArtifactsDir"; then
   echo "ERROR: Cannot create invocation artifact directory: $runArtifactsDir" >&2
   exit 1
fi

ln -sfn "$runArtifactsName" "${singularityArtifactsDir}/latest"
runLog="${runArtifactsDir}/run.log"
buildLog="${runArtifactsDir}/build.log"
saveLog="${runArtifactsDir}/save.log"
buildCommandFile="${runArtifactsDir}/build-command.txt"
imageDetailsFile="${runArtifactsDir}/image-details.txt"
sourceBuildArgumentsFile="${runArtifactsDir}/source-image-build-arguments.txt"

# Preserve the complete script output while continuing to display it.
exec > >(tee "$runLog") 2>&1

echo "Invocation artifacts: $runArtifactsDir"
echo "Complete run log: $runLog"
echo

# =============================================================================
# Step 1: Resolve the source and output image names
# =============================================================================
# Registry and explicit local references provide their own name and tag. When a
# local reference is omitted, derive both from the recipe Dockerfile defaults.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Resolving image naming"
if [[ "$MODE" == "registry" ]]; then
   # Normalize: ensure docker:// prefix
   if [[ "$REGO_IMAGE" != docker://* ]]; then
      REGO_IMAGE="docker://${REGO_IMAGE}"
   fi
   # Derive imageName and imageTag from the registry path
   # Strip docker:// prefix, then extract name and tag
   regoPath="${REGO_IMAGE#docker://}"
   if [[ "$regoPath" == *:* ]]; then
      imageTag="${regoPath##*:}"
      imageNamePath="${regoPath%:*}"
   else
      imageTag="latest"
      imageNamePath="$regoPath"
   fi
   # Use the last component of the path as imageName (e.g. "quay.io/org/myimage" -> "myimage")
   imageName="${imageNamePath##*/}"
   echo "  Source: --fromRegistryImage"
   echo "  REGO_IMAGE: $REGO_IMAGE"
elif [[ -n "$imageFull" ]]; then
   if [[ "$imageFull" != *:* ]]; then
      echo "ERROR: Local image must include a tag: $imageFull" >&2
      usage >&2
      exit 1
   fi
   imageTag="${imageFull##*:}"
   imageNamePath="${imageFull%:*}"
   imageName="${imageNamePath##*/}"
   echo "  Source: positional argument"
   echo "  imageFull: $imageFull"
else
   OF_FORK=$(grep '^ARG OF_FORK=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   OF_VERSION=$(grep '^ARG OF_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   GCC_VERSION=$(grep '^ARG GCC_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   WM_LABEL_SIZE=$(grep '^ARG WM_LABEL_SIZE=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   WM_PRECISION_OPTION=$(grep '^ARG WM_PRECISION_OPTION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   WM_COMPILE_OPTION=$(grep '^ARG WM_COMPILE_OPTION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   OS_VERSION=$(grep '^ARG BASE_IMAGE_OS_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
   MPICH_VERSION=$(grep '^ARG BASE_IMAGE_MPICH_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)

   # Apply command-line overrides that affect the derived source-image reference.
   # The last repeated --build-arg value wins.
   OF_FORK="${buildArgValues[OF_FORK]:-$OF_FORK}"
   OF_VERSION="${buildArgValues[OF_VERSION]:-$OF_VERSION}"
   WM_LABEL_SIZE="${buildArgValues[WM_LABEL_SIZE]:-$WM_LABEL_SIZE}"
   WM_PRECISION_OPTION="${buildArgValues[WM_PRECISION_OPTION]:-$WM_PRECISION_OPTION}"
   WM_COMPILE_OPTION="${buildArgValues[WM_COMPILE_OPTION]:-$WM_COMPILE_OPTION}"
   OS_VERSION="${buildArgValues[BASE_IMAGE_OS_VERSION]:-$OS_VERSION}"
   MPICH_VERSION="${buildArgValues[BASE_IMAGE_MPICH_VERSION]:-$MPICH_VERSION}"

   echo "  Source: Dockerfile defaults and supported build-argument overrides"
   echo "  OF_FORK: '$OF_FORK'"
   echo "  OF_VERSION: '$OF_VERSION'"
   echo "  GCC_VERSION: '$GCC_VERSION'"
   echo "  WM_LABEL_SIZE: '$WM_LABEL_SIZE'"
   echo "  WM_PRECISION_OPTION: '$WM_PRECISION_OPTION'"
   echo "  WM_COMPILE_OPTION: '$WM_COMPILE_OPTION'"
   echo "  OS_VERSION: '$OS_VERSION'"
   echo "  MPICH_VERSION: '$MPICH_VERSION'"
   if [[ -z "$OF_FORK" || -z "$OF_VERSION" || -z "$GCC_VERSION" || \
         -z "$WM_LABEL_SIZE" || -z "$WM_PRECISION_OPTION" || -z "$WM_COMPILE_OPTION" || \
         -z "$OS_VERSION" || -z "$MPICH_VERSION" ]]; then
      echo "✖ Step $testNum FAIL: Failed to extract required variables from Dockerfile"
      ((totalFailed++))
      exit 1
   fi

   # Record only the source-image build-argument overrides requested for this conversion.
   {
      echo "# Source-image build-argument overrides requested for this Singularity conversion."
      if [[ ${#buildArgValues[@]} -eq 0 ]]; then
         echo "# None. Dockerfile defaults were used."
      else
         for argumentName in "${!buildArgValues[@]}"; do
            printf '%s=%q
' "$argumentName" "${buildArgValues[$argumentName]}"
         done | sort
      fi
   } > "$sourceBuildArgumentsFile"

   imageName="${OF_FORK}"
   imageTag="${OF_VERSION}-gcc${GCC_VERSION}${WM_PRECISION_OPTION}Int${WM_LABEL_SIZE}${WM_COMPILE_OPTION}-mpich${MPICH_VERSION}-ubuntu${OS_VERSION}"
   imageFull="${imageName}:${imageTag}"

   # Explain how each override is handled by this conversion. Tag-forming
   # arguments identify the existing local source image. Other arguments may
   # describe how that image was built, but Singularity cannot apply them while
   # converting the already-built image.
   declare -A tagFormingBuildArgs=(
      [OF_FORK]=1
      [OF_VERSION]=1
      [GCC_VERSION]=1
      [WM_LABEL_SIZE]=1
      [WM_PRECISION_OPTION]=1
      [WM_COMPILE_OPTION]=1
      [BASE_IMAGE_OS_VERSION]=1
      [BASE_IMAGE_MPICH_VERSION]=1
   )
   for argumentName in "${!buildArgValues[@]}"; do
      if [[ -v "tagFormingBuildArgs[$argumentName]" ]]; then
         echo "NOTICE: --build-arg ${argumentName}=${buildArgValues[$argumentName]} is used to identify the local source-image tag."
      else
         echo "NOTICE: --build-arg ${argumentName}=${buildArgValues[$argumentName]} is accepted by the selected recipe but does not form part of the image tag."
         echo "        It is not applied during the Singularity conversion; the existing local image '${imageFull}' will be converted."
      fi
   done
fi
echo "  imageName: $imageName"
echo "  imageTag:  $imageTag"
expectedSourcePrefix="${OPENFOAM_FORK}:${OPENFOAM_VERSION}"
resolvedSourceName="${imageName}:${imageTag}"
if [[ "$resolvedSourceName" != "${expectedSourcePrefix}"* ]]; then
   echo "✖ Step $testNum FAIL: Source image name does not match the configured OpenFOAM identity"
   echo "  Source image name: $resolvedSourceName"
   echo "  Required prefix:  $expectedSourcePrefix"
   ((totalFailed++)); exit 1
fi
echo "✓ Step $testNum PASS: Source image name starts with '$expectedSourcePrefix'"
echo

# =============================================================================
# Step 2: Set up the local source-image engine
# =============================================================================
# This step is skipped for registry mode. Docker Desktop is started when needed,
# while Pawsey Podman builds source the site container setup script.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   echo "Step $testNum skipped. Not needed for --fromRegistryImage (no local engine required)"
else
   echo "Step $testNum - Setting up $ENGINE environment"
   if [[ "$ENGINE" == "docker" ]]; then
      echo "Step $testNum - Starting Docker engine"
      if ! docker info >/dev/null 2>&1; then
         echo "Starting Docker Desktop..."
         open -a Docker
         # Wait max 30s
         for i in {1..30}; do
            if docker info >/dev/null 2>&1; then
               break
            fi
            sleep 1
         done
      fi
      if ! docker info >/dev/null 2>&1; then
         echo "✖ Step $testNum FAIL: Docker failed to start"
         ((totalFailed++))
         exit 1
      fi
   else
      echo "Step $testNum - Sourcing the podman settings"
      # Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
      if ! source /container/setup_podman.sh 2>/dev/null; then
         echo "✖ Step $testNum FAIL: Failed to: source /container/setup_podman.sh"
         ((totalFailed++))
         exit 1
      fi
   fi
   echo "✓ Step $testNum PASS: ${ENGINE^} ready"
fi

# Preserve the invoking shell environment that the selected local engine or
# Singularity requires when an operation runs in a transient user service.
build_service_environment
echo

# =============================================================================
# Step 3: Confirm that the local container engine is accessible
# =============================================================================
# Registry mode does not need a local engine. Podman also requires XDG_DATA_HOME
# to have been initialized by the Pawsey setup script.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   echo "Step $testNum skipped. Not needed for --fromRegistryImage (no local engine required)"
else
   echo "Step $testNum - Checking if $ENGINE is accessible."
   engineVersion=$($ENGINE --version)
   if [[ -z "$engineVersion" ]]; then
      echo "✖ Step $testNum FAIL: Failed to execute: $ENGINE --version"
      ((totalFailed++))
      exit 1
   fi
   echo "✓ Step $testNum ${ENGINE}Version=$engineVersion"
   if [[ "$ENGINE" == "podman" ]]; then
      # Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
      if [[ -z "$XDG_DATA_HOME" ]]; then
         echo "✖ Step $testNum FAIL: Failed to check existance of: XDG_DATA_HOME"
         echo "  Probably forgot to: source /container/setup_podman.sh"
         ((totalFailed++))
         exit 1
      fi
      echo "✓ Step $testNum XDG_DATA_HOME=$XDG_DATA_HOME"
   fi
   echo "✓ Step $testNum PASS"
fi
echo

# =============================================================================
# Step 4: Set up the Singularity environment
# =============================================================================
# Docker-hosted conversion uses the local setup_singularity.sh environment.
# Podman and remote-registry conversion use Pawsey's Singularity module.
((++testNum))
echo "$thisScript: Step $testNum - Loading Singularity Environment"
if [[ "$ENGINE" == "docker" ]]; then
   # Adapt the check to your own system needs.
   if ! source "${HOME}/setup_singularity.sh" 2>/dev/null; then
      echo "✖ Step $testNum FAIL: Failed to: source ${HOME}/setup_singularity.sh"
      ((totalFailed++))
      exit 1
   fi
else
   # Check for use only on restricted Container-Building nodes at Pawsey. Adapt the check to your own system needs.
   # This branch is also used for --fromRegistryImage mode (no local engine).
   if ! module load "$singularityModule" 2>/dev/null; then
      echo "✖ Step $testNum FAIL: Failed to load Singularity module: $singularityModule"
      ((totalFailed++))
      exit 1
   fi
fi
echo "Singularity module: $([[ "$ENGINE" == "docker" ]] && echo "host setup script" || echo "$singularityModule")"
echo "✓ Step $testNum PASS"
echo

# =============================================================================
# Step 5: Confirm that Singularity is accessible
# =============================================================================
# A nonempty version response confirms that the Singularity command is ready.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking if singularity is accessible."
singularityVersion=$(singularity --version)
if [[ -z "$singularityVersion" ]]; then
   echo "✖ Step $testNum FAIL: Failed to execute: singularity --version"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum singularityVersion=$singularityVersion"
echo "✓ Step $testNum PASS"
echo

# =============================================================================
# Step 6: Verify the source image in the local image store
# =============================================================================
# This check is skipped for remote registry sources. Podman normally stores an
# unqualified image below localhost/, while Docker uses the reference directly.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   echo "Step $testNum skipped. Not needed for --fromRegistryImage (image is in a remote registry)"
else
   echo "Step $testNum - Verifying image $imageFull exists in $ENGINE local registry"
   if [[ $ENGINE == "podman" ]]; then
      imageLocal="localhost/${imageFull}"
   else
      imageLocal="${imageFull}"
   fi
   imageExists=false
   if $ENGINE images -q "${imageLocal}" | grep -q .; then
      imageExists=true
   fi
   if [[ "$imageExists" == true ]]; then
      imageReference=$($ENGINE images "${imageLocal}" --format '{{.Repository}}:{{.Tag}}' | grep "${imageLocal}")
      imageSize=$($ENGINE images --format "{{.Size}}" "${imageLocal}" | head -n1)
      echo "✓ Step $testNum PASS: Image found!"
      echo "  Local Reference: $imageReference"
      echo "  Size: $imageSize"
   else
      if [[ $ENGINE == "podman" ]]; then
         echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in $ENGINE \"localhost/\" local registry"
      else
         echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in $ENGINE local registry"
      fi
      ((totalFailed++))
      exit 1
   fi
fi
echo

# =============================================================================
# Step 7: Export a Podman source image as an OCI archive
# =============================================================================
# podman save reads the existing image store but does not create Buildah working
# containers. This path therefore uses service isolation and storage/FUSE health
# checks without the build-specific external-container removal fallback.
# Singularity can read Docker directly, but the Podman path uses an OCI archive.
# Registry mode also skips this step because Singularity pulls the image itself.
((++testNum))
imageTar=""
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   echo "Step $testNum skipped. Not needed for --fromRegistryImage (singularity pulls directly)"
elif [[ "$ENGINE" == "podman" ]]; then
   imageTar="${tmpDir}/${imageName}--${imageTag}.${buildTimestamp}.$$.tar"
   logFile="$saveLog"
   echo "Step $testNum - Saving the podman image ${imageFull} in oci-archive format"
   echo "Log of the process in $logFile"
   require_operation_scope_support || exit 1

   # Ensure that Podman sees the same storage inside the transient service.
   shellGraphRoot=$(podman info --format '{{.Store.GraphRoot}}')
   preflightUnit="${CONTAINER_BUILD_SERVICE_PREFIX}-${thisScript//[^A-Za-z0-9_.-]/-}-$$-podman-environment-check.service"
   serviceGraphRoot=$(
      systemd-run --user --wait --pipe --quiet --collect --service-type=exec \
         --unit="$preflightUnit" "${serviceEnvironment[@]}" -- \
         podman info --format '{{.Store.GraphRoot}}'
   )
   preflightExit=$?
   if [[ $preflightExit -ne 0 || -z "$serviceGraphRoot" ]]; then
      echo "ERROR: Podman failed inside the isolated systemd user service." >&2
      echo "       The OCI archive export has not been started." >&2
      exit 1
   fi
   if [[ "$serviceGraphRoot" != "$shellGraphRoot" ]]; then
      echo "ERROR: Podman storage differs inside the isolated systemd user service." >&2
      echo "       Shell GraphRoot:   $shellGraphRoot" >&2
      echo "       Service GraphRoot: $serviceGraphRoot" >&2
      echo "       The OCI archive export has not been started." >&2
      exit 1
   fi
   podmanGraphRoot="$shellGraphRoot"
   podmanEnvironmentReady=true
   echo "Podman storage identity check passed: GraphRoot=$podmanGraphRoot"
   wait_for_podman_storage \
      "Performing the pre-operation Podman storage-health check." 60 || exit 1
   new_operation_unit save
   stallMarker="${runArtifactsDir}/save-stalled.marker"
   stallDiagnostics="${runArtifactsDir}/save-stall-diagnostics.txt"
   operationStatusFile="${runArtifactsDir}/save-operation.status"
   rm -f "$stallMarker" "$stallDiagnostics" "$operationStatusFile"
   echo "Save process service: $activeOperationUnit"
   echo "Save inactivity limit: ${STALL_SILENCE_SECONDS} seconds plus a bounded ${STALL_CONFIRMATION_SECONDS}-second confirmation period"
   (
      systemd-run --user --wait --pipe --quiet --collect --service-type=exec \
         --unit="$activeOperationUnit" "${serviceEnvironment[@]}" -- \
         "$ENGINE" save --format=oci-archive "localhost/${imageFull}" -o "$imageTar"
      printf '%s\n' "$?" > "$operationStatusFile"
   ) |& tee "$logFile" &
   operationWasStarted=true
   storageVerifiedAfterOperation=false
   operationRunnerPid=$!
   monitor_operation_progress "$activeOperationUnit" "$operationRunnerPid" \
      "$logFile" "$stallMarker" "$stallDiagnostics" &
   watchdogPid=$!
   wait "$operationRunnerPid"
   operationRunnerPid=""
   stop_watchdog
   saveExit=$(cat "$operationStatusFile" 2>/dev/null || printf '1')
   statusAll=("$saveExit" "0")
   activeOperationUnit=""
   if [[ $saveExit -ne 0 || -f "$stallMarker" ]]; then
      if wait_for_podman_storage \
         "Verifying Podman storage after the stopped or failed OCI archive export."; then
         :
      fi
      storageVerifiedAfterOperation=true
   fi
   if [[ -f "$stallMarker" ]]; then
      echo "ERROR: The Podman save was terminated by the inactivity supervisor."
      echo "Diagnostics: $stallDiagnostics"
      exit 1
   fi
   #echo "saveExit=$saveExit"
   #echo "statusAll=${statusAll[*]}"
   if [[ -f "$imageTar" && $saveExit -eq 0 ]]; then
      echo "✓ Step $testNum PASS: $imageTar was created successfully"
   else
      echo "✖ Step $testNum FAIL: $imageTar was NOT created, or an error was detected during the save command"
      echo "saveExit=$saveExit"
      echo "statusAll=${statusAll[*]}"
      ((totalFailed++))
      exit 1
   fi
else
   echo "Step $testNum skipped. Not needed for docker (singularity reads from docker-daemon directly)"
fi
echo

# =============================================================================
# Step 8: Build the Singularity SIF image
# =============================================================================
# Select docker://, docker-daemon://, or oci-archive:// according to the source
# mode. The default SIF destination is the invocation artifact directory.
((++testNum))
if [[ -n "$outputDirInput" ]]; then
   mkdir -p "$outputDirInput"
   directorySif=$(cd -- "$outputDirInput" && pwd)
else
   directorySif="$runArtifactsDir"
fi
imageSif="${directorySif}/${imageName}--${imageTag}.sif"
imageSifName=$(basename "$imageSif")
expectedSifPrefix="${OPENFOAM_FORK}--${OPENFOAM_VERSION}"
if [[ "$imageSifName" != "${expectedSifPrefix}"*.sif ]]; then
   echo "✖ Step $testNum FAIL: Generated SIF filename does not match the configured OpenFOAM identity"
   echo "  Generated filename: $imageSifName"
   echo "  Required pattern:   ${expectedSifPrefix}*.sif"
   ((totalFailed++)); exit 1
fi
echo "✓ Step $testNum: Generated SIF filename matches '${expectedSifPrefix}*.sif'"
logFile="$buildLog"
if [[ -f "$imageSif" ]]; then mv "$imageSif" "${imageSif}.bak"; fi
echo "$thisScript: -----------------------------------------"
if [[ "$MODE" == "registry" ]]; then
   singularitySource="$REGO_IMAGE"
elif [[ "$ENGINE" == "docker" ]]; then
   singularitySource="docker-daemon://${imageFull}"
else
   singularitySource="oci-archive://${imageTar}"
fi
buildCommand=(singularity build "$imageSif" "$singularitySource")
echo "Step $testNum - Building the singularity image ${imageSif} from ${singularitySource}"
echo "Log of the process in $logFile"
printf 'Recorded build command:'
printf ' %q' "${buildCommand[@]}"
printf '\n'
printf '%q ' "${buildCommand[@]}" > "$buildCommandFile"
printf '\n' >> "$buildCommandFile"
require_operation_scope_support || exit 1
new_operation_unit singularity-build
stallMarker="${runArtifactsDir}/singularity-build-stalled.marker"
stallDiagnostics="${runArtifactsDir}/singularity-build-stall-diagnostics.txt"
operationStatusFile="${runArtifactsDir}/singularity-build-operation.status"
rm -f "$stallMarker" "$stallDiagnostics" "$operationStatusFile"
echo "Build process service: $activeOperationUnit"
echo "Build inactivity limit: ${STALL_SILENCE_SECONDS} seconds plus a bounded ${STALL_CONFIRMATION_SECONDS}-second confirmation period"
(
   systemd-run --user --wait --pipe --quiet --collect --service-type=exec \
      --unit="$activeOperationUnit" "${serviceEnvironment[@]}" -- \
      "${buildCommand[@]}"
   printf '%s\n' "$?" > "$operationStatusFile"
) |& tee "$logFile" &
operationWasStarted=true
storageVerifiedAfterOperation=false
operationRunnerPid=$!
monitor_operation_progress "$activeOperationUnit" "$operationRunnerPid" \
   "$logFile" "$stallMarker" "$stallDiagnostics" &
watchdogPid=$!
wait "$operationRunnerPid"
operationRunnerPid=""
stop_watchdog
buildExit=$(cat "$operationStatusFile" 2>/dev/null || printf '1')
statusAll=("$buildExit" "0")
activeOperationUnit=""
operationWasStarted=false
if [[ -f "$stallMarker" ]]; then
   echo "ERROR: The Singularity build was terminated by the inactivity supervisor."
   echo "Diagnostics: $stallDiagnostics"
   exit 1
fi
#echo "buildExit=$buildExit"
#echo "statusAll=${statusAll[*]}"
if [[ -f "$imageSif" && $buildExit -eq 0 ]]; then
   echo "✓ Step $testNum PASS: $imageSif was created successfully"
   echo "The singularity image is:"
   ls -lath "$imageSif"
   imageChecksum=$(sha256sum "$imageSif" | awk '{print $1}')
   {
      echo "Mode: $MODE"
      echo "Source kind: $sourceKind"
      echo "Source image: $singularitySource"
      echo "Source image name: $imageName"
      echo "Source image tag: $imageTag"
      if [[ -n "${GCC_VERSION:-}" ]]; then
         echo "GCC version: $GCC_VERSION"
         echo "WM label size: $WM_LABEL_SIZE"
         echo "WM precision option: $WM_PRECISION_OPTION"
         echo "WM compile option: $WM_COMPILE_OPTION"
         echo "Source build-argument overrides: $sourceBuildArgumentsFile"
      fi
      echo "SIF image: $imageSif"
      echo "SIF SHA256: $imageChecksum"
      echo "Build timestamp: $buildTimestamp"
      echo "Recipe directory: ${recipeDir:-none}"
      echo "Singularity module: $([[ "$ENGINE" == "docker" ]] && echo "host setup script" || echo "$singularityModule")"
      echo "Singularity version: $singularityVersion"
      echo "Build command file: $buildCommandFile"
      echo "Build log: $buildLog"
      echo "Complete run log: $runLog"
   } > "$imageDetailsFile"
   if [[ -n "$imageTar" ]]; then
      rm -f "$imageTar"
   fi
   echo "Latest invocation: ${singularityArtifactsDir}/latest"
   echo "Note: Once you test it, promote it into the correct permanent directory for production"
else
   echo "✖ Step $testNum FAIL: $imageSif was NOT created, or an error was detected during the build command"
   echo "buildExit=$buildExit"
   echo "statusAll=${statusAll[*]}"
   ((totalFailed++))
   exit 1
fi
echo

# =============================================================================
# Final summary
# =============================================================================
# Return success only after the requested SIF exists and singularity build exits
# successfully. All earlier setup and source-image failures return status 1.
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Total steps run: $testNum"
echo "Invocation artifacts: $runArtifactsDir"
echo "SIF image: $imageSif"
echo "Singularity module: $([[ "$ENGINE" == "docker" ]] && echo "host setup script" || echo "$singularityModule")"
echo "Singularity version: $singularityVersion"
echo "Build log: $buildLog"
echo "Complete run log: $runLog"
if [[ $totalFailed -eq 0 ]]; then
   echo "✓ ALL STEPS PASSED! Image '$imageSif' was built successfully."
   exit 0
else
   echo "✖ $totalFailed STEP(S) FAILED:"
   for test in "${failedTests[@]}"; do
      echo "  - $test"
   done
   exit 1
fi
