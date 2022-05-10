#!/bin/bash


# Disk space requirements:
# All images (no intermediate removal): about 110 GB (Docker), about XX GB (Singularity)
# Images in chunks (intermediate removal): about 40 GB (Docker), about XX GB (Singularity)


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
echo " This is an experimental script to automate conversion to SIF of Pawsey OpenFoam images."
echo " Please ensure you are logged in to the container registry, otherwise push command will fail."
echo " ***** "
echo ""


# Define work directory for this script
basedir=$(readlink -f $0)
basedir="${basedir%/*}"
# Move to work directory
# this assumes that the script sits in the parent directory of the Dockerfiles subdirectories
cd $basedir


# Build and push images "openfoam"
# using chunks, to avoid filling up the disk of small machines
for of_tool_tags in $chunks ; do
  for tool_tag in ${!of_tool_tags} ; do
    echo ""
    image="${reg_org}/${tool_tag/\//:}"
    echo " .. Now pulling $image"
    docker pull $image &>out_pull_${tool_tag/\//_}
    echo " .. Now converting $image"
    singularity pull docker-daemon:$image &>out_sif_${tool_tag/\//_}
  done
done


echo ""
echo " Gone through all builds and pushes. Done!"
exit
