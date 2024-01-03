ARG MPICH_VERSION=3.4.3
ARG OS_VERSION=ubuntu23.04
#ARG IMAGE_VERSION="3.4.3_ubuntu23.04_lustrerelease"
FROM quay.io/pawsey/mpich-lustre-base:${MPICH_VERSION}_${OS_VERSION}_lustrerelease
ARG PY_VERSION=3.11

LABEL org.opencontainers.image.created="2024-01"
LABEL org.opencontainers.image.authors="Pascal Jahan Elahi <pascal.elahi@pawsey.org.au>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/python/hpcpython/buildhpcpython.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Setonix compatible python container"
LABEL org.opencontainers.image.description="Common base image providing python on Setonix built on the lustre aware mpich"
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

# Install Python packages
ARG DATE_FILE="12-2023"
ADD requirements.in requirements-${DATE_FILE}.txt /
RUN pip3 --no-cache-dir install --break-system-packages -r /requirements-${DATE_FILE}.txt --no-deps

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildhpcpython.dockerfile /opt/docker-recipes/

# Final
CMD ["/bin/bash"]
