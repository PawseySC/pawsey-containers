FROM quay.io/pawsey/rocm-mpich-base:rocm6.3.3-mpich3.4.3-ubuntu24.04

RUN apt-get update && \
    apt-get install -y apt-transport-https && \
    apt-get install -y \
    build-essential \
    wget \
    git \
    libxml2 \
    aria2 \
    gcc \
    g++ \
    doxygen \
    autoconf \
    rccl \
    liblapack-dev \
    libopenblas-dev \
    hmmer \
    kalign \
    unzip && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get autoremove -y && \
    apt-get clean

#
# ROCm environment
#
ENV ROCM_RELEASE=6.3.3
ENV ROCM_PATH=/opt/rocm-$ROCM_RELEASE

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws

#
# Install miniforge (mamba)
#
RUN set -eux ; \
    curl -L -O "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh" ; \
    bash Miniforge3-$(uname)-$(uname -m).sh -b -p /opt/miniforge3 -s ; \
    rm -rf ./Miniforge3-*
ENV PATH=/opt/miniforge3/bin:$PATH

RUN mamba install -y -c conda-forge -c bioconda python=3.9 \
    pdbfixer==1.9 \
    mmseqs2=15.6f452
RUN mamba install -y -c streamhpc -c conda-forge --strict-channel-priority openmm-hip && \
    mamba clean -afy

# Configure pip to allow system-wide packages (appropriate for containers)
RUN pip config set global.break-system-packages true && \
    pip install --no-cache-dir --use-pep517 \
    modelcif==0.7 \
    "swig>=3.0.5" \
    ml-collections \
    dm-tree \
    pytorch-lightning \
    deepspeed==0.16.0 \
    pandas \
    PyYAML \
    requests \
    tqdm \
    typing-extensions \
    wandb==0.17.0 \
    matplotlib \
    einops \
    omegaconf \
    biotite==0.37.0 \
    "scipy<=1.15.0" \
    biopython==1.81 \
    numpy==1.26.4

#HHSUITE#
WORKDIR /opt
RUN mkdir /opt/hhsuite && \
    cd /opt/hhsuite && \
    wget https://github.com/soedinglab/hh-suite/releases/download/v3.3.0/hhsuite-3.3.0-SSE2-Linux.tar.gz && \
    tar xvfz hhsuite-3.3.0-SSE2-Linux.tar.gz && \
    rm hhsuite-3.3.0-SSE2-Linux.tar.gz
ENV PATH=/opt/hhsuite/bin:/opt/hhsuite/scripts:$PATH

RUN pip install torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 --index-url https://download.pytorch.org/whl/rocm6.3 --no-cache-dir

# Install OpenFold
WORKDIR /opt
RUN git clone https://github.com/aqlaboratory/openfold.git --branch v1.0.1
WORKDIR /opt/openfold
# Download folding resources
RUN wget --no-check-certificate -P openfold/resources \
    https://git.scicore.unibas.ch/schwede/openstructure/-/raw/7102c63615b64735c4941278d92b554ec94415f8/modules/mol/alg/src/stereo_chemical_props.txt

# Certain tests need access to this file
RUN mkdir -p tests/test_data/alphafold/common && \
    ln -rs openfold/resources/stereo_chemical_props.txt tests/test_data/alphafold/common

WORKDIR /opt/openfold
COPY * /opt/docker-recipes/
COPY nocuda_setup.py .
RUN python nocuda_setup.py install && rm /opt/openfold/openfold/utils/kernel/attention_core.py
COPY amd_attention_core.py /opt/openfold/openfold/utils/kernel/attention_core.py
COPY amd_attention_core.py /opt/miniforge3/lib/python3.9/site-packages/openfold/utils/kernel/attention_core.py
COPY openfold_structure_module.py /opt/openfold/openfold/model/structure_module.py
COPY openfold_structure_module.py /opt/miniforge3/lib/python3.9/site-packages/openfold/model/structure_module.py
RUN sed -i 's/deepspeed\.utils\.is_initialized()/deepspeed.comm.comm.is_initialized()/g' /opt/miniforge3/lib/python3.9/site-packages/openfold/model/primitives.py

# Install ESMFold dependencies
RUN pip install --no-cache-dir git+https://github.com/facebookresearch/esm.git

ENV TORCH_HOME=/scratch/references/esmfold/models
ENV TRITON_CACHE_DIR=/tmp/triton_cache
ENV XDG_CACHE_HOME=/tmp

LABEL org.opencontainers.image.authors="Sarah Beecroft <sarah.beecroft@csiro.au>" \
      org.opencontainers.image.title="esmfold1_v1.0.3_rocm6.3.3_ubuntu24.04" \
      org.opencontainers.image.version="1.0.3" \
      org.opencontainers.image.description="ESMFold v1.0.3 with ROCm 6.3.3 support on Ubuntu 24.04 for AMD GPUs" \
      org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/tree/master/setonix/gpu_biology/esmfold1/rocm6.3.3/v1.0.3"
