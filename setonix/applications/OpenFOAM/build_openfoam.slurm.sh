#!/bin/bash -l
#SBATCH --job-name=buildAll_openfoam
#SBATCH --partition=podman
#SBATCH --nodes=1
#SBATCH --ntasks=16
#SBATCH --time=24:00:00

# --- Exit on error
set -euo pipefail

# --- Job information
#scontrol show job "$SLURM_JOB_ID"

# --- Modules and environment
# Set up Podman environment variables and paths.
source /container/setup_podman.sh
# Load the Singularity module.
module load singularity/4.1.0-mpi

# --- Build parameters
engineToUse="podman"

# Optional build-argument overrides applied to every selected recipe.
# Comment out all entries to use the defaults defined in each recipe.
buildArguments=(
    # "BASE_IMAGE_MPICH_VERSION=4.2.2"
    # "WM_LABEL_SIZE=64"
    # "TP_COMPILE_TASKS=8"
)

# Comment out any recipe directory that should not be built.
recipeDirectories=(
    # "openfoam/v2606"
    "openfoam/v2412"
    "openfoam/v2406"
    "openfoam/v2212"
    "openfoam/v2206"
    "openfoam/v2012"
)

# --- Repository paths
# REPOSITORY_ROOT may be supplied in the submission environment. Otherwise, use
# the standard location of the repository on Setonix.
repositoryRoot="${REPOSITORY_ROOT:-${MYSCRATCH}/pawsey-containers}"
openfoamRoot="${repositoryRoot}/setonix/applications/OpenFOAM"

containerBuilder="${openfoamRoot}/buildingScripts/openfoamContainerBuild.sh"
singularityBuilder="${openfoamRoot}/buildingScripts/openfoamSingularityBuild.sh"

# Convert each NAME=VALUE entry into a repeated --build-arg option.
buildArgumentOptions=()
for buildArgument in "${buildArguments[@]}"; do
    buildArgumentOptions+=(--build-arg "$buildArgument")
done

# Validate the repository paths and builder scripts before starting the sequence.
[[ -d "$repositoryRoot" ]] || { echo "ERROR: Repository root does not exist: $repositoryRoot" >&2; exit 1; }
[[ -d "$openfoamRoot" ]] || { echo "ERROR: OpenFOAM root does not exist: $openfoamRoot" >&2; exit 1; }
[[ -x "$containerBuilder" ]] || { echo "ERROR: Container builder is not executable: $containerBuilder" >&2; exit 1; }
[[ -x "$singularityBuilder" ]] || { echo "ERROR: Singularity builder is not executable: $singularityBuilder" >&2; exit 1; }

# --- Build each selected OpenFOAM version sequentially
for recipeDirectory in "${recipeDirectories[@]}"; do
    recipePath="${openfoamRoot}/${recipeDirectory}"

    [[ -d "$recipePath" ]] || {
        echo "ERROR: Recipe directory does not exist: $recipePath" >&2
        exit 1
    }

    echo "================================================================"
    echo "Building OpenFOAM recipe: $recipeDirectory"
    echo "Repository root: $repositoryRoot"
    echo "Recipe path: $recipePath"
    echo "================================================================"

    "$containerBuilder" \
        --engine "$engineToUse" \
        --recipe-dir "$recipePath" \
        "${buildArgumentOptions[@]}"

    "$singularityBuilder" \
        --engine "$engineToUse" \
        --recipe-dir "$recipePath" \
        "${buildArgumentOptions[@]}"

    echo "Completed OpenFOAM recipe: $recipeDirectory"
done

echo "All selected OpenFOAM builds completed successfully."
