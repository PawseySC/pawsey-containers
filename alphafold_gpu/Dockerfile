FROM docker.io/library/rocm5.6:latest

RUN apt-get update && \
    apt install apt-transport-https curl gnupg -y && \
    curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor >bazel-archive-keyring.gpg && \
    mv bazel-archive-keyring.gpg /usr/share/keyrings && \
    echo deb [arch=amd64 signed-by=/usr/share/keyrings/bazel-archive-keyring.gpg] https://storage.googleapis.com/bazel-apt stable jdk1.8 | sudo tee /etc/apt/sources.list.d/bazel.list && \
    apt-get install -y build-essential wget aria2 git cmake gcc-10 clang gfortran zlib1g-dev numactl gawk patch tar autoconf automake libtool libjson-c-dev graphviz libncurses-dev nano xz-utils binutils doxygen && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get autoremove -y && \
    apt-get clean

#
# Alphafold info
#
ENV PYTHON_VERSION='3.10'
ENV JAX_VERSION='0.4.14'
ENV ALPHAFOLD_VERSION='69afc4d'
ENV ARIA2_VERSION='1.36.0'
ENV HHSUITE_VERSION='3.3.0'
ENV OPENMM_VERSION='8.0.0'
ENV OPENMM_HIP_VERSION='1631e8d'
#
# ROCm environment
#
ENV ROCM_RELEASE 5.6.0
ENV ROCM_PATH /opt/rocm-$ROCM_RELEASE
ENV PATH $ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH
ENV LD_LIBRARY_PATH $LD_LIBRARY_PATH:$ROCM_PATH/lib
#
# Mark RCCL as non-debug - this can be overriden by RCCL debug build. 
#
ENV RCCL_DEBUG 0

#
# Install miniconda
#
RUN set -eux ; \
  curl -LO https://repo.anaconda.com/miniconda/Miniconda3-py310_23.3.1-0-Linux-x86_64.sh ; \
  bash ./Miniconda3-* -b -p /opt/miniconda3 -s ; \
  rm -rf ./Miniconda3-*
ENV PATH /opt/miniconda3/bin:$PATH

ENV CC gcc
ENV CXX g++

#
# Install hh-suite.
#
ARG HHSUITE_VERSION
ENV HHSUITE_PATH /opt/hh-suite
RUN set -eux ; \
  mkdir -p /opt/builds ; \
  git clone --branch v$HHSUITE_VERSION https://github.com/soedinglab/hh-suite.git /opt/builds/hh-suite ; \
  mkdir /opt/builds/hh-suite/build ; \
  cd /opt/builds/hh-suite/build ; \
  cmake -DCMAKE_INSTALL_PREFIX=$HHSUITE_PATH .. ; \
  make -j   ; \
  make -j install  ; \
  rm -rf /opt/builds
  
#
# Install conda environment
# 
ARG PYTHON_VERSION
RUN set -eux ; \
  conda install -y \
  python=$PYTHON_VERSION \
    swig \
    numpy==1.24.3 \
    Cython \
    pandas==2.0.3 ; \
  conda install -y -c conda-forge \
    dm-tree==0.1.8 \
    pdbfixer==1.9 ; \
  conda install -y -c bioconda \
    kalign2
RUN pip install \
    tensorflow-rocm==2.12.0.560 \
    ml-collections==0.1.0 \
    dm-haiku==0.0.10 \
    hmmer \
    absl-py==1.0.0 \
    mock \
    chex==0.0.7 \
    immutabledict==2.0.0 \
    scipy==1.11.1 \
    biopython==1.79

#
# Install JAX
#
RUN python3 -m pip install https://github.com/ROCmSoftwarePlatform/jax/releases/download/jaxlib-v0.4.14/jaxlib-0.4.14+rocm560-cp310-cp310-manylinux2014_x86_64.whl
RUN python3 -m pip install https://github.com/ROCmSoftwarePlatform/jax/archive/refs/tags/jaxlib-v0.4.14.tar.gz
ENV JAX_PLATFORMS "rocm,cpu"

#
# Install OpenMM
#
ARG OPENMM_VERSION
ARG OPENMM_HIP_VERSION
ENV OPENMM_PATH /opt/openmm
RUN set -eux ; \
  mkdir -p /opt/builds/build /opt/builds/build-hip; \
  cd /opt/builds ; \
  \
  git clone https://github.com/openmm/openmm.git -b $OPENMM_VERSION /opt/builds/openmm ; \
  cd /opt/builds/build ; \
  cmake /opt/builds/openmm -DCMAKE_C_COMPILER=$ROCM_PATH/llvm/bin/clang \
                           -DCMAKE_CXX_COMPILER=$ROCM_PATH/llvm/bin/clang++ \
                           -DCMAKE_INSTALL_PREFIX=$OPENMM_PATH \
                           -DOPENMM_BUILD_COMMON=ON \
                           -DOPENMM_PYTHON_USER_INSTALL=OFF \
                           -DPYTHON_EXECUTABLE=$(which python) \
                           -DCMAKE_BUILD_TYPE=Release ; \
  make -j ; \
  make -j install ; \
  make -j PythonInstall ; \
  \ 
  git clone https://github.com/amd/openmm-hip.git /opt/builds/openmm-hip ; \
  cd /opt/builds/openmm-hip ; \
  git checkout -b mydev $OPENMM_HIP_VERSION ; \
  cd /opt/builds/build-hip ; \
  cmake /opt/builds/openmm-hip -DCMAKE_C_COMPILER=$ROCM_PATH/llvm/bin/clang \
                                      -DCMAKE_CXX_COMPILER=$ROCM_PATH/llvm/bin/clang++ \
                                      -DOPENMM_DIR=$OPENMM_PATH \
                                      -DOPENMM_SOURCE_DIR=/opt/builds/openmm \
                                      -DCMAKE_INSTALL_PREFIX=$OPENMM_PATH \
                                      -DCMAKE_BUILD_TYPE=Release ; \
  make -j ; \
  make -j install ; \
  rm -rf /opt/builds ; \
  true
  
#
# Clone alphafold 
#
ARG ALPHAFOLD_VERSION
ENV ALPHAFOLD_PATH /opt/alphafold
RUN set -eux ; \
  git clone https://github.com/deepmind/alphafold $ALPHAFOLD_PATH ; \
  \
  cd $ALPHAFOLD_PATH ; \
  git checkout -b mydev $ALPHAFOLD_VERSION ; \
  sed -i 's#CUDA#HIP#g' alphafold/relax/amber_minimize.py ; \
  \
  cd $ALPHAFOLD_PATH/alphafold/common ; \
  curl -LO https://git.scicore.unibas.ch/schwede/openstructure/-/raw/7102c63615b64735c4941278d92b554ec94415f8/modules/mol/alg/src/stereo_chemical_props.txt

RUN set -eux ; \
  rm /opt/miniconda3/lib/libstdc++.so* ; \
  ln -s /usr/lib64/libstdc++.so* /opt/miniconda3/lib

WORKDIR /opt/alphafold
