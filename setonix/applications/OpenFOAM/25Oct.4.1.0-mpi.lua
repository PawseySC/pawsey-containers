-- -*- lua -*-
-- Module file created by spack (https://github.com/spack/spack) on 2026-08-19 23:01:04.466352
--
-- singularityce@4.1.0+network+suid build_system=makefile platform=linux os=sles15 target=zen3/q7bmm6m
--

whatis([[Name : singularityce]])
whatis([[Short description : Singularity is a container technology focused on building portable encapsulated environments to support 'Mobility of Compute' For older versions of Singularity (pre 3.0) you should use singularity-legacy, which has a different install base (Autotools).]])
whatis([[Version : 4.1.0]])
whatis([[Compiler : gcc@14.2.0/kptdqdix4f744qd2xbtewigg64byquje]])
whatis([[Flags :  cflags='-O3 -O0' cppflags=-O3 cxxflags='-O3 -O0' fflags='-O3 -O0 -fallow-argument-mismatch' ]])
whatis([[Target : zen3]])
whatis([[Build date : Wed Aug 19 23:01:02 2026]])
whatis([[Spack configuration : +network+suid build_system=makefile]])
whatis([[Path : /software/setonix/2026.09/software/linux-sles15-zen3/gcc-14.2.0/singularityce-4.1.0-q7bmm6mmewwj5nkg3taoztgzftgobhii]])

help([[Singularity is a container technology focused on building portable
encapsulated environments to support "Mobility of Compute" For older
versions of Singularity (pre 3.0) you should use singularity-legacy,
which has a different install base (Autotools). Needs post-install
chmod/chown steps to enable full functionality. See package definition
or `spack-build-out.txt` build log for details, e.g. tail -15 $(spack
location -i singularityce)/.spack/spack-build-out.txt]])



prepend_path("PATH", "/software/setonix/2026.09/software/linux-sles15-zen3/gcc-14.2.0/singularityce-4.1.0-q7bmm6mmewwj5nkg3taoztgzftgobhii/bin", ":")
prepend_path("CMAKE_PREFIX_PATH", "/software/setonix/2026.09/software/linux-sles15-zen3/gcc-14.2.0/singularityce-4.1.0-q7bmm6mmewwj5nkg3taoztgzftgobhii/.", ":")
prepend_path("PATH", "/software/setonix/2026.09/software/linux-sles15-zen3/gcc-14.2.0/singularityce-4.1.0-q7bmm6mmewwj5nkg3taoztgzftgobhii/bin", ":")
prepend_path("MANPATH", "/software/setonix/2026.09/software/linux-sles15-zen3/gcc-14.2.0/singularityce-4.1.0-q7bmm6mmewwj5nkg3taoztgzftgobhii/share/man", ":")
prepend_path("CMAKE_PREFIX_PATH", "/software/setonix/2026.09/software/linux-sles15-zen3/gcc-14.2.0/singularityce-4.1.0-q7bmm6mmewwj5nkg3taoztgzftgobhii/.", ":")
prepend_path("PATH", "/software/setonix/2026.09/software/linux-sles15-zen3/gcc-14.2.0/cryptsetup-2.3.5-mnczslbbzizlch4niuvnvql4fmzims6v/sbin", ":")
setenv("PAWSEY_SINGULARITYCE_HOME", "/software/setonix/2026.09/software/linux-sles15-zen3/gcc-14.2.0/singularityce-4.1.0-q7bmm6mmewwj5nkg3taoztgzftgobhii")
setenv("SINGULARITY_CACHEDIR", os.getenv("MYSOFTWARE").."/.singularity")
-- Singularity configuration START
-- LD_LIBRARY_PATH addition
local singularity_ld_path = ""
-- COS 25.3
singularity_ld_path = singularity_ld_path .. ":/host_lib64"
-- add CRAY_PATHS START
singularity_ld_path = singularity_ld_path .. ":/opt/cray/pe/mpich/9.1.0/ofi/gnu/12.3/lib-abi-mpich:/opt/cray/pe/mpich/9.1.0/gtl/lib:/opt/cray/xpmem/default/lib64:/opt/cray/pe/pmi/default/lib:/opt/cray/pe/pals/default/lib"
--singularity_ld_path = singularity_ld_path .. ":/opt/cray/pe/gcc-libs"
-- add CRAY_PATHS END
-- add MPI START
-- for Cassini nics and SS>=11
-- add libfabric, might need version changes
singularity_ld_path = singularity_ld_path .. ":/opt/cray/libfabric/2.3.1/lib64/"
-- add MPI END
-- add CURRENT_HOST_LD_PATH START
singularity_ld_path = singularity_ld_path .. ":$LD_LIBRARY_PATH"
-- add CURRENT_HOST_LD_PATH END
setenv("SINGULARITYENV_LD_LIBRARY_PATH", singularity_ld_path)

-- BIND_PATH addition
-- add LOCAL FILESYSTEM START
local singularity_bindpath = ",/scratch,/software"
-- add LOCAL FILESYSTEM END
-- add SLURM START
-- add SLURM END
-- add CRAY_PATHS START
singularity_bindpath = singularity_bindpath .. ",/var/opt/cray/pe,/opt/cray,/opt/xpmem"
-- commented out below, adding lib64. Could be useful
-- singularity_bindpath = singularity_bindpath .. ",/lib64/libc.so.6,/lib64/libpthread.so.0,/lib64/librt.so.1,/lib64/libdl.so.2,/lib64/libz.so.1,/lib64/libselinux.so.1,/lib64/libm.so.6"
-- add CRAY_PATHS END
-- add MPI START
-- for Cassini nics and SS>=11
-- added several different libraries to ensure that mpi works
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/libcxi.so.1,/usr/lib64/libcurl.so.4,/usr/lib64/libjson-c.so.3"
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/libnghttp2.so.14,/usr/lib64/libidn2.so.0,/usr/lib64/libssh.so.4,/usr/lib64/libpsl.so.5,/usr/lib64/libssl.so.3,/usr/lib64/libcrypto.so.3,/usr/lib64/libgssapi_krb5.so.2,/usr/lib64/libldap_r-2.4.so.2,/usr/lib64/liblber-2.4.so.2,/usr/lib64/libunistring.so.2,/usr/lib64/libkrb5.so.3,/usr/lib64/libk5crypto.so.3,/lib64/libcom_err.so.2,/usr/lib64/libkrb5support.so.0,/lib64/libresolv.so.2,/usr/lib64/libsasl2.so.3,/usr/lib64/libkeyutils.so.1,/usr/lib64/libpcre.so.1"
-- authentication
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/libmunge.so.2"
-- new additions for libfabric 1.15.2.0
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/libjitterentropy.so.3,/usr/lib64/libbrotlidec.so.1,/usr/lib64/libbrotlicommon.so.1,/usr/lib64/libjansson.so.4"
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/libzstd.so.1"
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/libselinux.so.1"
-- lustre
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/liblustreapi.so.1,/usr/lib64/liblnetconfig.so.4,/usr/lib64/libyaml-0.so.2,/usr/lib64/libnl-genl-3.so.200,/usr/lib64/libnl-3.so.200"
-- COS 25.3
singularity_bindpath = singularity_bindpath .. ",/usr/lib64/liblustreapi.so:/host_lib64/liblustreapi.so"
-- this has to be conditional, path exists only in compute nodes
if isDir("/var/spool/slurmd") then
  singularity_bindpath = singularity_bindpath .. ",/var/spool/slurmd"
  singularity_bindpath = singularity_bindpath .. ",/var/run/munge"
end
-- add MPI END
setenv("SINGULARITY_BINDPATH",singularity_bindpath)

-- LD_PRELOAD addition
local singularity_ld_preload = ""
-- add MPI START
-- preload xpmem for fast mpi communication
singularity_ld_preload = singularity_ld_preload .. ":/opt/xpmem/lib64/libxpmem.so.0"
-- singularity_ld_preload = singularity_ld_preload .. ":/lib64/libc.so.6:/lib64/libpthread.so.0:/lib64/librt.so.1:/lib64/libdl.so.2:/lib64/libz.so.1:/lib64/libselinux.so.1:/lib64/libm.so.6"
-- for Cassini nics and SS>=11
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libcxi.so.1:/usr/lib64/libcurl.so.4:/usr/lib64/libjson-c.so.3"
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libnghttp2.so.14:/usr/lib64/libidn2.so.0:/usr/lib64/libssh.so.4:/usr/lib64/libpsl.so.5:/usr/lib64/libssl.so.3:/usr/lib64/libcrypto.so.3:/usr/lib64/libgssapi_krb5.so.2:/usr/lib64/libldap_r-2.4.so.2:/usr/lib64/liblber-2.4.so.2:/usr/lib64/libunistring.so.2:/usr/lib64/libkrb5.so.3:/usr/lib64/libk5crypto.so.3:/lib64/libcom_err.so.2:/usr/lib64/libkrb5support.so.0:/lib64/libresolv.so.2:/usr/lib64/libsasl2.so.3:/usr/lib64/libkeyutils.so.1:/usr/lib64/libpcre.so.1"
-- authentication
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libmunge.so.2"
-- new additions for libfabric 1.15.2.0
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libjitterentropy.so.3:/usr/lib64/libbrotlidec.so.1:/usr/lib64/libbrotlicommon.so.1:/usr/lib64/libjansson.so.4"
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/liblustreapi.so.1:/usr/lib64/liblnetconfig.so.4:/usr/lib64/libyaml-0.so.2:/usr/lib64/libnl-genl-3.so.200:/usr/lib64/libnl-3.so.200"
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libzstd.so.1"
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/libselinux.so.1"
-- lustre
singularity_ld_preload = singularity_ld_preload .. ":/usr/lib64/liblustreapi.so.1:/usr/lib64/liblnetconfig.so.4:/usr/lib64/libyaml-0.so.2:/usr/lib64/libnl-genl-3.so.200:/usr/lib64/libnl-3.so.200"
-- add MPI END
-- add GPUMPI START
-- add GPUMPI END
prepend_path("SINGULARITYENV_LD_PRELOAD", singularity_ld_preload)

-- add GPUMPI START
-- add GPUMPI END

-- Patch lmod messages in singularity shells
local patch_dir = "/software/setonix/2026.09/pawsey/lmod-variable-fixes"
local patch_file = patch_dir .. "/pawsey_fix_initial_bash.lua"
local func = assert(loadfile(patch_file))()
func(patch_dir)


-- Enforce explicit usage of versions by requiring full module name
if (mode() == "load") then
  if (myModuleUsrName() ~= myModuleFullName()) then
    LmodError(
        "Default module versions are disabled by your systems administrator.\n\n",
        "\tPlease load this module as <name>/<version>.\n"
    )
  end
end

-- Access is granted only to specific groups
if not isDir("/software/setonix/2026.09/software/linux-sles15-zen3/gcc-14.2.0/singularityce-4.1.0-q7bmm6mmewwj5nkg3taoztgzftgobhii") then
    LmodError (
        "You don't have the necessary rights to run \"singularityce\".\n\n",
        "\tPlease raise a help ticket if you need further information on how to get access to it.\n"
    )
end
