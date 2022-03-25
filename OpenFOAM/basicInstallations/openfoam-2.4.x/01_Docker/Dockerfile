#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition
# Defining the base image to build from
# In this case: mpich 3.1.4 and ubuntu 16.04; MPICH is needed for crays
FROM quay.io/pawsey/mpich-base:3.4.3_ubuntu16.04

LABEL maintainer="Alexis.Espinosa@pawsey.org.au"
#OpenFOAM version to install
ARG OFVERSION="2.4.x"
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
RUN groupadd -g 999 ofuser \
 && useradd -r -m -u 999 -g ofuser ofuser
RUN echo "ofuser:${OFVERSION}" | chpasswd



#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# III. INSTALLING OPENFOAM.
#This section is for installing OpenFOAM
#Will follow PARTIALLY the official installation instructions:
#https://openfoam.org/download/2-4-0-source/
#
#Will follow PARTIALLY the instructions for OpenFOAM-2.4.x  available in the wiki:
#https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-2.4.x/Ubuntu#Ubuntu_16.04
#
#Then, Will follow a combination of both
#(Also checking wiki for OpenFOAM-2.4.0)
#
#Where recipe deviates from the instructions mentioned above, comments from the maintainer are labelled as: AEG

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
   flex bison git-core cmake zlib1g-dev \
   libboost-system-dev libboost-thread-dev \
#AEG:No OpenMPI because MPICH will be used (installed in the parent FROM image)
#AEG:NoOpenMPI:   libopenmpi-dev openmpi-bin \
#AEG:(using libncurses-dev, as in official instructions, and not libncurses5-dev, as in wiki)
   gnuplot libreadline-dev libncurses-dev libxt-dev \
   qt4-dev-tools libqt4-dev libqt4-opengl-dev \ 
   freeglut3-dev libqtwebkit-dev \
#AEG:No scotch because it installs openmpi which later messes up with MPICH
#    Therefore, ThirdParty scotch is the one to be installed and used by openfoam.
#AEG:NoScotch:   libscotch-dev \
   libcgal-dev \
#AEG:These libraries are needed for CGAL (system and third party) (if needed, change libgmp-dev for libgmp3-dev):
   libgmp-dev libmpfr-dev\
#AEG: Some more suggestions from the wiki instructions:
   python python-dev \
   libglu1-mesa-dev \
#AEG:I found the following was needed to install  FlexLexer.h
   libfl-dev \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#...........
#Step 2. Download
#Change to the installation dir, clone OpenFOAM directories
ARG OFVERSIONGIT=$OFVERSION
WORKDIR $OFINSTDIR
#Try git or https protocol:
##RUN git clone https://github.com/OpenFOAM/OpenFOAM-${OFVERSIONGIT}.git \
## && git clone https://github.com/OpenFOAM/ThirdParty-${OFVERSIONGIT}.git

RUN git clone git://github.com/OpenFOAM/OpenFOAM-${OFVERSIONGIT}.git \
 && git clone git://github.com/OpenFOAM/ThirdParty-${OFVERSIONGIT}.git

#...........
#Step 3. Definitions for the prefs and bashrc files.
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
#   1. You can mount a directory of your local-host into this directory 
#   2. Or you can include and build stuff inside the image and save it as your own image for later use.
 && sed -i '/^export WM_PROJECT_USER_DIR=.*/aexport WM_PROJECT_USER_DIR="'"${OFUSERDIR}/ofuser"'-$WM_PROJECT_VERSION"' ${OFBASHRC} \
 && sed -i '0,/^export WM_PROJECT_USER_DIR/s//# export WM_PROJECT_USER_DIR/' ${OFBASHRC} \
#" (This comment line is needed to let vi to show the right syntax)
#--Dummy line:
 && echo ''

#...........
#Step 4.
#Install one or the other: paraview or VTK
#Install paraview or VTK for runTimePostprocessing of OpenFOAM to properly compile
#Install paraview for graphical postprocessing to be available in the container 

#AEG: Have not tried the VTK only installation yet

##Download paraview (taken from wiki instructions)
RUN . ${OFBASHRC} \
 && cd $WM_THIRD_PARTY_DIR \
 && mkdir download \
 && wget --no-check-certificate -P download http://www.paraview.org/files/v4.1/ParaView-v4.1.0-source.tar.gz \
 && tar -xzf download/ParaView-v4.1.0-source.tar.gz \
 && mv ParaView-v4.1.0 ParaView-4.1.0 \
 && rm -rf download

##Paraview compilation (Official instructions for 2.4)
#AEG: (This procedure is not working yet, needs some fix that I have not found) 
#AEG:(Also take a look into the ThirdParty-xx/README.* files)
##--##:RUN . ${OFBASHRC} \
##--##: && cd $WM_THIRD_PARTY_DIR \
##--##: && ./makeParaView4 | tee log.makePV

##Paraview compilation (Adapted alternative instructions from OpenFoamWiki)
RUN . ${OFBASHRC} \
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt4 \
 && sed -i -e 's=//#define GLX_GLXEXT_LEGACY=#define GLX_GLXEXT_LEGACY=' ParaView-4.1.0/VTK/Rendering/OpenGL/vtkXOpenGLRenderWindow.cxx \
 && cd ParaView-4.1.0 \
 && wget --no-check-certificate http://www.paraview.org/pipermail/paraview/attachments/20140210/464496cc/attachment.bin -O Fix.patch \
 && patch -p1 < Fix.patch \
 && cd VTK \
 && wget --no-check-certificate https://github.com/gladk/VTK/commit/ef22d3d69421581b33bc0cd94b647da73b61ba96.patch -O Fix2.patch \
 && patch -p1 < Fix2.patch \
 && cd $WM_THIRD_PARTY_DIR \
 && ./makeParaView4 -python -mpi -python-lib /usr/lib/x86_64-linux-gnu/libpython2.7.so.1.0 2>&1 | tee log.makePV

#...........
#Step 5.
#Install Third Party tools (preferred to do it as a separate step and not together with the full openfoam compilation) 

#Download scotch because we are not installing from apt-get(see above)
# (Instructions taken from wiki for Ubuntu 12.04)
RUN . ${OFBASHRC} \
 && cd $WM_THIRD_PARTY_DIR \
 && mkdir download \
 && wget --no-check-certificate -P download \
    https://gforge.inria.fr/frs/download.php/file/34099/scotch_6.0.3.tar.gz \
 && tar -xzf download/scotch_6.0.3.tar.gz \
 && rm -rf download

#Updating the CGAL setting to the system one (installed at the beginning):
#boost is already signaling to the system one (installed at the beginning too):
ARG OFCGAL=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config/CGAL.sh
RUN . ${OFBASHRC} \
 && cp ${OFCGAL} ${OFCGAL}.original \
 && sed -i '/^cgal_version=.*/acgal_version=cgal-system' ${OFCGAL} \
 && sed -i '0,/^cgal_version/s//# cgal_version/' ${OFCGAL} \
#AEG: commenting the definition of variables to avoid further settings as will use system installed tools
 && sed -i 's,export BOOST_ARCH_PATH,# export BOOST_ARCH_PATH,' ${OFCGAL} \
 && sed -i 's,export CGAL_ARCH_PATH,# export CGAL_ARCH_PATH,' ${OFCGAL} \
#" (This comment line is needed to let vi to show the right syntax)
#--Dummy line:
 && echo ''

#Third party compilation
RUN . ${OFBASHRC} \
 && cd $WM_THIRD_PARTY_DIR \
 && ./Allwmake 2>&1 | tee log.Allwmake

#...........
#Step 6.

#Fix for the flex version to be checked (idea obtained from the wiki instructions for 2.4.0 ubunut 16.04)
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
#Defining defaults of the controlDict

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
## Starting as ofuser by default
USER ofuser
WORKDIR /home/ofuser
