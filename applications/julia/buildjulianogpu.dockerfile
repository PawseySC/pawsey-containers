# This recipe uses rocm+mpich image
# and adds rocm-enabled julia

ARG BASE_IMAGE="quay.io/pawsey/mpich-base:3.4.3_ubuntu23.04"
FROM ${BASE_IMAGE}
ARG JULIA_VERSION=1.10.2

WORKDIR /tmp/
RUN echo "Running julia installer" \
    && curl -fsSL https://install.julialang.org | sh -s -- --yes -p /opt/julia \
    && /opt/julia/bin/juliaup add ${JULIA_VERSION} \
    && /opt/julia/bin/juliaup default ${JULIA_VERSION} \
    && echo "Finished"


ENV PATH="$PATH:/opt/julia/bin/"
RUN mkdir -p /.singularity.d/env/
RUN echo "export PATH=$PATH:/opt/julia/bin/"  >> /.singularity.d/env/91-environment.sh 

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildjulianogpu.dockerfile /opt/docker-recipes/

