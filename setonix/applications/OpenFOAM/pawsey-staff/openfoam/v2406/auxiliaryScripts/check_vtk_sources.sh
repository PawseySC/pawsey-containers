#!/usr/bin/env bash
# Check OpenFOAM source for VTK usage with canonical TOOL lines
set -e

if [ -z "$WM_PROJECT_DIR" ]; then
    echo "ERROR: OpenFOAM environment not loaded" >&2
    exit 1
fi

echo
echo "========================================"
echo "Scanning OpenFOAM source for VTK usage"
echo "Project: $WM_PROJECT_DIR"
echo "========================================"
echo

FOUND=0

while IFS= read -r file; do
    if grep -Ei "vtk|VTK_LIBRARIES" "$file" >/dev/null 2>&1; then
        FOUND=1
        echo "----------------------------------------"
        echo "VTK usage detected in:"
        echo "$file"
        echo
        grep -Ei "vtk|VTK_LIBRARIES" "$file"
        echo
        # Canonical line for diffing
        relpath=${file#$WM_PROJECT_DIR/}
        toolname=$(dirname "$(dirname "$relpath")" | awk -F/ '{print $NF}')
        echo "TOOL:$toolname"
    fi
done < <(find "$WM_PROJECT_DIR" -type f -path "*/Make/options")

if [ "$FOUND" -eq 0 ]; then
    echo "No VTK usage found in source."
fi

echo
echo "========================================"
echo "Done"
echo "========================================"
