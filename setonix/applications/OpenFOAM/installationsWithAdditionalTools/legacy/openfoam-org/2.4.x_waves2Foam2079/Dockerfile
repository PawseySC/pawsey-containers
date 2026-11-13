#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
##IMPORTANT: This recipe is still failing!
#Here create an image with waves2Foam 
#from the already existing and working image of openfoam
FROM quay.io/pawsey/openfoam-org:2.4.x
#OpenFOAM version using:
ARG OFVERSION="2.4.x"

LABEL maintainer="Alexis.Espinosa@pawsey.org.au"
#Using bash from now on
SHELL ["/bin/bash","-c"]

USER root

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
#Trick for making apt-get work again. This is very weird.
#Following the solution proposed here:
#https://sillycodes.com/quick-tip-couldnt-create-temporary-file/
#But modified a little bit in order to  let apt-get install -y to work fine
RUN apt-get clean \
 && mv /var/lib/apt/lists/partial /tmp \
 && mkdir -p /var/lib/apt/lists/partial \
 && apt-get clean \
 && apt-get update

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# Repeating settings from the basic installation
ARG OFINSTDIR=/opt/OpenFOAM
ARG OFUSERDIR=/home/ofuser/OpenFOAM
ARG OFTHIRDPARTYDIR=${OFINSTDIR}/ThirdParty-${OFVERSION}
ARG OFPREFS=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/prefs.sh
ARG OFBASHRC=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/bashrc
ARG ParaView_VERSION=4.1.0
ARG ParaView_ShortVERSION=4.1

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# I. Installing additional tools needed for waves2Foam
RUN apt-get update -qq\
 &&  apt-get -y --no-install-recommends --no-install-suggests install \
     libgsl0-dev subversion gfortran git ca-certificates\
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# II. Installation of waves2Foam
#...........
# A. First cloning the repo
#waves2Foam release to use: (Check release list in https://openfoamwiki.net/index.php/Contrib/waves2Foam) 
ARG WAVES2RELEASE=2079
#define the installation dir
ARG WAVES2INSTALLDIR=/opt
##ARG WAVES2INSTALLDIR=$OFUSERDIR/ofuser-${OFVERSION}/applications/utilities
#clone the repostiory for the required release
RUN . ${OFBASHRC} \
 && if [ ! -d $WAVES2INSTALLDIR ]; then mkdir -p $WAVES2INSTALLDIR; fi \
 && cd $WAVES2INSTALLDIR \
 && git clone https://github.com/ethan1366/waves2Foam.git
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
#--Dummy line:
 && echo ''

#...........
# C. Fixing the options for the momentumFluxBodyFixedHorizontal postProcessing utility to compile
RUN . ${OFBASHRC} \
 && . ${WAVES2BASHRC} \
 && ln -s -f $WAVES_POST/surfaceElevation/Make/options $WAVES_POST/momentumFluxBodyFixedHorizontal/Make/options

#...........
# D. The installation command
RUN . ${OFBASHRC} \
 && ./Allwmake 2>&1 | tee log.Allwmake

#...........
# E. Checking if waveFoam and other tools/solvers are working
RUN . ${OFBASHRC} \
 && . ${WAVES2BASHRC} \
 && cd $WAVES_DIR \
 && waveFoam -help 2>&1 | tee log.waveFoam \
 && momentumFluxBodyFixedHorizontal -help 2>&1 | tee log.momentumFluxBodyFixedHorizontal

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
## Setup to source OpenFoam OFBASHRC at container startup with Docker
# Note: OFBASHRC has several bash-isms and need to be interpreted with a bash shell
# Docker: will execute scripts in /etc/profile.d/ at startup when using "bash -l" at the ENTRYPOINT (see below).
#         Instructions to source OFBASHRC are included in zz_openfoam.sh script:
RUN echo 'if [ -z ${DEFINE_ME_ONCE+x} ] ; then' >/etc/profile.d/zz_openfoam.sh && \
    echo " . ${OFBASHRC}" >>/etc/profile.d/zz_openfoam.sh && \
    echo " . ${WAVES2BASHRC} noPrint" >>/etc/profile.d/zz_openfoam.sh && \
    echo ' export DEFINE_ME_ONCE="1"' >>/etc/profile.d/zz_openfoam.sh && \
    echo 'fi' >>/etc/profile.d/zz_openfoam.sh
# Docker: to enable sourcing of OFBASHRC at startup, need to have a login shell with `-l`:
ENTRYPOINT [ "/bin/bash", "-l", "-c", "$*", "--" ]
CMD [ "/bin/bash" ]

#...........
## Setup to source OpenFoam OFBASHRC at container startup when using Singularity
# Note: OFBASHRC has several bash-isms and need to be interpreted with a bash shell
# Singularity: will execute scripts in /.singularity.d/env/ at startup (and ignore those in /etc/profile.d/).
#              Standard naming of "environment" scripts is 9X-environment.sh
#              Here we copy the zz_openfoam.sh script into 91-environment.sh
#              (copy is preferred over sourcing files in /etc/profile.d/ from a 9X-environment.sh script):
RUN mkdir -p /.singularity.d/env/ && \
    cp -p /etc/profile.d/zz_openfoam.sh /.singularity.d/env/91-environment.sh
# Singularity: trick to source startup scripts using bash shell
#              (OpenFoam OFBASHRC needs bash shell, not sh):
#Already done in parent image:RUN /bin/mv /bin/sh /bin/sh.original && /bin/ln -s /bin/bash /bin/sh


#...........
## Starting as ofuser by default
USER ofuser
WORKDIR /home/ofuser
