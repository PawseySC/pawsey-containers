#!/bin/bash --login
#SBATCH --job-name=runFoam-tutorialCase
#SBATCH --partition=work
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00
# Run and validate the tutorial; allocation must match its decomposition.
# Standalone sbatch uses the defaults above. Override nodes/tasks/CPUs/time and
# --ntasks-per-node explicitly when changing the configured resource request.
# Runtime verifies actual node/task/CPU allocation, not walltime.
set -u
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/tutorialTestCommon.central.sh" || exit 1
central_stage_main RUN "$@"
exit "$?"
