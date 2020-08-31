ARG IPY_VERSION=2020.2
FROM intelpython/intelpython3_core:${IPY_VERSION}
# Note: these python images are based on Debian (as of 27 August 2020, Debian 10 Buster)

LABEL maintainer="marco.delapierre@pawsey.org.au"

# Just one extra conda variable
ENV CONDA_PREFIX="/opt/conda"


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


# Install Python packages - conda

ARG REQ_LABEL="30Aug2020"
ARG REQ_FILE="requirements-${REQ_LABEL}.yaml"

ADD ${REQ_FILE} /requirements.yaml
RUN conda install --no-update-deps -y --file /requirements.yaml \
      && conda clean -ay

# this is just to fix an intelpython missing dep, hopefully won't be needed in future
RUN conda install --no-deps -y threadpoolctl \
      && conda clean -ay


# Precedence to MPICH

ENV LD_LIBRARY_PATH=/usr/lib \
       LIBRARY_PATH=/usr/lib


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


# Install Python packages - h5py and mpi4py with pip

ARG H5PY_VERSION="2.10.0"
ARG MPI4PY_VERSION="3.0.3"

RUN pip --no-cache-dir install --no-deps mpi4py==${MPI4PY_VERSION} \
      && CC="mpicc" HDF5_MPI="ON" HDF5_DIR="/usr/local" pip --no-cache-dir install --no-deps --no-binary=h5py h5py==${H5PY_VERSION}


# Final
CMD ["/bin/bash"]
