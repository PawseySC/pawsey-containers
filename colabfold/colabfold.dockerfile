FROM quay.io/pawsey/rocm-mpich-base:rocm6.1-mpich3.4.3-ubuntu22

RUN apt-get update && \
    apt install apt-transport-https curl gnupg sed -y && \
    curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor >bazel-archive-keyring.gpg && \
    mv bazel-archive-keyring.gpg /usr/share/keyrings && \
    echo deb [arch=amd64 signed-by=/usr/share/keyrings/bazel-archive-keyring.gpg] https://storage.googleapis.com/bazel-apt stable jdk1.8 | sudo tee /etc/apt/sources.list.d/bazel.list && \
    apt-get install -y build-essential wget aria2 git cmake gcc-10 clang gfortran zlib1g-dev numactl gawk patch tar autoconf automake libtool libjson-c-dev graphviz libncurses-dev nano xz-utils binutils doxygen 

ENV PYTHON_VERSION='3.10'
ENV JAX_VERSION='0.4.28'
ENV ALPHAFOLD_VERSION='69afc4d'
ENV ARIA2_VERSION='1.36.0'
ENV HHSUITE_VERSION='3.3.0'
ENV OPENMM_VERSION='8.0.0'
ENV OPENMM_HIP_VERSION='1631e8d'

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
  cmake -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" -DCMAKE_INSTALL_PREFIX=$HHSUITE_PATH .. ; \
  make -j   ; \
  make -j install  ; \
  rm -rf /opt/builds




RUN set -eux ; \
  curl -LO https://repo.anaconda.com/miniconda/Miniconda3-py310_23.3.1-0-Linux-x86_64.sh ; \
  bash ./Miniconda3-* -b -p /opt/miniconda3 -s ; \
  rm -rf ./Miniconda3-*
ENV PATH /opt/miniconda3/bin:$PATH

ENV CC gcc
ENV CXX g++

RUN set -eux ; \
  conda install -y \
  conda=23.11.0
RUN conda install -y -c conda-forge -c bioconda \
    swig \
    numpy==1.24.3 \
    Cython \
    pandas==2.0.3 \
    dm-tree==0.1.8 \
    pdbfixer==1.9 \
    kalign2=2.04 \
    mmseqs2=15.6f452 \ 
    streamhpc::openmm-hip ; \
    conda clean -af
RUN pip install \
    tensorflow \
    ml-collections==0.1.0 \
    dm-haiku==0.0.12 \
    hmmer \
    absl-py==1.0.0 \
    mock \
    chex==0.0.7 \
    immutabledict==2.0.0 \
    scipy==1.11.1 \
    biopython==1.79 --no-cache-dir



ENV JAX_PLATFORMS "rocm"

ENV ROCM_PATH=/opt/rocm-6.1.0
RUN cd /opt/rocm-6.1.0/bin; mv rocm_agent_enumerator rocm_agent_enumerator_old; echo "echo gfx90a" >> rocm_agent_enumerator; chmod 0777 rocm_agent_enumerator;

ENV CURRENTPATH='/opt'
ENV COLABFOLDDIR="${CURRENTPATH}/localcolabfold"

RUN mkdir -p "${COLABFOLDDIR}"
RUN cd "${COLABFOLDDIR}"
RUN /opt/miniconda3/bin/python3 -m pip install "colabfold[alphafold]"
RUN /opt/miniconda3/bin/python3 -m pip install "dm-haiku==0.0.12" 
# Download the updater
RUN wget -qnc -O "$COLABFOLDDIR/update_linux.sh" \
    https://raw.githubusercontent.com/YoshitakaMo/localcolabfold/main/update_linux.sh
RUN chmod +x "$COLABFOLDDIR/update_linux.sh"

# Use 'Agg' for non-GUI backend && 
# modify the default params directory &&
# remove cache directory
RUN cd /opt/miniconda3/lib/python3.10/site-packages/colabfold && sed -i -e "s#from matplotlib import pyplot as plt#import matplotlib\nmatplotlib.use('Agg')\nimport matplotlib.pyplot as plt#g" plot.py && sed -i -e "s#appdirs.user_cache_dir(__package__ or \"colabfold\")#\"${COLABFOLDDIR}/colabfold\"#g" download.py && \
  rm -rf __pycache__

# Download weights
RUN python3 -m colabfold.download
ENV CXXFLAGS=--offload-arch=gfx90a
RUN pip uninstall -y jax jaxlib
# install ColabFold and Jaxlib
RUN mkdir /opt/build-jax;\
    cd /opt/build-jax &&\
    git clone --branch rocm-jaxlib-v0.4.28-qa  https://github.com/ROCm/jax.git &&\
    git clone --branch rocm-jaxlib-v0.4.28-qa  https://github.com/ROCm/xla.git &&\
    cd jax &&\
    git status &&\
    /opt/miniconda3/bin/python3 -m pip install build &&\
    /opt/miniconda3/bin/python3 ./build/build.py --enable_rocm --rocm_amdgpu_targets=gfx90a --bazel_options=--override_repository=xla=/opt/build-jax/xla --rocm_path=/opt/rocm-6.1.0

RUN cd /opt/build-jax/jax &&\
   /opt/miniconda3/bin/python3 setup.py develop --user && /opt/miniconda3/bin/python3 -m pip install dist/*.whl


ENV PYTHONPATH=/opt/build-jax/jax:${PYTHONPATH}
WORKDIR ${COLABFOLDDIR}
