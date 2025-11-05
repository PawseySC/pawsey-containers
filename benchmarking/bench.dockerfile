# This recipe uses ubuntu as a base and 
# adds minimal packages with apt-get
# adds spack and the default base image is 
# set to build on top of the pawsey provided mpich image
FROM quay.io/pawsey/rocm-mpich-base:rocm7.0.2-mpich3.4.3-ubuntu24.04
ARG SPACK_VERSION=v0.23.1
# currently this is a build time argument in the 
# recipe but eventually will migrate so that 
# this is extracted from the base image 
ARG MPICH_VERSION=3.4.3

LABEL org.opencontainers.image.created="2025-10"
LABEL org.opencontainers.image.authors="Cristian Di Pietrantonio (cristian.dipietrantonio@csiro.au), Pascal Jahan Elahi <pascal.elahi@pawsey.org.au.com>"
LABEL org.opencontainers.image.documentation="https://github.com/PawseySC/pawsey-containers/"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="AMD Applications Benchmarking Suite"
LABEL org.opencontainers.image.description="A set of scientific applications compiled to run on AMD hardware."

# build packages with spack
# note that the externals here are set based on 
# building from the pawsey mpich base image 
WORKDIR /
RUN echo "Setting up spack" \
    && git clone https://github.com/spack/spack \
    && cd spack \
    && git checkout ${SPACK_VERSION} \
    && rm -rf .git \
    # config spack \
    && ./bin/spack external find && ./bin/spack compiler find

COPY packages.yaml /root/.spack/packages.yaml
    # installation path
RUN echo "# project_wide: use appropriate install locations\n\
config:\n\
  install_tree:\n\
    root: /usr/bin/spack/\n\
" >> ~/.spack/config.yaml

    # run spack to boostrap
RUN echo "test spack" \
    # generate symbolic link to spack 
    && /spack/bin/spack spec nano \
    && echo "Finished"

RUN cd /tmp && git clone https://github.com/PawseySC/pawsey-spack-config.git && cd pawsey-spack-config \
    &&  mkdir -p "/spack/var/spack/repos/pawsey" \ 
    && cp -r repo/* "/spack/var/spack/repos/pawsey/"

RUN  /spack/bin/spack repo add /spack/var/spack/repos/pawsey/
RUN /spack/bin/spack install --reuse  lammps@=20230802.4 amdgpu_target=gfx90a,gfx942 +rocm ^kokkos@3.7.02 +rocm amdgpu_target=gfx90a,gfx942 +hwloc +memkind +numactl +openmp +tuning build_type=Release ^mpich@3.4.3
RUN  apt install -y gfortran-13
RUN sed -i 's|null|gfortran-13|g' /root/.spack/linux/compilers.yaml
RUN cat /root/.spack/linux/compilers.yaml
RUN /spack/bin/spack install --reuse --only=dependencies nekrs@23.0 amdgpu_target=gfx90a,gfx942 +rocm
RUN /spack/bin/spack install --reuse nekrs@23.0 amdgpu_target=gfx90a,gfx942 +rocm
RUN /spack/bin/spack install --reuse slate@2024.10.29 +rocm amdgpu_target=gfx90a,gfx942 build_type=Release
