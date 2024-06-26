# This recipe supports multi-stage builds
# This recepe includes CUDA 12.5.0 / lustre-aware MPICH 3.4.3 / Lustre 2.15.63 / OSU 6.2

# os version is allowed to be passed in as a build argument 22.04/20.04
ARG OS_VERSION="22.04"
# py version is allowed to be passed in as a build argument
ARG PY_VERSION="3.11" 
# cuda version is allowed to be passed in as a build argument 12.5.0/12.4.1. For Grace Hopper, we recommand only these two versions.
ARG CUDA_VERSION="12.5.0"
# date tag is allowed to be passed in as a build argument
ARG DATE_TAG=2024-06

#----------------------------------------------------------------
#------------------------start stage------------------------
#----------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${OS_VERSION} AS builder
# Predefined, redefine after FROM to ensure it is defined
ARG OS_VERSION
ARG PY_VERSION 
ARG DATE_TAG
ARG CUDA_VERSION

# mpich version
ARG MPICH_VERSION="3.4.3"
# lustre version
ARG LUSTRE_VERSION="2.15.63"
# mpi4py version
ARG MPI4PY_VERSION="3.1.4"
# OSU version
ARG OSU_VERSION="6.2"

# define some metadata 
LABEL org.opencontainers.image.created="2024-06"
LABEL org.opencontainers.image.authors="Shusen Liu <shusen.liu@pawsey.org.au>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/applications/qiskit/buildqiskit-cuda.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Qiskit - Setonix compatible Lustre-aware MPICH with CUDA${CUDA_VERSION}"
LABEL org.opencontainers.image.description="Image providing lustre-aware mpi compatible with cray-mpich, lustre and CUDA used on Setonix"
LABEL org.opencontainers.image.base.name="pawsey/qiskit.setonix"

# run apt-get install on a few packages
ENV DEBIAN_FRONTEND="noninteractive"

# run apt-get install on a few packages
RUN apt-get update -qq \
    && apt-get -y --no-install-recommends install \
        software-properties-common \
        build-essential \
        ca-certificates \
        gdb \
        gcc g++ gfortran \
        wget \
        git \
        python3 python3-dev python3-pip python3-setuptools python3-distutils \
        patchelf strace ltrace \
        libcrypt-dev \
        libcurl4-openssl-dev \
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
    && pip install --upgrade pip setuptools \
    && pip install nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cusolver-cu12 nvidia-cusparse-cu12 cuquantum-cu12 pip-tools \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# for the system which it NOT Ubuntu 22.04, adding deadsnakes PPA for more Python versions
RUN if [ ${OS_VERSION} != "22.04" ]; then \
        add-apt-repository ppa:deadsnakes/ppa \
        && apt-get update -qq \
        && apt-get install -y --no-install-recommends python${PY_VERSION}-dev python${PY_VERSION}-full \
        && update-alternatives --install /usr/bin/python python /usr/bin/python${PY_VERSION} 1 \
        && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PY_VERSION} 1 \
        && apt-get clean \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# copy lustre, mpich and OSU to image
ADD downloaded_files.tar.gz /tmp/

# build lustre
RUN echo "Building lustre" \
    && cd /tmp/lustre-build/lustre-release \
    && chmod +x ./autogen.sh && ./autogen.sh \
    && ./configure --disable-server --enable-client \
    && make -j8 \
    && cd /tmp/lustre-build/lustre-release \
    && make install \
    && echo "Finished building lustre"

# build MPICH
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

RUN echo "Building Qiskit ... " \
    && pip --no-cache-dir install  -r /tmp/qiskit-aer-build/requirements-dev.txt \
    && pip install pybind11 

# set the default Python version
RUN ln -s /usr/bin/python3 /usr/bin/python

RUN python /tmp/qiskit-aer-build/setup.py bdist_wheel -- \
    -DCMAKE_CXX_COMPILER=CC \
    -DCMAKE_BUILD_TYPE=Release \
    -DAER_MPI=True \
    -DAER_THRUST_BACKEND=CUDA \
    -DAER_DISABLE_GDR=False \
    -DPYBIND11_INCLUDE_DIR=$(python -c "import pybind11; print(pybind11.get_include())") \
    --
        
# copy the wheel to /tmp/qiskit-aer-build
RUN mkdir -p /tmp/qiskit-aer-build/dist
RUN cp /dist/qiskit_aer*.whl /tmp/qiskit-aer-build/dist/
  

#----------------------------------------------------------------
#------------------------production stage------------------------
#----------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${OS_VERSION} AS prod
# redefine after FROM to ensure it is defined
ARG OS_VERSION
ARG PY_VERSION
ARG CUDA_VERSION

# mpich version
ARG MPICH_VERSION="3.4.3"
# lustre version
ARG LUSTRE_VERSION="2.15.63"
# mpi4py version
ARG MPI4PY_VERSION="3.1.4"
# OSU version
ARG OSU_VERSION="6.2"


ENV DEBIAN_FRONTEND="noninteractive"
RUN apt-get update -qq \
    && apt-get -y --no-install-recommends install \
    software-properties-common\
    curl\
    wget\
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

# build and install OSU Benchmarks
ARG OSU_CONFIGURE_OPTIONS="--prefix=/usr/local CC=mpicc CXX=mpicxx CFLAGS=-O3"
ARG OSU_MAKE_OPTIONS="-j8"
RUN echo "Building and installing OSU..." \
    && cd /tmp/osu-benchmarks-build/osu-micro-benchmarks-${OSU_VERSION} \
    && ./configure ${OSU_CONFIGURE_OPTIONS} \
    && make ${OSU_MAKE_OPTIONS} \
    && make install \
    && echo "Finished building and installing OSU"

ENV PATH="/usr/local/libexec/osu-micro-benchmarks/mpi/collective:/usr/local/libexec/osu-micro-benchmarks/mpi/one-sided:/usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt:/usr/local/libexec/osu-micro-benchmarks/mpi/startup:$PATH"

# add deadsnakes PPA for Python versions if not on Ubuntu 22.04
RUN if [ ${OS_VERSION} != "ubuntu22.04" ]; then \
        add-apt-repository ppa:deadsnakes/ppa \
        && apt-get update -qq; \
    fi

# install Python and set the default Python version
RUN apt-get install -y --no-install-recommends \
        python${PY_VERSION}-dev \
        python${PY_VERSION}-distutils \
        python${PY_VERSION}-full \
    && update-alternatives --install /usr/bin/python python /usr/bin/python${PY_VERSION} 1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PY_VERSION} 1 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# install pip using get-pip.py script
RUN curl -sS https://bootstrap.pypa.io/get-pip.py | python3 \
    && python -m pip install --upgrade --break-system-packages pip \
    && pip install --break-system-packages pip-tools

# add mpi4py in the container 
RUN pip install mpi4py==${MPI4PY_VERSION}

# install qiskit-aer
RUN pip install /tmp/qiskit-aer-build/dist/qiskit_aer*.whl

# clean /tmp
RUN rm -rf /tmp/*

RUN mkdir -p /container-scratch/

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildqiskit-cuda.dockerfile /opt/docker-recipes/

# final
CMD ["/bin/bash"]   
