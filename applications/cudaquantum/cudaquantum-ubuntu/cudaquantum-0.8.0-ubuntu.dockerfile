FROM ubuntu:22.04

#CICD metadata
LABEL org.opencontainers.image.arch=arm
LABEL org.opencontainers.image.compilation=auto
LABEL org.opencontainers.image.devmode=false
LABEL org.opencontainers.image.noscan=true

#Image metadata
LABEL org.opencontainers.image.name="cudaquantum"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.version="10-11-2024"
LABEL org.opencontainers.image.minversion="0.0.6"
LABEL org.opencontainers.image.authors="Shusen Liu <shusen.liu@pawsey.org.au>"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Ella cudaquantum with cuQuantum and hpcx"
LABEL org.opencontainers.image.description="We provide a container image for the Ella project, \
which includes the cuQuantum library and the HPC-X MPI library. \
Pip venv: . /opt/cuquantum-source/cuquantum-env/bin/activate. \
1. Compile C++ with nvq++ from cudaquantum; \
2. Run Python with nvqpy from cudaquantum; \
3. Run MPI with OpenMPI from HPC-X; \
4. Run Qiskit with cuQuantum and Aer from Qiskit;"

ARG PY_VERSION="3.12"
ARG CUDA_VERSION="12.6.0"

# Set default environment variables
ENV DEBIAN_FRONTEND="noninteractive"
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV CPATH="/usr/include"
ENV LD_LIBRARY_PATH="/usr/lib64:/usr/lib"
ENV LIBRARY_PATH="/usr/lib:/usr/local/cuda/lib64/stubs"

RUN set -e && \
    export DEBIAN_FRONTEND=noninteractive && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends software-properties-common gpg-agent && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        libc-dev-bin \
        libc6 \
        libc-bin \
        libc-dev \
        libnuma-dev \
        lsof \
        coreutils \
        autoconf \
        automake \
        numactl \
        gnupg \
        bzip2 \
        file \
        perl \
        flex \
        tar \
        wget \
        git \
        sudo \
        curl \
        libtool \
        make \
        cmake \
        chrpath \
        openssh-server \
        openssh-client \
        vim \
        ninja-build \
        libblas-dev \
        libopenblas-dev \
        libtbb-dev \
        python3.12-dev \
        python3.12-distutils \
        python3.12-full \
        gcc \
        g++ \
        gfortran \
        libhwloc-dev \
        lsb-release \
        pciutils \
        ibverbs-providers \
        libibverbs1 \
        libibverbs-dev \
        ibverbs-utils \
        infiniband-diags \
        perftest \
        rdma-core \
        libgfortran5 \
        debhelper \
        graphviz \
        tk \
        libusb-1.0-0 \
        kmod \
        swig \
        pkg-config \
        tcl \
        bison \
        libfuse2 && \
        add-apt-repository ppa:ubuntu-toolchain-r/test && \
        apt-get update -qq && \
        apt-get install -y --no-install-recommends gcc-13 g++-13 gfortran-13 && \
        update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100 && \
        update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100 && \
        update-alternatives --install /usr/bin/gfortran gfortran /usr/bin/gfortran-13 100 && \
        add-apt-repository --remove ppa:ubuntu-toolchain-r/test &&\
        update-alternatives --install /usr/bin/python python /usr/bin/python${PY_VERSION} 1 && \
        update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PY_VERSION} 1 && \
        curl https://bootstrap.pypa.io/get-pip.py | python - && \
        wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/sbsa/cuda-keyring_1.1-1_all.deb && \
        dpkg -i cuda-keyring_1.1-1_all.deb && \
        apt-get update && \
        apt-get install -y cuda-toolkit-12-6=12.6.1-1 libcutensor2 libcutensor-dev libcutensor-doc && \
        rm cuda-keyring_1.1-1_all.deb && \
        python -m pip install nvidia-cuda-runtime-cu12 nvidia-nvjitlink-cu12 nvidia-cublas-cu12 nvidia-cusolver-cu12 nvidia-cusparse-cu12 pip-tools && \
        rm -rf /root/.cache/pip && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/*

ENV CUDA_HOME=/usr/local/cuda-12.6 
ENV LD_LIBRARY_PATH=${CUDA_HOME}/lib64:$LD_LIBRARY_PATH 
ENV PATH=${CUDA_HOME}/bin:$PATH 
ENV HPCX_VERSION=v2.20 
ENV HPCX_PACKAGE=hpcx-v2.20-gcc-mlnx_ofed-ubuntu22.04-cuda12-aarch64.tbz 
ENV HPCX_DOWNLOAD_URL=https://content.mellanox.com/hpc/hpc-x/${HPCX_VERSION}/${HPCX_PACKAGE}

RUN mkdir -p /opt && \
    cd /opt && \
    wget -q ${HPCX_DOWNLOAD_URL} && \
    tar -xf $(basename ${HPCX_DOWNLOAD_URL}) && \
    rm $(basename ${HPCX_DOWNLOAD_URL}) && \
    mv hpcx-v2.20-gcc-mlnx_ofed-ubuntu22.04-cuda12-aarch64 hpcx && \
    chmod o+w hpcx 

# HPCX related paths are set only for further complation of MPI
# Execution of MPI applications relys on the env file of singularity
ENV HPCX_HOME=/opt/hpcx 
ENV HPCX_DIR=${HPCX_HOME} \
    HPCX_UCX_DIR=${HPCX_HOME}/ucx \
    HPCX_UCC_DIR=${HPCX_HOME}/ucc \
    HPCX_SHARP_DIR=${HPCX_HOME}/sharp \
    HPCX_HCOLL_DIR=${HPCX_HOME}/hcoll \
    HPCX_NCCL_RDMA_SHARP_PLUGIN_DIR=${HPCX_HOME}/nccl_rdma_sharp_plugin \
    HPCX_MPI_DIR=${HPCX_HOME}/ompi \
    HPCX_OSHMEM_DIR=${HPCX_HOME}/ompi \
    HPCX_MPI_TESTS_DIR=${HPCX_HOME}/ompi/tests \
    HPCX_OSU_DIR=${HPCX_HOME}/ompi/tests/osu-micro-benchmarks \
    HPCX_OSU_CUDA_DIR=${HPCX_HOME}/ompi/tests/osu-micro-benchmarks-cuda \
    OPAL_PREFIX=${HPCX_HOME}/ompi \
    PMIX_INSTALL_PREFIX=${HPCX_HOME}/ompi \
    OMPI_HOME=${HPCX_HOME}/ompi \
    MPI_HOME=${HPCX_HOME}/ompi \
    OSHMEM_HOME=${HPCX_HOME}/ompi \
    SHMEM_HOME=${HPCX_HOME}/ompi \
    MPI_PATH=${HPCX_HOME}/ompi \
    MPI_ROOT=${HPCX_HOME}/ompi

# Update PATH
ENV CUDA_HOME=/usr/local/cuda
ENV CUDA_PATH=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${HPCX_UCX_DIR}/bin:${HPCX_UCC_DIR}/bin:${HPCX_HCOLL_DIR}/bin:${HPCX_SHARP_DIR}/bin:${HPCX_MPI_TESTS_DIR}/imb:${HPCX_HOME}/clusterkit/bin:${HPCX_MPI_DIR}/bin:$PATH
ENV LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu:${CUDA_HOME}/lib64:/usr/lib64:${HPCX_UCX_DIR}/lib:${HPCX_UCX_DIR}/lib/ucx:${HPCX_UCC_DIR}/lib:${HPCX_UCC_DIR}/lib/ucc:${HPCX_HCOLL_DIR}/lib:${HPCX_SHARP_DIR}/lib:${HPCX_NCCL_RDMA_SHARP_PLUGIN_DIR}/lib:${HPCX_MPI_DIR}/lib:$LD_LIBRARY_PATH
ENV LIBRARY_PATH=$/usr/lib/aarch64-linux-gnu:${CUDA_HOME}/lib64:/usr/lib64:{HPCX_UCX_DIR}/lib:${HPCX_UCC_DIR}/lib:${HPCX_HCOLL_DIR}/lib:${HPCX_SHARP_DIR}/lib:${HPCX_NCCL_RDMA_SHARP_PLUGIN_DIR}/lib:$LIBRARY_PATH
ENV CPATH=/usr/local/cuda/include:${HPCX_HCOLL_DIR}/include:${HPCX_SHARP_DIR}/include:${HPCX_UCX_DIR}/include:${HPCX_UCC_DIR}/include:${HPCX_MPI_DIR}/include:$CPATH
ENV PKG_CONFIG_PATH=${HPCX_HCOLL_DIR}/lib/pkgconfig:${HPCX_SHARP_DIR}/lib/pkgconfig:${HPCX_UCX_DIR}/lib/pkgconfig:${HPCX_MPI_DIR}/lib/pkgconfig:$PKG_CONFIG_PATH
ENV MANPATH=${HPCX_MPI_DIR}/share/man:$MANPATH 

# Create a symbolic link to the OpenMPI installation
RUN /bin/bash -c ' \
    base_path=$(ls -d /opt/hpcx/ompi 2>/dev/null | head -n 1) && \
    if [ -z "$base_path" ]; then \
        echo "Error: No OpenMPI installation found in /opt/hpcx/ompi/" && \
        exit 1; \
    fi && \
    echo "Using OpenMPI base path: $base_path" && \
    for package in openmpi; do \
        for target in bin lib include; do \
            src_path="${base_path}/${target}" && \
            dest_path="/usr/${package}/${target}" && \
            if [ -d "${src_path}" ]; then \
                mkdir -p "${dest_path}" && \
                for file in "${src_path}"/*; do \
                    if [ -f "${file}" ] || [ -L "${file}" ]; then \
                        ln -s "${file}" "${dest_path}/$(basename "${file}")"; \
                    fi; \
                done; \
            fi; \
        done; \
    done && \
    update-alternatives --install /usr/local/mpi mpi /usr/openmpi 100 '

RUN mkdir -p /opt/qiskit
COPY qiskit_aer-0.15.0-cp312-cp312-linux_aarch64.whl /opt/qiskit


# Install cuQuantum binary without examples
RUN wget -q https://developer.download.nvidia.com/compute/cuquantum/redist/cuquantum/linux-sbsa/cuquantum-linux-sbsa-24.08.0.5_cuda12-archive.tar.xz \
    && mkdir -p /opt/cuquantum \
    && chmod -R 755 /opt/cuquantum \
    && tar -xf cuquantum-linux-sbsa-24.08.0.5_cuda12-archive.tar.xz -C /opt/cuquantum --strip-components=1 \
    && rm cuquantum-linux-sbsa-24.08.0.5_cuda12-archive.tar.xz \
    && cd /opt/cuquantum/distributed_interfaces \
    && sh activate_mpi.sh

ENV LD_LIBRARY_PATH=/opt/cuquantum/lib:${LD_LIBRARY_PATH}
ENV CUQUANTUM_ROOT="/opt/cuquantum"
ENV CUTENSORNET_COMM_LIB="/opt/cuquantum/distributed_interfaces/libcutensornet_distributed_interface_mpi.so"

# download cuQuantum source code
RUN wget -q https://github.com/NVIDIA/cuQuantum/archive/refs/tags/v24.08.0.tar.gz &&\
    mkdir -p /opt/cuquantum-source &&\
    tar -xf v24.08.0.tar.gz -C /opt/cuquantum-source --strip-components=1 &&\
    rm v24.08.0.tar.gz 

# Install cuQuantum python package
RUN python -m venv --system-site-packages /opt/cuquantum-source/cuquantum-env && \
    chmod -R a+rwX /opt/cuquantum-source/cuquantum-env &&\
    . /opt/cuquantum-source/cuquantum-env/bin/activate &&\
    pip install --upgrade pip && \
    pip install 'cryptography~=43.0' 'setuptools' 'urllib3==1.26.5' 'packaging'\
     'httpx' 'wheel' 'mpmath==1.3.0' 'pyjwt==2.4.0' 'Cython>=0.29.22,<3' 'numpy'\
     'cupy-cuda12x' 'nbformat' 'pytest' &&\
    rm -rf /root/.cache/pip

# create mpi.cfg 
RUN mkdir -p /opt/mpicfg &&\
    echo "[openmpi]" > /opt/mpicfg/mpi.cfg && \
    echo "mpi_dir = /opt/hpcx/ompi" >> /opt/mpicfg/mpi.cfg && \
    echo "mpicc   = %(mpi_dir)s/bin/mpicc" >> /opt/mpicfg/mpi.cfg && \
    echo "mpicxx  = %(mpi_dir)s/bin/mpicxx" >> /opt/mpicfg/mpi.cfg

ENV MPI4PY_BUILD_MPICFG=/opt/mpicfg/mpi.cfg

RUN . /opt/cuquantum-source/cuquantum-env/bin/activate &&\
    pip install 'mpi4py' &&\    
    cd /opt/cuquantum-source/python &&\
    pip install -v --no-deps --no-build-isolation . &&\
    pip install /opt/qiskit/qiskit_aer-0.15.0-cp312-cp312-linux_aarch64.whl &&\
    rm -rf /root/.cache/pip

# Create symbolic links for cutensor and cuquantum libraries, from /opt/cuquantum to /opt/cuquantum-source/cuquantum-env
RUN ln -s /opt/cuquantum/lib/libcustatevec.so.1 /opt/cuquantum-source/cuquantum-env/lib/libcustatevec.so.1 &&\
    ln -s /opt/cuquantum/lib/libcustatevec.so.1 /opt/cuquantum-source/cuquantum-env/lib/libcustatevec.so &&\
    ln -s /opt/cuquantum/lib/libcutensornet.so.2 /opt/cuquantum-source/cuquantum-env/lib/libcutensornet.so.2 &&\
    ln -s /opt/cuquantum/lib/libcutensornet.so.2 /opt/cuquantum-source/cuquantum-env/lib/libcutensornet.so 

ENV LD_LIBRARY_PATH=/opt/cuquantum-source/cuquantum-env/lib:${LD_LIBRARY_PATH}

RUN wget -q https://r2.qcompiler.com/cuda_quantum_cu12-0.0.0-cp312-cp312-manylinux_2_28_aarch64.whl -O /tmp/cuda_quantum_cu12-0.0.0-cp312-cp312-manylinux_2_28_aarch64.whl &&\
    . /opt/cuquantum-source/cuquantum-env/bin/activate &&\
    pip install /tmp/cuda_quantum_cu12-0.0.0-cp312-cp312-manylinux_2_28_aarch64.whl &&\
    . /opt/cuquantum-source/cuquantum-env/lib/python3.12/site-packages/distributed_interfaces/activate_custom_mpi.sh

# Install cuda-quantum and temp patch 
RUN wget -q https://github.com/NVIDIA/cuda-quantum/releases/download/0.8.0/install_cuda_quantum.aarch64 -O /tmp/install_cuda_quantum.aarch64 && \
    chmod +x /tmp/install_cuda_quantum.aarch64 && \
    bash /tmp/install_cuda_quantum.aarch64 --accept && \
    ln -s /usr/local/cuda/targets/sbsa-linux/lib/libcublas.so /usr/local/cuda/targets/sbsa-linux/lib/libcublas.so.11 && \   
    ln -s /usr/local/cuda/targets/sbsa-linux/lib/libcublasLt.so /usr/local/cuda/targets/sbsa-linux/lib/libcublasLt.so.11 &&\
    rm /tmp/install_cuda_quantum.aarch64
    
ENV CUDAQ_INSTALL_PATH="/opt/nvidia/cudaq"
ENV LD_LIBRARY_PATH=${CUDAQ_INSTALL_PATH}/lib:${LD_LIBRARY_PATH}
ENV PATH=${CUDAQ_INSTALL_PATH}/bin:${PATH}
ENV CPLUS_INCLUDE_PATH=${CUDAQ_INSTALL_PATH}/include:${CPLUS_INCLUDE_PATH}

# Prepare activation script
RUN echo '#!/bin/bash' > /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
    echo ". /opt/cuquantum-source/cuquantum-env/bin/activate" >> /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
    echo "export CUDA_PATH=/usr/local/cuda" >> /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
    echo "export CUDA_HOME=/usr/local/cuda" >> /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
    echo "export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}" >> /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
    echo "export LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libgomp.so.1" >> /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
    echo "export CUQUANTUM_ROOT=/opt/cuquantum">> /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
    echo "export CUTENSOR_ROOT=/opt/cuquantum">> /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
    echo "export MPI_PATH=${MPI_PATH}" >> /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
#   for cutensornet samples require MPI_ROOT   
    echo "export MPI_ROOT=${MPI_PATH}" >> /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
    echo "export PATH=${PATH}" >> /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh && \
    chmod +x /opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh

# Copy the Dockerfile and environment files for Ella to the container
# For reference, we copy all the dockerfiles in this topic to the container
RUN mkdir -p /opt/docker-recipes
COPY *.dockerfile /opt/docker-recipes
COPY *.env /opt/docker-recipes
COPY *.sh /opt/docker-recipes
COPY *.whl /opt/docker-recipes

# Set entrypoint to activate the environment on container start
ENTRYPOINT ["/opt/cuquantum-source/cuquantum-env/activate_cuquantum.sh"]