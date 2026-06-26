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
/usr/lib64/libcxi.so.1,/usr/lib64/libcurl.so.4,/usr/lib64/libjson-c.so.3,/usr/lib64/libnghttp2.so.14,/usr/lib64/libidn2.so.0,\
/usr/lib64/libssh.so.4,/usr/lib64/libpsl.so.5,/usr/lib64/libssl.so.3,/usr/lib64/libcrypto.so.3,/usr/lib64/libgssapi_krb5.so.2,\
/usr/lib64/libldap_r-2.4.so.2,/usr/lib64/liblber-2.4.so.2,/usr/lib64/libunistring.so.2,/usr/lib64/libkrb5.so.3,/usr/lib64/libk5crypto.so.3,\
/lib64/libcom_err.so.2,/usr/lib64/libkrb5support.so.0,/lib64/libresolv.so.2,/usr/lib64/libsasl2.so.3,/usr/lib64/libkeyutils.so.1,/usr/lib64/libpcre.so.1,\
/usr/lib64/libmunge.so.2,/usr/lib64/libjitterentropy.so.3,/usr/lib64/libbrotlidec.so.1,/usr/lib64/libbrotlicommon.so.1,/usr/lib64/libjansson.so.4,/usr/lib64/libzstd.so.1,\
/usr/lib64/libselinux.so.1,\
/usr/lib64/liblustreapi.so.1,/usr/lib64/liblnetconfig.so.4,/usr/lib64/libyaml-0.so.2,/usr/lib64/libnl-genl-3.so.200,/usr/lib64/libnl-3.so.200,\
/usr/lib64:/host_lib64,\
/var/spool/slurmd,/var/run/munge
export SINGULARITYENV_LD_LIBRARY_PATH=:/host_lib64\
:/opt/cray/pe/mpich/${crayver}/ofi/gnu/12.3/lib-abi-mpich\
:/opt/cray/pe/mpich/${crayver}/gtl/lib\
:/opt/cray/xpmem/default/lib64:/opt/cray/pe/pmi/default/lib:/opt/cray/pe/pals/default/lib\
:/opt/cray/libfabric/${libfabricver}/lib64/\
:$LD_LIBRARY_PATH
export SINGULARITYENV_LD_PRELOAD=:/opt/xpmem/lib64/libxpmem.so.0:/usr/lib64/libcxi.so.1\
:/usr/lib64/libcurl.so.4:/usr/lib64/libjson-c.so.3:/usr/lib64/libnghttp2.so.14:/usr/lib64/libidn2.so.0:/usr/lib64/libssh.so.4\
:/usr/lib64/libpsl.so.5:/usr/lib64/libssl.so.3:/usr/lib64/libcrypto.so.3:/usr/lib64/libgssapi_krb5.so.2:/usr/lib64/libldap_r-2.4.so.2:/usr/lib64/liblber-2.4.so.2\
:/usr/lib64/libunistring.so.2:/usr/lib64/libkrb5.so.3:/usr/lib64/libk5crypto.so.3:/lib64/libcom_err.so.2:/usr/lib64/libkrb5support.so.0:/lib64/libresolv.so.2\
:/usr/lib64/libsasl2.so.3:/usr/lib64/libkeyutils.so.1:/usr/lib64/libpcre.so.1:/usr/lib64/libmunge.so.2:/usr/lib64/libjitterentropy.so.3:/usr/lib64/libbrotlidec.so.1\
:/usr/lib64/libbrotlicommon.so.1:/usr/lib64/libjansson.so.4\
:/usr/lib64/liblustreapi.so.1:/usr/lib64/liblnetconfig.so.4:/usr/lib64/libyaml-0.so.2:/usr/lib64/libnl-genl-3.so.200:/usr/lib64/libnl-3.so.200:/usr/lib64/libzstd.so.1:/usr/lib64/libselinux.so.1
fi

echo "SINGULARITY env ------- start"
env | grep "SINGULARITY"
echo "SINGULARITY env ------- end"
echo "MPICH env ------- start"
env | grep "MPICH"
echo "MPICH env ------- end "