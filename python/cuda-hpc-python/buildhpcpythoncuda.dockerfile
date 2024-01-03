ARG PAWSEY_BASE="3.11"
FROM quay.io/pawsey/hpc-python:${PAWSEY_BASE}

ARG CUDA_VERSION=12.3
ARG CUDA_PKG_VERSION=12-3

RUN echo "Installing CUDA" \
    && wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i cuda-keyring_1.1-1_all.deb \
    && apt-get update \
    && apt-get -y install cuda-toolkit-${CUDA_PKG_VERSION} \
    && apt-get install -y nvidia-kernel-open-545 \
    && apt-get install -y cuda-drivers-545 \
    && echo "Done"

RUN echo "Installing NVHPC SDK" \
    && curl https://developer.download.nvidia.com/hpc-sdk/ubuntu/DEB-GPG-KEY-NVIDIA-HPC-SDK | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-hpcsdk-archive-keyring.gpg \
    && echo 'deb [signed-by=/usr/share/keyrings/nvidia-hpcsdk-archive-keyring.gpg] https://developer.download.nvidia.com/hpc-sdk/ubuntu/amd64 /' | sudo tee /etc/apt/sources.list.d/nvhpc.list \
    && apt-get update -y \
    && apt-get install -y nvhpc-23-11 \
    && echo "Done"

# Update to libmozjs which is at this point version 68. Upgrade to 102 
#RUN echo "Updating libmozjs" \
#    && sed -i "s/focal/jammy/g"  /etc/apt/sources.list \
#    && apt-get update \ 
#    && apt-get install -y libmozjs-102-0 \
#    && apt-get remove -y libmozjs-68-0 \
#    && echo "Done"

ENV CUDA_VERSION 12.3
ENV CUDA_PKG_VERSION 12-3=$CUDA_VERSION-1

# # For libraries in the cuda-compat-* package: https://docs.nvidia.com/cuda/eula/index.html#attachment-a
# RUN apt-get update && apt-get install -y --no-install-recommends \
#     cuda-cudart-${CUDA_PKG_VERSION} \
#     cuda-compat-${CUDA_PKG_VERSION} \
#     && ln -s cuda-${CUDA_VERSION}} /usr/local/cuda && \
#     rm -rf /var/lib/apt/lists/*

# # Required for nvidia-docker v1
# RUN echo "/usr/local/nvidia/lib" >> /etc/ld.so.conf.d/nvidia.conf && \
#     echo "/usr/local/nvidia/lib64" >> /etc/ld.so.conf.d/nvidia.conf

# ENV PATH /usr/local/nvidia/bin:/usr/local/cuda/bin:${PATH}
# ENV LD_LIBRARY_PATH /usr/local/nvidia/lib:/usr/local/nvidia/lib64

# nvidia-container-runtime
ENV NVIDIA_VISIBLE_DEVICES all
ENV NVIDIA_DRIVER_CAPABILITIES compute,utility
ENV NVIDIA_REQUIRE_CUDA "cuda>=12.3" 
#brand=tesla,driver>=396,driver<397 brand=tesla,driver>=410,driver<411 brand=tesla,driver>=418,driver<419 brand=tesla,driver>=440,driver<441"

# ENV NCCL_VERSION 2.10.3


# RUN apt-get update && apt-get install -y --no-install-recommends \
#     cuda-libraries-$CUDA_PKG_VERSION \
#     cuda-npp-$CUDA_PKG_VERSION \
#     cuda-nvtx-$CUDA_PKG_VERSION \
#     cuda-cusparse-$CUDA_PKG_VERSION \
#     libcublas10=10.2.2.89-1 \
#     libnccl2=$NCCL_VERSION-1+cuda10.2 \
#     && apt-mark hold libcublas10 libnccl2 \
#     && rm -rf /var/lib/apt/lists/*

# RUN apt-get update && apt-get install -y --no-install-recommends \
#     cuda-nvml-dev-$CUDA_PKG_VERSION \
#     cuda-command-line-tools-$CUDA_PKG_VERSION \
#     cuda-nvprof-$CUDA_PKG_VERSION \
#     cuda-npp-dev-$CUDA_PKG_VERSION \
#     cuda-libraries-dev-$CUDA_PKG_VERSION \
#     cuda-minimal-build-$CUDA_PKG_VERSION \
#     libcublas-dev=10.2.2.89-1 \
#     libnccl-dev=$NCCL_VERSION-1+cuda10.2 \
#     && apt-mark hold libcublas-dev libnccl-dev \
#     && rm -rf /var/lib/apt/lists/*

# ENV LIBRARY_PATH /usr/local/cuda/lib64/stubs

##### END   NVIDIA CUDA DOCKERFILES ####

