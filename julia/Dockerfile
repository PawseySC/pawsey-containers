ARG JULIA_VERSION=1.10.5

ENV JULIA_LLVM_ARGS="--opaque-pointers"
ENV JULIA_CUDA_USE_BINARY_BUILDER=false
ENV JULIA_CUDA_MEMORY_POOL=none

WORKDIR /tmp/
RUN echo "Running julia installer" \
    && wget https://julialang-s3.julialang.org/bin/linux/x64/1.10/julia-1.10.5-linux-x86_64.tar.gz \
    && tar zxvf julia-1.10.5-linux-x86_64.tar.gz -C /opt \
    #& curl -fsSL https://install.julialang.org | sh -s -- -y -p $JULIA_DEPOT_PATH\
    #&& $JULIA_DEPOT_PATH/bin/juliaup add ${JULIA_VERSION} \
    #&& $JULIA_DEPOT_PATH/bin/juliaup default ${JULIA_VERSION} \
    && echo "Finished"
ENV JULIA_DEPOT_PATH=/opt/julia-1.10.5
ENV JULIA_BINDIR=/opt/julia-1.10.5/bin



ENV DEBIAN_FRONTEND="noninteractive"

RUN echo "Add amd package" \
     && apt-get update -qq \
     && apt-get -y --no-install-recommends install \
        rocm-libs hipcub miopen-hip \
    && apt-get clean all \
    && rm -r /var/lib/apt/lists/* \
#    && echo "import Pkg;  Pkg.add(\"MPI\"); Pkg.add(\"AMDGPU\"); Pkg.add(\"MPIPreferences\");" >> /tmp/addamdgpu.jl \
#    && echo " using MPIPreferences; MPIPreferences.use_system_binary(mpiexec=\"srun\");" >> /tmp/addamdgpu.jl \
#    && ls julia \
#    && julia --version \
   # && julia --project -e 'using Pkg; Pkg.add("MPIPreferences")' \
   # && julia --project -e 'using MPIPreferences; MPIPreferences.use_system_binary()' \
   # && julia -e 'ENV["JULIA_MPI_BINARY"]="system"; using Pkg; Pkg.build("MPI"; verbose=true)' \
#    && julia /tmp/addamdgpu.jl \
    && echo "Finished"

#...........
## Setup to source OpenFoam OFBASHRC at container startup with Docker
# Note: OFBASHRC has several bash-isms and need to be interpreted with a bash shell
# Docker: will execute scripts in /etc/profile.d/ at startup when using "bash -l" at the ENTRYPOINT (see below).
#         Instructions to source OFBASHRC are included in zz_openfoam.sh script:
RUN echo 'if [ -z ${DEFINE_ME_ONCE+x} ] ; then' >/etc/profile.d/zz_julia.sh && \
    echo ' export JULIA_BINDIR="/opt/julia-1.10.5/bin" ' >>/etc/profile.d/zz_julia.sh && \
    echo ' export JULIA_PROJECT=/project' >>/etc/profile.d/zz_julia.sh && \
    echo ' export JULIA_LOAD_PATH=$JULIA_BINDIR:$JULIA_PROJECT:$JULIA_DEPOT_PATH:$LD_LIBRARY_PATH:/lib/x86_64-linux-gnu/:@v1.10:@stdlib'  >>/etc/profile.d/zz_julia.sh && \
    echo ' export JULIA_DEPOT_PATH=$JULIA_PROJECT:$JULIA_DEPOT_PATH:@stdlib' >>/etc/profile.d/zz_julia.sh && \
    echo ' export DEFINE_ME_ONCE="1"' >>/etc/profile.d/zz_julia.sh && \
    echo '  export JULIA_LLVM_ARGS="--opaque-pointers" ' >>/etc/profile.d/zz_julia.sh && \
    echo ' export JULIA_CUDA_USE_BINARY_BUILDER=false ' >>/etc/profile.d/zz_julia.sh && \
    echo ' export JULIA_CUDA_MEMORY_POOL=none ' >>/etc/profile.d/zz_julia.sh && \
    echo ' fi ' >>/etc/profile.d/zz_julia.sh
# Docker: to enable sourcing of OFBASHRC at startup, need to have a login shell with `-l`:
ENTRYPOINT [ "/bin/bash", "-l", "-c", "$*", "--" ]
CMD [ "/bin/bash" ]

RUN mkdir -p /.singularity.d/env/ && \
    cp -p /etc/profile.d/zz_julia.sh /.singularity.d/env/91-environment.sh

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY Dockerfile /opt/docker-recipes/

