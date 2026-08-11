# This Dockerfile builds an Ubuntu-based Open MPI container image for
# restricted single-node MPI jobs on HPE Cray EX systems.
# Open MPI is not supported for multi-node execution in this environment,
# including the corresponding bare-metal installation.
# It installs a minimal build/runtime environment, compiles Open MPI from
# source, and builds the OSU Micro-Benchmarks.
# Build-time arguments allow the Ubuntu, Open MPI, and benchmark versions to
# be overridden without modifying the recipe.
# (When updating this image, don't forget to double check that labels are also
# updated accordingly.)

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition of global parameters
# IMPORTANT: All these settings can be overridden with the use of `--build-arg <Name>=<Value>`
# IMPORTANT: Recipe needs to re-call them at each stage to recover their values

# 0.1 Main global arguments related to versions used
ARG OS_VERSION="20.04"
ARG BASE_IMAGE_FULL="ubuntu:${OS_VERSION}"
ARG OPENMPI_VERSION="5.0.5"
ARG OPENMPI_SHA256="5cbefa0780b84f4126743c40cdd6a334b2f0574cd7fd95050fb1ac0ddbb7f0b8"
ARG OSU_BENCHMARKS_VERSION="7.3"

# 0.2 Other auxiliary variables to ease building
ARG DOCKER_RECIPES_DIR="/opt/docker-recipes"


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# A. Basic Stage
FROM ${BASE_IMAGE_FULL} AS basic_stage
#---------------------------------------------------------------
# A.0 Recall global definitions made at the top
ARG OPENMPI_VERSION
ARG OS_VERSION
ARG DOCKER_RECIPES_DIR

#---------------------------------------------------------------
# A.1 Defining documented labels
LABEL org.opencontainers.image.authors="Alexis Espinosa <alexis.espinosa@pawsey.org.au>"
LABEL org.opencontainers.image.name="openmpi-base"
LABEL org.opencontainers.image.branch="openmpi${OPENMPI_VERSION}-ubuntu${OS_VERSION}"
LABEL org.opencontainers.image.dockerfile-internal-backup="${DOCKER_RECIPES_DIR}/buildopenmpi.dockerfile"
LABEL org.opencontainers.image.git-repository="https://github.com/PawseySC/pawsey-containers"

#---------------------------------------------------------------
# A.2 Installing basic requirements
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get -y --no-install-recommends install \
        build-essential \
        ca-certificates \
        gdb \
        gcc \
        g++ \
        gfortran \
        patchelf \
        strace \
        ltrace \
        git \
        curl \
        wget \
        cmake \
        python3 \
        valgrind \
        vim \
        zlib1g-dev \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
## B. Build Open MPI
FROM basic_stage AS build_openmpi
#---------------------------------------------------------------
# B.0 Recall global definitions made at the top
ARG OPENMPI_VERSION
ARG OPENMPI_SHA256

#---------------------------------------------------------------
# B.1 Build Open MPI
ARG OPENMPI_CONFIGURE_OPTIONS="--enable-fast=all,O3 --prefix=/usr"
ARG OPENMPI_MAKE_OPTIONS="-j16"

RUN set -eux; \
    mkdir -p /tmp/openmpi-build; \
    cd /tmp/openmpi-build; \
    OPENMPI_VERSION_MAJOR_MINOR="${OPENMPI_VERSION%.*}"; \
    wget "https://download.open-mpi.org/release/open-mpi/v${OPENMPI_VERSION_MAJOR_MINOR}/openmpi-${OPENMPI_VERSION}.tar.gz"; \
    echo "${OPENMPI_SHA256} openmpi-${OPENMPI_VERSION}.tar.gz" | sha256sum -c -; \
    tar xzvf "openmpi-${OPENMPI_VERSION}.tar.gz"; \
    cd "openmpi-${OPENMPI_VERSION}"; \
    ./configure ${OPENMPI_CONFIGURE_OPTIONS}; \
    make ${OPENMPI_MAKE_OPTIONS}; \
    make install; \
    ldconfig; \
    rm -rf /tmp/openmpi-build


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# C. Install OSU Benchmarks
FROM build_openmpi AS build_osu
#---------------------------------------------------------------
# C.0 Recall global definitions made at the top
ARG OSU_BENCHMARKS_VERSION

#---------------------------------------------------------------
# C.1 Build OSU Benchmarks
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
# D. Final settings
FROM build_osu AS final_settings
#---------------------------------------------------------------
# D.0 Recall global definitions made at the top
ARG DOCKER_RECIPES_DIR

#---------------------------------------------------------------
# D.1 Copy the recipe into the Docker recipes directory
RUN set -eux; \
    mkdir -p "${DOCKER_RECIPES_DIR}"
COPY buildopenmpi.dockerfile "${DOCKER_RECIPES_DIR}/buildopenmpi.dockerfile"
