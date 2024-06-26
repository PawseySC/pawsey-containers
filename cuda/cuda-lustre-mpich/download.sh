#!/bin/bash

# lustre version  2.15.63  or main
LUSTRE_VERSION="2.15.63"
# mpich version
MPICH_VERSION="3.4.3"
# osu version
OSU_VERSION="6.2"
script_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

echo "Downloading lustre source"

if [ -d "$script_dir/lustre-build" ]; then
    echo "Removing existing lustre-build directory"
    rm -rf $script_dir/lustre-build
fi

mkdir -p $script_dir/lustre-build
cd $script_dir/lustre-build
git clone git://git.whamcloud.com/fs/lustre-release.git
cd lustre-release
# Fetch tags and checkout the specified version
git fetch --tags && git checkout ${LUSTRE_VERSION}
echo "Finished downloading and checking out lustre source"

echo "Downloading MPICH"
if [ -d "$script_dir/mpich-build" ]; then
    echo "Removing existing mpich-build directory"
    rm -rf $script_dir/mpich-build
fi
mkdir -p $script_dir/mpich-build/
wget -P $script_dir/mpich-build/ http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz
tar xf $script_dir/mpich-build/mpich-${MPICH_VERSION}.tar.gz -C $script_dir/mpich-build/
rm -f $script_dir/mpich-build/mpich-${MPICH_VERSION}.tar.gz
cp $script_dir/mpich_patches.tgz $script_dir/mpich-build/mpich-${MPICH_VERSION}
cd $script_dir/mpich-build/mpich-${MPICH_VERSION}
tar xf mpich_patches.tgz
patch -p0 < csel.patch
patch -p0 < ch4r_init.patch
rm $script_dir/mpich-build/mpich-${MPICH_VERSION}/mpich_patches.tgz
echo "MPICH has been downloaded and patched"

echo "Downloading OSU Benchmarks"
if [ -d "$script_dir/osu-benchmarks" ]; then
    echo "Removing existing osu-benchmarks directory"
    rm -rf $script_dir/osu-benchmarks
fi
mkdir -p $script_dir/osu-benchmarks-build
cd $script_dir/osu-benchmarks-build
wget https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz -O osu-micro-benchmarks-${OSU_VERSION}.tar.gz
tar xzvf osu-micro-benchmarks-${OSU_VERSION}.tar.gz
rm -f osu-micro-benchmarks-${OSU_VERSION}.tar.gz
echo "Finished downloading OSU Benchmarks"

# package all downloaded files for transferring to docker image
cd $script_dir
tar czvf downloaded_files.tar.gz lustre-build mpich-build osu-benchmarks-build
echo "All files have been packaged into downloaded_files.tar.gz"

# del them
rm -rf lustre-build mpich-build osu-benchmarks-build
echo "All source directories have been removed"