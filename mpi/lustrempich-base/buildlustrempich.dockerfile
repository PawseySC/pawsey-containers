# This recipe uses ubuntu as a base and 
# adds minimal packages with apt-get
# builds lustre-aware mpich and also some useful mpi packages for testing
# The labels present here will need to be updated

ARG OS_VERSION="20.04"
FROM ubuntu:${OS_VERSION}
# redefine after FROM to ensure it is defined
ARG OS_VERSION="20.04"
# mpich version
ARG MPICH_VERSION="3.4.3"
# lustre version
ARG LUSTRE_VERSION="2.15.0-RC4"
# mpi4py version
ARG MPI4PY_VERSION="3.1.4"

#define some metadata 
LABEL org.opencontainers.image.created="2023-02"
LABEL org.opencontainers.image.authors="Pascal Jahan Elahi <pascal.elahi@pawsey.org.au>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/mpi/mpich-base/buildlustrempich.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Setonix compatible Lustre-aware MPICH base"
LABEL org.opencontainers.image.description="Common base image providing lustre-aware mpi compatible with cray-mpich and lustre used on Setonix"
LABEL org.opencontainers.image.base.name="pawsey/mpibase:ubuntu${OS_VERSION}-mpich-${MPICH_VERSION}.lustre.setonix"

# syntax=docker/dockerfile:1 
# run apt-get install on a few packages
ENV DEBIAN_FRONTEND="noninteractive"
RUN apt-get update -qq \
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
        gdb \
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
        wget \
        xsltproc \
        zlib1g-dev \
        libkeyutils-dev libnl-genl-3-dev libyaml-dev linux-headers-$(uname -r) \
        libmount-dev pkg-config \
    && apt-get clean all \
    && rm -r /var/lib/apt/lists/* \
    && echo "Finished apt-get installs"
    
# Build lustre
RUN echo "Building lustre" \
    && mkdir -p /tmp/lustre-build \
    && cd /tmp/lustre-build \
    && git clone git://git.whamcloud.com/fs/lustre-release.git \
    && cd lustre-release \
    # there appears to be an odd error with some release not being able to configure. 
    # for the moment, just use the main branch rather than a particular version.
    # && git fetch --tags && git checkout ${LUSTRE_VERSION} \
    && chmod +x ./autogen.sh && ./autogen.sh \
    && ./configure --disable-server --enable-client \
    && make -j8 && make install \
    && cd / \
    && rm -rf /tmp/lustre-build \
    && echo "Finished installing lustre"

# Build MPICH
ARG MPICH_CONFIGURE_OPTIONS="--without-mpe --enable-fortran=all --enable-shared --enable-sharedlibs=gcc --enable-debuginfo --enable-yield=sched_yield \
--enable-g=mem --with-device=ch4:ofi --with-namepublisher=file \
--with-shared-memory=sysv \
--disable-allowport \
--with-pm=gforker \
--with-file-system=ufs+lustre+nfs \
--enable-threads=runtime \
--enable-fast=O2 \
--enable-thread-cs=global \
"
ARG MPICH_MAKE_OPTIONS="-j8"
COPY mpich_patches.tgz /tmp/
RUN echo "Building MPICH ... " \
    && mkdir -p /tmp/mpich-build \
    && cd /tmp/mpich-build \
    && wget http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz \
    && tar xf mpich-${MPICH_VERSION}.tar.gz \
    && cd mpich-${MPICH_VERSION}  \
    # apply patches 
    && tar xf /tmp/mpich_patches.tgz \
    && patch -p0 < csel.patch \
    && patch -p0 < ch4r_init.patch \
    && ./configure ${MPICH_CONFIGURE_OPTIONS} \
    && make ${MPICH_MAKE_OPTIONS} && make install \
    && ldconfig \
    && cp -p /tmp/mpich-build/mpich-${MPICH_VERSION}/examples/cpi /usr/bin/ \
    && cd / \
    && rm -rf /tmp/mpich-build \
    && echo "Finished building MPICH" 

# Build OSU Benchmarks
ARG OSU_VERSION="6.2"
ARG OSU_CONFIGURE_OPTIONS="--prefix=/usr/local CC=mpicc CXX=mpicxx CFLAGS=-O3"
ARG OSU_MAKE_OPTIONS="-j8"
RUN mkdir -p /tmp/osu-benchmark-build \
    && cd /tmp/osu-benchmark-build \
    && wget https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz \
    && tar xzvf osu-micro-benchmarks-${OSU_VERSION}.tar.gz \
    && cd osu-micro-benchmarks-${OSU_VERSION} \
    && ./configure ${OSU_CONFIGURE_OPTIONS} \
    && make ${OSU_MAKE_OPTIONS} \
    && make install \
    && cd / \
    && rm -rf /tmp/osu-benchmark-build
ENV PATH="/usr/local/libexec/osu-micro-benchmarks/mpi/collective:/usr/local/libexec/osu-micro-benchmarks/mpi/one-sided:/usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt:/usr/local/libexec/osu-micro-benchmarks/mpi/startup:$PATH"

# Add a more complex set of tests for MPI as well 
RUN mkdir -p /opt/ \
      && cd /opt/ \
      && git clone https://github.com/pelahi/profile_util \
      && cd profile_util  \
      && sed -i "s:CXX=CC:CXX=g++:g" ./build_cpu.sh \
      && sed -i "s:MPICXX=CC:MPICXX=mpic++:g" ./build_cpu.sh \
      && ./build_cpu.sh \
      && cd examples/mpi/ \
      && make MPICXX=mpic++ \
      && cd ../../examples/openmp \
      && make CXX=g++ bin/openmpvec_cpp

# add mpi4py in the container 
RUN pip install mpi4py==${MPI4PY_VERSION}

RUN mkdir -p /container-scratch/

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildlustrempich.dockerfile /opt/docker-recipes/
