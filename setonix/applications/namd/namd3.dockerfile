# Build args
ARG NAMD_VERSION="3.0.3"
ARG MPICH_VERSION="4.2.2"
ARG OS_VERSION="24.04"

# Additional files - building onto existing directory in rocm-mpich-base image
ARG IMAGE_TITLE="namd"
ARG IMAGE_BUILD_INFO_DIR="/opt/build-info-and-recipes"
ARG INTERNAL_BUILD_INFO_SUBDIR="${IMAGE_BUILD_INFO_DIR}/${IMAGE_TITLE}"

# Image labels
LABEL org.opencontainers.image.authors="Craig Meyer <cmeyer@pawsey.org.au>"
LABEL org.opencontainers.image.title="${IMAGE_TITLE}"
LABEL org.opencontainers.image.version="namd${NAMD_VERSION}-mpich${MPICH_VERSION}-ubuntu${OS_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers"
LABEL au.org.pawsey.image.build-info-dir="${IMAGE_BUILD_INFO_DIR}"


# Build from mpich-base image
FROM quay.io/pawsey/mpich-base:mpich${MPICH_VERSION}-ubuntu${OS_VERSION}

SHELL [ "/bin/bash", "-c" ]

# Prefix for tarball containing source
# Cannot provide source directly due to namd license, so this recipe requires whoever is running it to already have access to the source tarball
ARG NAMD_SOURCE="NAMD_${NAMD_VERSION}_Source"

ADD ${NAMD_SOURCE}.tar.gz /tmp/namd-build

WORKDIR /tmp/namd-build/${NAMD_SOURCE}

# Build linux-x86_64 MPI-SMP Charm++/Converse library
RUN tar xf charm-8.0.0.tar \
    && cd charm-8.0.0 \
    && env MPICXX=mpicxx ./build charm++ mpi-linux-x86_64 smp --with-production

# Install TCL and FFTW libraries
# Install fftw from source (need --with-pic option and --enable-float options not present in pre-compiled library
RUN wget http://www.fftw.org/fftw-3.3.10.tar.gz \
    && tar xzf fftw-3.3.10.tar.gz \
    && cd fftw-3.3.10 \
    && ./configure --enable-shared --enable-threads --with-pic --enable-float --prefix=/tmp/namd-build/${NAMD_SOURCE}/fftw \
    && make -j4 \
    && make install
# Obtain pre-built TCL libraries
RUN wget http://www.ks.uiuc.edu/Research/namd/libraries/tcl8.6.13-linux-x86_64.tar.gz\
    && wget http://www.ks.uiuc.edu/Research/namd/libraries/tcl8.6.13-linux-x86_64-threaded.tar.gz \
    && tar xzf tcl8.6.13-linux-x86_64.tar.gz \
    && tar xzf tcl8.6.13-linux-x86_64-threaded.tar.gz \
    && mv tcl8.6.13-linux-x86_64 tcl \
    && mv tcl8.6.13-linux-x86_64-threaded tcl-threaded

# Set up build directory and build namd
RUN ./config Linux-x86_64-g++ --charm-arch mpi-linux-x86_64-smp \
    && cd Linux-x86_64-g++ \
    && gmake -j4

RUN mkdir -p /opt/namd \
    && mv ./Linux-x86_64-g++ /opt/namd/bin \
    && mv ./license.txt /opt/namd/ \
    && rm -fr /tmp/namd-build

    
WORKDIR /opt/namd

ENV PATH=/opt/namd/bin:$PATH

# Add dockerfile to container
RUN mkdir -p "${INTERNAL_BUILD_INFO_SUBDIR}"
COPY namd3.dockerfile "${INTERNAL_BUILD_INFO_SUBDIR}"