# This recipe uses ubuntu as a base and 
# adds minimal packages with apt-get
# adds spack and the default base image is 
# set to build on top of the pawsey provided mpich image

ARG BASE_IMAGE="quay.io/pawsey/spack:0.20.0-mpich-lustre"
FROM ${BASE_IMAGE}

WORKDIR /
RUN echo "Building nektar dependencies" \
    && /usr/bin/spack/spack install -j16 \
    hdf5@1.12.2+cxx+fortran+hl~ipo~java+mpi+shared+szip~threadsafe+tools api=v110 build_type=Release \
    && /usr/bin/spack/spack install -j16 boost@1.80.0 +atomic+chrono~clanglibcpp \  
        +container~context~contract~coroutine\
        ~date_time~debug+exception~fiber+filesystem~graph~graph_parallel~icu+iostreams~json~locale~log+math+mpi+multithreaded\
        ~nowide~numpy+pic+program_options~python~random+regex+serialization+shared~signals~singlethreaded~stacktrace+system\
        ~taggedlayout~test+thread~timer~type_erasure~versionedlayout~wave \
    && /usr/bin/spack/spack install --reuse -j16 petsc@3.16.1~complex metis parmetis \
    && /usr/bin/spack/spack install -j16 --reuse --only dependencies \
        nektar+arpack+mpi+hdf5+fftw+scotch \
    && echo "Done "

# these are the arguments to get nektar to work 
# for silly reasons, there is no include of blas and lapack headers
# so it is easier to just have netkar build it's own version
# the build is also quite bad and not including appropriate headers
# for libraries and so needs to have the cmake files patched 
ARG NEKTAR_VERSION=v5.5.0
ARG NEKTAR_CMAKE_ARGS="-DNEKTAR_USE_MPI=ON -DNEKTAR_USE_ARPACK=ON -DNEKTAR_USE_FFTW=ON \
-DNEKTAR_USE_HDF5=ON -DNEKTAR_USE_METIS=ON -DNEKTAR_USE_SCOTCH=ON -DNEKTAR_BUILD_PYTHON=OFF \
-DNEKTAR_USE_PETSC=ON \
-DTHIRDPARTY_BUILD_ARPACK=OFF -DTHIRDPARTY_BUILD_BLAS_LAPACK=ON -DTHIRDPARTY_BUILD_BOOST=OFF \
-DTHIRDPARTY_BUILD_FFTW=OFF -DTHIRDPARTY_BUILD_HDF5=OFF -DTHIRDPARTY_BUILD_METIS=OFF -DTHIRDPARTY_BUILD_SCOTCH=OFF \
-DTHIRDPARTY_BUILD_PETSC=OFF \
-DCMAKE_INSTALL_PREFIX=/usr/"
RUN echo "Building nektar" \
    && mkdir -p /opt/nektar && cd /opt/nektar \
    && . /root/spack/spack/share/spack/setup-env.sh \
    # store the spack script and also edit it so it sets the LD_LIBARARY_PATH
    && spack load --sh arpack-ng petsc hdf5@1.12.2 metis parmetis fftw scotch boost@1.80.0 cmake \
        > /opt/nektar/set_spack_env.sh \
    && grep "export PATH=" /opt/nektar/set_spack_env.sh | sed "s:export PATH=:export LD_LIBRARY_PATH=:g" | sed "s;/bin:;/lib:;g" >> /opt/nektar/set_spack_env.sh \
    && . /opt/nektar/set_spack_env.sh \
    && git clone http://gitlab.nektar.info/nektar/nektar nektar++ \
    && cd nektar++ && git fetch --tags && git checkout ${NEKTAR_VERSION} \
    # remove non-functioning findHDF5 and use inbuilt one \
    && rm cmake/FindHDF5.cmake \
    # update the include path for metis \
    && sed -i "s:TARGET_LINK_LIBRARIES(SpatialDomains LINK_PRIVATE \${METIS_LIBRARY}):TARGET_LINK_LIBRARIES(SpatialDomains LINK_PRIVATE \${METIS_LIBRARY})\n    TARGET_INCLUDE_DIRECTORIES(SpatialDomains PRIVATE \${METIS_INCLUDE_DIR}):g" library/SpatialDomains/CMakeLists.txt \
    && mkdir -p build && cd build \ 
    && cmake ${NEKTAR_CMAKE_ARGS} ../ \
    && make -j8 && make install \
    && echo "Done "

RUN rm -rf /opt/nektar/nektar++
RUN mkdir -p /.singularity.d/env/
RUN echo "export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:\${PETSC_DIR}/lib/" >> /opt/nektar/set_spack_env.sh \
    && echo "export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:\${BOOST_ROOT}/lib/" >> /opt/nektar/set_spack_env.sh \
    && echo "export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/usr/lib64/:/usr/lib64/netkar++/" >> /opt/nektar/set_spack_env.sh \
    && echo "export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/usr/bin/spack/linux-ubuntu20.04-zen2/gcc-9.4.0/arpack-ng-3.9.0-scetpg3kqalbbrlqvjcud3gsxjm4omio/lib/" >> /opt/nektar/set_spack_env.sh \
    && cat /opt/nektar/set_spack_env.sh >> /.singularity.d/env/91-environment.sh 

# and copy the recipe into the docker recipes directory
RUN mkdir -p /opt/docker-recipes/
COPY buildnektar.dockerfile /opt/docker-recipes/

