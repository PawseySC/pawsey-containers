FROM ubuntu:22.04

#CICD metadata
LABEL org.opencontainers.image.arch=arm
LABEL org.opencontainers.image.compilation=auto
LABEL org.opencontainers.image.devmode=false
LABEL org.opencontainers.image.noscan=true

#Image metadata
LABEL org.opencontainers.image.name="qiskit"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.version="12-11-2024"
LABEL org.opencontainers.image.minversion="0.0.4"
LABEL org.opencontainers.image.authors="Shusen Liu <shusen.liu@pawsey.org.au>"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Ella Qiskit"
LABEL org.opencontainers.image.description="We provide a container image for the Ella project, \
supporting Qiskit-aer-GPU built with a minimal image based on CUDA 12.6. \
1. qiskit v0.15.0 with cuquantum support"

ARG CUDA_VERSION=12.6.0
ARG PY_VERSION=3.12
# run apt-get install on a few packages
ENV DEBIAN_FRONTEND="noninteractive"

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends software-properties-common gpg-agent \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        wget \
        git \
        sudo \
        curl \
        libtool \
        make \
        cmake \
        openssh-server \
        vim \
        ninja-build \
        libblas-dev libopenblas-dev \
        python${PY_VERSION}-dev \
        python${PY_VERSION}-distutils \
        python${PY_VERSION}-full \
        python3-pip \
    && add-apt-repository ppa:ubuntu-toolchain-r/test  \
    && apt-get update -qq  \
    && apt-get install -y --no-install-recommends gcc-13 g++-13 gfortran-13  \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100  \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100 \
    && update-alternatives --install /usr/bin/gfortran gfortran /usr/bin/gfortran-13 100  \
    && add-apt-repository --remove ppa:ubuntu-toolchain-r/test \
    && wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/sbsa/cuda-keyring_1.1-1_all.deb \
    && dpkg -i cuda-keyring_1.1-1_all.deb \
    && apt-get update \
    && if [ "${CUDA_VERSION}" = "12.5.0" ]; then \
           apt-get -y install cuda-compiler-12-5; \
       elif [ "${CUDA_VERSION}" = "12.6.0" ]; then \
           apt-get -y install cuda-compiler-12-6; \
       else \
           echo "Unsupported CUDA version: ${CUDA_VERSION}"; \
           exit 1; \
       fi \
    && pip install --upgrade pip setuptools \
    && pip install nvidia-cuda-runtime-cu12 nvidia-nvjitlink-cu12 nvidia-cublas-cu12 nvidia-cusolver-cu12 nvidia-cusparse-cu12 pip-tools \
    && update-alternatives --install /usr/bin/python python /usr/bin/python${PY_VERSION} 1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PY_VERSION} 1 \    
    && apt-get clean \
    && rm -rf /root/.cache/pip  \
    && rm -rf /var/lib/apt/lists/* \
    && rm cuda-keyring_1.1-1_all.deb

WORKDIR /opt/

RUN wget -q https://developer.download.nvidia.com/compute/cuquantum/redist/cuquantum/linux-sbsa/cuquantum-linux-sbsa-24.08.0.5_cuda12-archive.tar.xz -O cuquantum.tar.xz \
  && wget -q https://developer.download.nvidia.com/compute/cutensor/redist/libcutensor/linux-sbsa/libcutensor-linux-sbsa-2.0.2.5-archive.tar.xz -O libcutensor.tar.xz \
  && tar -xf cuquantum.tar.xz \
  && tar -xf libcutensor.tar.xz \
  && ls  \
  && mv cuquantum-linux* /opt/cuquantum \
  && mv libcutensor-linux* /opt/libcutensor \
  && mkdir -p /opt/cuquantum/lib/12 \
  && cd /opt/cuquantum/lib \
  && for file in *; do ln -s ../$file 12/$file; done \
  && rm /opt/cuquantum.tar.xz /opt/libcutensor.tar.xz

RUN mkdir -p /opt/qiskit-aer-build \
  && git clone https://github.com/Qiskit/qiskit-aer /opt/qiskit-aer-build \
  && cd /opt/qiskit-aer-build \
  ## Only 0.15 and above For Grace Hopper
  && git checkout 0.15  

RUN echo "Building Qiskit ... " \
    && python -m ensurepip --upgrade \
    && python -m pip install --upgrade setuptools

RUN pip --no-cache-dir install  scikit-build>=0.11.0 conan==1.65.0 pybind11==2.13.4 numpy==2.0.1

# set the default Python version
RUN if [ ! -e /usr/bin/python ]; then ln -s /usr/bin/python3 /usr/bin/python; fi

RUN rm -rf /opt/qiskit-aer-build/_skbuild

ENV CC=/usr/bin/gcc \
    CXX=/usr/bin/g++ \
    CUDACXX=/usr/local/cuda/bin/nvcc

WORKDIR /opt/qiskit-aer-build

ENV LD_LIBRARY_PATH=/opt/cuquantum/lib:/opt/libcutensor/lib/12:${LD_LIBRARY_PATH:-""}


RUN  python ./setup.py bdist_wheel -vvv --  \
    -DAER_THRUST_BACKEND=CUDA \
    -DCUQUANTUM_ROOT=/opt/cuquantum \
    -DCUTENSOR_ROOT=/opt/libcutensor \
    -DAER_ENABLE_CUQUANTUM=true
 
# install qiskit-aer
RUN python -m pip install /opt/qiskit-aer-build/dist/qiskit_aer*.whl

RUN rm -rf /opt/qiskit-aer-build/_skbuild
#RUN python -m pip install -r /opt/qiskit-aer-build/requirements-dev.txt

RUN mkdir -p /container-scratch/

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY *.dockerfile /opt/docker-recipes/
# final
CMD ["/bin/bash"]   
