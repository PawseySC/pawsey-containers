#!/usr/bin/env bash
# General build and validation script for OpenFOAM container images.
#
# This script builds an OpenFOAM image with Docker or Podman and then performs
# a sequence of checks on the build result. The OpenFOAM version directory is
# supplied with --recipe-dir and is used as the container build context. It must
# contain the following version-specific configuration file:
#
#   buildAndValidationConfig/openfoamBuildAndValidation.config
#
# The build-validation configuration defines the paths of the compilation and
# functional-test logs to inspect inside the completed image. The following
# settings must be defined:
#
#   THIRDPARTY_BUILD_LOG  ThirdParty authoritative compilation summary.
#   PARAVIEW_BUILD_LOG    ParaView authoritative compilation summary.
#   OPENFOAM_BUILD_LOG    OpenFOAM authoritative compilation summary.
#   OPENFOAM_TOOL_LOG     OpenFOAM basic-functionality log created at build time.
#   OPENFOAM_FORK         Expected image repository and recipe-name stem.
#   OPENFOAM_VERSION      Expected OpenFOAM version and recipe-name version.
#
# Internal paths may contain OpenFOAM environment variables such as
# $WM_THIRD_PARTY_DIR and $WM_PROJECT_DIR. These variables are preserved when
# the configuration is loaded and are expanded inside the completed image,
# where the OpenFOAM environment is available.
#
# Assign NO_CHECK to an individual log setting when that validation does not
# apply to a particular OpenFOAM version, image type, or partial build stage.
# The corresponding validation step will then be reported as skipped rather
# than failed. For example:
#
#   PARAVIEW_BUILD_LOG='NO_CHECK'
#
# The script reads the OpenFOAM fork, OpenFOAM version, compiler version,
# OpenFOAM compilation settings, operating-system version, and MPICH version
# from Dockerfile ARG instructions. These values define the generated image name.
# Only ARG instructions marked with USER_BUILD_ARG in the selected recipe can be
# overridden with --build-arg. Unknown arguments and fixed recipe arguments are
# rejected before the container engine is started. Repeated supported build
# arguments are accepted and the last supplied value is used.
#
# Docker and Podman use cached build layers by default. Supply --no-cache to make
# the selected engine execute every Dockerfile instruction without reusing cached
# layers. This affects layer reuse only; it does not automatically pull a newer
# copy of an already-local base image.
#
# A recipe can mark output from deliberately non-authoritative compilation passes
# with OPENFOAM_BUILD_SCAN_IGNORE_BEGIN and OPENFOAM_BUILD_SCAN_IGNORE_END. The
# supplementary whole-build error scan excludes only those marked ranges. The
# complete build.log and pass-specific logs remain unchanged, while errors from
# authoritative compilation passes continue to be checked normally.
#
# A complete image is built by default. For development and troubleshooting,
# --target builds a named Dockerfile stage. The optional --targetFrom setting
# temporarily changes the base of that selected stage without modifying the
# original Dockerfile. Any generated Dockerfile is kept under the version's
# tmp/ directory. Persistent output is grouped under a timestamped artifacts/
# directory for each invocation.
#
# After the build, the script verifies that the image exists in the local
# container-engine registry. It then checks the engine build log and the
# configured compilation and functional-test logs stored inside the image.
#
# Argument, setup, build, and image-registry failures stop the script
# immediately. The later diagnostic and internal-log checks continue after a
# failure so that all detected validation problems can be included in the final
# summary.
#
# Examples:
#   openfoamContainerBuild.sh --recipe-dir openfoam/v2406 --engine podman
#
#   openfoamContainerBuild.sh --recipe-dir openfoam/v2406 --engine docker \
#      --build-arg WM_LABEL_SIZE=64
#
#   openfoamContainerBuild.sh --recipe-dir openfoam/v2406 --engine podman --no-cache
#
#   openfoamContainerBuild.sh --recipe-dir openfoam/v2406 --engine podman \
#      --target openfoam-development
#
#   openfoamContainerBuild.sh --recipe-dir openfoam/v2406 --engine podman \
#      --target openfoam-development --targetFrom openfoam-base
#
#   openfoamContainerBuild.sh --help
#
# Exit status:
#   0  The image build and all enabled validation checks passed.
#   1  Invalid input, setup failure, build failure, or validation failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

# =============================================================================
# Initial settings
# =============================================================================
# Runtime state is initialized before command-line values are parsed.
thisScript=$(basename "$0")
scriptDir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
testNum=0
failedTests=()
totalFailed=0
stageName=""
buildArgs=()
declare -A buildArgValues=()
recipeDirInput=""
recipeDir=""
recipeFile=""
tmpDir=""
artifactsDir=""
runArtifactsDir=""
runLog=""
buildLog=""
buildCommandFile=""
imageDetailsFile=""
buildScanLog=""
configFile=""
noCache=false


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
externalContainersBeforeFile=""
externalContainersAfterFile=""
newExternalContainersFile=""
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
# Helper: snapshot external Buildah container IDs
# -----------------------------------------------------------------------------



# Record a stable list of external Buildah container IDs. A temporary file avoids
# replacing a valid snapshot with partial output if the Podman query fails.
snapshot_external_containers() {
   local outputFile=$1
   local temporaryFile="${outputFile}.tmp.$$"

   if ! timeout 30 podman ps --all --external --no-trunc \
      --format '{{.ID}}' > "$temporaryFile" 2>/dev/null; then
      rm -f "$temporaryFile"
      return 1
   fi
   sort -u "$temporaryFile" > "$outputFile"
   rm -f "$temporaryFile"
}
# -----------------------------------------------------------------------------
# Helper: record the pre-operation container baseline
# -----------------------------------------------------------------------------

# Capture the external-container baseline immediately before this Podman operation.
# Pre-existing records are preserved and are never attributed to this invocation.
record_external_containers_before_operation() {
   [[ "${ENGINE:-}" == "podman" ]] || return 0
   externalContainersBeforeFile="${runArtifactsDir}/external-containers-before.txt"
   externalContainersAfterFile="${runArtifactsDir}/external-containers-after.txt"
   newExternalContainersFile="${runArtifactsDir}/external-containers-new.txt"
   snapshot_external_containers "$externalContainersBeforeFile"
   rm -f "$externalContainersAfterFile" "$newExternalContainersFile"
}
# -----------------------------------------------------------------------------
# Helper: detect newly remaining external containers
# -----------------------------------------------------------------------------

# Compare the current external-container IDs with the operation baseline.
# The function is intentionally quiet because storage settling calls it repeatedly.
new_external_containers_remain() {
   [[ "${ENGINE:-}" == "podman" ]] || return 1
   [[ -f "$externalContainersBeforeFile" ]] || return 1
   snapshot_external_containers "$externalContainersAfterFile" || return 0
   comm -13 "$externalContainersBeforeFile" "$externalContainersAfterFile" \
      > "$newExternalContainersFile"
   [[ -s "$newExternalContainersFile" ]]
}
# -----------------------------------------------------------------------------
# Helper: report remaining external containers
# -----------------------------------------------------------------------------

# Print one final report after the bounded settling period has expired.
report_new_external_containers() {
   local detailsFile="${runArtifactsDir}/external-containers-new-details.txt"
   timeout 30 podman ps --all --external --no-trunc > "$detailsFile" 2>&1 || true
   echo "ERROR: New external Buildah container records remain after the operation." >&2
   echo "       Automatic removal was unsafe or unsuccessful; another build may own them." >&2
   echo "       IDs: $newExternalContainersFile" >&2
   echo "       Details: $detailsFile" >&2
}

# -----------------------------------------------------------------------------
# Helper: remove this operation's external Buildah containers when safe
# -----------------------------------------------------------------------------
# Force-removal is restricted to IDs absent from the pre-operation baseline. The
# fallback runs only after the supervised service has stopped and only when no
# Podman, Buildah, Conmon, FUSE, or another container-build service is active.
# If shared activity is detected, cleanup remains non-destructive and reports the records.
remove_new_external_containers_if_safe() {
   local containerId
   local cleanupLog="${runArtifactsDir}/external-containers-cleanup.log"

   new_external_containers_remain || return 0

   # Never modify storage while the supervised operation is still active.
   if [[ -n "${activeOperationUnit:-}" ]] && \
      systemctl --user is-active --quiet "$activeOperationUnit" 2>/dev/null; then
      return 1
   fi

   # Protect concurrent Podman or Buildah work, including work not launched by
   # these scripts. A later manual check can resolve records when the node is idle.
   for processName in podman buildah conmon fuse-overlayfs; do
      if pgrep -u "$USER" -x "$processName" >/dev/null 2>&1; then
         return 1
      fi
   done
   if systemctl --user list-units --type=service --state=running \
      "${CONTAINER_BUILD_SERVICE_PREFIX}-*.service" --no-legend 2>/dev/null | grep -q .; then
      return 1
   fi

   {
      echo "Timestamp: $(date --iso-8601=seconds)"
      echo "Removing external Buildah containers introduced by this operation:"
      cat "$newExternalContainersFile"
   } > "$cleanupLog"

   # podman rm --storage --force removes each selected Buildah storage container
   # together with a lingering mount, without deleting images or baseline records.
   while IFS= read -r containerId; do
      [[ -n "$containerId" ]] || continue
      if ! podman rm --storage --force "$containerId" >> "$cleanupLog" 2>&1; then
         echo "ERROR: Failed to remove external Buildah container $containerId." >&2
         echo "       Cleanup log: $cleanupLog" >&2
         return 1
      fi
   done < "$newExternalContainersFile"

   if new_external_containers_remain; then
      return 1
   fi

   echo "Removed external Buildah containers introduced by this operation."
   echo "Targeted cleanup log: $cleanupLog"
   return 0
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
         # Prefer Podman's own cleanup. If its working container remains after the
         # service stops, apply the targeted fallback only when the node is idle.
         if ! new_external_containers_remain ||             remove_new_external_containers_if_safe; then
            echo "Podman storage cleanup verification passed."
            echo "No new external Buildah container records remain."
            echo "It is safe to start another build using this Podman storage."
            return 0
         fi
      fi
      sleep "$STORAGE_CHECK_INTERVAL"
   done

   # Report external records once, after retries are exhausted, instead of on every poll.
   if new_external_containers_remain; then
      report_new_external_containers
   fi
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
  $thisScript --recipe-dir <directory> --engine docker|podman [--build-arg NAME=VALUE]... [--target <stageName>] [--targetFrom <startingStage>]
  $thisScript --help

Options:
  --recipe-dir, -r <directory>  OpenFOAM build-context directory containing the docker recipe and
                                 the buildAndValidationConfig/openfoamBuildAndValidation.config file
  --engine, -b <engine>         Container engine: docker or podman (required)
  --no-cache                    Build every layer without using cached layers
  --build-arg NAME=VALUE        Override a Dockerfile ARG marked with USER_BUILD_ARG; may be repeated
  --target <stageName>          Build a specific named Dockerfile stage
  --targetFrom <startingStage>  Replace the selected target stage base; requires --target
  --help, -h                    Show this help message and exit
USAGE
}

# =============================================================================
# Parse and validate command-line arguments
# =============================================================================
ENGINE=""
stageName=""
stageFrom=""
while [[ $# -gt 0 ]]; do
   case $1 in
      --recipe-dir|-r)
         if [[ $# -lt 2 || -z "$2" ]]; then
            echo "ERROR: --recipe-dir requires <directory>" >&2
            exit 1
         fi
         recipeDirInput="$2"
         shift 2
         ;;
      --engine|-b)
         ENGINE="$2"
         if [[ -z "$ENGINE" ]]; then
            echo "ERROR: --engine requires docker|podman" >&2
            usage
            exit 1
         fi
         shift 2
         ;;
      --no-cache)
         noCache=true
         shift
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
      --target)
         stageName="$2"
         if [[ -z "$stageName" ]]; then
            echo "ERROR: --target requires <stageName>" >&2
            usage
            exit 1
         fi
         shift 2
         ;;
      --targetFrom)
         stageFrom="$2"
         if [[ -z "$stageFrom" ]]; then
            echo "ERROR: --targetFrom requires <startingStage>" >&2
            usage
            exit 1
         fi
         shift 2
         ;;
      -h|--help)
         usage
         exit 0
         ;;
      *)
         echo "ERROR: Unknown option '$1'" >&2
         usage
         exit 1
         ;;
   esac
done

# =============================================================================
# Validate and prepare the OpenFOAM version directory
# =============================================================================
# The selected directory is the build context. Temporary Dockerfiles are kept
# under tmp/, while build logs intended for later inspection go to artifacts/.
if [[ -z "$recipeDirInput" ]]; then
   echo "ERROR: --recipe-dir <directory> is required" >&2
   usage
   exit 1
fi
if [[ ! -d "$recipeDirInput" ]]; then
   echo "ERROR: Recipe directory does not exist: $recipeDirInput" >&2
   exit 1
fi
recipeDir=$(cd -- "$recipeDirInput" && pwd)
recipeFile=""
tmpDir="${recipeDir}/tmp"
artifactsRootDir="${recipeDir}/artifacts"
artifactsDir="${artifactsRootDir}/container"
configFile="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
if [[ ! -r "$configFile" ]]; then
   echo "ERROR: Build-validation configuration is not readable: $configFile" >&2
   exit 1
fi
mkdir -p "$tmpDir" "$artifactsDir"
latestLink="${artifactsDir}/latest"
if [[ -e "$latestLink" && ! -L "$latestLink" ]]; then
   echo "ERROR: Refusing to remove non-symbolic-link path: $latestLink" >&2
   exit 1
fi
if ! rm -f "$latestLink"; then
   echo "ERROR: Failed to remove latest link: $latestLink" >&2
   exit 1
fi
echo "This directory contains disposable temporary files only. It can be removed anytime." > "${tmpDir}/README.txt"
echo "This directory contains timestamped build artifacts. The latest link identifies the most recent tracked build invocation. If the link is absent, the most recent command failed before invocation tracking was established." > "${artifactsDir}/README.txt"

# =============================================================================
# Create the persistent artifact directory for this invocation
# =============================================================================
# Use one timestamped directory for all output from the invocation. The engine
# and selected build stages make the directory identifiable without inspecting
# its contents. The latest symbolic link points to the most recent invocation.
buildTimestamp=$(date '+%Y%m%dT%H%M%S%z')
if [[ -n "$stageName" && -n "$stageFrom" ]]; then
   buildKind="${stageName}_from-${stageFrom}"
elif [[ -n "$stageName" ]]; then
   buildKind="$stageName"
else
   buildKind="full"
fi
runArtifactsName="${buildTimestamp}_${ENGINE}_${buildKind}"
runArtifactsDir="${artifactsDir}/${runArtifactsName}"
mkdir -p "$runArtifactsDir"
ln -sfn "$runArtifactsName" "${artifactsDir}/latest"

runLog="${runArtifactsDir}/run.log"
buildLog="${runArtifactsDir}/build.log"
buildCommandFile="${runArtifactsDir}/build-command.txt"
imageDetailsFile="${runArtifactsDir}/image-details.txt"
buildScanLog="${runArtifactsDir}/build.scan.log"

# Preserve the complete script output while continuing to display it.
exec > >(tee "$runLog") 2>&1

echo "Invocation artifacts: $runArtifactsDir"
echo "Complete run log: $runLog"
echo

# =============================================================================
# Load the version-specific build-validation settings
# =============================================================================
# Clear inherited values first so the four internal log paths must come from the
# selected version configuration. A value of NO_CHECK explicitly disables its
# corresponding validation step.
unset OPENFOAM_FORK OPENFOAM_VERSION THIRDPARTY_BUILD_LOG PARAVIEW_BUILD_LOG OPENFOAM_BUILD_LOG OPENFOAM_TOOL_LOG
# shellcheck source=/dev/null
source "$configFile"

for requiredSetting in \
   OPENFOAM_FORK \
   OPENFOAM_VERSION \
   THIRDPARTY_BUILD_LOG \
   PARAVIEW_BUILD_LOG \
   OPENFOAM_BUILD_LOG \
   OPENFOAM_TOOL_LOG
do
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
echo "OpenFOAM docker recipe: $recipeFile"

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

# =============================================================================
# Validate the selected container engine
# =============================================================================
if [[ -z "$ENGINE" ]]; then
   echo "ERROR: --engine docker|podman is required" >&2
   echo "Usage: $0 --recipe-dir <directory> --engine docker|podman [--build-arg NAME=VALUE]... [--target <stageName>] [--targetFrom <startingStage>]" >&2
   exit 1
fi
if [[ "$ENGINE" != "docker" && "$ENGINE" != "podman" ]]; then
   echo "ERROR: --engine must be 'docker' or 'podman', got '$ENGINE'" >&2
   exit 1
fi

# =============================================================================
# Validate the relationship between partial-build options
# =============================================================================
# --targetFrom only has meaning when a target stage has also been selected.
if [[ -n "$stageFrom" && -z "$stageName" ]]; then
   echo "ERROR: --targetFrom requires --target" >&2
   exit 1
fi

echo "Parsed: recipeDir='$recipeDir' ENGINE='$ENGINE' stageName='$stageName' stageFrom='$stageFrom' noCache='$noCache'"
echo "Build-validation configuration: $configFile"
if [[ "$noCache" == true ]]; then
   echo "Build cache: disabled; all Dockerfile instructions will be executed"
else
   echo "Build cache: enabled; the engine may reuse cached layers"
fi
if [[ ${#buildArgs[@]} -gt 0 ]]; then
   echo "Build-argument overrides:"
   for ((i=0; i<${#buildArgs[@]}; i+=2)); do
      echo "  ${buildArgs[$((i + 1))]}"
   done
else
   echo "Build-argument overrides: none; Dockerfile defaults will be used"
fi
echo

# =============================================================================
# Step 1: Set up the selected container engine environment
# =============================================================================
# Docker Desktop is started when Docker is not responsive. On Pawsey container
# build nodes, the site Podman setup script initializes the required settings.
# This step stops the script immediately on failure.
((++testNum))
echo "$thisScript: -----------------------------------------"
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

# Transient systemd services start with the user manager environment rather than
# the complete environment of this shell. Preserve the variables required by the
# selected container engine so it uses the same configuration and storage paths.
build_service_environment
echo

# =============================================================================
# Step 2: Confirm that the container engine is accessible
# =============================================================================
# A nonempty version response confirms that the command can be executed. Podman
# also requires XDG_DATA_HOME from the Pawsey setup script.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking if $ENGINE is accessible."
ENGINEVersion=$($ENGINE --version)
if [[ -z "$ENGINEVersion" ]]; then
   echo "✖ Step $testNum FAIL: Failed to execute: $ENGINE --version"
   ((totalFailed++))
   exit 1
fi
echo "✓ Step $testNum ${ENGINE}Version=$ENGINEVersion"
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
echo

# =============================================================================
# Step 3: Read the values used to construct the image name
# =============================================================================
# Start with Dockerfile ARG defaults, then apply matching command-line build-arg
# overrides. The final values form the repository and tag used by this script.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Setting the variables for defining names"
OF_FORK=$(grep '^ARG OF_FORK=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
OF_VERSION=$(grep '^ARG OF_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
GCC_VERSION=$(grep '^ARG GCC_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
WM_LABEL_SIZE=$(grep '^ARG WM_LABEL_SIZE=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
WM_PRECISION_OPTION=$(grep '^ARG WM_PRECISION_OPTION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
WM_COMPILE_OPTION=$(grep '^ARG WM_COMPILE_OPTION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
OS_VERSION=$(grep '^ARG BASE_IMAGE_OS_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)
MPICH_VERSION=$(grep '^ARG BASE_IMAGE_MPICH_VERSION=' "$recipeFile" 2>/dev/null | cut -d'"' -f2)

# Apply command-line overrides that affect the generated image reference.
# The last repeated --build-arg value wins.
OF_FORK="${buildArgValues[OF_FORK]:-$OF_FORK}"
OF_VERSION="${buildArgValues[OF_VERSION]:-$OF_VERSION}"
WM_LABEL_SIZE="${buildArgValues[WM_LABEL_SIZE]:-$WM_LABEL_SIZE}"
WM_PRECISION_OPTION="${buildArgValues[WM_PRECISION_OPTION]:-$WM_PRECISION_OPTION}"
WM_COMPILE_OPTION="${buildArgValues[WM_COMPILE_OPTION]:-$WM_COMPILE_OPTION}"
OS_VERSION="${buildArgValues[BASE_IMAGE_OS_VERSION]:-$OS_VERSION}"
MPICH_VERSION="${buildArgValues[BASE_IMAGE_MPICH_VERSION]:-$MPICH_VERSION}"

echo "OF_FORK: '$OF_FORK'"
echo "OF_VERSION: '$OF_VERSION'"
echo "GCC_VERSION: '$GCC_VERSION'"
echo "WM_LABEL_SIZE: '$WM_LABEL_SIZE'"
echo "WM_PRECISION_OPTION: '$WM_PRECISION_OPTION'"
echo "WM_COMPILE_OPTION: '$WM_COMPILE_OPTION'"
echo "OS_VERSION: '$OS_VERSION'"
echo "MPICH_VERSION: '$MPICH_VERSION'"

if [[ -z "$OF_FORK" || -z "$OF_VERSION" || -z "$GCC_VERSION" || \
      -z "$WM_LABEL_SIZE" || -z "$WM_PRECISION_OPTION" || -z "$WM_COMPILE_OPTION" || \
      -z "$OS_VERSION" || -z "$MPICH_VERSION" ]]; then
   echo "✖ Step $testNum FAIL: Failed to extract required variables from docker recipe"
   ((totalFailed++))
   exit 1
fi
if [[ "$OF_FORK" != "$OPENFOAM_FORK" ]]; then
   echo "✖ Step $testNum FAIL: OpenFOAM fork mismatch between recipe settings and configuration"
   echo "  Recipe/build setting: $OF_FORK"
   echo "  Configuration:        $OPENFOAM_FORK"
   ((totalFailed++)); exit 1
fi
if [[ "$OF_VERSION" != "$OPENFOAM_VERSION" ]]; then
   echo "✖ Step $testNum FAIL: OpenFOAM version mismatch between recipe settings and configuration"
   echo "  Recipe/build setting: $OF_VERSION"
   echo "  Configuration:        $OPENFOAM_VERSION"
   ((totalFailed++)); exit 1
fi
echo "✓ Step $testNum PASS: Recipe identity matches OPENFOAM_FORK='$OPENFOAM_FORK' and OPENFOAM_VERSION='$OPENFOAM_VERSION'"
echo

# =============================================================================
# Step 4: Validate the optional target stage
# =============================================================================
# When --target is supplied, the Dockerfile must define the requested named stage.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Validating if stage name exists in the Dockerfile"
if [[ -n "$stageName" ]]; then
   if ! grep -qiE "^FROM .* AS[[:space:]]+$stageName[[:space:]]*" "$recipeFile"; then
      echo "✖ Step $testNum FAIL: Stage '$stageName' not found in $recipeFile"
      echo "  Looking for line: FROM ... as $stageName"
      ((totalFailed++))
      exit 1
   fi
   echo "✓ Step $testNum PASS: Stage '$stageName' found"
else
   echo "Step $testNum skipped. Not needed"
fi
echo

# =============================================================================
# Step 5: Validate the optional replacement base stage
# =============================================================================
# The --targetFrom stage must also be a named stage in the original Dockerfile.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Validating if stageFrom name exists in the Dockerfile"
if [[ -n "$stageFrom" ]]; then
   if ! grep -qiE "^FROM .* AS[[:space:]]+$stageFrom[[:space:]]*" "$recipeFile"; then
      echo "✖ Step $testNum FAIL: Stage '$stageFrom' not found in $recipeFile"
      echo "  Looking for line: FROM ... as $stageFrom"
      echo "  Can't be used as a stageFrom value"
      ((totalFailed++))
      exit 1
   fi
   echo "✓ Step $testNum PASS: Stage '$stageFrom' found"
else
   echo "Step $testNum skipped. Not needed"
fi
echo

# =============================================================================
# Step 6: Create a temporary Dockerfile when --targetFrom is used
# =============================================================================
# The selected target stage is rewritten as "FROM <stageFrom> AS <stageName>" in
# a temporary copy. The original version-specific Dockerfile remains unchanged.
((++testNum))
tempRecipeFile=""
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Creating temp Dockerfile: FROM $stageFrom AS $stageName"
if [[ -n "$stageFrom" && -n "$stageName" ]]; then
   recipeName=$(basename $recipeFile)
   tempRecipeFile="${tmpDir}/${recipeName}.$$.tmp"
   cp "$recipeFile" "$tempRecipeFile"

   # Pass 1: Comment line starting with FROM, ending with AS $stageName
   sed "/^FROM .* AS[[:space:]]*$stageName$/s/^/#-ha-#/" "$tempRecipeFile" > "${tempRecipeFile}.new.tmp"

   # Pass 2: Insert new line after commented one
   sed "/^#-ha-#FROM .* AS[[:space:]]*$stageName$/a\\
FROM $stageFrom AS $stageName" "${tempRecipeFile}.new.tmp" > "$tempRecipeFile" && rm "${tempRecipeFile}.new.tmp"

   # Verify EXACT line exists
   if ! grep -q "^FROM[[:space:]]\+$stageFrom[[:space:]]\+AS[[:space:]]\+$stageName" "$tempRecipeFile"; then
      echo "✖ Step $testNum FAIL: No 'FROM $stageFrom AS $stageName' in $tempRecipeFile"
      ((totalFailed++))
      exit 1
   fi

   recipeFile="$tempRecipeFile"
   echo "✓ Step $testNum PASS: temporal $recipeFile created (1 line replaced)"
   echo "                      It will be used for the build with:"
   grep -iE "^FROM .* AS[[:space:]]+$stageName[[:space:]]*" $recipeFile
else
   echo "Step $testNum skipped no temporary Dockefile needed (no --targetFrom)"
fi
echo

# =============================================================================
# Step 7: Build the image and record the complete output
# =============================================================================
# Build options are held in arrays so every argument is passed safely. The build
# runs from the selected context and its combined output is saved in artifacts/.
((++testNum))
imageName="${OF_FORK}"
imageTag="${OF_VERSION}-gcc${GCC_VERSION}${WM_PRECISION_OPTION}Int${WM_LABEL_SIZE}${WM_COMPILE_OPTION}-mpich${MPICH_VERSION}-ubuntu${OS_VERSION}"
buildOptions=()
if [[ "$noCache" == true ]]; then
   # Docker and Podman both accept --no-cache for build-layer cache bypass.
   buildOptions+=(--no-cache)
fi
if [[ -n "$stageName" ]]; then
   imageTag="${imageTag}-${stageName}"
   buildOptions+=(--target "$stageName")
fi
if [[ -n "$stageFrom" ]]; then
   imageTag="${imageTag}-from-${stageFrom}"
fi
imageFull="${imageName}:${imageTag}"
expectedImagePrefix="${OPENFOAM_FORK}:${OPENFOAM_VERSION}"
if [[ "$imageFull" != "${expectedImagePrefix}"* ]]; then
   echo "✖ Step $testNum FAIL: Generated image name does not match the configured OpenFOAM identity"
   echo "  Generated image: $imageFull"
   echo "  Required prefix: $expectedImagePrefix"
   ((totalFailed++)); exit 1
fi
echo "✓ Step $testNum: Generated image name starts with '$expectedImagePrefix'"
logFileBuild="$buildLog"
if [[ "$ENGINE" == "docker" ]]; then
   buildOptions+=(--progress=plain)
else
   buildOptions+=(--format=docker)
fi
buildOptions+=(--ulimit nofile=16384:16384)
if [[ ${#buildArgs[@]} -gt 0 ]]; then
   buildOptions+=("${buildArgs[@]}")
fi

# Verify that an isolated Podman service resolves the same storage location as
# this shell. Refuse to build if the environment hand-off changes GraphRoot.
if [[ "$ENGINE" == "podman" ]]; then
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
      echo "       The image build has not been started." >&2
      exit 1
   fi
   if [[ "$serviceGraphRoot" != "$shellGraphRoot" ]]; then
      echo "ERROR: Podman storage differs inside the isolated systemd user service." >&2
      echo "       Shell GraphRoot:   $shellGraphRoot" >&2
      echo "       Service GraphRoot: $serviceGraphRoot" >&2
      echo "       The image build has not been started." >&2
      exit 1
   fi
   podmanGraphRoot="$shellGraphRoot"
   podmanEnvironmentReady=true
   echo "Podman storage identity check passed: GraphRoot=$podmanGraphRoot"
   wait_for_podman_storage \
      "Performing the pre-operation Podman storage-health check." 60 || exit 1
fi

# Pass the recipe relative to the build context.
recipeRelative=${recipeFile#"$recipeDir"/}
buildCommand=(
   "$ENGINE" build
   "${buildOptions[@]}"
   -t "$imageFull"
   -f "$recipeRelative"
   .
)

echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Building with $ENGINE the image $imageFull"
printf 'Recorded build command:'
printf ' %q' "${buildCommand[@]}"
printf '\n'
{
   printf 'cd %q &&' "$recipeDir"
   printf ' %q' "${buildCommand[@]}"
   printf '\n'
} > "$buildCommandFile"

# Run the build in an isolated service and monitor its log for bounded inactivity.
require_operation_scope_support || exit 1
new_operation_unit build
stallMarker="${runArtifactsDir}/build-stalled.marker"
stallDiagnostics="${runArtifactsDir}/build-stall-diagnostics.txt"
operationStatusFile="${runArtifactsDir}/build-operation.status"
rm -f "$stallMarker" "$stallDiagnostics" "$operationStatusFile"
echo "Build process service: $activeOperationUnit"
echo "Build inactivity limit: ${STALL_SILENCE_SECONDS} seconds plus a bounded ${STALL_CONFIRMATION_SECONDS}-second confirmation period"
record_external_containers_before_operation || exit 1
echo "=== BUILD START: $(date)" | tee "$logFileBuild"
(
   cd "$recipeDir"
   time systemd-run --user --wait --pipe --quiet --collect --service-type=exec \
      --unit="$activeOperationUnit" --working-directory="$recipeDir" \
      "${serviceEnvironment[@]}" -- "${buildCommand[@]}"
   printf '%s\n' "$?" > "$operationStatusFile"
) |& tee -a "$logFileBuild" &
operationWasStarted=true
storageVerifiedAfterOperation=false
operationRunnerPid=$!
monitor_operation_progress "$activeOperationUnit" "$operationRunnerPid" \
   "$logFileBuild" "$stallMarker" "$stallDiagnostics" &
watchdogPid=$!
wait "$operationRunnerPid"
operationRunnerPid=""
stop_watchdog
buildExit=$(cat "$operationStatusFile" 2>/dev/null || printf '1')
statusAll=("$buildExit" "0")
activeOperationUnit=""
echo "=== BUILD END: $(date)" | tee -a "$logFileBuild"
if [[ $buildExit -ne 0 || -f "$stallMarker" ]]; then
   if wait_for_podman_storage \
      "Verifying Podman storage after the stopped or failed build."; then
      :
   fi
   storageVerifiedAfterOperation=true
fi
if [[ -f "$stallMarker" ]]; then
   echo "ERROR: The build was terminated by the inactivity supervisor."
   echo "Diagnostics: $stallDiagnostics"
   exit 1
fi

if [[ $buildExit -ne 0 ]]; then
   echo "✖ Step $testNum FAIL: $ENGINE build failed (check $logFileBuild)"
   echo "buildExit=$buildExit"
   echo "statusAll=${statusAll[*]}"
   exit 1
fi
echo "✓ Step $testNum PASS: Build completed"
echo

# =============================================================================
# Step 8: Verify that the image exists in the local registry
# =============================================================================
# Podman normally records unqualified image names below localhost/, while Docker
# uses the generated image reference directly. This check stops on failure.
((++testNum))
echo "$thisScript: -----------------------------------------"
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
   {
      echo "Engine: $ENGINE"
      echo "Image: $imageFull"
      echo "Local reference: $imageReference"
      echo "Size: $imageSize"
      echo "Build timestamp: $buildTimestamp"
      echo "Build kind: $buildKind"
      echo "Recipe directory: $recipeDir"
      echo "Build command file: $buildCommandFile"
      echo "Build log: $buildLog"
      echo "Build scan log: $buildScanLog"
      echo "Complete run log: $runLog"
   } > "$imageDetailsFile"
else
   if [[ $ENGINE == "podman" ]]; then
      echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in $ENGINE \"localhost/\" local registry"
   else
      echo "✖ Step $testNum FAIL: Image '${imageFull}' not found in $ENGINE local registry"
   fi
   ((totalFailed++))
   exit 1
fi
echo

# =============================================================================
# Step 9: Look for the engine-specific build success line
# =============================================================================
# This supplementary log check reports a problem but allows later checks to run.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Checking build success line"

if [[ "$ENGINE" == "docker" ]]; then
   successPattern="naming to.*${imageFull}.*done"
else
   successPattern="Successfully tagged.*${imageFull}"
fi
if tail -10 "$logFileBuild" | grep -qE "$successPattern"; then
   echo "✓ Step $testNum PASS: Success line found in $logFileBuild"
   tail -10 "$logFileBuild" | grep -E "$successPattern"
else
   failedTests+=("$testNum: Build success line not found in $logFileBuild")
   ((++totalFailed))
   echo "Last 10 lines:"
   tail -10 "$logFileBuild"
fi
echo

# =============================================================================
# Step 10: Scan unmarked build output for additional error messages
# =============================================================================
# The recipe can mark deliberately non-authoritative compilation-pass output with
# OPENFOAM_BUILD_SCAN_IGNORE_BEGIN and OPENFOAM_BUILD_SCAN_IGNORE_END. This step
# removes only those marked ranges from its supplementary diagnostic scan and
# stores the exact inspected text in build.scan.log. The original build.log is
# never modified.
#
# Marker parsing is strict. Nested, unmatched, or unclosed markers fail this step
# instead of allowing an invalid range to hide later authoritative build output.
((++testNum))
echo "$thisScript: -----------------------------------------"
echo "Step $testNum - Scanning unmarked build output for additional error messages"
echo "Complete build log: $logFileBuild"
echo "Filtered scan log: $buildScanLog"

if [[ -f "$logFileBuild" ]]; then
   markerCountFile="${buildScanLog}.marker-count"
   markerStatus=0
   awk '
      /^OPENFOAM_BUILD_SCAN_IGNORE_BEGIN([[:space:]]|$)/ {
         if (ignoring) {
            printf "Nested ignore-begin marker at line %d\n", NR > "/dev/stderr"
            invalid = 1
         }
         ignoring = 1
         beginCount++
         next
      }
      /^OPENFOAM_BUILD_SCAN_IGNORE_END([[:space:]]|$)/ {
         if (!ignoring) {
            printf "Ignore-end marker without a matching begin at line %d\n", NR > "/dev/stderr"
            invalid = 1
         }
         ignoring = 0
         endCount++
         next
      }
      !ignoring { print }
      END {
         if (ignoring) {
            print "Build log ended inside an ignored range" > "/dev/stderr"
            invalid = 1
         }
         if (beginCount != endCount) {
            printf "Ignore-marker count mismatch: begin=%d end=%d\n", beginCount, endCount > "/dev/stderr"
            invalid = 1
         }
         if (invalid) exit 1
         printf "%d\n", beginCount > countFile
      }
   ' countFile="$markerCountFile" "$logFileBuild" > "$buildScanLog" || markerStatus=$?

   if [[ $markerStatus -ne 0 ]]; then
      rm -f "$markerCountFile"
      echo "✖ Step $testNum FAIL: Invalid build-log ignore-marker structure"
      failedTests+=("$testNum: Invalid build-log ignore-marker structure")
      ((++totalFailed))
   else
      ignoredRangeCount=$(cat "$markerCountFile")
      rm -f "$markerCountFile"
      echo "Ignored non-authoritative compilation ranges: $ignoredRangeCount"

      errorOutput=$(
         grep -iE '\bError\b' "$buildScanLog" |
            grep -vE '^\[[0-9]+/[0-9]+\][[:space:]]+STEP[[:space:]]+[0-9]+/[0-9]+:' |
            grep -viE 'Error[./-]|ignor' ||
            true
      )

      if [[ -z "$errorOutput" ]]; then
         echo "✓ Step $testNum PASS: No additional error messages found outside marked ranges"
      else
         errorCount=$(printf '%s\n' "$errorOutput" | wc -l)
         echo "✖ Step $testNum FAIL: $errorCount additional error message(s) found outside marked ranges"
         echo "First 5 errors:"
         printf '%s\n' "$errorOutput" | head -n 5
         failedTests+=("$testNum: $buildScanLog has $errorCount additional error message(s)")
         ((++totalFailed))
      fi
   fi
else
   echo "✖ Step $testNum FAIL: Build log does not exist: $logFileBuild"
   failedTests+=("$testNum: Build log does not exist: $logFileBuild")
   ((++totalFailed))
fi
echo

# =============================================================================
# Step 11: Check the configured ThirdParty compilation summary
# =============================================================================
# The internal path comes from THIRDPARTY_BUILD_LOG. Set it to NO_CHECK in the
# version configuration when this image is not expected to contain that log.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$THIRDPARTY_BUILD_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: THIRDPARTY_BUILD_LOG=NO_CHECK"
else
   logFile="$THIRDPARTY_BUILD_LOG"
   echo "Step $testNum - Checking that ThirdParty compilation finalised without 'Error'"
   echo "Checking the file $logFile"
   if "$ENGINE" run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
      errorOutput=$("$ENGINE" run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viE 'Error[./-]|ignor' || true)
      if [[ -z "$errorOutput" ]]; then
         echo "✓ Step $testNum PASS: Clean $logFile"
      else
         errorCount=$(printf '%s\n' "$errorOutput" | wc -l)
         echo "✖ Step $testNum FAIL: $errorCount 'Error'(s) found in $logFile"
         echo "First 5 errors:"
         printf '%s\n' "$errorOutput" | head -n 5
         failedTests+=("$testNum: ThirdParty log has $errorCount errors")
         ((++totalFailed))
      fi
   else
      echo "⚠ Step $testNum FAIL: $logFile cannot be read from image $imageFull"
      echo "This may happen when a partial stage does not contain the log or"
      echo "does not initialize the environment variable used in its path."
      failedTests+=("$testNum: ThirdParty log file not accessible")
      ((++totalFailed))
   fi
fi
echo

# =============================================================================
# Step 12: Check the configured ParaView compilation summary
# =============================================================================
# The internal path comes from PARAVIEW_BUILD_LOG. Set it to NO_CHECK to skip.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$PARAVIEW_BUILD_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: PARAVIEW_BUILD_LOG=NO_CHECK"
else
   logFile="$PARAVIEW_BUILD_LOG"
   echo "Step $testNum - Checking that ParaView compilation finalised without 'Error'"
   echo "Checking the file $logFile"
   if "$ENGINE" run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
      errorOutput=$("$ENGINE" run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viE 'Error[./-]|ignor' || true)
      if [[ -z "$errorOutput" ]]; then
         echo "✓ Step $testNum PASS: Clean $logFile"
      else
         errorCount=$(printf '%s\n' "$errorOutput" | wc -l)
         echo "✖ Step $testNum FAIL: $errorCount 'Error'(s) found in $logFile"
         echo "First 5 errors:"
         printf '%s\n' "$errorOutput" | head -n 5
         failedTests+=("$testNum: ParaView log has $errorCount errors")
         ((++totalFailed))
      fi
   else
      echo "⚠ Step $testNum FAIL: $logFile cannot be read from image $imageFull"
      echo "This may happen when a partial stage does not contain the log or"
      echo "does not initialize the environment variable used in its path."
      failedTests+=("$testNum: ParaView log file not accessible")
      ((++totalFailed))
   fi
fi
echo

# =============================================================================
# Step 13: Check the configured OpenFOAM compilation summary
# =============================================================================
# The internal path comes from OPENFOAM_BUILD_LOG. Set it to NO_CHECK to skip.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$OPENFOAM_BUILD_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: OPENFOAM_BUILD_LOG=NO_CHECK"
else
   logFile="$OPENFOAM_BUILD_LOG"
   echo "Step $testNum - Checking that OpenFOAM compilation finalised without 'Error'"
   echo "Checking the file $logFile"
   if "$ENGINE" run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
      errorOutput=$("$ENGINE" run --rm "$imageFull" bash -c "grep -iE '\\bError\\b' \"$logFile\"" | grep -viE 'Error[./-]|ignor' || true)
      if [[ -z "$errorOutput" ]]; then
         echo "✓ Step $testNum PASS: Clean $logFile"
      else
         errorCount=$(printf '%s\n' "$errorOutput" | wc -l)
         echo "✖ Step $testNum FAIL: $errorCount 'Error'(s) found in $logFile"
         echo "First 5 errors:"
         printf '%s\n' "$errorOutput" | head -n 5
         failedTests+=("$testNum: OpenFOAM log has $errorCount errors")
         ((++totalFailed))
      fi
   else
      echo "⚠ Step $testNum FAIL: $logFile cannot be read from image $imageFull"
      echo "This may happen when a partial stage does not contain the log or"
      echo "does not initialize the environment variable used in its path."
      failedTests+=("$testNum: OpenFOAM log file not accessible")
      ((++totalFailed))
   fi
fi
echo

# =============================================================================
# Step 14: Check the configured OpenFOAM basic-functionality log
# =============================================================================
# The internal path comes from OPENFOAM_TOOL_LOG. Set it to NO_CHECK to skip.
((++testNum))
echo "$thisScript: -----------------------------------------"
if [[ "$OPENFOAM_TOOL_LOG" == "NO_CHECK" ]]; then
   echo "Step $testNum skipped: OPENFOAM_TOOL_LOG=NO_CHECK"
else
   logFile="$OPENFOAM_TOOL_LOG"
   echo "Step $testNum - Checking that OpenFOAM tool basic output is correct"
   echo "Checking the file $logFile"
   if "$ENGINE" run --rm "$imageFull" bash -c "[[ -f $logFile ]]" 2>/dev/null; then
      if "$ENGINE" run --rm "$imageFull" bash -c "
         grep -qE '^Usage:' \"$logFile\" &&
         grep -qE '^Options:' \"$logFile\" &&
         grep -qF 'Using: OpenFOAM-${OF_VERSION}' \"$logFile\"
      "; then
         echo "✓ Step $testNum PASS: All required output lines found in $logFile"
         "$ENGINE" run --rm "$imageFull" bash -c "
            grep -E '^Usage:' \"$logFile\";
            grep -E '^Options:' \"$logFile\";
            grep -F 'Using: OpenFOAM-${OF_VERSION}' \"$logFile\"
         "
      else
         echo "✖ Step $testNum FAIL: Missing required output lines in $logFile"
         echo "Missing patterns:"
         "$ENGINE" run --rm "$imageFull" bash -c "
            grep -qE '^Usage:' \"$logFile\" || echo '  - ^Usage:';
            grep -qE '^Options:' \"$logFile\" || echo '  - ^Options:';
            grep -qF 'Using: OpenFOAM-${OF_VERSION}' \"$logFile\" || echo '  - Using: OpenFOAM-${OF_VERSION}'
         "
         failedTests+=("$testNum: OpenFOAM tool basic output incomplete")
         ((++totalFailed))
      fi
   else
      echo "⚠ Step $testNum FAIL: $logFile cannot be read from image $imageFull"
      echo "This may happen when a partial stage does not contain the log or"
      echo "does not initialize the environment variable used in its path."
      failedTests+=("$testNum: OpenFOAM tool basic test log file not accessible")
      ((++totalFailed))
   fi
fi
echo

# =============================================================================
# Final summary
# =============================================================================
# Return success only when every required build and validation step passed.
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Total steps run: $testNum"
echo "Invocation artifacts: $runArtifactsDir"
echo "Build log: $buildLog"
echo "Build scan log: $buildScanLog"
echo "Complete run log: $runLog"
if [[ $totalFailed -eq 0 ]]; then
   echo "✓ ALL STEPS PASSED! Image '$imageFull' was built successfully."
   exit 0
else
   echo "✖ $totalFailed STEPS(S) FAILED:"
   for test in "${failedTests[@]}"; do
      echo "  - $test"
   done
   exit 1
fi
