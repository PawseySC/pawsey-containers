# OpenFOAM container recipes

This directory contains Dockerfile recipes and companion files for building OpenFOAM container images for Setonix. The maintained images target `linux/amd64`, the Linux x86-64 platform used by Setonix.

## Repository layout

### `openfoam`

Recipes for the OpenFOAM distribution developed by [ESI-OpenCFD](https://www.openfoam.com/).

| Version | Tag in `quay.io/pawsey/openfoam` | Setonix module | Notes |
|---|---|---|---|
| v2606 | `v2606-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04` | `openfoam-container/v2606` | |
| v2412 | `v2412-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04` | `openfoam-container/v2412` | |
| v2406 | `v2406-gcc9DPInt32Opt-mpich4.2.2-ubuntu24.04` | `openfoam-container/v2406` | |
| v2212 | `v2212-gcc9DPInt32Opt-mpich4.2.2-ubuntu24.04` | `openfoam-container/v2212` | Requires GCC 9 |
| v2206 | `v2206-gcc9DPInt32Opt-mpich4.2.2-ubuntu24.04` | `openfoam-container/v2206` | Requires GCC 9 |
| v2012 | `v2012-gcc9DPInt32Opt-mpich4.2.2-ubuntu24.04` | `openfoam-container/v2012` | Requires GCC 9 |

Older recipes are retained under `legacy/` for reference. They are no longer maintained and may use outdated base images, dependencies, build procedures, or runtime assumptions.

### `openfoam-org`

Recipes for the OpenFOAM distribution developed by [The OpenFOAM Foundation](https://openfoam.org/).

| Version | Tag in `quay.io/pawsey/openfoam-org` | Setonix module | Notes |
|---|---|---|---|
| 14 | `14-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04` | `openfoam-org-container/14` | |
| 12 | `12-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04` | `openfoam-org-container/12` | |
| 10 | `10-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04` | `openfoam-org-container/10` | |

### `openfoamextend`

Recipes for the [foam-extend](https://wikki.co.uk/foam-extend/) distribution developed by Wikki Ltd. This directory does not currently contain a maintained modern recipe.

Files under `legacy/` are retained for reference only.

### `installationsWithAdditionalTools`

Examples of installing additional software on top of Pawsey-provided OpenFOAM images. This directory does not currently contain a maintained modern recipe.

Files under `legacy/` are retained for reference only.

### `pawsey-staff`

Internal scripts used by Pawsey staff to develop, build, test, validate, and deploy OpenFOAM images. These scripts are tailored to Pawsey's operational workflows and are not intended as a general user interface.

## Modern recipe file set

Each maintained recipe version consists of three files that should be kept together:

- `<fork>--<version>.dockerfile`
- `docker-entrypoint-openfoam-template.sh`
- `singularity-environment-openfoam-template.sh`

The Docker entrypoint script loads the OpenFOAM environment and then executes the requested container command with `exec "$@"`.

The Singularity environment script is sourced during container startup. It loads the OpenFOAM environment but deliberately does not execute `"$@"`. This preserves host-supplied environment variables and avoids conflicts with Singularity startup behaviour. Prefer `singularity exec` or `singularity shell`; avoid `singularity run` for these images.

## Building an OpenFOAM version not currently provided

Published Pawsey images are available from `quay.io/pawsey`, and many are also deployed as Setonix modules. Users normally do not need to rebuild an already published image. A common use case is creating an image for an OpenFOAM version that Pawsey does not currently provide.

The example below proposes the needed steps for an ESI-OpenCFD OpenFOAM v1912 recipe by adapting the maintained v2012 recipe.

### 1. Clone the repository

```bash
git clone https://github.com/PawseySC/pawsey-containers.git
cd pawsey-containers/setonix/applications/OpenFOAM
```

### 2. Select the closest maintained recipe

Choose a maintained recipe from the same OpenFOAM distribution and as close as practical to the required version.

In general, older OpenFOAM versions are more difficult to build on current Linux distributions. The main challenge is usually not OpenFOAM itself, but providing sufficiently old and mutually compatible compilers, system packages, ThirdParty libraries, and other build dependencies. For example, the older `openfoam/v*` releases that we maintain already require an older GCC version to compile successfully.

Using an equally old Ubuntu base image is not necessarily a suitable solution. The image must remain compatible with the current Setonix container environment, Pawsey's MPICH integration, host-provided runtime libraries, and supported software stack. Older Ubuntu releases may also be unsupported and no longer receive security updates. Consequently, an old OpenFOAM release may need to be adapted to build with an older compiler and dependencies installed on a current, supported Ubuntu base image.

The further the target OpenFOAM version is from the selected maintained recipe, the more compiler, dependency, and source-compatibility changes are likely to be required.

For this example, v2012 is the closest maintained recipe to v1912 and provides the most appropriate starting point. Copy the complete v2012 recipe directory to a new directory for v1912:

```bash
cd openfoam
cp -a v2012 v1912
```

### 3. Rename the Dockerfile

```bash
cd v1912
mv openfoam--v2012.dockerfile openfoam--v1912.dockerfile
```

Keep the renamed Dockerfile and the two companion template scripts together in the version directory.

### 4. Update the recipe

At minimum, update the OpenFOAM version argument:

```dockerfile
ARG OF_VERSION="v1912"
```

This change alone may not be sufficient. Depending on the selected OpenFOAM release, also review:

- `GCC_VERSION`;
- packages installed in the `install_dependencies` stage;
- the source-download method in the `download` stage;
- compatibility changes in the `update_settings` stage;
- ThirdParty and ParaView version requirements;
- compiler, MPI, precision, label-size, and base-image compatibility.

Start with the smallest justified change when the required differences are unknown. Build failures and authoritative compilation logs can then identify the next compatibility issue to address.

### 5. Build and troubleshoot the image

#### 5.1 Build the image and save the complete output

Run the build from the version directory so that the Dockerfile and both companion scripts are included in the build context. Modern Docker uses BuildKit's compact interactive progress display by default. Use `--progress=plain` to print the output from each build step as sequential text, and use `tee` to display and save the combined standard output and standard error:

```bash
docker build \
    --progress=plain \
    --platform linux/amd64 \
    --tag "openfoam:v1912-my-build" \
    --file openfoam--v1912.dockerfile \
    . 2>&1 | tee "openfoam-v1912-build.log"
```

The final `.` selects the current directory as the Docker build context. The Setonix images target `linux/amd64`; this workflow does not currently support cross-platform OpenFOAM builds.

The plain-progress log is the first place to investigate a failed build. The end of the log normally identifies the Dockerfile instruction that failed:

```bash
tail -n 200 openfoam-v1912-build.log
```

A first-pass error search can also help locate compiler, linker, dependency, and filesystem failures:

```bash
grep -nEi -C 10 \
    'error:|fatal:|undefined reference|no such file|not found|failed|cannot|could not' \
    openfoam-v1912-build.log
```

The search is only a diagnostic aid. Review the surrounding build output because not every occurrence of words such as `failed` or `error` represents the final cause.

As this is a modified recipe for a new version, the build may fail at different points. When a failure occurs, investigate it, update the recipe, and build again. Docker can reuse cached results for unchanged instructions whose relevant inputs still match, so subsequent attempts normally continue from the first instruction whose cache is unavailable or invalidated.

(If testing the build of a published unmodified recipe, it should build without errors. If a maintained recipe fails, contact the [Pawsey Helpdesk](https://support.pawsey.org.au/)).

#### 5.2 Inspect preliminary compilation logs from a cached checkpoint

Our modern-style recipes perform preliminary compilation passes before the authoritative ThirdParty, ParaView, and OpenFOAM passes. Preliminary failures are tolerated so that partial compilation products and logs can be retained for the later passes.

A failure in an authoritative pass stops the Docker build. With modern BuildKit, the cache hashes shown during the build are not normally runnable image IDs. To inspect the state produced by the preliminary passes, the development Dockerfile must expose a named checkpoint stage **after the preliminary passes and immediately before the authoritative pass**.

To make this diagnostic workflow possible, temporarily add named checkpoint stages to the recipe. The checkpoint names should clearly identify the corresponding component. For example:

```text
third_party_preliminary
pv_preliminary
of_preliminary
```

Apply the following pattern to the component whose authoritative compilation pass is failing. For example, for an OpenFOAM compilation failure:

```dockerfile
FROM pv_install AS of_preliminary

# Existing preliminary OpenFOAM compilation passes

FROM of_preliminary AS of_install

# Existing authoritative OpenFOAM compilation pass
```

The checkpoint must be after the preliminary passes. A checkpoint before them would not contain their compilation logs.

After an authoritative pass fails, identify the affected component from `openfoam-v1912-build.log`, then materialise the corresponding cached checkpoint as a normal tagged image. For an OpenFOAM compilation failure:

```bash
docker build \
    --progress=plain \
    --platform linux/amd64 \
    --target of_preliminary \
    --tag "openfoam:v1912-openfoam-debug" \
    --file openfoam--v1912.dockerfile \
    .
```

Docker should reuse the cached preliminary stage when its Dockerfile instructions and inputs have not changed. Use `third_party_preliminary` or `pv_preliminary` instead when the failure came from the ThirdParty or ParaView authoritative pass.

Open a shell in the checkpoint image:

```bash
docker run \
    --rm \
    --interactive \
    --tty \
    --entrypoint /bin/bash \
    "openfoam:v1912-openfoam-debug"
```

The checkpoint precedes the `final_settings` stage, where the final Docker entrypoint is installed and configured. Therefore, opening the checkpoint with `/bin/bash` does not automatically load the OpenFOAM environment. Source the known OpenFOAM bashrc explicitly:

```bash
source /opt/OpenFOAM/OpenFOAM-v1912/etc/bashrc
```

Confirm that the expected environment is loaded:

```bash
printf 'WM_THIRD_PARTY_DIR=%s\n' "$WM_THIRD_PARTY_DIR"
printf 'WM_PROJECT_DIR=%s\n' "$WM_PROJECT_DIR"
printf 'WM_OPTIONS=%s\n' "$WM_OPTIONS"
```

Before interpreting the compilation logs, verify that the checkpoint contains the configuration changes made by the recipe. The image does not include `less`, so use `vi` for inspection:

```bash
vi /opt/OpenFOAM/OpenFOAM-v1912/etc/bashrc
vi /opt/OpenFOAM/OpenFOAM-v1912/etc/prefs.sh
vi /opt/OpenFOAM/OpenFOAM-v1912/etc/controlDict
```

In `vi`, use `/pattern` to search, `n` to move to the next match, and `:q` to exit. Use `:q!` to exit without saving if the file was modified accidentally.

These files should contain the environment, compiler, MPI, precision, label-size, and global OpenFOAM settings intended by the recipe. If the expected modifications are absent or incorrect, the compilation logs may reflect a misconfigured build environment rather than an OpenFOAM source-compatibility problem.

Locate the build logs available in the checkpoint instead of assuming that every OpenFOAM version uses exactly the same filenames. For the component being diagnosed, the checkpoint contains its preliminary-pass logs but not the log from the later failed authoritative pass:

```bash
find "$WM_THIRD_PARTY_DIR" \
    -maxdepth 2 \
    -type f \
    \( -name 'log.Allwmake*' -o -name 'log.makePV*' \) \
    -print

find "$WM_PROJECT_DIR" \
    -maxdepth 1 \
    -type f \
    -name 'log.Allwmake*' \
    -print
```

Inspect the relevant files with `vi`, `tail`, or `grep`. For example:

```bash
vi "$WM_PROJECT_DIR/log.Allwmake.pass-1-tasks-16"
```

The exact filename can differ between recipe versions and passes, so use the preceding `find` commands first.

If you prefer to inspect a file outside the checkpoint image, where more viewing and editing tools are available, create a stopped container from the checkpoint image:

```bash
checkpointContainer=$(
    docker create \
        --entrypoint /bin/true \
        "openfoam:v1912-openfoam-debug"
)
```

For example, copy one preliminary OpenFOAM compilation log to the current host directory:

```bash
docker cp \
    "${checkpointContainer}:/opt/OpenFOAM/OpenFOAM-v1912/log.Allwmake.pass-1-tasks-16" \
    .
```

Use the preceding `find` commands to identify the actual log filename before running `docker cp`. When the required file has been copied, remove the stopped container:

```bash
docker rm "$checkpointContainer"
```

The host-side `openfoam-v1912-build.log` contains the output from the failed authoritative Docker build step. The checkpoint image instead contains the preliminary logs, partial compilation products, and filesystem state produced before that authoritative pass. For example, an `of_preliminary` checkpoint can contain OpenFOAM preliminary-pass logs and the completed ThirdParty and ParaView authoritative logs, but it cannot contain the later failed OpenFOAM authoritative-pass log created in `of_install`.

A checkpoint can be materialised only when its preliminary `RUN` instruction returns a successful shell status. Individual preliminary compilation passes may still have failed internally because the recipe deliberately records those failures without terminating the `RUN` instruction. If the preliminary and authoritative work are kept in the same failing `RUN` instruction, Docker cannot expose the preliminary filesystem state as a normal image. Separating the checkpoint and authoritative stages is therefore required for this workflow.

### 6. Test the completed image

When the complete image builds successfully, run a basic OpenFOAM command to confirm that Docker can start the image, the entrypoint loads the OpenFOAM environment, and an installed solver is available through `PATH`:

```bash
docker run \
    --rm \
    "openfoam:v1912-my-build" \
    pimpleFoam -help
```

This test is non-interactive, so `--interactive` and `--tty` are not required. The command should print the `pimpleFoam` usage information and exit successfully.

### 7. Tag and push the image

Tag the image for a registry that you can access from Setonix:

```bash
docker tag \
    openfoam:v1912-my-build \
    my-registry.example/openfoam:v1912-my-build
```

Push the image:

```bash
docker push my-registry.example/openfoam:v1912-my-build
```

If, instead of the shorter example tag, you prefer to follow Pawsey’s image-tag convention, tags used by Pawsey are generated from the principal build settings:

```text
${OF_VERSION}-gcc${GCC_VERSION}${WM_PRECISION_OPTION}Int${WM_LABEL_SIZE}${WM_COMPILE_OPTION}-mpich${BASE_IMAGE_MPICH_VERSION}-ubuntu${BASE_IMAGE_OS_VERSION}
```

For example:

```text
v2606-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04
```

### 8. Pull and use the image on Setonix

The Pawsey documentation page [OpenFOAM: Advanced use of containerised modules and external containers](https://pawsey.atlassian.net/wiki/spaces/US/pages/51925448/OpenFOAM+Advanced+use+of+containerised+modules+and+external+containers) explains how to use an OpenFOAM version that Pawsey does not provide as a module.

## How the modern recipes work

### Multi-stage Dockerfile structure

The current recipes use a multi-stage build. For example, the maintained v2606 recipe contains these stages:

1. `basic_stage`
2. `install_dependencies`
3. `download`
4. `update_settings`
5. `third_party_install`
6. `pv_install`
7. `of_install`
8. `final_settings`

Each stage begins with a `FROM ... AS ...` instruction. During recipe development, Docker's `--target <stage>` option can stop the build after a selected stage. A developer can also temporarily change a later stage's `FROM` source to test selected build logic while bypassing intermediate stages. Such temporary edits should not be committed as production recipe changes.

### Global build arguments

The recipes declare global `ARG` instructions before the first `FROM`. Global arguments can be used in `FROM` instructions. To use one inside a build stage, the stage recalls it with `ARG NAME`, which makes the supplied or default value available in that stage.

Only global arguments marked `USER_BUILD_ARG` are supported command-line overrides. Other global arguments are fixed recipe settings and should not normally be overridden with `--build-arg`.

The current recipes derive from Pawsey's MPICH base image, for example:

```text
quay.io/pawsey/mpich-base:mpich4.2.2-ubuntu24.04
```

This MPICH-compatible base supports integration with the MPI runtime and high-performance interconnect configuration provided on Setonix.

### Preliminary and authoritative compilation passes

The ThirdParty, ParaView, and OpenFOAM build stages use preliminary compilation passes followed by an authoritative pass:

- Preliminary-pass failures are recorded but do not immediately stop the image build. Partial build products are retained so that a later pass can complete work affected by parallel-build race conditions.
- A successful preliminary pass creates a component-specific sentinel file, allowing later preliminary passes for that component to be skipped.
- The final authoritative pass always runs. Because shell pipeline failures are propagated, a failure in the authoritative pass stops the image build.
- Each authoritative pass produces the summary log used by the validation workflow.

This strategy addresses intermittent dependency-ordering and parallel-compilation issues while ensuring that the final image is accepted only after a successful authoritative build.

### Docker and Singularity startup integration

During `final_settings`, the recipe installs the Docker entrypoint and Singularity environment scripts after replacing the bashrc template marker with the correct OpenFOAM bashrc path.

The scripts deliberately have different final behaviour:

- Docker loads the OpenFOAM environment and then executes the requested command.
- Singularity loads the OpenFOAM environment without executing the container arguments, preserving host-provided variables such as `FOAM_IORANKS`.

### Embedded provenance and build settings

The recipe copies the Dockerfile and companion scripts into the image under the build-information directory, currently based on:

```dockerfile
ARG IMAGE_BUILD_INFO_DIR="/opt/build-info-and-recipes"
```

It also records the resolved global build arguments used for the image. This is important because supported `USER_BUILD_ARG` values can be changed from the command line and Docker does not otherwise retain the complete source recipe as a clearly accessible file inside the image.

The final image also includes OCI and Pawsey-specific labels describing the OpenFOAM version, compiler, precision, label size, MPI base, operating-system base, and build-information location.

## Further documentation

- [OpenFOAM: Advanced use of containerised modules and external containers](https://pawsey.atlassian.net/wiki/spaces/US/pages/51925448/OpenFOAM+Advanced+use+of+containerised+modules+and+external+containers)
- [Containers at Pawsey with Singularity](https://pawseysc.github.io/singularity-containers/) training material
- [Pawsey Helpdesk](https://support.pawsey.org.au/)

For general Docker and Singularity usage, also consult the official documentation for the container engine installed in your environment.
