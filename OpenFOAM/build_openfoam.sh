#!/bin/bash


# Disk space requirements:
# All images (no intermediate removal): about 110 GB
# Images in chunks (intermediate removal): about 40 GB


### BEGIN OF EDITABLE: edit these variables to change which images are being built
# Definition of base images, only to force pull them
base="quay.io/pawsey/mpich-base"
base_os_vers="16.04 18.04"
base_mpich_vers="3.4.3"
# Target registry/organisation
reg_org="quay.io/pawsey"
# Using chunks, to avoid filling up the disk of small machines
of_tool_tags_1="openfoam-org/2.2.0 openfoam-org/2.4.x openfoam-org/5.x"
of_tool_tags_2="openfoam-org/7 openfoam-org/8"
of_tool_tags_3="openfoam/v1712 openfoam/v1812 openfoam/v1912"
of_tool_tags_4="openfoam/v2006 openfoam/v2012"
chunks="of_tool_tags_1 of_tool_tags_2 of_tool_tags_3 of_tool_tags_4"
# 
# Enable removal (in chunks) of local images, to save disk space
enable_remove_local_image="0"
### END OF EDITABLE


# SHOULD NOT modify past this point


echo " ***** "
echo " This is an experimental script to automate build of Pawsey OpenFoam images."
echo " Please ensure you are logged in to the container registry, otherwise push command will fail."
echo " ***** "
echo ""


# Define work directory for this script
basedir=$(readlink -f $0)
basedir="${basedir%/*}"
# Move to work directory
# this assumes that the script sits in the parent directory of the Dockerfiles subdirectories
cd $basedir


# Force update starting images
for os in $base_os_vers ; do
  for mpich in $base_mpich_vers ; do
    base_tag="${mpich}_ubuntu${os}"
    base_image="${base}:${base_tag}"
    echo " .. Force pulling base $base_image"
    docker pull $base_image &>out_base_pull_${base_tag}
  done
done


# Build and push images "openfoam"
# using chunks, to avoid filling up the disk of small machines
for of_tool_tags in $chunks ; do
  for tool_tag in ${!of_tool_tags} ; do
    echo ""
    image="${reg_org}/${tool_tag/\//:}"
    cd $tool_tag
    echo " .. In directory $(pwd)"
    echo " .. Now building $image"
    docker build -t $image . &>../../out_build_${tool_tag/\//_}
    echo " .. Now pushing $image"
    docker push $image &>../../out_push_${tool_tag/\//_}
    cd ../..
  done

# Remove local images to save disk space
  if [ "$enable_remove_local_image" != 0 ] ; then
    for tool_tag in ${!of_tool_tags} ; do
      image="${reg_org}/${tool_tag/\//:}"
      echo " .. Now removing local $image"
      docker rmi $image &>out_rmi_${tool_tag/\//_}
    done
  fi
done


echo ""
echo " Gone through all builds and pushes. Done!"
exit
