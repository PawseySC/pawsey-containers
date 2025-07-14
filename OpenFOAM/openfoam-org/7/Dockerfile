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
ARG OFVERSION="7"
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
#https://openfoam.org/download/7-source/
#
#Will follow PARTIALLY the instructions for openfoam-7 available in the wiki:
#https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-7/Ubuntu/18.04
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
#A warning may appear:
#debconf: delaying package configuration, since apt-utils is not installed
#But seems to be a bug:
#https://github.com/phusion/baseimage-docker/issues/319
#But harmless.
RUN apt-get update -qq\
 &&  apt-get -y --no-install-recommends --no-install-suggests install \
   build-essential\
   flex bison git-core cmake zlib1g-dev \
#AEG:(No third party boost is provided (although can be downloaded) but will use the system installation):
   libboost-system-dev libboost-thread-dev \
#AEG:No OpenMPI because MPICH will be used (installed in the parent FROM image)
#AEG:NoOpenMPI:   libopenmpi-dev openmpi-bin \
   gnuplot libreadline-dev libncurses-dev \
#AEG:NoQt4: libqtwebkit-dev \ 
#AEG: CMEYER suggestion:replace qt5-default by the expanded set of qt5 libraries for ubuntu24.04
    #qt5-default \
    qtbase5-dev qttools5-dev qttools5-dev-tools qtchooser qt5-qmake qtbase5-dev-tools libqt5opengl5-dev libqt5x11extras5-dev libxt-dev \
    curl \
#--continue
   freeglut3-dev \
#AEG:No scotch because it installs openmpi which later messes up with MPICH
#    Therefore, ThirdParty scotch is the one to be installed and used by openfoam.
#AEG:NoScotch:   libscotch-dev \
#AEG:(No third party CGAL is provided (although can be downloaded) but will use the system installation):
#CMEYER: ubuntu/24.04 libcgal-dev incompatible with openfoam 7, build cgal from source instead
   #libcgal-dev \
#AEG:These libraries are needed for CGAL (system and third party) (if needed, change libgmp-dev for libgmp3-dev):
   libgmp-dev libmpfr-dev\
#AEG:Wiki additional qt suggestions:
   qtbase5-dev \
#AEG: Some more suggestions from the wiki instructions:
   python3 python3-dev \
   libglu1-mesa-dev \
#AEG:I found the following was needed to install  FlexLexer.hi (now included in the wiki instructions too):
   libfl-dev \
#AEG:I need wget to download ParaView (because automatic download with curl is failing)
   wget \
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
## && echo 'export MPI_ARCH_INC="-isystem $MPI_ROOT/include"' >> ${OFPREFS} \
## && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpi -lrt"' >> ${OFPREFS} \
#
#  ~(C)Even further modifications were needed for some other OpenFOAM versions:
##AEG:Gcc7 has problems with the -isystem flag. Using -I instead:
 && echo 'export MPI_ARCH_INC="-I ${MPI_ROOT}/include"' >> ${OFPREFS} \
##AEG:Only one library path and using -lmpich
## && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OFPREFS} \
##AEG:The two library paths and using -lmpich
 && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OFPREFS} \
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
ARG BASHRC_OPTIONS="FOAMY_HEX_MESH=yes"

#...........
#Step 4.
#Install one or the other: paraview or VTK
#Install paraview or VTK for runTimePostprocessing of OpenFOAM to properly compile
#Install paraview for graphical postprocessing to be available in the container
#Catalyst tools are not available for the foundation version

#AEG: foundation source files do not count with makeVTK script, so will not attempt to install VTK

# CMEYER: Paraview is failing to build in ubuntu24.04 with default Python and Compiler. So Paraview (or paraFoam) will not work inside this container. 
# If there is still interest to compile it, the recommendation is to try installing an old verion of Python and gcc and attempt compilation again or else
# upgrade to ParaView/6.0.0, which compiles fine with default python and compilers in container, but may have runtime issues with older openfoam 
# due to how comparatively new it is
##Paraview compilation (Using instructions from the wiki)
# RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
#  && cd $WM_THIRD_PARTY_DIR \
#  && export QT_SELECT=qt5 \
# #downloading ParaView with wget because the supposedly automatic download with curl is failing
# #(Paraview download address pasted from ThirdParty-<Version>/README.org)
#  && wget --no-check-certificate http://www.paraview.org/files/v5.6/ParaView-v5.6.0.tar.gz \
#  && tar xvf ParaView-v5.6.0.tar.gz \
#  && rm ParaView-v5.6.0.tar.gz \
#  && mv ParaView-v5.6.0 ParaView-5.6.0 \
#  && ./makeParaView -python -mpi -python-include /usr/local/include/python2.7 -python-lib /usr/local/lib/libpython2.7.so.1.0 2>&1 | tee log.makePV

#...........
#Step 5.
#Install Third Party tools (preferred to do it as a separate step and not together with the full openfoam compilation) 
#AEG:NoThirdPartyCGAL&Boost, will use ubuntu packages installed above with apt-get:
#@@-@@#:#CGAL and boost first need to be downloaded from the sites given in ThirdParty/README.org
#@@-@@#:#Updating the BOOST version to be used:
#@@-@@#:ARG OFCGAL=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/config.sh/CGAL
#@@-@@#:RUN cp ${OFCGAL} ${OFCGAL}.original \
#@@-@@#: && sed -i '/^boost_version=.*/aboost_version=boost_1_64_0' ${OFCGAL} \
#@@-@@#: && sed -i '0,/^boost_version/s//# boost_version/' ${OFCGAL} \
#@@-@@#:#" (This comment line is needed to let vi to show the right syntax)
#@@-@@#:#--Dummy line:
#@@-@@#: && echo ''

#CMEYER: Patch files for fix to sha1 overload problem
#CMEYER: see https://develop.openfoam.com/Development/openfoam/-/issues/2496
#CMEYER: see https://develop.openfoam.com/Development/openfoam/-/commit/eb3f7dfe7443fe852b256072f337ac24effff0ac
RUN . ${OFBASHRC} \
 && cd ${WM_PROJECT_DIR}
WORKDIR /opt/OpenFOAM/OpenFOAM-7
COPY sha1-fix.patch /tmp/sha1-fix.patch
RUN patch -p1 < /tmp/sha1-fix.patch

# CMEYER: Install cgal from source, given library packaged with ubuntu/24.04 incompatible with openfoam 7
RUN apt-get update -qq\
 && apt-get -y --no-install-recommends install \
   build-essential cmake libboost-all-dev libgmp-dev libmpfr-dev
RUN mkdir -p /tmp/cgal-build \
 && cd /tmp/cgal-build \
 && wget https://github.com/CGAL/cgal/releases/download/releases/CGAL-4.10/CGAL-4.10.tar.xz \
 && tar -xf CGAL-4.10.tar.xz \
 && cd CGAL-4.10 \
 && mkdir build \
 && cd build \
 && cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local/cgal-4.10 \
 && make -j 4 \
 && make install \
 && cd /tmp \
 && rm -rf CGAL-4.10 CGAL-4.10.tar.xz

ENV CGAL_INC_DIR=/usr/local/cgal-4.10/include \
   CGAL_LIB_DIR=/usr/local/cgal-4.10/lib \
   LD_LIBRARY_PATH=$CGAL_LIB_DIR:$LD_LIBRARY_PATH \
   CPATH=$CGAL_INC_DIR:$CPATH \
   LIBRARY_PATH=$CGAL_LIB_DIR:$LIBRARY_PATH

#Third party compilation
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_THIRD_PARTY_DIR \
 && ./Allwmake 2>&1 | tee log.Allwmake

#...........
#Step 6.
#OpenFOAM compilation
ARG OFNUMPROCOPTION="-j 4"
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 # CMEYER: Patch etc/config/CGAL.sh to use custom-installed cgal
 && sed -i 's/^cgal_version=cgal-system$/cgal_version=CGAL-4.10/' ./etc/config.sh/CGAL \
 && echo -e "\nif [ \"\$cgal_version\" != \"cgal-system\" ]\nthen\n    export CGAL_ARCH_PATH=/usr/local/cgal-4.10\nfi" >> ./etc/config.sh/CGAL \
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
