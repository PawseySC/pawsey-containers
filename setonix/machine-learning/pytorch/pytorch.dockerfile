# This Dockerfile builds an Ubuntu-based PyTorch container image with ROCm
# and MPICH support for AMD GPUs on HPE Cray EX systems.
#
# The container is based on the Pawsey ROCm + MPICH base image and builds
# PyTorch from source with ROCm support.
#
# The following components are installed:
#   - PyTorch
#   - PyTorch Vision
#   - PyTorch Audio
#   - PyTorch Triton
#   - Eigen
#   - JupyterLab
#
# The recipe is structured similarly to the Pawsey ROCm-MPICH base image:
#   0. Global build parameters
#   A. Base image
#   B. Configure the ROCm environment
#   C. Install system dependencies
#   D. Install Eigen
#   E. Prepare the Python environment
#   F. Build and install PyTorch
#   G. Install torchvision
#   H. Install torchaudio
#   I. Add build information and clean up
#
#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------


#================================================================
# 0. Initial main definition of global parameters
#================================================================

ARG OS_VERSION="24.04"

ARG ROCM_VERSION="7.2.4"
ARG MPICH_VERSION="4.2.2"
ARG PYTORCH_VERSION="2.13.0"

ARG PYTORCH_VISION_VERSION="0.28.0"
ARG PYTORCH_TRITON_VERSION="3.3.1"

ARG AMDGPU_TARGETS="gfx90a"

# Additional system packages can be supplied at build time.
ARG APT_GET_APPS=""

# Image/build metadata.
ARG IMAGE_TITLE="pytorch-amd-${AMDGPU_TARGETS}"
ARG IMAGE_BUILD_INFO_DIR="/opt/build-info-and-recipes"
ARG INTERNAL_BUILD_INFO_SUBDIR="${IMAGE_BUILD_INFO_DIR}/${IMAGE_TITLE}"


#================================================================
# 0.1 Image labels
#================================================================
#
# These labels are inherited by the final image and provide
# provenance and version information.
#
#---------------------------------------------------------------

LABEL org.opencontainers.image.authors="Deva Deeptimahanti <ddeeptimahanti@pawsey.org.au>"
LABEL org.opencontainers.image.title="${IMAGE_TITLE}"
LABEL org.opencontainers.image.version="pytorch${PYTORCH_VERSION}-rocm${ROCM_VERSION}-mpich${MPICH_VERSION}-ubuntu${OS_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers"
LABEL au.org.pawsey.image.build-info-dir="${IMAGE_BUILD_INFO_DIR}"

#================================================================
# A. Base image
#================================================================
#
# Use the Pawsey ROCm + MPICH base image.
#
# This provides:
#   - ROCm
#   - MPICH
#   - Lustre support
#   - MPI/OFI support required on Setonix
#
#---------------------------------------------------------------

FROM quay.io/pawsey/rocm-mpich-base:rocm${ROCM_VERSION}-mpich${MPICH_VERSION}-lustrerelease-ubuntu${OS_VERSION}

#---------------------------------------------------------------
# A.0 Recall global build arguments
#---------------------------------------------------------------

ARG ROCM_VERSION
ARG MPICH_VERSION
ARG PYTORCH_VERSION
ARG AMDGPU_TARGETS

ARG IMAGE_BUILD_INFO_DIR
ARG INTERNAL_BUILD_INFO_SUBDIR


#================================================================
# B. Configure the ROCm/PyTorch build environment
#================================================================
#
# PyTorch's build system uses several environment variables to
# determine whether CUDA or ROCm is being used and which AMD GPU
# architecture should be compiled.
#
#---------------------------------------------------------------

ENV _GLIBCXX_USE_CXX11_ABI=1
ENV USE_CUDA=0
ENV USE_ROCM=1

ENV CC=gcc
ENV CXX=g++
ENV CXXFLAGS=-std=c++17

ENV PYTORCH_ROCM_ARCH=${AMDGPU_TARGETS}

ENV ROCM_PATH=/opt/rocm
ENV LD_LIBRARY_PATH=/opt/rocm/llvm/lib:$LD_LIBRARY_PATH

#---------------------------------------------------------------
# B.1 Restrict ROCm architecture detection
#---------------------------------------------------------------
#
# The container is intended for the target AMD GPU architecture.
# Prevent the ROCm architecture detection tools from attempting
# to detect hardware during the image build.
#
# This is particularly useful when building the image on a system
# where the target GPU is not directly visible to Docker.
#
#---------------------------------------------------------------

RUN set -eux; \
    cd /opt/rocm/bin; \
    mv rocm_agent_enumerator rocm_agent_enumerator_old; \
    printf '%s\n' "echo ${AMDGPU_TARGETS}" > rocm_agent_enumerator; \
    chmod 0777 rocm_agent_enumerator

RUN set -eux; \
    cd /opt/rocm/lib/llvm/bin; \
    mv amdgpu-arch amdgpu-arch.old; \
    printf '%s\n' "echo ${AMDGPU_TARGETS}" > amdgpu-arch; \
    chmod 0777 amdgpu-arch


#================================================================
# C. Install system dependencies
#================================================================
#
# Install the libraries required to build PyTorch and its
# dependencies.
#
# Keep this list minimal because the ROCm-MPICH base image already
# provides most of the compiler, MPI, ROCm and runtime stack.
#
#---------------------------------------------------------------

ARG APT_GET_APPS

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get -y --no-install-recommends install \
        libopenblas-dev \
        libpng-dev \
        libjpeg-dev \
        ${APT_GET_APPS}; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*


#================================================================
# D. Build and install Eigen
#================================================================
#
# PyTorch can use the system Eigen installation rather than
# building its own bundled copy.
#
#---------------------------------------------------------------

ARG EIGEN_VERSION="5.0.1"

RUN set -eux; \
    rm -rf /tmp/build; \
    mkdir -p /tmp/build; \
    cd /tmp/build; \
    wget -q \
        https://gitlab.com/libeigen/eigen/-/archive/${EIGEN_VERSION}/eigen-${EIGEN_VERSION}.tar.gz; \
    tar xf eigen-${EIGEN_VERSION}.tar.gz; \
    cd eigen-${EIGEN_VERSION}; \
    mkdir build; \
    cd build; \
    cmake ..; \
    make -j16; \
    make install




#================================================================
# E. Configure Python/pip
#================================================================
#
# Ubuntu 24.04 protects the system Python installation using
# PEP 668. PyTorch and its build dependencies therefore require
# the break-system-packages option.
#
#---------------------------------------------------------------

RUN set -eux; \
    mkdir -p ~/.config/pip; \
    printf '%s\n' \
        '[global]' \
        'break-system-packages = true' \
        > ~/.config/pip/pip.conf


#================================================================
# F. Build and install PyTorch
#================================================================
#
# PyTorch is built from source to enable the required ROCm
# architecture and integration with the ROCm/MPICH environment.
#
#---------------------------------------------------------------

#---------------------------------------------------------------
# F.0 Clone PyTorch
#---------------------------------------------------------------

RUN set -eux; \
    cd /tmp/build; \
    git clone \
        --branch "v${PYTORCH_VERSION}" \
        --recursive \
        https://github.com/pytorch/pytorch.git; \
    cd pytorch; \
    \
    # PyTorch expects MPI_CXX in some locations. Replace it with
    # MPI_C so that the MPI C interface provided by the container
    # is used consistently.
    grep -R . -e "MPI_CXX" \
        | cut -f1 -d: \
        | xargs -r -n1 sed -i -e "s/MPI_CXX/MPI_C/g"; \
    \
    # Ensure all submodules are synchronized and initialized.
    git submodule sync; \
    git submodule update --init --recursive


#---------------------------------------------------------------
# F.1 Configure PyTorch to use the system Eigen installation
#---------------------------------------------------------------

RUN set -eux; \
    cd /tmp/build/pytorch; \
    \
    # Modify the PyTorch CMake configuration so that the system
    # Eigen installation is used instead of the bundled version.
    sed -i \
        -e '321d' \
        -e '320a ON)' \
        CMakeLists.txt; \
    \
    # Install Python build dependencies.
    python3 -m pip install \
        --break-system-packages \
        -r requirements.txt

#---------------------------------------------------------------
# F.2 Verify CMake
#---------------------------------------------------------------

RUN set -eux; \
    cmake --version


#---------------------------------------------------------------
# F.3 Build/install Triton and PyTorch
#---------------------------------------------------------------
#
# PyTorch's AMD build process requires the ROCm-specific build
# helper and Triton installation.
#
#---------------------------------------------------------------

ARG PYTORCH_TRITON_VERSION

RUN set -eux; \
    cd /tmp/build/pytorch; \
    \
    # Use the specified PyTorch Triton test wheel during the
    # PyTorch build.
    sed -i \
        -e "4a python3 -m pip install --index-url \${DOWNLOAD_PYTORCH_ORG}/test/ pytorch-triton==${PYTORCH_TRITON_VERSION}; exit 0" \
        scripts/install_triton_wheel.sh; \
    \
    cat scripts/install_triton_wheel.sh; \
    \
    # Build Triton and configure the AMD/ROCm PyTorch build.
    make triton; \
    python3 tools/amd_build/build_amd.py; \
    \
    # Build and install PyTorch.
    python3 setup.py install


#---------------------------------------------------------------
# F.4 Install Python runtime dependencies
#---------------------------------------------------------------

RUN set -eux; \
    python3 -m pip install \
        --break-system-packages \
        mpmath \
        urllib3 \
        typing-extensions \
        sympy \
        pillow \
        numpy \
        networkx \
        MarkupSafe \
        idna \
        fsspec \
        filelock \
        charset-normalizer \
        certifi \
        requests \
        pytorch-triton-rocm \
        jinja2 \
        --index-url https://download.pytorch.org/whl/rocm7.2 \
        --no-dependencies



#================================================================
# G. Install torchvision
#================================================================
#
# Install the torchvision version associated with the selected
# PyTorch release.
#
#---------------------------------------------------------------
ARG PYTORCH_VISION_VERSION
RUN set -eux; \
    cd /tmp/build; \
    git clone \
        --branch "v${PYTORCH_VISION_VERSION}" \
        https://github.com/pytorch/vision.git; \
    cd vision; \
    python3 setup.py install



#================================================================
# H. Install torchaudio
#================================================================
#
# Configure ROCm library locations used when building or
# installing torchaudio.
#
#---------------------------------------------------------------

ARG CXX=hipcc
ARG ROCRAND_PATH=/opt/rocm
ARG HIPRAND_PATH=/opt/rocm
ARG ROCBLAS_PATH=/opt/rocm
ARG MIOPEN_PATH=/opt/rocm
ARG ROCFFT_PATH=/opt/rocm
ARG HIPFFT_PATH=/opt/rocm
ARG HIPSPARSE_PATH=/opt/rocm
ARG RCCL_PATH=/opt/rocm
ARG ROCPRIM_PATH=/opt/rocm
ARG HIPCUB_PATH=/opt/rocm
ARG ROCTHRUST_PATH=/opt/rocm

RUN set -eux; \
    python3 -m pip install torchaudio


#================================================================
# I. Install JupyterLab
#================================================================
#
# JupyterLab is included to provide an interactive Python
# environment when the container is used for ML workflows.
#
#---------------------------------------------------------------

RUN set -eux; \
    python3 -m pip install jupyterlab


#================================================================
# J. Container build information
#================================================================
#
# Store the Dockerfile used to create the image inside the
# container. This follows the Pawsey container build-info
# convention and makes the recipe available alongside the image.
#
#---------------------------------------------------------------

ARG INTERNAL_BUILD_INFO_SUBDIR

RUN set -eux; \
    mkdir -p "${INTERNAL_BUILD_INFO_SUBDIR}"

COPY pytorch.dockerfile "${INTERNAL_BUILD_INFO_SUBDIR}/"


#================================================================
# K. Clean up
#================================================================
#
# Remove temporary source trees and other build artefacts that
# are no longer required at runtime.
#
#---------------------------------------------------------------

RUN set -eux; \
    rm -rf /tmp/build


#================================================================
# L. Runtime environment
#================================================================
#
# Ensure ROCM_PATH is available when the image is executed under
# Singularity
#
#---------------------------------------------------------------

RUN set -eux; \
    printf '%s\n' \
        'export ROCM_PATH=/opt/rocm' \
        >> /.singularity.d/env/91-environment.sh
