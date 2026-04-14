#!/bin/bash
#This script should be copied into the image to the right path for the Docker Entrypoint File.
#After copying, the BASHRC_TEMPLATE_TAG should be replaced with the correct path to the OpenFOAM bashrc file.

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
# --- Execute command
exec "$@"