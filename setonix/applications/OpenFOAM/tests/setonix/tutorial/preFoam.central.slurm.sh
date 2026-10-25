#!/bin/bash --login
#SBATCH --job-name=preFoam-tutorialCase
#SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=14GB
#SBATCH --time=00:10:00
# Prepare the extracted tutorial; launcher overrides must match its config.
# Standalone sbatch uses the defaults above. For a different configured resource
# request, pass matching sbatch --nodes/--ntasks/--cpus-per-task/--mem/--time.
# Runtime verifies actual node/task/CPU allocation, not memory or walltime.
set -u
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/tutorialTestCommon.central.sh" || exit 1
central_stage_main PRE "$@"
exit "$?"
