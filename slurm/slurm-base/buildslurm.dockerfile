# This recipe uses ubuntu as a base and 
# adds minimal packages with apt-get
# builds mpich and also some useful mpi packages for testing
# The labels present here will need to be updated

ARG OS_VERSION="24.04"
FROM ubuntu:${OS_VERSION}
#redefine arguments after the FROM command
ARG OS_VERSION="24.04"
# define slurm version for meta data 
#ARG SLURM_VERSION="22-05-2-1"
ARG SLURM_VERSION="24-11-6-1"
# for builds in parallel 
ARG NCPUS=8

LABEL org.opencontainers.image.created="2023-02"
LABEL org.opencontainers.image.authors="Pascal Jahan Elahi <pascaljelahi@gmail.com>"
LABEL org.opencontainers.image.documentation="https://github.com/"
LABEL org.opencontainers.image.source="https://github.com/pelahi/docker-recipes/slurm-base/"
LABEL org.opencontainers.image.vendor="Pawsey Supercomputing Research Centre"
LABEL org.opencontainers.image.licenses="GNU GPL3.0"
LABEL org.opencontainers.image.title="Setonix compatible slurm container"
LABEL org.opencontainers.image.description="Common base image providing slurm compatible with that on Setonix"
LABEL org.opencontainers.image.base.name="pawsey/slurmbase:ubuntu${OS_VERSION}-slurm-${SLURM_VERSION}"

# install packages like munge
ENV DEBIAN_FRONTEND="noninteractive"
ARG GCC_VERSION=13
RUN apt-get update -qq \
    && apt-get -y --no-install-recommends install \
    wget \
    bzip2 \
    perl \
    gcc-${GCC_VERSION} \
    g++-${GCC_VERSION} \
    gfortran-${GCC_VERSION} \
    git \
    gnupg \
    make \
    munge \
    libmunge-dev \
    python3-dev \
    python3-pip \
    python3 \
    # python2 \
    psmisc \
    bash-completion \
    autoconf automake libtool \
    cmake \
    less \
    #vim-enhanced \
    libhttp-parser-dev \
    libjson-glib-dev libjson-c-dev libjsonparser-dev \
    lua5.3 liblua5.3 liblua5.3-dev lua-cjson-dev lua-posix-dev \
    pkg-config \
    openssl libcurl4-openssl-dev \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-${GCC_VERSION} 100 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-${GCC_VERSION} 100 \
    && update-alternatives --install /usr/bin/gfortran gfortran /usr/bin/gfortran-${GCC_VERSION} 100 \
    && apt-get clean all \
    && rm -r /var/lib/apt/lists/* \
    && echo "Finished apt-get installs"


# now build dependencies based on schemd
# now build json 
ARG JSON_VERSION=json-c-0.15-20200726
ARG HTTP_PARSER_VERSION=v2.9.4
ARG YAML_VERSION=0.2.5
ARG JWT_VERSION=v1.12.0
RUN echo "Building json" \
    && git clone --depth 1 --single-branch -b ${JSON_VERSION} https://github.com/json-c/json-c.git json-c \
    && mkdir json-c-build \
    && cd json-c-build \
    && cmake ../json-c \
    && make -j${NPROCS} \
    && make install \
    && cd ../../ && rm -rf json-c \
    && echo "Finished json build" 
RUN echo "Building http parser" \
    && git clone --depth 1 --single-branch -b ${HTTP_PARSER_VERSION} https://github.com/nodejs/http-parser.git http_parser \
    && cd http_parser \
    && make -j${NPROCS} CC=gcc \
    && make install CC=gcc \
    && cd ../ && rm -rf http_parser \
    && echo "Finished http parser build" \
    # yaml 
    && echo "Building yaml" \
    && git clone --depth 1 --single-branch -b ${YAML_VERSION} https://github.com/yaml/libyaml libyaml \
    && cd libyaml \
    && ./bootstrap \
    && ./configure \
    && make -j${NPROCS} \
    && make install \
    && cd ../ && rm -rf libyaml \
    && echo "Finished yaml build" \
    # jwt 
    # && echo "Building jwt" \
    # && git clone --depth 1 --single-branch -b ${JWT_VERSION} https://github.com/benmcollins/libjwt.git libjwt \
    # && cd libjwt \
    # && autoreconf --force --install \
    # && ./configure --prefix=/usr/local \
    # && make -j${NPROCS} \
    # && make install \
    # && cd ../ && rm -rf libjwt \
    # && echo "Finished jwt build"
    && echo "Finished slurm dependency build"

# now build schedmd slurm 
RUN echo "Building slurm ${SLURM_VERSION}" \
    && set -x \
    && git clone -b slurm-${SLURM_VERSION} --single-branch --depth=1 https://github.com/SchedMD/slurm.git \
    && cd slurm \
    # configure slurm \
    && ./configure --enable-debug \
        --prefix=/usr \
        --sysconfdir=/etc/slurm \
        --libdir=/usr/lib64 \
    && mkdir -p /opt/slurm-build-info && cp config.log /opt/slurm-build-info/ \
    && make -j ${NCPUS} > /opt/slurm-build-info/make.log && make install \
    # then run specific install commands for the configuration file examples \
    && install -D -m644 etc/cgroup.conf.example /etc/slurm/cgroup.conf.example \
    && install -D -m644 etc/slurm.conf.example /etc/slurm/slurm.conf.example \
    && install -D -m644 etc/slurmdbd.conf.example /etc/slurm/slurmdbd.conf.example \
    && install -D -m644 contribs/slurm_completion_help/slurm_completion.sh /etc/profile.d/slurm_completion.sh \
    # finalize installation and make directories
    && cd ../ \
    && rm -rf slurm \
    && groupadd -r --gid=990 slurm \
    && useradd -r -g slurm --uid=990 slurm \
    && mkdir -p /etc/sysconfig/slurm \
        /var/spool/slurmd \
        /var/run/slurmd \
        /var/run/slurmdbd \
        /var/lib/slurmd \
        /var/log/slurm \
        /data \
    && touch /var/lib/slurmd/node_state \
        /var/lib/slurmd/front_end_state \
        /var/lib/slurmd/job_state \
        /var/lib/slurmd/resv_state \
        /var/lib/slurmd/trigger_state \
        /var/lib/slurmd/assoc_mgr_state \
        /var/lib/slurmd/assoc_usage \
        /var/lib/slurmd/qos_usage \
        /var/lib/slurmd/fed_mgr_state \
    # ensure that slurm directory is owned by slurm user/group
    && chown -R slurm:slurm /var/*/slurm* \
    && echo "Finished building slurm"

    # create munge kes 
RUN echo "Create keys" \
    #&& /sbin/create-munge-key \
    && echo "Finished keys "

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildslurm.dockerfile /opt/docker-recipes/
