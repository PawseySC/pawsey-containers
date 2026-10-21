# This Dockerfile builds an Ubuntu-based TensorFlow container image with
# ROCm, MPICH and Horovod support for AMD GPUs.
#
# The container is based on the Pawsey ROCm + MPICH base image.
#
# The following components are installed:
#   - TensorFlow ROCm
#   - Horovod with ROCm/RCCL support
#   - Python 3.10 for TensorFlow 2.15.x
#   - Python 3.12 for newer TensorFlow releases
#
# The recipe follows the Pawsey container build structure:
#   0. Global build parameters
#   A. Base image
#   B. Configure ROCm environment
#   C. Configure Python/pip
#   D. Install TensorFlow
#   E. Configure Horovod
#   F. Build and install Horovod
#   G. Container build information
#   H. Runtime environment
#   I. Clean up
#
#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------


#================================================================
# 0. Initial main definition of global parameters
#================================================================
#
# These arguments can be overridden at build time using:
#
#   docker build --build-arg <NAME>=<VALUE> ...
#
#---------------------------------------------------------------

ARG OS_VERSION="24.04"

ARG ROCM_VERSION="7.2.4" 
# TF/2.15.1 is available with rocm/6.3.x

ARG MPICH_VERSION="4.2.2"

ARG TF_VERSION="2.21.0"
ARG HOROVOD_VERSION="0.28.1"

ARG AMDGPU_TARGETS="gfx90a"

# Python versions used by the supported TensorFlow releases.
ARG PYTHON_TF215_VERSION="3.10.12"
ARG PYTHON_TF221_VERSION="3.12"

# Additional system packages can be supplied at build time.
ARG APT_GET_APPS=""

# Image/build metadata.
ARG IMAGE_TITLE="tensorflow-amd-${AMDGPU_TARGETS}"
ARG IMAGE_BUILD_INFO_DIR="/opt/build-info-and-recipes"
ARG INTERNAL_BUILD_INFO_SUBDIR="${IMAGE_BUILD_INFO_DIR}/${IMAGE_TITLE}"


#================================================================
# 0.1 Image labels
#================================================================
#
# Provide image provenance and version information.
#
#---------------------------------------------------------------

LABEL org.opencontainers.image.authors="Deva Deeptimahanti <ddeeptimahanti@pawsey.org.au>"
LABEL org.opencontainers.image.title="${IMAGE_TITLE}"
LABEL org.opencontainers.image.version="tensorflow${TF_VERSION}-rocm${ROCM_VERSION}-mpich${MPICH_VERSION}-ubuntu${OS_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers"
LABEL au.org.pawsey.image.build-info-dir="${IMAGE_BUILD_INFO_DIR}"


#================================================================
# A. Base image
#================================================================
#
# Use the Pawsey ROCm + MPICH base image.
#
#---------------------------------------------------------------

FROM quay.io/pawsey/rocm-mpich-base:rocm${ROCM_VERSION}-mpich${MPICH_VERSION}-lustrerelease-ubuntu${OS_VERSION}


#---------------------------------------------------------------
# A.0 Recall global build arguments
#---------------------------------------------------------------

ARG OS_VERSION
ARG ROCM_VERSION
ARG MPICH_VERSION

ARG TF_VERSION
ARG HOROVOD_VERSION

ARG AMDGPU_TARGETS

ARG PYTHON_TF215_VERSION
ARG PYTHON_TF221_VERSION

ARG APT_GET_APPS

ARG IMAGE_BUILD_INFO_DIR
ARG INTERNAL_BUILD_INFO_SUBDIR


#================================================================
# B. Configure ROCm environment
#================================================================
#
# Configure the ROCm installation and target AMD GPU architecture.
#
#---------------------------------------------------------------

ENV ROCM_PATH=/opt/rocm
ENV HCC_AMDGPU_TARGET=${AMDGPU_TARGETS}


#---------------------------------------------------------------
# B.1 Restrict ROCm architecture detection
#---------------------------------------------------------------
#
# The image may be built on a system where the target GPU is not
# visible. Override rocm_agent_enumerator so that ROCm/TensorFlow
# build scripts consistently use the requested architecture.
#
#---------------------------------------------------------------

RUN set -eux; \
    cd /opt/rocm/bin; \
    mv rocm_agent_enumerator rocm_agent_enumerator_old; \
    printf '%s\n' "echo ${AMDGPU_TARGETS}" > rocm_agent_enumerator; \
    chmod 0777 rocm_agent_enumerator


#================================================================
# C. Configure Python/pip
#================================================================
#
# Ubuntu 24.04 protects the system Python installation using
# PEP 668. Allow pip to install packages into the system
# environment.
#
#---------------------------------------------------------------

RUN set -eux; \
    mkdir -p /root/.config/pip; \
    printf '%s\n' \
        '[global]' \
        'break-system-packages = true' \
        > /root/.config/pip/pip.conf


#================================================================
# D. Install TensorFlow
#================================================================
#
# TensorFlow ROCm wheels are provided by AMD through the ROCm
# package repository.
#
# TensorFlow 2.15.x requires Python 3.10, while the TensorFlow
# 2.21.x wheel used here requires Python 3.12.
#
# The existing recipe therefore installs Python 3.10 only when
# TensorFlow 2.15.x is requested.
#
#---------------------------------------------------------------

RUN set -eux; \
    echo "Building TensorFlow ${TF_VERSION}"; \
    \
    # Install common system packages for both TensorFlow versions \
    apt-get update -qq; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends \
        wget \
        git \
        build-essential \
	openssl \
        ${APT_GET_APPS}; 

RUN set -eux; \
    tf_major="$(echo "${TF_VERSION}" | cut -d. -f1)"; \
    tf_minor="$(echo "${TF_VERSION}" | cut -d. -f2)"; \
    \
    if [ "${tf_minor}" -eq 15 ]; then \
        \
        #-------------------------------------------------------
        # D.1 Dependencies required to build Python 3.10
        #-------------------------------------------------------
        #
        # These packages are required to build Python 3.10 on
        # Ubuntu 24.04.
        #
        apt-get update -qq; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends \
            libbz2-dev \
            libdb-dev \
            libgdbm-dev \
            libgdbm-compat-dev \
            liblzma-dev \
            libsqlite3-dev \
            libncurses-dev \
            libffi-dev \
            uuid-dev \
            tk-dev \
            xz-utils \
            libnss3-dev \
            libexpat1-dev \
            libtirpc-dev \
            libnsl-dev \
            ${APT_GET_APPS}; \
        \
        #-------------------------------------------------------
        # D.2 Build Python 3.10
        #-------------------------------------------------------
        \
        mkdir -p /tmp/python-build; \
        cd /tmp/python-build; \
        \
        wget -q \
            "https://www.python.org/ftp/python/${PYTHON_TF215_VERSION}/Python-${PYTHON_TF215_VERSION}.tgz"; \
        \
        tar xzf "Python-${PYTHON_TF215_VERSION}.tgz"; \
        cd "Python-${PYTHON_TF215_VERSION}"; \
        \
        ./configure \
            --prefix=/usr \
            --exec-prefix=/usr \
            --bindir=/usr/bin \
            --libdir=/usr/lib \
            --includedir=/usr/include \
            --enable-optimizations \
            --enable-shared; \
        \
        make -j4; \
        make altinstall; \
        \
        #-------------------------------------------------------
        # D.3 Select Python 3.10
        #-------------------------------------------------------
        \
        update-alternatives \
            --install /usr/bin/python3 python3 /usr/bin/python3.12 1; \
        \
        update-alternatives \
            --install /usr/bin/python3 python3 /usr/bin/python3.10 2; \
        \
        update-alternatives \
            --set python3 /usr/bin/python3.10; \
        \
        #-------------------------------------------------------
        # D.4 Install TensorFlow 2.15.1
        #-------------------------------------------------------
        \
        cd /tmp; \
        wget -q \
            "https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION}/tensorflow_rocm-2.15.1-cp310-cp310-manylinux_2_28_x86_64.whl"; \
        \
        python3 -m pip install \
            --prefix=/usr \
            --upgrade \
            --no-cache-dir \
            "tensorflow_rocm-2.15.1-cp310-cp310-manylinux_2_28_x86_64.whl"; \
        \
        rm -rf /tmp/python-build \
               "/tmp/tensorflow_rocm-2.15.1-cp310-cp310-manylinux_2_28_x86_64.whl"; \
        \
        apt-get clean; \
        rm -rf /var/lib/apt/lists/*; \
    \
    else \
        \
        #-------------------------------------------------------
        # D.5 Install TensorFlow 2.21.x
        #-------------------------------------------------------
        \
        cd /tmp; \
        wget -q \
            "https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION}/tf_nightly_rocm-${TF_VERSION}.dev0+selfbuilt-cp312-cp312-manylinux_2_28_x86_64.whl"; \
        \
        python3 -m pip install \
            --break-system-packages \
            --prefix=/usr \
            --no-cache-dir \
            --ignore-installed \
            "numpy==1.26.4" \
             "scipy<1.14" \
            "tf_nightly_rocm-${TF_VERSION}.dev0+selfbuilt-cp312-cp312-manylinux_2_28_x86_64.whl"; \
        \
        rm -f \
            "/tmp/tf_nightly_rocm-${TF_VERSION}.dev0+selfbuilt-cp312-cp312-manylinux_2_28_x86_64.whl"; \
    \
    fi


#================================================================
# E. Configure Horovod
#================================================================
#
# Horovod is built with:
#
#   - ROCm GPU support
#   - RCCL collective communication
#   - TensorFlow support
#   - MPICH provided by the base image
#
# Horovod 0.28.1 in this recipe is currently used with the
# TensorFlow 2.15.x configuration.
#
#---------------------------------------------------------------

ENV HOROVOD_WITHOUT_MXNET=1
ENV HOROVOD_WITHOUT_PYTORCH=1
ENV HOROVOD_GPU=ROCM
ENV HOROVOD_GPU_OPERATIONS=NCCL
ENV HOROVOD_WITHOUT_GLOO=1
ENV HOROVOD_WITH_TENSORFLOW=1

ENV HOROVOD_ROCM_PATH=/opt/rocm
ENV HOROVOD_RCCL_HOME=/opt/rocm/rccl

ENV RCCL_INCLUDE_DIRS=/opt/rocm/rccl/include
ENV HOROVOD_RCCL_LIB=/opt/rocm/rccl/lib


#================================================================
# F. Build and install Horovod
#================================================================
#
# The existing Pawsey recipe notes that the current Horovod
# configuration is not compatible with TensorFlow versions newer
# than 2.15.
#
# Therefore, only build Horovod when TensorFlow 2.15.x is selected.
#
#---------------------------------------------------------------

RUN set -eux; \
    tf_minor="$(echo "${TF_VERSION}" | cut -d. -f2)"; \
    \
    if [ "${tf_minor}" -eq 15 ]; then \
        \
        mkdir -p /tmp/horovod-build; \
        cd /tmp/horovod-build; \
        \
        #-------------------------------------------------------
        # F.1 Obtain Horovod source
        #-------------------------------------------------------
        \
        git clone \
            --recursive \
            https://github.com/horovod/horovod.git; \
        \
        cd horovod; \
        \
        #-------------------------------------------------------
        # F.2 Remove previous build artefacts
        #-------------------------------------------------------
        \
        rm -rf \
            build/ \
            horovod.egg-info/ \
            dist/; \
        \
        #-------------------------------------------------------
        # F.3 Make the ROCm HIP CMake module available
        #-------------------------------------------------------
        \
        ln -s \
            "${ROCM_PATH}"/lib/cmake/hip/FindHIP* \
            cmake/Modules/; \
        \
        #-------------------------------------------------------
        # F.4 Fix RCCL include path
        #-------------------------------------------------------
        \
        sed -i \
            's/rccl\.h/rccl\/rccl\.h/' \
            horovod/common/ops/nccl_operations.h; \
        \
        #-------------------------------------------------------
        # F.5 Build Horovod wheel
        #-------------------------------------------------------
        \
        python3 setup.py bdist_wheel; \
        \
        #-------------------------------------------------------
        # F.6 Install Horovod
        #-------------------------------------------------------
        \
        python3 -m pip install \
            --ignore-installed \
            --force-reinstall \
            --no-cache-dir \
            "dist/horovod-${HOROVOD_VERSION}-cp310-cp310-linux_x86_64.whl"; \
        \
        rm -rf /tmp/horovod-build; \
    \
    else \
        echo "Horovod is not installed for TensorFlow ${TF_VERSION}"; \
    \
    fi


#================================================================
# G. Container build information
#================================================================
#
# Keep the Dockerfile used to build the image inside the image.
# This follows the Pawsey container build-info convention.
#
#---------------------------------------------------------------

ARG INTERNAL_BUILD_INFO_SUBDIR

RUN set -eux; \
    mkdir -p "${INTERNAL_BUILD_INFO_SUBDIR}"

COPY tensorflow.dockerfile "${INTERNAL_BUILD_INFO_SUBDIR}/"


#================================================================
# H. Runtime environment
#================================================================
#
# These variables are added to the Singularity/Apptainer runtime
# environment so that they are available when the container is
# executed on Setonix.
#
#---------------------------------------------------------------

RUN set -eux; \
    printf '%s\n' \
        'export TF_CPP_MIN_LOG_LEVEL=3' \
        'export ROCM_PATH=/opt/rocm' \
        >> /.singularity.d/env/91-environment.sh


#================================================================
# I. Clean up
#================================================================
#
# Remove temporary build directories.
#
#---------------------------------------------------------------

RUN set -eux; \
    rm -rf /tmp/build \
           /tmp/python-build \
           /tmp/horovod-build
