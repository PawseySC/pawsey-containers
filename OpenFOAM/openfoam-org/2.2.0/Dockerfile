#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition
# Defining the base image to build from
# IMPORTANT: 
# Setonix needs at least ubuntu20.04 (From August 2023)
# FROM quay.io/pawsey/mpich-base:3.4.3_ubuntu20.04
# IMPORTANT:
# Unfortunately current recipe does not compile correctly on ubuntu20.04,
# So, this recipe is left to use ubuntu16.04 as a starting point for further development.
# This recipe compiles and may run properly elsewhere, but will not run properly on Setonix anymore.
# For this reason, the docker image has been moved to the openfoam-legacy-2021 repository in quay.io .
FROM quay.io/pawsey/mpich-base:3.4.3_ubuntu16.04
# IMPORTANT:
# Therefore, this recipe needs to be modified to be able to compile with ubuntu20.04
# in order to be used on Setonix. This furher effort is left to users, and Pawsey will not put
# additional effort on this, as the OpenFOAM version is rather old.
# Problems that have been identified are:
# -Ubuntu20.04 does not have apt-get install for QT4 related libraries
#      + Possible solutions: = find another way for installing old QT4 libraries,
#                            or
#                            = switch to use equivalent QT5 libraries
# -Ubuntu20.04 does not have apt-get install for the old compiler gcc-5
#      + Possible solutions: = find another way for installing old gcc-5 compiler,
#                            or
#                            = swicth to the use the oldest possible compiler (like gcc-7)
#                              and perform changes in compiler configuration/code in order
#                              to allow proper compilation
#

LABEL maintainer="Alexis.Espinosa@pawsey.org.au"
#OpenFOAM version to install
ARG OFVERSION="2.2.0"
#Using bash from now on
SHELL ["/bin/bash", "-c"]


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# I. Installing additional tools useful for interactive sessions
RUN apt-get update -qq\
 &&  apt-get -y --no-install-recommends install \
            vim time\
            cron \
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
RUN groupadd -g 999 ofuser \
 && useradd -r -m -u 999 -g ofuser ofuser
RUN echo "ofuser:${OFVERSION}" | chpasswd



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# III. INSTALLING OPENFOAM.
#This section is for installing OpenFOAM
#Will follow PARTIALLY the official installation instructions:
#https://openfoam.org/download/2-2-0-source/
#
#Will follow PARTIALLY the instructions for OpenFOAM-2.2.0  available in the wiki:
#https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-2.2.0/Ubuntu#Ubuntu_13.10
#
#Then, Will follow a combination of both.
#
#(Also checking wiki for OpenFOAM-2.2.2/Ubuntu16.04 and the already successful installation recipe for 2.4.x)

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
   build-essential\
   flex bison cmake zlib1g-dev \
#AEG:No OpenMPI because MPICH will be used (installed in the parent FROM image)
#AEG:NoOpenMPI:   libopenmpi-dev openmpi-bin \
   gnuplot libreadline-dev libncurses-dev libxt-dev \
   qt4-dev-tools libqt4-dev libqt4-opengl-dev \ 
   freeglut3-dev libqtwebkit-dev \
#AEG:No scotch because it installs openmpi which later messes up with MPICH
#    Therefore, ThirdParty scotch is the one to be installed and used by openfoam.
#AEG:NoScotch:   libscotch-dev \
#AEG:I found the following was needed to install  FlexLexer.h
   libfl-dev \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#...........
#Step 2. Download
#Change to the installation dir, download openfoam 
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
#Step 3. (Additional, not in the instructions)
#Adapting settings for the use of the case: WM_MPLIB=SYSTEMMPI
#Rule files for SYSTEMMPI are not present by default in OpenFoam-2.2.0. Then, these files need to be created.
#Examples of these files were checked from the ones that do exist in standard OpenFOAM-2.4.x installation
ARG MPIRULEFILE1=${OFINSTDIR}/OpenFOAM-${OFVERSION}/wmake/rules/General/mplibSYSTEMMPI
ARG MPIRULEFILE2=${OFINSTDIR}/OpenFOAM-${OFVERSION}/wmake/rules/linux64Gcc/mplibSYSTEMMPI
ARG OFSETTINGS=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config/settings.sh
RUN echo 'PFLAGS     = $(MPI_ARCH_FLAGS)' > ${MPIRULEFILE1} \
 && echo 'PINC       = $(MPI_ARCH_INC)' >> ${MPIRULEFILE1} \
 && echo 'PLIBS      = $(MPI_ARCH_LIBS)' >> ${MPIRULEFILE1} \
 && cp ${MPIRULEFILE1} ${MPIRULEFILE2} \
 && sed -i $'s@^OPENMPI)@SYSTEMMPI)\\\n    export FOAM_MPI=mpi-system\\\n   export MPI_ARCH_PATH=$MPI_ROOT\\\n    ;;\\\nOPENMPI)@' ${OFSETTINGS}

#...........
#Step 4. Definitions for the prefs and bashrc files.
ARG OFPREFS=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/prefs.sh
ARG OFBASHRC=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/bashrc

#...........
#Defining the prefs.sh:
RUN head -23 ${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config/example/prefs.sh > $OFPREFS \
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
 && echo 'export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX"' >> ${OFPREFS} \
 && echo 'export MPI_ARCH_INC="-I${MPI_ROOT}/include"' >> ${OFPREFS} \
 && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OFPREFS} \
#
#  ~(C)Even further modifications were needed for some other OpenFOAM versions:
##AEG:Gcc7 has problems with the -isystem flag. Using -I instead:
## && echo 'export MPI_ARCH_INC="-I${MPI_ROOT}/include"' >> ${OFPREFS} \
##AEG:Only one library path and using -lmpich
## && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OFPREFS} \
##AEG:The two library paths and using -lmpich
## && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OFPREFS} \
#--Dummy line:
 && echo ''

#...........
#Modifying the bashrc file
RUN cp ${OFBASHRC} ${OFBASHRC}.original \
#Changing the installation directory within the bashrc file (This is not in the openfoamwiki instructions)
 && sed -i '/^foamInstall=$HOME.*/afoamInstall='"${OFINSTDIR}" ${OFBASHRC} \
 && sed -i '0,/^foamInstall=$HOME/s//# foamInstall=$HOME/' ${OFBASHRC} \
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
#Step 5.
#Install Third Party tools (preferred to do it as a separate step and not together with the full openfoam compilation) 

#Fix for the build options for scotch:
RUN . ${OFBASHRC} \
 && sed -i -e 's=-lz -lm -lrt=-Xlinker --no-as-needed -lz -lm -lrt=' \
    $WM_THIRD_PARTY_DIR/etc/wmakeFiles/scotch/Makefile.inc.i686_pc_linux2.shlib-OpenFOAM-*

#Third party compilation
RUN . ${OFBASHRC} \
 && cd $WM_THIRD_PARTY_DIR \
 && ./Allwmake 2>&1 | tee log.Allwmake

#...........
#Step 6.

#Fix for the flex version to be checked (idea obtained from the wiki instructions for 2.2.2 ubuntu 16.04)
#Because flex is causing problems for the compilation of openfoam also for this version
RUN . ${OFBASHRC} \
 && cd $WM_PROJECT_DIR \
 && find src applications -name "*.L" -type f -exec cp \{} \{}.original \; \
 && find src applications -name "*.L" -type f | xargs sed -i -e \
    's=\(YY\_FLEX\_SUBMINOR\_VERSION\)=YY_FLEX_MINOR_VERSION < 6 \&\& \1='

#OpenFOAM compilation 
ENV WM_NCOMPPROCS=4
RUN . ${OFBASHRC} \
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt4 \
 && ./Allwmake 2>&1 | tee log.Allwmake

#Obtaining a summary
RUN . ${OFBASHRC} \
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt4 \
 && ./Allwmake 2>&1 | tee log.AllwmakeSummary

#...........
#Step 7.
#Install one or the other: paraview or VTK
#Install paraview or VTK for runTimePostprocessing of OpenFOAM to properly compile
#Install paraview for graphical postprocessing to be available in the container 
#Note (for OpenFOAM-2.2.0 The paraview installation only worked when done after the OpenFOAM installation)

##Installation of old version of cmake (following wiki instructions for OpenFOAM-2.2.2/ubuntu16.04)
RUN . ${OFBASHRC} \
 && cd $WM_THIRD_PARTY_DIR \
 && wget --no-check-certificate "https://raw.github.com/wyldckat/scripts4OpenFOAM3rdParty/master/getCmake" \
 && chmod +x getCmake \
 && cp getCmake getCmake.original \
 && sed -i -e 's=\.3=.12.1=' getCmake \
 && ./getCmake \
 && ./makeCmake cmake-2.8.12.1 2>&1 | tee log.makeCmake \
 && cd $WM_PROJECT_DIR \
 && cp etc/config/paraview.sh etc/config/paraview.sh.original \
 && sed -i -e 's=cmake-2\.8\.4=cmake-2.8.12.1 cmake-2.8.4=' etc/config/paraview.sh

##Paraview compilation (Official instructions for 2.2.0)
#AEG: (This procedure is not working yet, needs some fix that I have not found) 
#AEG:(Also take a look into the ThirdParty-xx/README.* files)
##--##:RUN . ${OFBASHRC} \
##--##: && cd $WM_THIRD_PARTY_DIR \
##--##: && ./makeParaView | tee log.makePV

##Paraview compilation (following wiki instructions for OpenFOAM-2.2.2/ubuntu16.04)
RUN . ${OFBASHRC} \
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt4 \
 && cp ParaView-3.12.0/VTK/Rendering/vtkXOpenGLRenderWindow.cxx ParaView-3.12.0/VTK/Rendering/vtkXOpenGLRenderWindow.cxx.original \
 && sed -i -e 's=//#define GLX_GLXEXT_LEGACY=#define GLX_GLXEXT_LEGACY=' ParaView-3.12.0/VTK/Rendering/vtkXOpenGLRenderWindow.cxx \
 && ./makeParaView 2>&1 | tee log.makePV

RUN . ${OFBASHRC} \
 && cd $FOAM_UTILITIES/postProcessing/graphics/PV3Readers \ 
 && ./Allwclean \
 && ./Allwmake

#...........
#Step 8.
#Defining defaults of the controlDict

#...........
#Step 9.
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
