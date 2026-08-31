#!/bin/bash

crayver=9.1.0
libfabricver=2.3.1
clearsing=1

module load cray-mpich/${crayver}
module load libfabric/${libfabricver}

if [ ${clearsing} -eq "1" ]
then
        echo "Clearing singularity environment and doing specific bind mounting and other things"
        #bindpath=$(echo $SINGULARITY_BINDPATH | sed "s:,/scratch::g" | sed "s:,/software::g")
        #export SINGULARITY_BINDPATH=${bindpath}
export SINGULARITY_BINDPATH=,/scratch,/software,/var/opt/cray/pe,/opt/cray,/opt/xpmem,\
/usr/lib64/libcxi.so.1,/usr/lib64/libjson-c.so.5,\
/usr/lib64/libmunge.so.2,\
/usr/lib64/liblustreapi.so.1,/usr/lib64/liblnetconfig.so.4,/usr/lib64/libyaml-0.so.2,/usr/lib64/libnl-genl-3.so.200,/usr/lib64/libnl-3.so.200,\
/usr/lib64/liblustreapi.so:/host_lib64/liblustreapi.so,\
/var/spool/slurmd,/var/run/munge
export SINGULARITYENV_LD_LIBRARY_PATH=:/host_lib64\
:/opt/cray/pe/mpich/${crayver}/ofi/gnu/12.3/lib-abi-mpich\
:/opt/cray/pe/mpich/${crayver}/gtl/lib\
:/opt/xpmem/lib64:/opt/cray/pe/pmi/default/lib:/opt/cray/pe/pals/default/lib\
:/opt/cray/libfabric/${libfabricver}/lib64/\
:$LD_LIBRARY_PATH
export SINGULARITYENV_LD_PRELOAD=:/opt/xpmem/lib64/libxpmem.so.0:/usr/lib64/libcxi.so.1\
:/usr/lib64/libcurl.so.4:/usr/lib64/libjson-c.so.5\
:/usr/lib64/libmunge.so.2\
:/usr/lib64/liblustreapi.so.1:/usr/lib64/liblnetconfig.so.4:/usr/lib64/libyaml-0.so.2:/usr/lib64/libnl-genl-3.so.200:/usr/lib64/libnl-3.so.200
fi

echo "SINGULARITY env ------- start"
env | grep "SINGULARITY"
echo "SINGULARITY env ------- end"
echo "MPICH env ------- start"
env | grep "MPICH"
echo "MPICH env ------- end "
