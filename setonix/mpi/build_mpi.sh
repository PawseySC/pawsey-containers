#!/bin/bash


### BEGIN OF EDITABLE: edit these variables to change which images are being built
# Define versions of interest
os_vers="16.04 18.04 20.04"
os_cuda_vers="18.04" # os versions for cuda images
cuda_vers="10.1 10.2"
mpich_vers="3.4.3"
openmpi_vers="4.0.2"
### END OF EDITABLE


# SHOULD NOT modify past this point


echo " ***** "
echo " This is an experimental script to automate build of some Pawsey base images."
echo " Please ensure you are logged in to the container registry, otherwise push command will fail."
echo " ***** "
echo ""


# Define work directory for this script
basedir=$(readlink -f $0)
basedir="${basedir%/*}"
basedir="${basedir%/*}" # this assumes that the script sits in a subdirectory of $basedir
# Move to work directory
cd $basedir/mpi


# Force update starting images
for os in $os_vers ; do
  docker pull ubuntu:${os}
done
for os in $os_cuda_vers ; do
  for cuda in $cuda_vers ; do
    docker pull nvidia/cuda:${cuda}-devel-ubuntu${os}
  done
done


# Build and push images "mpich-base"
repo="mpich-base"
cd $repo
for os in $os_vers ; do
  for mpi in $mpich_vers ; do
    image="${repo}:${mpi}_ubuntu${os}"
    echo " .. Now building $image"
    # Build
    docker build \
      --build-arg OS_VERSION="${os}" \
      --build-arg MPI_VERSION="${mpi}" \
      -t quay.io/pawsey/$image .
    # Push
    docker push quay.io/pawsey/$image
  done
done
cd ..


# Build and push images "openmpi-base"
repo="openmpi-base"
cd $repo
for os in $os_vers ; do
  for mpi in $openmpi_vers ; do
    image="${repo}:${mpi}_ubuntu${os}"
    echo " .. Now building $image"
    # Build
    docker build \
      --build-arg OS_VERSION="${os}" \
      --build-arg MPI_VERSION="${mpi}" \
      -t quay.io/pawsey/$image .
    # Push
    docker push quay.io/pawsey/$image
  done
done
cd ..


# Build and push images "cuda-mpich-base"
repo="cuda-mpich-base"
cd $repo
for os in $os_cuda_vers ; do
  for cuda in $cuda_vers ; do
    for mpi in $mpich_vers ; do
      image="${repo}:${mpi}_cuda${cuda}-devel_ubuntu${os}"
      echo " .. Now building $image"
      # Build
      docker build \
        --build-arg OS_VERSION="${os}" \
        --build-arg CUDA_VERSION="${cuda}" \
        --build-arg MPI_VERSION="${mpi}" \
        -t quay.io/pawsey/$image .
      # Push
      docker push quay.io/pawsey/$image
    done
  done
done
cd ..


# Build and push images "cuda-openmpi-base"
repo="cuda-openmpi-base"
cd $repo
for os in $os_cuda_vers ; do
  for cuda in $cuda_vers ; do
    for mpi in $openmpi_vers ; do
      image="${repo}:${mpi}_cuda${cuda}-devel_ubuntu${os}"
      echo " .. Now building $image"
      # Build
      docker build \
        --build-arg OS_VERSION="${os}" \
        --build-arg CUDA_VERSION="${cuda}" \
        --build-arg MPI_VERSION="${mpi}" \
        -t quay.io/pawsey/$image .
      # Push
      docker push quay.io/pawsey/$image
    done
  done
done
cd ..


echo ""
echo " Gone through all builds and pushes. Done!"
exit
