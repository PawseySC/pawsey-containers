# -----------------------------------------------------------------------------
# Disposable OpenFOAM wrapper watchdog test recipe
# -----------------------------------------------------------------------------
# This recipe keeps the global arguments required by openfoamContainerBuild.sh
# for validation and image naming, but it does not install OpenFOAM.
#
# The single RUN instruction prints one line and then remains silent. This lets
# the real wrapper exercise its inactivity watchdog, transient-service cleanup,
# external Buildah-container comparison, and Podman storage verification.
#
# Run this test with --no-cache so Podman cannot reuse a completed test layer.

# --- Image identity
# USER_BUILD_ARG
ARG OF_FORK="openfoam"

# USER_BUILD_ARG
ARG OF_VERSION="v2606"

ARG GCC_VERSION="13"

# --- OpenFOAM settings used in the generated image tag
# USER_BUILD_ARG
ARG WM_LABEL_SIZE="32"

# USER_BUILD_ARG
ARG WM_PRECISION_OPTION="DP"

# USER_BUILD_ARG
ARG WM_COMPILE_OPTION="Opt"

# --- Base-image settings
# USER_BUILD_ARG
ARG BASE_IMAGE_REGISTRY="quay.io/pawsey"

# USER_BUILD_ARG
ARG BASE_IMAGE_NAME="mpich-base"

# USER_BUILD_ARG
ARG BASE_IMAGE_OS_VERSION="24.04"

# USER_BUILD_ARG
ARG BASE_IMAGE_MPICH_VERSION="4.2.2"

ARG BASE_IMAGE_TAG="mpich${BASE_IMAGE_MPICH_VERSION}-ubuntu${BASE_IMAGE_OS_VERSION}"
ARG BASE_IMAGE_FULL="${BASE_IMAGE_REGISTRY}/${BASE_IMAGE_NAME}:${BASE_IMAGE_TAG}"

# --- Silent watchdog test operation
FROM ${BASE_IMAGE_FULL} AS watchdog_test

# Print one progress line, then remain silent for ten minutes. The sleep process
# runs inside Podman's Buildah working container, so watchdog termination tests
# the real container-build cleanup path rather than only a host-side sleep.
RUN echo "Disposable watchdog test started" \
 && sleep 600
