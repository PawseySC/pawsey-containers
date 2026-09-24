# NAMD Container

## Overview

There are two docker recipes here, one for a HIP GPU-enabled NAMD build, and another that is a pure CPU build. Both versions are built with MPI (via MPICH) and SMP. The two dockerfiles build on top of base mpich images - `namd3-gpu.dockerfile` builds on top of `rocm-mpich-base` while `namd3.dockerfile` builds on top of `mpich-base`.

The build process:
1. Start from base image
2. **GPU-ONLY**: Build `gfortran`
3. Bring in the NAMD source tarball and extract
4. Build `linux-x86_64 MPI-SMP` charm++
5. Install TCL and FFTW libraries. TCL is pre-compiled, while FFTW is built from source (see below note)
6. **GPU-ONLY**: Set gpu architecture to build against and FFTW include/library paths
7. Configure and build `mpi-linux-x86_64-smp` NAMD
8. Add `/opt/namd/bin` to `$PATH` for easy access to NAMD executables
9. Add dockerfile into container

## Build Arguments

`build-arg` parameters relevant for the build command:

- **NAMD_VERSION** (default: `3.0.3`)
  - NAMD version to build.

- **ROCM_VERSION** (default: `7.1.0`) - GPU only
  - Version of ROCm to build against - inherited from the base image the NAMD image builds on top of.

- **MPICH_VERSION** (default: `4.2.2`)
  - MPICH version to build against - inherited from the base image the NAMD image builds on top of.

- **OS_VERSION** (default: `24.04`)
  - Ubuntu version - inherited from the base image the NAMD image builds on top of

- **AMDGPU_TARGETS** (default: `gfx90a` [MI200]) - GPU only
  - GPU architecture(s) to target

## Build Instructions

One first needs to obtain a NAMD source tarball and place it in the same directory as the dockerfile. It should be named `NAMD_${NAMD_VERSION}_Source.tar.gz` to match the format the dockerfile expects. For instance, for version 3.0.3, it should be named `NAMD_3.0.3_Source.tar.gz`. Then just run a standard build command.

## Common build problem points

* The installation instructions on NAMD's documentation make use of a pre-compiled FFTW library from `http://www.ks.uiuc.edu/Research/namd/libraries/fftw-linux-x86_64.tar.gz`. However, across two versions of NAMD this pre-compiled FFTW library has caused errors later on in the NAMD build, primarily due to NAMD requiring FFTW built with certain flags, which the pre-compiled library does not have. Therefore, FFTW/3.3.10 from `fftw.org` has been used instead.
* The GPU build requires patching of specific GPU architectures and more explicit options in the NAMD build. Certain options are not picked up automatically (such as ROCm paths and FFTW paths). These are factored into and included in the dockerfiles. But future versions may require additional patches or explicit paths to be passed or specified.


## Testing the container

The container is tested by running 2 small testcases. Below are some examples of the commands run and performance observed in the two testcases across the two container variants in a small set of configurations.

#### apoa1
```bash
> wget http://www.ks.uiuc.edu/Research/namd/utilities/apoa1.tar.gz
> tar xzf apoa1.tar.gz

# GPU-container
> srun -N 1 -n 2 --gres=gpu:2 singularity exec namd3.0.3-amd-gfx90a.sif namd3 +ppn 7 apoa1/apoa1.namd
PERFORMANCE: 500  averaging 34.8074 ns/day, 0.00248223 sec/step with standard deviation 0.000148228
> srun -N 1 -n 8 --gres=gpu:8 singularity exec namd3.0.3-amd-gfx90a.sif namd3 +ppn 7 apoa1/apoa1.namd
PERFORMANCE: 500  averaging 64.0782 ns/day, 0.00134835 sec/step with standard deviation 0.00033024
> srun -N 2 -n 16 --ntasks-per-node=8 --gres=gpu:8 singularity exec namd3.0.3-amd-gfx90a.sif namd3 +ppn 7 apoa1/apoa1.namd
PERFORMANCE: 500  averaging 64.7198 ns/day, 0.00133499 sec/step with standard deviation 0.000259708

# CPU-container
> srun -N 1 -n 2 singularity exec namd3.0.3.sif namd3 +ppn 7 apoa1/apoa1.namd
PERFORMANCE: 500  averaging 2.03785 ns/day, 0.0423976 sec/step with standard deviation 0.000983872
> srun -N 1 -n 8 singularity exec namd3.0.3.sif namd3 +ppn 7 apoa1/apoa1.namd
PERFORMANCE: 500  averaging 6.12649 ns/day, 0.0141027 sec/step with standard deviation 0.00138682
> srun -N 2 -n 16 --ntasks-per-node=8 singularity exec namd3.0.3.sif namd3 +ppn 7 apoa1/apoa1.namd
PERFORMANCE: 500  averaging 11.7656 ns/day, 0.00734344 sec/step with standard deviation 0.000622107
```

### reframe test
This is the test case that forms the basis of our reframe NAMD tests
```bash
cp /scratch/references/reframe_input/namd/* .

# GPU container
> srun -N 1 -n 2 --gres=gpu:2 singularity exec namd3.0.3-amd-gfx90a.sif namd3 stmv.namd
PERFORMANCE: 500  averaging 1.90583 ns/day, 0.0453345 sec/step with standard deviation 0.000575781
> srun -N 1 -n 4 --gres=gpu:4 singularity exec namd3.0.3-amd-gfx90a.sif namd3 stmv.namd
PERFORMANCE: 500  averaging 2.91447 ns/day, 0.0296452 sec/step with standard deviation 0.0041789
> srun -N 1 -n 8 --gres=gpu:8 singularity exec namd3.0.3-amd-gfx90a.sif namd3 stmv.namd
PERFORMANCE: 500  averaging 4.61788 ns/day, 0.0187099 sec/step with standard deviation 0.00200719
> srun -N 2 -n 8 --ntasks-per-node=4 --gres=gpu:4 singularity exec namd3.0.3-amd-gfx90a.sif namd3 stmv.namd
PERFORMANCE: 500  averaging 3.88997 ns/day, 0.022211 sec/step with standard deviation 0.000388404
> srun -N 2 -n 16 --ntasks-per-node=8 --gres=gpu:8 singularity exec namd3.0.3-amd-gfx90a.sif namd3 stmv.namd
PERFORMANCE: 500  averaging 6.47448 ns/day, 0.0133447 sec/step with standard deviation 0.000554809

# CPU contianer
> srun -N 1 -n 2 singularity exec namd3.0.3.sif namd3 stmv.namd
PERFORMANCE: 500  averaging 0.210741 ns/day, 0.409981 sec/step with standard deviation 0.00349108
> srun -N 1 -n 4 singularity exec namd3.0.3.sif namd3 stmv.namd
PERFORMANCE: 500  averaging 0.408965 ns/day, 0.211265 sec/step with standard deviation 0.00302024
> srun -N 1 -n 8 singularity exec namd3.0.3.sif namd3 stmv.namd
PERFORMANCE: 500  averaging 0.629089 ns/day, 0.137342 sec/step with standard deviation 0.00332675
> srun -N 2 -n 8 --ntasks-per-node=4 singularity exec namd3.0.3.sif namd3 stmv.namd
PERFORMANCE: 500  averaging 0.787603 ns/day, 0.1097 sec/step with standard deviation 0.00506869
> srun -N 2 -n 16 --ntasks-per-node=8 singularity exec namd3.0.3.sif namd3 stmv.namd
PERFORMANCE: 500  averaging 1.23302 ns/day, 0.0700718 sec/step with standard deviation 0.00204303
```