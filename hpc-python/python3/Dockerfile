FROM pawsey/mpi-base:3.1.4

LABEL maintainer="brian.skjerven@pawsey.org.au"

# Install Python, compilers, and other utilities
RUN apt-get update -qq && apt-get -y --no-install-recommends install \
      build-essential \
      cython \
      python3-dev \
      python3-pip \
      python3-setuptools \
      && apt-get clean all \
      && rm -rf /var/lib/apt/lists/*

# Install Python packages
RUN pip3 --no-cache-dir install \
      astropy \
      h5py \
      matplotlib \
      mpi4py \
      nose \
      numpy \
      pandas \
      scikit-learn \
      scipy

CMD ["/bin/bash"]
