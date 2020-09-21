ARG PY_VERSION=3.8
FROM python:${PY_VERSION}-slim
# Note: these python images are based on Debian (as of 27 August 2020, Debian 10 Buster)

LABEL maintainer="marco.delapierre@pawsey.org.au"


# Install package dependencies
RUN apt-get update -qq \
      && apt-get -y --no-install-recommends install \
         build-essential \
         ca-certificates \
         gdb \
         gfortran \
         wget \
      && apt-get clean all \
      && rm -r /var/lib/apt/lists/*


# Build MPICH for mpi4py

ARG MPICH_VERSION="3.1.4"
ARG MPICH_CONFIGURE_OPTIONS="--enable-fast=all,O3 --prefix=/usr"
ARG MPICH_MAKE_OPTIONS="-j4"

RUN mkdir -p /tmp/mpich-build \
      && cd /tmp/mpich-build \
      && wget http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz \
      && tar xvzf mpich-${MPICH_VERSION}.tar.gz \
      && cd mpich-${MPICH_VERSION}  \
      && ./configure ${MPICH_CONFIGURE_OPTIONS} \
      && make ${MPICH_MAKE_OPTIONS} \
      && make install \
      && ldconfig \
      && cp -p /tmp/mpich-build/mpich-${MPICH_VERSION}/examples/cpi /usr/bin/ \
      && cd / \
      && rm -rf /tmp/mpich-build


# Install Python packages (apart from h5py)

ARG REQ_LABEL="27Aug2020"
ARG REQ_FILE="requirements-${REQ_LABEL}.txt"

ADD requirements.in /
ADD ${REQ_FILE} /requirements.txt
RUN pip3 --no-cache-dir install -r /requirements.txt --no-deps


# Install HDF5-parallel

ARG HDF5_VERSION="1.10.4"
ARG HDF5_CONFIGURE_OPTIONS="--prefix=/usr/local --enable-parallel CC=mpicc"
ARG HDF5_MAKE_OPTIONS="-j4"

RUN mkdir -p /tmp/hdf5-build \
      && cd /tmp/hdf5-build \
      && HDF5_VER_MM="${HDF5_VERSION%.*}" \
      && wget https://support.hdfgroup.org/ftp/HDF5/releases/hdf5-${HDF5_VER_MM}/hdf5-${HDF5_VERSION}/src/hdf5-${HDF5_VERSION}.tar.gz \
      && tar xzf hdf5-${HDF5_VERSION}.tar.gz \
      && cd hdf5-${HDF5_VERSION} \
      && ./configure ${HDF5_CONFIGURE_OPTIONS} \
      && make ${HDF5_MAKE_OPTIONS} \
      && make install \
      && ldconfig \
      && cd / \
      && rm -rf /tmp/hdf5-build


# Install h5py

RUN H5PY_VERSION=$( grep '#h5py' /requirements.txt ) && H5PY_VERSION=${H5PY_VERSION#*==} && H5PY_VERSION=${H5PY_VERSION%% *} \
      && CC="mpicc" HDF5_MPI="ON" HDF5_DIR="/usr/local" pip3 --no-cache-dir install --no-deps --no-binary=h5py h5py==${H5PY_VERSION}


# Final
CMD ["/bin/bash"]
