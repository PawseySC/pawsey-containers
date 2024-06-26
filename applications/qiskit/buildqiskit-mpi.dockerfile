# This recipe supports multi-stage builds
# This recepe includes MPICH backend for qiskit

ARG OS_VERSION=22.04
ARG DATE_TAG=2024-06
ARG PY_VERSION=3.11

#----------------------------------------------------------------
#------------------------builder stage------------------------
#----------------------------------------------------------------
#define some metadata 
FROM ubuntu:${OS_VERSION} as builder
LABEL org.opencontainers.image.created="2024-06"
LABEL org.opencontainers.image.authors="Shusen Liu <shusen.liu@pawsey.org.au>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/applications/qiskit/buildqiskit-mpi.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Qiskit on Setonix compatible Lustre-aware MPICH with CUDA 12.5"
LABEL org.opencontainers.image.description="Qiskit on the image providing lustre-aware mpi compatible with cray-mpich, lustre used on Setonix"
LABEL org.opencontainers.image.base.name="pawsey/qiskit.setonix"

# redefine after FROM to ensure it is defined
ARG OS_VERSION
ARG PY_VERSION
# mpich version
ARG MPICH_VERSION="3.4.3"
# mpi4py version
ARG MPI4PY_VERSION="3.1.4"
# OSU version
ARG OSU_VERSION="6.2"
# lustre version
ARG LUSTRE_VERSION="2.15.63"

# set frontend to noninteractive to avoid user interaction during build
ENV DEBIAN_FRONTEND="noninteractive"

# update and install initial dependencies
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
    software-properties-common \
    curl \
    gnupg \
    dirmngr \
    sudo \
    wget

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

# install additional system packages
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        gdb \
        gcc g++ gfortran \
        git \
        python3-six python3-setuptools \
        patchelf strace ltrace \
        libcrypt-dev \
        libcurl4-openssl-dev \
        libpython3-dev \
        libreadline-dev \
        libssl-dev \
        autoconf \
        automake \
        bison \
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
        libkeyutils-dev libnl-genl-3-dev libyaml-dev linux-headers-$(uname -r) \
        libmount-dev pkg-config \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && echo "Environment setup complete."

# copy scr to image
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

RUN cd /tmp/mpich-build/mpich-${MPICH_VERSION} \
    && make install \
    && ldconfig \
    && cp -p /tmp/mpich-build/mpich-${MPICH_VERSION}/examples/cpi /usr/bin/ \
    && echo "Finished installing MPICH"

RUN echo "Building Qiskit ... " \
    && pip --no-cache-dir install --break-system-packages -r /tmp/qiskit-aer-build/requirements-dev.txt \
    && pip install pybind11 

RUN python /tmp/qiskit-aer-build/setup.py bdist_wheel -- \
  -DCMAKE_CXX_COMPILER=CC \
  -DCMAKE_BUILD_TYPE=Release \
  -DAER_MPI=True \
  -DAER_THRUST_BACKEND=OMP \
  -DAER_DISABLE_GDR=True \
  -DPYBIND11_INCLUDE_DIR=$(python -c "import pybind11; print(pybind11.get_include())") \
  --

# Copy the wheel to /tmp/qiskit-aer-build
RUN mkdir -p /tmp/qiskit-aer-build/dist
RUN cp /dist/qiskit_aer*.whl /tmp/qiskit-aer-build/dist/


#----------------------------------------------------------------
#------------------------production stage------------------------
#----------------------------------------------------------------
FROM ubuntu:${OS_VERSION} as prod
# os version
ARG OS_VERSION
# py version
ARG PY_VERSION

# redefine after FROM to ensure it is defined
ARG MPICH_VERSION="3.4.3"
# mpi4py version
ARG MPI4PY_VERSION="3.1.6"
# OSU version
ARG OSU_VERSION="6.2"
# lustre version
ARG LUSTRE_VERSION="2.15.63"

# set frontend to noninteractive to avoid user interaction during build
ENV DEBIAN_FRONTEND="noninteractive"

# update and install initial dependencies
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
    software-properties-common \
    curl \
    gnupg \
    dirmngr \
    sudo \
    wget \
    make

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
    gcc g++ gfortran\
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

# add mpi4py in the container 
RUN pip install mpi4py==${MPI4PY_VERSION}

# install qiskit by the wheel from the builder
RUN pip install /tmp/qiskit-aer-build/dist/qiskit_aer*.whl

# clean /tmp
RUN rm -rf /tmp/*

RUN mkdir -p /container-scratch/

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildqiskit-mpi.dockerfile /opt/docker-recipes/

# final
CMD ["/bin/bash"]   
