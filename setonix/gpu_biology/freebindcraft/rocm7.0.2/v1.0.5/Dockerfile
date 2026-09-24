FROM quay.io/pawsey/rocm-mpich-base:rocm7.0.2-mpich3.4.3-ubuntu24.04

# Use bash to support string substitution.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update --quiet \
    && apt-get install --no-install-recommends --yes --quiet \
      build-essential \
      ca-certificates \
      curl \
      git \
      rsync \
      libgfortran5 \
      tmux \
      wget \
      pkg-config \
      procps \
      ocl-icd-libopencl1 \
      clinfo \
      unzip \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get autoremove --yes \
    && apt-get clean

# ROCm environment
ENV ROCM_RELEASE 7.0.2
ENV ROCM_PATH /opt/rocm-$ROCM_RELEASE
ENV PATH $ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH
ENV LD_LIBRARY_PATH $LD_LIBRARY_PATH:$ROCM_PATH/lib
ENV JAX_PLATFORMS="rocm,cpu"
ENV PIP_NO_CACHE_DIR=true

WORKDIR /app

# Install miniforge (mamba). Pinned versions here and in env.yml match the
# working quay.io/pawsey/freebindcraft:v1.0.5_rocm7.0.2_nopyrosetta image.
ARG MINIFORGE_VERSION=26.5.3-0
RUN set -eux ; \
    curl -fsSL -O "https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-${MINIFORGE_VERSION}-Linux-x86_64.sh" ; \
    bash Miniforge3-${MINIFORGE_VERSION}-Linux-x86_64.sh -b -p /opt/miniforge3 -s ; \
    rm -rf ./Miniforge3-*

# Put mamba on PATH
ENV PATH /opt/miniforge3/bin:$PATH

# Clone FreeBindCraft and make sure the executables are executable (chmod +x)
RUN git clone --branch v1.0.5 https://github.com/cytokineking/FreeBindCraft.git && \
    chmod +x /app/FreeBindCraft/functions/dssp && \
    chmod +x /app/FreeBindCraft/functions/sc && \
    chmod +x /app/FreeBindCraft/functions/DAlphaBall.gcc

# Copy the environment file and Dockerfile into the image for reproducibility.
COPY Dockerfile env.yml /opt/docker-recipes/

# Install the conda environment and ColabDesign (no dependencies for ColabDesign, since they are already in the conda env).
RUN mamba env update -n base -y -f /opt/docker-recipes/env.yml && \
    mamba clean -afy
RUN pip install git+https://github.com/sokrypton/ColabDesign.git@e31a56fe1d9b4de25c8697f3a28b75892941cc72 --no-deps

# Default environment
ENV PYTHONUNBUFFERED=1 \
    BINDCRAFT_HOME=/app/FreeBindCraft

ENV OPENMM_PLATFORM_ORDER=HIP,OpenCL,CPU \
    OPENMM_DEFAULT_PLATFORM=HIP
ENV XLA_FLAGS='--xla_gpu_enable_command_buffer= --xla_gpu_autotune_level=0'
ENV AMD_COMGR_CACHE_DIR=/tmp/amd_comgr_cache

LABEL org.opencontainers.image.authors="Sarah Beecroft <sarah.beecroft@csiro.au>" \
      org.opencontainers.image.title="freebindcraft_v1.0.5_rocm7.0.2_ubuntu24.04" \
      org.opencontainers.image.version="1.0.5" \
      org.opencontainers.image.description="FreeBindCraft v1.0.5 (without PyRosetta) with ROCm 7.0.2 support on Ubuntu 24.04 for AMD GPUs" \
      org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/tree/master/setonix/gpu_biology/freebindcraft/rocm7.0.2/v1.0.5"
