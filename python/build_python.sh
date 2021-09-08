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
cuda_ver="10.2" # this is for cuda-hpc-python -- each cuda version needs a dedicated dockerfile
cuda_ext_ver="10.2.89" # this one is for cuda-intel-hpc-python
mpich_ver="3.1.4"
hdf5_ver="1.12.0"


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
mkdir -p .home_py
docker run --rm \
  -u $(id -u):$(id -g) \
  -v $(pwd):$(pwd) -w $(pwd) \
  --env date_file="${date_file}" --env HOME="$(pwd)/.home_py" \
  python:${py_ver}-slim bash -c 'pip3 install --user pip-tools && \
    $HOME/.local/bin/pip-compile requirements.in -o requirements-${date_file}.txt'
rm -r .home_py
docker build \
  --build-arg PY_VERSION="${py_ver}" \
  --build-arg MPICH_VERSION="${mpich_ver}" \
  --build-arg DATE_FILE="${date_file}" \
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
image="${repo%-hdf5mpi}:${date_tag}-hdf5mpi"
echo " .. Now building $image"
mkdir -p .home_py
docker run --rm \
  -u $(id -u):$(id -g) \
  -v $(pwd):$(pwd) -w $(pwd) \
  --env date_file="${date_file}" --env HOME="$(pwd)/.home_py" \
  python:${py_ver}-slim bash -c 'pip3 install --user pip-tools && \
    $HOME/.local/bin/pip-compile requirements.in -o requirements-${date_file}.txt && \
    sed -i "s/^h5py/#h5py/g" requirements-${date_file}.txt'
rm -r .home_py
docker build \
  --build-arg PY_VERSION="${py_ver}" \
  --build-arg MPICH_VERSION="${mpich_ver}" \
  --build-arg HDF5_VERSION="${hdf5_ver}" \
  --build-arg DATE_FILE="${date_file}" \
  -t quay.io/pawsey/$image .
docker push quay.io/pawsey/$image
# Begin - Docker Hub - will go away
docker tag quay.io/pawsey/$image pawsey/$image
docker push pawsey/$image
docker rmi pawsey/$image
# End - Docker Hub
cd ..


# Build and push images "cuda-hpc-python"
repo="cuda-hpc-python_cuda${cuda_ver}"
cd $repo
#
image="${repo%_cuda*}:${date_tag}"
echo " .. Now building $image"
docker build \
  --build-arg PAWSEY_BASE="${date_tag}" \
  -t quay.io/pawsey/$image .
docker push quay.io/pawsey/$image
# Begin - Docker Hub - will go away
docker tag quay.io/pawsey/$image pawsey/$image
docker push pawsey/$image
docker rmi pawsey/$image
# End - Docker Hub
#
image="${repo%_cuda*}:${date_tag}-hdf5mpi"
echo " .. Now building $image"
docker build \
  --build-arg PAWSEY_BASE="${date_tag}-hdf5mpi" \
  -t quay.io/pawsey/$image .
docker push quay.io/pawsey/$image
# Begin - Docker Hub - will go away
docker tag quay.io/pawsey/$image pawsey/$image
docker push pawsey/$image
docker rmi pawsey/$image
# End - Docker Hub
#
cd ..


# Build and push images "intel-hpc-python"
repo="intel-hpc-python"
cd $repo
image="${repo}:${date_tag}"
echo " .. Now building $image"
docker run --rm \
  -v $(pwd):$(pwd) -w $(pwd) \
  --env date_file="${date_file}" --env myuser="$(id -u)" --env mygroup="$(id -g)" \
  intelpython/intelpython3_core:${ipy_ver} bash -c 'conda install \
    --no-update-deps -y --file requirements.in && \
    conda env export -n base >environment-${date_file}.yaml && \
    chown $myuser:$mygroup environment-${date_file}.yaml'
cp environment-${date_file}.yaml requirements-${date_file}.yaml
sed -i -n '/dependencies/,/prefix/p' requirements-${date_file}.yaml
sed -i -e '/dependencies:/d' -e '/prefix:/d' requirements-${date_file}.yaml
sed -i 's/ *- //g' requirements-${date_file}.yaml
mpi4py_ver="$( grep '^mpi4py' ../hpc-python/requirements-${date_file}.txt |cut -d '=' -f 3 )"
h5py_ver="$( grep '^h5py' ../hpc-python/requirements-${date_file}.txt |cut -d '=' -f 3 )"
docker build \
  --build-arg IPY_VERSION="${ipy_ver}" \
  --build-arg MPICH_VERSION="${mpich_ver}" \
  --build-arg DATE_FILE="${date_file}" \
  --build-arg MPI4PY_VERSION="${mpi4py_ver}" \
  --build-arg H5PY_VERSION="${h5py_ver}" \
  -t quay.io/pawsey/$image .
docker push quay.io/pawsey/$image
# Begin - Docker Hub - will go away
docker tag quay.io/pawsey/$image pawsey/$image
docker push pawsey/$image
docker rmi pawsey/$image
# End - Docker Hub
cd ..








echo ""
echo " Gone through all builds and pushes. Done!"
exit

