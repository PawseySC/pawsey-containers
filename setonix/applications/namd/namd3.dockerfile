# Build with mpich
FROM quay.io/pawsey/mpich-base:3.4.3_ubuntu24.04

SHELL [ "/bin/bash", "-c" ]

# Prefix for tarball containing source
# Cannot provide source directly due to namd license, so this recipe requires whoever is running it to already have access to the source tarball
ARG NAMD_SOURCE="NAMD_3.0.1_Source"

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
RUN wget http://www.ks.uiuc.edu/Research/namd/libraries/tcl8.6.13-linux-x86_64.tar.gz\
    && wget http://www.ks.uiuc.edu/Research/namd/libraries/tcl8.6.13-linux-x86_64-threaded.tar.gz \
    && tar xzf tcl8.6.13-linux-x86_64.tar.gz \
    && tar xzf tcl8.6.13-linux-x86_64-threaded.tar.gz \
    && mv tcl8.6.13-linux-x86_64 tcl \
    && mv tcl8.6.13-linux-x86_64-threaded tcl-threaded

# Set up build directory and build namd
RUN ./config Linux-x86_64-g++ --charm-arch mpi-linux-x86_64-smp \
    && cd Linux-x86_64-g++ \
    && gmake -j4

RUN mkdir -p /opt/namd \
    && mv ./Linux-x86_64-g++ /opt/namd/bin \
    && mv ./license.txt /opt/namd/ \
    && rm -fr /tmp/namd-build

    
WORKDIR /opt/namd

ENV PATH=/opt/namd/bin:$PATH