FROM quay.io/pawsey/rocm-mpich-base:rocm5.6.0-mpich3.4.3-ubuntu22

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
	&& git clone --branch v2.1.0 --recursive https://github.com/pytorch/pytorch \
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
	
RUN	[ -e /tmp/build ] && rm -rf /tmp/build
