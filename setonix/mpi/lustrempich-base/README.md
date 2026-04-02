# Lustre+MPI

This container provides a basis for running parallel io on HPE Cray EX systems. It does this by providing a
lustre-aware mpi. Then by mounting the appropriate libraries (mpich and associated dependencies, lustre and associated depds) 
into the container, the container will be able to run parallel IO such as parallel HDF5 or ADIOS2.

For completeness, here we provide how the lmod module would add various paths for binding the libraries into the host

```lua

-- example for a lmod module where we set the singularity environments to these 
local singularity_ld_path = "/opt/cray/pe/mpich/default/ofi/gnu/9.1/lib-abi-mpich:/opt/cray/pe/mpich/default/gtl/lib:/opt/cray/xpmem/default/lib64:/opt/cray/pe/pmi/default/lib:/opt/cray/pe/pals/default/lib"
singularity_ld_path = singularity_ld_path .. ":/opt/cray/pe/gcc-libs"
singularity_ld_path = singularity_ld_path .. ":/opt/cray/libfabric/1.15.2.0/lib64/"

-- BIND_PATH addition
local singularity_bindpath = "/some_standard_paths"
-- add CRAY_PATHS START
singularity_bindpath = singularity_bindpath .. ",/var/opt/cray/pe,/etc/opt/cray/pe,/opt/cray,/etc/alternatives/cray-dvs,/etc/alternatives/cray-xpmem"
-- singularity_bindpath = singularity_bindpath .. ",/lib64/libc.so.6,/lib64/libpthread.so.0,/lib64/librt.so.1,/lib64/libdl.so.2,/lib64/libz.so.1,/lib64/libselinux.so.1,/lib64/libm.so.6"
-- add MPI START
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/libcxi.so.1,/usr/lib64/libcurl.so.4,/usr/lib64/libjson-c.so.3"
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/libnghttp2.so.14,/usr/lib64/libidn2.so.0,/usr/lib64/libssh.so.4,/usr/lib64/libpsl.so.5,/usr/lib64/libssl.so.1.1,/usr/lib64/libcrypto.so.1.1,/usr/lib64/libgssapi_krb5.so.2,/usr/lib64/libldap_r-2.4.so.2,/usr/lib64/liblber-2.4.so.2,/usr/lib64/libunistring.so.2,/usr/lib64/libkrb5.so.3,/usr/lib64/libk5crypto.so.3,/lib64/libcom_err.so.2,/usr/lib64/libkrb5support.so.0,/lib64/libresolv.so.2,/usr/lib64/libsasl2.so.3,/usr/lib64/libkeyutils.so.1,/usr/lib64/libpcre.so.1"
-- new additions for libfabric 1.15.2.0
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/libjitterentropy.so.3,/usr/lib64/libbrotlidec.so.1,/usr/lib64/libbrotlicommon.so.1,/usr/lib64/libjansson.so.4"
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/libzstd.so.1"
singularity_bindpath = singularity_bindpath .. ",/lib64/libselinux.so.1"
-- lustre 
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/liblustreapi.so.1,/usr/lib64/liblnetconfig.so.4,/usr/lib64/libyaml-0.so.2,/usr/lib64/libnl-genl-3.so.200,/usr/lib64/libnl-3.so.200"

-- LD_PRELOAD addition 
local singularity_ld_preload = ""
-- add MPI START
-- preload xpmem for fast mpi communication
singularity_ld_preload = singularity_ld_preload .. ":/opt/cray/xpmem/default/lib64/libxpmem.so.0"
-- singularity_ld_preload = singularity_ld_preload .. ":/lib64/libc.so.6:/lib64/libpthread.so.0:/lib64/librt.so.1:/lib64/libdl.so.2:/lib64/libz.so.1:/lib64/libselinux.so.1:/lib64/libm.so.6"
-- for Cassini nics and SS>=11
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libcxi.so.1:/usr/lib64/libcurl.so.4:/usr/lib64/libjson-c.so.3"
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libnghttp2.so.14:/usr/lib64/libidn2.so.0:/usr/lib64/libssh.so.4:/usr/lib64/libpsl.so.5:/usr/lib64/libssl.so.1.1:/usr/lib64/libcrypto.so.1.1:/usr/lib64/libgssapi_krb5.so.2:/usr/lib64/libldap_r-2.4.so.2:/usr/lib64/liblber-2.4.so.2:/usr/lib64/libunistring.so.2:/usr/lib64/libkrb5.so.3:/usr/lib64/libk5crypto.so.3:/lib64/libcom_err.so.2:/usr/lib64/libkrb5support.so.0:/lib64/libresolv.so.2:/usr/lib64/libsasl2.so.3:/usr/lib64/libkeyutils.so.1:/usr/lib64/libpcre.so.1"
-- authentication 
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libmunge.so.2"
-- new additions for libfabric 1.15.2.0
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libjitterentropy.so.3:/usr/lib64/libbrotlidec.so.1:/usr/lib64/libbrotlicommon.so.1:/usr/lib64/libjansson.so.4"
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/liblustreapi.so.1:/usr/lib64/liblnetconfig.so.4:/usr/lib64/libyaml-0.so.2:/usr/lib64/libnl-genl-3.so.200:/usr/lib64/libnl-3.so.200"
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libzstd.so.1"
singularity_ld_preload = singularity_ld_preload .. ":/lib64/libselinux.so.1"
-- lustre
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/liblustreapi.so.1:/usr/lib64/liblnetconfig.so.4:/usr/lib64/libyaml-0.so.2:/usr/lib64/libnl-genl-3.so.200:/usr/lib64/libnl-3.so.200"
-- add MPI END
```


