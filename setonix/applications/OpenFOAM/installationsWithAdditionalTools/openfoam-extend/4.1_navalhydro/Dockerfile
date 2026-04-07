FROM quay.io/pawsey/foamextend41_ubuntu20_04

LABEL maintainer="mebasha@pawsey.org.au"

SHELL ["/bin/bash", "-c"]

USER root

ARG DEBIAN_FRONTEND=noninteractive

ARG OFINSTDIR=/opt/foam/foam-extend-4.1
ARG OFBASHRC=$OFINSTDIR/etc/bashrc

ADD NavalHydro.tar.gz $OFINSTDIR/applications/utilities/

WORKDIR $OFINSTDIR/applications/utilities/NavalHydro
RUN . $OFBASHRC \
&& ./Allwmake 2>&1 | tee log.buildNavalHydro

RUN  mv /root/foam/root-4.1/applications/bin/linux64GccDPOpt/* /opt/foam/foam-extend-4.1/applications/bin/linux64GccDPOpt/ && mv /root/foam/root-4.1/lib/linux64GccDPOpt/*  /opt/foam/foam-extend-4.1/lib/linux64GccDPOpt/


# Singularity: trick to source startup scripts using bash shell
#              (OpenFoam OFBASHRC needs bash shell, not sh):
RUN /bin/mv /bin/sh /bin/sh.original && /bin/ln -s /bin/bash /bin/sh
#...........
## Starting as ofuser by default
USER ofuser
WORKDIR /home/ofuser
