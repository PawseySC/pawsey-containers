#!/usr/bin/env bash

# =============================================================================
# Forceful cleanup of lingering Podman build processes and services
# =============================================================================
# This recovery tool cleans host-side runtime state when the current user's
# container-build environment is known to be idle but remains polluted by
# lingering services, processes, or FUSE helpers after an interrupted build.
#
# The cleaner deliberately does not modify Podman's stored objects. It does not
# remove external Buildah container records, images, ordinary containers,
# volumes, networks, build cache, or storage directories. External Buildah
# records are displayed after process cleanup for separate manual review.
#
# WARNING:
#   --clean assumes that no legitimate container build or related compilation
#   owned by the current user should still be running on this node. The command
#   may terminate every matching user-owned process, including build tools that
#   are not contained in a container-build service.
#
# Exit status:
#   0  Runtime cleanup completed and no targeted process or service remains.
#   1  Runtime state remains dirty or cleanup was requested without --clean.
#   2  A prerequisite, configuration, or required verification failed.

set -o pipefail

# =============================================================================
# Runtime configuration
# =============================================================================
# Defaults match the OpenFOAM builders and the general Podman node checker.
# Environment overrides support controlled testing without changing the script.
PODMAN_SETUP_SCRIPT=${PODMAN_SETUP_SCRIPT:-/container/setup_podman.sh}
CHECK_TIMEOUT_SECONDS=${CHECK_TIMEOUT_SECONDS:-30}
SERVICE_TERM_GRACE_SECONDS=${SERVICE_TERM_GRACE_SECONDS:-60}
PROCESS_TERM_GRACE_SECONDS=${PROCESS_TERM_GRACE_SECONDS:-30}
STOP_POLL_INTERVAL_SECONDS=${STOP_POLL_INTERVAL_SECONDS:-1}
STOP_STATUS_INTERVAL_SECONDS=${STOP_STATUS_INTERVAL_SECONDS:-10}
CONTAINER_BUILD_SERVICE_PATTERN=${CONTAINER_BUILD_SERVICE_PATTERN:-container-build-*.service}

cleanRequested=false

# Container runtime processes are terminated after supervised services have had
# an opportunity to stop themselves and clean up their process trees.
runtimeProcessNames=(
   podman
   buildah
   conmon
   fuse-overlayfs
)

# Compilation processes are included because failed container builds previously
# left detached compiler trees consuming node resources. The script targets only
# exact executable names owned by the current user.
buildProcessNames=(
   make
   cmake
   gcc
   g++
   cc1
   cc1plus
   ld
)

# =============================================================================
# Helper functions
# =============================================================================

# -----------------------------------------------------------------------------
# Helper: print command-line usage
# -----------------------------------------------------------------------------
usage() {
   cat <<USAGE
Usage:
  $(basename "$0")
  $(basename "$0") --clean
  $(basename "$0") --help

Modes:
  No option   Inspect the runtime state and explain what --clean would target.
  --clean     Forcefully stop container-build services and matching user-owned
              runtime and compilation processes, then verify the node state.

The script does not modify Podman images, containers, volumes, build cache,
external Buildah storage records, or storage directories.

Environment overrides:
  PODMAN_SETUP_SCRIPT            Default: /container/setup_podman.sh
  CHECK_TIMEOUT_SECONDS          Default: 30
  SERVICE_TERM_GRACE_SECONDS     Default: 60
  PROCESS_TERM_GRACE_SECONDS     Default: 30
  STOP_POLL_INTERVAL_SECONDS     Default: 1
  STOP_STATUS_INTERVAL_SECONDS   Default: 10
  CONTAINER_BUILD_SERVICE_PATTERN
                                 Default: container-build-*.service
USAGE
}

# -----------------------------------------------------------------------------
# Helper: print one consistently formatted section heading
# -----------------------------------------------------------------------------
print_heading() {
   local title=$1
   echo
   echo "===== $title ====="
}

# -----------------------------------------------------------------------------
# Helper: validate configuration and required commands
# -----------------------------------------------------------------------------
validate_prerequisites() {
   local settingName
   local settingValue
   local commandName
   local -a requiredCommands=(
      findmnt
      pgrep
      podman
      ps
      systemctl
      timeout
   )

   for settingName in \
      CHECK_TIMEOUT_SECONDS \
      SERVICE_TERM_GRACE_SECONDS \
      PROCESS_TERM_GRACE_SECONDS \
      STOP_POLL_INTERVAL_SECONDS \
      STOP_STATUS_INTERVAL_SECONDS; do
      settingValue=${!settingName}
      if [[ ! "$settingValue" =~ ^[1-9][0-9]*$ ]]; then
         echo "ERROR: $settingName must be a positive integer; got '$settingValue'." >&2
         return 1
      fi
   done

   if [[ ! -r "$PODMAN_SETUP_SCRIPT" ]]; then
      echo "ERROR: Podman setup script is not readable: $PODMAN_SETUP_SCRIPT" >&2
      return 1
   fi

   for commandName in "${requiredCommands[@]}"; do
      if ! command -v "$commandName" >/dev/null 2>&1; then
         echo "ERROR: Required command is unavailable: $commandName" >&2
         return 1
      fi
   done
}

# -----------------------------------------------------------------------------
# Helper: collect container-build transient service names
# -----------------------------------------------------------------------------
# Unit names are returned one per line. Loaded inactive failed units are included
# so the cleaner can reset their state after all running processes have stopped.
collect_container_build_services() {
   systemctl --user list-units --all "$CONTAINER_BUILD_SERVICE_PATTERN" \
      --no-legend --no-pager 2>/dev/null |
      awk 'NF > 0 { print $1 }'
}

# -----------------------------------------------------------------------------
# Helper: report current targeted processes
# -----------------------------------------------------------------------------
report_targeted_processes() {
   local processName
   local processOutput
   local found=false

   for processName in "${runtimeProcessNames[@]}" "${buildProcessNames[@]}"; do
      processOutput=$(pgrep -u "$USER" -a -x "$processName" 2>/dev/null || true)
      if [[ -n "$processOutput" ]]; then
         echo "=== $processName ==="
         printf '%s\n' "$processOutput"
         found=true
      fi
   done

   [[ "$found" == true ]]
}

# -----------------------------------------------------------------------------
# Helper: collect unique PIDs for exact user-owned executable names
# -----------------------------------------------------------------------------
collect_process_pids() {
   local processName
   local processId

   for processName in "$@"; do
      while IFS= read -r processId; do
         [[ -n "$processId" ]] && printf '%s\n' "$processId"
      done < <(pgrep -u "$USER" -x "$processName" 2>/dev/null || true)
   done | sort -nu
}

# -----------------------------------------------------------------------------
# Helper: test whether any PID from a supplied file still belongs to this user
# -----------------------------------------------------------------------------
any_recorded_process_remains() {
   local pidFile=$1
   local processId
   local processUser

   [[ -s "$pidFile" ]] || return 1

   while IFS= read -r processId; do
      [[ -n "$processId" ]] || continue
      processUser=$(ps -o user= -p "$processId" 2>/dev/null | awk '{$1=$1; print}')
      if [[ "$processUser" == "$USER" ]]; then
         return 0
      fi
   done < "$pidFile"

   return 1
}

# -----------------------------------------------------------------------------
# Helper: wait for a transient service to stop
# -----------------------------------------------------------------------------
wait_for_service_stop() {
   local unit=$1
   local limit=$2
   local elapsed=0
   local nextStatus=$STOP_STATUS_INTERVAL_SECONDS

   while (( elapsed < limit )); do
      if ! systemctl --user is-active --quiet "$unit" 2>/dev/null; then
         return 0
      fi
      sleep "$STOP_POLL_INTERVAL_SECONDS"
      elapsed=$((elapsed + STOP_POLL_INTERVAL_SECONDS))
      if (( elapsed >= nextStatus )); then
         echo "Waiting for service shutdown: $unit (${elapsed}/${limit} seconds)"
         nextStatus=$((nextStatus + STOP_STATUS_INTERVAL_SECONDS))
      fi
   done

   ! systemctl --user is-active --quiet "$unit" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Helper: stop one container-build service with bounded escalation
# -----------------------------------------------------------------------------
# MainPID receives SIGTERM first so Podman can perform its own child and mount
# cleanup. The complete cgroup receives SIGTERM only if the service remains
# active, followed by SIGKILL as the final recovery action.
stop_container_build_service() {
   local unit=$1

   echo "Stopping service: $unit"

   if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
      echo "  Sending SIGTERM to the service main process."
      systemctl --user kill --kill-whom=main --signal=TERM "$unit" 2>/dev/null || true

      if ! wait_for_service_stop "$unit" "$SERVICE_TERM_GRACE_SECONDS"; then
         echo "  Main-process grace period expired; sending SIGTERM to the cgroup."
         systemctl --user kill --kill-whom=all --signal=TERM "$unit" 2>/dev/null || true

         if ! wait_for_service_stop "$unit" "$PROCESS_TERM_GRACE_SECONDS"; then
            echo "  Service still active; sending SIGKILL to the cgroup."
            systemctl --user kill --kill-whom=all --signal=KILL "$unit" 2>/dev/null || true
         fi
      fi
   fi

   # Stop and reset remove residual failed or inactive unit state. --collect
   # services normally disappear automatically, but recovery must not assume it.
   systemctl --user stop "$unit" 2>/dev/null || true
   systemctl --user reset-failed "$unit" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Helper: terminate an exact group of user-owned processes
# -----------------------------------------------------------------------------
# The PID snapshot prevents the final SIGKILL pass from targeting unrelated new
# processes that happen to start later with the same executable name.
terminate_named_processes() {
   local label=$1
   shift
   local pidFile="${temporaryDirectory}/${label}-pids.txt"
   local processId
   local elapsed=0
   local nextStatus=$STOP_STATUS_INTERVAL_SECONDS

   collect_process_pids "$@" > "$pidFile"
   if [[ ! -s "$pidFile" ]]; then
      echo "OK: No $label processes require termination."
      return 0
   fi

   echo "Sending SIGTERM to these $label process IDs:"
   paste -sd ' ' "$pidFile"
   while IFS= read -r processId; do
      [[ -n "$processId" ]] || continue
      kill -TERM "$processId" 2>/dev/null || true
   done < "$pidFile"

   while (( elapsed < PROCESS_TERM_GRACE_SECONDS )); do
      if ! any_recorded_process_remains "$pidFile"; then
         echo "All recorded $label processes stopped after SIGTERM."
         return 0
      fi
      sleep "$STOP_POLL_INTERVAL_SECONDS"
      elapsed=$((elapsed + STOP_POLL_INTERVAL_SECONDS))
      if (( elapsed >= nextStatus )); then
         echo "Waiting for $label processes: ${elapsed}/${PROCESS_TERM_GRACE_SECONDS} seconds"
         nextStatus=$((nextStatus + STOP_STATUS_INTERVAL_SECONDS))
      fi
   done

   echo "Grace period expired; sending SIGKILL to remaining recorded $label processes."
   while IFS= read -r processId; do
      [[ -n "$processId" ]] || continue
      if [[ $(ps -o user= -p "$processId" 2>/dev/null | awk '{$1=$1; print}') == "$USER" ]]; then
         kill -KILL "$processId" 2>/dev/null || true
      fi
   done < "$pidFile"

   sleep "$STOP_POLL_INTERVAL_SECONDS"
   ! any_recorded_process_remains "$pidFile"
}

# -----------------------------------------------------------------------------
# Helper: report FUSE overlay mounts in visible namespaces
# -----------------------------------------------------------------------------
report_fuse_mounts() {
   local mountOutput
   local unshareMountOutput

   mountOutput=$(findmnt -rn -t fuse.fuse-overlayfs,fuse-overlayfs \
      -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)
   unshareMountOutput=$(timeout "$CHECK_TIMEOUT_SECONDS" podman unshare \
      findmnt -rn -t fuse.fuse-overlayfs,fuse-overlayfs \
      -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)

   if [[ -n "$mountOutput" || -n "$unshareMountOutput" ]]; then
      [[ -n "$mountOutput" ]] && printf '%s\n' "$mountOutput"
      [[ -n "$unshareMountOutput" ]] && printf '%s\n' "$unshareMountOutput"
      return 0
   fi

   return 1
}

# -----------------------------------------------------------------------------
# Helper: verify bounded Podman metadata access
# -----------------------------------------------------------------------------
verify_podman_storage() {
   local graphRoot

   if ! timeout "$CHECK_TIMEOUT_SECONDS" podman images --no-trunc >/dev/null 2>&1; then
      echo "ERROR: 'podman images' failed or timed out." >&2
      return 1
   fi
   if ! timeout "$CHECK_TIMEOUT_SECONDS" podman ps -a >/dev/null 2>&1; then
      echo "ERROR: 'podman ps -a' failed or timed out." >&2
      return 1
   fi
   if ! timeout "$CHECK_TIMEOUT_SECONDS" \
      podman ps --all --external --no-trunc >/dev/null 2>&1; then
      echo "ERROR: External-container metadata is unresponsive." >&2
      return 1
   fi

   graphRoot=$(timeout "$CHECK_TIMEOUT_SECONDS" \
      podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)
   if [[ -z "$graphRoot" ]]; then
      echo "ERROR: Unable to resolve the Podman GraphRoot." >&2
      return 1
   fi

   echo "Podman GraphRoot: $graphRoot"
}

# -----------------------------------------------------------------------------
# Helper: report external Buildah storage records without modifying them
# -----------------------------------------------------------------------------
report_external_buildah_records() {
   local records

   records=$(timeout "$CHECK_TIMEOUT_SECONDS" \
      podman ps --all --external --no-trunc 2>&1)
   if [[ $? -ne 0 ]]; then
      echo "ERROR: Unable to query external Buildah storage records." >&2
      printf '%s\n' "$records" >&2
      return 2
   fi

   local ids
   ids=$(timeout "$CHECK_TIMEOUT_SECONDS" \
      podman ps --all --external --no-trunc --format '{{.ID}}' 2>/dev/null)
   if [[ $? -ne 0 ]]; then
      echo "ERROR: Unable to query external Buildah storage IDs." >&2
      return 2
   fi

   if [[ -n "$ids" ]]; then
      printf '%s\n' "$records"
      return 0
   fi

   echo "OK: No external Buildah storage records remain."
   return 1
}

# =============================================================================
# Command-line handling
# =============================================================================
case "${1:-}" in
   "") ;;
   --clean)
      cleanRequested=true
      ;;
   --help|-h)
      usage
      exit 0
      ;;
   *)
      echo "ERROR: Unsupported argument: $1" >&2
      usage >&2
      exit 2
      ;;
esac

# =============================================================================
# Environment preparation
# =============================================================================
validate_prerequisites || exit 2

# Source the same site configuration used by the builders and node checker so
# every Podman query targets the intended GraphRoot, RunRoot, and temporary path.
# shellcheck source=/dev/null
source "$PODMAN_SETUP_SCRIPT"

temporaryDirectory=$(mktemp -d "${TMPDIR:-/tmp}/cleanPodmanNode.XXXXXX") || exit 2
trap 'rm -rf "$temporaryDirectory"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# =============================================================================
# Initial runtime inspection
# =============================================================================
echo "Forceful Podman build-runtime cleanup"
echo "Host: $(hostname)"
echo "User: $USER"
echo "Timestamp: $(date --iso-8601=seconds)"
echo "Mode: $([[ "$cleanRequested" == true ]] && echo clean || echo inspect-only)"

runtimeStateFound=false
externalRecordsFound=false

print_heading "CONTAINER-BUILD TRANSIENT SERVICES"
serviceUnits=$(collect_container_build_services)
serviceQueryStatus=$?
if [[ $serviceQueryStatus -ne 0 ]]; then
   echo "ERROR: Unable to query the systemd user manager." >&2
   exit 2
elif [[ -n "$serviceUnits" ]]; then
   printf '%s\n' "$serviceUnits"
   runtimeStateFound=true
else
   echo "OK: No container-build transient services are loaded."
fi

print_heading "TARGETED USER PROCESSES"
report_targeted_processes
processReportStatus=$?
if [[ $processReportStatus -eq 0 ]]; then
   runtimeStateFound=true
else
   echo "OK: No targeted runtime or compilation processes are active."
fi

print_heading "FUSE OVERLAY MOUNTS"
report_fuse_mounts
fuseReportStatus=$?
if [[ $fuseReportStatus -eq 0 ]]; then
   runtimeStateFound=true
else
   echo "OK: No FUSE overlay mounts are visible."
fi

print_heading "EXTERNAL BUILDAH STORAGE RECORDS"
report_external_buildah_records
externalStatus=$?
if [[ $externalStatus -eq 0 ]]; then
   externalRecordsFound=true
   echo "NOTICE: These are Podman storage records, not running processes."
   echo "This runtime cleaner reports them but intentionally does not remove them."
elif [[ $externalStatus -eq 2 ]]; then
   exit 2
fi

# =============================================================================
# Inspect-only result
# =============================================================================
if [[ "$cleanRequested" != true ]]; then
   echo
   echo "======================================================"
   echo "PODMAN RUNTIME CLEANUP INSPECTION"
   echo "======================================================"
   echo "No changes were made."

   if [[ "$runtimeStateFound" == true ]]; then
      echo "RUNTIME CLEANUP REQUIRED: Lingering services, processes, or FUSE mounts were found."
      echo "When no legitimate user build should remain, run:"
      echo "  $(basename "$0") --clean"
      if [[ "$externalRecordsFound" == true ]]; then
         echo "After runtime cleanup, review the external Buildah storage records separately."
      fi
      exit 1
   fi

   if [[ "$externalRecordsFound" == true ]]; then
      echo "RUNTIME CLEANUP NOT REQUIRED: No services, processes, or FUSE mounts were found."
      echo "PODMAN STORAGE CLEANUP MAY BE REQUIRED: External Buildah records remain."
      echo "The --clean mode will not remove those records because it does not modify"
      echo "Podman's stored objects. Review them separately before starting another build."
      exit 1
   fi

   echo "NO CLEANUP REQUIRED: No targeted runtime state or external Buildah records remain."
   echo "Run checkPodmanNode.sh for the complete readiness check."
   exit 0
fi

# =============================================================================
# Forceful runtime cleanup
# =============================================================================
echo
echo "WARNING: --clean assumes no legitimate user build should remain on this node."
echo "The script will stop container-build services and terminate matching"
echo "user-owned container runtime and compilation processes."

print_heading "STOPPING CONTAINER-BUILD SERVICES"
if [[ -n "$serviceUnits" ]]; then
   while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      stop_container_build_service "$unit"
   done <<< "$serviceUnits"
else
   echo "OK: No container-build services require stopping."
fi

print_heading "TERMINATING COMPILATION PROCESSES"
terminate_named_processes "compilation" "${buildProcessNames[@]}" || true

print_heading "TERMINATING CONTAINER RUNTIME PROCESSES"
terminate_named_processes "container-runtime" "${runtimeProcessNames[@]}" || true

# Run one final service pass in case a unit remained loaded while its descendants
# were being terminated directly.
remainingUnits=$(collect_container_build_services)
serviceQueryStatus=$?
if [[ $serviceQueryStatus -ne 0 ]]; then
   echo "ERROR: Unable to re-query the systemd user manager." >&2
   exit 2
fi
if [[ -n "$remainingUnits" ]]; then
   print_heading "FINAL SERVICE ESCALATION"
   while IFS= read -r unit; do
      [[ -n "$unit" ]] || continue
      systemctl --user kill --kill-whom=all --signal=KILL "$unit" 2>/dev/null || true
      systemctl --user stop "$unit" 2>/dev/null || true
      systemctl --user reset-failed "$unit" 2>/dev/null || true
   done <<< "$remainingUnits"
fi

# =============================================================================
# Post-clean runtime verification
# =============================================================================
cleanupFailed=false

print_heading "SERVICE VERIFICATION"
remainingUnits=$(collect_container_build_services)
serviceQueryStatus=$?
if [[ $serviceQueryStatus -ne 0 ]]; then
   echo "ERROR: Unable to verify container-build services." >&2
   exit 2
elif [[ -n "$remainingUnits" ]]; then
   echo "ERROR: Container-build services remain:" >&2
   printf '%s\n' "$remainingUnits" >&2
   cleanupFailed=true
else
   echo "OK: No container-build transient services remain."
fi

print_heading "PROCESS VERIFICATION"
if report_targeted_processes; then
   echo "ERROR: Targeted user processes remain after cleanup." >&2
   cleanupFailed=true
else
   echo "OK: No targeted runtime or compilation processes remain."
fi

print_heading "FUSE MOUNT VERIFICATION"
if report_fuse_mounts; then
   echo "WARNING: FUSE overlay mounts remain after process cleanup." >&2
   echo "The script does not force-unmount filesystems." >&2
   cleanupFailed=true
else
   echo "OK: No FUSE overlay mounts remain."
fi

print_heading "PODMAN STORAGE RESPONSIVENESS"
if ! verify_podman_storage; then
   cleanupFailed=true
fi

print_heading "EXTERNAL BUILDAH STORAGE RECORDS"
report_external_buildah_records
externalStatus=$?
if [[ $externalStatus -eq 0 ]]; then
   echo "NOTICE: These are Podman storage records, not running processes."
   echo "They were intentionally not removed by this runtime cleaner."
elif [[ $externalStatus -eq 2 ]]; then
   cleanupFailed=true
fi

# =============================================================================
# Final result
# =============================================================================
echo
echo "======================================================"
echo "PODMAN RUNTIME CLEANUP RESULT"
echo "======================================================"

if [[ "$cleanupFailed" == true ]]; then
   echo "NOT CLEAN: Runtime state or Podman responsiveness still requires attention."
   echo "Do not start another build until checkPodmanNode.sh reports CLEAN."
   exit 1
fi

echo "CLEAN: No targeted services, processes, or FUSE mounts remain."
echo "Podman storage is responsive. External storage records, if any, were preserved."
echo "Run checkPodmanNode.sh before starting the next build."
exit 0
