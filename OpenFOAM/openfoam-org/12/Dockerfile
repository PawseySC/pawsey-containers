#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition
# .......
# Arguments needed in several stages
#(will need to call them at the begining of each stage to recover these values)
ARG OFVERSION="12"
ARG OFINSTDIR=/opt/OpenFOAM
ARG OFUSERDIR=/home/ofuser/OpenFOAM
ARG OFPREFS=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/prefs.sh
ARG OFBASHRC=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/bashrc
ARG OFCONTROL=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/controlDict
#Using DEBIAN_FRONTEND and TZ definitions to avoid interactive questions in apt-get
ARG DEBIAN_FRONTEND=noninteractive
ARG TZ=Australia/Perth

# ......
# Defining the base container to build from
# IMPORTANT: 
# Setonix mpi containers need at least ubuntu24.04 (From August 2025)
FROM quay.io/pawsey/mpich-base:3.4.3_ubuntu24.04 AS primary
ARG OFVERSION
ARG OFUSERDIR
LABEL maintainer="Alexis.Espinosa@pawsey.org.au"
#OpenFOAM version to install
#Using bash from now on
SHELL ["/bin/bash","-c"]


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# I. Installing additional tools useful for interactive sessions
RUN apt-get update -qq\
 &&  apt-get -y --no-install-recommends install \
            vim time\
            cron gosu \
            bc curl \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# II. Setting a user for interactive sessions and development of own tools
#Recent native developers' containers are not using this "ofuser" anymore, although it is still useful to have it
#for Pawsey purposes, where some directory in $MYSOFTWARE in Pawsey cluster,
#needs to be mounted to the path in WM_PROJECT_USER_DIR which is set to point to
#somewhere in the tree of OFUSERDIR (see section III).
RUN groupadd -g 10001 ofuser \
 && useradd -r -m -u 10001 -g ofuser ofuser

RUN mkdir -p ${OFUSERDIR}/ofuser-${OFVERSION} \
 && chown -R ofuser:ofuser ${OFUSERDIR} \
 && chmod -R 755 ${OFUSERDIR}


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# III. INSTALLING OPENFOAM.
#This section is for installing OpenFOAM
#Will follow PARTIALLY the official installation instructions:
#https://openfoam.org/download/source/
#
#Will follow PARTIALLY the instructions latest instructions available in the wiki:
#https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-7/Ubuntu/18.04
#https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-8
#
#Then, Will follow a combination of both

#...........
#Step 1.
#Install necessary packages
#
#A warning may appear:
#debconf: delaying package configuration, since apt-utils is not installed
#But seems to be a bug:
#https://github.com/phusion/baseimage-docker/issues/319
#But harmless.
FROM primary AS withpackages
RUN apt-get update -qq\
 && apt-get --no-install-recommends --no-install-suggests --yes install \
#(1) As indicated in official documentation
#tools for repositories and compilation:
    build-essential cmake git ca-certificates flex \
#tools for ThirdParty:
    #AEG:This installation goes in the ThirdParty section: paraview-dev \
#tools in openfoam-nopv-deps list (not repeating ones already included):
    #AEG:No openMPI as MPICH is to be used: libopenmpi-dev \
    zlib1g-dev gnuplot gnuplot-x11 libxt-dev \
#tools in openfoam-deps list (not repeating ones already included):
    libxml2-dev libhdf5-dev libavfilter-dev libtheora-dev libgl2ps-dev \
    libx11-dev libqt5x11extras5-dev libglew-dev libutfcpp-dev \
    libdouble-conversion-dev libfreetype-dev libqt5svg5-dev \
    qtxmlpatterns5-dev-tools qttools5-dev python3-dev \
    libadios2-serial-c-dev libadios2-serial-c++11-dev \
#tools not officially listed, but needed in the past:
    libfl-dev bison libboost-system-dev libboost-thread-dev \
    libreadline-dev libncurses-dev \
##AEG: CMEYER suggestion:replace qt5-default by the expanded set of qt5 libraries for older openfoams (I'll keep the commented list for reference here):
    ##qt5-default \
    #qtbase5-dev qttools5-dev qttools5-dev-tools qtchooser qt5-qmake qtbase5-dev-tools libqt5opengl5-dev libqt5x11extras5-dev libxt-dev \
#end of the command:
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#...........
#Step 2. Download
#Change to the installation dir, clone OpenFOAM directories
FROM withpackages AS preparesource
ARG OFVERSION
ARG OFINSTDIR
ARG OFUSERDIR
ARG OFPREFS
ARG OFBASHRC
ARG OFCONTROL

ARG OFVERSIONGIT=$OFVERSION
WORKDIR $OFINSTDIR
#Try git or https protocol:
RUN git clone https://github.com/OpenFOAM/OpenFOAM-${OFVERSIONGIT}.git \
 && git clone https://github.com/OpenFOAM/ThirdParty-${OFVERSIONGIT}.git

##RUN git clone git://github.com/OpenFOAM/OpenFOAM-${OFVERSIONGIT}.git \
## && git clone git://github.com/OpenFOAM/ThirdParty-${OFVERSIONGIT}.git

#...........
#Step 3. Definitions for the prefs, bashrc and controlDict files.
#...........
#Defining the prefs.sh:
RUN head -23 ${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config.sh/example/prefs.sh > $OFPREFS \
 && echo '#------------------------------------------------------------------------------' >> ${OFPREFS} \
#Using a combination of the variable definition recommended for the use of system mpich in this link:
#   https://bugs.openfoam.org/view.php?id=1167
#And in the file /opt/OpenFOAM/OpenFOAM-$OFVERSION/wmake/rules/General/mplibMPICH
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
## && echo 'export MPI_ARCH_INC="-isystem ${MPI_ROOT}/include"' >> ${OFPREFS} \
 && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OFPREFS} \
#
#  ~(C)Even further modifications were needed for some other OpenFOAM versions:
##AEG:Gcc7 has problems with the -isystem flag. Using -I instead:
 && echo 'export MPI_ARCH_INC="-I ${MPI_ROOT}/include"' >> ${OFPREFS} \
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
 && sed -i 's/^export FOAM_INST_DIR=/# export FOAM_INST_DIR=/g' ${OFBASHRC} \
 && sed -i '0,/\[ "$BASH"/s//# \[ "$BASH"/' ${OFBASHRC} \
 && sed -i '0,/\[ "$ZSH_NAME"/s//# \[ "$ZSH"/' ${OFBASHRC} \
 && sed -i '0,/^# export FOAM_INST_DIR=.*/!b;//a\export FOAM_INST_DIR='"${OFINSTDIR}" ${OFBASHRC} \
#" (This comment line is needed to let vi to show the right syntax when editing this Dockerfile)
#Changing the place for your own tools/solvers (WM_PROJECT_USER_DIR directory) within the bashrc file 
#IMPORTANT:When using this container, you have two options when building your own tools/solvers:
#   1. You can mount a directory of your local-host into this directory
#   2. Or you can include and build stuff inside the image and save it as your own image for later use.
 && sed -i '/^export WM_PROJECT_USER_DIR=.*/aexport WM_PROJECT_USER_DIR="'"${OFUSERDIR}/ofuser"'-$WM_PROJECT_VERSION"' ${OFBASHRC} \
 && sed -i '0,/^export WM_PROJECT_USER_DIR/s//# export WM_PROJECT_USER_DIR/' ${OFBASHRC} \
#" (This comment line is needed to let vi to show the right syntax when editing this Dockerfile)
#--Dummy line:
 && echo ''

#...........
#Defining Best Practices as defaults of the controlDict
RUN cp ${OFCONTROL} ${OFCONTROL}.original \
#Setting collated as default for fileHandler
 && sed -i '\@fileHandler uncollated;@a    fileHandler collated;' ${OFCONTROL} \
 && sed -i '0,\@fileHandler uncollated;@s@@// fileHandler uncollated;@' ${OFCONTROL} \
#--Dummy line:
 && echo ''

#...........
#Step 4.
#Install Third Party tools (preferred to do it as a separate step and not together with the full openfoam compilation) 
#AEG:NoThirdPartyCGAL&Boost. There is no indication for how to install CGAL or Boost here.
#                            So, if needed, will first be tried to install with apt-get at the top of this recipe.
#                            It seems that "foamyHexMesh" has been deprecated, so CGAL seems not to be needed.
#Third party compilation
#Bashrc options to be used
FROM preparesource AS thirdpartyinstall
ARG OFBASHRC
ARG BASHRC_OPTIONS=""

RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_THIRD_PARTY_DIR \
 && ./Allwmake 2>&1 | tee log.Allwmake

#...........
#Step 5.
#Install one or the other: paraview or VTK
#Install paraview or VTK for runTimePostprocessing of OpenFOAM to properly compile
#Install paraview for graphical postprocessing to be available in the container
#Catalyst tools are not available for the foundation version

#AEG: foundation source files do not count with makeVTK script, so will not attempt to install VTK
FROM thirdpartyinstall AS pvinstall
ARG OFPREFS
ARG OFBASHRC

#Install ParaView as a system package:
ARG DEBIAN_FRONTEND
ARG TZ
RUN apt-get update -qq\
 && apt-get --no-install-recommends --no-install-suggests --yes install \
    paraview-dev \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#Alternatively, to install ParaView from source:
#(Paraview download address copy/pasted from ThirdParty-<Version>/README.org)
#NotUsed:ARG PVverFull="5.11.2"
#NotUsed:ARG PVverMajor="5.11"
#NotUsed:RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
#NotUsed: && cd $WM_THIRD_PARTY_DIR \
#NotUsed: && export QT_SELECT=qt5 \
#NotUsed: && wget --no-check-certificate http://www.paraview.org/files/v${PVverMajor}/ParaView-v${PVverFull}.tar.gz \
#NotUsed: && tar xvf ParaView-v${PVverFull}.tar.gz \
#NotUsed: && rm ParaView-v${PVverFull}.tar.gz \
#NotUsed: && mv ParaView-v${PVverFull} ParaView-${PVverFull}

#Paraview compilation (according to instructions from the official site)
#NotUsed:RUN echo 'export ParaView_TYPE=ThirdParty' >> ${OFPREFS} \
#NotUsed: && . ${OFBASHRC} ${BASHRC_OPTIONS} \
#NotUsed: && cd $WM_THIRD_PARTY_DIR \
#NotUsed: && ./makeParaView -version ${PVverFull} 2>&1 | tee log.makePVOfficial


#...........
#Step 6.
#OpenFOAM compilation
FROM pvinstall AS ofinstall
ARG OFBASHRC

ARG OFCOMPOPTION="-j"
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 #To avoid confusion with qt4:
 && export QT_SELECT=qt5 \ 
 && ./Allwmake $OFCOMPOPTION 2>&1 | tee log.Allwmake

#Obtaining the summary of the OpenFOAM compilation as suggested in the openfoamwiki instructions
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 #To avoid confusion with qt4:
 && export QT_SELECT=qt5 \
 && ./Allwmake $OFCOMPOPTION 2>&1 | tee log.SummaryAllwmake

#...........
#Step 7.
#Checking if openfoam is working
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && icoFoam -help 2>&1 | tee log.icoFoam

#...........
#Printing the environment variables for the installation so far:
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && printenv > environment_vars_raw.env

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# IV. Final settings
FROM ofinstall AS finalsettings
#FROM preparesource AS finalsettings
ARG OFINSTDIR

#...........
#Allowing normal users to read and execute on the OF installation
RUN find $OFINSTDIR -type d -exec chmod 755 {} + \
 && find $OFINSTDIR -type f -exec bash -c 'for file; do \
      if [ -x "$file" ]; then \
        chmod 755 "$file"; \
      else \
        chmod 644 "$file"; \
      fi; \
    done' _ {} +

#...........
#Trick for making apt-get work again. This is very weird.
#Following the solution proposed here:
#https://sillycodes.com/quick-tip-couldnt-create-temporary-file/
#But modified a little bit in order to  let apt-get install -y to work fine
# for further installations on top of this image
ARG DEBIAN_FRONTEND
ARG TZ
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
