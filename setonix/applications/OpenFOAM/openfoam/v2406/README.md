# OpenFOAM v2406

## General
This repository provides the recipe to build a container image capable of executing OpenFOAM in parallel using the MPI installation (Cray-MPICH) on the Setonix cluster at Pawsey.

Setonix requires Singularity images, and the recipes provided here are in Docker format. Therefore, the process needs two steps: 1) The build of the image in Docker format and 2) The build of the Singularity image from the Docker image created in step 1.

Although the processs in two steps my look counterintuitive, it is still the preferred approach as the Docker builds allow the reuse of layers in the cache which saves a lot of effort during the development process.

### MPI ABI compatibility

This OpenFOAM image is built `FROM` Pawsey's tested based image with MPICH, which allows OpenFOAM to efficiently run in parallel on the Setonix cluster. (Check the Dockerfile for current versions in use for the recipe)

### "Source" files for building the image

To build this image, the following files are needed:
- `openfoam-v2406.dockerfile` (File that contains the recipe)
- (`Dockerfile` (This is just a soft link to the real file that contains the recipe)
- `docker-entrypoint-openfoam-template.sh` (Script to be COPY-ed into the image during the build)
- `singularity-environment-openfoam-template.sh` (Script to be COPY-ed into the image during the build)

The two scripts to be COPY-ed into the image are used for defining the OpenFOAM environment on entry to the container. One works for Docker/Podman the other one works for Singularity. Both are templates as some "tags" in them need to be replaced with the final internal path of the OpenFOAM `bashrc` file defined during build.

### The Dockerfile structure
#### The use of Stages

The Dockerfile for this version of OpenFOAM has a slightly different structure than past recipes. Although the main functionality remains the same as for the previous versions. The main difference for this version is that the Dockerfile is now structured with Stages, which help during the intermediate tests and troubleshooting performed during developement.

The names of the different stages can be seen in all the intermediate `FROM <previousStage> AS <stageName>` instructions within the Dockerfile.

#### The use of gloabl arguments
The Dockerfile for this version of OpenFOAM has another clear change in the use of global arguments. These arguments are defined at the top of the Dockerfile before the first `FROM` instruction. The only caveat is that, to use these global definitions, they need to be re-called with the `ARG` instruction in each of the Stages. So, for example, the global argument defined at the top of the Dockerfile:
```dockerfile
ARG OF_VERSION="v2406"
```
is later re-called in the `download_and_settings` stage with:
```dockerfile
# C. Download OpenFOAM source-files and define settings for installation
FROM install_dependencies AS download_and_settings
#---------------------------------------------------------------
# C.1 Download
# Recall global definitions made on the top
ARG OF_VERSION
```
and then used in the rest of that stage. (Note that no value is provided during the re-calling.)


### Image metadata LABELs information

The Dockerfile includes several metadata `LABEL`s with information about the image. That information can be inspected with:

#### Docker
```bash
docker inspect <dockerImageName>:<imageTag> --format '{{json .Config.Labels}}' | jq .
```

#### Podman
```bash
podman inspect <dockerImageName>:<imageTag> --format '{{json .Config.Labels}}' | jq .
```

#### Singularity
```bash
singularity inspect -l <singularityImage>
```

#### Internal Backup of the Dockerfile
One of the labels indicate that the Dockerfile and all the rest of files used during building are backed up internally within the image in the indicate path:
```json
"org.opencontainers.image.dockerfile-internal-backup": "/opt/docker-recipes"
```

#### Creation date
Creation can also be obtained by inspecting the image metadata:
```bash
docker inspect <dockerImageName>:<imageTag> --format '{{.Created}}'
# OR
podman inspect <dockerImageName>:<imageTag> --format '{{.Created}}'
# OR
singularity inspect -l <singularityImage> | grep build-date
```

## Building

### Pre-building settings

```bash
OF_FORK="openfoam"
OF_VERSION="v2406"
OS_VERSION="24.04"
```

### Building of a specific stage

#### Using Docker

If one specific stage is preferred to be built for testing purposes, this can be done with
```bash
docker build --target basic_stage --progress plain -t ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}-basic_stage -f Dockerfile . |& tee build.log
```

#### Using Podman

```bash
podman build --format=docker --target basic_stage -t ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}-basic_stage -f Dockerfile . |& tee build.log
```

#### Choosing Stages to Build

Building can also aim for only build later stages with "jumping" of intermediate stages. For, example, the `final_settings` stage can be tested by modifying the corresponding instruction to start `FROM` some other early stage and skip intermediate stages. For example:
```dockerfile
FROM basic_stage AS final_settings
```
In that way the image will only contain the first and the last stages for testing purposes.

### Building the whole image

#### Using Docker

```bash
docker build --progress plain -t ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION} -f Dockerfile . |& tee build.log
```

#### Using Podman

```bash
podman build --format=docker -t ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION} -f Dockerfile . |& tee build.log
```

### Creating the Singularity Image

Once a docker image exists, the singularity image can be built from it:

#### When Docker was used for building the docker image

```bash
singularity build ${OF_FORK}_${OF_VERSION}-ubuntu${OS_VERSION}.sif docker-daemon://${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}
```

#### When Podman was used for building the docker image

```bash
podman save --format oci-archive ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION} -o ${OF_FORK}_${OF_VERSION}-ubuntu${OS_VERSION}.tar

singularity build ${OF_FORK}_${OF_VERSION}-ubuntu${OS_VERSION}.sif oci-archive://${OF_FORK}_${OF_VERSION}-ubuntu${OS_VERSION}.tar
```

## Use on Setonix

### Pre-use settings

Load the singularity module with mpi capabilities (adapt the version number to one that is currently available in the system):
```bash
module load singularity/4.1.0-mpi
```

Define the real path of the image to use:
```bash
SINGULARITY_CONTAINER="${MYSOFTWARE}/singularity/images/${OF_FORK}_${OF_VERSION}-ubuntu${OS_VERSION}.sif 
```

NOTE: Pawsey provides many versions of containerised OpenFOAM available as modules on Setonix. When any of those modules is loaded on Setonix, the two steps indicated above are performed automatically as part of the OpenFOAM module loading. Check Pawsey documentation about OpenFOAM use for more information about how to work with those modules.

### Basic commands showing functionality

Testing the recognition of a common solver:
```bash
singularity exec $SINGULARITY_CONTAINER icoFoam -help
```

### Compilation logs
If you observe some OpenFOAM functionality failing, please check the logs of the compilation/installations inside the image. We save a log of the output of the several compilation commands within the image. Check the Dockerfile directly to see their names. These logs can provide some clues if any specific tool was compiled successfully or not.

### Tests included in this repository

Tests are included in the `functionalTests` directory, which has two subdirectories: `tutorialCase` and `compileMyTool`.

The `tutorialCase` subdirectory has scripts that show the whole sequence of execution of a tutorial case. This subdirectory has the following scripts that should be executed in sequence:
1. `extractCase.sh` (normal bash script to be executed on the login node for copying a tutorial case into the host)
2. `preFoam.sh` (slurm job script for preparing the domain decomposition for this case to run in parallel)
3. `runFoam.sh` (slurm job script for executing the case in parallel)

The `compileMyTool` subdirectory has a script that show the whole sequence of developing and compiling user's own tools. The source files and binaries are kept in the host, while compilation and execution happens from inside the container. The subdirectory has the following script:
- `runCompile.sh` (slurm job script that shows the steps for compiling user's own solver)

All these scripts assume that the singularity image to be tested has been moved to the following real path:
`SINGULARITY_CONTAINER="${MYSOFTWARE}/singularity/images/${OF_FORK}_${OF_VERSION}-ubuntu${UBUNTU_VERSION}.sif"`
But that can be adapted to user's wishes.

## Other material in this repository

The `auxiliaryScripts` directory contains a series of scripts that were used during the developement of this recipe. These scripts are not needed for the building of the image, but are kept as a reference that might be useful for future developments.



