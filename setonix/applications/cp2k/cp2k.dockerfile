# NOTE: This container uses the AMD Infinityhub CP2K dockerfile as a starting point - see https://github.com/amd/InfinityHub-CI/blob/main/cp2k/docker/Dockerfile

# Build with mpich and rocm/7.0.1
FROM quay.io/pawsey/rocm-mpich-base:rocm7.0.1-mpich4.2.2-lustrerelease-ubuntu24.04

ARG APT_GET_APPS=""
ARG AMDGPU_TARGETS="gfx90a"

# Update and Install basic Linux development tools
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        ssh \
        make \
        vim \
        nano \
        libtinfo-dev\
        initramfs-tools \
        libelf-dev \
        numactl \
        curl \
        wget \
        tmux \
        build-essential \
        autoconf \
        automake \
        cmake \
        gcc-12 \
        g++-12 \
        libtool \
        pkg-config \
        libnuma-dev \
        gfortran \
        flex \
        hwloc \
        gfortran-12 \
        libstdc++-12-dev \
        libxml2-dev \
        python3-dev \
        python3-pip \
        unzip ${APT_GET_APPS}\
    && apt-get clean

RUN rm /usr/bin/gcc /usr/bin/g++ /usr/bin/gfortran
RUN ln -s /usr/bin/gcc-12 /usr/bin/gcc
RUN ln -s /usr/bin/g++-12 /usr/bin/g++
RUN ln -s /usr/bin/gfortran-12 /usr/bin/gfortran

ENV ROCM_PATH=/opt/rocm \
    AMDGPU_TARGETS=${AMDGPU_TARGETS}

# Adding rocm/cmake to the Environment
ENV PATH=$ROCM_PATH/bin:/opt/cmake/bin:$PATH \
    LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:$ROCM_PATH/llvm/lib:$ROCM_PATH/lib/llvm/lib:$LD_LIBRARY_PATH \
    LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:$LIBRARY_PATH \
    C_INCLUDE_PATH=$ROCM_PATH/include:$C_INCLUDE_PATH \
    CPLUS_INCLUDE_PATH=$ROCM_PATH/include:$CPLUS_INCLUDE_PATH \
    CMAKE_PREFIX_PATH=$ROCM_PATH/lib/cmake:$CMAKE_PREFIX_PATH

ENV LD_LIBRARY_PATH=$ROCM_PATH/lib/hipblas:$ROCM_PATH/lib/hipfft:$ROCM_PATH/lib/rocfft:$ROCM_PATH/lib/rocblas:$LD_LIBRARY_PATH \
    LIBRARY_PATH=$ROCM_PATH/lib/rocfft:$ROCM_PATH/lib/hipblas:$ROCM_PATH/lib/rocblas:$LIBRARY_PATH \
    C_INCLUDE_PATH=$ROCM_PATH/include/rocfft:$ROCM_PATH/include/hipblas:$ROCM_PATH/include/hipfft:$ROCM_PATH/include/rocblas:$C_INCLUDE_PATH \
    CPLUS_INCLUDE_PATH=$ROCM_PATH/include/rocfft:$ROCM_PATH/include/hipfft:$ROCM_PATH/include/hipblas:$ROCM_PATH/include/rocblas:$CPLUS_INCLUDE_PATH \
    CP2K_DIR=/opt/cp2k


WORKDIR /opt/


# clone spack.
RUN git clone https://github.com/spack/spack.git
ENV PATH=$PATH:/opt/spack/bin
RUN spack external find --all
RUN gfortran --version
COPY ./cp2k_environment ./cp2k_environment
COPY ./spack.sh ./spack.sh
COPY /scripts /scripts
RUN chmod -R 777 /scripts

# the entire configuration is treated externally using spack environments
RUN ./spack.sh

ENV PATH=$PATH:/opt/cp2k/bin:/scripts

# cp2k can be called with cp2k.psmp without without any spack knowledge
CMD ["/bin/bash"]

