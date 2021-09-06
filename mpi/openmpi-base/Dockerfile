ARG OS_VERSION="18.04"
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

ARG OPENMPI_VERSION="4.0.2"
ARG OPENMPI_CONFIGURE_OPTIONS="--enable-fast=all,O3 --prefix=/usr"
ARG OPENMPI_MAKE_OPTIONS="-j4"

RUN mkdir -p /tmp/openmpi-build \
      && cd /tmp/openmpi-build \
      && OPENMPI_VER_MM="${OPENMPI_VERSION%.*}" \
      && wget http://www.openmpi.org/software/ompi/v${OPENMPI_VER_MM}/downloads/openmpi-${OPENMPI_VERSION}.tar.bz2 \
      && tar xjf openmpi-${OPENMPI_VERSION}.tar.bz2 \
      && cd openmpi-${OPENMPI_VERSION}  \
      && ./configure ${OPENMPI_CONFIGURE_OPTIONS} \
      && make ${OPENMPI_MAKE_OPTIONS} \
      && make install \
      && ldconfig \
      && cd / \
      && rm -rf /tmp/openmpi-build


# Build OSU Benchmarks

ARG OSU_BENCH_VERSION="5.4.2"
ARG OSU_BENCH_CONFIGURE_OPTIONS="--prefix=/usr/local CC=mpicc CXX=mpicxx CFLAGS=-O3"
ARG OSU_BENCH_MAKE_OPTIONS="-j4"

RUN mkdir -p /tmp/osu-benchmark-build \
      && cd /tmp/osu-benchmark-build \
      && wget http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_BENCH_VERSION}.tar.gz \
      && tar xzvf osu-micro-benchmarks-${OSU_BENCH_VERSION}.tar.gz \
      && cd osu-micro-benchmarks-${OSU_BENCH_VERSION} \
      && ./configure ${OSU_BENCH_CONFIGURE_OPTIONS} \
      && make ${OSU_BENCH_MAKE_OPTIONS} \
      && make install \
      && cd / \
      && rm -rf /tmp/osu-benchmark-build






# Final settings
WORKDIR /
CMD ["/bin/bash"]
