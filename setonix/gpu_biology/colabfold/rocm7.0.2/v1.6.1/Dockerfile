FROM quay.io/pawsey/rocm-mpich-base:rocm7.0.2-mpich3.4.3-ubuntu24.04

# Use bash to support string substitution.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update --quiet \
    && apt-get install --no-install-recommends --yes --quiet \
        build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get autoremove --yes \
    && apt-get clean

WORKDIR /opt

# ROCm environment
ENV ROCM_RELEASE 7.0.2
ENV ROCM_PATH /opt/rocm-$ROCM_RELEASE
ENV PATH $ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH
ENV LD_LIBRARY_PATH $LD_LIBRARY_PATH:$ROCM_PATH/lib
ENV JAX_PLATFORMS="rocm,cpu"
ENV PIP_NO_CACHE_DIR=true

# Install miniforge (mamba). Pinned versions here match the working
# quay.io/pawsey/colabfold:1.6.1_rocm7.0.2 image.
ARG MINIFORGE_VERSION=26.5.3-0
RUN set -eux ; \
    curl -fsSL -O "https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-${MINIFORGE_VERSION}-Linux-x86_64.sh" ; \
    bash Miniforge3-${MINIFORGE_VERSION}-Linux-x86_64.sh -b -p /opt/miniforge3 -s ; \
    rm -rf ./Miniforge3-*
ENV PATH /opt/miniforge3/bin:$PATH

RUN mamba install -y -c conda-forge -c bioconda python=3.12.3 kalign2=2.04 hhsuite=3.3.0 mmseqs2=18.8cc5c
# Pin the TensorFlow / JAX-ecosystem packages colabfold leaves open, so they stay
# compatible with the ROCm JAX 0.6.2 installed next.
RUN pip install colabfold[alphafold,openmm]==1.6.1 \
        tensorflow-cpu==2.21.0 keras==3.15.1 numpy==2.5.2 scipy==1.18.0 ml-dtypes==0.6.0 \
        chex==0.1.90 dm-haiku==0.0.16 dm-tree==0.1.10 pandas==2.3.3 && \
    pip uninstall -y jax jaxlib && \
    pip install https://github.com/ROCm/rocm-jax/releases/download/rocm-jax-v0.6.0/jax_rocm7_pjrt-0.6.0-py3-none-manylinux_2_28_x86_64.whl \
    https://github.com/ROCm/rocm-jax/releases/download/rocm-jax-v0.6.0/jax_rocm7_plugin-0.6.0-cp312-cp312-manylinux_2_28_x86_64.whl \
    https://github.com/ROCm/rocm-jax/releases/download/rocm-jax-v0.6.0/jaxlib-0.6.2-cp312-cp312-manylinux2014_x86_64.whl \
    jax==0.6.2 && \
    pip install openmm[hip7]==8.5.2 && \
    mamba clean -afy

RUN sed -i 's/CUDA/HIP/g' /opt/miniforge3/lib/python3.12/site-packages/alphafold/relax/amber_minimize.py

COPY Dockerfile /opt/docker-recipes/
LABEL org.opencontainers.image.authors="Sarah Beecroft <sarah.beecroft@csiro.au>" \
      org.opencontainers.image.title="colabfold_v1.6.1_rocm7.0.2_ubuntu24.04" \
      org.opencontainers.image.version="1.6.1" \
      org.opencontainers.image.description="ColabFold v1.6.1 with ROCm 7.0.2 support on Ubuntu 24.04 for AMD GPUs" \
      org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/tree/master/setonix/gpu_biology/colabfold/rocm7.0.2/v1.6.1"

ENV XLA_PYTHON_CLIENT_MEM_FRACTION="4.0"
ENV XLA_PYTHON_CLIENT_ALLOCATOR="platform"
ENV TF_FORCE_GPU_ALLOW_GROWTH="true"
ENV TF_FORCE_UNIFIED_MEMORY="0"
ENV XLA_FLAGS='--xla_gpu_enable_command_buffer= --xla_gpu_autotune_level=0'
ENV HIP_VISIBLE_DEVICES=0
ENV ROCR_VISIBLE_DEVICES=0
