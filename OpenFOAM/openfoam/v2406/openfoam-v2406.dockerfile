
#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition of global parameters
# Global arguments needed in several stages
#(will need to call them at the begining of each stage to recover these values)
ARG OFVERSION="v2406"
ARG OFINSTDIR=/opt/OpenFOAM
ARG OFUSER=ofuser
#Using DEBIAN_FRONTEND and TZ definitions to avoid interactive questions in apt-get
ARG DEBIAN_FRONTEND=noninteractive
ARG TZ=Australia/Perth


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# A. Basic Stage.
# Defining the base container to use
# IMPORTANT: Setonix mpi containers need at least ubuntu24.04 (From August 2025)
FROM quay.io/pawsey/mpich-base:3.4.3_ubuntu24.04 AS basic_stage
#---------------------------------------------------------------
# A.1 Grabbing global parameters, defining labels, defining Dockerfile shell
LABEL maintainer="Alexis.Espinosa@pawsey.org.au"
#Using bash from now on
SHELL ["/bin/bash","-c"]

#---------------------------------------------------------------
# A.2 Installing useful tools for interactive sessions and pulling source files
RUN apt-get update -qq\
 &&  apt-get -y --no-install-recommends install \
            vim time \
            cron gosu \
            bc curl wget \
            git \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#---------------------------------------------------------------
# A.3. Setting a user for interactive sessions and development of own tools
#Recent native developers' containers are not using this "ofuser" anymore, although it is still useful to have it
#for Pawsey purposes, where some directory in $MYSOFTWARE in Pawsey cluster,
#needs to be mounted to the path in WM_PROJECT_USER_DIR which is set to point to
#somewhere in the tree of OFUSERDIR (see section C.3).
# Recall global definitions made at the top
#ARG OFINSTDIR
#ARG OFUSER
# Useful variables
ARG OFUSERDIR=/home/${OFUSER}/OpenFOAM
# Creating the ofuser
RUN groupadd -g 10001 $OFUSER \
 && useradd -m -u 10001 -g $OFUSER $OFUSER
# Creting its corresponding working directory and changing owner and permissions
RUN mkdir -p ${OFUSERDIR}/${OFUSER}-${OFVERSION} \
 && chown -R $OFUSER:$OFUSER ${OFUSERDIR} \
 && chmod -R 755 ${OFUSERDIR}


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# B. Install dependencies
FROM basic_stage AS install_dependencies
#---------------------------------------------------------------
# B.1 Install OpenFOAM dependencies
# OpenFOAM v2406+ source dependencies for Ubuntu 24.04 LTS
# Aggregated from:
# [1] https://develop.openfoam.com/Development/openfoam/-/blob/maintenance-v2406/doc/Build.md
# [2] https://develop.openfoam.com/Development/ThirdParty-common/-/blob/v2406/Requirements.md
# [3] https://www.openfoam.com/news/main-news/openfoam-v2406
# [4] https://gitlab.com/openfoam/core/openfoam/-/blob/master/doc/Build.md
RUN apt-get update -qq\
 && apt-get --no-install-recommends --no-install-suggests --yes install \
    build-essential flex bison cmake ca-certificates zlib1g-dev \
    libboost-system-dev libboost-thread-dev \
#AEG:No OpenMPI because MPICH will be used (installed in the parent FROM image)
#AEG:NoOpenMPI:    libopenmpi-dev openmpi-bin \
    libopenmpi-dev openmpi-bin \
    gnuplot libreadline-dev libncurses-dev libxt-dev \
    qtbase5-dev qtchooser qt5-qmake qtbase5-dev-tools \
#AEG:NO qtwebkit5 as it fail to install due to lack of support due to vulenrability issues
#AEG:NoQTWebKit5    qtwebkit5-dev libqt5webkit5-dev \
    libqt5opengl5-dev \
    libgl1-mesa-dev libglu1-mesa-dev freeglut3-dev \
    libcgal-dev libfftw3-dev \
#AEG:No scotch because it installs openmpi which later messes up with MPICH
#    Therefore, ThirdParty scotch is the one to be installed and used by openfoam.
#AEG:NoScotch:    scotch scotch-openmpi scotch-openmpi-dev \
#cleaning part of the command:
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#---------------------------------------------------------------
# For the record, this was the originally suggested list of dependencies:
#     build-essential flex bison cmake zlib1g-dev \
#     libboost-system1.83-dev libboost-thread1.83-dev \
#     libopenmpi-dev openmpi-bin \
#     gnuplot libreadline8 libncurses6 libxt6 \
#     qtbase5-dev qtchooser qt5-qmake qtbase5-dev-tools \
#     qtwebkit5-dev libqt5webkit5-dev \
#     libqt5opengl5-dev \
#     libgl1-mesa-dev libglu1-mesa-dev freeglut3-dev \
#     libcgal-dev libfftw3-dev \
#     scotch scotch-openmpi scotch-openmpi-dev


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# C. Define OpenFOAM and Third-Party settings for installation
FROM install_dependencies AS define_settings
#---------------------------------------------------------------
# C.1 Activating the global ARGs to be used in this stage




#---------------------------------------------------------------
# C.1 Download
# Recall global definitions made on the top
ARG OFVERSION
ARG OFINSTDIR
#Change to the installation dir, download OpenFOAM and untar
WORKDIR $OFINSTDIR
RUN wget --no-check-certificate -O OpenFOAM-${OFVERSION}.tgz \
    "https://sourceforge.net/projects/openfoam/files/OpenFOAM-${OFVERSION}.tgz?use_mirror=mesh" \
 && wget --no-check-certificate -O ThirdParty-${OFVERSION}.tgz \
    "https://sourceforge.net/projects/openfoam/files/ThirdParty-${OFVERSION}.tgz?use_mirror=mesh" \
 && tar -xvzf OpenFOAM-${OFVERSION}.tgz \
 && tar -xvzf ThirdParty-${OFVERSION}.tgz \
 && rm -f OpenFOAM-${OFVERSION}.tgz \
 && rm -f ThirdParty-${OFVERSION}.tgz

#---------------------------------------------------------------
# C.2 Updating the prefs.sh file
# Recall global definitions made on the top
ARG OFVERSION
ARG OFINSTDIR
# Defining the prefs.sh file and its template
ARG OFPREFS=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/prefs.sh
ARG OFPREFSTEMPLATE=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config.sh/example/prefs.sh
# Creating the prefs.sh file from the template and update settings
RUN head -23 $OFPREFSTEMPLATE > $OFPREFS \
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
#--Leaving active only the options that worked among the different suggestions (A,B,C)
#  ~(A)The suggestions from the link above:
## && echo 'export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX"' >> ${OFPREFS} \
## && echo 'export MPI_ARCH_INC="-I/usr/include/mpich"' >> ${OFPREFS} \
## && echo 'export MPI_ARCH_LIBS="-L/usr/lib/x86_64-linux-gnu -lmpich"' >> ${OFPREFS} \
#
#  ~(B)The suggestions from the file mplibMPICH file are:
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
 && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OFPREFS}

#---------------------------------------------------------------
# C.3 Updating the bashrc file
# Recall global definitions made on the top
ARG OFVERSION
ARG OFINSTDIR
# Defining the bashrc file & backing up the original. Defining other arguments.
ARG OFBASHRC=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/bashrc
RUN cp ${OFBASHRC} ${OFBASHRC}.original
# Update settings in the bashrc file
#Changing the installation directory within the bashrc file (This is not in the openfoamwiki instructions)
RUN sed -i 's/^projectDir=/# projectDir=/g' ${OFBASHRC} \
 && sed -i '0,/\[ -n "$projectDir"/s//# \[ -n "$projectDir"/' ${OFBASHRC} \
 && sed -i '0,/^# projectDir="$HOME.*/!b;//a\projectDir="'"${OFINSTDIR}"'/OpenFOAM-$WM_PROJECT_VERSION"' ${OFBASHRC} \
#" (This comment line is needed to let vi to show the right syntax)
#Changing the place for your own tools/solvers (WM_PROJECT_USER_DIR directory) within the bashrc file 
#IMPORTANT:When using this container, you have two options when building your own tools/solvers:
#   1. You can mount a directory of your local-host into this directory (as explained at the end of the Dockerfile)
#   2. Or you can include and build stuff inside the container and save it as your own image for later use.
 && sed -i '/^export WM_PROJECT_USER_DIR=.*/aexport WM_PROJECT_USER_DIR="'"${OFUSERDIR}/ofuser"'-$WM_PROJECT_VERSION"' ${OFBASHRC} \
 && sed -i '0,/^export WM_PROJECT_USER_DIR/s//# export WM_PROJECT_USER_DIR/' ${OFBASHRC}

#...........
FROM define_settings AS stop_here
#Step 4.
#Install one or the other: paraview or VTK
#Install paraview or VTK for runTimePostprocessing of OpenFOAM to properly compile
#Install paraview for catalyst module to properly compile (wont work with just VTK)
#Install paraview for graphical postprocessing to be available in the container 

##Paraview compilation (Adapted alternative instructions from OpenFoamWiki)
RUN . ${OFBASHRC} \
#AEG: recomendation in the ThirdParty-xx/README.md:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt5 \
#AEG: makeParaView failing due to bash-isms, changing explicitly to bash:
 && cp makeParaView makeParaView.original \
 && sed -i '\,^#!/bin/sh.*,i#!/bin/bash' makeParaView \
 && sed -i 's,^#!/bin/sh,###!/bin/sh,' makeParaView \
 && ./makeParaView -python -mpi -python-lib /usr/lib/x86_64-linux-gnu/libpython2.7.so.1.0 2>&1 | tee log.makePV

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

#Third party compilation
RUN . ${OFBASHRC} \
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
ARG OFCONTROL
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
