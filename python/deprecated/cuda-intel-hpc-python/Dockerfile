ARG PAWSEY_BASE="2022.03"
FROM quay.io/pawsey/intel-hpc-python:${PAWSEY_BASE}

ARG CUDATOOLKIT_VERSION="10.2.89"
RUN conda install --no-deps -y cudatoolkit==${CUDATOOLKIT_VERSION} \
      && conda clean -ay
