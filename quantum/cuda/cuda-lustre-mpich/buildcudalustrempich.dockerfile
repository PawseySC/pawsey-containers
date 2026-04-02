# This recipe supports multi-stage builds
# This recepe includes CUDA 12.5.0 / lustre-aware MPICH 3.4.3 / Lustre 2.15.63 / OSU 6.2

ARG OS_VERSION="22.04"
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 as builder
# redefine after FROM to ensure it is defined
ARG OS_VERSION="22.04"
# mpich version
ARG MPICH_VERSION="3.4.3"
# lustre version
ARG LUSTRE_VERSION="2.15.63"
# mpi4py version
ARG MPI4PY_VERSION="3.1.4"
# OSU version
ARG OSU_VERSION="6.2"

ARG DATE_TAG="2024-06"

#define some metadata 
LABEL org.opencontainers.image.created="2024-06"
LABEL org.opencontainers.image.authors="Shusen Liu <shusen.liu@pawsey.org.au>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/cuda/cuda-lustre-mpich/buildlustrempich.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Setonix compatible Lustre-aware MPICH with CUDA 12.5"
LABEL org.opencontainers.image.description="Common base image providing lustre-aware mpi compatible with cray-mpich, lustre and CUDA used on Setonix"
LABEL org.opencontainers.image.base.name="pawsey/cuda-lustre-mpich:${DATE_TAG}.cuda.setonix"

# syntax=docker/dockerfile:1 

#COPY ./kernel-docker/kernel-headers.tar /tmp/kernel-docker/  
# Install kernel headers
# RUN echo "Installing kernel headers" \
#     && cd /tmp/kernel-docker \
#     && tar xf kernel-headers.tar\
#     && tar xf kernel-dev.tar \
#     && cp -r usr/include/* /usr/include/ \
#     && cp -r usr/src/* /usr/src/ \
#     && rm -rf /tmp/kernel-docker \
#     && cd / \
#     && echo "Finished installing kernel"



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

#Copy lustre, mpich and OSU to image
ADD downloaded_files.tar.gz /tmp/

# Build lustre
RUN echo "Building lustre" \
    && cd /tmp/lustre-build/lustre-release \
    && chmod +x ./autogen.sh && ./autogen.sh \
    && ./configure --disable-server --enable-client \
    && make -j8 \
    && cd /tmp/lustre-build/lustre-release \
    && make install \
    && echo "Finished building lustre"


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

RUN echo "Building MPICH ... " \
    && cd /tmp/mpich-build/mpich-${MPICH_VERSION}   \
    &&./configure ${MPICH_CONFIGURE_OPTIONS} FFLAGS=-fallow-argument-mismatch \
    && make ${MPICH_MAKE_OPTIONS} \
    && echo "Finished building MPICH" 

FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 as prod
# redefine after FROM to ensure it is defined
ARG OS_VERSION="22.04"
# mpich version
ARG MPICH_VERSION="3.4.3"
# lustre version
ARG LUSTRE_VERSION="2.15.63"
# mpi4py version
ARG MPI4PY_VERSION="3.1.4"
# OSU version
ARG OSU_VERSION="6.2"

RUN apt-get update -qq \
    && apt-get -y --no-install-recommends install \
    libreadline-dev \
    libmount-dev pkg-config \
    zlib1g-dev\
    libcrypt-dev \ 
    libcurl4-openssl-dev \
    libpython3-dev \
    libreadline-dev \
    libssl-dev \
    valgrind \
    gfortran\
    libkeyutils-dev libnl-genl-3-dev libyaml-dev linux-headers-$(uname -r) \
    && apt-get clean all \
    && rm -r /var/lib/apt/lists/* \
    && echo "Finished apt-get installs"

WORKDIR /tmp/

COPY --from=builder /tmp/ /tmp/

# install lustre from stage builder
RUN cd /tmp/lustre-build/lustre-release \
    && make install \
    && echo "Finished installing lustre"

# install mpich from stage builder
RUN cd /tmp/mpich-build/mpich-${MPICH_VERSION} \
    && make install \
    && ldconfig \
    && cp -p /tmp/mpich-build/mpich-${MPICH_VERSION}/examples/cpi /usr/bin/ \
    && echo "Finished installing MPICH"

# Build and install OSU Benchmarks
ARG OSU_CONFIGURE_OPTIONS="--prefix=/usr/local CC=mpicc CXX=mpicxx CFLAGS=-O3"
ARG OSU_MAKE_OPTIONS="-j8"
RUN echo "Building and installing OSU..." \
    && cd /tmp/osu-benchmarks-build/osu-micro-benchmarks-${OSU_VERSION} \
    && ./configure ${OSU_CONFIGURE_OPTIONS} \
    && make ${OSU_MAKE_OPTIONS} \
    && make install \
    && echo "Finished building and installing OSU"


ENV PATH="/usr/local/libexec/osu-micro-benchmarks/mpi/collective:/usr/local/libexec/osu-micro-benchmarks/mpi/one-sided:/usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt:/usr/local/libexec/osu-micro-benchmarks/mpi/startup:$PATH"



#clean /tmp
RUN rm -rf /tmp/*
# add mpi4py in the container 
#RUN pip install mpi4py==${MPI4PY_VERSION}

RUN mkdir -p /container-scratch/

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildcudalustrempich.dockerfile /opt/docker-recipes/

# Final
CMD ["/bin/bash"]   
