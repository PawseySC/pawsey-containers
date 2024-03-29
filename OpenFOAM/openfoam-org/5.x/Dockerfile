#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition

# Setonix needs at least ubuntu20.04 (From August 2023)
# This recipe follows other recipes for older openfoam, installing older compilers to 
# compile openfoam
FROM quay.io/pawsey/mpich-base:3.4.3_ubuntu20.04

LABEL maintainer="Alexis.Espinosa@pawsey.org.au, mebasha@pawsey.org.au"
#OpenFOAM version to install
ARG OFVERSION="5.x"
#Using bash from now on
SHELL ["/bin/bash", "-c"]


#sed xenial repo to apt source list
RUN echo 'deb http://dk.archive.ubuntu.com/ubuntu/ xenial main' >> /etc/apt/sources.list \
    && echo 'deb http://dk.archive.ubuntu.com/ubuntu/ xenial universe' >> /etc/apt/sources.list \
    && echo 'deb http://archive.ubuntu.com/ubuntu xenial main' >> /etc/apt/sources.list


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
RUN groupadd -g 999 ofuser \
 && useradd -r -m -u 999 -g ofuser ofuser
RUN echo "ofuser:${OFVERSION}" | chpasswd



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# III. INSTALLING OPENFOAM.
#This section is for installing OpenFOAM
#Will follow PARTIALLY the official installation instructions:
#https://openfoam.org/download/5-0-source/
#
#Will follow PARTIALLY the instructions for openfoam-5.x available in the wiki:
#https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-5.x/Ubuntu/16.04
#
#Then, Will follow a combination of both
#(Also checking wiki for OpenFOAM-5.0)
#
#Where recipe deviates from the instructions mentioned above, comments from the maintainer are labelled as: AEG

#...........
#Definition of the installation directory within the container
ARG OFINSTDIR=/opt/OpenFOAM
ARG OFUSERDIR=/home/ofuser/OpenFOAM
WORKDIR $OFINSTDIR

# to install qt4
RUN apt-get update -qq \
   && apt-get -y --no-install-recommends --no-install-suggests install software-properties-common \
        && add-apt-repository ppa:rock-core/qt4


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
 &&  apt-get -y --no-install-recommends install \
   git-core \
   build-essential\
   cmake flex \
   bison zlib1g-dev qt4-dev-tools libqt4-dev \
   libqtwebkit-dev gnuplot \
   libreadline-dev libncurses-dev libxt-dev \
#AEG:No OpenMPI because MPICH will be used (installed in the parent FROM image)
#AEG:NoOpenMPI:   libopenmpi-dev openmpi-bin \
   libboost-system-dev libboost-thread-dev \
#AEG:(No third party CGAL is provided (although can be downloaded) but will use the system installation):
  # libcgal-dev \
#AEG:These libraries are needed for CGAL (system and third party) (if needed, change libgmp-dev for libgmp3-dev):
   libgmp-dev libmpfr-dev\
   python python-dev curl\
   libglu1-mesa-dev libqt4-opengl-dev \
#AEG:I found the following was needed to install  FlexLexer.h
   libfl-dev \
#AEG: Version 5 of gcc is needed:
   gcc-5 g++-5 \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#...........
#Step 2. Download
#Change to the installation dir, download OpenFOAM and untar
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
ARG OFSETTINGS=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config.sh/settings

#...........
#Defining the prefs.sh:
RUN head -23 ${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config.sh/example/prefs.sh > $OFPREFS \
 && echo '#------------------------------------------------------------------------------' >> ${OFPREFS} \
#Using a combination of the variable definition recommended for the use of system mpich in this link:
#   https://bugs.openfoam.org/view.php?id=1167
#And in the file .../OpenFOAM-<VERSION>/wmake/rules/General/mplibMPICH
#(These MPI_* environmental variables are set in the prefs.sh as suggested in the link above,
# and this file is sourced automatically by the bashrc when the bashrc is sourced)
#
#--As suggested in the link above, WM_MPLIB and MPI_ROOT need to be set:
 && echo 'export WM_MPLIB=SYSTEMMPI' >> ${OFPREFS} \
 && echo 'export MPI_ROOT="/usr"' >> ${OFPREFS} \
#
#--As suggested in the link above, MPI_ARCH_FLAGS,MPI_ARCH_INC,MPI_ARCH_LIBS need to be set
#--Leaving active only the options that worked from different suggestions (A,B,C)
#  ~(A)The suggestions from the link above:
## && echo 'export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX"' >> ${OFPREFS} \
## && echo 'export MPI_ARCH_INC="-I/usr/include/mpich"' >> ${OFPREFS} \
## && echo 'export MPI_ARCH_LIBS="-L/usr/lib/x86_64-linux-gnu -lmpich"' >> ${OFPREFS} \
#
#  ~(B)The suggestions from the file mplibMPICH are:
 && echo 'export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX"' >> ${OFPREFS} \
 && echo 'export MPI_ARCH_INC="-isystem $MPI_ROOT/include"' >> ${OFPREFS} \
 && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OFPREFS} \
#
#  ~(C)Even further modifications were needed for some other OpenFOAM versions:
##AEG:Gcc7 has problems with the -isystem flag. Using -I instead:
## && echo 'export MPI_ARCH_INC="-I ${MPI_ROOT}/include"' >> ${OFPREFS} \
##AEG:Only one library path and using -lmpich
## && echo 'export MPI_ARCH_LIBS="-L$MPI_ROOT/lib -lmpich"' >> ${OFPREFS} \
#--Dummy line:
 && echo ''

#...........
#Modifying the settings.sh file to use gcc-5 and g++-5
#This as an adaptation from instructions in: 
# https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-2.4.0/Ubuntu#Ubuntu_18.04
RUN cp ${OFSETTINGS} ${OFSETTINGS}.original \
#Changing to use gcc-5
 && sed -i "s/export WM_CC='gcc'/export WM_CC='gcc-5'/g" ${OFSETTINGS} \
#Changing to use g++-5
 && sed -i "s/export WM_CXX='g++'/export WM_CXX='g++-5'/g" ${OFSETTINGS} \
#--Dummy line:
 && echo ''

#...........
#Modifying the bashrc file
RUN cp ${OFBASHRC} ${OFBASHRC}.original \
#Changing the installation directory within the bashrc file (This is not in the openfoamwiki instructions)
 && sed -i '/^export FOAM_INST_DIR=$HOME.*/aexport FOAM_INST_DIR='"${OFINSTDIR}" ${OFBASHRC} \
 && sed -i '0,/^export FOAM_INST_DIR=$HOME/s//# export FOAM_INST_DIR=$HOME/' ${OFBASHRC} \
#" (This comment line is needed to let vi to show the right syntax)
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
ARG BASHRC_OPTIONS="FOAMY_HEX_MESH=yes"

#...........
#Modifying the "aliases" file to avoid the "declare" error with singularity at Pawsey
#Idea for modification comes from the same file in openfoam-6
ARG OFALIASFILE=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config.sh/aliases
RUN cp ${OFALIASFILE} ${OFALIASFILE}.original \
 && sed -i 's,declare -f wmRefresh > /dev/null, command -V wmRefresh 2> /dev/null | head -1 | grep -q "function",' ${OFALIASFILE} \
#--Dummy line:
 && echo ''

#...........
#Modifying the wmake files for using gcc-5 and g++-5
RUN cd ${OFINSTDIR}/OpenFOAM-${OFVERSION}/wmake/rules \
 && for iDir in $(ls -d linux*Gcc); do       \
        cp $iDir/c $iDir/c.original;         \
        cp $iDir/c++ $iDir/c++.original;     \
        sed -i 's/gcc/\$(WM_CC)/' $iDir/c;   \
        sed -i 's/g++/\$(WM_CXX)/' $iDir/c++;\
    done

#...........
#Step 4.
##Paraview compilation (Using instructions from the wiki)
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt4 \
#downloading ParaView with wget because the supposedly automatic download with curl is failing
#(Paraview download address pasted from ThirdParty-<Version>/README.org)
 && wget --no-check-certificate http://www.paraview.org/files/v5.4/ParaView-v5.4.0.tar.gz \
 && tar xvf ParaView-v5.4.0.tar.gz \
 && rm ParaView-v5.4.0.tar.gz \
 && mv ParaView-v5.4.0 ParaView-5.4.0 \
 && sed -i 's/DOCUMENTATION_DIR/#DOCUMENTATION_DIR/' ParaView-5.4.0/Plugins/StreamLinesRepresentation/CMakeLists.txt \
 && ./makeParaView -python -mpi -python-lib /usr/lib/x86_64-linux-gnu/libpython2.7.so.1.0 2>&1 | tee log.makePV

#...........
#Step 5.
#Install Third Party tools (preferred to do it as a separate step and not together with the full openfoam compilation)
##Third party compilation
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt4 \
 && ./Allwmake 2>&1 | tee log.Allwmake


# to install cgal 4.11 which is compatible with OF5X
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_THIRD_PARTY_DIR \
 && wget https://github.com/CGAL/cgal/archive/refs/tags/releases/CGAL-4.11.tar.gz \
 && tar -xvf CGAL-4.11.tar.gz \
 && rm CGAL-4.11.tar.gz \
 && cd cgal-releases-CGAL-4.11 \
 && mkdir build && cd build \
 && cmake .. \
 && make install 2>&1 | tee log.cgal




#...........
#Step 6.
##OpenFOAM compilation
ARG OFNUMPROCOPTION="-j 4"
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt4 \
 && ./Allwmake $OFNUMPROCOPTION 2>&1 | tee log.Allwmake

#Obtaining the summary of the OpenFOAM compilation as suggested in the openfoamwiki instructions
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt4 \
 && ./Allwmake $OFNUMPROCOPTION 2>&1 | tee log.SummaryAllwmake

#...........
#Step 7.
#Defining defaults of the controlDict
#AEG: Not using collated default for version 5.x anymore as it was not mature yet
#    (Therefore, commenting settings with ##@##)
#
##@##ARG OFCONTROL=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/controlDict
##@###(No other defaults to be defined yet)
##@##RUN cp ${OFCONTROL} ${OFCONTROL}.original \
##@###Setting collated as default for fileHandler
##@## && sed -i '\@fileHandler uncollated;@a    fileHandler collated;' ${OFCONTROL} \
##@## && sed -i '0,\@fileHandler uncollated;@s@@// fileHandler uncollated;@' ${OFCONTROL} \
##@###--Dummy line:
##@## && echo ''

#...........
#Step 8.
##Checking if openfoam is working
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && icoFoam -help 2>&1 | tee log.icoFoam

#...........
#Writing the environment variables for the installation so far:
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
