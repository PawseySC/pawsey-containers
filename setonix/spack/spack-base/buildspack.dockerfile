# This recipe uses ubuntu as a base and 
# adds minimal packages with apt-get
# adds spack

ARG OS_VERSION="20.04"
FROM ubuntu:${OS_VERSION}
# redefine after FROM to ensure it is defined
ARG OS_VERSION="20.04"
ARG SPACK_VERSION=v0.19

LABEL org.opencontainers.image.created="2023-02"
LABEL org.opencontainers.image.authors="Pascal Jahan Elahi <pascal.elahi@pawsey.org.au.com>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/spack/buildspack.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Setonix compatible base image with Spack added"
LABEL org.opencontainers.image.description="Common base image with spack added "
LABEL org.opencontainers.image.base.name="pawsey/spack-${SPACK_VERSION}:ubuntu-${OS_VERSION}-setonix"
LABEL org.opencontainers.image.spack.version="${SPACK_VERSION}"


# run apt-get install on a few packages
ENV DEBIAN_FRONTEND="noninteractive"
RUN apt-get update -qq \
    && apt-get -y --no-install-recommends install \
        build-essential \
        ca-certificates \
        gdb \
        gcc g++ gfortran \
        wget \
        git \
        python3-six python3-setuptools \
        patchelf strace ltrace \
        libcrypt-dev \ 
        libcurl4-openssl-dev \
        libpython3-dev \
        libreadline-dev \
        libssl-dev \
        sudo \
        autoconf \
        automake \
        bison \
        curl \
        flex \
        gcovr \
        gdb \
        libtool \
        m4 \
        make \
        openssh-server \
        patch \
        subversion \
        tzdata \
        valgrind \
        vim \
        wget \
        xsltproc \
        zlib1g-dev \
    && apt-get clean all \
    && rm -r /var/lib/apt/lists/* \
    && echo "Finished apt-get installs"

# build packages with spack
# note that the externals here are set based on 
# building from the pawsey mpich base image 
WORKDIR /root/spack
RUN echo "Setting up spack" \
    && git clone https://github.com/spack/spack \
    && cd spack \
    && git checkout releases/${SPACK_VERSION} \
    && rm -rf .git \
    # config spack \
    && ./bin/spack external find && ./bin/spack compiler find \
    # and also add python to externals 
    && pyver=$(python3 --version | awk '{print $2}') \
    && pipver=$(pip --version | awk '{print $2}') \
    && sixver=$(pip freeze | grep six | sed "s:==: :g" | awk '{print $2}') \
    # set the config 
    && echo "\n  python: \n\
    externals:\n\
    - spec: python@${pyver}\n\
      prefix: /usr\n\
    buildable: false\n\
  py-pip:\n\
    externals:\n\
    - spec: py-pip@${pipver}\n\
      prefix: /usr\n\
    buildable: false\n\
  py-six:\n\
    externals:\n\
    - spec: py-six@${sixver}\n\
      prefix: /usr\n\
    buildable: false\n\
      " >> ~/.spack/packages.yaml \
    # installation path
    && echo "# project_wide: use appropriate install locations\n\
config:\n\
  install_tree:\n\
    root: /usr/bin/spack/\n\
" >> ~/.spack/config.yaml \
    # run spack to boostrap
    && ./bin/spack spec nano \
    # generate symbolic link to spack 
    && ln -s /root/spack/spack/bin/spack /usr/bin/spack \
    && chmod +x /usr/bin/spack \
    && echo "Finished"

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildspack.dockerfile /opt/docker-recipes/

