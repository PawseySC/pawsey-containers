ARG PAWSEY_BASE="3.7_intel2020.2_mpich3.1.4_2"
FROM pawsey/hpc-python:${PAWSEY_BASE}

ARG CUDATOOLKIT_VERSION="10.2.89"
RUN conda install --no-deps -y cudatoolkit==${CUDATOOLKIT_VERSION} \
      && conda clean -ay
