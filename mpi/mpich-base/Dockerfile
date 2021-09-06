ARG OS_VERSION="18.04"
FROM ubuntu:${OS_VERSION}


LABEL maintainer="alexis.espinosa@pawsey.org.au"


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


# Build MPICH

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


# Quick Test
RUN mpiexec -n 8 /usr/bin/cpi 2>&1 | tee log.cpi


# Final settings
WORKDIR /
CMD ["/bin/bash"]
