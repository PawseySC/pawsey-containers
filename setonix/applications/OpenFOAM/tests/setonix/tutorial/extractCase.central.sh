#!/bin/bash --login
# Extract a configured tutorial using the shared central workflow.
set -u
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/tutorialTestCommon.central.sh" || exit 1
central_stage_main EXTRACT "$@"
exit "$?"
