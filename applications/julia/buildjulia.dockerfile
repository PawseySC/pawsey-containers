# This recipe uses rocm+mpich image
# and adds rocm-enabled julia

ARG ROCM_VERSION=6.0.2
ARG BASE_IMAGE="quay.io/pawsey/rocm-mpich-base:"
#FROM quay.io/pawsey/rocm-mpich-base:rocm${ROCM_VERSION}-mpich3.4.3-ubuntu22
FROM ${BASE_IMAGE}
ARG JULIA_VERSION=1.10.2

WORKDIR /tmp/
RUN echo "Running julia installer" \
    && curl -fsSL https://install.julialang.org | sh -s -- --yes -p /opt/julia \
    && /opt/julia/bin/juliaup add ${JULIA_VERSION} \
    && /opt/julia/bin/juliaup default ${JULIA_VERSION} \
    && echo "Finished"

ENV DEBIAN_FRONTEND="noninteractive"
RUN echo "Add amd package" \
    && apt-get update -qq \
    && apt-get -y --no-install-recommends install \
        rocm-libs hipcub miopen-hip \ 
    && apt-get clean all \
    && rm -r /var/lib/apt/lists/* \
    && echo "import Pkg; Pkg.add(\"AMDGPU\")" >> /tmp/addamdgpu.jl \
    && ls /opt/julia/bin/julia \
    && /opt/julia/bin/julia --version \ 
    && /opt/julia/bin/julia /tmp/addamdgpu.jl \ 
    && echo "Finished"

ENV PATH="$PATH:/opt/julia/bin/"
RUN mkdir -p /.singularity.d/env/
RUN echo "export PATH=$PATH:/opt/julia/bin/"  >> /.singularity.d/env/91-environment.sh 

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildjulia.dockerfile /opt/docker-recipes/

