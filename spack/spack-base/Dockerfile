# This recipe uses ubuntu as a base and 
# adds minimal packages with apt-get
# adds spack and the default base image is 
# set to build on top of the pawsey provided mpich image

ARG BASE_IMAGE="pawsey:mpich-setonix"
FROM ${BASE_IMAGE}
ARG SPACK_VERSION=v0.19
# currently this is a build time argument in the 
# recipe but eventually will migrate so that 
# this is extracted from the base image 
ARG MPICH_VERSION=3.4.3

LABEL org.opencontainers.image.created="2023-02"
LABEL org.opencontainers.image.authors="Pascal Jahan Elahi <pascal.elahi@pawsey.org.au.com>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers/spack/buildspack.dockerfile"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Setonix compatible MPICH base with Spack added"
LABEL org.opencontainers.image.description="Common base image providing mpi compatible with cray-mpich used on Setonix"
LABEL org.opencontainers.image.base.name="pawsey/spack-${SPACK_VERSION}:mpibase:ubuntu-mpich-setonix"
LABEL org.opencontainers.image.spack.version="${SPACK_VERSION}"


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
    && numpyver=$(pip freeze | grep numpy | sed "s:==: :g" | awk '{print $2}') \
    && scipyver=$(pip freeze | grep scipy | sed "s:==: :g" | awk '{print $2}') \
    && sixver=$(pip freeze | grep six | sed "s:==: :g" | awk '{print $2}') \
    # set the config 
    && echo "\n  python: \n\
    externals:\n\
    - spec: python@${pyver}\n\
      prefix: /usr\n\
    buildable: false\n\
  py-numpy:\n\
    externals:\n\
    - spec: py-numpy@${numpyver}\n\
      prefix: /usr\n\
    buildable: false\n\
  py-scipy:\n\
    externals:\n\
    - spec: py-scipy@${scipyver}\n\
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
  mpich:\n\
    externals:\n\
    - spec: mpich@${MPICH_VERSION}\n\
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
    && echo "Finished"

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildspack.dockerfile /opt/docker-recipes/

