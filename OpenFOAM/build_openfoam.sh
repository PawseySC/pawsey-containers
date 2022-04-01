#!/bin/bash


# Disk space requirements:
# All images (no intermediate removal): about 110 GB
# Images in chunks (intermediate removal): about 40 GB


### BEGIN OF EDITABLE: edit these variables to change which images are being built
# Definition of base images, only to force pull them
base="quay.io/pawsey/mpich-base"
base_os_vers="16.04 18.04"
base_mpich_vers="3.4.3"
# Target repo
repo="quay.io/pawsey/openfoam"
# Using chunks, to avoid filling up the disk of small machines
of_tags_1="2.2.0 2.4.x 5.x 5.x_CFDEM"
of_tags_2="7 8"
of_tags_3="v1712 v1812 v1912"
of_tags_4="v2006 v2012"
chunks="of_tags_1 of_tags_2 of_tags_3 of_tags_4"
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
for of_tags in $chunks ; do
  echo ""

  for tag in ${!of_tags} ; do
    image="$repo:$tag"
    if [ "$tag" == "5.x_CFDEM" ] ; then
      cd installationsWithAdditionalTools/openfoam-$tag
    else
      cd basicInstallations/openfoam-$tag
    fi
    echo " .. In directory $(pwd)"
    echo " .. Now building $image"
    docker build -t $image . &>../../out_build_$tag
    echo " .. Now pushing $image"
    docker push $image &>../../out_push_$tag
    cd ../..
  done

# Remove local images to save disk space
  if [ "$enable_remove_local_image" != 0 ] ; then
    for tag in ${!of_tags} ; do
      image="$repo:$tag"
      echo " .. Now removing local $image"
      docker rmi $image &>out_rmi_$tag
    done
  fi
done


echo ""
echo " Gone through all builds and pushes. Done!"
exit
