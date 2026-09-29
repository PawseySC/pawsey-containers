# CP2K Container

## Overview

This docker recipe is for a ROCm/HIP GPU-enabled build of CP2K. This dockerfile and build is adapted from the AMD InfinityHub CP2K docker build available at https://github.com/amd/InfinityHub-CI/tree/main/cp2k/docker. This dockerfile builds on top of `rocm-mpich-base`.

The build process:
1. Start from base image
2. Install base packages via `apt-get`
3. Set up compiler symlinks
4. Add ROCm paths to `PATH` and other environment variables
5. Clone spack from github repository
6. Copy in build files - spack environment and associated scripts
7. Install CP2K and all dependencies using spack environment
8. Add `/opt/cp2k/bin` to `PATH` for easy access to CP2K executables
9. Add dockerfile and other build files into container

## Build Arguments

`build-arg` parameters relevant for the build command:

- **CP2K_VERSION** (default: `2026.2`)
  - CP2K version to build.

- **ROCM_VERSION** (default: `7.0.1`)
  - Version of ROCm to build against - inherited from the base image the CP2K image builds on top of.

- **MPICH_VERSION** (default: `4.2.2`)
  - MPICH version to build against - inherited from the base image the CP2K image builds on top of.

- **OS_VERSION** (default: `24.04`)
  - Ubuntu version - inherited from the base image the CP2K image builds on top of

- **AMDGPU_TARGETS** (default: `gfx90a` [MI200])
  - GPU architecture(s) to target

## Common build problem points

* The primary point that is likely to cause issues is the specification of packages in `spack.yaml` for the spack environment when changing CP2K versions or backends, or patches that may be needed when moving to a new version. Particular sticking points in the most recent build were the `sirius` and `dftd4` packages. API changes and version incompatibilities appeared most frequently with those two packages.

## Testing the container

The container is tested by running 3 small testcases. One is our reframe testcase, and two are from supplied scripts under the `scripts` directory.

#### RPA benchmark (32-H2O)
```bash
# From root directory of repo
cd setonix/applications/cp2k/scripts
./run_rpa32.sh /scratch/pawsey0001/cmeyer/containers_2026.09_stack/cp2k2026.2-amd-gfx90a.sif
CP2K RPA Benchmark (32-H2O)
CP2K Branch: v2026.2

==========================================
STAGE 1: Init (H2O-32-PBE-TZ.inp)
Ranks: 1, Threads: 8, GPUs: 1
==========================================

==========================================
Init Stage completed successfully!
==========================================
FORCE_EVAL timing:
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -551.537074909292301
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -551.537074909284797
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -551.537074909301850
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -551.537074909286616

CP2K timing:
 CP2K                                 1  1.0    0.065    0.065   59.861   59.861
Init Stage FOM: 59.861 seconds

==========================================
STAGE 2: Solver (H2O-32-RI-dRPA-TZ.inp)
Ranks: 8, Threads: 8, GPUs: 8
==========================================

==========================================
Solver Stage completed successfully!
==========================================
FORCE_EVAL timing:
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -564.562201074585801
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -564.562201074579775
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -564.562201074579775

CP2K timing:
 CP2K                                 1  1.0    0.075    0.077  121.244  121.245
Solver Stage FOM: 121.245 seconds

==========================================
RPA Benchmark Complete!
==========================================
Init output: /tmp/H2O-32-PBE-TZ-output.txt
Solver output: /tmp/H2O-32-RI-dRPA-TZ-output.txt

Summary:
--------
Init Stage:
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -551.537074909292301
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -551.537074909284797
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -551.537074909301850
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -551.537074909286616
  CP2K FOM: 59.861 seconds

Solver Stage:
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -564.562201074585801
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -564.562201074579775
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]           -564.562201074579775
  CP2K FOM: 121.245 seconds
```

### DFT benchmark

```bash
# From root directory of repo
cd setonix/applications/cp2k/scripts
./run_dft_nrep2.sh /scratch/pawsey0001/cmeyer/containers_2026.09_stack/cp2k2026.2-amd-gfx90a.sif
==========================================
Running CP2K DFT Benchmark
Container: /scratch/pawsey0001/cmeyer/containers_2026.09_stack/cp2k2026.2-amd-gfx90a.sif
MPI Ranks: 8
OpenMP Threads per rank: 8
Executable: cp2k.psmp
CP2K Branch: v2026.2
==========================================
CP2K repository already exists, skipping clone...
Setting execute permissions on scripts...

==========================================
Benchmark completed successfully!
==========================================
Output file: /tmp/H2O-DFT-LS-NREP2-8ranks.txt

FORCE_EVAL timing:
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]          -4402.752774498844701
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]          -4402.752774498844701
 ENERGY| Total FORCE_EVAL ( QS ) energy [hartree]          -4402.752774498844701

All CP2K timing lines:
 CP2K                                 1  1.0    0.096    0.100   27.230   27.230
 CP2K                                 1  1.0    0.098    0.100   27.054   27.054
 CP2K                                 1  1.0    0.102    0.105   27.185   27.185

==========================================
FOM (Figure of Merit): 27.185 seconds
==========================================

Output file saved to: /tmp/H2O-DFT-LS-NREP2-8ranks.txt
```

### reframe test
This is the test case that forms the basis of our reframe CP2K tests
```bash
> cp /scratch/references/reframe_input/cp2k/* .
> sed -i '16a\      MAX_SCF 100' H2O-256.inpss

> srun -N 1 -n 2 --gres=gpu:2 singularity exec cp2k2026.2-amd-gfx90a.sif cp2k.psmp H2O-256.inp # 10 MD steps
 CP2K                                 1  1.0    0.077    0.086  550.695  550.695
> srun -N 1 -n 4 --gres=gpu:4 singularity exec cp2k2026.2-amd-gfx90a.sif cp2k.psmp H2O-256.inp
 CP2K                                 1  1.0    0.079    0.080  311.827  311.828
> srun -N 1 -n 8 --gres=gpu:8 singularity exec cp2k2026.2-amd-gfx90a.sif cp2k.psmp H2O-256.inp
 CP2K                                 1  1.0    0.093    0.097  229.180  229.180
> srun -N 2 -n 8 --ntasks-per-node=4 --gres=gpu:4 singularity exec cp2k2026.2-amd-gfx90a.sif cp2k.psmp H2O-256.inp
 CP2K                                 1  1.0    0.093    0.105  208.057  208.058
> srun -N 2 -n 16 --ntasks-per-node=8 --gres=gpu:8 singularity exec cp2k2026.2-amd-gfx90a.sif cp2k.psmp H2O-256.inp
 CP2K                                 1  1.0    0.129    0.140  143.608  143.609
```