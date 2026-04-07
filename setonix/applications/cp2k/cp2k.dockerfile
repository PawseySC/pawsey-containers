# NOTE: This container uses the AMD Infinityhub CP2K dockerfile as a starting point - see https://github.com/amd/InfinityHub-CI/blob/main/cp2k/docker/Dockerfile

# Build with mpich and rocm/6.3.0
FROM quay.io/pawsey/rocm-mpich-base:rocm6.3.0-mpich3.4.3-ubuntu24.04

ARG CP2K_BRANCH="v2024.3"
ARG AMDGPU_TARGETS="gfx908,gfx90a"

# Add rocfft,rocblas,hipblas,hipfft paths to environment
ENV LD_LIBRARY_PATH=$ROCM_PATH/lib/hipblas:$ROCM_PATH/lib/hipfft:$ROCM_PATH/lib/rocfft:$ROCM_PATH/lib/rocblas:$LD_LIBRARY_PATH \
    LIBRARY_PATH=$ROCM_PATH/lib/rocfft:$ROCM_PATH/lib/hipblas:$ROCM_PATH/lib/rocblas:$LIBRARY_PATH \
    C_INCLUDE_PATH=$ROCM_PATH/include/rocfft:$ROCM_PATH/include/hipblas:$ROCM_PATH/include/hipfft:$ROCM_PATH/include/rocblas:$C_INCLUDE_PATH \
    CPLUS_INCLUDE_PATH=$ROCM_PATH/include/rocfft:$ROCM_PATH/include/hipfft:$ROCM_PATH/include/hipblas:$ROCM_PATH/include/rocblas:$CPLUS_INCLUDE_PATH

# Add rocm/cmake to the Environment
ENV PATH=$ROCM_PATH/bin:/opt/cmake/bin:$PATH \
    LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:$ROCM_PATH/llvm/lib \
    LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64 \
    C_INCLUDE_PATH=$ROCM_PATH/include \
    CPLUS_INCLUDE_PATH=$ROCM_PATH/include \
    CMAKE_PREFIX_PATH=$ROCM_PATH/lib/cmake

# Set cp2k directory and GPU targets
ENV CP2K_DIR=/opt/cp2k \
    AMDGPU_TARGETS=${AMDGPU_TARGETS}

SHELL [ "/bin/bash", "-c" ]

# Install required packages and dependencies
ENV DEBIAN_FRONTEND="noninteractive"
RUN echo "Install apt packages" \
    && apt-get update -qq \
    && apt-get -y --no-install-recommends install \
        gfortran \
        unzip \
        && echo "Done"

WORKDIR /opt/

# Get CP2K
RUN git clone --recursive -b ${CP2K_BRANCH} https://github.com/cp2k/cp2k.git \
      && cd cp2k/tools/toolchain \
      && ./install_cp2k_toolchain.sh \
            -j $(nproc) \
            --install-all \
            --mpi-mode=mpich \
            --math-mode=openblas \
            --gpu-ver=Mi250 \
            --enable-hip \
            --with-gcc=system \
            --with-openmpi=no \
            --with-mpich=system \
            --with-mkl=no \
            --with-acml=no \
            --with-ptscotch=no \
            --with-superlu=no \
            --with-pexsi=no \
            --with-quip=no \
            --with-plumed=no \
            --with-sirius=no \
            --with-gsl=no \
            --with-libvdwxc=no \
            --with-spglib=no \
            --with-hdf5=no \
            --with-spfft=no \
            --with-libvori=no \
            --with-libtorch=no \
            --with-elpa=no \
            --with-deepmd=no \
            --with-dftd4=no
RUN sed -i 's/hip\/bin/bin/' /opt/cp2k/tools/toolchain/install/arch/local_hip.psmp \
        && sed -i "s/gfx90a/$AMDGPU_TARGETS/" ${CP2K_DIR}/tools/toolchain/install/arch/local_hip.psmp \
        && sed -i "s/gfx90a/$AMDGPU_TARGETS/" ${CP2K_DIR}/exts/build_dbcsr/Makefile
# Inject GPU flags into the arch file (enables GPU for DBCSR and PW)
RUN sed -i '/FCFLAGS/s/$/ -D__DBCSR_ACC -D__PW_GPU/' ${CP2K_DIR}/tools/toolchain/install/arch/local_hip.psmp \
        && cp ${CP2K_DIR}/tools/toolchain/install/arch/* ${CP2K_DIR}/arch \
        && cat ${CP2K_DIR}/arch/local_hip.psmp
RUN source ${CP2K_DIR}/tools/toolchain/install/setup \
        && cd ${CP2K_DIR} \
        # Duplicate definition of hipHostAllocDefault in cp2k and rocm
        && sed -i 's/hipHostAllocDefault/cp2k_hipHostAllocDefault/g' ${CP2K_DIR}/exts/dbcsr/src/acc/hip/acc_hip.h \
        && sed -i 's/hipHostAllocDefault/cp2k_hipHostAllocDefault/g' ${CP2K_DIR}/exts/dbcsr/src/acc/hip/acc_hip.cpp \
        && make realclean ARCH=local_hip VERSION=psmp \
        && make -j $(nproc) ARCH=local_hip VERSION=psmp
RUN source ${CP2K_DIR}/tools/toolchain/install/setup \
        && cd ${CP2K_DIR} \
        && cp ${CP2K_DIR}/exe/local_hip/cp2k.psmp ${CP2K_DIR}/exe/local_hip/cp2k.psmp.dbcsr_gpu.pw_gpu \
        && cp ${CP2K_DIR}/tools/toolchain/install/arch/* ${CP2K_DIR}/arch \
        # Build no DBCSR GPU
        && sed -i '/FCFLAGS/s/-D__DBCSR_ACC//' ${CP2K_DIR}/arch/local_hip.psmp \
        && cat ${CP2K_DIR}/arch/local_hip.psmp \
        && make realclean ARCH=local_hip VERSION=psmp \
        && make -j $(nproc) ARCH=local_hip VERSION=psmp
RUN source ${CP2K_DIR}/tools/toolchain/install/setup \
        && cd ${CP2K_DIR} \
        && cp ${CP2K_DIR}/exe/local_hip/cp2k.psmp ${CP2K_DIR}/exe/local_hip/cp2k.psmp.no_dbcsr_gpu \
        && cp ${CP2K_DIR}/tools/toolchain/install/arch/* ${CP2K_DIR}/arch \
        # Restore DBCSR_ACC and disable PW GPU
        && sed -i '/FCFLAGS/s/$/ -D__DBCSR_ACC -D__NO_OFFLOAD_PW/' ${CP2K_DIR}/arch/local_hip.psmp \
        && cat ${CP2K_DIR}/arch/local_hip.psmp \
        && make realclean ARCH=local_hip VERSION=psmp \
        && make -j $(nproc) ARCH=local_hip VERSION=psmp \
        && cp ${CP2K_DIR}/exe/local_hip/cp2k.psmp ${CP2K_DIR}/exe/local_hip/cp2k.psmp.no_pw_gpu \
        && chmod -R 777 /opt/cp2k \
        && ln -s /opt/cp2k/exe/local_hip/ /opt/cp2k/bin \
        && mkdir /tmp/benchmarks 

COPY /scripts /scripts

RUN chmod -R 777 /scripts

# Adding environment variable for Running as ROOT
ENV PATH=$PATH:/opt/cp2k/bin:/scripts

WORKDIR /opt/cp2k/benchmarks

CMD ["/bin/bash"]