#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
##IMPORTANT: This recipe is still failing!
#Here create an image with waves2Foam
#from the already existing and working image of openfoam
FROM quay.io/pawsey/openfoam-org:2.4.x
#OpenFOAM version using:
ARG OFVERSION="2.4.x"

LABEL maintainer="mebasha@pawsey.org.au"
#Using bash from now on
SHELL ["/bin/bash","-c"]

USER root

#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# Repeating settings from the basic installation
ARG OFINSTDIR=/opt/OpenFOAM
ARG OFPREFS=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/prefs.sh
ARG OFBASHRC=${OFINSTDIR}/OpenFOAM-${OFVERSION}/etc/bashrc
ARG OFTHIRDPARTYDIR=${OFINSTDIR}/ThirdParty-${OFVERSION}


WORKDIR ${OFINSTDIR}
#Swak4form installation
RUN . ${OFBASHRC} \
 && wget "https://github.com/Unofficial-Extend-Project-Mirror/openfoam-extend-Breeder2.0-libraries-swak4Foam/archive/1bf86713f5a9c4ec24d5fcd22edd40a04991b215.tar.gz" -O swak4Foam.tar.gz \
 && tar -xf swak4Foam.tar.gz \
 && mv openfoam-extend-Breeder2.0-libraries-swak4Foam-1bf86713f5a9c4ec24d5fcd22edd40a04991b215 swak4Foam \
 && cd swak4Foam \
 && mv swakConfiguration.example swakConfiguration

RUN . ${OFBASHRC} \
 && wget http://ftp.gnu.org/gnu/bison/bison-2.7.1.tar.gz \
 && tar -xvf bison-2.7.1.tar.gz && rm bison-2.7.1.tar.gz \
 && cd bison-2.7.1 \
 && sed -i 's/_IO_ftrylockfile/_IO_EOF_SEEN/' lib/fseterr.c \
 && sed -i '21 i #if !defined _IO_IN_BACKUP && defined _IO_EOF_SEEN' lib/stdio-impl.h \
 && sed -i '22 i #define _IO_IN_BACKUP 0x100' lib/stdio-impl.h \
 && sed -i '23 i #endif' lib/stdio-impl.h \
 && ./configure --prefix=/opt/OpenFOAM/swak4Foam/privateRequirements/ \
 && make -j16 \
 && make install


ENV PATH $PATH:${FOAM_USER_APPBIN}:${FOAM_APPBIN}:/opt/OpenFOAM/swak4Foam/privateRequirements/bin:/opt/OpenFOAM/OpenFOAM-2.4.x/src/OpenFOAM/lnInclude
ENV LD_LIBRARY_PATH ${LD_LIBRARY_PATH}:${FOAM_USER_LIBBIN}:${FOAM_LIBBIN}
ENV CPATH $CPATH:/usr/include/python2.7:/opt/OpenFOAM/OpenFOAM-2.4.x/src/OpenFOAM/lnInclude
ENV SWAK4FOAM_SRC /opt/OpenFOAM/swak4Foam/Libraries

WORKDIR ${OFINSTDIR}
#Swak4form installation
RUN . ${OFBASHRC} \
 && cd swak4Foam \
 #sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/swak4FoamParsers/lnInclude/NumericAccumulationNamedEnum.C
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/swak4FoamParsers/namedEnums/NumericAccumulationNamedEnum.C \
 #sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/swak4FoamParsers/lnInclude/CommonValueExpressionDriver.C
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/swak4FoamParsers/CommonValueExpressionDriver.C \
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleFunctionObjects/DataStructures/Distribution/SimpleDistribution.C \
 #sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleFunctionObjects/lnInclude/SimpleDistribution.C
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleSearchableSurfaces/Objects/unitCylinderSearchableSurface.C \
 #sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleSearchableSurfaces/lnInclude/unitCylinderSearchableSurface.C
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/swak4FoamParsers/helpers/AccumulationCalculation.C \
 #sed -i 's/HUGE/pTraits<scalar>::min/g'  Libraries/swak4FoamParsers/lnInclude/AccumulationCalculation.C
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleFunctionObjects/misc/panicDump/panicDumpFunctionObject.C \
 #sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleFunctionObjects/lnInclude/panicDumpFunctionObject.C
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleFunctionObjects/writeFields/conditionDrivenWriting/writeIfFieldOutside/writeIfFieldOutsideFunctionObject.C \
 #sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleFunctionObjects/lnInclude/writeIfFieldOutsideFunctionObject.C
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleSearchableSurfaces/Operations/binaryOperationSearchableSurface.C \
 #sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleSearchableSurfaces/lnInclude/binaryOperationSearchableSurface.C
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleFunctionObjects/misc/writeAndEndFieldRangeFunctionObject/writeAndEndFieldRangeFunctionObject.C \
#sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/simpleFunctionObjects/lnInclude/writeAndEndFieldRangeFunctionObject.C
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/functionPlugins/swakSurfacesAndSetsFunctionPlugin/surfaceDistancePluginFunction.C \
#sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/functionPlugins/swakSurfacesAndSetsFunctionPlugin/lnInclude/surfaceDistancePluginFunction.C
 && sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/functionPlugins/swakSurfacesAndSetsFunctionPlugin/setDistancePluginFunction.C \
#sed -i 's/HUGE/pTraits<scalar>::min/g' Libraries/functionPlugins/swakSurfacesAndSetsFunctionPlugin/lnInclude/setDistancePluginFunction.C
 && ./Allwmake 2>&1 | tee log.Allwmakeswak

ENV LD_LIBRARY_PATH ${LD_LIBRARY_PATH}:/home/ofuser/OpenFOAM/ofuser-2.4.x/platforms/linux64GccDPOpt/lib

RUN mv /home/ofuser/OpenFOAM/ofuser-2.4.x/platforms/linux64GccDPOpt/lib/* /opt/OpenFOAM/OpenFOAM-2.4.x/platforms/linux64GccDPOpt/lib/ \
&& mv /home/ofuser/OpenFOAM/ofuser-2.4.x/platforms/linux64GccDPOpt/bin/* /opt/OpenFOAM/OpenFOAM-2.4.x/platforms/linux64GccDPOpt/bin/

USER ofuser
WORKDIR /home/ofuser
                       
