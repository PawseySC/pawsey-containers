FROM ubuntu:22-rocm5.6-mpich3.4.3

ENV _GLIBCXX_USE_CXX11_ABI=1
ENV USE_CUDA=0
ENV USE_ROCM=1
ENV CXX=g++
ENV CC=gcc
ENV CXXFLAGS=-std=c++17
ENV PYTORCH_ROCM_ARCH=gfx90a	

RUN	apt -y install libopenblas-dev \
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

RUN	cd /tmp/build \
	&& git clone --recursive https://github.com/pytorch/pytorch \
	&& cd pytorch \
	&& grep -R . -e "MPI_CXX" | cut -f1 -d: | xargs -n1 sed -i -e "s/MPI_CXX/MPI_C/g" \
	# if you are updating an existing checkout \
	&& git submodule sync \
	&& git submodule update --init --recursive \
	# sets "USE_SYSTEM_EIGEN_INSTALL=ON"
	&& sed -i -e '270d' -e '269a ON)' CMakeLists.txt \
	# Install deps	
	&& python3 -m pip install -r requirements.txt \
	&& make triton\
	&& python3 tools/amd_build/build_amd.py\
	&& python3 setup.py install 
	
	#export HOROVOD_WITHOUT_MXNET=1
	#export HOROVOD_WITH_PYTORCH=1
	#export HOROVOD_GPU=ROCM
	#export HOROVOD_GPU_OPERATIONS=NCCL
	#export HOROVOD_WITHOUT_GLOO=1
	#export HOROVOD_WITHOUT_TENSORFLOW=1
	#export HOROVOD_ROCM_PATH=/opt/rocm
	#export HOROVOD_RCCL_HOME=/opt/rocm/rccl
	#export RCCL_INCLUDE_DIRS=/opt/rocm/rccl/include
	#export HOROVOD_RCCL_LIB=/opt/rocm/rccl/lib
	#export HCC_AMDGPU_TARGET=gfx90a
	#
	#git clone https://github.com/horovod/horovod.git
	#cd horovod
	#sed -i 's/set(CMAKE_CXX_STANDARD 14)/set(CMAKE_CXX_STANDARD 17)/g' CMakeLists.txt
	#python3 setup.py install	

RUN	[ -e /tmp/build ] && rm -rf /tmp/build

#%environment
#	export NCCL_DEBUG=INFO
#	export NCCL_SOCKET_IFNAME=hsn
#	export CXI_FORK_SAFE=1
#	export CXI_FORK_SAFE_HP=1
#	export FI_CXI_DISABLE_CQ_HUGETLB=1
