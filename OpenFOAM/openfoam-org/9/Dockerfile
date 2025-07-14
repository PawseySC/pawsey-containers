#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition
# Defining the base container to build from
# IMPORTANT: 
# Setonix needs at least ubuntu24.04 (From August 2025)
FROM quay.io/pawsey/mpich-base:3.4.3_ubuntu24.04

LABEL maintainer="Alexis.Espinosa@pawsey.org.au"
#OpenFOAM version to install
ARG OFVERSION="9"
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
RUN groupadd -g 10001 ofuser \
 && useradd -r -m -u 10001 -g ofuser ofuser
RUN echo "ofuser:${OFVERSION}" | chpasswd



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# III. INSTALLING OPENFOAM.
#This section is for installing OpenFOAM
#Will follow PARTIALLY the official installation instructions:
#https://openfoam.org/download/source/
#
#Will follow PARTIALLY the instructions latest instructions available in the wiki:
#https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-7/Ubuntu/20.04
#https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-8
#
#Then, Will follow a combination of both

#...........
#Definition of the installation directory within the container
ARG OFINSTDIR=/opt/OpenFOAM
ARG OFUSERDIR=/home/ofuser/OpenFOAM
WORKDIR $OFINSTDIR

#...........
#Step 1.
#Install necessary packages
#
# tzdata is a needed dependecy of a dependency below.
#        using DEBIAN_FRONTEND and TZ definitions to avoid interactive questions
ARG DEBIAN_FRONTEND=noninteractive
ARG TZ=Australia/Perth
#A warning may appear:
#debconf: delaying package configuration, since apt-utils is not installed
#But seems to be a bug:
#https://github.com/phusion/baseimage-docker/issues/319
#But harmless.
RUN apt-get update -qq\
 && apt-get --no-install-recommends --no-install-suggests --yes install \
#(1) As indicated in official documentation
    build-essential cmake git ca-certificates \
    flex libfl-dev bison zlib1g-dev libboost-system-dev libboost-thread-dev \
#AEG:No openMPI as MPICH is to be used:    libopenmpi-dev openmpi-bin \
    gnuplot libreadline-dev libncurses-dev \
#AEG: CMEYER suggestion:replace qt5-default by the expanded set of qt5 libraries for ubuntu24.04
    #qt5-default \
    qtbase5-dev qttools5-dev qttools5-dev-tools qtchooser qt5-qmake qtbase5-dev-tools libqt5opengl5-dev libqt5x11extras5-dev libxt-dev \
    curl \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#...........
#Step 2. Download
#Change to the installation dir, clone OpenFOAM directories
ARG OFVERSIONGIT=$OFVERSION
WORKDIR $OFINSTDIR
#Try git or https protocol:
RUN git clone https://github.com/OpenFOAM/OpenFOAM-${OFVERSIONGIT}.git \
 && git clone https://github.com/OpenFOAM/ThirdParty-${OFVERSIONGIT}.git

##RUN git clone git://github.com/OpenFOAM/OpenFOAM-${OFVERSIONGIT}.git \
## && git clone git://github.com/OpenFOAM/ThirdParty-${OFVERSIONGIT}.git

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
## && echo 'export MPI_ARCH_INC="-isystem $MPI_ROOT/include"' >> ${OFPREFS} \
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
 && sed -i '0,/^# export FOAM_INST_DIR=.*/!b;//a\export FOAM_INST_DIR='"${OFINSTDIR}" ${OFBASHRC} \
#" (This comment line is needed to let vi to show the right syntax when editing this Dockerfile)
#Changing the place for your own tools/solvers (WM_PROJECT_USER_DIR directory) within the bashrc file 
#IMPORTANT:When using this container, you have two options when building your own tools/solvers:
#   1. You can mount a directory of your local-host into this directory
#   2. Or you can include and build stuff inside the image and save it as your own image for later use.
 && sed -i '/^export WM_PROJECT_USER_DIR=.*/aexport WM_PROJECT_USER_DIR="'"${OFUSERDIR}/ofuser"'-$WM_PROJECT_VERSION"' ${OFBASHRC} \
 && sed -i '0,/^export WM_PROJECT_USER_DIR/s//# export WM_PROJECT_USER_DIR/' ${OFBASHRC} \
#" (This comment line is needed to let vi to show the right syntax)
#--Dummy line:
 && echo ''

#...........
#Bashrc options to be used
ARG BASHRC_OPTIONS=""

#...........
#Step 4.
#Install Third Party tools (preferred to do it as a separate step and not together with the full openfoam compilation) 
#AEG:NoThirdPartyCGAL&Boost. There is no indication for how to install CGAL or Boost here.
#                            So, if needed, will first be tried to install with apt-get at the top of this recipe.
#                            It seems that "foamyHexMesh" has been deprecated, so CGAL seems not to be needed.
#Third party compilation
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

# CMEYER: Paraview is failing to build in ubuntu24.04 with default Python and Compiler. So Paraview (or paraFoam) will not work inside this container. 
# If there is still interest to compile it, the recommendation is to try installing an old verion of Python and gcc and attempt compilation again or else
# upgrade to ParaView/6.0.0, which compiles fine with default python and compilers in container, but may have runtime issues with older openfoam 
# due to how comparatively new it is
#Downloading first ParaView with wget because automatic download with curl is failing
#(Paraview download address copy/pasted from ThirdParty-<Version>/README.org)
# ARG PVverFull="5.6.3"
# ARG PVverMajor="5.6"
# RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
#  && cd $WM_THIRD_PARTY_DIR \
#  && export QT_SELECT=qt5 \
#  && wget --no-check-certificate http://www.paraview.org/files/v${PVverMajor}/ParaView-v${PVverFull}.tar.gz \
#  && tar xvf ParaView-v${PVverFull}.tar.gz \
#  && rm ParaView-v${PVverFull}.tar.gz \
#  && mv ParaView-v${PVverFull} ParaView-${PVverFull}

# #Paraview compilation (according to instructions from the official site)
# RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
#  && cd $WM_THIRD_PARTY_DIR \
#  && ./makeParaView 2>&1 | tee log.makePVOfficial

#NotFor8:#Paraview compilation (Using instructions from the wiki)
#NotFor8:RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
#NotFor8: && cd $WM_THIRD_PARTY_DIR \
#NotFor8: && export QT_SELECT=qt5 \
#NotFor8: && ./makeParaView -python -mpi -python-lib /usr/lib/x86_64-linux-gnu/libpython2.7.so.1.0 2>&1 | tee log.makePVWiki

#...........
#Step 6.
#OpenFOAM compilation
ARG OFNUMPROCOPTION="-j"
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && ./Allwmake $OFNUMPROCOPTION 2>&1 | tee log.Allwmake

#Obtaining the summary of the OpenFOAM compilation as suggested in the openfoamwiki instructions
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && ./Allwmake $OFNUMPROCOPTION 2>&1 | tee log.SummaryAllwmake

#...........
#Step 7.
#Defining Best Practices as defaults of the controlDict
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