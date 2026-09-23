FROM quay.io/pawsey/rocm-mpich-base:rocm6.2.4-mpich3.4.3-ubuntu24.04

# Use bash to support string substitution.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ROCm environment
ENV ROCM_RELEASE 6.2.4
ENV ROCM_PATH /opt/rocm-$ROCM_RELEASE
ENV PATH $ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH
ENV LD_LIBRARY_PATH $LD_LIBRARY_PATH:$ROCM_PATH/lib:/opt/miniforge3/lib
ENV JAX_PLATFORMS "rocm,cpu"

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update --quiet \
    && apt-get install --no-install-recommends --yes --quiet \
        build-essential \
        cmake \
        git \
        hmmer \
        kalign \
        tzdata \
        wget \
		clang \
        doxygen \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get autoremove --yes \
    && apt-get clean

WORKDIR /opt

RUN git clone https://github.com/deepmind/alphafold.git /app/alphafold && \
    cd /app/alphafold && \
    git checkout e9b68483fc8764e7a1906e74a5d1f0ea2137311d && \
    wget -q -P /app/alphafold/alphafold/common/ \
    https://git.scicore.unibas.ch/schwede/openstructure/-/raw/7102c63615b64735c4941278d92b554ec94415f8/modules/mol/alg/src/stereo_chemical_props.txt

# Install miniforge (mamba)
RUN set -eux ; \
    curl -L -O "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh" ; \
    bash Miniforge3-$(uname)-$(uname -m).sh -b -p /opt/miniforge3 -s ; \
    rm -rf ./Miniforge3-*
ENV PATH /opt/miniforge3/bin:$PATH

RUN mamba install -y -c conda-forge -c bioconda \
    python=3.11 \
    pdbfixer==1.12 \
    bioconda::hhsuite=3.3.0 && \
    mamba clean -afy

# Install pip packages.
COPY requirements.txt run_msa.py run_predict.py /app/alphafold/
RUN pip3 install -r /app/alphafold/requirements.txt --no-cache-dir --root-user-action=ignore --break-system-packages && \
    pip uninstall -y jax jaxlib --break-system-packages && \
    python3 -m pip install --no-cache-dir --root-user-action=ignore --break-system-packages https://github.com/ROCm/jax/releases/download/rocm-jax-v0.4.34/jaxlib-0.4.34-cp311-cp311-manylinux_2_28_x86_64.whl && \
    python3 -m pip install --no-cache-dir --root-user-action=ignore --break-system-packages https://github.com/ROCm/jax/releases/download/rocm-jax-v0.4.34/jax_rocm60_pjrt-0.4.34-py3-none-manylinux_2_28_x86_64.whl https://github.com/ROCm/jax/releases/download/rocm-jax-v0.4.34/jax_rocm60_plugin-0.4.34-cp311-cp311-manylinux_2_28_x86_64.whl && \
    python3 -m pip install --no-cache-dir --root-user-action=ignore --break-system-packages https://github.com/ROCm/jax/archive/refs/tags/rocm-jax-v0.4.34.tar.gz

RUN sed -i 's|tolerance = tolerance \* ENERGY|tolerance = tolerance * ENERGY / unit.nanometer|' \
    /app/alphafold/alphafold/relax/amber_minimize.py

# bfloat16 is disabled in this config: the ROCm 6.2.4 LLVM backend cannot select
# the i1 -> bf16 conversion that the multimer model emits, aborting at compile time.
COPY config.py /app/alphafold/alphafold/model/config.py

WORKDIR /app/alphafold

COPY config.py Dockerfile requirements.txt run_msa.py run_predict.py /opt/docker-recipes/
LABEL org.opencontainers.image.authors="Sarah Beecroft <sarah.beecroft@csiro.au>" \
      org.opencontainers.image.title="alphafold2_v2.3.2_rocm6.2.4_ubuntu24.04" \
      org.opencontainers.image.version="2.3.2" \
      org.opencontainers.image.description="AlphaFold2 v2.3.2 with ROCm 6.2.4 support on Ubuntu 24.04 for AMD GPUs, with helper scripts for the nf-core/proteinfold pipeline" \
      org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/tree/master/setonix/gpu_biology/alphafold2/rocm6.2.4/v2.3.2"

ENV XLA_FLAGS='--xla_gpu_enable_command_buffer= --xla_gpu_autotune_level=0'
ENV HIP_VISIBLE_DEVICES="0"
ENV ROCR_VISIBLE_DEVICES="0"
