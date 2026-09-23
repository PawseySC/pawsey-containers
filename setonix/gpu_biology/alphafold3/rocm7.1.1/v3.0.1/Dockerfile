# AlphaFold3 on AMD GPUs (ROCm 7.x) with JAX installed from prebuilt pip wheels.

ARG ROCM_VERSION=7.1.1
FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION}
# Re-declare so the value is visible after FROM (used in LABEL below).
ARG ROCM_VERSION

# ---- build time options -------------
ARG JAX_VERSION=0.7.1
ARG ROCM_JAX_MAJOR=7
ARG AF3_COMMIT=3a09f04
ARG HMMER_VERSION=3.4
# Ubuntu 24.04 ships Python 3.12 -> cp312 wheels.
ARG PYTAG=cp312

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=true

# ---- OS packages --------------
RUN apt-get update && apt-get install -q -y --no-install-recommends \
        build-essential \
        git \
        wget \
        curl \
        ca-certificates patch \
        python3-dev \
        python3-venv \
        python3-pip \
        pkg-config \
        zlib1g-dev \
        libtbb-dev \
        miopen-hip \
        hipfft \
        hipsparse \
        hipsolver \
        hiprand \
        rccl \
        hipblas \
        hipcub \
        libdw1t64 \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get autoremove --yes \
    && apt-get clean

# ---- isolated Python environment --------------------------------------------
ENV VIRTUAL_ENV=/opt/alphafold3_env
RUN python3 -m venv ${VIRTUAL_ENV}
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"
RUN pip install --upgrade pip

# ---- JAX for ROCm: pip wheels, no source build ------------------------------
# jax (pure python) from PyPI, then override jaxlib with the ROCm build, then
# install the ROCm pjrt + plugin (all from the rocm-jax v${JAX_VERSION} release).
RUN REL="https://github.com/ROCm/jax/releases/download/rocm-jax-v${JAX_VERSION}" && \
    pip install --no-cache-dir "jax==${JAX_VERSION}" && \
    pip install --no-cache-dir --force-reinstall --no-deps \
        "${REL}/jaxlib-${JAX_VERSION}-${PYTAG}-${PYTAG}-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl" && \
    pip install --no-cache-dir --no-deps \
        "${REL}/jax_rocm${ROCM_JAX_MAJOR}_pjrt-${JAX_VERSION}-py3-none-manylinux_2_28_x86_64.whl" \
        "${REL}/jax_rocm${ROCM_JAX_MAJOR}_plugin-${JAX_VERSION}-${PYTAG}-${PYTAG}-manylinux_2_28_x86_64.whl" && \
    python3 -c "import jax, jaxlib; print('jax', jax.__version__, '| jaxlib', jaxlib.__version__)"

# ---- helper scripts (requirements filter + AMD patcher) ---------------------
COPY filter_af3_requirements.py apply_af3_patches.py Dockerfile /opt/docker-recipes/

# ---- AlphaFold3 + dependencies ----------------------------------------------
# The checkout lives at /app/alphafold, NOT /app/alphafold3: nf-core/proteinfold
# hardcodes `python3 /app/alphafold/run_alphafold.py` in
# modules/local/run_alphafold3/main.nf, so this path lets the pipeline drive the
# image without overriding the module's command. If you rename it, update every
# reference below -- especially the --af3-repo argument to apply_af3_patches.py,
# which fails the build if it points at a directory that does not exist.
WORKDIR /app
RUN git clone https://github.com/google-deepmind/alphafold3.git /app/alphafold && \
    cd /app/alphafold && git checkout ${AF3_COMMIT}

# Drop the CUDA jax/nvidia pins (keep jax-triton/jaxtyping), then install AF3.
RUN cd /app/alphafold && \
    python3 /opt/docker-recipes/filter_af3_requirements.py requirements.txt requirements.rocm.txt && \
    pip install --upgrade "cmake==3.28.3" ninja pybind11 scikit_build_core numpy biopython && \
    pip install --no-build-isolation --no-deps -r requirements.rocm.txt --force-reinstall && \
    pip install -vvv --no-deps --force-reinstall --upgrade . && \
    pip install dm-haiku==0.0.16 --upgrade --no-deps --force-reinstall && \
    pip install immutabledict --no-deps && \
    build_data

# ---- HMMER 3.4 (patched with AF3's jackhmmer sequence-limit patch) ----------
RUN mkdir -p /hmmer_build && cd /hmmer_build && \
    wget -q "http://eddylab.org/software/hmmer/hmmer-${HMMER_VERSION}.tar.gz" && \
    if [ "${HMMER_VERSION}" = "3.4" ]; then \
        echo "ca70d94fd0cf271bd7063423aabb116d42de533117343a9b27a65c17ff06fbf3  hmmer-3.4.tar.gz" | sha256sum -c - ; \
    fi && \
    tar zxf "hmmer-${HMMER_VERSION}.tar.gz" && \
    cp /app/alphafold/docker/jackhmmer_seq_limit.patch . && \
    patch -p0 < jackhmmer_seq_limit.patch && \
    cd "hmmer-${HMMER_VERSION}" && ./configure --prefix /hmmer && \
    make -j"$(nproc)" && make install && ( cd easel && make install ) && \
    rm -rf /hmmer_build
ENV PATH="/hmmer/bin:${PATH}"

# ---- apply the AlphaFold3-on-AMD patches (run LAST: reinstalling tokamax
#      would revert them) -----------------------------------------------------
# Based on work from AMD in this repo: https://github.com/amd/HPCTrainingDock/tree/main/extras/scripts/alphafold3
RUN python3 /opt/docker-recipes/apply_af3_patches.py --af3-repo /app/alphafold
RUN wget https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-amd64 && \
    chmod +x jq-linux-amd64 && mv jq-linux-amd64 /usr/local/bin/jq

ENV JAX_PLATFORMS="rocm,cpu"
ENV XLA_FLAGS="--xla_gpu_enable_triton_gemm=false --xla_gpu_enable_command_buffer= --xla_gpu_autotune_level=0 --xla_disable_hlo_passes=priority-fusion"
ENV XLA_PYTHON_CLIENT_PREALLOCATE="true"
ENV XLA_PYTHON_CLIENT_MEM_FRACTION="0.95"

WORKDIR /app/alphafold

LABEL org.opencontainers.image.authors="Sarah Beecroft <sarah.beecroft@csiro.au>" \
      org.opencontainers.image.title="alphafold3_v3.0.1_rocm${ROCM_VERSION}_ubuntu24.04" \
      org.opencontainers.image.version="3.0.1" \
      org.opencontainers.image.description="AlphaFold3 v3.0.1 with ROCm ${ROCM_VERSION} support on Ubuntu 24.04 for AMD GPUs, with helper scripts for the nf-core/proteinfold pipeline" \
      org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/tree/master/setonix/gpu_biology/alphafold3/rocm7.1.1/v3.0.1"
