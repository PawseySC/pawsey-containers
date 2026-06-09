# MPI Recipes

These container provides a basis for running MPI enabled computation (and IO) on HPE Cray EX systems. All these containers rely on injecting host libraries to function across nodes and also for performance. 

These containers build
* `MPICH`
* `Lustre` + `MPICH`, which ensures that MPICH builds with relevant headers and symbols for MPI-IO on a lustre filesystem
* `Lustre` + `MPICH` + `ROCM`. **NOTE** this order may change as `MPICH/4.x` onwards has native GPU support but should be built with `CUDA` or `ROCM` already build and gpu-aware flag enabled. 

The containers also have several tests included in the container.
* `OSU-MB` (OSU Microbenchmarks): which has a large collection of MPI communication tests. These tests are informative though incomplete since they do not check whether messages are correctly sent. Simply latency and throughput. The tests are located in `/usr/local/bin`.
* `profile-util` ([https://github.com/PawseySC/profile_util]): which contains several MPI tests that not only check performance but will check the correctness of results and also has an MPI IO test, which is not present in the OSU benchmark. The executables are found in `/opt/profile_utils/examples/mpi/bin/`. Key tests are 
    - `mpi-io`: runs an io test
    - `mpi-compute`: runs several rounds of point-to-point mpi send receives, collectives, to mimic mpi codes
    - `mpicomm-cpp`: runs a suite of different specific tests, such as check to see if messages sent correctly. 

