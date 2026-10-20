# TensorFlow Container

## Overview

This directory contains the Docker recipe for building a ROCm-enabled TensorFlow container for AMD GPUs on Pawsey's Setonix supercomputer.

The container is based on the Pawsey ROCm + MPICH base image and is configured for:

- Ubuntu 24.04
- ROCm 7.2.4
- MPICH 4.2.2
- TensorFlow 2.21.0 by default
- AMD `gfx90a` GPUs, including the AMD Instinct MI250X GPUs on Setonix

This builds Horovod with ROCm/RCCL support for Tensorflow 2.15.x versions. The Dockerfile includes Python configuration for the TensorFlow releases supported by this recipe: Python 3.12 for TensorFlow 2.21.x and Python 3.10 for the legacy TensorFlow 2.15.x configuration.

The resulting OCI image can be converted to a Singularity/Apptainer SIF image for execution on Setonix.

## Main components

- TensorFlow with ROCm support
- Horovod with ROCm/RCCL support for Tensorflow 2.15.x versions
- ROCm runtime and libraries supplied by the Pawsey ROCm + MPICH base image
- MPICH for MPI integration
- Python and pip dependencies required by the selected TensorFlow version

## Build process

Run the following commands from this directory:

```bash
cd setonix/machine-learning/tensorflow
```

Build the Docker/OCI image using Podman:

```bash
podman build \
    --format=docker \
    -f tensorflow.dockerfile \
    -t tensorflow-2.21.0-rocm7.2.4:latest 
```

Save the container as an OCI archive:

```bash
podman save \
    --format oci-archive \
    tensorflow-2.21.0-rocm7.2.4:latest \
    -o tensorflow-2.21.0-rocm7.2.4.tar
```

Load the Singularity module available in your Setonix environment, then build the SIF image from the OCI archive:

```bash
module load singularity/4.3.5-nompi

singularity build \
    tensorflow-2.21.0-rocm7.2.4.sif \
    oci-archive://tensorflow-2.21.0-rocm7.2.4.tar
```

The resulting image is:

```text
tensorflow-2.21.0-rocm7.2.4.sif
```

## Test the container

First, check that TensorFlow imports and reports its version:

```bash
singularity exec tensorflow-2.21.0-rocm7.2.4.sif     python3 -c 'import tensorflow as tf; print(tf.__version__)'
2.21.0-dev0+selfbuilt

```

The container is tested by running the test case that is currently in ReFrame on 4 GPUs. The following instructions can be used to test the container directly without ReFrame.

```
> cd pawsey-containers/setonix/machine-learning/tensorflow/testing

# Copy the SIF image to this location

> sbatch tensorflow_gpu_check_job.sh
117/117 ━━━━━━━━━━━━━━━━━━━━ 2s 19ms/step - accuracy: 0.9904 - loss: 0.0297 - val_accuracy: 0.9910 - val_loss: 0.0277
Model finished training and validation
```

