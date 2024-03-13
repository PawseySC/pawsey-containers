# Building the rocm container

This recipe can be built with the following build args 
* `OS_VERSION` (default value is 22.04)
* `LINUX_KERNEL` (default is 5.15.0-91)
*  `ROCM_VERSION` (default is 6.0.2)

This container provides:
* libfabric
* luster
* luster aware mpi build with libfabric
* rocm
* rccl 
* osu microbenchmarks that provide tests for checking the mpi works


