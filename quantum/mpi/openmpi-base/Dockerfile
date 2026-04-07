ARG OS_VERSION="20.04"
FROM ubuntu:${OS_VERSION}


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


# Build OPENMPI

ARG MPI_VERSION="4.0.2"
ARG MPI_CONFIGURE_OPTIONS="--enable-fast=all,O3 --prefix=/usr"
ARG MPI_MAKE_OPTIONS="-j4"

RUN mkdir -p /tmp/openmpi-build \
      && cd /tmp/openmpi-build \
      && MPI_VER_MM="${MPI_VERSION%.*}" \
      && wget http://www.openmpi.org/software/ompi/v${MPI_VER_MM}/downloads/openmpi-${MPI_VERSION}.tar.bz2 \
      && tar xjf openmpi-${MPI_VERSION}.tar.bz2 \
      && cd openmpi-${MPI_VERSION}  \
      && ./configure ${MPI_CONFIGURE_OPTIONS} \
      && make ${MPI_MAKE_OPTIONS} \
      && make install \
      && ldconfig \
      && cd / \
      && rm -rf /tmp/openmpi-build


# Build OSU Benchmarks

ARG OSU_VERSION="5.4.2"
ARG OSU_CONFIGURE_OPTIONS="--prefix=/usr/local CC=mpicc CXX=mpicxx CFLAGS=-O3"
ARG OSU_MAKE_OPTIONS="-j4"

RUN mkdir -p /tmp/osu-benchmark-build \
      && cd /tmp/osu-benchmark-build \
      && wget http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz \
      && tar xzvf osu-micro-benchmarks-${OSU_VERSION}.tar.gz \
      && cd osu-micro-benchmarks-${OSU_VERSION} \
      && ./configure ${OSU_CONFIGURE_OPTIONS} \
      && make ${OSU_MAKE_OPTIONS} \
      && make install \
      && cd / \
      && rm -rf /tmp/osu-benchmark-build
ENV PATH="/usr/local/libexec/osu-micro-benchmarks/mpi/collective:/usr/local/libexec/osu-micro-benchmarks/mpi/one-sided:/usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt:/usr/local/libexec/osu-micro-benchmarks/mpi/startup:$PATH"


# Some uesful Linux utilities
RUN apt-get update -qq \
      && apt-get -y --no-install-recommends install patchelf strace ltrace \
      && apt-get clean all \
      && rm -r /var/lib/apt/lists/*


# Final settings
WORKDIR /
CMD ["/bin/bash"]
