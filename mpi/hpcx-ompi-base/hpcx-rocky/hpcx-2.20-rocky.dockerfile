FROM rockylinux/rockylinux:9.4

#CICD metadata
LABEL org.opencontainers.image.arch=arm
LABEL org.opencontainers.image.compilation=auto
LABEL org.opencontainers.image.devmode=false
LABEL org.opencontainers.image.noscan=true

#Image metadata
LABEL org.opencontainers.image.name="hpcx"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.version="13-11-2024"
LABEL org.opencontainers.image.minversion="0.0.3"
LABEL org.opencontainers.image.authors="Shusen Liu <shusen.liu@pawsey.org.au>"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Ella MPI from hpcx based on rockylinux"
LABEL org.opencontainers.image.description="We provide a container image for the Ella project, \
which includes the HPC-X MPI library. \
Pip venv: . /opt/cuquantum-source/cuquantum-env/bin/activate. \
1. Run MPI with OpenMPI from HPC-X;  "



# Set noninteractive mode for apt
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN dnf -y update && dnf install -y \
    gcc \
    gcc-c++ \
    make \
    wget \
    tar \
    ca-certificates \
    numactl \
    numactl-devel \
    hwloc \
    hwloc-devel \
    pciutils \
    rdma-core \
    rdma-core-devel \
    libibverbs-devel \  
    openssh-clients \
    chrpath \
    graphviz \
    lsof \
    tk \
    gcc-gfortran \
    libusb1 \
    kmod \
    pkgconfig \
    flex \
    tcl \
    bison \
    fuse-libs \
    perl \
    libmnl \
    ethtool\
    dnf-plugins-core \
    bzip2 \
    binutils\
    binutils-devel\
    && dnf clean all



# Install CUDA 12.6
# Add NVIDIA's package repository and install CUDA Toolkit 12.6
RUN dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/sbsa/cuda-rhel9.repo && \
    dnf clean all && \   
    dnf -y install cuda-toolkit-12-6 && \
    dnf clean all

# # Set CUDA environment variables
ENV CUDA_HOME=/usr/local/cuda-12.6
ENV LD_LIBRARY_PATH=${CUDA_HOME}/lib64:$LD_LIBRARY_PATH
ENV PATH=${CUDA_HOME}/bin:$PATH

# # Set the HPC-X version and download URL
ENV HPCX_VERSION=v2.20
ENV HPCX_PACKAGE=hpcx-v2.20-gcc-mlnx_ofed-redhat9-cuda12-aarch64
ENV HPCX_DOWNLOAD_URL=https://content.mellanox.com/hpc/hpc-x/${HPCX_VERSION}/${HPCX_PACKAGE}.tbz

# # Download and extract HPC-X
RUN mkdir -p /opt && \
    cd /opt && \
    wget ${HPCX_DOWNLOAD_URL} && \
    tar -xvf $(basename ${HPCX_DOWNLOAD_URL}) && \
    rm $(basename ${HPCX_DOWNLOAD_URL}) && \
    mv ${HPCX_PACKAGE} hpcx &&\
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

#Update path. All of these paths would be rewritten in the singularity env file
# Update PATH
ENV CUDA_HOME=/usr/local/cuda
ENV CUDA_PATH=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${HPCX_UCX_DIR}/bin:${HPCX_UCC_DIR}/bin:${HPCX_HCOLL_DIR}/bin:${HPCX_SHARP_DIR}/bin:${HPCX_MPI_TESTS_DIR}/imb:${HPCX_HOME}/clusterkit/bin:${HPCX_MPI_DIR}/bin:$PATH
ENV LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu:${CUDA_HOME}/lib64:/usr/lib64:${HPCX_UCX_DIR}/lib:${HPCX_UCX_DIR}/lib/ucx:${HPCX_UCC_DIR}/lib:${HPCX_UCC_DIR}/lib/ucc:${HPCX_HCOLL_DIR}/lib:${HPCX_SHARP_DIR}/lib:${HPCX_NCCL_RDMA_SHARP_PLUGIN_DIR}/lib:${HPCX_MPI_DIR}/lib:$LD_LIBRARY_PATH
ENV LIBRARY_PATH=$/usr/lib/aarch64-linux-gnu:${CUDA_HOME}/lib64:/usr/lib64:{HPCX_UCX_DIR}/lib:${HPCX_UCC_DIR}/lib:${HPCX_HCOLL_DIR}/lib:${HPCX_SHARP_DIR}/lib:${HPCX_NCCL_RDMA_SHARP_PLUGIN_DIR}/lib:$LIBRARY_PATH
ENV CPATH=/usr/local/cuda/include:${HPCX_HCOLL_DIR}/include:${HPCX_SHARP_DIR}/include:${HPCX_UCX_DIR}/include:${HPCX_UCC_DIR}/include:${HPCX_MPI_DIR}/include:$CPATH
ENV PKG_CONFIG_PATH=${HPCX_HCOLL_DIR}/lib/pkgconfig:${HPCX_SHARP_DIR}/lib/pkgconfig:${HPCX_UCX_DIR}/lib/pkgconfig:${HPCX_MPI_DIR}/lib/pkgconfig:$PKG_CONFIG_PATH
ENV MANPATH=${HPCX_MPI_DIR}/share/man:$MANPATH 
# Set working directory
WORKDIR ${HPCX_HOME}

# Copy the Dockerfile and environment files for Ella to the container
# For reference, we copy all the dockerfiles in this topic to the container
RUN mkdir -p /opt/docker-recipes/
COPY *.dockerfile /opt/docker-recipes/
COPY *.env /opt/docker-recipes/

# Optional: Set entrypoint to bash
CMD ["/bin/bash"]