# This recipe supports Qiskit-aer-GPU built with a minimal image based on CUDA 12.5, compatible with Grace Hopper, and supporting aarch64 architectures.
# NO MPI, NO LUSTRE, NO
# py version is allowed to be passed in as a build argument
ARG PY_VERSION="3.12" 
# cuda version is allowed to be passed in as a build argument 12.5.0/12.6.0. For Grace Hopper, we recommand only these two versions.
ARG CUDA_VERSION="12.5.0"
# date tag is allowed to be passed in as a build argument
ARG DATE_TAG=2024-09

#----------------------------------------------------------------
#------------------------start stage------------------------
#----------------------------------------------------------------
FROM ubuntu:22.04
ARG PY_VERSION 
ARG DATE_TAG
ARG CUDA_VERSION


# define some metadata 
LABEL org.opencontainers.image.created="2024-09"
LABEL org.opencontainers.image.authors="Shusen Liu <shusen.liu@pawsey.org.au>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/applications/qiskit/buildqiskit-cuda.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Qiskit - Grace Hopper with CUDA ${CUDA_VERSION}"
LABEL org.opencontainers.image.description="A Qiskit-aer-GPU built with a minimal image based on CUDA 12.5, compatible with Grace Hopper, and supporting aarch64 architectures."
LABEL org.opencontainers.image.base.name="ubuntu2204"

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
        python3 python3-dev python3-pip python3-setuptools python3-venv \
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
    && rm -rf /var/lib/apt/lists/* \
    && rm cuda-keyring_1.1-1_all.deb

WORKDIR /opt/

RUN wget https://developer.download.nvidia.com/compute/cuquantum/redist/cuquantum/linux-sbsa/cuquantum-linux-sbsa-24.08.0.5_cuda12-archive.tar.xz -O cuquantum.tar.xz \
  && wget https://developer.download.nvidia.com/compute/cutensor/redist/libcutensor/linux-sbsa/libcutensor-linux-sbsa-2.0.2.5-archive.tar.xz -O libcutensor.tar.xz \
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
  ## Only 0.15 For Grace Hopper
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
ENV LD_LIBRARY_PATH=/opt/cuquantum/lib:/usr/local/lib/python3.10/dist-packages/nvidia/cublas/lib:/opt/libcutensor/lib/12:/usr/local/lib/python3.10/dist-packages/nvidia/cusolver/lib:/usr/local/lib/python3.10/dist-packages/nvidia/cusparse/lib:${LD_LIBRARY_PATH:-""}

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
COPY buildqiskit-cuda.dockerfile /opt/docker-recipes/

# final
CMD ["/bin/bash"]   
