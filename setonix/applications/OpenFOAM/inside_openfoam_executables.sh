#!/bin/bash
set -e

# -- Receiving the name of the container as parameter
tool_tag="$1"

# -- Deducing the auxiliary variables
tool="${tool_tag%/*}"
ver="${tool_tag#*/}"

# -- Creating the directory and the file for the list
alias_dir="aliases_${tool}"
alias_file="${alias_dir}/${ver}.yaml"
mkdir -p "$alias_dir"
echo "aliases:" > "$alias_file"

# -- These are the directories that contain executables and scripts
bin_dirs=(
  "/opt/OpenFOAM/OpenFOAM-${ver}/bin"
  "/opt/OpenFOAM/OpenFOAM-${ver}/platforms/linux64GccDPInt32Opt/bin"
)

# -- Checking for executables and scripts to be added to the list
for bindir in "${bin_dirs[@]}"; do
  if [ -d "$bindir" ]; then
    for bin in "$bindir"/*; do
      if [ -x "$bin" ] && [ ! -d "$bin" ]; then
        echo " Adding $bin"
        echo "  $(basename "$bin"): $bin" >> "$alias_file"
      fi
    done
  fi
done

echo "Alias file for $tool_tag generated at ${alias_file}"
