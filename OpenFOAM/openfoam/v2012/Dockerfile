#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition
# Defining the base container to build from
# IMPORTANT: 
# Setonix needs at least ubuntu24.04 (From August 2025)
FROM quay.io/pawsey/mpich-base:3.4.3_ubuntu24.04


#LABEL maintainer="Alexis.Espinosa@pawsey.org.au"
#OpenFOAM version to install
ARG OFVERSION="v2012"
#Using bash from now on
SHELL ["/bin/bash", "-c"]


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# I. Installing additional tools useful for interactive sessions
RUN apt-get update -qq\
 &&  apt-get -y --no-install-recommends install \
            vim time\
            cron gosu \
            bc \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# II. Setting a user for interactive sessions (with Docker) and passwords
#The passwords will be the $OFVERSION defined above
#Give a password to root.
#Examples from here:
#https://stackoverflow.com/questions/714915/using-the-passwd-command-from-within-a-shell-script
RUN echo "root:${OFVERSION}" | chpasswd


#Create the ofuser with the same password (all the *USER* environmental variables will point towards this user)
#Recent native developers' containers are not using this "ofuser" anymore, although it is still useful to have it
#for pawsey purposes where /group needs to be used as the place for the *USER* variables. Then, /group directory
#will be mounted into the ofuser dir whenever own compiled tools are used
#CMEYER: Change 999 -> 9999 since 999 is already in use
RUN groupadd -g 9999 ofuser \
 && useradd -r -m -u 9999 -g ofuser ofuser
RUN echo "ofuser:${OFVERSION}" | chpasswd



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# III. INSTALLING OPENFOAM.
#This section is for installing OpenFOAM
#Will follow PARTIALLY the official installation instructions:
#https://www.openfoam.com/documentation/system-requirements.php
#and
#https://www.openfoam.com/code/build-guide.php
#and
#https://www.openfoam.com/download/install-source.php
#
#Will follow PARTIALLY the instructions for openfoamplus available in the wiki (latest for ubuntu is v1806):
#https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-v1806/Ubuntu
#(There are some other instructions for v1906, but not for ubuntu)
#
#Then, Will follow a combination of both
#There are other official instructions (but will not follow them now):
#https://develop.openfoam.com/Development/openfoam/-/wikis/building
#and
#https://develop.openfoam.com/Development/openfoam/blob/develop/doc/Build.md
#and
#https://develop.openfoam.com/Development/openfoam/blob/develop/doc/Requirements.md

#...........
#Definition of the installation directory within the container
ARG OFINSTDIR=/opt/OpenFOAM
ARG OFUSERDIR=/home/ofuser/OpenFOAM
WORKDIR $OFINSTDIR

#...........
#Step 1.
#Install necessary packages
#
#A warning may appear:
#debconf: delaying package configuration, since apt-utils is not installed
#But seems to be a bug:
#https://github.com/phusion/baseimage-docker/issues/319
#But harmless.
RUN apt-get update -qq\
 &&  apt-get -y --no-install-recommends --no-install-suggests install \
   wget build-essential\
   flex bison zlib1g-dev \
#AEG:No cmake because ADIOS2-2.4.6 needs at least cmake-3.12 and apt-get installs 3.10
#AEG:   cmake \
#AEG:No Boost because the third party will be used
#AEG:NoBoost:   libboost-system-dev libboost-thread-dev \
   libboost-system-dev libboost-thread-dev \
#AEG:No OpenMPI because MPICH will be used (installed in the parent FROM image)
#AEG:NoOpenMPI:   libopenmpi-dev openmpi-bin \
#AEG:No fftw3 because the third party will be used
#AEG:   libfftw3-dev \
   gnuplot libreadline-dev libncurses-dev libxt-dev \
#AEG:NoQt4:   qt4-dev-tools libqt4-dev libqt4-opengl-dev libqtwebkit-dev\ 
#AEG:Not installing qt4 (as in the official instructions), but qt5 as in the 3rd party requirements list
#CMEYER: Expanded set of qt5 libraries for ubuntu/24.04
   qtbase5-dev qttools5-dev qttools5-dev-tools qtchooser qt5-qmake qtbase5-dev-tools libqt5opengl5-dev libqt5x11extras5-dev libxt-dev \
#AEG:And these other suggested in the wiki:
   #qt5-default
   libqt5help5 qtdeclarative5-dev \
#--continue
   freeglut3-dev  \
#AEG:No scotch because it installs openmpi which later messes up with MPICH
#    Therefore, ThirdParty scotch is the one to be installed and used by openfoam.
#AEG:NoScotch:   libscotch-dev \
#AEG:No CGAL because third party will be used
#AEG:NoCGAL:   libcgal-dev \
#AEG:These libraries are needed for CGAL (system and third party) (if needed, change libgmp-dev for libgmp3-dev):
   libgmp-dev libmpfr-dev\
#AEG: Some more suggestions from the wiki instructions:
#CMEYER: python2 unavailable by default in ubuntu24.04
   #python python-dev \
   libglu1-mesa-dev \
#AEG:I found the following was needed to install  FlexLexer.h
   libfl-dev \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#...........
#Step 2. Download
#Change to the installation dir, download OpenFOAM and untar
ARG OFVERSIONFORGE=$OFVERSION
WORKDIR $OFINSTDIR
RUN wget --no-check-certificate -O OpenFOAM-${OFVERSION}.tgz \
    "https://sourceforge.net/projects/openfoam/files/OpenFOAM-${OFVERSIONFORGE}.tgz?use_mirror=mesh" \
 && wget --no-check-certificate -O ThirdParty-${OFVERSION}.tgz \
    "https://sourceforge.net/projects/openfoam/files/ThirdParty-${OFVERSIONFORGE}.tgz?use_mirror=mesh" \
 && tar -xvzf OpenFOAM-${OFVERSION}.tgz \
 && tar -xvzf ThirdParty-${OFVERSION}.tgz \
 && rm -f OpenFOAM-${OFVERSION}.tgz \
 && rm -f ThirdParty-${OFVERSION}.tgz

#...........
#Step 3. Definitions for the prefs and bashrc files.
ARG OFPREFS=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/prefs.sh
ARG OFBASHRC=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/bashrc

#...........
#Defining the prefs.sh:
RUN head -23 ${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config.sh/example/prefs.sh > $OFPREFS \
 && echo '#------------------------------------------------------------------------------' >> ${OFPREFS} \
#Using a combination of the variable definition recommended for the use of system mpich in this link:
#   https://bugs.openfoam.org/view.php?id=1167
#And in the file .../OpenFOAM-$OFVERSION/wmake/rules/General/mplibMPICH
#(These MPI_* environmental variables are set in the prefs.sh,
# and this file will be sourced automatically by the bashrc when the bashrc is sourced)
#
#--As suggested in the link above, WM_MPLIB and MPI_ROOT need to be set:
 && echo 'export WM_MPLIB=SYSTEMMPI' >> ${OFPREFS} \
 && echo 'export MPI_ROOT="/usr"' >> ${OFPREFS} \
#
#--As suggested in the link above, MPI_ARCH_FLAGS,MPI_ARCH_INC,MPI_ARCH_LIBS need to be set:
#--Leaving active only the options that worked from different suggestions (A,B,C)
#  ~(A)The suggestions from the link above:
## && echo 'export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX"' >> ${OFPREFS} \
## && echo 'export MPI_ARCH_INC="-I/usr/include/mpich"' >> ${OFPREFS} \
## && echo 'export MPI_ARCH_LIBS="-L/usr/lib/x86_64-linux-gnu -lmpich"' >> ${OFPREFS} \
#
#  ~(B)The suggestions from the file mplibMPICH are:
 && echo 'export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX -DOMPI_SKIP_MPICXX"' >> ${OFPREFS} \
## && echo 'export MPI_ARCH_INC="-isystem $MPI_ROOT/include"' >> ${OFPREFS} \
## && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpi -lrt"' >> ${OFPREFS} \
#
#  ~(C)Even further modifications were needed for some other OpenFOAM versions:
##AEG:Gcc7 has problems with the -isystem flag. Using -I instead:
 && echo 'export MPI_ARCH_INC="-I ${MPI_ROOT}/include"' >> ${OFPREFS} \
##AEG:Only one library path and using -lmpich
## && echo 'export MPI_ARCH_LIBS="-L$MPI_ROOT/lib -lmpich"' >> ${OFPREFS} \
##AEG:The two library paths and using -lmpich
 && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OFPREFS} \
#--Dummy line:
 && echo ''

#...........
#Modifying the bashrc file
RUN cp ${OFBASHRC} ${OFBASHRC}.original \
#Changing the installation directory within the bashrc file (This is not in the openfoamwiki instructions)
 && sed -i 's/^projectDir=/# projectDir=/g' ${OFBASHRC} \
 && sed -i '0,/\[ -n "$projectDir"/s//# \[ -n "$projectDir"/' ${OFBASHRC} \
 && sed -i '0,/^# projectDir="$HOME.*/!b;//a\projectDir="'"${OFINSTDIR}"'/OpenFOAM-$WM_PROJECT_VERSION"' ${OFBASHRC} \
#" (This comment line is needed to let vi to show the right syntax)
#Changing the place for your own tools/solvers (WM_PROJECT_USER_DIR directory) within the bashrc file 
#IMPORTANT:When using this container, you have two options when building your own tools/solvers:
#   1. You can mount a directory of your local-host into this directory (as explained at the end of the Dockerfile)
#   2. Or you can include and build stuff inside the container and save it as your own image for later use.
 && sed -i '/^export WM_PROJECT_USER_DIR=.*/aexport WM_PROJECT_USER_DIR="'"${OFUSERDIR}/ofuser"'-$WM_PROJECT_VERSION"' ${OFBASHRC} \
 && sed -i '0,/^export WM_PROJECT_USER_DIR/s//# export WM_PROJECT_USER_DIR/' ${OFBASHRC} \
#" (This comment line is needed to let vi to show the right syntax)
#--Dummy line:
 && echo ''

#...........
#(Additional) Installing cmake-3.12.4 as will be needed later for ADIOS2-2.6.0
#Following instructions from https://vitux.com/how-to-install-cmake-on-ubuntu-18-04
ARG CMAKEVER="3.12.4"
RUN cd ${OFINSTDIR}/ThirdParty-${OFVERSION} \
 && wget https://github.com/Kitware/CMake/releases/download/v${CMAKEVER}/cmake-${CMAKEVER}.tar.gz \
 && tar -zxvf cmake-${CMAKEVER}.tar.gz \
 && cd cmake-${CMAKEVER} \
 && ./bootstrap \
 && make \
 && make install \
 && cmake --version \
 && rm -f cmake-${CMAKEVER}.tar.gz

#...........
#Step 4.
#Install one or the other: paraview or VTK
#Install paraview or VTK for runTimePostprocessing of OpenFOAM to properly compile
#Install paraview for catalyst module to properly compile (wont work with just VTK)
#Install paraview for graphical postprocessing to be available in the container 

# CMEYER: Paraview is failing to build in ubuntu24.04 with default Python and Compiler. So Paraview (or paraFoam) will not work inside this container. 
# If there is still interest to compile it, the recommendation is to try installing an old verion of Python and gcc and attempt compilation again or else
# upgrade to ParaView/6.0.0, which compiles fine with default python and compilers in container, but may have runtime issues with older openfoam 
# due to how new it is
##Paraview compilation (Adapted alternative instructions from OpenFoamWiki)
# RUN . ${OFBASHRC} \
# #AEG: recomendation in the ThirdParty-xx/README.md:
#  && $WM_PROJECT_DIR/wmake/src/Allmake \
#  && cd $WM_THIRD_PARTY_DIR \
#  && export QT_SELECT=qt5 \
# #AEG: makeParaView failing due to bash-isms, changing explicitly to bash:
#  && cp makeParaView makeParaView.original \
#  && sed -i '\,^#!/bin/sh.*,i#!/bin/bash' makeParaView \
#  && sed -i 's,^#!/bin/sh,###!/bin/sh,' makeParaView \
#  && ./makeParaView -python -mpi -python-lib /usr/lib/x86_64-linux-gnu/libpython2.7.so.1.0 2>&1 | tee log.makePV

#AEG##...........
#AEG##Step 5.
#AEG##Install Third Party tools (preferred to do it as a separate step and not together with the full openfoam compilation) 
#AEG##Updating the BOOST version to be used:
#AEG#ARG OFCGAL=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config.sh/CGAL
#AEG#RUN cp ${OFCGAL} ${OFCGAL}.original \
#AEG# && sed -i '/^boost_version=.*/aboost_version=boost_1_64_0' ${OFCGAL} \
#AEG# && sed -i '0,/^boost_version/s//# boost_version/' ${OFCGAL} \
#AEG##" (This comment line is needed to let vi to show the right syntax)
#AEG##--Dummy line:
#AEG# && echo ''

#CMEYER: Patch files for fix to sha1 overload problem
#CMEYER: see https://develop.openfoam.com/Development/openfoam/-/issues/2496
#CMEYER: see https://develop.openfoam.com/Development/openfoam/-/commit/eb3f7dfe7443fe852b256072f337ac24effff0ac
RUN . ${OFBASHRC} \
 && cd ${WM_PROJECT_DIR}
WORKDIR /opt/OpenFOAM/OpenFOAM-v2012
COPY sha1-fix.patch /tmp/sha1-fix.patch
RUN patch -p1 < /tmp/sha1-fix.patch

#Third party compilation
RUN . ${OFBASHRC} \
#CMEYER: Update files to account for gcc/13 compiler behaviour changes in ubuntu 24.04
#CMEYER: cstdint and array needed in some files
 && sed -i '0,/^#include/ s//\#include <cstdint>\n&/' ${WM_PROJECT_DIR}/src/meshTools/searchableSurfaces/searchableSphere/searchableSphere.C \
 && sed -i '0,/^#include/ s//\#include <array>\n&/' ${WM_PROJECT_DIR}/src/meshTools/searchableSurfaces/searchableSphere/searchableSphere.C \
 && sed -i '0,/^#include/ s//\#include <cstdint>\n&/' ${WM_PROJECT_DIR}/modules/avalanche/src/avalanche/gistools/shapefile.H \
 && sed -i '0,/^#include/ s//\#include <cstdint>\n&/' ${WM_PROJECT_DIR}/src/OpenFOAM/primitives/strings/word/word.C \
 && sed -i '0,/^#include/ s//\#include <cstdint>\n&/' ${WM_PROJECT_DIR}/src/OSspecific/POSIX/printStack/printStack.C \
#AEG: recomendation in the ThirdParty-xx/README.md:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
 && cd $WM_THIRD_PARTY_DIR \
 && ./Allwmake 2>&1 | tee log.Allwmake

#...........
#Step 6.
#AEG: Compilation of "Additional components/modules" is failing due to bash-isms, changing explicitly to bash:
RUN . ${OFBASHRC} \
 && cd $WM_PROJECT_DIR \
 && cp Allwmake Allwmake.original \
 && sed -i '\,^#!/bin/sh.*,i#!/bin/bash' Allwmake \
 && sed -i 's,^#!/bin/sh,###!/bin/sh,' Allwmake

##-##:#OpenFOAM compilation (From official instructions)
##-##:ARG OFNUMPROCOPTION="-j 4"
##-##:RUN . ${OFBASHRC} \
##-##: && cd $WM_PROJECT_DIR \
##-##: && ./Allwmake $OFNUMPROCOPTION 2>&1 | tee log.Allwmake

##-##:#Obtaining a summary
##-##:RUN . ${OFBASHRC} \
##-##: && cd $WM_PROJECT_DIR \
##-##: && ./Allwmake 2>&1 | tee log.AllwmakeSummary

#OpenFOAM compilation (Adapted alternative instructions from OpenFoamWiki)
ARG OFNUMPROCOPTION="-j 4"
RUN . ${OFBASHRC} \
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && ./Allwmake $OFNUMPROCOPTION 2>&1 | tee log.Allwmake

#Obtaining a  summary 
RUN . ${OFBASHRC} \
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && ./Allwmake 2>&1 | tee log.AllwmakeSummary

#...........
#Step 7.
#Defining defaults of the controlDict
ARG OFCONTROL=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/controlDict
#...........
#Modifying the default controlDict file
RUN cp ${OFCONTROL} ${OFCONTROL}.original \
#Setting collated as default for fileHandler
 && sed -i '\@fileHandler uncollated;@a    fileHandler collated;' ${OFCONTROL} \
 && sed -i '0,\@fileHandler uncollated;@s@@// fileHandler uncollated;@' ${OFCONTROL} \
#--Dummy line:
 && echo ''

#...........
#Step 8.
##Checking if openfoam is working
RUN . ${OFBASHRC} \
 && cd $WM_PROJECT_DIR \
 && icoFoam -help 2>&1 | tee log.icoFoam

#Writing the environment variables for the installation so far:
RUN . ${OFBASHRC} \
 && cd $WM_PROJECT_DIR \
 && printenv > environment_vars_raw.env

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# IV. Final settings
#...........
#Create the openfoam user directory
USER ofuser
RUN mkdir -p ${OFUSERDIR}/ofuser-${OFVERSION} \
 && chmod -R 777 ${OFUSERDIR}
USER root

#...........
#Allowing normal users to read,write and execute on the OF installation
RUN chmod -R 777 $OFINSTDIR

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
RUN /bin/mv /bin/sh /bin/sh.original && /bin/ln -s /bin/bash /bin/sh

#...........
## Starting as ofuser by default
USER ofuser
WORKDIR /home/ofuser