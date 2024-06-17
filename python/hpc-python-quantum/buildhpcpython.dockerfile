ARG MPICH_VERSION=3.4.3
ARG OS_VERSION=ubuntu23.04
ARG AER_VERSION=0.14.2
#ARG IMAGE_VERSION="3.4.3_ubuntu23.04_lustrerelease"
FROM quay.io/pawsey/mpich-lustre-base:${MPICH_VERSION}_${OS_VERSION}_lustrerelease
ARG PY_VERSION=3.11

LABEL org.opencontainers.image.created="2024-06"
LABEL org.opencontainers.image.authors="Shusen Liu <shusen.liu@pawsey.org.au>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/python/quantum/buildhpcpython.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Qiskit for Setonix compatible python container"
LABEL org.opencontainers.image.description="Integrate qiskit into base image providing python on Setonix built on the lustre aware mpich"
LABEL org.opencontainers.image.base.name="pawsey/hpcpython:${PY_VERSION}-ubuntu23.04"

# add python 
ENV DEBIAN_FRONTEND="noninteractive"
RUN echo "Updating python to ${PY_VERSION}" \
    && apt-get update -qq \
    && apt install -y --no-install-recommends software-properties-common \
    && if [ ${OS_VERSION} != "ubuntu23.04" ]; then add-apt-repository ppa:deadsnakes/ppa; apt-get update -qq; fi \
    && apt-get -y --no-install-recommends install \
        python${PY_VERSION}-dev python${PY_VERSION}-distutils python${PY_VERSION}-full \
    && apt-get clean all \
    && rm -r /var/lib/apt/lists/* \
    && echo "Done"
RUN echo "Setting default python to desired version" \
    && update-alternatives --install /usr/bin/python python /usr/bin/python${PY_VERSION} 1 \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PY_VERSION} 1 \
    && if [ ${OS_VERSION} != "ubuntu23.04" ]; then \
        curl -sS https://bootstrap.pypa.io/get-pip.py | sudo python3; \
        curl -sS https://bootstrap.pypa.io/get-pip.py | python3; \
        python -m pip install --upgrade --break-system-packages pip; \
       fi \
    && pip install --break-system-packages pip-tools \
    && echo "Done "

ENV SCRFOLDER=/opt/src
RUN mkdir -p ${SCRFOLDER}

#Download src and checkout
RUN git clone https://github.com/Qiskit/qiskit-aer ${SCRFOLDER}/qiskit-aer-scr &&\
    cp -r ${SCRFOLDER}/qiskit-aer-scr ${SCRFOLDER}/qiskit-aer &&\
    cd ${SCRFOLDER}/qiskit-aer-scr &&\
    git checkout ${AER_VERSION}  &&\
    ls -la ${SCRFOLDER}/qiskit-aer-scr

RUN python3 -m venv /opt/venv && \
    . /opt/venv/bin/activate && \
    cd ${SCRFOLDER}/qiskit-aer-scr &&\
    pip --no-cache-dir install --break-system-packages -r ${SCRFOLDER}/qiskit-aer-scr/requirements-dev.txt &&\
    pip install pybind11 &&\
    ls -la ${SCRFOLDER}/qiskit-aer-scr

#Build and install qiskit-aer on OMP and MPI
RUN . /opt/venv/bin/activate && \
    python ${SCRFOLDER}/qiskit-aer-scr/setup.py bdist_wheel -- \
  -DCMAKE_CXX_COMPILER=CC \
  -DCMAKE_BUILD_TYPE=Release \
  -DAER_MPI=True \
  -DAER_THRUST_BACKEND=OMP \
  -DAER_DISABLE_GDR=True \
  -DPYBIND11_INCLUDE_DIR=$(python -c "import pybind11; print(pybind11.get_include())") \
  -- 

RUN . /opt/venv/bin/activate &&\
   pip install /dist/qiskit_aer*.whl

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildhpcpython.dockerfile /opt/docker-recipes/

# Final
CMD ["/bin/bash"]
