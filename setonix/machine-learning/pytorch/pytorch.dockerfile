FROM quay.io/pawsey/rocm-mpich-base:rocm6.3.3-mpich3.4.3-ubuntu24.04

ENV _GLIBCXX_USE_CXX11_ABI=1
ENV USE_CUDA=0
ENV USE_ROCM=1
ENV CXX=g++
ENV CC=gcc
ENV CXXFLAGS=-std=c++17
ENV PYTORCH_ROCM_ARCH=gfx90a
ENV LD_LIBRARY_PATH=/opt/rocm/llvm/lib:$LD_LIBRARY_PATH
ENV ROCM_PATH=/opt/rocm

RUN cd /opt/rocm/bin; mv rocm_agent_enumerator rocm_agent_enumerator_old; echo "echo gfx90a" >> rocm_agent_enumerator; chmod 0777 rocm_agent_enumerator;
RUN cd /opt/rocm/lib/llvm/bin; mv amdgpu-arch amdgpu-arch.old;  echo "echo gfx90a" >> amdgpu-arch; chmod 0777 amdgpu-arch;

RUN	apt -y install libopenblas-dev "libpng*" "libjpeg-turbo*" libjpeg-dev python3-venv libpng-dev \
        && (! [ -e /tmp/build ] || rm -rf /tmp/build) \
        && mkdir /tmp/build && cd /tmp/build \
        # install eigen
        && wget https://gitlab.com/libeigen/eigen/-/archive/3.4.0/eigen-3.4.0.tar.gz \
        && tar xf eigen-3.4.0.tar.gz \
        && cd eigen-3.4.0 \
        && mkdir build \
        && cd build \
        && cmake .. \
        && make -j 16 \
        && make install
RUN mkdir -p ~/.config/pip
RUN echo "[global]" >> ~/.config/pip/pip.conf
RUN echo "break-system-packages = true" >> ~/.config/pip/pip.conf

RUN     cd /tmp/build \
        && git clone --branch v2.7.1 --recursive https://github.com/pytorch/pytorch \
        && cd pytorch \
        && grep -R . -e "MPI_CXX" | cut -f1 -d: | xargs -n1 sed -i -e "s/MPI_CXX/MPI_C/g" \
        # if you are updating an existing checkout \
        && git submodule sync \
        && git submodule update --init --recursive

RUN     cd /tmp/build/pytorch && sed -i -e '295d' -e '294a ON)' CMakeLists.txt \
        # Install deps
        && python3 -m pip install --break-system-packages -r requirements.txt

RUN cmake --version


RUN     cd /tmp/build/pytorch && sed -i -e '4a  python3 -m pip install --index-url ${DOWNLOAD_PYTORCH_ORG}/test/ pytorch-triton==3.3.1; exit 0' scripts/install_triton_wheel.sh && cat scripts/install_triton_wheel.sh \
	&& make triton\
        && python3 tools/amd_build/build_amd.py\
        && python3 setup.py install

RUN pip3 install jupyterlab

RUN     pip3 install mpmath urllib3 typing-extensions sympy pillow numpy networkx MarkupSafe idna fsspec filelock charset-normalizer certifi requests pytorch-triton-rocm jinja2 --index-url https://download.pytorch.org/whl/rocm6.3 --no-dependencies



# Install torch vision
RUN     cd /tmp/build \
        && git clone --branch v0.22.1 https://github.com/pytorch/vision.git \
        && cd vision \
        && python3 setup.py install

# Install torch audio
ARG CXX=hipcc
ARG ROCRAND_PATH=/opt/rocm
ARG HIPRAND_PATH=/opt/rocm
ARG ROCBLAS_PATH=/opt/rocm
ARG MIOPEN_PATH=/opt/rocm
ARG ROCFFT_PATH=/opt/rocm
ARG HIPFFT_PATH=/opt/rocm
ARG HIPSPARSE_PATH=/opt/rocm
ARG RCCL_PATH=/opt/rocm
ARG ROCPRIM_PATH=/opt/rocm
ARG HIPCUB_PATH=/opt/rocm
ARG ROCTHRUST_PATH=/opt/rocm

RUN     cd /tmp/build \
        && git clone --branch v2.7.1 https://github.com/pytorch/audio.git \
        && cd audio \
        && sed -i '149,150d' cmake/LoadHIP.cmake \
        && python3 setup.py install


RUN	[ -e /tmp/build ] && rm -rf /tmp/build
RUN echo 'export ROCM_PATH=/opt/rocm' >> /.singularity.d/env/91-environment.sh
