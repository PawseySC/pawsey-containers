#!/bin/bash
#This script should be copied into the image to the right path for the Singularity Environment Files.
#After copying, the BASHRC_TEMPLATE TAG should be replaced with the correct path to the OpenFOAM bashrc file.

# Singularity Environment Script to be sourced on entry to singularity container.
# Works when "singularity exec" or "singularity shell" are invoqued.
# IMPORTANT: Avoid the use of "singularity run" as this command invoques Docker ENTRYPOINT+CMD after sourcing Singularity environment
#            and fails for some corner cases.
# IMPORTANT2: NO `exec "$@"` command at the end
# `exec "$@"` should NOT be used in the environment script for Singularity.
# Otherwise, the Host Environment variables will be lost.
# Keeping the Host Environment variables is important to be able to set from the outside:
#      export FOAM_IORANKS="(0 32 64 96 128 160 192 224 256)"
# for example.
# This is the main reason why separate scripts are kept for Docker and for Singularity startup environments.

# ---------- Debugging: Is the script being sourced or executed?
echo
echo "=== DETECTING TYPE OF ACTION ==="
# 1. Action detection with POSIX commands (knowing that /.singularity.d/actions/* scripts always source)
case "${0}" in
    *"/.singularity.d/actions/"*) sourced=1 ;;  # Singularity ALWAYS sources env scripts
    */bin/sh|*/bin/bash|bash|sh)  sourced=1 ;;  # Shell names = sourced
    *.sh)                         sourced=0 ;;  # .sh filename = executed
    *)                            # Fallback
        (return 0 2>/dev/null) && sourced=1 || sourced=0 ;;
esac

[ "$sourced" = 1 ] && echo "POSIX test: SOURCED (. or source command)" || echo "POSIX test: EXECUTED directly"

# 2. Action detection with bash-isms (comment them out if creating problems due to the bashisms)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Bash test: Current script has been: EXECUTED directly"
else
    echo "Bash test: Current script has been: SOURCED (. or source command)"
fi
echo "=============================="

# ---------- Debugging: Comprehensive Shell Detection
# Identifies Singularity starter-suid, container shell,
# parent processes, bash status, and OS-specific binaries (dash/busybox)

echo
echo "=== COMPREHENSIVE SHELL DETECTION ==="
echo "Detects: Singularity runtime | Container shell | Bash status | OS binaries"

# 1. Process basics + readlink (handles BusyBox ps failures)
echo "1. Process Information:"
echo "   PID: $$"
echo "   Executable: $(readlink /proc/$$/exe 2>/dev/null || echo 'readlink failed')"
echo "   Invocation: $(ps -o args= -p $$ 2>/dev/null || echo 'ps failed')"

# 2. Shell identity ($0 reveals Singularity actions/run context)
echo "2. Shell Identity:"
echo "   Current shell (\$0): $0"
if [[ "$0" == *"/.singularity.d/actions/"* ]]; then
    echo "   SINGULARITY RUNTIME DETECTED (actions script)"
else
    echo "   Normal shell execution"
fi

# 3. Parent process tree (starter-suid → Singularity parent)
echo "3. Parent Process Tree:"
ps_out=$(ps -p $$ -o pid,ppid,comm= 2>/dev/null)
if [ -n "$ps_out" ]; then
    echo "   $ps_out" | tail -1 | sed 's/^/   /'
    if echo "$ps_out" | grep -q starter-suid; then
        echo "   STARTER-SUID SINGULARITY PARENT CONFIRMED"
    fi
else
    echo "   ps output unavailable (BusyBox limitation)"
fi

# 4. Bash detection (definitive)
echo "4. Bash Status:"
if [ -n "${BASH_VERSION:-}" ]; then
    echo "   BASH_VERSION: $BASH_VERSION → FULL BASH CONFIRMED"
else
    echo "   No BASH_VERSION → POSIX shell or restricted bash"
fi

# 5. Container/OS shell binaries (distinguishes Alpine/Ubuntu/Debian)
echo "5. Container Shell Binaries:"
binaries_found=0
if command -v busybox >/dev/null 2>&1; then
    echo "   BusyBox found → ALPINE Linux (ash shell)"
    binaries_found=1
fi
if command -v dash >/dev/null 2>&1; then
    echo "   dash found → UBUNTU/DEBIAN (dash /bin/sh)"
    binaries_found=1
fi
if command -v bash >/dev/null 2>&1; then
    echo "   bash available → $(command -v bash) (may not be active)"
fi
if [ $binaries_found -eq 0 ]; then
    echo "   Minimal container (no standard shell binaries)"
fi

# 6. Shell symlink resolution
echo "6. Shell Symlink Chain:"
ls -l /bin/sh /bin/ash /bin/dash /bin/bash 2>/dev/null | head -4 | sed 's/^/   /' || \
echo "   Symlink resolution failed"

echo "=== SHELL DETECTION COMPLETE ==="
echo "Summary: PID=$$ | Shell=$0 | Parent=starter-suid | Bash=No"

# ---------- Debugging: Show the explicit positional variables
echo
echo "=== EXPLICIT POSITIONAL VARIABLES CURRENTLY IN PLAY ==="
echo "The \"argument-zero\", usually the command or script in execution:"
echo "0: $0"
echo "Number of arguments: $#"
for ((i=1; i<=$#; i++)); do
   echo "$i: ${!i}"
done
echo "====================================="

# ----------- Debugging: Defining some debugging environment variable
echo
echo "===  DEFINING DEBUGGING VARIABLES ==="
export MYVAR_SINGENTRY="SSSS"
echo "MYVAR_SINGENTRY = $MYVAR_SINGENTRY"
echo "====================================="

# ----------- Debugging: Final comments
echo
echo "This is the end of the debugging part of the script!"
echo "What comes after the following line is the result of the container execution:"
echo "======================================="

# Singularity Environment Script to be sourced on entry to singularity container.
# Works when "singularity exec" or "singularity shell" are invoqued.
# IMPORTANT: Avoid the use of "singularity run" as this command invoques Docker ENTRYPOINT+CMD after this one
#            and fails for some corner cases.
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