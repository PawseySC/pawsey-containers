#!/bin/bash


# Disk space requirements:
# All images (no intermediate removal): about 110 GB (Docker), about 50  GB (Singularity, incl cache)
# Images in chunks (intermediate removal): about 40 GB (Docker), about 16 GB (Singularity, incl cache)


### BEGIN OF EDITABLE: edit these variables to change which images are being built
# Target registry/organisation
reg_org="quay.io/pawsey"
# Using chunks, to avoid filling up the disk of small machines
of_tool_tags_1="openfoam/v2412"
of_tool_tags_2="openfoam/v2212 openfoam/v2206 openfoam/v2012"
of_tool_tags_3="openfoam/v2006 openfoam/v1912"
#of_tool_tags_4="openfoam/v1812 openfoam/v1712"
of_tool_tags_5="openfoam-org/12"
of_tool_tags_6="openfoam-org/10 openfoam-org/9 openfoam-org/8"
of_tool_tags_7="openfoam-org/7"
#of_tool_tags_8="openfoam-org/5.x openfoam-org/2.4.x openfoam-org/2.2.0"
#chunks="of_tool_tags_1 of_tool_tags_2 of_tool_tags_3 of_tool_tags_4 of_tool_tags_5 of_tool_tags_6 of_tool_tags_7 of_tool_tags_8"
#chunks="of_tool_tags_1 of_tool_tags_2 of_tool_tags_3 of_tool_tags_5 of_tool_tags_6 of_tool_tags_7"
chunks="of_tool_tags_1 of_tool_tags_5"

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
internal_script="./inside_openfoam_executables.sh"
for of_tool_tags in $chunks ; do
  for tool_tag in ${!of_tool_tags} ; do
    sif="${tool_tag/\//_}.sif"
    
    singularity exec "$sif" bash -c "$internal_script $tool_tag"
    
  done
done

# Create tarball with all command aliases
#alias_tgz="command_aliases_openfoam.tgz"
#echo ""
#echo " .. Creating tarball containing all command aliases"
#rm -f $alias_tgz
#tar czf $alias_tgz aliases_*/
#rm -r aliases_*/

echo ""
echo " Gone through all alias generations. Done!"
exit
