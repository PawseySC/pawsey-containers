#!/usr/bin/env bash

# =============================================================================
# Podman container-build node cleanliness check
# =============================================================================
# This companion script verifies that the current user's Podman build environment
# is ready for a new container build operation. It performs read-only checks
# for build-related processes, transient container services, external Buildah
# containers, FUSE overlay mounts, and Podman storage responsiveness.
#
# The script never kills processes, removes containers, unmounts filesystems,
# prunes images, or modifies Podman storage. Any reported issue must be reviewed
# before a cleanup action is selected.
#
# Exit status:
#   0  The checked Podman environment is clean and responsive.
#   1  Active or residual build state was found.
#   2  A required command, configuration, or Podman query failed.

set -o pipefail

# =============================================================================
# Initial settings
# =============================================================================
# Allow the site-specific Podman setup script and command timeout to be overridden
# without editing this file.
PODMAN_SETUP_SCRIPT=${PODMAN_SETUP_SCRIPT:-/container/setup_podman.sh}
CHECK_TIMEOUT_SECONDS=${CHECK_TIMEOUT_SECONDS:-30}

# Track cleanliness findings separately from operational check failures so the
# final message and exit status distinguish residual state from a broken probe.
cleanlinessIssues=0
checkErrors=0

# Build-related executable names checked for the current user. Exact-name matching
# avoids treating unrelated commands whose arguments contain these words as builds.
buildProcessNames=(
   podman
   buildah
   conmon
   fuse-overlayfs
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
  $(basename "$0") --help

Environment overrides:
  PODMAN_SETUP_SCRIPT     Podman environment script
                          Default: /container/setup_podman.sh
  CHECK_TIMEOUT_SECONDS   Timeout for each Podman metadata query
                          Default: 30
USAGE
}

# -----------------------------------------------------------------------------
# Helper: print one consistently formatted check heading
# -----------------------------------------------------------------------------
print_check_heading() {
   local title=$1
   echo
   echo "===== $title ====="
}

# -----------------------------------------------------------------------------
# Helper: record a cleanliness issue
# -----------------------------------------------------------------------------
record_cleanliness_issue() {
   ((++cleanlinessIssues))
}

# -----------------------------------------------------------------------------
# Helper: record an operational check failure
# -----------------------------------------------------------------------------
record_check_error() {
   ((++checkErrors))
}

# -----------------------------------------------------------------------------
# Helper: validate script configuration and required commands
# -----------------------------------------------------------------------------
validate_prerequisites() {
   local commandName
   local -a requiredCommands=(
      findmnt
      pgrep
      podman
      systemctl
      timeout
   )

   if [[ ! "$CHECK_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: CHECK_TIMEOUT_SECONDS must be a positive integer; got '$CHECK_TIMEOUT_SECONDS'." >&2
      return 1
   fi

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
# Helper: check build-related processes owned by the current user
# -----------------------------------------------------------------------------
check_build_processes() {
   local processName
   local processOutput

   print_check_heading "BUILD-RELATED PROCESSES"
   for processName in "${buildProcessNames[@]}"; do
      processOutput=$(pgrep -u "$USER" -a -x "$processName" 2>/dev/null || true)
      if [[ -n "$processOutput" ]]; then
         echo "FOUND: $processName"
         printf '%s\n' "$processOutput"
         record_cleanliness_issue
      else
         echo "OK: $processName"
      fi
   done
}

# -----------------------------------------------------------------------------
# Helper: check transient container user services
# -----------------------------------------------------------------------------
check_container_services() {
   local serviceOutput

   print_check_heading "CONTAINER TRANSIENT SERVICES"
   serviceOutput=$(systemctl --user list-units --all 'container-*.service' \
      --no-legend --no-pager 2>&1)
   if [[ $? -ne 0 ]]; then
      echo "ERROR: Unable to query the systemd user manager." >&2
      printf '%s\n' "$serviceOutput" >&2
      record_check_error
      return
   fi

   if [[ -n "$serviceOutput" ]]; then
      printf '%s\n' "$serviceOutput"
      record_cleanliness_issue
   else
      echo "OK: No container transient services are loaded."
   fi
}

# -----------------------------------------------------------------------------
# Helper: check external Buildah containers visible through Podman
# -----------------------------------------------------------------------------
check_external_containers() {
   local containerOutput

   print_check_heading "EXTERNAL BUILDAH CONTAINERS"
   containerOutput=$(timeout "$CHECK_TIMEOUT_SECONDS" \
      podman ps --all --external --no-trunc 2>&1)
   if [[ $? -ne 0 ]]; then
      echo "ERROR: The external-container query failed or timed out." >&2
      printf '%s\n' "$containerOutput" >&2
      record_check_error
      return
   fi

   # Podman's formatted ID query avoids treating the table header as a container.
   local containerIds
   containerIds=$(timeout "$CHECK_TIMEOUT_SECONDS" \
      podman ps --all --external --no-trunc --format '{{.ID}}' 2>/dev/null)
   if [[ $? -ne 0 ]]; then
      echo "ERROR: Unable to obtain external-container IDs." >&2
      record_check_error
   elif [[ -n "$containerIds" ]]; then
      printf '%s\n' "$containerOutput"
      record_cleanliness_issue
   else
      echo "OK: No external Buildah containers remain."
   fi
}

# -----------------------------------------------------------------------------
# Helper: check visible FUSE overlay mounts
# -----------------------------------------------------------------------------
check_fuse_mounts() {
   local mountOutput
   local unshareMountOutput

   print_check_heading "FUSE OVERLAY MOUNTS"

   # Check the current mount namespace first.
   mountOutput=$(findmnt -rn -t fuse.fuse-overlayfs,fuse-overlayfs \
      -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)

   # Rootless Podman mounts may be visible only inside its user namespace.
   unshareMountOutput=$(timeout "$CHECK_TIMEOUT_SECONDS" podman unshare \
      findmnt -rn -t fuse.fuse-overlayfs,fuse-overlayfs \
      -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)

   if [[ -n "$mountOutput" || -n "$unshareMountOutput" ]]; then
      [[ -n "$mountOutput" ]] && printf '%s\n' "$mountOutput"
      [[ -n "$unshareMountOutput" ]] && printf '%s\n' "$unshareMountOutput"
      record_cleanliness_issue
   else
      echo "OK: No FUSE overlay mounts remain."
   fi
}

# -----------------------------------------------------------------------------
# Helper: check Podman metadata and storage responsiveness
# -----------------------------------------------------------------------------
check_podman_storage() {
   local graphRoot

   print_check_heading "PODMAN STORAGE RESPONSIVENESS"

   if ! timeout "$CHECK_TIMEOUT_SECONDS" podman images --no-trunc >/dev/null 2>&1; then
      echo "ERROR: 'podman images' failed or timed out." >&2
      record_check_error
   else
      echo "OK: Image metadata is responsive."
   fi

   if ! timeout "$CHECK_TIMEOUT_SECONDS" podman ps -a >/dev/null 2>&1; then
      echo "ERROR: 'podman ps -a' failed or timed out." >&2
      record_check_error
   else
      echo "OK: Container metadata is responsive."
   fi

   if ! timeout "$CHECK_TIMEOUT_SECONDS" \
      podman ps --all --external --no-trunc >/dev/null 2>&1; then
      echo "ERROR: External-container metadata is unresponsive." >&2
      record_check_error
   else
      echo "OK: External-container metadata is responsive."
   fi

   graphRoot=$(timeout "$CHECK_TIMEOUT_SECONDS" \
      podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)
   if [[ -z "$graphRoot" ]]; then
      echo "ERROR: Unable to resolve the Podman GraphRoot." >&2
      record_check_error
   else
      echo "Podman GraphRoot: $graphRoot"
   fi
}

# =============================================================================
# Command-line handling
# =============================================================================
case "${1:-}" in
   "") ;;
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

# Source the same site configuration used by the container builders so every
# Podman query targets the intended GraphRoot, RunRoot, and temporary directory.
# shellcheck source=/dev/null
source "$PODMAN_SETUP_SCRIPT"

echo "Container build-node cleanliness check"
echo "Host: $(hostname)"
echo "User: $USER"
echo "Timestamp: $(date --iso-8601=seconds)"

# =============================================================================
# Cleanliness checks
# =============================================================================
check_build_processes
check_container_services
check_external_containers
check_fuse_mounts
check_podman_storage

# =============================================================================
# Final result
# =============================================================================
echo
echo "======================================================"
echo "CONTAINER BUILD-NODE CLEANLINESS RESULT"
echo "======================================================"

if (( checkErrors > 0 )); then
   echo "ERROR: $checkErrors required check(s) failed."
   echo "The node's cleanliness could not be established reliably."
   exit 2
fi

if (( cleanlinessIssues > 0 )); then
   echo "NOT CLEAN: $cleanlinessIssues active or residual condition(s) were found."
   echo "Review the findings before starting another container operation."
   exit 1
fi

echo "CLEAN: No active or residual container-build state was found."
echo "Podman storage is responsive and ready for another build."
exit 0
