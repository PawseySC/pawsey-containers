FROM quay.io/pawsey/rocm-mpich-base:rocm6.3.3-mpich3.4.3-ubuntu24.04
ENV ROCM_PATH=/opt/rocm

ARG TF_VERSION=2.17.0

# RUN apt update && apt -y install wget
RUN mkdir -p ~/.config/pip
RUN echo "[global]" >> ~/.config/pip/pip.conf
RUN echo "break-system-packages = true" >> ~/.config/pip/pip.conf
RUN cd /opt/rocm/bin; mv rocm_agent_enumerator rocm_agent_enumerator_old; echo "echo gfx90a" >> rocm_agent_enumerator; chmod 0777 rocm_agent_enumerator;


RUN echo "Building tensorflow ${TF_VERSION}" \
    && tf_major=$(echo ${TF_VERSION} | sed "s/\./ /g" | awk '{print $1}') \
    && tf_minor=$(echo ${TF_VERSION} | sed "s/\./ /g" | awk '{print $2}') \
    && if [ "$tf_minor" -eq 15 ]; then \
        # Libraries for tensorflow/2.15.1 + horovod/0.28.1 to both successfully build
        apt-get update -qq \
        && apt-get -y --no-install-recommends install \
            libbz2-dev \
            libdb-dev \
            libgdbm-dev \
            libgdbm-compat-dev \
            liblzma-dev \
            libsqlite3-dev \
            libncurses-dev \
            libffi-dev \
            uuid-dev \
            tk-dev \
            xz-utils \
            libnss3-dev \
            libexpat1-dev \
            libtirpc-dev \
            libnsl-dev \
        # Need python/3.10 for tensorflow/2.15.1
        && mkdir -p /tmp/python-build \
        && cd /tmp/python-build \
        && wget https://www.python.org/ftp/python/3.10.12/Python-3.10.12.tgz \
        && tar xzf Python-3.10.12.tgz \
        && cd Python-3.10.12 \
        && ./configure \
            --prefix=/usr \
            --exec-prefix=/usr \
            --bindir=/usr/bin \
            --libdir=/usr/lib \
            --includedir=/usr/include \
            --enable-optimizations \
            --enable-shared \
        && make -j 4 \
        && make altinstall \
        && cd / \
        && rm -rf /tmp/python-build \
        && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 \
        && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 2 \
        && update-alternatives --set python3 /usr/bin/python3.10 \
        # Install tensorflow
        && wget https://repo.radeon.com/rocm/manylinux/rocm-rel-6.3.3/tensorflow_rocm-2.15.1-cp310-cp310-manylinux_2_28_x86_64.whl \
        && python3 -m pip install --prefix=/usr --upgrade --no-cache-dir tensorflow_rocm-2.15.1-cp310-cp310-manylinux_2_28_x86_64.whl; \
    else \
        wget https://repo.radeon.com/rocm/manylinux/rocm-rel-6.3.3/tensorflow_rocm-2.17.0-cp312-cp312-manylinux_2_28_x86_64.whl \
        && python3 -m pip install --prefix=/usr --upgrade --no-cache-dir ./tensorflow_rocm-2.17.0-cp312-cp312-manylinux_2_28_x86_64.whl; \
    fi

ENV HOROVOD_WITHOUT_MXNET=1
ENV HOROVOD_WITHOUT_PYTORCH=1
ENV HOROVOD_GPU=ROCM
ENV HOROVOD_GPU_OPERATIONS=NCCL
ENV HOROVOD_WITHOUT_GLOO=1
ENV HOROVOD_WITH_TENSORFLOW=1
ENV HOROVOD_ROCM_PATH=/opt/rocm
ENV HOROVOD_RCCL_HOME=/opt/rocm/rccl
ENV RCCL_INCLUDE_DIRS=/opt/rocm/rccl/include
ENV HOROVOD_RCCL_LIB=/opt/rocm/rccl/lib
ENV HCC_AMDGPU_TARGET=gfx90a

# Install horovod (not compatible with tensorflow > 2.15)
RUN tf_major=$(echo ${TF_VERSION} | sed "s/\./ /g" | awk '{print $1}') \
    && tf_minor=$(echo ${TF_VERSION} | sed "s/\./ /g" | awk '{print $2}') \
    && if [ "$tf_minor" -eq 15 ]; then \
        mkdir -p /tmp/horovod-build \
        && cd /tmp/horovod-build \
        && git clone --recursive https://github.com/horovod/horovod.git \
        && cd horovod \
        && rm -rf build/ horovod.egg-info/ dist/ \
        && ln -s "$ROCM_PATH/lib/cmake/hip/FindHIP"* cmake/Modules/ \
        && sed -i 's/rccl\.h/rccl\/rccl\.h/' horovod/common/ops/nccl_operations.h \
        && python3 setup.py bdist_wheel \
        && python3 -m pip install --ignore-installed --force-reinstall --no-cache-dir dist/horovod-0.28.1-cp310-cp310-linux_x86_64.whl; \
    fi


# RUN python3 -m pip install --force-reinstall "numpy<=1.24.0"
# RUN python3 -m pip install --prefix=/usr --force-reinstall --upgrade --no-cache-dir "horovod==0.28.1"
RUN echo 'export TF_CPP_MIN_LOG_LEVEL=3' >> /.singularity.d/env/91-environment.sh
RUN echo 'export ROCM_PATH=/opt/rocm' >> /.singularity.d/env/91-environment.sh
