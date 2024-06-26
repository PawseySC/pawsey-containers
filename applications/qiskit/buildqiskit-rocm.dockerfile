# This recipe supports one-stage builds
# This recepe includes rocm backend for qiskit

ARG OS_VERSION=22.04
ARG DATE_TAG=2024-06
ARG PY_VERSION=3.11
# ROCM version is 6.1 or 5.6.0
ARG ROCM_VERSION=6.1

# define some metadata 
FROM quay.io/pawsey/rocm-mpich-base:rocm${ROCM_VERSION}-mpich3.4.3-ubuntu22 as builder
LABEL org.opencontainers.image.created="2024-06"
LABEL org.opencontainers.image.authors="Shusen Liu <shusen.liu@pawsey.org.au>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/applications/qiskit/buildqiskit-rocm.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Qiskit on Setonix compatible Lustre-aware MPICH with rocm${ROCM_VERSION}"
LABEL org.opencontainers.image.description="Qiskit image providing lustre-aware mpi compatible with cray-mpich, lustre and ROCM used on Setonix"
LABEL org.opencontainers.image.base.name="pawsey/qiskit.setonix"

# redefine after FROM to ensure it is defined
ARG OS_VERSION
ARG PY_VERSION

# set frontend to noninteractive to avoid user interaction during build
ENV DEBIAN_FRONTEND="noninteractive"

# add deadsnakes PPA for Python versions if not on Ubuntu 22.04
RUN if [ ${OS_VERSION} != "ubuntu22.04" ]; then \
        add-apt-repository ppa:deadsnakes/ppa \
        && apt-get update -qq; \
    fi

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
    software-properties-common \
    curl \
    gnupg \
    dirmngr \
    sudo \
    wget

# Install Python and set the default Python version
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

# copy scr to image
ADD downloaded_files.tar.gz /tmp/

# install qiskit-aer requirements and compile qiskit-aer
RUN echo "Building Qiskit ... " \
    && pip --no-cache-dir install --break-system-packages -r /tmp/qiskit-aer-build/requirements-dev.txt \
    && pip install pybind11 

RUN python /tmp/qiskit-aer-build/setup.py bdist_wheel -- \
  -DCMAKE_CXX_COMPILER=CC \
  -DCMAKE_BUILD_TYPE=Release \
  -DAER_MPI=True \
  -DAER_THRUST_BACKEND=ROCM \
  -DAER_ROCM_ARCH=gfx90a \
  -DAER_DISABLE_GDR=False \
  -DPYBIND11_INCLUDE_DIR=$(python -c "import pybind11; print(pybind11.get_include())") \
  --

# copy the wheel to /tmp/qiskit-aer-build
RUN mkdir -p /tmp/qiskit-aer-build/dist
RUN cp /dist/qiskit_aer*.whl /tmp/qiskit-aer-build/dist/

RUN pip install /tmp/qiskit-aer-build/dist/qiskit_aer*.whl

#clean /tmp
RUN rm -rf /tmp/*

RUN mkdir -p /container-scratch/

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildqiskit-rocm.dockerfile /opt/docker-recipes/

# final
CMD ["/bin/bash"]   
