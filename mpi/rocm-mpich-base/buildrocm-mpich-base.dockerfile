ARG OS_VERSION="22.04"
FROM ubuntu:${OS_VERSION}
# redefine after FROM to ensure it is defined
ARG OS_VERSION="22.04"

#libfabric version 
ARG LIBFABRIC_VERSION=1.18.1
# mpich version
ARG MPICH_VERSION="3.4.3"
# lustre version
ARG LUSTRE_VERSION="2.15.0-RC4"
# mpi4py version
ARG MPI4PY_VERSION="3.1.4"


#define some metadata 
LABEL org.opencontainers.image.created="2024-02"
LABEL org.opencontainers.image.authors="Cristian Di Pietratonio <cristian.dipietrantonio@pawsey.org.au>, Pascal Elahi <pascal.elahi@pawsey.org.au>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/mpi/mpich-base/buildmpich.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Setonix compatible MPICH + ROCM base"
LABEL org.opencontainers.image.description="Common base image providing mpi + rocm compatible with cray-mpich used on Setonix"
LABEL org.opencontainers.image.base.name="pawsey/mpibase:ubuntu${OS_VERSION}-mpich-${MPICH_VERSION}.setonix"

# Install required packages and dependencies
ARG LINUX_KERNEL=5.15.0-91
# for newer ubuntu might want to use newer kernels like 6.2.0-39
ENV DEBIAN_FRONTEND="noninteractive"
RUN echo "Install apt packages" \
    && apt-get update -qq \
    && apt-get -y --no-install-recommends install \
        build-essential \
        gnupg gnupg2 \
        ca-certificates \
        gdb \
        gcc-12 g++-12 gfortran-12 \
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
        python3-venv \
        subversion \
        tzdata \
        valgrind \
        vim \
        wget \
        xsltproc \
        zlib1g-dev \
        ninja-build \
        libnuma-dev \
        swig \
        linux-tools-generic \
        linux-source \
        software-properties-common \
        libkeyutils-dev libnl-genl-3-dev libyaml-dev \
        # get the headers as well 
        linux-headers-${LINUX_KERNEL}-generic linux-headers-${LINUX_KERNEL} \
        libmount-dev pkg-config \
        && echo "Done"

ENV PATH=/usr/cmake-3.31.7-linux-x86_64/bin:$PATH

# now to ensure we get very new cmake to make sure it will work with rocm
# but cant get latest as 4.x breaks stuff
RUN echo "Adding cmake " \
    && apt -y remove --purge --auto-remove cmake \
    && wget https://github.com/Kitware/CMake/releases/download/v3.31.7/cmake-3.31.7-linux-x86_64.sh \
    && chmod a+x cmake-3.31.7-linux-x86_64.sh && yes | ./cmake-3.31.7-linux-x86_64.sh --prefix=/usr \
    && cmake --version \
    && echo "Finished apt-get installs"


# generate a kernel config for building luster
RUN echo "Generate kernel config file" \
    && cd /usr/src/linux-source-$(echo ${LINUX_KERNEL} | awk -F"-" '{print $1}')/ \ 
    && ./debian/scripts/misc/annotations \
        --arch amd64 --flavour generic --export > .config \
    && echo "Finished"

# Build and install libfabric, required for adding rccl
RUN echo "Build libfabric" \
    && (if [ -e /tmp/build ]; then rm -rf /tmp/build; fi;) \
    && mkdir -p /tmp/build \
    && cd /tmp/build \
    && wget https://github.com/ofiwg/libfabric/archive/refs/tags/v${LIBFABRIC_VERSION}.tar.gz \
    && tar xf v${LIBFABRIC_VERSION}.tar.gz \
    && cd libfabric-${LIBFABRIC_VERSION} \ 
    && ./autogen.sh \
    && ./configure \
    && make -j 16 \ 
    && make install \
    && rm -rf /tmp/build/v${LIBFABRIC_VERSION}.tar.gz \
    && rm -rf /tmp/build/libfabric-${LIBFABRIC_VERSION} \
    && echo "Done"

# Build lustre and lustre aware mpich
ARG LUSTRE_CONFIG_ARGS="--with-linux=/usr/lib/modules/${LINUX_KERNEL}-generic/build --disable-tests CFLAGS=-Wno-error=attribute-warning"
RUN echo "Building lustre" \
    && mkdir -p /tmp/lustre-build \
    && cd /tmp/lustre-build \
    && git clone git://git.whamcloud.com/fs/lustre-release.git \
    && cd lustre-release \
    # there appears to be an odd error with some release not being able to configure. 
    # for the moment, just use the main branch rather than a particular version.
    # && git fetch --tags && git checkout ${LUSTRE_VERSION} \
    && chmod +x ./autogen.sh && ./autogen.sh \
    && ./configure --disable-server --enable-client ${LUSTRE_CONFIG_ARGS}\
    && make -j8 && make install \
    && cd / \
    && rm -rf /tmp/lustre-build \
    && echo "Finished installing lustre"

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
CC=gcc-12 CXX=g++-12 FC=gfortran-12 FFLAGS=-fallow-argument-mismatch"
ARG MPICH_MAKE_OPTIONS=-j16
COPY mpich_patches.tgz /tmp/
RUN echo "Building MPICH ... " \
    && mkdir -p /tmp/mpich-build \
    && cd /tmp/mpich-build \
    && wget http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz \
    && tar xf mpich-${MPICH_VERSION}.tar.gz \
    && cd mpich-${MPICH_VERSION}  \
    # apply patches to get luster working (only relevant for mpich 3.4.3)
    && tar xf /tmp/mpich_patches.tgz \
    && patch -p0 < csel.patch \
    && patch -p0 < ch4r_init.patch \
    && ./configure ${MPICH_CONFIGURE_OPTIONS} \
    && make ${MPICH_MAKE_OPTIONS} && make install \
    && ldconfig \
    && cp -p /tmp/mpich-build/mpich-${MPICH_VERSION}/examples/cpi /usr/bin/ \
    && cd / \
    && rm -rf /tmp/mpich-build \
    && echo "Finished building MPICH" 

# add mpi4py in the container 
#RUN pip install --break-system-packages mpi4py==${MPI4PY_VERSION}
RUN pip install mpi4py==${MPI4PY_VERSION}
RUN apt -y update
RUN apt -y upgrade
RUN apt -y install rsync
# Install ROCm (note that version to installer version incomplete)
ARG ROCM_VERSION=6.0.2
RUN echo "Building rocm ${ROCM_VERSION}" \
    && rocm_major=$(echo ${ROCM_VERSION} | sed "s/\./ /g" | awk '{print $1}') \
    && rocm_minor=$(echo ${ROCM_VERSION} | sed "s/\./ /g" | awk '{print $2}') \
    && ROCM_INSTALLER_VERSION=$(echo ${ROCM_VERSION} | sed "s/\./0/g") \
    # if rocm version does not list minor patch version number add 00 to end of installer version
    && if [ $(echo ${ROCM_VERSION} | sed "s/\./\n/g" | wc -l) -eq "2" ]; then ROCM_INSTALLER_VERSION=${ROCM_INSTALLER_VERSION}"00"; fi \
    && ROCM_INSTALLER_VERSION=${ROCM_INSTALLER_VERSION}"-1" \
    && ROCM_INSTALLER_VERSION=${rocm_major}.${rocm_minor}.${ROCM_INSTALLER_VERSION} \
    && cd /tmp/build \
    # && wget https://bootstrap.pypa.io/get-pip.py \
    # && python3 get-pip.py \
    && roc_url="https://repo.radeon.com/amdgpu-install/"${ROCM_VERSION}"/ubuntu/jammy/amdgpu-install_"${ROCM_INSTALLER_VERSION}"_all.deb" \
    && echo ${roc_url} \
    && wget ${roc_url} \
    && apt -y install ./amdgpu-install_${ROCM_INSTALLER_VERSION}_all.deb \
    && amdgpu-install -y --usecase=hiplibsdk,rocm,hip,opencl \
    && cd /tmp/build && rm -rf amdgpu-install_${ROCM_INSTALLER_VERSION}_all.deb \
    && echo "Done"

# Install aws-ofi-rccl
ARG RCCL_CONFIGURE_OPTIONS="--prefix=/usr --with-mpi=/usr --with-libfabric=/usr --with-hip=/opt/rocm --with-rccl=/opt/rocm CC=gcc-12 CXX=g++-12"
RUN echo "Build aws-ofi-rccl" \
    && rocm_major=$(echo ${ROCM_VERSION} | sed "s/\./ /g" | awk '{print $1}') \
    && gitrepo=https://github.com/ROCmSoftwarePlatform/aws-ofi-rccl.git \
    # before rccl was not compatible with 6.0.2 till there was a PR that was merged. Leaving this to document that something similar could be ncessary in the future
    #&& if [ "${rocm_major}" = "6" ]; then gitrepo=https://github.com/teojgo/aws-ofi-rccl.git; RCCL_CONFIGURE_OPTIONS=${RCCL_CONFIGURE_OPTIONS}" CFLAGS=-D__HIP_PLATFORM_AMD__ CXXFLAGS=-D__HIP_PLATFORM_AMD__"; fi \
    # now just need to ensure that adding __HIP_PLATFORM_AMD__ to compilation as that was not being set in the 6.0.2 installation
    && if [ "${rocm_major}" = "6" ]; then RCCL_CONFIGURE_OPTIONS=${RCCL_CONFIGURE_OPTIONS}" CFLAGS=-D__HIP_PLATFORM_AMD__ CXXFLAGS=-D__HIP_PLATFORM_AMD__"; fi \
    && git clone ${gitrepo} \
    && cd aws-ofi-rccl \
    # this is only valid when was grabbing a fork for a fix. 
    # && if [ "${rocm_major}" = "6" ]; then git checkout rocm60_memorytype_fix; fi \
    && ./autogen.sh \
    && ./configure ${RCCL_CONFIGURE_OPTIONS}} \
    && make -j 16 \
    && make install \
    && cd /tmp \
    && rm -rf /tmp/build \
    && echo "Done"

# Build OSU Benchmarks
ARG OSU_VERSION="7.3"
ARG OSU_CONFIGURE_OPTIONS="--prefix=/usr/local CC=mpicc CXX=mpicxx CFLAGS=-O3 --enable-rocm --with-rocm=/opt/rocm"
ARG OSU_MAKE_OPTIONS="-j16"
RUN echo "Building OSU" \
    && rocm_major=$(echo ${ROCM_VERSION} | sed "s/\./ /g" | awk '{print $1}') \
	&& mkdir -p /tmp/osu-benchmark-build \
	&& cd /tmp/osu-benchmark-build \
	&& wget http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz \
	&& tar xzvf osu-micro-benchmarks-${OSU_VERSION}.tar.gz \
	&& cd osu-micro-benchmarks-${OSU_VERSION} \
    && if [ "${rocm_major}" = "6" ]; then OSU_CONFIGURE_OPTIONS=${OSU_CONFIGURE_OPTIONS}" CFLAGS=-D__HIP_PLATFORM_AMD__ CXXFLAGS=-D__HIP_PLATFORM_AMD__"; fi \
	&& ./configure ${OSU_CONFIGURE_OPTIONS} \
	&& make ${OSU_MAKE_OPTIONS} \
	&& make install \
	&& cd / \
	&& rm -rf /tmp/osu-benchmark-build \
	&& echo "Done"
ENV PATH="/usr/local/libexec/osu-micro-benchmarks/mpi/collective:/usr/local/libexec/osu-micro-benchmarks/mpi/one-sided:/usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt:/usr/local/libexec/osu-micro-benchmarks/mpi/startup:$PATH"

# For the moment, not adding the more complex mpi tests as this can be added later
# Add a more complex set of tests for MPI as well 
# RUN echo "Adding some extra mpi tests " \
#     && mkdir -p /opt/ \
#     && cd /opt/ \
#     && git clone https://github.com/pelahi/profile_util \
#     && cd profile_util  \
#     && sed -i "s:CXX=CC:CXX=g++:g" ./build_cpu.sh \
#     && sed -i "s:MPICXX=CC:MPICXX=mpic++:g" ./build_cpu.sh \
#     && sed -i "s:MPICXX=CC:MPICXX=mpic++:g" ./build_hip.sh \
#     && ./build_hip.sh \
#     && cd examples/mpi/ \
#     && make MPICXX=mpic++ \
#     && cd ../../examples/openmp \
#     && make CXX=g++ bin/openmpvec_cpp \
#     && cd ../../examples/gpu-mpi/ \
#     && make \ 
#     && echo "Done"

# Set some environment variables related to gpu communication and libfabric
ENV NCCL_SOCKET_IFNAME=hsn
ENV CXI_FORK_SAFE=1
ENV CXI_FORK_SAFE_HP=1
ENV HSA_FORCE_FINE_GRAIN_PCIE=1
ENV FI_CXI_DISABLE_CQ_HUGETLB=1
ENV ROCM_PATH=/opt/rocm
# Singularity: will execute scripts in /.singularity.d/env/ at startup (and ignore those in /etc/profile.d/).
#              Standard naming of "environment" scripts is 9X-environment.sh
RUN mkdir -p /.singularity.d/env/
RUN echo "export NCCL_SOCKET_IFNAME=hsn"  >> /.singularity.d/env/91-environment.sh \
    && echo "export CXI_FORK_SAFE=1"  >> /.singularity.d/env/91-environment.sh \
    && echo "export ROCM_PATH=/opt/rocm"  >> /.singularity.d/env/91-environment.sh \
    && echo "export CXI_FORK_SAFE_HP=1" >> /.singularity.d/env/91-environment.sh \
    && echo "export HSA_FORCE_FINE_GRAIN_PCIE=1" >> /.singularity.d/env/91-environment.sh \
    && echo "export FI_CXI_DISABLE_CQ_HUGETLB=1" >> /.singularity.d/env/91-environment.sh

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildrocm-mpich-base.dockerfile /opt/docker-recipes/
