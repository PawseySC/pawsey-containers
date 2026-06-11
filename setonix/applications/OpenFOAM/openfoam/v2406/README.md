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
- `Dockerfile` (This is just a soft link to the real file that contains the recipe)
- `docker-entrypoint-openfoam-template.sh` (Script to be COPY-ed into the image during the build)
- `singularity-environment-openfoam-template.sh` (Script to be COPY-ed into the image during the build)

The two scripts to be COPY-ed into the image are used for defining the OpenFOAM environment on entry to the container. One works for Docker/Podman, and the other works for Singularity. Both are templates; therefore, some "tags" in them are replaced during build with correct path of the OpenFOAM `bashrc` file defined in the image.

### The Dockerfile structure
#### The use of Stages

The Dockerfile for this version of OpenFOAM has a slightly different structure than past recipes. Although the main functionality remains the same as for the previous versions. The main difference for this version is that the Dockerfile is now structured with Stages, which help during the intermediate tests and troubleshooting performed during developement.

The names of the different stages can be seen in all the intermediate `FROM <previousStage> AS <stageName>` instructions within the Dockerfile.

#### The use of gloabl arguments
The Dockerfile for this version of OpenFOAM has another clear change with respect to previous versions which is the use of global arguments. These arguments are defined at the top of the Dockerfile before the first `FROM` instruction. The only caveat is that, to use these global definitions, they need to be recalled with the `ARG` instruction in each of the Stages where its value is needed. For example, the global argument defined at the top of the Dockerfile:
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
making its already defined value available for rest of that stage. (Note that assignment is performed during the recall.)


### Image metadata LABELs information

The Dockerfile includes several metadata `LABEL`s with information about the image. That information can be inspected with:

#### Docker
```bash
docker inspect <imageName>:<imageTag> --format '{{json .Config.Labels}}' | jq .
```

#### Or Podman
```bash
podman inspect <imageName>:<imageTag> --format '{{json .Config.Labels}}' | jq .
```

#### Or Singularity
```bash
singularity inspect -l <singularityImage>
```

#### Internal Backup of the Dockerfile
One of the labels indicate that the Dockerfile and all the rest of the files used during building are backed up internally within the image in the path indicated by the label:
```json
"org.opencontainers.image.dockerfile-internal-backup"
```

#### Creation date
Creation date is not defined in the labels, but can be obtained by inspecting the image metadata:
```bash
docker inspect <imageName>:<imageTag> --format '{{.Created}}'
# OR
podman inspect <imageName>:<imageTag> --format '{{.Created}}'
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

### Building the whole image

#### 1st Building-Step: building the image in Docker format

##### Using Docker Engine

```bash
docker build --progress plain -t ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION} -f Dockerfile . |& tee build.log
```

##### Or Using Podman Engine

```bash
podman build --format=docker -t ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION} -f Dockerfile . |& tee build.log
```

#### 2nd Building-Step: building the image in Singularity format

Once an image in docker format exists in the local engine registry, the singularity image can be built from it:

##### When Docker engine was used in previous step

```bash
singularity build ${OF_FORK}_${OF_VERSION}-ubuntu${OS_VERSION}.sif docker-daemon://${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}
```

##### Or When Podman engine was used in previous step

```bash
podman save --format oci-archive ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION} -o ${OF_FORK}_${OF_VERSION}-ubuntu${OS_VERSION}.tar

singularity build ${OF_FORK}_${OF_VERSION}-ubuntu${OS_VERSION}.sif oci-archive://${OF_FORK}_${OF_VERSION}-ubuntu${OS_VERSION}.tar
```

##### Or When the image in docker format is already in an online registry
If the image in docker format was pushed to an online registry after the 1st building step, that image can be used for building the singularity image (it does not matter what local engine was used for the build):
```bash 
singularity build ${OF_FORK}_${OF_VERSION}-ubuntu${OS_VERSION}.sif docker://<repositoryName>/${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}
```

#### Using scripts in `buildingScripts` directory

Some scripts for simplifying the building process are provided in the `buildingScripts` directory. These scripts read the Dockerfile and defines the `OF_FORK`, `OF_VERSION` and `OS_VERSION` from the internal settings. Then build the image with the correct naming. They also perform some checks of the build and of the log files left inside the image after the compilation of the different tools.

##### Script for 1st building step from Dockerfile

From the `buildingScripts` directory use, for example:
```bash
./containerBuild.sh --engine podman
```
Where `--engine` option means the "local engine to use for building the image in docker format". The script also creates a `./tmp` directory to store logs and temporary files. Check the script for additional functionality.

##### Script for 2nd building step to create the Singularity image

From the `buildingScripts` directory use, for example:
```bash
./singularityBuild.sh --engine podman
```
Where `--engine` option means the "local engine that used to build the image in docker format". The script also creates a `./tmp` directory to store logs and temporary files. Check the script for additional functionality.

IMPORTANT: The script saves the singularity image into:
- `${MYSCRATCH}/singularity/images/${imageName}_${imageTag}.sif`

or

- `${HOME}/singularity/images/${imageName}_${imageTag}.sif`

##### When the image in docker format is already in an online registry

From the `buildingScripts` directory use the following option:
```bash
./singularityBuild.sh --fromRegistryImage docker://<repositoryName>/${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}
```
The script also creates a `./tmp` directory to store logs and temporary files. Check the script for additional functionality.

#### Basic Testing

We recommend to test basic functionality after each of the building steps. If succeeded, then proceed to test proper execution of OpenFOAM solvers and compilation of user's own tool. For that check the "Use on Setonix" section.

###### Testing the image in Docker format using the local engine

- A. Test the recognition of the OpenFOAM environment variables: For example, when the local engine is `docker`:
```bash
docker run --rm ${FORK}:${OF_VERSION}-ubuntu${OS_VERSION} bash -c 'echo FOAM_ETC=$FOAM_ETC'
```

- B. Test the basic call of the `-help` of an OpenFOAM tool. For example, when the local engine is `podman` :
```bash
podman run --rm ${FORK}:${OF_VERSION}-ubuntu${OS_VERSION} icoFoam -help
```

###### Testing the image in Singularity format

Same basic tests are recommended for the singularity image:
```bash
singularity exec ${FORK}:${OF_VERSION}-ubuntu${OS_VERSION}.sif bash -c 'echo FOAM_ETC=$FOAM_ETC'

singularity exec ${FORK}:${OF_VERSION}-ubuntu${OS_VERSION}.sif icoFoam -help
```

###### Basic testing script

The script `functionalTests/basic/basicTests.sh` performs two tests: 1) reconginsing of the OpenFOAM environment variables, and 2) basic call of an OpenFOAM tool help.

After the 1st step of building, the script can be used to perform basic testing on the image in docker format. For example, when `podman` is the local buildind engine:
```bash
./basicTests.sh --engine podman ${imageName}:${imageTag}
```

And, after the 2nd step of building, the script can be used to perform basic testing on the singularity image:
```bash
./basicTests.sh --engine singularity ${singularityImage}
```

#### Execution testing

See "Use on Setonix" section

## Use on Setonix

NOTE: Current explantion is for a first time created image, or for images with OpenFOAM versions that are not deployed as modules in Pawsey clusters. For the use of OpenFOAM modules already deployed, please check Pawsey Supercomputing Centre documentation.

### Pre-use settings
Load the singularity module with mpi capabilities (adapt the version number to one that is currently available in the system):
```bash
module load singularity/4.1.0-mpi
```

Define the real path of the image to use:
```bash
SINGULARITY_CONTAINER="realpath/to/singularityImage.sif"
```
(Variable name `SINGULARITY_CONTAINER` is to be consistent with the naming used in OpenFOAM modules currently deployed in Pawsey clusters)

### Basic commands showing functionality

Testing the recognition of environment and solvers. For example:
```bash
singularity exec $SINGULARITY_CONTAINER bash -c 'echo FOAM_ETC=$FOAM_ETC'
singularity exec $SINGULARITY_CONTAINER icoFoam -help
```

### Tests included in this repository

Higher level tests are included in the `functionalTests/setonix` directory, which has two subdirectories: `tutorialCase` and `compileMyTool`.

The `tutorialCase` subdirectory has scripts that show the whole sequence of execution of a tutorial case. This subdirectory has the following scripts that should be executed in sequence:
1. `extractCase.sh` (normal bash script to be executed on the login node for copying a tutorial case into the host)
2. `preFoam.sh` (slurm job script for preparing the domain decomposition for this case to run in parallel)
3. `runFoam.sh` (slurm job script for executing the case in parallel)

The `compileMyTool` subdirectory has a script that show the whole sequence of developing and compiling user's own tools. The source files and binaries are kept in the host, while compilation and execution happens from inside the container. The subdirectory has the following script:
- `runCompile.sh` (slurm job script that shows the steps for compiling user's own solver)

All these scripts assume that the singularity image to be tested has been moved to the temporary realpath:
`SINGULARITY_CONTAINER="${MYSCRATCH}/singularity/images/${OF_FORK}_${OF_VERSION}-ubuntu${UBUNTU_VERSION}.sif"`
(Once the image has proven to work properly, we recommend to move the image to a more permanent correct directory.)

## For developers

### Building up to a specific stage

When developing an image, it may be useful to be build only up to one stage and not the whole image. This can be done with:

#### Using Docker (1st step)
```bash
docker build --target basic_stage --progress plain -t ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}-basic_stage -f Dockerfile . |& tee build.log
```

#### Or Using Podman (1st step)
```bash
podman build --format=docker --target basic_stage -t ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}-basic_stage -f Dockerfile . |& tee build.log
```

#### Using Singularity (2nd step)
Same command(s) as for the whole image but building from `${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}-basic_stage` docker image in the local engine registry.

#### Using the building scripts (1st and 2nd steps)
```bash
./containerBuild.sh --engine <localEngineName> --target basic_stage
```
The script adds automatically the `-basic_stage` suffix to the imageTag.

Then:
```bash 
./singularityBuild.sh --engine <localEngineName> ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}-basic_stage
```
Note that the `imageName:imageTag` needs to be provided to the `singularityBuild.sh` script as a final argument, otherwise it will try to build from the default image (which is the full image).

### Choosing Stages to Build

When developing an image, it may be useful to build an early stage and a later stage but "jumping" intermediate stages. For, example, the `final_settings` stage can be built from the `basic_stage` jumping all the intermediate stages. To do that, the corresponding `FROM` instruction in the Dockerfile should be modified to:
```dockerfile
FROM basic_stage AS final_settings
```
In that way the image will only contain the first and the last stages for testing purposes.

#### Using podman (1st Step)
Then use, for example:
```bash
podman build --format=docker --target final_settings -t ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}-final_settings-from-basic_stage -f Dockerfile . |& tee build.log
```

#### Using singularity (2nd Step)
Same command(s) as for the whole image but building from `${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}-basic_stage` docker image in the local engine registry.

#### Using the building scripts (1st and 2nd steps)
```bash
./containerBuild.sh --engine <localEngineName> --target final_settings --targetFrom basic_stage
```
The script adds automatically the `-final_settings-from-basic_stage` suffix to the imageTag.

Then:
```bash 
./singularityBuild.sh --engine <localEngineName> ${OF_FORK}:${OF_VERSION}-ubuntu${OS_VERSION}-final_settings-from-basic_stage
```
Note that the `imageName:imageTag` needs to be provided to the `singularityBuild.sh` script as a final argument, otherwise it will try to build from the default image (which is the full image).

### Other material in this repository

The `auxiliaryScripts` directory contains a series of scripts that were used during the developement of this recipe. These scripts are not needed for the building of the image, but are kept as a reference that might be useful for future developments.