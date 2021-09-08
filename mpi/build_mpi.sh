#!/bin/bash

basedir=$(readlink -f $0)
basedir="${basedir%/*}"
basedir="${basedir%/*}" # this assumes that the script sits in a subdirectory of $basedir
cd $basedir/mpi


echo " ***** "
echo " This is an experimental script to automate build of some Pawsey base images."
echo " Please ensure you are logged in to the container registry, otherwise push command will fail."
echo " ***** "
echo ""


# Define versions of interest
os_vers="16.04 18.04 20.04"
os_cuda_vers="18.04"
cuda_vers="10.1 10.2"
mpich_vers="3.1.4"
openmpi_vers="2.1.2 4.0.2" # when Zeus is gone, can ditch 2.x and unify this and the following variable
openmpi_cuda_vers="4.0.2"


# Update starting images
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
    docker build \
      --build-arg OS_VERSION="${os}" \
      --build-arg MPI_VERSION="${mpi}" \
      -t quay.io/pawsey/$image .
    docker push quay.io/pawsey/$image
    # Begin - Docker Hub - will go away
    docker tag quay.io/pawsey/$image pawsey/$image
    docker push pawsey/$image
    docker rmi pawsey/$image
    # End - Docker Hub
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
    docker build \
      --build-arg OS_VERSION="${os}" \
      --build-arg MPI_VERSION="${mpi}" \
      -t quay.io/pawsey/$image .
    docker push quay.io/pawsey/$image
    # Begin - Docker Hub - will go away
    docker tag quay.io/pawsey/$image pawsey/$image
    docker push pawsey/$image
    docker rmi pawsey/$image
    # End - Docker Hub
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
      docker build \
        --build-arg OS_VERSION="${os}" \
        --build-arg CUDA_VERSION="${cuda}" \
        --build-arg MPI_VERSION="${mpi}" \
        -t quay.io/pawsey/$image .
      docker push quay.io/pawsey/$image
      # Begin - Docker Hub - will go away
      docker tag quay.io/pawsey/$image pawsey/$image
      docker push pawsey/$image
      docker rmi pawsey/$image
      # End - Docker Hub
    done
  done
done
cd ..


# Build and push images "cuda-openmpi-base"
repo="cuda-openmpi-base"
cd $repo
for os in $os_cuda_vers ; do
  for cuda in $cuda_vers ; do
    for mpi in $openmpi_cuda_vers ; do
      image="${repo}:${mpi}_cuda${cuda}-devel_ubuntu${os}"
      echo " .. Now building $image"
      docker build \
        --build-arg OS_VERSION="${os}" \
        --build-arg CUDA_VERSION="${cuda}" \
        --build-arg MPI_VERSION="${mpi}" \
        -t quay.io/pawsey/$image .
      docker push quay.io/pawsey/$image
      # Begin - Docker Hub - will go away
      docker tag quay.io/pawsey/$image pawsey/$image
      docker push pawsey/$image
      docker rmi pawsey/$image
      # End - Docker Hub
    done
  done
done
cd ..


echo ""
echo " Gone through all builds and pushes. Done!"
exit

