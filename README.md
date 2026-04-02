# pawsey-containers

This repository contains a collection of Dockerfiles for container images built and supported by the Pawsey Supercomputing Research Centre.

## Overview

Dockerfiles are organised by target platform — Setonix and Quantum — with a shared common/ directory for Dockerfiles shared by both.

### Setonix

The following categories of Dockerfiles are maintained for Setonix:
* `mpi/`: plain and GPU-enabled MPI base images
* `applications/`: Dockerfiles for a range of HPC applications, including OpenFOAM, CP2K and NAMD
* `machine-learning/`: Frameworks such as PyTorch and Tensorflow

### Quantum

The following categories of Dockerfiles are maintained inside Quantum:
* `mpi/`: plain and GPU-enabled MPI base images
* `applications/`: Dockerfiles for CUDAQuantum, CUQuantum, PennyLane, Qiskit
* `cuda/`: CUDA-based images, including cuda-lustre-mpich

### Images

Docker images built from these Dockerfiles are published on Quay.io: https://quay.io/pawsey  
