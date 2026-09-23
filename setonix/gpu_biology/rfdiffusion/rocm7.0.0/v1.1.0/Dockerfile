FROM rocm/dgl:dgl-2.4.0.amd0_rocm7.0.0_ubuntu22.04_py3.10_pytorch_2.7.1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=true

RUN apt-get -q update \
	&& apt-get install --no-install-recommends -y \
	build-essential \
    ca-certificates \
	git \
    wget \
	&& rm -rf /var/lib/apt/lists/* \
	&& apt-get autoremove -y \
	&& apt-get clean
	
WORKDIR /app
RUN git clone https://github.com/RosettaCommons/RFdiffusion.git && \
    cd RFdiffusion && \
    git checkout 86507b6 && \
    cd examples && \
    tar -xzvf /app/RFdiffusion/examples/ppi_scaffolds_subset.tar.gz -C /app/RFdiffusion/examples && \
    rm -rf /app/RFdiffusion/examples/ppi_scaffolds_subset.tar.gz && \
    sed -i -E \
      -e 's|(python[0-9.]*[[:space:]]+)?\.\./scripts/run_inference\.py|run_inference.py|g' \
      -e 's|\.\./models\b|/app/RFdiffusion/models|g' \
      -e 's#=(\./)?(input_pdbs|target_folds|tim_barrel_scaffold|ppi_scaffolds)/#=/app/RFdiffusion/examples/\2/#g' \
      /app/RFdiffusion/examples/*.sh && \
    sed -i 's|schedule_directory = f"{SCRIPT_DIR}/../../schedules"|schedule_directory = f"./.schedules"|g' /app/RFdiffusion/rfdiffusion/inference/model_runners.py

RUN mkdir /app/RFdiffusion/models && cd /app/RFdiffusion/models && \
    wget -q https://files.ipd.uw.edu/pub/RFdiffusion/6f5902ac237024bdd0c176cb93063dc4/Base_ckpt.pt && \
    wget -q https://files.ipd.uw.edu/pub/RFdiffusion/e29311f6f1bf1af907f9ef9f44b8328b/Complex_base_ckpt.pt && \
    wget -q https://files.ipd.uw.edu/pub/RFdiffusion/60f09a193fb5e5ccdc4980417708dbab/Complex_Fold_base_ckpt.pt && \
    wget -q https://files.ipd.uw.edu/pub/RFdiffusion/74f51cfb8b440f50d70878e05361d8f0/InpaintSeq_ckpt.pt && \
    wget -q https://files.ipd.uw.edu/pub/RFdiffusion/76d00716416567174cdb7ca96e208296/InpaintSeq_Fold_ckpt.pt && \
    wget -q https://files.ipd.uw.edu/pub/RFdiffusion/5532d2e1f3a4738decd58b19d633b3c3/ActiveSite_ckpt.pt && \
    wget -q https://files.ipd.uw.edu/pub/RFdiffusion/12fc204edeae5b57713c5ad7dcb97d39/Base_epoch8_ckpt.pt && \
    wget -q https://files.ipd.uw.edu/pub/RFdiffusion/f572d396fae9206628714fb2ce00f72e/Complex_beta_ckpt.pt && \
    wget -q https://files.ipd.uw.edu/pub/RFdiffusion/1befcb9b28e2f778f53d47f18b7597fa/RF_structure_prediction_weights.pt

RUN pip install \
    e3nn==0.5.6 \
    wandb==0.17.0 \
    decorator==5.1.0 \
    hydra-core==1.3.6 \
    pyrsistent==0.19.3 \
    icecream==2.2.0 \
    hiredis==3.4.1 \
    pyarrow==25.0.1 \
    numpy==1.26.4 \
    /app/RFdiffusion/env/SE3Transformer \
    && pip install -e /app/RFdiffusion --no-deps

# Hydra resolves config_path relative to the installed entry point, so the
# configs must sit under sys.prefix. Resolve it instead of hardcoding it.
RUN set -eux; \
    prefix="$(python -c 'import sys; print(sys.prefix)')" && \
    echo "python prefix: ${prefix}" && \
    mkdir -p "${prefix}/config/inference" && \
    cp -a /app/RFdiffusion/config/inference/. "${prefix}/config/inference/"

WORKDIR /app/RFdiffusion

ENV DGLBACKEND="pytorch"
# Singularity bind-mounts $HOME; don't let users' ~/.local pip installs shadow the image's packages.
ENV PYTHONNOUSERSITE=1
RUN chmod +x /app/RFdiffusion/helper_scripts/*.py /app/RFdiffusion/examples/*.sh /app/RFdiffusion/tests/*.py
ENV PATH="/app/RFdiffusion/scripts:/app/RFdiffusion/helper_scripts:/app/RFdiffusion/examples:/app/RFdiffusion/tests:/app:${PATH}"

COPY Dockerfile /opt/docker-recipes/
LABEL org.opencontainers.image.authors="Sarah Beecroft <sarah.beecroft@csiro.au>" \
      org.opencontainers.image.title="rfdiffusion_v1.1.0_rocm7.0.0_ubuntu22.04" \
      org.opencontainers.image.version="1.1.0" \
      org.opencontainers.image.description="RFdiffusion v1.1.0 with ROCm 7.0.0 and DGL 2.4.0 support on Ubuntu 22.04 for AMD GPUs" \
      org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/tree/master/setonix/gpu_biology/rfdiffusion/rocm7.0.0/v1.1.0"
