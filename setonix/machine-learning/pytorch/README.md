# PyTorch Container

## Overview

This directory contains the Docker recipe for building a ROCm-enabled PyTorch container for AMD GPUs on Pawsey's Setonix supercomputer.

The container is based on the Pawsey ROCm + MPICH base image and is configured for:

- Ubuntu 24.04
- ROCm 7.2.4
- MPICH 4.2.2
- PyTorch 2.13.0
- AMD `gfx90a` GPUs
- Distributed PyTorch workloads across multiple Setonix GPU nodes

The resulting container is converted to a Singularity SIF image for use on Setonix.

The image includes:

- PyTorch
- PyTorch Vision
- PyTorch Audio
- PyTorch Triton
- Eigen
- JupyterLab

## Build Process

Build the Docker/OCI image using Podman:

```bash
podman build \
    --format=docker \
    -f pytorch.dockerfile \
    -t pytorch2.13.0-rocm7.2.4:latest 
```

Save the container as an OCI archive:

```bash
podman save \
    --format oci-archive \
    pytorch2.13.0-rocm7.2.4:latest \
    -o pytorch2.13.0-rocm7.2.4.tar
```

Load the Singularity module:

```bash
module load singularity/3.11.4-
```

Build the Singularity image:

```bash
singularity build \
    pytorch2.13.0-rocm7.2.4.sif \
    oci-archive://pytorch2.13.0-rocm7.2.4.tar
```

The resulting file is:

```text
pytorch2.13.0-rocm7.2.4.sif
```

## Testing the container

The container is tested by running the test case that is currently in ReFrame on **2 Setonix GPU nodes** with:

```text
8 PyTorch processes per node
2 nodes
20 epochs
batch size 128
```

The following instructions can be used to test the container directly without ReFrame.

```

> cd pawsey-containers/setonix/machine-learning/pytorch/testing

# Copy the SIF image to this location

> sbatch pytorch_check_job.slm
Epoch [20/20], Training Loss: 0.3232, Validation Loss: 0.3181, Validation Accuracy: 0.9616
Model training + validation complete in: 0:00:22.312728

```

