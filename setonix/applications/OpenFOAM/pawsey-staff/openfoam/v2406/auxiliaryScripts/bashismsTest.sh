#!/bin/bash
# This script can be used to test which interpreter-shell is in use during the environment startup of containers.
# For easier testing, we recommend to use a pointer towards this file from the "entry file" (now a link) from the image
# instead of COPYing this file into the entry file of the image and build it (although that would work too).
# When using a link, the host directory containing the real script should be binded to the correct directory set inside the image.
# bashismsTest.sh - FAILS in dash/ash, passes ONLY in bash

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
    echo "   bash available → $(command -v bash)"
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



# ---------- Debugging: Testing the execution of strict bashisms
echo
echo "=== STRICT Bashisms Test (Expected to fail in dash/ash) ==="
# 1. declare -p on array (syntax error in dash/ash)
echo "1. declare -p array:"
packages=(gcc cmake flex)
declare -p packages 2>/dev/null || echo "   FAIL: declare unsupported (NOT bash)"

# 2. shopt command
echo "2. shopt nullglob:"
shopt -u nullglob 2>/dev/null || echo "   FAIL: shopt unsupported (NOT bash)"

# 3. [[ =~ ]] regex (requires bash)
echo "3. [[ regex =~ ]]:"
if [[ "v2406" =~ ^v[0-9]{4}$ ]]; then
    echo "   PASS (bash regex)"
else
    echo "   FAIL (no bash [[ =~ ])"
fi

# 4. printf %q (bash-specific)
echo "4. printf %q:"
printf "%q\n" $'test\nline' 2>/dev/null || echo "   FAIL: %%q unsupported (NOT bash)"

# 5. Bash process substitution in command
echo "5. Process substitution:"
ls <(echo "test") >/dev/null 2>/dev/null && echo "   PASS" || echo "   FAIL"

# 6. Bash mapfile/readarray
echo "6. mapfile:"
mapfile -t lines < <(echo -e "line1\nline2") 2>/dev/null && echo "   PASS (mapfile)" || echo "   FAIL"

echo "=== STRICT BASHISMS TEST COMPLETE ==="