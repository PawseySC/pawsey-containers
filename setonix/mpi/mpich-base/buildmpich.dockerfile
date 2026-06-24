# This Dockerfile builds an Ubuntu-based MPICH container image ABI compatible
# with Cray-MPICH to enable MPI computation on HPE Cray EX systems.
# It installs a minimal build/runtime environment,
# compiles MPICH from source with OFI support, adds mpi4py, builds the OSU
# Micro-Benchmarks, and includes additional Pawsey MPI/OpenMP test utilities.
# Build-time arguments allow the Ubuntu, MPICH, and benchmark versions to be
# overridden without modifying the recipe.
# (When updating this image, don't forget to double check that labels are also updated accordingly)

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition of global parameters
# IMPORTANT: All these settings can be overriden with the use of `--build-arg <Name>=<Value>`
# IMPORTANT: Recipe needs to re-call them at each stage to recover their values
# 0.1 Main global arguments (related to version used)
ARG OS_VERSION="24.04"
ARG MPICH_VERSION="4.2.2"
ARG BASE_IMAGE_FULL="ubuntu:${OS_VERSION}"
ARG OSU_BENCHMARKS_VERSION="7.3"

# 0.2 Other auxiliary variables to ease building
ARG DOCKER_RECIPES_DIR="/opt/docker-recipes"


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# A. Basic Stage.
FROM $BASE_IMAGE_FULL AS basic_stage
#---------------------------------------------------------------
# A.0 Recall global definitions made at the top
ARG MPICH_VERSION
ARG OS_VERSION
ARG DOCKER_RECIPES_DIR

#---------------------------------------------------------------
# A.1 Defining documented labels
# Labels:
LABEL org.opencontainers.image.authors="Pascal Jahan Elahi <pascal.elahi@pawsey.org.au>, Alexis Espinosa <alexis.espinosa@pawsey.org.au>, Craig Meyer <cmeyer@pawsey.org.au, Deva Deeptimahanti <deva.deeptimahanti@pawsey.org.au>"
LABEL org.opencontainers.image.name="mpich-base"
LABEL org.opencontainers.image.branch="${MPICH_VERSION}-ubuntu${OS_VERSION}"
LABEL org.opencontainers.image.dockerfile-internal-backup="${DOCKER_RECIPES_DIR}"
LABEL org.opencontainers.image.git-repository="https://github.com/PawseySC/pawsey-containers"

#---------------------------------------------------------------
# A.2 Installing basic requirements
RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq \
    && apt-get -y --no-install-recommends install \
        build-essential \
        ca-certificates \
        gdb \
        gcc g++ gfortran \
        wget \
        git \
        python3-six python3-setuptools \
        patchelf strace ltrace \
        libcrypt-dev \
        libcurl4-openssl-dev \
        libpython3-dev \
        libreadline-dev \
        libssl-dev \
        sudo \
        autoconf \
        automake \
        bison \
        curl \
        flex \
        gcovr \
        libtool \
        m4 \
        make \
        openssh-server \
        patch \
        python3-numpy \
        python3-pip \
        python3-scipy \
        subversion \
        tzdata \
        valgrind \
        vim \
        xsltproc \
        zlib1g-dev \
    && apt-get clean all \
    && rm -r /var/lib/apt/lists/* \
    && echo "Finished apt-get installs"


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# B. Build MPICH
FROM basic_stage AS build_mpich
#---------------------------------------------------------------
# B.0 Recall global definitions made at the top
ARG MPICH_VERSION

#---------------------------------------------------------------
# B.1 Build MPICH
ARG MPICH_CONFIGURE_OPTIONS="--enable-fast=O2 --enable-fortran --enable-romio --prefix=/usr --with-device=ch4:ofi CC=gcc CXX=g++ FC=gfortran FFLAGS=-fallow-argument-mismatch FCFLAGS=-fallow-argument-mismatch"
ARG MPICH_MAKE_OPTIONS="-j16"
RUN mkdir -p /tmp/mpich-build \
      && cd /tmp/mpich-build \
      && wget http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz \
      && tar xvzf mpich-${MPICH_VERSION}.tar.gz \
      && cd mpich-${MPICH_VERSION}  \
      && ./configure ${MPICH_CONFIGURE_OPTIONS} \
      && make ${MPICH_MAKE_OPTIONS} && make install \
      && ldconfig \
      && cp -p /tmp/mpich-build/mpich-${MPICH_VERSION}/examples/cpi /usr/bin/ \
      && cd / \
      && rm -rf /tmp/mpich-build


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# C. Install other tests
FROM build_mpich AS install_mpi4py
#---------------------------------------------------------------
# C.0 Recall global definitions made at the top

#---------------------------------------------------------------
# C.1 Add mpi4py in the container 
# CMEYER: --breaks-system-packages needed with python/3.12 + ubuntu24.04
RUN MPICC=/usr/bin/mpicc pip install --no-binary=mpi4py --break-system-packages mpi4py


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# D. Install OSU benchmarks
FROM install_mpi4py AS build_osu
#---------------------------------------------------------------
# D.0 Recall global definitions made at the top
ARG MPICH_VERSION
ARG OSU_BENCHMARKS_VERSION

#---------------------------------------------------------------
# D.1 Build OSU Benchmarks
ARG OSU_CONFIGURE_OPTIONS="--prefix=/usr/local CC=mpicc CXX=mpicxx CFLAGS=-O3"
ARG OSU_MAKE_OPTIONS="-j8"
RUN mkdir -p /tmp/osu-benchmark-build \
      && cd /tmp/osu-benchmark-build \
      && wget https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_BENCHMARKS_VERSION}.tar.gz \
      && tar xzvf osu-micro-benchmarks-${OSU_BENCHMARKS_VERSION}.tar.gz \
      && cd osu-micro-benchmarks-${OSU_BENCHMARKS_VERSION} \
      && ./configure ${OSU_CONFIGURE_OPTIONS} \
      && make ${OSU_MAKE_OPTIONS} \
      && make install \
      && cd / \
      && rm -rf /tmp/osu-benchmark-build
ENV PATH="/usr/local/libexec/osu-micro-benchmarks/mpi/collective:/usr/local/libexec/osu-micro-benchmarks/mpi/one-sided:/usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt:/usr/local/libexec/osu-micro-benchmarks/mpi/startup:$PATH"


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# E. Install other tests
FROM build_osu AS other_tests
#---------------------------------------------------------------
# E.0 Recall global definitions made at the top

#---------------------------------------------------------------
# E.1 Add a more complex set of tests for MPI as well
RUN mkdir -p /opt/ \
      && cd /opt/ \
      && git clone https://github.com/PawseySC/profile_util \
      && cd profile_util  \
      && sed -i "s:CXX=CC:CXX=g++:g" ./build_cpu.sh \
      && sed -i "s:MPICXX=CC:MPICXX=mpic++:g" ./build_cpu.sh \
      && ./build_cpu.sh \
      && cd examples/mpi/ \
      && make MPICXX=mpic++ \
      && cd ../../examples/openmp \
      && make CXX=g++ bin/openmpvec_cpp


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# H. Final settings
FROM other_tests AS final_settings
#---------------------------------------------------------------
# H.0 Recall global definitions made at the top
ARG DOCKER_RECIPES_DIR

#---------------------------------------------------------------
# E.1 Copy the recipe into the docker recipes directory
RUN mkdir -p $DOCKER_RECIPES_DIR
COPY buildmpich.dockerfile $DOCKER_RECIPES_DIR
