FROM pawsey/mpich-base:3.1.4_ubuntu18.04

LABEL maintainer="marco.delapierre@pawsey.org.au"
#Original maintainer="brian.skjerven@pawsey.org.au"

RUN apt-get update -qq && apt-get -y --no-install-recommends install \
      build-essential \
      cython \
      python-dev \
      python-pip \
      python-setuptools \
      && apt-get clean all \
      && rm -rf /var/lib/apt/lists/*

RUN pip --no-cache-dir install \
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
