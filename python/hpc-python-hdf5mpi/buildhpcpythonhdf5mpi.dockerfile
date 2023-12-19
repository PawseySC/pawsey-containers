ARG HPCPYTHON_VERSION="3.11"
FROM quay.io/pawsey/hpc-python:${HPCPYTHON_VERSION}

LABEL org.opencontainers.image.created="2023-12"
LABEL org.opencontainers.image.authors="Pascal Jahan Elahi <pascal.elahi@pawsey.org.au>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/python/hpcpython/buildhpcpython.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Setonix compatible python container with parallel h5py"
LABEL org.opencontainers.image.description="Common base image providing python on Setonix built on the lustre aware mpich"
LABEL org.opencontainers.image.base.name="pawsey/hpcpython:3.11-hdf5-mpi"

# add HDF5
ARG HDF5_VERSION="1.14.3"
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


# # Install h5py and h5netcdf
ARG DATE_FILE="12-2023"
RUN echo "Install h5py " \
    && H5PY_VERSION=$(grep 'h5py' /requirements-${DATE_FILE}.txt | sed 's/==/ /g' | sed 's/ # / /'g | awk '{print $2}') \
    && H5NETCDF_VERSION=$(grep 'h5netcdf' /requirements-${DATE_FILE}.txt | sed 's/==/ /g' | sed 's/ # / /'g | awk '{print $2}') \
    && CC="mpicc" CXX="mpic++" HDF5_MPI="ON" HDF5_DIR="/usr/local" pip3 --no-cache-dir install --no-deps --no-binary=h5py h5py==${H5PY_VERSION} h5netcdf==${H5NETCDF_VERSION}

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildhpcpythonhdf5mpi.dockerfile /opt/docker-recipes/

# Final
CMD ["/bin/bash"]
