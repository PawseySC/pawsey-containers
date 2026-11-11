#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
#The creation of this image that contains VTK, LIGGGHTS && CFDEM starts
#from the already existing and working image of openfoam-org:5.x
FROM quay.io/pawsey/openfoam-org:5.x
LABEL maintainer="Alexis.Espinosa@pawsey.org.au"
#OpenFOAM version to install
ARG OFVERSION="5.x"
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
ARG OFBASHRC=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/bashrc
ARG OFWMPROJECTVERSION=${OFVERSION}
ARG BASHRC_OPTIONS="FOAMY_HEX_MESH=yes"
ARG ParaView_VERSION=5.4.0
ARG ParaView_ShortVERSION=5.4

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# I. Settings for VTK

#............
# Defining version numbers
#This version number is not needed for the installation of VTK but will be needed for CFDEM & LIGGGHTS settings
#(Version obtained from the file $VTKSOURCEDIR/CMake/vtkVersion.cmake):
ARG VTKVERSION=8.1

# =====================
#(When using the VTK already compiled with the already compiled ParaView)
#...........
# Directories settings 
ARG VTKBASEDIR=${OFTHIRDPARTYDIR}/platforms/linux64Gcc
ARG VTKSOURCEDIR=${OFTHIRDPARTYDIR}/ParaView-${ParaView_VERSION}/VTK
ARG VTKINSTDIR=$VTKBASEDIR/VTK-install
#This appendix naming is not needed for the installation of VTK but will be needed for CFDEM & LIGGGHTS settings
#(Appendix obtained from the name of libraries in ${WM_THIRD_PARTY_DIR}/platforms/linux64Gcc/ParaView-${ParaView_VERSION}/lib/paraview-${ParaView_ShortVERSION}):
ARG VTKAPPENDIX=pv${ParaView_ShortVERSION}

#...........
# Instead of Installation, just generating soft links to allow CFDEM adn LIGGGHTS to flow correctly
WORKDIR $VTKINSTDIR
RUN ln -s ${VTKBASEDIR}/ParaView-${ParaView_VERSION}/bin ./bin \
 && mkdir -p include \
 && ln -s ${VTKBASEDIR}/ParaView-${ParaView_VERSION}/include/paraview-${ParaView_ShortVERSION} ./include/vtk-${VTKVERSION} \
 && ln -s ${VTKBASEDIR}/ParaView-${ParaView_VERSION}/lib/paraview-${ParaView_ShortVERSION} ./lib \
 && mkdir -p share/doc \
 && ln -s ${VTKBASEDIR}/ParaView-${ParaView_VERSION}/share/doc/paraview-${ParaView_ShortVERSION} ./share/doc/vtk-${VTKVERSION} \
 && ln -s ${VTKBASEDIR}/ParaView-${ParaView_VERSION}/share/cmake ./share/cmake
# =====================


# =====================
#(When using the VTK provided by ParaView for a separate installation)
#AEG: Not installing because the already compiled paraview build will be used)
##-##:#...........
##-##:# Directories settings 
##-##:ARG VTKBASEDIR=/opt/VTK
##-##:#ARG VTKSOURCEDIR=$VTKBASEDIR
##-##:ARG VTKSOURCEDIR=${OFTHIRDPARTYDIR}/ParaView-${ParaView_VERSION}/VTK
##-##:ARG VTKBUILDDIR=$VTKBASEDIR/VTK-build
##-##:ARG VTKINSTDIR=$VTKBASEDIR/VTK-install
##-##:#This appendix naming is not needed for the installation of VTK but will be needed for CFDEM & LIGGGHTS settings
##-##:#(When installing VTK from scratch it is the same as the VTKVERSION):
##-##:ARG VTKAPPENDIX=${VTKVERSION}
##-##:
##-##:#...........
##-##:# Installation
##-##:ARG VTKMAKEOPTIONS="-j4"
##-##:WORKDIR $VTKBUILDDIR
##-##:RUN cmake ${VTKSOURCEDIR} -DVTK_Group_MPI=on -DBUILD_SHARED_LIBS=on -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${VTKINSTDIR} \
##-##: && make ${VTKMAKEOPTIONS} \
##-##: && make install
# =====================

#...........
#Adding the VTK libraries to the library path
ENV LD_LIBRARY_PATH=${VTKINSTDIR}/lib:$LD_LIBRARY_PATH

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
#Installation of CFDEM & LIGGGHTS
#...........
#Installing prerequisites
RUN apt-get update -qq\
 &&  apt-get -y --no-install-recommends install \
#   build-essential flex bison cmake zlib1g-dev libboost-system-dev \
#   libboost-thread-dev \
#AEG:No openmpi:   libopenmpi-dev openmpi-bin \
#   gnuplot \
#   libreadline-dev libncurses-dev libxt-dev \
#   libscotch-dev libptscotch-dev \ 
#AEG:No VTK:   libvtk6.2 libvtk6-dev \
   python-numpy \
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*


#...........
#Downloading the tools
ARG CFDEMINSTDIR=/opt/CFDEM
ARG CFDEMUSERDIR=/home/ofuser/CFDEM
WORKDIR $CFDEMINSTDIR
RUN git clone https://github.com/CFDEMproject/CFDEMcoupling-PUBLIC.git \ 
 && mv CFDEMcoupling-PUBLIC CFDEMcoupling-PUBLIC-$OFWMPROJECTVERSION 

WORKDIR /opt/LIGGGHTS
ARG LIGGGHTSINSTDIR=/opt/LIGGGHTS
WORKDIR $LIGGGHTSINSTDIR
RUN git clone https://github.com/CFDEMproject/LIGGGHTS-PUBLIC.git \ 
 && git clone https://github.com/CFDEMproject/LPP.git lpp


#...........
#Standard Settings of environment variables
ENV CFDEM_VERSION=PUBLIC
ENV CFDEM_PROJECT_DIR=$CFDEMINSTDIR/CFDEMcoupling-$CFDEM_VERSION-$OFWMPROJECTVERSION
ENV CFDEM_PROJECT_USER_DIR=$CFDEMUSERDIR/ofuser-$CFDEM_VERSION-$OFWMPROJECTVERSION
ENV CFDEM_bashrc=$CFDEM_PROJECT_DIR/src/lagrangian/cfdemParticle/etc/bashrc
ENV CFDEM_LIGGGHTS_SRC_DIR=$LIGGGHTSINSTDIR/LIGGGHTS-PUBLIC/src
ENV CFDEM_LIGGGHTS_MAKEFILE_NAME=auto
ENV CFDEM_LPP_DIR=$LIGGGHTSINSTDIR/lpp/src
#...........
#Extended Settings of environment variables
ENV CFDEM_SRC_DIR=$CFDEM_PROJECT_DIR/src
ENV CFDEM_SOLVER_DIR=$CFDEM_PROJECT_DIR/applications/solvers
ENV CFDEM_DOC_DIR=$CFDEM_PROJECT_DIR/doc
ENV CFDEM_UT_DIR=$CFDEM_PROJECT_DIR/applications/utilities
ENV CFDEM_TUT_DIR=$CFDEM_PROJECT_DIR/tutorials
ENV CFDEM_LIGGGHTS_MAKEFILE_POSTIFX=
ENV CFDEM_VERBOSE=false
#...........
#Defining additional libraries for CFDEM
#(Basically telling CFDEM where is VTK)
ENV CFDEM_ADD_LIB_PATHS="-Wl,-rpath,${VTKINSTDIR}/lib -L${VTKINSTDIR}/lib"
ENV CFDEM_ADD_LIBS="-lvtkCommonCore-${VTKAPPENDIX} -lvtkIOCore-${VTKAPPENDIX} -lvtkIOXML-${VTKAPPENDIX} -lvtkIOLegacy-${VTKAPPENDIX} -lvtkIOImage-${VTKAPPENDIX} -lvtkCommonDataModel-${VTKAPPENDIX} -lvtkIOParallelXML-${VTKAPPENDIX} -lvtkParallelCore-${VTKAPPENDIX} -lvtkParallelMPI-${VTKAPPENDIX} -lvtkCommonExecutionModel-${VTKAPPENDIX} -lvtkFiltersCore-${VTKAPPENDIX} -lvtksys-${VTKAPPENDIX} -lvtkCommonMisc-${VTKAPPENDIX} -lvtkCommonTransforms-${VTKAPPENDIX} -lvtkCommonMath-${VTKAPPENDIX} -lvtkIOXMLParser-${VTKAPPENDIX} -lvtkCommonSystem-${VTKAPPENDIX} -lvtkDICOMParser-${VTKAPPENDIX} -lvtkmetaio-${VTKAPPENDIX}"


#...........
#Create the cfdem user directory
USER ofuser
RUN mkdir -p ${CFDEM_PROJECT_USER_DIR} \
 && chmod -R 777 ${CFDEMUSERDIR}
USER root

#...........
#Modifying the LIGGGHTS makefile
WORKDIR $LIGGGHTSINSTDIR/LIGGGHTS-PUBLIC/src
RUN make auto; exit 0
RUN sed -i '/^#VTK_INC_USR=.*/aVTK_INC_USR=-I'"${VTKINSTDIR}"'\/include\/vtk-'"${VTKVERSION}" ./MAKE/Makefile.user \
 && sed -i '/^#VTK_LIB_USR=.*/aVTK_LIB_USR=-L'"${VTKINSTDIR}"'\/lib' ./MAKE/Makefile.user \
#AEG:Activate the following line if using the VTK already compiled with the already compiled ParaView
 && sed -i '/^#VTK_APPENDIX_USR.*/aVTK_APPENDIX_USR='"${VTKAPPENDIX}" ./MAKE/Makefile.user \
 && make clean-auto

#...........
#Installing LIGGGTHS
RUN make auto

#...........
#Test that CFDEM settings are correct (the alias cfdemSysTest defined in the CFDEM_bashrc file does not work)
WORKDIR $CFDEMINSTDIR
ENV WM_NCOMPPROCS=4
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && . ${CFDEM_bashrc} \
#### && cfdemSysTest 2>&1 | tee log.cfdemSysTest
 && $CFDEM_SRC_DIR/lagrangian/cfdemParticle/etc/cfdemSystemTest.sh 2>&1 | tee log.cfdemSysTest

#...........
#Installing CFDEM
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && . ${CFDEM_bashrc} \
#### && cfdemCompLIG | tee log.cfdemCompLIG
 && $CFDEM_SRC_DIR/lagrangian/cfdemParticle/etc/compileLIGGGHTS.sh 2>&1 | tee log.cfdemCompLIG

RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && . ${CFDEM_bashrc} \
#### && cfdemCompCFDEMsrc | tee log.cfdemCompCFDEMsrc
 && $CFDEM_SRC_DIR/lagrangian/cfdemParticle/etc/compileCFDEMcoupling_src.sh 2>&1 | tee log.cfdemCompCFDEMsrc

RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && . ${CFDEM_bashrc} \
#### && cfdemCompCFDEMsol | tee log.cfdemCompCFDEMsol
 && $CFDEM_SRC_DIR/lagrangian/cfdemParticle/etc/compileCFDEMcoupling_sol.sh 2>&1 | tee log.cfdemCompCFDEMsol

RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && . ${CFDEM_bashrc} \
#### && cfdemCompCFDEMuti | tee log.cfdemCompCFDEMuti
 && $CFDEM_SRC_DIR/lagrangian/cfdemParticle/etc/compileCFDEMcoupling_uti.sh 2>&1 | tee log.cfdemCompCFDEMuti

#...........
#Test that CFDEM installation has gone right
WORKDIR $CFDEMINSTDIR
RUN . ${OFBASHRC} ${BASHRC_OPTIONS} \
 && . ${CFDEM_bashrc} \
#### && cfdemSysTest 2>&1 | tee log.cfdemSysTestFinal
 && $CFDEM_SRC_DIR/lagrangian/cfdemParticle/etc/cfdemSystemTest.sh 2>&1 | tee log.cfdemSysTestFinal

#...........
#Allowing normal users to read,write and execute on the VTK, LIGGGHTS and CFDEM installation
RUN chmod -R 777 $VTKBASEDIR \
 && chmod -R 777 $LIGGGHTSINSTDIR \
 && chmod -R 777 $CFDEMINSTDIR

#...........
## Setup to source OpenFoam OFBASHRC at container startup
# Docker: use file in /etc/profile
RUN echo 'if [ -z ${DEFINE_ME_ONCE+x} ] ; then' >/etc/profile.d/zz_openfoam.sh && \
    echo " . ${OFBASHRC}" >>/etc/profile.d/zz_openfoam.sh && \
    echo " . ${CFDEM_bashrc}" >>/etc/profile.d/zz_openfoam.sh && \
    echo ' export DEFINE_ME_ONCE="1"' >>/etc/profile.d/zz_openfoam.sh && \
    echo 'fi' >>/etc/profile.d/zz_openfoam.sh
# Singularity: use /.singularity.d/env/91-environment.sh
RUN mkdir -p /.singularity.d/env/ && \
    cp -p /etc/profile.d/zz_openfoam.sh /.singularity.d/env/91-environment.sh
# OpenFoam OFBASHRC needs bash shell, not sh
# This is already done in the starting base image
#RUN /bin/mv /bin/sh /bin/sh.original && /bin/ln -s /bin/bash /bin/sh
# To enable sourcing of OFBASHRC with Docker at startup, need to have a login shell with `-l`
ENTRYPOINT [ "/bin/bash", "-l", "-c", "$*", "--" ]
CMD [ "/bin/bash" ]

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
## Starting as ofuser by default
USER ofuser
WORKDIR /home/ofuser
