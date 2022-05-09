# pawsey-containers

This is a collection of Dockerfiles (and Singularity deffiles) for container images built and supported by the Pawsey Supercomputing Centre.  

Currently, the following categories of images are maintained:
* `mpi/`: plain and GPU-enabled MPI base images
* `python/`: Python base images featuring a collection of HPC packages
* `OpenFOAM/`: OpenFOAM software for Computational Fluid Dynamics

Some experimental scripts are provided, to automate image build and push:
* `mpi/build_mpi.sh`
* `python/build_python.sh`
* `OpenFOAM/build_openfoam.sh`

The first lines of these scripts contain editable variables, to determine which images are built.  Note that, only in the case of the CUDA-enabled standard Python images, `cuda-hpc-python` images, specific Dockerfile have to be written for each CUDA version.  
The scripts also assume that the user has logged in to the relevant container registry to push images and, for `python` only, has GitHub credentials to commit and push changes to this remote project.  Interaction with GitHub can be disabled.  
The requirements to use the automation scripts can be summarised as follows:
* a `docker` installation
* a free account on <quay.io>
* Docker login via `docker login quay.io` (one-off)
* (optional) a free account on a Git remote host repository
* (optional) GitHub authentication to avoid password/passphrase requests for push commands (*e.g.* using SSH keys)


Quay.io image repository: https://quay.io/pawsey  
