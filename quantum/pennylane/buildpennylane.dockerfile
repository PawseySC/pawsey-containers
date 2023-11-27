# This recipe uses pennylane as a base and 
# adds some extra python packages

ARG PENNYLANE_VERSION="0.33.1-lightning-kokkos-rocm"
FROM pennylaneai/pennylane:${PENNYLANE_VERSION}
ARG PENNYLANE_VERSION="0.33.1-lightning-kokkos-rocm"

ARG REQ_FILE="requirements.txt"

#define some metadata 
LABEL org.opencontainers.image.created="2023-11"
LABEL org.opencontainers.image.authors="Pascal Jahan Elahi <pascal.elahi@pawsey.org.au>, "
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/quantum/pennylane/buildpennylane.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Setonix compatible pennylane gpu with python packages"
LABEL org.opencontainers.image.description="PennyLane lightning using kokkos for AMD gpus with extra python packages for analysis"
LABEL org.opencontainers.image.base.name="pawsey/pennylane:${PENNYLANE_VERSION}}"

# build packages with spack
# note that the externals here are set based on 
# building from the pawsey mpich base image 
WORKDIR /opt/
ADD REQ_FILE /opt/container_python_requirements.txt
RUN echo "Adding python packages" \
    && pip install --requirements /opt/container_python_requirements.txt \
    echo "Finished adding python requirements"
    
