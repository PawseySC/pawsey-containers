#!/bin/bash

basedir=$(readlink -f $0)
basedir="${basedir%/*}"
basedir="${basedir%/*}" # this assumes that the script sits in a subdirectory of $basedir
cd $basedir/python


echo " ***** "
echo " This is an experimental script to automate build of some Pawsey base images."
echo " Please ensure you are logged in to the container registry, otherwise push command will fail."
echo " ***** "
echo ""


# Define versions of interest
py_ver="3.9"
ipy_ver="2020.2"
cuda_ver="10.2"
cuda_ext_ver="10.2.89"


# Get and format date
date_tag="$( date +%Y.%m )"
date_file="$( date +%d%b%Y )"


# Update starting images
docker pull python:${py_ver}-slim
docker pull intelpython/intelpython3_core:${ipy_ver}


# Build and push images "hpc-python"
repo="hpc-python"
cd $repo
image="${repo}:${date_tag}"
echo " .. Now building $image"
docker run --rm \
  -u $(id -u):$(id -g) \
  -v $(pwd):$(pwd) -w $(pwd) \
  --env date_file=${date_file} --env HOME=$(pwd)/.home_py \
  python:${py_ver}-slim bash -c 'pip3 install --user pip-tools && \
    $HOME/.local/bin/pip-compile requirements.in -o requirements-${date_file}.txt'
rm -r .home_py
docker build \
  --build-arg PY_VERSION="${py_ver}" \
  --build-arg DATE_FILE=${date_file} \
  -t quay.io/pawsey/$image .
docker push quay.io/pawsey/$image
# Begin - Docker Hub - will go away
docker tag quay.io/pawsey/$image pawsey/$image
docker push pawsey/$image
docker rmi pawsey/$image
# End - Docker Hub
cd ..


# Build and push images "hpc-python-hdf5mpi"
repo="hpc-python-hdf5mpi"
cd $repo
image="${repo}:${date_tag}"
echo " .. Now building $image"



cd ..




echo ""
echo " Gone through all builds and pushes. Done!"
exit

