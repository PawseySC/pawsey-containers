ARG PY_VERSION="3.9"
FROM python:${PY_VERSION}-slim

LABEL maintainer="marco.delapierre@pawsey.org.au"


# Install package dependencies
RUN apt-get update -qq \
      && apt-get -y --no-install-recommends install \
         build-essential \
         ca-certificates \
         gdb \
         gfortran \
         wget \
      && apt-get clean all \
      && rm -r /var/lib/apt/lists/*


# Build MPICH for mpi4py

ARG MPICH_VERSION="3.4.3"
#ARG MPICH_CONFIGURE_OPTIONS="--enable-fast=all,O3 --prefix=/usr FFLAGS=-fallow-argument-mismatch"
ARG MPICH_CONFIGURE_OPTIONS="--enable-fast=all,O3 --prefix=/usr FFLAGS=-fallow-argument-mismatch --with-device=ch4:ofi"
ARG MPICH_MAKE_OPTIONS="-j4"

RUN mkdir -p /tmp/mpich-build \
      && cd /tmp/mpich-build \
      && wget http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz \
      && tar xvzf mpich-${MPICH_VERSION}.tar.gz \
      && cd mpich-${MPICH_VERSION}  \
      && ./configure ${MPICH_CONFIGURE_OPTIONS} \
      && make ${MPICH_MAKE_OPTIONS} \
      && make install \
      && ldconfig \
      && cp -p /tmp/mpich-build/mpich-${MPICH_VERSION}/examples/cpi /usr/bin/ \
      && cd / \
      && rm -rf /tmp/mpich-build


# Install Python packages

ARG DATE_FILE="24Mar2022"

ADD requirements.in requirements-${DATE_FILE}.txt /
RUN pip3 --no-cache-dir install -r /requirements-${DATE_FILE}.txt --no-deps


# Final
CMD ["/bin/bash"]
