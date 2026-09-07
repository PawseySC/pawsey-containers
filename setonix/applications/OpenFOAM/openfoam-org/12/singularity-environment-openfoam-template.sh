#!/bin/bash
#This script should be copied into the image to the right path for the Singularity Environment Files.
#After copying, the BASHRC_TEMPLATE TAG should be replaced with the correct path to the OpenFOAM bashrc file.

# Singularity Environment Script to be sourced on entry to singularity container.
# Works when "singularity exec" or "singularity shell" are invoqued.
# IMPORTANT: Avoid the use of "singularity run" as this command invoques Docker ENTRYPOINT+CMD after sourcing Singularity environment
#            and fails for some corner cases.
# IMPORTANT2: NO `exec "$@"` command at the end

# ----------- Main: Load OpenFOAM environement
# --- Load OpenFOAM environment safely
if [ -z "${OPENFOAM_ENV_LOADED+x}" ]; then
    if [ -f BASHRC_TEMPLATE_TAG ]; then
        # Save current arguments
        old_argv=("$@")
        # Then clear positional parameters to avoid breaking bashrc internals
        set --
        # Source OpenFOAM bashrc
        source BASHRC_TEMPLATE_TAG
        # Restore arguments
        set -- "${old_argv[@]}"
        unset old_argv
    else
        echo "ERROR: OpenFOAM bashrc not found"
        return 1 2>/dev/null || exit 1
    fi
    export OPENFOAM_ENV_LOADED=1
fi
# --- IMPORTANT: NO `exec "$@"` command at the end
# `exec "$@"` should NOT be used in the environment script for Singularity.
# Otherwise, the Host Environment variables will be lost.
# Keeping the Host Environment variables is important to be able to set from the outside:
#      export FOAM_IORANKS="(0 32 64 96 128 160 192 224 256)"
# for example.
# This is the main reason why separate scripts are kept for Docker and for Singularity startup environments.