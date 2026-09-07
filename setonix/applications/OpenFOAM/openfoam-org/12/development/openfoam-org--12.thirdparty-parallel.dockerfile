#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition of global parameters
# IMPORTANT: All these settings can be overriden with the use of `--build-arg <Name>=<Value>`
# IMPORTANT: Recipe needs to re-call them at each stage to recover their values
# IMPORTANT: Developers should check that ALL the ARG definitions here are recalled in the "recording_arguments" section of the final stage.
# 0.1 Main global arguments (related to the OpenFOAM version)
ARG OF_FORK="openfoam-org"
ARG OF_VERSION="12"

# 0.1 Main arguments related to the base container to use
# Defining the base container to use
# IMPORTANT: Setonix mpi containers need at least ubuntu24.04 (From August 2025)
ARG BASE_IMAGE_REGISTRY="quay.io/pawsey"
ARG BASE_IMAGE_NAME="mpich-base"
ARG BASE_IMAGE_OS_VERSION="24.04"
ARG BASE_IMAGE_MPICH_VERSION="4.2.2"
ARG BASE_IMAGE_TAG="mpich${BASE_IMAGE_MPICH_VERSION}-ubuntu${BASE_IMAGE_OS_VERSION}"
ARG BASE_IMAGE_FULL="${BASE_IMAGE_REGISTRY}/${BASE_IMAGE_NAME}:${BASE_IMAGE_TAG}"

#---------------------------------------------------------------
# 0.2 Auxiliary global arguments of definitions used in multiple stages
ARG OF_INSTALL_DIR="/opt/OpenFOAM"
ARG OF_USER="ofuser"
ARG OF_USER_DIR="/home/${OF_USER}/OpenFOAM/${OF_USER}-${OF_VERSION}"
ARG OF_BASHRC_FILE="${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/bashrc"

# 0.3 Other auxiliary variables
ARG BUILD_FILES_DIR="/opt/build-information-and-recipes"


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# A. Basic Stage.
FROM $BASE_IMAGE_FULL AS basic_stage
#---------------------------------------------------------------
# A.1 Installing additional tools useful for interactive sessions,
#     downloading and other checks
 RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq \
 &&  apt-get -y --no-install-recommends install \
            vim time \
            cron gosu \
            bc curl wget \
# cleaning at the end:
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

### Use the following block anywher in the script during developing whenever the tools are needed
##RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq \
## &&  apt-get -y --no-install-recommends install \
##            git \ #For git pulling capabilities
##            devscripts \ #For installing the checkbashisms tool
### cleaning at the end:
## && apt-get clean all \
## && rm -r /var/lib/apt/lists/*

#---------------------------------------------------------------
# A.2 Setting a user for interactive sessions and development of own tools
# Recent native developers' containers are not using this "ofuser" anymore, although it is still useful to have it for Pawsey purposes.
# Then, some directory within a Pawsey cluster file system could be mounted to WM_PROJECT_USER_DIR path and
#  perform interactive testing or development of own tools.
# (WM_PROJECT_USER_DIR is set to OF_USER_DIR in the `bashrc` file in the `update_settings` stage below.)
# Recall global definitions made at the top:
ARG OF_USER
ARG OF_USER_DIR
# Creating the ofuser
RUN groupadd -g 10001 $OF_USER \
 && useradd -m -u 10001 -g $OF_USER $OF_USER
# Creating its OpenFOAM working directory and changing owner and permissions in its home tree
RUN mkdir -p ${OF_USER_DIR} \
 && chown -R $OF_USER:$OF_USER /home/${OF_USER}


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# B. Install dependencies
FROM basic_stage AS install_dependencies
#---------------------------------------------------------------
# B.1 Install OpenFOAM dependencies
# Will follow PARTIALLY the official installation instructions:
# [1] https://openfoam.org/download/source/
#
# Will follow PARTIALLY the latest instructions available in the wiki:
# [2] https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-7/Ubuntu/18.04
# [3] https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-8
#
# Then, will follow a combination of both.
# The package selection below is preserved from the original OpenFOAM 12 recipe
# because it defines the dependencies intended for this specific OpenFOAM version.
# A warning may appear:
# debconf: delaying package configuration, since apt-utils is not installed
# But seems to be a bug:
# [4] https://github.com/phusion/baseimage-docker/issues/319
# But harmless.
RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq \
 && apt-get --no-install-recommends --no-install-suggests --yes install \
    # As indicated in the official documentation:
    # Tools for repositories and compilation:
    build-essential cmake git ca-certificates flex \
    # Tools for ThirdParty:
    # paraview-dev is installed in the ParaView stage below. \
    # Tools in the openfoam-nopv-deps list (not repeating ones already included):
    # No OpenMPI because MPICH will be used (installed in the parent FROM image): \
    # libopenmpi-dev \
    zlib1g-dev gnuplot gnuplot-x11 libxt-dev \
    # Tools in the openfoam-deps list (not repeating ones already included):
    libxml2-dev libhdf5-dev libavfilter-dev libtheora-dev libgl2ps-dev \
    libx11-dev libqt5x11extras5-dev libglew-dev libutfcpp-dev \
    libdouble-conversion-dev libfreetype-dev libqt5svg5-dev \
    qtxmlpatterns5-dev-tools qttools5-dev python3-dev \
    libadios2-serial-c-dev libadios2-serial-c++11-dev \
    # Tools not officially listed, but needed in the past:
    libfl-dev bison libboost-system-dev libboost-thread-dev \
    libreadline-dev libncurses-dev \
    # Expanded set of Qt5 libraries suggested for older OpenFOAM versions:
    # qt5-default \
    # qtbase5-dev qttools5-dev qttools5-dev-tools qtchooser qt5-qmake qtbase5-dev-tools libqt5opengl5-dev libqt5x11extras5-dev libxt-dev \
# cleaning at the end:
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# C. Download OpenFOAM source-files
FROM install_dependencies AS download
#---------------------------------------------------------------
# C.1 Download
# Recall global definitions made at the top
ARG OF_VERSION
ARG OF_INSTALL_DIR
#Change to the installation dir, clone OpenFOAM directories
WORKDIR $OF_INSTALL_DIR
RUN git clone https://github.com/OpenFOAM/OpenFOAM-${OF_VERSION}.git
RUN git clone https://github.com/OpenFOAM/ThirdParty-${OF_VERSION}.git
##RUN git clone git://github.com/OpenFOAM/OpenFOAM-${OF_VERSION}.git
##RUN git clone git://github.com/OpenFOAM/ThirdParty-${OF_VERSION}.git


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# D. Update OpenFOAM settings pre-installation
FROM download AS update_settings
#---------------------------------------------------------------
# D.1 Update of the prefs.sh file settings
# Recall global definitions made at the top
ARG OF_VERSION
ARG OF_INSTALL_DIR
# Auxiliary arguments
ARG OF_PREFS_TEMPLATE="${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/config.sh/example/prefs.sh"
ARG OF_PREFS_FILE="${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/prefs.sh"
ARG OF_PREFS_HEADER_LINES=23

#Updating the prefs.sh file
RUN head -${OF_PREFS_HEADER_LINES} $OF_PREFS_TEMPLATE > $OF_PREFS_FILE \
 && echo '#------------------------------------------------------------------------------' >> ${OF_PREFS_FILE} \
#Using a combination of the variable definition recommended for the use of system mpich in this link:
#   https://bugs.openfoam.org/view.php?id=1167
#And in the file .../OpenFOAM-${OF_VERSION}/wmake/rules/General/mplibMPICH
#(These MPI_* environmental variables are set in the prefs.sh,
# and this file will be sourced automatically by the bashrc when the bashrc is sourced)
#
#--As suggested in the link above, WM_MPLIB and MPI_ROOT need to be set:
 && echo 'export WM_MPLIB=SYSTEMMPI' >> ${OF_PREFS_FILE} \
 && echo 'export MPI_ROOT="/usr"' >> ${OF_PREFS_FILE} \
#
#--As suggested in the link above, MPI_ARCH_FLAGS,MPI_ARCH_INC,MPI_ARCH_LIBS also need to be set:
#--The setting of these three variables has been a strugle during the years. We have found different type
#  of solutions that are kept commented for reference. And those that work for this version of OpenFOAM
#  are left active. So the active lines are the settings that worked among the different suggestions (A,B,C):
#  ~(A)The suggestions from the link above:
## && echo 'export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX"' >> ${OF_PREFS_FILE} \
## && echo 'export MPI_ARCH_INC="-I/usr/include/mpich"' >> ${OF_PREFS_FILE} \
## && echo 'export MPI_ARCH_LIBS="-L/usr/lib/x86_64-linux-gnu -lmpich"' >> ${OF_PREFS_FILE} \
#
#  ~(B)The suggestions from the file mplibMPICH file itself are:
 && echo 'export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX"' >> ${OF_PREFS_FILE} \
## && echo 'export MPI_ARCH_INC="-isystem ${MPI_ROOT}/include"' >> ${OF_PREFS_FILE} \
 && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OF_PREFS_FILE} \
#
#  ~(C)Even further modifications needed for some OpenFOAM and compiler versions:
#..If the gcc compiler has problems with the -isystem flag, use -I instead:
 && echo 'export MPI_ARCH_INC="-I ${MPI_ROOT}/include"' >> ${OF_PREFS_FILE} \
#..Use only one library path and plus -lmpich
## && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OF_PREFS_FILE} \
#..Use the two library paths and plus -lmpich
## && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OF_PREFS_FILE} \
#--Dummy line to avoid tracking continuation lines:
 && echo ''

#---------------------------------------------------------------
# D.2 Update of the bashrc file settings
# Recall global definitions made at the top
ARG OF_INSTALL_DIR
ARG OF_USER_DIR
ARG OF_BASHRC_FILE
# Updating the bashrc file (also saving a backup of the original)
RUN cp ${OF_BASHRC_FILE} ${OF_BASHRC_FILE}.original \
#Changing the installation directory within the bashrc file (This is not in the openfoamwiki instructions)
 && sed -i 's/^export FOAM_INST_DIR=/# export FOAM_INST_DIR=/g' ${OF_BASHRC_FILE} \
 && sed -i '0,/\[ "$BASH"/s//# \[ "$BASH"/' ${OF_BASHRC_FILE} \
 && sed -i '0,/\[ "$ZSH_NAME"/s//# \[ "$ZSH"/' ${OF_BASHRC_FILE} \
 && sed -i '0,/^# export FOAM_INST_DIR=.*/!b;//a\export FOAM_INST_DIR='"${OF_INSTALL_DIR}" ${OF_BASHRC_FILE} \
#Changing the place for your own tools/solvers (WM_PROJECT_USER_DIR directory) within the bashrc file
#IMPORTANT:When using this container, you have two options when building your own tools/solvers:
#   1. You can mount a directory of your local-host into this directory
#   2. Or you can include and build stuff inside the image and save it as your own image for later use.
 && sed -i '/^export WM_PROJECT_USER_DIR=.*/aexport WM_PROJECT_USER_DIR='"${OF_USER_DIR}" ${OF_BASHRC_FILE} \
 && sed -i '0,/^export WM_PROJECT_USER_DIR/s//# export WM_PROJECT_USER_DIR/' ${OF_BASHRC_FILE} \
#--Dummy line to avoid tracking continuation lines:
 && echo ''

#---------------------------------------------------------------
# D.3 Update of the controlDict file settings
# Recall global definitions made at the top
ARG OF_INSTALL_DIR
ARG OF_VERSION
#Auxiliary arguments
ARG OF_CONTROL_FILE="${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/controlDict"
#Defining Pawsey Best Practices as defaults of the controlDict (also creating a backup of the original)
RUN cp ${OF_CONTROL_FILE} ${OF_CONTROL_FILE}.original \
#Setting collated as default for fileHandler
 && sed -i '\@fileHandler uncollated;@a    fileHandler collated;' ${OF_CONTROL_FILE} \
 && sed -i '0,\@fileHandler uncollated;@s@@// fileHandler uncollated;@' ${OF_CONTROL_FILE} \
#--Dummy line to avoid tracking continuation lines:
 && echo ''


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# E. Third-Party installation
#    Install Third Party tools (preferred to do it as a separate step and not together with the full openfoam compilation)
# No ThirdParty CGAL or Boost build is indicated for this release.
# If needed, these dependencies are expected to be installed with apt-get.
# It seems that foamyHexMesh has been deprecated, so CGAL seems not to be needed.
FROM update_settings AS third_party_install
#---------------------------------------------------------------
# Recall global definitions made at the top
ARG OF_BASHRC_FILE
# Auxiliary arguments
ARG BASHRC_OPTIONS=""
ARG TP_COMPILE_TASKS="16"

#---------------------------------------------------------------
#Using bash to interpret OpenFOAM scripts
#Also, using the `pipefail` option to avoid losing errors in the compilation commands when using `tee` and/or piped commands
SHELL ["/bin/bash","-o","pipefail","-c"]

#---------------------------------------------------------------
# Third-Party compilation
# IMPORTANT: We are using 3 preliminary compilation passes (2 in parallel, 1 in serial)
#            and 1 final parallel authoritative compilation pass.
#            This because some compilation race conditions were found when compiling in a single parallel pass.
#            The preliminary compilation passes are "sheltered" to avoid the building to break.
#            The only compilation pass that causes the building to break if there are issues is the final authoritative pass.
# IMPORTANT: A successful preliminary compilation pass creates a component-specific
#            sentinel file. Later preliminary compilation passes skip their
#            compilation when that sentinel exists. The final authoritative
#            compilation pass always runs. The sentinel is retained as provenance.
# NOTE:      In a "normal" recipe only a single compilation pass would have been used,
#            (in this case just the final authoritative pass would exist). But, as mentioned above,
#            the multiple preliminary passes were needed to warranty proper compilation in our builidng nodes.

# First preliminary compilation pass, performed in parallel.
# A failure is recorded but does not stop the image build,
# allowing partial build products to be committed into this layer.
# OPENFOAM_BUILD_SCAN_IGNORE_BEGIN and _END print-outs are for an external
# review of the building logs to ignore errors in these compilation passes and concentrate
# only on errors in the final authoritative compilation pass.
ARG TP_PASS_NUMBER="1"
ARG TP_PASS_TASKS="${TP_COMPILE_TASKS}"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Continue from the component source directory:
 && cd $WM_THIRD_PARTY_DIR \
 && { \
      passInfo="pass-${TP_PASS_NUMBER}-tasks-${TP_PASS_TASKS}"; \
      passLog="log.Allwmake.${passInfo}"; \
      sentinelFile="$WM_THIRD_PARTY_DIR/.thirdparty-preliminary-compilation-succeeded"; \
      if [[ -f "$sentinelFile" ]]; then \
          echo "Skipping ThirdParty preliminary compilation $passInfo."; \
          echo "First successful preliminary compilation: $(cat "$sentinelFile")"; \
          printf '%s\n' "SKIPPED" > "${passLog}.status"; \
          exit 0; \
      fi; \
      echo "Starting ThirdParty preliminary compilation $passInfo"; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_BEGIN component=ThirdParty pass=${TP_PASS_NUMBER}"; \
      # ----- The compilation command:
      ./Allwmake -j"${TP_PASS_TASKS}" 2>&1 | tee "$passLog"; \
      compileStatus=${PIPESTATUS[0]}; \
      echo "ThirdParty preliminary compilation $passInfo exit status: $compileStatus"; \
      printf '%s\n' "$compileStatus" > "${passLog}.exit-status"; \
      if [[ $compileStatus -eq 0 ]]; then \
          printf '%s\n' "$passInfo" > "$sentinelFile"; \
          echo "ThirdParty preliminary compilation $passInfo completed successfully."; \
          echo "Later preliminary compilation passes can be skipped."; \
      else \
          echo "WARNING: ThirdParty preliminary compilation $passInfo failed with exit status $compileStatus."; \
          echo "Partial compilation results will be retained for the next compilation pass."; \
      fi; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_END component=ThirdParty pass=${TP_PASS_NUMBER}"; \
      exit 0; \
    }

# Second preliminary compilation pass, performed in parallel.
# A failure is recorded but does not stop the image build,
# allowing partial build products to be committed into this layer.
ARG TP_PASS_NUMBER="2"
ARG TP_PASS_TASKS="${TP_COMPILE_TASKS}"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Continue from the component source directory:
 && cd $WM_THIRD_PARTY_DIR \
 && { \
      passInfo="pass-${TP_PASS_NUMBER}-tasks-${TP_PASS_TASKS}"; \
      passLog="log.Allwmake.${passInfo}"; \
      sentinelFile="$WM_THIRD_PARTY_DIR/.thirdparty-preliminary-compilation-succeeded"; \
      if [[ -f "$sentinelFile" ]]; then \
          echo "Skipping ThirdParty preliminary compilation $passInfo."; \
          echo "First successful preliminary compilation: $(cat "$sentinelFile")"; \
          printf '%s\n' "SKIPPED" > "${passLog}.status"; \
          exit 0; \
      fi; \
      echo "Starting ThirdParty preliminary compilation $passInfo"; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_BEGIN component=ThirdParty pass=${TP_PASS_NUMBER}"; \
      # ----- The compilation command:
      ./Allwmake -j"${TP_PASS_TASKS}" 2>&1 | tee "$passLog"; \
      compileStatus=${PIPESTATUS[0]}; \
      echo "ThirdParty preliminary compilation $passInfo exit status: $compileStatus"; \
      printf '%s\n' "$compileStatus" > "${passLog}.exit-status"; \
      if [[ $compileStatus -eq 0 ]]; then \
          printf '%s\n' "$passInfo" > "$sentinelFile"; \
          echo "ThirdParty preliminary compilation $passInfo completed successfully."; \
          echo "Later preliminary compilation passes can be skipped."; \
      else \
          echo "WARNING: ThirdParty preliminary compilation $passInfo failed with exit status $compileStatus."; \
          echo "Partial compilation results will be retained for the next compilation pass."; \
      fi; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_END component=ThirdParty pass=${TP_PASS_NUMBER}"; \
      exit 0; \
    }

# Third preliminary compilation pass, performed serially.
# A failure is recorded but does not stop the image build,
# allowing partial build products to be committed into this layer.
ARG TP_PASS_NUMBER="3"
ARG TP_PASS_TASKS="1"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Continue from the component source directory:
 && cd $WM_THIRD_PARTY_DIR \
 && { \
      passInfo="pass-${TP_PASS_NUMBER}-tasks-${TP_PASS_TASKS}"; \
      passLog="log.Allwmake.${passInfo}"; \
      sentinelFile="$WM_THIRD_PARTY_DIR/.thirdparty-preliminary-compilation-succeeded"; \
      if [[ -f "$sentinelFile" ]]; then \
          echo "Skipping ThirdParty preliminary compilation $passInfo."; \
          echo "First successful preliminary compilation: $(cat "$sentinelFile")"; \
          printf '%s\n' "SKIPPED" > "${passLog}.status"; \
          exit 0; \
      fi; \
      echo "Starting ThirdParty preliminary compilation $passInfo"; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_BEGIN component=ThirdParty pass=${TP_PASS_NUMBER}"; \
      # ----- The compilation command:
      ./Allwmake -j"${TP_PASS_TASKS}" 2>&1 | tee "$passLog"; \
      compileStatus=${PIPESTATUS[0]}; \
      echo "ThirdParty preliminary compilation $passInfo exit status: $compileStatus"; \
      printf '%s\n' "$compileStatus" > "${passLog}.exit-status"; \
      if [[ $compileStatus -eq 0 ]]; then \
          printf '%s\n' "$passInfo" > "$sentinelFile"; \
          echo "ThirdParty preliminary compilation $passInfo completed successfully."; \
          echo "Later preliminary compilation passes can be skipped."; \
      else \
          echo "WARNING: ThirdParty preliminary compilation $passInfo failed with exit status $compileStatus."; \
          echo "Partial compilation results will be retained for the next compilation pass."; \
      fi; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_END component=ThirdParty pass=${TP_PASS_NUMBER}"; \
      exit 0; \
    }

# Final authoritative compilation pass, performed in parallel.
# This failure is not masked. With pipefail enabled, any remaining
# compilation failure stops the Podman build.
ARG TP_PASS_NUMBER="authoritative"
ARG TP_PASS_TASKS="${TP_COMPILE_TASKS}"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Perform the authoritative compilation check:
 && cd $WM_THIRD_PARTY_DIR \
 && echo "Starting authoritative ThirdParty compilation pass" \
 && ./Allwmake -j"$TP_PASS_TASKS" 2>&1 | tee log.Allwmake.AuthoritativeSummary


