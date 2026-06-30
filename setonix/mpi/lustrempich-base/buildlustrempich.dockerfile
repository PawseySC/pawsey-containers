# This Dockerfile builds an Ubuntu-based MPICH container image ABI compatible
# with Cray-MPICH to enable MPI computation on HPE Cray EX systems.
# It installs a minimal build/runtime environment,
# compiles MPICH from source with OFI support, adds mpi4py, builds the OSU
# Micro-Benchmarks, and includes additional Pawsey MPI test utilities.
# It also installs Lustre libraries to allow correct MPI/IO.
# The recipe does not start FROM mpich-base:<tag> image because Lustre libraries
# need to be installed before the MPI installation.
# Build-time arguments allow the Ubuntu, MPICH, and benchmark versions to be
# overridden without modifying the recipe.
# (When updating this image, don't forget to double check that labels are also updated accordingly)

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition of global parameters
# IMPORTANT: All these settings can be overridden with the use of `--build-arg <Name>=<Value>`
# IMPORTANT: Recipe needs to re-call them at each stage to recover their values

# 0.1 Main global arguments related to versions used
ARG OS_VERSION="24.04"
ARG BASE_IMAGE_FULL="ubuntu:${OS_VERSION}"
ARG MPICH_VERSION="4.2.2"
ARG MPICH_SHA256="883f5bb3aeabf627cb8492ca02a03b191d09836bbe0f599d8508351179781d41"
ARG MPI4PY_VERSION="4.1.2"
ARG OSU_BENCHMARKS_VERSION="7.3"
#ARG PROFILE_UTIL_VERSION="v1.0"
ARG PROFILE_UTIL_VERSION="main"
ARG GCC_VERSION="12"
ARG LINUX_KERNEL="6.8.0-31"
#ARG LUSTRE_VERSION="2.15.0-RC4"
ARG LUSTRE_VERSION="release"

# 0.2 Other auxiliary variables to ease building
ARG DOCKER_RECIPES_DIR="/opt/docker-recipes"


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# A. Basic Stage.
FROM ${BASE_IMAGE_FULL} AS basic_stage
#---------------------------------------------------------------
# A.0 Recall global definitions made at the top
ARG MPICH_VERSION
ARG OS_VERSION
ARG DOCKER_RECIPES_DIR
ARG GCC_VERSION
ARG LINUX_KERNEL
ARG LUSTRE_VERSION

#---------------------------------------------------------------
# A.1 Defining documented labels
LABEL org.opencontainers.image.authors="Pascal Jahan Elahi <pascal.elahi@pawsey.org.au>, Alexis Espinosa <alexis.espinosa@pawsey.org.au>, Craig Meyer <cmeyer@pawsey.org.au>, Deva Deeptimahanti <deva.deeptimahanti@pawsey.org.au>"
LABEL org.opencontainers.image.name="lustrempich-base"
LABEL org.opencontainers.image.branch="mpich${MPICH_VERSION}-lustre${LUSTRE_VERSION}-ubuntu${OS_VERSION}"
LABEL org.opencontainers.image.dockerfile-internal-backup="${DOCKER_RECIPES_DIR}"
LABEL org.opencontainers.image.git-repository="https://github.com/PawseySC/pawsey-containers"

#---------------------------------------------------------------
# A.2 Installing basic requirements
RUN set -eux; \
    DEBIAN_FRONTEND=noninteractive apt-get update; \
    apt-get -y --no-install-recommends install \
    build-essential \
    gnupg \
    gnupg2 \
    ca-certificates \
    gdb \
    gcc-${GCC_VERSION} \
    g++-${GCC_VERSION} \
    gfortran-${GCC_VERSION} \
    wget \
    git \
    python3-six \
    python3-setuptools \
    patchelf \
    strace \
    ltrace \
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
    cmake \
    openssh-server \
    patch \
    python3-numpy \
    python3-pip \
    python3-scipy \
    python3-venv \
    subversion \
    tzdata \
    valgrind \
    vim \
    xsltproc \
    zlib1g-dev \
    ninja-build \
    libnuma-dev \
    swig \
    linux-tools-generic \
    linux-source \
    software-properties-common \
    libkeyutils-dev \
    libnl-genl-3-dev \
    libyaml-dev \
    linux-headers-${LINUX_KERNEL}-generic \
    linux-headers-${LINUX_KERNEL} \
    libmount-dev \
    pkg-config \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# B. Build Lustre
FROM basic_stage AS build_lustre
#---------------------------------------------------------------
# B.0 Recall global definitions made at the top
ARG LINUX_KERNEL
#ARG LUSTRE_VERSION

#---------------------------------------------------------------
# B.1 Build LUSTRE
ARG LUSTRE_CONFIG_ARGS="--with-linux=/usr/lib/modules/${LINUX_KERNEL}-generic/build --disable-tests CFLAGS=-Wno-error=attribute-warning"

RUN set -eux; \
    mkdir -p /tmp/lustre-build; \
    cd /tmp/lustre-build; \
    git clone https://github.com/lustre/lustre-release.git; \
    cd lustre-release; \
    # there appears to be an odd error with some release not being able to configure.
    # for the moment, just use the main branch rather than a particular version.
    #git fetch --tags; \
    #git checkout "${LUSTRE_VERSION}"; \
    chmod +x ./autogen.sh; \
    ./autogen.sh; \
    ./configure --disable-server --enable-client ${LUSTRE_CONFIG_ARGS}; \
    make -j8; \
    make install; \
    rm -rf /tmp/lustre-build


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# C. Build MPICH
FROM build_lustre AS build_mpich
#---------------------------------------------------------------
# C.0 Recall global definitions made at the top
ARG MPICH_VERSION
ARG MPICH_SHA256

#---------------------------------------------------------------
# C.1 Build MPICH
ARG MPICH_CONFIGURE_OPTIONS="\
    --without-mpe \
    --enable-fortran=all \
    --enable-shared \
    --enable-sharedlibs=gcc \
    --enable-debuginfo \
    --enable-yield=sched_yield \
    --enable-g=mem \
    --with-device=ch4:ofi \
    --with-namepublisher=file \
    --with-shared-memory=sysv \
    --disable-allowport \
    --with-pm=gforker \
    --with-file-system=ufs+lustre+nfs \
    --enable-threads=runtime \
    --enable-fast=O2 \
    --enable-thread-cs=global \
    CC=gcc-12 \
    CXX=g++-12 \
    FC=gfortran-12 \
    FFLAGS=-fallow-argument-mismatch"
ARG MPICH_MAKE_OPTIONS="-j16"

RUN set -eux; \
    mkdir -p /tmp/mpich-build; \
    cd /tmp/mpich-build; \
    wget "https://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz"; \
    echo "${MPICH_SHA256}  mpich-${MPICH_VERSION}.tar.gz" | sha256sum -c -; \
    tar xzvf "mpich-${MPICH_VERSION}.tar.gz"; \
    cd "mpich-${MPICH_VERSION}"; \
    sed -i "/Error use MPL_/d" src/mpl/include/mpl_trmem.h; \
    ./configure ${MPICH_CONFIGURE_OPTIONS}; \
    make ${MPICH_MAKE_OPTIONS}; \
    make install; \
    ldconfig; \
    cp -p "/tmp/mpich-build/mpich-${MPICH_VERSION}/examples/cpi" /usr/bin/; \
    rm -rf /tmp/mpich-build



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# D. Install mpi4py
FROM build_mpich AS install_mpi4py
#---------------------------------------------------------------
# D.0 Recall global definitions made at the top
ARG MPI4PY_VERSION

#---------------------------------------------------------------
# D.1 Add mpi4py in the container
RUN set -eux; \
    MPICC=/usr/bin/mpicc python3 -m pip install \
        --no-cache-dir \
        --no-binary=mpi4py \
        --break-system-packages \
        "mpi4py==${MPI4PY_VERSION}"


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# E. Install OSU benchmarks
FROM install_mpi4py AS build_osu
#---------------------------------------------------------------
# E.0 Recall global definitions made at the top
ARG OSU_BENCHMARKS_VERSION

#---------------------------------------------------------------
# E.1 Build OSU Benchmarks
ARG OSU_CONFIGURE_OPTIONS="--prefix=/usr/local CC=mpicc CXX=mpicxx CFLAGS=-O3"
ARG OSU_MAKE_OPTIONS="-j8"

RUN set -eux; \
    mkdir -p /tmp/osu-benchmark-build; \
    cd /tmp/osu-benchmark-build; \
    wget "https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_BENCHMARKS_VERSION}.tar.gz"; \
    tar xzvf "osu-micro-benchmarks-${OSU_BENCHMARKS_VERSION}.tar.gz"; \
    cd "osu-micro-benchmarks-${OSU_BENCHMARKS_VERSION}"; \
    ./configure ${OSU_CONFIGURE_OPTIONS}; \
    make ${OSU_MAKE_OPTIONS}; \
    make install; \
    rm -rf /tmp/osu-benchmark-build

ENV PATH="/usr/local/libexec/osu-micro-benchmarks/mpi/collective:/usr/local/libexec/osu-micro-benchmarks/mpi/one-sided:/usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt:/usr/local/libexec/osu-micro-benchmarks/mpi/startup:${PATH}"


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# F. Install other tests
FROM build_osu AS other_tests
#---------------------------------------------------------------
# F.0 Recall global definitions made at the top
ARG PROFILE_UTIL_VERSION

#---------------------------------------------------------------
# F.1 Add a more complex set of tests for MPI as well
# Cache invalidation helper to neglect cache use in the RUN..cmake instruction if the repository has changed:
ADD "https://api.github.com/repos/PawseySC/profile_util/commits/${PROFILE_UTIL_VERSION}" /tmp/profile_util_commit.json
# Compilation:
RUN set -eux; \
    mkdir -p /opt/; \
    cd /opt/; \
    git clone --branch "${PROFILE_UTIL_VERSION}" --depth 1 https://github.com/PawseySC/profile_util; \
    cd profile_util; \
    cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_COMPILER=mpic++ \
        -DPU_ENABLE_MPI=ON \
        -DPU_ENABLE_OPENMP=OFF \
        -DPU_ENABLE_CUDA=OFF \
        -DPU_ENABLE_HIP=OFF; \
    cmake --build build --parallel; \
    rm -f /tmp/profile_util_commit.json


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# H. Final settings
FROM other_tests AS final_settings
#---------------------------------------------------------------
# H.0 Recall global definitions made at the top
ARG DOCKER_RECIPES_DIR

#---------------------------------------------------------------
# H.1 Copy the recipe into the docker recipes directory
RUN set -eux; \
    mkdir -p "${DOCKER_RECIPES_DIR}"
COPY buildlustrempich.dockerfile "${DOCKER_RECIPES_DIR}"
