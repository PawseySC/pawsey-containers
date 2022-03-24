ARG OS_VERSION="20.04"
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

ARG MPI_VERSION="3.4.3"
#ARG MPI_CONFIGURE_OPTIONS="--enable-fast=all,O3 --prefix=/usr" works with 3.1.4, and 4.0.x
ARG MPI_CONFIGURE_OPTIONS="--enable-fast=all,O3 --prefix=/usr --with-device=ch4:ofi"
ARG MPI_MAKE_OPTIONS="-j4"

RUN mkdir -p /tmp/mpich-build \
      && cd /tmp/mpich-build \
      && wget http://www.mpich.org/static/downloads/${MPI_VERSION}/mpich-${MPI_VERSION}.tar.gz \
      && tar xvzf mpich-${MPI_VERSION}.tar.gz \
      && cd mpich-${MPI_VERSION}  \
      && ./configure ${MPI_CONFIGURE_OPTIONS} \
      && make ${MPI_MAKE_OPTIONS} \
      && make install \
      && ldconfig \
      && cp -p /tmp/mpich-build/mpich-${MPI_VERSION}/examples/cpi /usr/bin/ \
      && cd / \
      && rm -rf /tmp/mpich-build


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


# Quick Test
RUN mpiexec -n 8 /usr/bin/cpi 2>&1 | tee log.cpi


# Final settings
WORKDIR /
CMD ["/bin/bash"]
