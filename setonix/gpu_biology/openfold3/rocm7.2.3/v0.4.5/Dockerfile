ARG ROCM_VERSION=7.2.3
FROM rocm/dev-ubuntu-24.04:${ROCM_VERSION}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update --quiet \
    && apt-get install --no-install-recommends --yes --quiet \
        build-essential \
        cmake \
        git \
        tzdata \
        wget \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get autoremove --yes \
    && apt-get clean

ENV PIP_NO_CACHE_DIR=true

# ROCm environment
ENV ROCM_RELEASE 7.2.3
ENV ROCM_PATH /opt/rocm-$ROCM_RELEASE
ENV PATH $ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH
ENV LD_LIBRARY_PATH $LD_LIBRARY_PATH:$ROCM_PATH/lib

WORKDIR /opt

# Pin Miniforge installer (avoid "latest" busting cache every release).
ARG MINIFORGE_VERSION=25.3.0-3
RUN set -eux; \
    curl -fsSL -o /tmp/mf.sh \
      "https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-${MINIFORGE_VERSION}-Linux-$(uname -m).sh"; \
    bash /tmp/mf.sh -b -p /opt/miniforge3 -s; \
    rm -f /tmp/mf.sh
ENV PATH=/opt/miniforge3/bin:${PATH}

# Versions match those pip chose when the working
# quay.io/pawsey/openfold3:v0.4.5_rocm7.2.3 image was built (17 Aug 2026).
# openfold3 leaves these open; torch==2.13.0 is repeated in the second pip call
# so the ROCm build installed first is never replaced.
RUN git clone https://github.com/aqlaboratory/openfold-3.git --branch 0.4.5 /app/openfold-3 && \
    cd /app/openfold-3 && \
    mamba install python=3.13 -y && \
    pip install torch==2.13.0 torchvision==0.28.0 torchaudio==2.11.0 --index-url https://download.pytorch.org/whl/rocm7.2 && \
    pip install openfold3==0.4.5 torch==2.13.0 \
        numpy==2.5.2 scipy==1.18.0 pandas==3.0.5 ml-collections==1.1.0 \
        pytorch-lightning==2.6.5 torchmetrics==1.9.0 lightning-utilities==0.15.3 \
        biotite==1.7.1 rdkit==2025.9.6 pdbeccdutils==1.0.4 gemmi==0.7.5 && \
    mamba clean -afy

WORKDIR /app/openfold-3

COPY Dockerfile /opt/docker-recipes/
LABEL org.opencontainers.image.authors="Sarah Beecroft <sarah.beecroft@csiro.au>" \
      org.opencontainers.image.title="openfold3_v0.4.5_rocm7.2.3_ubuntu24.04" \
      org.opencontainers.image.version="0.4.5" \
      org.opencontainers.image.description="OpenFold3 v0.4.5 with ROCm 7.2.3 support on Ubuntu 24.04 for AMD GPUs" \
      org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/tree/master/setonix/gpu_biology/openfold3/rocm7.2.3/v0.4.5"
