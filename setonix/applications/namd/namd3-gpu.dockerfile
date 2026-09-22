# Build with mpich and rocm/7.1.0
FROM quay.io/pawsey/rocm-mpich-base:rocm7.1.0-mpich4.2.2-lustrerelease-ubuntu24.04

SHELL [ "/bin/bash", "-c" ]

# Install needed gfortran
ENV DEBIAN_FRONTEND="noninteractive"
RUN echo "Install apt packages" \
    && apt-get update -qq \
    && apt-get -y --no-install-recommends install \
        gfortran \
        && echo "Done"

ENV ROCM_PATH=/opt/rocm
# Prefix for tarball containing source
# Cannot provide source directly due to namd license, so this recipe requires whoever is running it to already have access to the source tarball
ARG NAMD_SOURCE="NAMD_3.0.3_Source"

ADD ${NAMD_SOURCE}.tar.gz /tmp/namd-build

WORKDIR /tmp/namd-build/${NAMD_SOURCE}

# Build linux-x86_64 MPI-SMP Charm++/Converse library
RUN tar xf charm-8.0.0.tar \
    && cd charm-8.0.0 \
    && env MPICXX=mpicxx ./build charm++ mpi-linux-x86_64 smp --with-production

# Install TCL and FFTW libraries
# Install fftw from source (need --with-pic option and --enable-float options not present in pre-compiled library
RUN wget http://www.fftw.org/fftw-3.3.10.tar.gz \
    && tar xzf fftw-3.3.10.tar.gz \
    && cd fftw-3.3.10 \
    && ./configure --enable-shared --enable-threads --with-pic --enable-float --prefix=/tmp/namd-build/${NAMD_SOURCE}/fftw \
    && make -j4 \
    && make install
# Obtain pre-built TCL libraries
RUN wget http://www.ks.uiuc.edu/Research/namd/libraries/tcl8.6.13-linux-x86_64.tar.gz \
    && wget http://www.ks.uiuc.edu/Research/namd/libraries/tcl8.6.13-linux-x86_64-threaded.tar.gz \
    && tar xzf tcl8.6.13-linux-x86_64.tar.gz \
    && tar xzf tcl8.6.13-linux-x86_64-threaded.tar.gz \
    && mv tcl8.6.13-linux-x86_64 tcl \
    && mv tcl8.6.13-linux-x86_64-threaded tcl-threaded

# Set up build directory and build namd, setting offload architecture
RUN sed -i 's/--offload-arch=[^ ]*/--offload-arch=gfx908,gfx90a/' ./arch/Linux-x86_64.hip \
    && sed -i 's/HIPARCH = [^ ]*/HIPARCH = "gfx908,gfx90a"/' ./arch/Linux-x86_64.hip \
    # Set up FFTW inc and lib paths
    && cat >> ./arch/Linux-x86_64.hip <<EOF
        FFTDIR=$(pwd)/fftw
        FFTINCL=-I$(FFTDIR)/include
        FFTLIB=-L$(FFTDIR)/lib64 -lfftw3f
    EOF \
    # Build GPU-resident HIP-enabled namd with fftw3
    && ./config Linux-x86_64-g++ --charm-arch mpi-linux-x86_64-smp \
         --with-hip \
         --with-fftw3 \
         --fftw-prefix $(pwd)/fftw \
         --rocm-prefix $ROCM_PATH \
         --hipcub-prefix $ROCM_PATH \
         --rocprim-prefix $ROCM_PATH \
         --with-single-node-hip \
    && cd Linux-x86_64-g++ \
    # Patch syncwarp references, which are CUDA only and break HIP build
    && sed -i 's/__syncwarp();[[:space:]]*//g' src/SequencerCUDAKernel.cu \
    && gmake -j4

RUN mkdir -p /opt/namd \
    && mv ./Linux-x86_64-g++ /opt/namd/bin \
    && mv ./license.txt /opt/namd/ \
    && rm -fr /tmp/namd-build

    
WORKDIR /opt/namd

ENV PATH=/opt/namd/bin:$PATH