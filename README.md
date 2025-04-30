![Pawsey Logo](pawsey-logo-beige.png)

# Pawsey Container Collection

This repository contains a collection of Dockerfiles for container images built and maintained by the Pawsey Supercomputing Research Centre.

## Available Images

Currently, we maintain the following categories of images:

- `mpi/`: Plain and GPU-enabled MPI base images
- `python/`: Python base images with HPC-focused packages
- `OpenFOAM/`: OpenFOAM software for Computational Fluid Dynamics

## Quick Start

Our images are hosted on Quay.io: [https://quay.io/pawsey](https://quay.io/pawsey)

To pull an image using Docker:

```bash
docker pull quay.io/pawsey/<image-name>
```

To pull an image using Podman:

```bash
podman pull quay.io/pawsey/<image-name>
```

To pull an image using Singularity/Apptainer:

```bash
singularity pull docker://quay.io/pawsey/<image-name>
# or using apptainer
apptainer pull docker://quay.io/pawsey/<image-name>
```

## Automation Scripts

We provide automation scripts for building and pushing images:

- `mpi/build_mpi.sh`
- `python/build_python.sh`
- `OpenFOAM/build_openfoam.sh`

### Prerequisites

To use the automation scripts, you'll need:

- Docker or Podman installation
- Quay.io account
- Container registry login:
  - Docker: `docker login quay.io`
  - Podman: `podman login quay.io`
- (Optional) GitHub account for contributing
- (Optional) GitHub authentication setup (e.g., SSH keys)

### Configuration

The first lines of these scripts contain editable variables to determine which images are built. Note that, only in the case of the CUDA-enabled standard Python images (`cuda-hpc-python`), specific Dockerfiles have to be written for each CUDA version.

The scripts also assume that the user has logged in to the relevant container registry to push images and, for `python` only, has GitHub credentials to commit and push changes to this remote project. Interaction with GitHub can be disabled.
