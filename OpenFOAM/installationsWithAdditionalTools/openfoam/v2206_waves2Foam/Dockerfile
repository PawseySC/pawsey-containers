#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
##IMPORTANT: This recipe is still failing!
#Here create an image with waves2Foam 
#from the already existing and working image of openfoam
FROM quay.io/pawsey/openfoam:v2206
#OpenFOAM version using:
ARG OFVERSION="v2206"

LABEL maintainer="Alexis.Espinosa@pawsey.org.au"
#Using bash from now on
SHELL ["/bin/bash", "-c"]

USER root

#...........
#Trick for making apt-get work again. This is very weird.
#Following the solution proposed here:
#https://sillycodes.com/quick-tip-couldnt-create-temporary-file/
#But modified a little bit in order to  let apt-get install -y to work fine
# for further installations on top of this image
RUN apt-get clean \
 && rm -rf /var/lib/apt/lists/partial \
 && mkdir -p /var/lib/apt/lists/partial \
 && apt-get clean \
 && apt-get update


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# Repeating settings from the basic installation
ARG OFINSTDIR=/opt/OpenFOAM
ARG OFUSERDIR=/home/ofuser/OpenFOAM
ARG WAVES2INSTALLDIR=/opt
ARG OFPREFS=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/prefs.sh
ARG OFBASHRC=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/bashrc

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# I. Installing additional tools needed for waves2Foam
RUN apt-get update -qq\
 &&  apt-get -y --no-install-recommends --no-install-suggests install \
     gfortran-9 git subversion gcc-9 g++-9 \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

# II. Changing default versions of packages  (according to instructions in 
# https://www.cfd-online.com/Forums/openfoam-community-contributions/205436-waves2foam-ubuntu-18-04-openfoam-1712-a.html)
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-9 90 \
    && update-alternatives --install /usr/bin/gfortran gfortran /usr/bin/gfortran-9 90

# III. Download GSL (according to https://coral.ise.lehigh.edu/jild13/2016/07/11/hello/)
RUN . ${OFBASHRC} \
    && cd ${WAVES2INSTALLDIR} \
    && wget ftp://ftp.gnu.org/gnu/gsl/gsl-2.8.tar.gz \
    && tar -zxvf gsl-2.8.tar.gz \
    && cd gsl-2.8 \
    && mkdir ${WAVES2INSTALLDIR}/gsl \
    && ./configure --prefix=${WAVES2INSTALLDIR}/gsl \
    && make \
    && make install \
    && cd .. \
    && rm -r ${WAVES2INSTALLDIR}/gsl-2.8 ${WAVES2INSTALLDIR}/gsl-2.8.tar.gz

ENV LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/opt/gsl/lib"
ENV WM_COMPILE_CONTROL="version=9"
#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# IV. Installation of waves2Foam
#...........
# A. First cloning the repo
RUN . ${OFBASHRC} \
 && if [ ! -d $WAVES2INSTALLDIR ]; then mkdir -p $WAVES2INSTALLDIR; fi \
 && cd $WAVES2INSTALLDIR \
 && svn co http://svn.code.sf.net/p/openfoam-extend/svn/trunk/Breeder_1.6/other/waves2Foam 

ARG WAVES2ROOTDIR=$WAVES2INSTALLDIR/waves2Foam

# change the mode for waves2Foam directory so it could be run and installed. because it is cloned from git
RUN chmod -R 777 $WAVES2ROOTDIR

#...........
# B. Second updating the bashrc environmental variables for the waves2Foam installation
ARG WAVES2BASHRC=$WAVES2ROOTDIR/bin/bashrc
WORKDIR $WAVES2ROOTDIR

RUN cp $WAVES2BASHRC.org $WAVES2BASHRC \
# Installation files reside in the $WAVES2FOAMDIR
 && sed -i '/^export WAVES_DIR=./aexport WAVES_DIR='"$WAVES2ROOTDIR" ${WAVES2BASHRC} \
 && sed -i '0,/^export WAVES_DIR/s//# export WAVES_DIR/' ${WAVES2BASHRC} \
# Compiled binaries will be added to the OpenFOAM $FOAM_APPBIN
 && sed -i '/^export WAVES_APPBIN=.*/aexport WAVES_APPBIN=$FOAM_APPBIN' ${WAVES2BASHRC} \
 && sed -i '0,/^export WAVES_APPBIN/s//# export WAVES_APPBIN/' ${WAVES2BASHRC} \
# Compiled libraries will be added to the OpenFOAM $FOAM_LIBBIN
 && sed -i '/^export WAVES_LIBBIN=.*/aexport WAVES_LIBBIN=$FOAM_LIBBIN' ${WAVES2BASHRC} \
 && sed -i '0,/^export WAVES_LIBBIN/s//# export WAVES_LIBBIN/' ${WAVES2BASHRC} \
# Modification in the definition of variable "version" to allow bashrc file to be interpreted in singularity
# This is not a correction for Darwin OS, but a correction for allowing the script to be interpreted
# Check original file if the line for Darwin OS needs to be reverted for real use in Darwin OS
 && sed -i '0,/^    version=.*/s/^    version=.*/#Check original file for real settings for Darwin\n&/' ${WAVES2BASHRC} \
 && sed -i '0,/^    version=.*/s/'"'"'\$'"'"'\\//g' ${WAVES2BASHRC} \
# Change GSL directory
 && sed -i '/^export WAVES_GSL_INCLUDE=.*/aexport WAVES_GSL_INCLUDE=/opt/gsl/include' ${WAVES2BASHRC} \
 && sed -i '0,/^export WAVES_GSL_INCLUDE/s//# export WAVES_GSL_INCLUDE/' ${WAVES2BASHRC} \
 && sed -i '/^export WAVES_GSL_LIB=.*/aexport WAVES_GSL_LIB=/opt/gsl/lib' ${WAVES2BASHRC} \
 && sed -i '0,/^export WAVES_GSL_LIB/s//# export WAVES_GSL_LIB/' ${WAVES2BASHRC} \
#--Dummy line:
 && echo ''

#...........
# C. The installation command
RUN . ${OFBASHRC} \
 && cd ${WAVES2ROOTDIR} \
 && ./Allwmake 2>&1 | tee log.Allwmake

#...........
# D. Checking if waveFoam and other tools/solvers are working
RUN . ${OFBASHRC} \
 && . ${WAVES2BASHRC} \
 && cd $WAVES_DIR \
 && waveFoam -help 2>&1 | tee log.waveFoam
 
#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# III. Final settings
#...........
#Allowing normal users to read,write the waves2Foam directory
RUN chmod -R 777 $WAVES2ROOTDIR

#...........
#Trick for making apt-get work again. This is very weird.
#Following the solution proposed here:
#https://sillycodes.com/quick-tip-couldnt-create-temporary-file/
#But modified a little bit in order to  let apt-get install -y to work fine
# for further installations on top of this image
RUN apt-get clean \
 && rm -rf /var/lib/apt/lists/partial \
 && mkdir -p /var/lib/apt/lists/partial \
 && apt-get clean \
 && apt-get update

#...........
# Some final touches in the WAVES2BASHRC file:
# Comment the buggy echo of the flag with the OpenFOAM version number from the WAVES2BASHRC file
RUN sed -i 's/^\(echo \$flag\)/# \1/' $WAVES2BASHRC

# Comment out the `version` assignment line for `Darwin` (This to avoid weird error at entry in Singularity)
RUN sed -i "$(grep -n 'version=`echo \$WM_PROJECT_VERSION |' $WAVES2BASHRC | head -n 1 | cut -d: -f1)s/^/#/" $WAVES2BASHRC &&\
 sed -i '/^#        version=`echo \$WM_PROJECT_VERSION |/i echo "Setting commented to avoid a weird error on entry to Singularity"' $WAVES2BASHRC

#...........
## Setup to source OpenFoam OFBASHRC at container startup with Docker
# Note: OFBASHRC has several bash-isms and need to be interpreted with a bash shell
# Docker: will execute scripts in /etc/profile.d/ at startup when using "bash -l" at the ENTRYPOINT (see below).
#   Instructions to source OFBASHRC are included in zz_openfoam.sh script:
#     The `set --` is used to bypass the error an `config.sh/setup` script when entering an interactive session.
#     So the OFBASHRC and WAVES2BASHRC scripts are called without arguments and,
#     whatever arguments provided are evaluated at the end.
RUN echo 'if [ -z ${DEFINE_ME_ONCE+x} ] ; then' >/etc/profile.d/zz_openfoam.sh && \
 echo '  ORIGINAL_ARGS="$@"' >>/etc/profile.d/zz_openfoam.sh && \
 echo '  set --' >>/etc/profile.d/zz_openfoam.sh && \
 echo "  . ${OFBASHRC}" >>/etc/profile.d/zz_openfoam.sh && \
 echo "  . ${WAVES2BASHRC} noPrint" >>/etc/profile.d/zz_openfoam.sh && \
 echo '  export DEFINE_ME_ONCE="1"' >>/etc/profile.d/zz_openfoam.sh && \
 echo '  eval "$ORIGINAL_ARGS"' >>/etc/profile.d/zz_openfoam.sh && \
 echo 'fi' >>/etc/profile.d/zz_openfoam.sh

# Docker: to enable sourcing of OFBASHRC at startup, need to have a login shell with `-l`:
ENTRYPOINT [ "/bin/bash", "-l", "-c", "$*", "--" ]
CMD [ "/bin/bash" ]

#...........
## Setup to source OpenFoam OFBASHRC at container startup when using Singularity
# Note: OFBASHRC has several bash-isms and need to be interpreted with a bash shell
# Singularity: will execute scripts in /.singularity.d/env/ at startup (and ignore those in /etc/profile.d/).
#              Standard naming of "environment" scripts is 9X-environment.sh
#   Instructions to source OFBASHRC are included in 91-environment.sh script:
#   (Note that script is now different from the one needed for Docker, so we don't copy the Docker script anymore)
#    RUN mkdir -p /.singularity.d/env/ && \
#    cp -p /etc/profile.d/zz_openfoam.sh /.singularity.d/env/91-environment.sh
RUN mkdir -p /.singularity.d/env/ && \
 echo 'if [ -z ${DEFINE_ME_ONCE+x} ] ; then' >/.singularity.d/env/91-environment.sh && \
 echo "  . ${OFBASHRC}" >>/.singularity.d/env/91-environment.sh && \
 echo "  . ${WAVES2BASHRC} noPrint" >>/.singularity.d/env/91-environment.sh && \
 echo '  export DEFINE_ME_ONCE="1"' >>/.singularity.d/env/91-environment.sh && \
 echo 'fi' >>/.singularity.d/env/91-environment.sh

# Singularity: trick to source startup scripts using bash shell
#              (OpenFoam OFBASHRC needs bash shell, not sh):
#Already done in parent OpenFOAM image:RUN /bin/mv /bin/sh /bin/sh.original && /bin/ln -s /bin/bash /bin/sh

#...........
## Starting as ofuser by default
USER ofuser
WORKDIR /home/ofuser
