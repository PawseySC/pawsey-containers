FROM quay.io/pawsey/mpich-base:3.4.3_ubuntu20.04

SHELL ["/bin/bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

#step 0
#sed xenial repo to apt source list
#RUN echo 'deb http://dk.archive.ubuntu.com/ubuntu/ xenial main' >> /etc/apt/sources.list \
#    && echo 'deb http://dk.archive.ubuntu.com/ubuntu/ xenial universe' >> /etc/apt/sources.list \
#    && echo 'deb http://archive.ubuntu.com/ubuntu xenial main' >> /etc/apt/sources.list


RUN apt-get update -qq \
&& apt-get  -y --no-install-recommends install \
git-core binutils-dev cmake \
libncurses5-dev gnuplot gnuplot-qt \
libxt-dev rpm mercurial graphviz python python-dev \
vim scotch libscotch-dev libgsl-dev gcc-7 g++-7 libfl-dev

#RUN sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-5 1 \
 #&& sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-5 1

RUN mkdir -p /opt/foam

#source files from vmishra
ADD foam-extend-4.1.tar.gz /opt/foam


# preference and setting files
ARG OFPREFS=/opt/foam/foam-extend-4.1/etc/prefs.sh
ARG OFSET=/opt/foam/foam-extend-4.1/etc/settings.sh
ARG OFBASHRC=/opt/foam/foam-extend-4.1/etc/bashrc
#SRC installation
ARG OFINSTDIR=/opt/foam/foam-extend-4.1

ENV CPATH $CPATH:/usr/include:/usr/include/gsl
ENV LD_LIBRARY_PATH $LD_LIBRARY_PATH:/usr/lib:/usr/lib/x86_64-linux-gnu

#RUN cd /opt/foam \
#&& git clone git://git.code.sf.net/p/foam-extend/foam-extend-4.1 foam-extend-4.1
#changes to bashrc and settings file

WORKDIR $OFINSTDIR
RUN sed -i -e 's/foamInstall=\/group\/pawsey0126\/avalizadeh\/$WM_PROJECT/foamInstall=\/opt\/$WM_PROJECT/' $OFBASHRC \
&& sed -i -e 's/WM_MPLIB:=CRAY-MPICH/WM_MPLIB:=SYSTEMMPICH/' $OFBASHRC \
&& sed -i -e 's/WM_COMPILER:=Cray/WM_COMPILER:=Gcc/'  $OFBASHRC \
&& sed -i -e 's/WM_ARCH_OPTION:=cray/WM_ARCH_OPTION:=64/' $OFBASHRC \
#&& sed -i -e 's/#export WM_THIRD_PARTY_USE_BISON_27=1/export WM_THIRD_PARTY_USE_BISON_27=1/'  $OFBASHRC \
&& sed -i -e 's/export WM_THIRD_PARTY_USE_OPENMPI_311=1/#export WM_THIRD_PARTY_USE_OPENMPI_311=1/' $OFBASHRC \
&& sed -i -e 's/export WM_THIRD_PARTY_USE_SCOTCH_604=1/#export WM_THIRD_PARTY_USE_SCOTCH_604=1/'  $OFBASHRC \
&& sed -i -e 's/CRAY-MPICH)/SYSTEMMPICH)/' $OFSET \
&& sed -i -e 's/$MPICH_DIR/\/usr/' $OFSET \
&& sed -i -e 's/export FOAM_MPI=cray-mpich/export FOAM_MPI=system-mpich/' $OFSET \
&& sed -i -e 's/#_foamAddPath/_foamAddPath/' $OFSET \
&& echo "export WM_CC='gcc-7'"  >> $OFPREFS \
&& echo "export WM_CXX='g++-7'"  >> $OFPREFS \
&& echo 'export MPI_ROOT="/usr"' >>  $OFPREFS \
&& echo 'export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX"' >>  $OFPREFS \
&& echo 'export MPI_ARCH_INC="${MPI_ROOT}/include"' >>  $OFPREFS \
&& echo 'export SCOTCH_SYSTEM=1' >>  $OFPREFS \
&& echo 'export SCOTCH_DIR=/usr' >>  $OFPREFS \
&& echo 'export SCOTCH_BIN_DIR=$SCOTCH_DIR/bin'  >>  $OFPREFS \
&& echo 'export SCOTCH_LIB_DIR=$SCOTCH_DIR/lib/x86_64-linux-gnu/' >>  $OFPREFS \
&& echo 'export SCOTCH_INCLUDE_DIR=$SCOTCH_DIR/include/scotch'  >>  $OFPREFS \
&& echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >>  $OFPREFS \
&& echo 'export WAVES_GSL_INCLUDE=/usr/include/gsl' >> $OFPREFS \
&& echo 'export WAVES_GSL_LIB=/usr/lib/x86_64-linux-gnu' >> $OFPREFS \
#changes to thirdparty software build packages links
&& sed -i -e 's/http:\/\/glaros.dtc.umn.edu\/gkhome\/fetch\/sw\/parmetis\/parmetis-4.0.3.tar.gz/https:\/\/launchpad.net\/ubuntu\/+archive\/primary\/+sourcefiles\/parmetis\/4.0.3-5build1\/parmetis_4.0.3.orig.tar.gz/' $OFINSTDIR/ThirdParty/AllMake.stage3 \
&& sed -i -e 's/http:\/\/glaros.dtc.umn.edu\/gkhome\/fetch\/sw\/parmetis/https:\/\/launchpad.net\/ubuntu\/+archive\/primary\/+sourcefiles\/parmetis\/4.0.3-5build1/' $OFINSTDIR/ThirdParty/rpmBuild/SPECS/parmetis-4.0.3.spec \
&& sed -i -e 's/%url\/%{name}-%{version}.tar.gz/%url\/%{name}_%{version}.orig.tar.gz/' $OFINSTDIR/ThirdParty/rpmBuild/SPECS/parmetis-4.0.3.spec \
&& sed -i -e 's/http:\/\/portal.nersc.gov\/project\/visit\/third_party\/libccmio-2.6.1.tar.gz/http:\/\/downloads.sourceforge.net\/project\/foam-extend\/ThirdParty\/libccmio-2.6.1.tar.gz/' $OFINSTDIR/ThirdParty/AllMake.stage3 \
&& sed -i -e 's/SWAK_RELEASE_VERSION=0.4.2/SWAK_RELEASE_VERSION=0.4.0/' $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i -e 's/#hg checkout version_${SWAK_RELEASE_VERSION}_v2.x/hg checkout version_${SWAK_RELEASE_VERSION}_v2.x/'  $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i -e 's/hg checkout compile_foamExtend4.1/#hg checkout compile_foamExtend4.1/'  $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "85 i sed -i -e 's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/swak4FoamParsers/namedEnums/NumericAccumulationNamedEnum.C" $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "86 i sed -i -e  's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/swak4FoamParsers/CommonValueExpressionDriver.C" $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "87 i sed -i -e 's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/simpleFunctionObjects/DataStructures/Distribution/SimpleDistribution.C" $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "88 i sed -i -e 's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/simpleSearchableSurfaces/Objects/unitCylinderSearchableSurface.C" $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "89 i sed -i -e 's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/swak4FoamParsers/helpers/AccumulationCalculation.C" $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "90 i sed -i -e 's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/simpleFunctionObjects/misc/panicDump/panicDumpFunctionObject.C" $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "91 i sed -i -e 's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/simpleFunctionObjects/writeFields/conditionDrivenWriting/writeIfFieldOutside/writeIfFieldOutsideFunctionObject.C" $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "92 i sed -i -e 's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/simpleSearchableSurfaces/Operations/binaryOperationSearchableSurface.C" $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "93 i sed -i -e 's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/simpleFunctionObjects/misc/writeAndEndFieldRangeFunctionObject/writeAndEndFieldRangeFunctionObject.C" $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "94 i sed -i -e 's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/functionPlugins/swakSurfacesAndSetsFunctionPlugin/surfaceDistancePluginFunction.C" $OFINSTDIR/ThirdParty/AllMake.stage5 \
&& sed -i "95 i sed -i -e 's/HUGE/pTraits<scalar>::min/g' $OFINSTDIR/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/Libraries/functionPlugins/swakSurfacesAndSetsFunctionPlugin/setDistancePluginFunction.C" $OFINSTDIR/ThirdParty/AllMake.stage5
#&& sed -i -e 's/SWAK_RELEASE_VERSION=0.4.0/SWAK_RELEASE_VERSION=0.3.2/' $OFINSTDIR/ThirdParty/AllMake.stage5 \
#&& sed -i "96 i cp /opt/foam/foam-extend-4.1/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/swakConfiguration.example /opt/foam/foam-extend-4.1/ThirdParty/rpmBuild/BUILD/swak4Foam-0.4.0/swakConfiguration" $OFINSTDIR/ThirdParty/AllMake.stage5 \
#&& sed -i -e 's/cd swak4/#cd swak4/' $OFINSTDIR/ThirdParty/AllMake.stage5 \

WORKDIR $OFINSTDIR
RUN . $OFBASHRC \
&& ./Allclean &&  wmakeLnIncludeAll


WORKDIR $OFINSTDIR/ThirdParty


RUN wget http://ftp.gnu.org/gnu/bison/bison-2.7.1.tar.gz \
 && tar -xvf bison-2.7.1.tar.gz && rm bison-2.7.1.tar.gz \
 && cd bison-2.7.1 \
 && sed -i 's/_IO_ftrylockfile/_IO_EOF_SEEN/' lib/fseterr.c \
# && sed -i '21 i #if !defined _IO_IN_BACKUP && defined _IO_EOF_SEEN' lib/stdio-impl.h \
# && sed -i '22 i #define _IO_IN_BACKUP 0x100' lib/stdio-impl.h \
  && ./configure --prefix=/usr \
 && make -j16 \
 && make install

#ENV WM_NCOMPPROCS=64
#ENV WM_64=ON

ENV SWAK4FOAM_SYSTEM=1



# Thirdparty software installation
RUN . $OFBASHRC && ./AllClean && ./AllMake 2>&1 | tee log.buildtp

WORKDIR $OFINSTDIR

# foamextend installation
#RUN mv applications/utilities/NavalHydro /opt/NavalHydro

#RUN sed -i -e 's/EXE_INC = \\/EXE_INC = -I${OFUTILS}\/NavalHydro\/src\/navalHydro\/lnInclude \\/' applications/utilities/NavalHydro/src/navalHydro/Make/options \
RUN . $OFBASHRC \
&& ./Allwmake 2>&1 | tee log.buildfe41


ARG OFVERSION="4.1"
ARG OFUSERDIR=/home/ofuser/OpenFOAM

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
# IV. Final settings
#...........
#Create the openfoam user directory
USER ofuser
RUN mkdir -p ${OFUSERDIR}/ofuser-${OFVERSION} \
 && chmod -R 777 ${OFUSERDIR}
USER root


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

RUN  mv /root/foam/root-4.1/applications/bin/linux64GccDPOpt/* /opt/foam/foam-extend-4.1/applications/bin/linux64GccDPOpt/ && mv /root/foam/root-4.1/lib/linux64GccDPOpt/*  /opt/foam/foam-extend-4.1/lib/linux64GccDPOpt/


WORKDIR $OFINSTDIR
#disabling alisa in bashrc and settings file
RUN sed -i -e 's/alias wm64/#alias wm64/' etc/aliases.sh \
&& sed -i -e 's/alias wm32/#alias wn32/' etc/aliases.sh \
&& sed -i -e 's/alias wmSP/#alias wmSP/'  etc/aliases.sh \
&& sed -i -e 's/alias wmDP/#alias wmDP/'  etc/aliases.sh \
&& sed -i "35i alias wmSet\=\'\. \$WM_PROJECT_DIR/etc/bashrc\'" etc/aliases.sh \
&& sed -i "36i alias wm64\=\'wmSet WM_ARCH_OPTION\=64\'" etc/aliases.sh \
&& sed -i "37i alias wm32\=\'wmSet WM_ARCH_OPTION\=32\'" etc/aliases.sh \
&& sed -i "38i alias wmSP\=\'wmSet WM_PRECISION_OPTION\=SP\'" etc/aliases.sh \
&& sed -i "39i alias wmDP\=\'wmSet WM_PRECISION_OPTION\=DP\'" etc/aliases.sh \
&& sed -i "40i alias wmLP\=\'wmSet WM_PRECISION_OPTION\=LP\'" etc/aliases.sh

ENV WM_PROJECT=/opt/foam
ENV WM_PROJECT_DIR=$WM_PROJECT/foam-extend-4.1
ENV WM_ARCH=linux64
ENV WM_COMPILER=Gcc
ENV WM_PRECISION_OPTION=DP
ENV WM_COMPILE_OPTION=Opt
# location of the jobControl directory
ENV FOAM_JOB_DIR=$HOME/$WM_PROJECT/jobControl


ENV WM_PROJECT_VERSION=4.1
ENV WM_PROJECT_USER_DIR=$HOME/$WM_PROJECT/$USER-$WM_PROJECT_VERSION

# wmake configuration
ENV WM_DIR=$WM_PROJECT_DIR/wmake
ENV WM_LINK_LANGUAGE=c++
ENV WM_OPTIONS=$WM_ARCH$WM_COMPILER$WM_PRECISION_OPTION$WM_COMPILE_OPTION
ENV PATH=$WM_DIR:$PATH

# base configuration
ENV FOAM_APP=$WM_PROJECT_DIR/applications
ENV FOAM_APPBIN=$WM_PROJECT_DIR/applications/bin/$WM_OPTIONS
ENV FOAM_LIB=$WM_PROJECT_DIR/lib
ENV FOAM_LIBBIN=$WM_PROJECT_DIR/lib/$WM_OPTIONS
ENV FOAM_SRC=$WM_PROJECT_DIR/src

# shared site configuration - similar naming convention as ~FOAM expansion
ENV FOAM_SITE_DIR=$WM_PROJECT_INST_DIR/site/$WM_PROJECT_VERSION
ENV FOAM_SITE_APPBIN=$FOAM_SITE_DIR/bin/$WM_OPTIONS
ENV FOAM_SITE_LIBBIN=$FOAM_SITE_DIR/lib/$WM_OPTIONS

# user configuration
ENV FOAM_USER_APPBIN=$WM_PROJECT_USER_DIR/applications/bin/$WM_OPTIONS
ENV FOAM_USER_LIBBIN=$WM_PROJECT_USER_DIR/lib/$WM_OPTIONS

# convenience
ENV FOAM_TUTORIALS=$WM_PROJECT_DIR/tutorials
ENV FOAM_UTILITIES=$FOAM_APP/utilities
ENV FOAM_SOLVERS=$FOAM_APP/solvers
ENV FOAM_RUN=$WM_PROJECT_USER_DIR/run
ENV FOAM_TEST_HARNESS_DIR=$WM_PROJECT_DIR/testHarness/foam-extend/$WM_PROJECT_VERSION


ENV WM_THIRD_PARTY_DIR=$WM_PROJECT_DIR/ThirdParty
# add FOAM scripts and wmake to the path
ENV PATH=$WM_DIR:$WM_PROJECT_DIR/bin:$PATH

ENV PATH=$PATH:$FOAM_APPBIN:$FOAM_SITE_APPBIN:$FOAM_USER_APPBIN
ENV LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$FOAM_LIBBIN:$FOAM_SITE_LIBBIN:$FOAM_USER_LIBBIN


# path for thirdparty lib
ENV PATH=$PATH:/opt/foam/foam-extend-4.1/ThirdParty/packages/hwloc-2.0.1/platforms/linux64GccDPOpt/bin:/opt/foam/foam-extend-4.1/ThirdParty/PyFoamSiteScripts/bin:/opt/foam/foam-extend-4.1/ThirdParty/packages/PyFoam-0.6.9/platforms/noarch/bin:/opt/foam/foam-extend-4.1/ThirdParty/packages/bison-2.7/platforms/linux64GccDPOpt/bin:/opt/foam/foam-extend-4.1/ThirdParty/packages/mesquite-2.3.0/platforms/linux64GccDPOpt/bin:/opt/mpich/bin
#:/home/ubuntu/foam/ubuntu-4.1/applications/bin/linux64GccDPOpt:/opt/foam/site/4.1/bin/linux64GccDPOpt:/opt/foam/foam-extend-4.1/applications/bin/linux64GccDPOpt:/opt/foam/foam-extend-4.1/wmake:/opt/foam/foam-extend-4.1/bin:

ENV LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/foam/foam-extend-4.1/ThirdParty/packages/bison-2.7/platforms/linux64GccDPOpt/lib:/opt/foam/foam-extend-4.1/ThirdParty/packages/libccmio-2.6.1/platforms/linux64GccDPOpt/lib:/opt/foam/foam-extend-4.1/ThirdParty/packages/ParMGridGen-1.0/platforms/linux64GccDPOpt/lib:/opt/foam/foam-extend-4.1/ThirdParty/packages/parmetis-4.0.3/platforms/linux64GccDPOpt/lib:/opt/foam/foam-extend-4.1/ThirdParty/packages/metis-5.1.0/platforms/linux64GccDPOpt/lib:/opt/foam/foam-extend-4.1/ThirdParty/packages/mesquite-2.3.0/platforms/linux64GccDPOpt/lib:/opt/mpich/lib
#:/home/ubuntu/foam/ubuntu-4.1/lib/linux64GccDPOpt:/opt/foam/site/4.1/lib/linux64GccDPOpt:/opt/foam/foam-extend-4.1/lib/linux64GccDPOpt



## Starting as ofuser by default
USER ofuser
WORKDIR /home/ofuser
