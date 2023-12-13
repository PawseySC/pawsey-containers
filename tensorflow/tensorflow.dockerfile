FROM ubuntu:22-rocm5.6.0-mpich3.4.3
RUN python3 -m pip install --prefix=/usr --force-reinstall --upgrade --no-cache-dir "tensorflow-rocm==2.12.1.570" # "tensorflow-rocm==2.13.0.570

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

RUN python3 -m pip install --prefix=/usr --force-reinstall --upgrade --no-cache-dir "horovod==0.28.1"
RUN echo 'export TF_CPP_MIN_LOG_LEVEL=3' >> /.singularity.d/env/91-environment.sh 
