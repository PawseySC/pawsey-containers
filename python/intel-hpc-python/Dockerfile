ARG IPY_VERSION="2020.2"
FROM intelpython/intelpython3_core:${IPY_VERSION}

LABEL maintainer="marco.delapierre@pawsey.org.au"


# Just one extra conda variable
ENV CONDA_PREFIX="/opt/conda"


# Install package dependencies
RUN apt-get update -qq --allow-releaseinfo-change \
      && apt-get -y --no-install-recommends install \
         build-essential \
         ca-certificates \
         gdb \
         gfortran \
         wget \
      && apt-get clean all \
      && rm -r /var/lib/apt/lists/*


# Build MPICH for mpi4py

ARG MPICH_VERSION="3.4.3"
#ARG MPICH_CONFIGURE_OPTIONS="--enable-fast=all,O3 --prefix=/usr"
ARG MPICH_CONFIGURE_OPTIONS="--enable-fast=all,O3 --prefix=/usr --with-device=ch4:ofi"
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

ARG DATE_FILE="24Mar2022"

ADD requirements.in requirements-${DATE_FILE}.yaml /
RUN conda install --no-deps -y --file /requirements-${DATE_FILE}.yaml \
      && conda clean -ay


# This is to accelerate scikit-learn with daal4py
ENV USE_DAAL4PY_SKLEARN="YES"


# Precedence to MPICH
ENV LD_LIBRARY_PATH="/usr/lib" \
       LIBRARY_PATH="/usr/lib"


# Install Python packages - h5netcdf, h5py and mpi4py with pip, and eventually their dependencies

ARG DEPENDENCIES="cached_property"
ARG H5NETCDF_VERSION="0.15.0"
ARG H5PY_VERSION="3.6.0"
ARG MPI4PY_VERSION="3.1.3"

RUN pip --no-cache-dir install --no-deps ${DEPENDENCIES} h5netcdf==${H5NETCDF_VERSION} h5py==${H5PY_VERSION} mpi4py==${MPI4PY_VERSION}



# Final
CMD ["/bin/bash"]
