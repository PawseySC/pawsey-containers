# This Dockerfile builds an Ubuntu-based container image with MPICH and ROCm, 
# ABI compatible with Cray-MPICH, enabling MPI applications to run on AMD GPUs on HPE Cray EX systems.
# It installs a minimal build/runtime environment,
# compiles: 
#    - CMake requred for ROCm, 
#    - Lustre libraries to allow correct MPI I/O,
#    - Libfabric required for adding RCCL,
#    - MPICH from source with OFI support, 
#    - rocm,
#    - mpi4py, 
#    - aws-ofi-rccl,
#    - OSU Micro-Benchmarks, and 
#    - additional Pawsey MPI test utilities.
# The recipe does not start FROM mpich-base:<tag> image because Lustre libraries
# need to be installed before the MPI installation.
# Build-time arguments allow the Ubuntu, MPICH, and benchmark versions to be
# overridden without modifying the recipe.
# (When updating this image, don't forget to double check that labels are also updated accordingly)
    
#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition of global parameters
# IMPORTANT: All these settings can be overridden with the use of `--build-arg <Name>=<Value>`
# IMPORTANT: Recipe needs to re-call them at each stage to recover their values

# 0.1 Main global arguments related to versions used
ARG OS_VERSION="24.04"
ARG BASE_IMAGE_FULL="ubuntu:${OS_VERSION}"
ARG MPICH_VERSION="4.2.2"
ARG MPICH_SHA256="883f5bb3aeabf627cb8492ca02a03b191d09836bbe0f599d8508351179781d41"
ARG MPI4PY_VERSION="4.1.2"
ARG OSU_BENCHMARKS_VERSION="7.3"
#ARG PROFILE_UTIL_VERSION="v1.0"
ARG PROFILE_UTIL_VERSION="main"
ARG GCC_VERSION="12"
ARG LINUX_KERNEL="6.8.0-31"
ARG LINUX_KERNEL_MAJOR="6.8.0"
ARG LIBFABRIC_VERSION="1.18.1"
ARG LUSTRE_VERSION="release"
#ARG LUSTRE_VERSION="2.15"
ARG ROCM_VERSION="7.0.1"
ARG CMAKE_VERSION="3.31.7"
ARG ARCH="amd64"
ARG GFX_ARCH=gfx90a

# 0.2 Other auxiliary variables to ease building
ARG DOCKER_RECIPES_DIR="/opt/docker-recipes"


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# A. Basic Stage

FROM ${BASE_IMAGE_FULL} AS basic_stage

#---------------------------------------------------------------
# A.0 Recall global definitions made at the top
ARG MPICH_VERSION
ARG OS_VERSION
ARG DOCKER_RECIPES_DIR
ARG GCC_VERSION
ARG LINUX_KERNEL
ARG ROCM_VERSION
ARG LUSTRE_VERSION

#---------------------------------------------------------------
# A.1 Defining documented labels
LABEL org.opencontainers.image.authors="Pascal Jahan Elahi <pascal.elahi@pawsey.org.au>, Alexis Espinosa <alexis.espinosa@pawsey.org.au>, Craig Meyer <cmeyer@pawsey.org.au>, Deva Deeptimahanti <deva.deeptimahanti@pawsey.org.au>"
LABEL org.opencontainers.image.name="rocm-mpich-base"
LABEL org.opencontainers.image.branch="rocm${ROCM_VERSION}-mpich${MPICH_VERSION}-lustre${LUSTRE_VERSION}-ubuntu${OS_VERSION}"
LABEL org.opencontainers.image.dockerfile-internal-backup="${DOCKER_RECIPES_DIR}"
LABEL org.opencontainers.image.git-repository="https://github.com/PawseySC/pawsey-containers"

#---------------------------------------------------------------
# A.2 Installing basic requirements

RUN set -eux; \
    DEBIAN_FRONTEND=noninteractive apt-get update; \
    apt-get -y --no-install-recommends install \
    build-essential \
    gnupg \
    gnupg2 \
    ca-certificates \
    gdb \
    gcc-${GCC_VERSION} \
    g++-${GCC_VERSION} \
    gfortran-${GCC_VERSION} \
    wget \
    git \
    python3-six \
    python3-setuptools \
    patchelf \
    strace \
    ltrace \
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
    libtool \
    m4 \
    make \
    openssh-server \
    patch \
    python3-numpy \
    python3-pip \
    python3-scipy \
    python3-venv \
    subversion \
    tzdata \
    valgrind \
    vim \
    xsltproc \
    zlib1g-dev \
    ninja-build \
    libnuma-dev \
    swig \
    linux-tools-generic \
    linux-source \
    software-properties-common \
    libkeyutils-dev \
    libnl-genl-3-dev \
    libyaml-dev \
    linux-headers-${LINUX_KERNEL}-generic \
    linux-headers-${LINUX_KERNEL} \
    libmount-dev \
    pkg-config \
    cmake \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# B. Build CMake to make sure it will work with ROCm
# 4.x breaks stuff
FROM basic_stage AS build_cmake
#---------------------------------------------------------------
# B.0 Recall global definitions made at the top
ARG CMAKE_VERSION

#---------------------------------------------------------------
# B.1 Build CMake

ENV PATH=/usr/cmake-${CMAKE_VERSION}-linux-x86_64/bin:$PATH

RUN set -eux; \
    apt -y remove --purge --auto-remove cmake; \
    wget https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.sh; \
    chmod a+x cmake-${CMAKE_VERSION}-linux-x86_64.sh && yes | ./cmake-${CMAKE_VERSION}-linux-x86_64.sh --prefix=/usr; \
    cmake --version 


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# C. Generate a Kernel config for building Lustre
FROM build_cmake AS build_lustre_config
#---------------------------------------------------------------
# C.0 Recall global definitions made at the top
ARG LINUX_KERNEL_MAJOR
ARG ARCH

#---------------------------------------------------------------
# C.1 Ggenerate a kernel config file

# CMEYER: ./debian/scripts/misc/annotations not present in ubuntu24.04 by default, this is workaround
RUN set -eux; \
    echo "deb-src http://archive.ubuntu.com/ubuntu noble main restricted" >> /etc/apt/sources.list; \
    apt-get update -qq;\
    apt-get install -y --no-install-recommends build-essential fakeroot devscripts dpkg-dev;\
    apt-get source linux; \
    cd linux-${LINUX_KERNEL_MAJOR}; \
    chmod +x ./debian/scripts/misc/annotations; \
    ./debian/scripts/misc/annotations \
        --arch ${ARCH} --flavour generic --export > .config 



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# D. Generate a Kernel config for building Lustre
FROM build_lustre_config AS build_libfabric
#---------------------------------------------------------------
# D.0 Recall global definitions made at the top
ARG LIBFABRIC_VERSION

#---------------------------------------------------------------
# D.1 Ggenerate a kernel config file

# Build and install libfabric, required for adding rccl
RUN set -eux; \
    (if [ -e /tmp/build ]; then rm -rf /tmp/build; fi;); \
    mkdir -p /tmp/build; \
    cd /tmp/build; \
    wget https://github.com/ofiwg/libfabric/archive/refs/tags/v${LIBFABRIC_VERSION}.tar.gz; \
    tar xf v${LIBFABRIC_VERSION}.tar.gz; \
    cd libfabric-${LIBFABRIC_VERSION}; \ 
    ./autogen.sh; \
    ./configure; \
    make -j 16; \ 
    make install; \
    rm -rf /tmp/build/v${LIBFABRIC_VERSION}.tar.gz; \
    rm -rf /tmp/build/libfabric-${LIBFABRIC_VERSION} 



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# E. Build Lustre
FROM build_libfabric AS build_lustre
#---------------------------------------------------------------
# E.0 Recall global definitions made at the top
ARG LINUX_KERNEL
ARG LUSTRE_VERSION

#---------------------------------------------------------------
# E.1 Build LUSTRE
ARG LUSTRE_CONFIG_ARGS="--with-linux=/usr/lib/modules/${LINUX_KERNEL}-generic/build --disable-tests CFLAGS=-Wno-error=attribute-warning"

RUN set -eux; \
    mkdir -p /tmp/lustre-build; \
    cd /tmp/lustre-build; \
    git clone https://github.com/lustre/lustre-${LUSTRE_VERSION}.git; \
    cd lustre-${LUSTRE_VERSION}; \
    # there appears to be an odd error with some release not being able to configure.
    # for the moment, just use the main branch rather than a particular version.
    #git fetch --tags; \
    #git checkout "${LUSTRE_VERSION}"; \
    chmod +x ./autogen.sh; \
    ./autogen.sh; \
    ./configure --disable-server --enable-client ${LUSTRE_CONFIG_ARGS}; \
    make -j8; \
    make install; \
    rm -rf /tmp/lustre-build


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# F. Build MPICH
FROM build_lustre AS build_mpich
#---------------------------------------------------------------
# F.0 Recall global definitions made at the top
ARG MPICH_VERSION
ARG MPICH_SHA256
ARG GCC_VERSION
#---------------------------------------------------------------
# F.1 Build MPICH
ARG MPICH_CONFIGURE_OPTIONS="\
    --without-mpe \
    --enable-fortran=all \
    --enable-shared \
    --enable-sharedlibs=gcc \
    --enable-debuginfo \
    --enable-yield=sched_yield \
    --enable-g=mem \
    --with-device=ch4:ofi \
    --with-namepublisher=file \
    --with-shared-memory=sysv \
    --disable-allowport \
    --with-pm=gforker \
    --with-file-system=ufs+lustre+nfs \
    --enable-threads=runtime \
    --enable-fast=O2 \
    --enable-thread-cs=global \
    CC=gcc-${GCC_VERSION} \
    CXX=g++-${GCC_VERSION} \
    FC=gfortran-${GCC_VERSION} \
    FFLAGS=-fallow-argument-mismatch"
ARG MPICH_MAKE_OPTIONS="-j16"

RUN set -eux; \
    mkdir -p /tmp/mpich-build; \
    cd /tmp/mpich-build; \
    wget "https://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz"; \
    echo "${MPICH_SHA256}  mpich-${MPICH_VERSION}.tar.gz" | sha256sum -c -; \
    tar xzvf "mpich-${MPICH_VERSION}.tar.gz"; \
    cd "mpich-${MPICH_VERSION}"; \
    sed -i "/Error use MPL_/d" src/mpl/include/mpl_trmem.h; \
    ./configure ${MPICH_CONFIGURE_OPTIONS}; \
    make ${MPICH_MAKE_OPTIONS}; \
    make install; \
    ldconfig; \
    cp -p "/tmp/mpich-build/mpich-${MPICH_VERSION}/examples/cpi" /usr/bin/; \
    rm -rf /tmp/mpich-build



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# G. Install mpi4py
FROM build_mpich AS install_mpi4py
#---------------------------------------------------------------
# G.0 Recall global definitions made at the top
ARG MPI4PY_VERSION

#---------------------------------------------------------------
# G.1 Add mpi4py in the container
RUN set -eux; \
    MPICC=/usr/bin/mpicc python3 -m pip install \
        --no-cache-dir \
        --no-binary=mpi4py \
        --break-system-packages \
        "mpi4py==${MPI4PY_VERSION}"



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# H. Install ROCm
# Note that version to installer version incomplete
# CMEYER: Need to add jammy repo to sources list in ubuntu24.04 to get libraries
# needed for rocm. rocm-gdb (pulled in by the rocm usecase) depends on libtinfo5 /
# libncurses5 / libpython3.10, none of which exist on noble (24.04). They are
# satisfied from the jammy repo, which is the same repo amdgpu-install pulls rocm
# from for rocm 5.x and rocm 6.x < 6.2 — so install the compat libs in those cases.

FROM install_mpi4py AS build_rocm
#---------------------------------------------------------------
# H.0 Recall global definitions made at the top
ARG ROCM_VERSION
ARG GFX_ARCH
#---------------------------------------------------------------
# H.1 Install ROCm 

RUN apt -y update
RUN apt -y upgrade
RUN apt -y install rsync
RUN set -eux; \
    rocm_major=$(echo ${ROCM_VERSION} | sed "s/\./ /g" | awk '{print $1}'); \
    rocm_minor=$(echo ${ROCM_VERSION} | sed "s/\./ /g" | awk '{print $2}'); \
    if [ "$rocm_major" -eq 5 ] || { [ "$rocm_major" -eq 6 ] && [ "$rocm_minor" -lt 2 ]; }; then \
       { \
            echo "deb http://archive.ubuntu.com/ubuntu jammy main universe" > /etc/apt/sources.list.d/jammy.list \
            apt-get update -qq \
            apt-get -y --no-install-recommends install \
                libtinfo5 libncurses5 libpython3.10; \
        }; \
     fi

RUN set -eux; \
    rocm_major=$(echo ${ROCM_VERSION} | sed "s/\./ /g" | awk '{print $1}'); \
    rocm_minor=$(echo ${ROCM_VERSION} | sed "s/\./ /g" | awk '{print $2}'); \
    ROCM_INSTALLER_VERSION=$(echo ${ROCM_VERSION} | sed "s/\./0/g"); \
    # if rocm version does not list minor patch version number add 00 to end of installer version
    if [ $(echo ${ROCM_VERSION} | sed "s/\./\n/g" | wc -l) -eq "2" ]; then ROCM_INSTALLER_VERSION=${ROCM_INSTALLER_VERSION}"00"; fi; \
    ROCM_INSTALLER_VERSION=${ROCM_INSTALLER_VERSION}"-1"; \
    if [ $rocm_major -ge 7 ]; then ROCM_INSTALLER_VERSION=${ROCM_VERSION}.${ROCM_INSTALLER_VERSION}; \
       else \
        ROCM_INSTALLER_VERSION=${rocm_major}.${rocm_minor}.${ROCM_INSTALLER_VERSION}; fi; \
    cd /tmp/build; \
    # wget https://bootstrap.pypa.io/get-pip.py \
    # python3 get-pip.py \
    # CMEYER: Need jammy for < rocm6.2, noble for > rocm6.2
    if [ "$rocm_major" -lt 6 ] || { [ "$rocm_major" -eq 6 ] && [ "$rocm_minor" -lt 2 ]; }; then \
        roc_url="https://repo.radeon.com/amdgpu-install/"${ROCM_VERSION}"/ubuntu/jammy/amdgpu-install_"${ROCM_INSTALLER_VERSION}"_all.deb"; \
       else \
        roc_url="https://repo.radeon.com/amdgpu-install/"${ROCM_VERSION}"/ubuntu/noble/amdgpu-install_"${ROCM_INSTALLER_VERSION}"_all.deb"; \
       fi; \
    # roc_url="https://repo.radeon.com/amdgpu-install/7.0.1/ubuntu/noble/amdgpu-install_7.0.1.70001-1_all.deb" \
    echo ${roc_url}; \
    wget ${roc_url}; \
    apt -y install ./amdgpu-install_*_all.deb; \
    # CMEYER: Adding --no-dkms - older rocm versions fail without it and seems to be recommended by amd
    # CMEYER: See https://rocmdocs.amd.com/projects/install-on-linux/en/latest/install/install-methods/amdgpu-installer/amdgpu-installer-ubuntu.html and https://github.com/amd/InfinityHub-CI/blob/55ffdd622595cf678fb55fce7681792390173f3d/base-mpich-rocm-docker/Dockerfile#L47
    amdgpu-install -y --usecase=hiplibsdk,rocm,hip,opencl --no-dkms; \
    cd /tmp/build; \
    rm -rf amdgpu-install_*_all.deb 


# modify the rocm_agent_enumerator and andgpu-arch executables to detect the gfx90a architecture regardless of whether it is present on
# the system or not. This is useful to build containers optimised for the gfx90a architecture on machines with no GPUs.
RUN set -eux; \
    cd /opt/rocm/bin; \
    mv rocm_agent_enumerator rocm_agent_enumerator_old; \
    echo "echo ${GFX_ARCH}" >> rocm_agent_enumerator; \
    chmod 0777 rocm_agent_enumerator;

RUN set -eux; \
    cd /opt/rocm/lib/llvm/bin; \
    mv amdgpu-arch amdgpu-arch.old;  \
    echo "echo ${GFX_ARCH}" >> amdgpu-arch; \
    chmod 0777 amdgpu-arch;



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# I. Install aws-ofi-rccl
FROM build_rocm AS build_rccl
#---------------------------------------------------------------
# I.0 Recall global definitions made at the top
ARG ROCM_VERSION
ARG GCC_VERSION

#---------------------------------------------------------------
# I.1 Install aws-ofi-rccl

ARG RCCL_CONFIGURE_OPTIONS="--prefix=/usr --with-mpi=/usr --with-libfabric=/usr --with-hip=/opt/rocm --with-rccl=/opt/rocm CC=gcc-${GCC_VERSION} CXX=g++-${GCC_VERSION}"

RUN set -eux; \
    rocm_major=$(echo ${ROCM_VERSION} | sed "s/\./ /g" | awk '{print $1}'); \
    gitrepo=https://github.com/ROCmSoftwarePlatform/aws-ofi-rccl.git; \
    # before rccl was not compatible with 6.0.2 till there was a PR that was merged. 
    #Leaving this to document that something similar could be ncessary in the future
    # if [ "${rocm_major}" = "6" ]; then gitrepo=https://github.com/teojgo/aws-ofi-rccl.git; RCCL_CONFIGURE_OPTIONS=${RCCL_CONFIGURE_OPTIONS}" CFLAGS=-D__HIP_PLATFORM_AMD__ CXXFLAGS=-D__HIP_PLATFORM_AMD__"; fi \
    # now just need to ensure that adding __HIP_PLATFORM_AMD__ to compilation as that was not being set in the 6.0.2 installation

    if [ "${rocm_major}" -ge "6" ]; then RCCL_CONFIGURE_OPTIONS=${RCCL_CONFIGURE_OPTIONS}" CFLAGS=-D__HIP_PLATFORM_AMD__ CXXFLAGS=-D__HIP_PLATFORM_AMD__"; fi; \
    git clone ${gitrepo}; \
    cd aws-ofi-rccl; \
    # this is only valid when was grabbing a fork for a fix. 
    # if [ "${rocm_major}" = "6" ]; then git checkout rocm60_memorytype_fix; fi \
    ./autogen.sh; \
    ./configure ${RCCL_CONFIGURE_OPTIONS}; \
    make -j 16; \
    make install; \
    cd /tmp; \
    rm -rf /tmp/build 


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# J. Install OSU benchmarks
FROM build_rccl AS build_osu
#---------------------------------------------------------------
# J.0 Recall global definitions made at the top
ARG OSU_BENCHMARKS_VERSION
ARG ROCM_VERSION

#---------------------------------------------------------------
# J.1 Build OSU Benchmarks
ARG OSU_CONFIGURE_OPTIONS="--prefix=/usr/local \
	CC=mpicc CXX=mpicxx \
	CFLAGS=-O3 \
	 --enable-rocm --with-rocm=/opt/rocm"

ARG OSU_MAKE_OPTIONS="-j16"

RUN set -eux; \
    rocm_major=$(echo ${ROCM_VERSION} | sed "s/\./ /g" | awk '{print $1}'); \
	mkdir -p /tmp/osu-benchmark-build; \
	cd /tmp/osu-benchmark-build; \
	wget http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_BENCHMARKS_VERSION}.tar.gz; \
	tar xzvf osu-micro-benchmarks-${OSU_BENCHMARKS_VERSION}.tar.gz; \
	cd osu-micro-benchmarks-${OSU_BENCHMARKS_VERSION}; \
    if [ "${rocm_major}" -ge "6" ]; then OSU_CONFIGURE_OPTIONS=${OSU_CONFIGURE_OPTIONS}" CFLAGS=-D__HIP_PLATFORM_AMD__ CXXFLAGS=-D__HIP_PLATFORM_AMD__"; fi; \
	./configure ${OSU_CONFIGURE_OPTIONS}; \
	make ${OSU_MAKE_OPTIONS}; \
	make install; \
	rm -rf /tmp/osu-benchmark-build 

ENV PATH="/usr/local/libexec/osu-micro-benchmarks/mpi/collective:/usr/local/libexec/osu-micro-benchmarks/mpi/one-sided:/usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt:/usr/local/libexec/osu-micro-benchmarks/mpi/startup:$PATH"


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# K. Install other tests
FROM build_osu AS other_tests
#---------------------------------------------------------------
# K.0 Recall global definitions made at the top
ARG PROFILE_UTIL_VERSION

#---------------------------------------------------------------
# K.1 Add a more complex set of tests for MPI as well
# Cache invalidation helper to neglect cache use in the RUN..cmake instruction if the repository has changed:

#ADD "https://api.github.com/repos/PawseySC/profile_util/commits/${PROFILE_UTIL_VERSION}" /tmp/profile_util_commit.json
#RUN set -eux; \
#    mkdir -p /opt/; \
#    cd /opt/; \
#    git clone --branch "${PROFILE_UTIL_VERSION}" --depth 1 https://github.com/PawseySC/profile_util; \
#    cd profile_util; \
#    sed -i "s:CXX=CC:CXX=g++:g" ./build_cpu.sh; \
#    sed -i "s:MPICXX=CC:MPICXX=mpic++:g" ./build_cpu.sh; \
#    sed -i "s:MPICXX=CC:MPICXX=mpic++:g" ./build_hip.sh; \
#    ./build_hip.sh; \
#    cd examples/mpi/; \
#    make MPICXX=mpic++; \
#    cd ../../examples/openmp; \
#    make CXX=g++ bin/openmpvec_cpp; \
#    cd ../../examples/gpu-mpi/; \
#    make 



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# L. Final settings
FROM other_tests AS final_settings
#---------------------------------------------------------------
# L.0 Recall global definitions made at the top
ARG DOCKER_RECIPES_DIR

#---------------------------------------------------------------
# L.1 Set some environment variables related to gpu communication and libfabric
ENV NCCL_SOCKET_IFNAME=hsn
ENV HSA_FORCE_FINE_GRAIN_PCIE=1
ENV FI_CXI_DISABLE_CQ_HUGETLB=1
ENV ROCM_PATH=/opt/rocm

# L.2 Singularity: will execute scripts in /.singularity.d/env/ at startup (and ignore those in /etc/profile.d/).
#              Standard naming of "environment" scripts is 9X-environment.sh
RUN mkdir -p /.singularity.d/env/
RUN echo "export NCCL_SOCKET_IFNAME=hsn"  >> /.singularity.d/env/91-environment.sh \
    echo "export ROCM_PATH=/opt/rocm"  >> /.singularity.d/env/91-environment.sh \
    echo "export HSA_FORCE_FINE_GRAIN_PCIE=1" >> /.singularity.d/env/91-environment.sh \
    echo "export FI_CXI_DISABLE_CQ_HUGETLB=1" >> /.singularity.d/env/91-environment.sh


# L.3 Copy the recipe into the docker recipes directory
RUN set -eux; \
    mkdir -p "${DOCKER_RECIPES_DIR}"
COPY buildrocm-mpich-base.dockerfile "${DOCKER_RECIPES_DIR}"
