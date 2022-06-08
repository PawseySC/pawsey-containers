#!/bin/bash


# Disk space requirements:
# All images (no intermediate removal): about 110 GB (Docker), about 50  GB (Singularity, incl cache)
# Images in chunks (intermediate removal): about 40 GB (Docker), about 16 GB (Singularity, incl cache)


### BEGIN OF EDITABLE: edit these variables to change which images are being built
# Target registry/organisation
reg_org="quay.io/pawsey"
# Using chunks, to avoid filling up the disk of small machines
of_tool_tags_1="openfoam-org/2.2.0 openfoam-org/2.4.x openfoam-org/5.x"
of_tool_tags_2="openfoam-org/7 openfoam-org/8"
of_tool_tags_3="openfoam/v1712 openfoam/v1812 openfoam/v1912"
of_tool_tags_4="openfoam/v2006 openfoam/v2012"
chunks="of_tool_tags_1 of_tool_tags_2 of_tool_tags_3 of_tool_tags_4"
### END OF EDITABLE


# SHOULD NOT modify past this point


echo " ***** "
echo " This is an experimental script to automate generation of command aliases Pawsey OpenFoam images."
echo " ***** "
echo ""


# Define work directory for this script
basedir=$(readlink -f $0)
basedir="${basedir%/*}"
# Move to work directory
# this assumes that the script sits in the parent directory of the Dockerfiles subdirectories
cd $basedir


# Generate lists of command aliases for each openfoam image
# using chunks, to avoid filling up the disk of small machines
for of_tool_tags in $chunks ; do
  for tool_tag in ${!of_tool_tags} ; do
    sif="${tool_tag/\//_}.sif"
    tool="${sif%_*}"
    ver="${sif#*_}"
    ver="${ver%.sif}"
    alias_dir="aliases_${tool}"
    alias_file="${alias_dir}/${ver}.yaml"
    echo " .. Now creating command aliases for $sif"
    mkdir -p $alias_dir
    echo "aliases:" >$alias_file
    bindir="$( singularity exec $sif which pimpleFoam )"
    bindir="${bindir%/*}"
    list_file="list_cmd_${tool}_${ver}"
    bin_list="$( singularity exec $sif ls $bindir >${list_file} )"
    for bin in $( cat $list_file  ) ; do
      echo "  ${bin}: ${bin}" >>$alias_file
    done 
    rm -f $list_file
  done
done

# Create tarball with all command aliases
alias_tgz="command_aliases_openfoam.tgz"
echo ""
echo " .. Creating tarball containing all command aliases"
rm -f $alias_tgz
tar czf $alias_tgz aliases_*/
rm -r aliases_*/

echo ""
echo " Gone through all alias generations. Done!"
exit
