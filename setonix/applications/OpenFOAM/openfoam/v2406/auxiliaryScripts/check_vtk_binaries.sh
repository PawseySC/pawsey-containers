#!/bin/bash
# scan VTK-linked binaries recursively in APPBIN and LIBBIN
# now including indirect symbol scan for all executables/libraries

echo "========================================"
echo "Scanning compiled binaries for VTK linkage"
echo "========================================"

dirs=("$FOAM_APPBIN" "$FOAM_LIBBIN")

for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue

    find "$dir" -type f \( -executable -o -name "*.so" \) \
        ! -name "*.o" ! -name "*.dep" | while read -r f; do
        
        toolname=$(basename "$f")
        if [[ "$dir" == "$FOAM_APPBIN" ]]; then
            type="Executable"
        else
            type="Library"
        fi

        # Direct linkage
        if ldd "$f" 2>/dev/null | grep -qi vtk; then
            echo "$type VTK-linked: $f"
            echo "TOOL:$toolname"
        else
            # Indirect linkage: scan symbols in all executables and libraries
            if nm -D "$f" 2>/dev/null | grep -qi vtk; then
                echo "$type indirectly using VTK: $f"
                echo "TOOL:$toolname"
            fi
        fi
    done
done

echo "========================================"
echo "Done"
echo "========================================"
