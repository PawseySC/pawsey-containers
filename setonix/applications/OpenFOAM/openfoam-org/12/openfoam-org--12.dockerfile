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
            git \
# cleaning at the end:
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

### Use the following block anywhere in the script during developing whenever the tools are needed
##RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq \
## &&  apt-get -y --no-install-recommends install \
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
    build-essential cmake ca-certificates flex \
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
##RUN git clone https://github.com/OpenFOAM/OpenFOAM-${OF_VERSION}.git
##RUN git clone https://github.com/OpenFOAM/ThirdParty-${OF_VERSION}.git
##RUN git clone git://github.com/OpenFOAM/OpenFOAM-${OF_VERSION}.git
##RUN git clone git://github.com/OpenFOAM/ThirdParty-${OF_VERSION}.git
RUN git clone --depth 1 --branch version-${OF_VERSION} \
    https://github.com/OpenFOAM/OpenFOAM-${OF_VERSION}.git

RUN git clone --depth 1 --branch version-${OF_VERSION} \
    https://github.com/OpenFOAM/ThirdParty-${OF_VERSION}.git


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
ARG OF_PREFS_HEADER_LINES=37

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


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# F. ParaView installation
FROM third_party_install AS pv_install
#---------------------------------------------------------------
# ParaView or VTK historically needed for runTimePostprocessing of OpenFOAM to properly compile
# ParaView needed for graphical postprocessing to be available in the container
# Catalyst tools are not available for the Foundation version
# Foundation source files do not include a makeVTK script, so VTK will not be installed separately

#---------------------------------------------------------------
# F.1 Install ParaView as a system package
RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq \
 && apt-get --no-install-recommends --no-install-suggests --yes install \
    paraview-dev \
# cleaning at the end:
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*

#---------------------------------------------------------------
# F.2 Alternative installation of ParaView from source
# (ParaView download address copied from ThirdParty-<Version>/README.org)
#NotUsed:ARG PVverFull="5.11.2"
#NotUsed:ARG PVverMajor="5.11"
#NotUsed:RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
#NotUsed: && cd $WM_THIRD_PARTY_DIR \
#NotUsed: && export QT_SELECT=qt5 \
#NotUsed: && wget --no-check-certificate http://www.paraview.org/files/v${PVverMajor}/ParaView-v${PVverFull}.tar.gz \
#NotUsed: && tar xvf ParaView-v${PVverFull}.tar.gz \
#NotUsed: && rm ParaView-v${PVverFull}.tar.gz \
#NotUsed: && mv ParaView-v${PVverFull} ParaView-${PVverFull}

# ParaView compilation according to instructions from the official site
#NotUsed:RUN echo 'export ParaView_TYPE=ThirdParty' >> ${OF_PREFS_FILE} \
#NotUsed: && source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
#NotUsed: && cd $WM_THIRD_PARTY_DIR \
#NotUsed: && ./makeParaView -version ${PVverFull} 2>&1 | tee log.makePVOfficial


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# G. OpenFOAM compilation
FROM pv_install AS of_install
#FROM third_party_install AS of_install
#---------------------------------------------------------------
# Recall global definitions made at the top
ARG OF_BASHRC_FILE
# Auxiliary arguments
ARG OF_COMPILE_TASKS=16
ARG BASHRC_OPTIONS=""

#---------------------------------------------------------------
#Using bash to interpret OpenFOAM scripts
#Also, using the `pipefail` option to avoid losing errors in the compilation commands when using `tee` and/or piped commands
SHELL ["/bin/bash","-o","pipefail","-c"]

#---------------------------------------------------------------
# G.1 Preparatory updates

#---------------------------------------------------------------
# G.2 OpenFOAM compilation
#     Adapted from OpenFoamWiki v1806 (last version documented in the wiki)
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
#            the multiple passes were needed to warranty proper compilation in our builidng nodes.

# First parallel preliminary compilation pass.
# A compilation failure is recorded but does not stop the image build,
# allowing partial build products to be committed into this layer.
ARG OF_PASS_NUMBER="1"
ARG OF_PASS_TASKS="${OF_COMPILE_TASKS}"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Continue from the component source directory:
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && { \
      passInfo="pass-${OF_PASS_NUMBER}-tasks-${OF_PASS_TASKS}"; \
      passLog="log.Allwmake.${passInfo}"; \
      sentinelFile="$WM_PROJECT_DIR/.openfoam-preliminary-compilation-succeeded"; \
      if [[ -f "$sentinelFile" ]]; then \
          echo "Skipping OpenFOAM preliminary compilation $passInfo."; \
          echo "First successful preliminary compilation: $(cat "$sentinelFile")"; \
          printf '%s\n' "SKIPPED" > "${passLog}.status"; \
          exit 0; \
      fi; \
      echo "Starting OpenFOAM preliminary compilation $passInfo"; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_BEGIN component=OpenFOAM pass=${OF_PASS_NUMBER}"; \
      # ----- The compilation command:
      ./Allwmake -j"${OF_PASS_TASKS}" 2>&1 | tee "$passLog"; \
      compileStatus=${PIPESTATUS[0]}; \
      echo "OpenFOAM preliminary compilation $passInfo exit status: $compileStatus"; \
      printf '%s\n' "$compileStatus" > "${passLog}.exit-status"; \
      if [[ $compileStatus -eq 0 ]]; then \
          printf '%s\n' "$passInfo" > "$sentinelFile"; \
          echo "OpenFOAM preliminary compilation $passInfo completed successfully."; \
          echo "Later preliminary compilation passes can be skipped."; \
      else \
          echo "WARNING: OpenFOAM preliminary compilation $passInfo failed with exit status $compileStatus."; \
          echo "Partial compilation results will be retained for the next compilation pass."; \
      fi; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_END component=OpenFOAM pass=${OF_PASS_NUMBER}"; \
      exit 0; \
    }

# Second parallel preliminary compilation pass.
# A compilation failure is recorded but does not stop the image build,
# allowing partial build products to be committed into this layer.
ARG OF_PASS_NUMBER="2"
ARG OF_PASS_TASKS="${OF_COMPILE_TASKS}"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Continue from the component source directory:
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && { \
      passInfo="pass-${OF_PASS_NUMBER}-tasks-${OF_PASS_TASKS}"; \
      passLog="log.Allwmake.${passInfo}"; \
      sentinelFile="$WM_PROJECT_DIR/.openfoam-preliminary-compilation-succeeded"; \
      if [[ -f "$sentinelFile" ]]; then \
          echo "Skipping OpenFOAM preliminary compilation $passInfo."; \
          echo "First successful preliminary compilation: $(cat "$sentinelFile")"; \
          printf '%s\n' "SKIPPED" > "${passLog}.status"; \
          exit 0; \
      fi; \
      echo "Starting OpenFOAM preliminary compilation $passInfo"; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_BEGIN component=OpenFOAM pass=${OF_PASS_NUMBER}"; \
      # ----- The compilation command:
      ./Allwmake -j"${OF_PASS_TASKS}" 2>&1 | tee "$passLog"; \
      compileStatus=${PIPESTATUS[0]}; \
      echo "OpenFOAM preliminary compilation $passInfo exit status: $compileStatus"; \
      printf '%s\n' "$compileStatus" > "${passLog}.exit-status"; \
      if [[ $compileStatus -eq 0 ]]; then \
          printf '%s\n' "$passInfo" > "$sentinelFile"; \
          echo "OpenFOAM preliminary compilation $passInfo completed successfully."; \
          echo "Later preliminary compilation passes can be skipped."; \
      else \
          echo "WARNING: OpenFOAM preliminary compilation $passInfo failed with exit status $compileStatus."; \
          echo "Partial compilation results will be retained for the next compilation pass."; \
      fi; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_END component=OpenFOAM pass=${OF_PASS_NUMBER}"; \
      exit 0; \
    }

# Third preliminary compilation pass, performed serially.
# A compilation failure is recorded but does not stop the image build,
# allowing partial build products to be committed into this layer.
ARG OF_PASS_NUMBER="3"
ARG OF_PASS_TASKS="1"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Continue from the component source directory:
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && { \
      passInfo="pass-${OF_PASS_NUMBER}-tasks-${OF_PASS_TASKS}"; \
      passLog="log.Allwmake.${passInfo}"; \
      sentinelFile="$WM_PROJECT_DIR/.openfoam-preliminary-compilation-succeeded"; \
      if [[ -f "$sentinelFile" ]]; then \
          echo "Skipping OpenFOAM preliminary compilation $passInfo."; \
          echo "First successful preliminary compilation: $(cat "$sentinelFile")"; \
          printf '%s\n' "SKIPPED" > "${passLog}.status"; \
          exit 0; \
      fi; \
      echo "Starting OpenFOAM preliminary compilation $passInfo"; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_BEGIN component=OpenFOAM pass=${OF_PASS_NUMBER}"; \
      # ----- The compilation command:
      ./Allwmake -j"${OF_PASS_TASKS}" 2>&1 | tee "$passLog"; \
      compileStatus=${PIPESTATUS[0]}; \
      echo "OpenFOAM preliminary compilation $passInfo exit status: $compileStatus"; \
      printf '%s\n' "$compileStatus" > "${passLog}.exit-status"; \
      if [[ $compileStatus -eq 0 ]]; then \
          printf '%s\n' "$passInfo" > "$sentinelFile"; \
          echo "OpenFOAM preliminary compilation $passInfo completed successfully."; \
          echo "Later preliminary compilation passes can be skipped."; \
      else \
          echo "WARNING: OpenFOAM preliminary compilation $passInfo failed with exit status $compileStatus."; \
          echo "Partial compilation results will be retained for the next compilation pass."; \
      fi; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_END component=OpenFOAM pass=${OF_PASS_NUMBER}"; \
      exit 0; \
    }

# Final authoritative parallel pass and summary of the OpenFOAM compilation.
# With pipefail enabled, any remaining compilation failure stops building process.
ARG OF_PASS_NUMBER="authoritative"
ARG OF_PASS_TASKS="${OF_COMPILE_TASKS}"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Continue:
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && echo "Starting authoritative OpenFOAM summary compilation pass" \
 && ./Allwmake -j"$OF_PASS_TASKS" 2>&1 | tee log.Allwmake.AuthoritativeSummary

#---------------------------------------------------------------
# G.3 Checking if a popular executable is working
ARG OF_TOOL="icoFoam"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && $OF_TOOL -help 2>&1 | tee log.OF_TOOL

#---------------------------------------------------------------
# G.4 Printing out the environment variables for the installation so far:
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && printenv > environment_vars_raw.txt


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# H. Final settings
FROM of_install AS final_settings
#FROM update_settings AS final_settings
#FROM basic_stage AS final_settings

#---------------------------------------------------------------
# H.1 Avoid permission problems with files in the installation directory
# Recall global definitions made at the top
ARG OF_INSTALL_DIR
# Relaxing permissions to avoid problems
RUN mkdir -p $OF_INSTALL_DIR \
 && chmod -R a+rwX $OF_INSTALL_DIR

#---------------------------------------------------------------
# H.2 Setup to source OpenFoam OF_BASHRC_FILE at container entry with Docker
# Reasoning: OF_BASHRC_FILE has to be sourced on entry to define the OpenFOAM environment.
#            It has historically showed several bash-isms, so better to interpret it with bash.
#            The sourcing of `bashrc` script will be performed inside the execution of the Docker Entrypoint Script.
# For Docker Use: Docker executes (yes:executes) entrypoint script on entry to the container:
#                 (name needs to be hardcoded, can't use dynamic evaluation of arguments inside ENTRYPOINT command)
# IMPORTANT: "docker-entrypoint-openfoam-template.sh" file should be available in the building directory
# Recall global definitions made at the top
ARG OF_BASHRC_FILE
# Auxiliary arguments
ARG ENTRYPOINT_FILE_TEMPLATE="docker-entrypoint-openfoam-template.sh"
#ARG ENTRYPOINT_FILE_TEMPLATE="auxiliaryScripts/docker-entrypoint-openfoam-template-debugging.sh"
ARG ENTRYPOINT_FILE_DOCKER="/usr/local/bin/docker-entrypoint-openfoam.sh"
#ARG ENTRYPOINT_FILE_DOCKER="/etc/profile.d/docker-entrypoint-openfoam.sh"

# Using bash to interpret the entry script
#Also, using the `pipefail` option to avoid losing errors in the compilation commands when using `tee` and/or piped commands
SHELL ["/bin/bash","-o","pipefail","-c"]

# Copy and update the ENTRYPOINT_FILE_DOCKER script with the right OF_BASHRC_FILE definition in this recipe
COPY $ENTRYPOINT_FILE_TEMPLATE $ENTRYPOINT_FILE_DOCKER
RUN sed -i 's,BASHRC_TEMPLATE_TAG,'"${OF_BASHRC_FILE}"',g' $ENTRYPOINT_FILE_DOCKER \
 && chmod a+rwx $ENTRYPOINT_FILE_DOCKER

# Note: for developing purposes, the use of a link instead of the `COPY`+`RUN sed` above can be useful
#       Using the link allows the modification of the script in the host without having to rebuild the image for each change
#       Obviously, the host directory containing `theDockerScript.sh` script needs to be binded to `/home/ofuser` when running the container.
#RUN ln -s /home/ofuser/theDockerScript.sh $ENTRYPOINT_FILE_DOCKER

# For Docker Use: Defining the ENTRYPOINT file and default command
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-openfoam.sh"]
CMD ["/bin/bash"]

#---------------------------------------------------------------
# H.3 Setup to source OpenFoam OF_BASHRC_FILE at container entry when using Singularity
# Reasoning: OF_BASHRC_FILE has to be sourced on entry to define the OpenFOAM environment.
#            It has historically showed several bash-isms so it would be better to interpret it with bash.
#            The sourcing of `bashrc` script will be performed during a "master" sourcing (yes:sourcing) of a singularity environment script.
#            Unfortunately, the trick to force bash interpretation during sourcing of environment scripts is obsolete (see down in this section).
#            Fortunately, the singularity-embedded-shell-interpreter understands basic bash-isms, and that has been enough so far.
# For Singularity Use: the singularity-embedded-shell-interpreter will source (yes:source) scripts in /.singularity.d/env/ at startup.
#            Standard naming of "environment" scripts is XX-<someName>.sh (extension is compulsory exact `.sh`).
#            Scripts are sourced (yes:sourced) in alphanumerical order, and here we use the name: 91-environment-openfoam.sh
# IMPORTANT:  "singularity-environment-openfoam-template.sh" file should be available in the building directory.
#             and is copied into "91-environment-openfoam.sh" and updated for the correct `bashrc` file in this recipe.
# IMPORTANT2: The environment script should not contain the `exec "$@"` command at the end,
#             otherwise the Host Environment Variables will be lost.
#             This is the main reason why separate scripts are kept for Docker and for Singularity startup environments.
# IMPORTANT3: And during practical use of the singularit image:
#             The `singularity shell` and `singularity exec` commands are the only safe commands:
#               These commands only source (yes:source) the singularity environment files and ignore the Docker entry settings.
#             The `singularity run` command is not safe and fails in some corner cases:
#               This command tries to emulate the Docker behaviour and it executes (yes:executes) the Docker ENTRYPOINT+CMD after the sourcing (yes:sourcing) of the Singularity environment part.
#               (Even if the `91-environment-openfoam.sh` was not set, this command fails in some corner cases and is not safe to use.)

# Recall global definitions made at the top
ARG OF_BASHRC_FILE
# Auxiliary arguments
ARG ENVIRONMENT_FILE_TEMPLATE="singularity-environment-openfoam-template.sh"
#ARG ENVIRONMENT_FILE_TEMPLATE="auxiliaryScripts/singularity-environment-openfoam-template-debugging.sh"
ARG ENVIRONMENT_DIR_SINGULARITY="/.singularity.d/env"
ARG ENVIRONMENT_FILE_SINGULARITY="${ENVIRONMENT_DIR_SINGULARITY}/91-environment-openfoam.sh"

# Copy and update the ENVIRONMENT_FILE_SINGULARITY script with the right OF_BASHRC_FILE definition in this recipe
RUN mkdir -p $ENVIRONMENT_DIR_SINGULARITY
COPY $ENVIRONMENT_FILE_TEMPLATE $ENVIRONMENT_FILE_SINGULARITY
RUN sed -i 's,BASHRC_TEMPLATE_TAG,'"${OF_BASHRC_FILE}"',g' $ENVIRONMENT_FILE_SINGULARITY \
 && chmod a+rwx $ENVIRONMENT_FILE_SINGULARITY

# Note: for developing purposes, the use of a link instead of the `COPY`+`RUN sed` above can be useful
#       Using the link allows the modification of the script in the host without having to rebuild the image for each change
#       Obviously, the host directory containing `theSingularityScript.sh` script needs to be binded to `/home/ofuser` when running the container.
#RUN ln -s /home/ofuser/theSingularityScript.sh $ENVIRONMENT_FILE_SINGULARITY

# For Singularity Use:
# Legacy trick (stopped working since singularity 3.6):trick to force the use of bash shell when sourcing the environment scripts
#        OpenFoam OF_BASHRC_FILE may have bashisms that may only work in `bash` shell, not `sh`, `dash` nor `ash`.
#        The trick of linking `sh` to `bash` used to work in previous versions for correctly sourcing files in /.singularity.d/env with `bash` instead of `sh`,`dash` or `ash`.
#RUN /bin/mv /bin/sh /bin/sh.original && /bin/ln -s /bin/bash /bin/sh
#        But this trick DOES NOT WORK ANYMORE since singularity 3.6, as singularity does not use `/bin/*sh*` available commands anymore to interpret these environment scripts.
#        Since the mentioned version, Singularity is using an in-house-singularity embedded shell interpreter (capable to interpret many bashisms besides standard `POSIX sh`)
#        Check issue 5541 here: https://github.com/apptainer/singularity/issues/5541
#        If you found that OpenFOAM's bashrc sourcing still has bashisms that require forced `bash` interpretation, then read the mentioned link for alternatives (not implemented here.)

#---------------------------------------------------------------
# H.4 Backup into the image the recipe and all files "called" during building
# Recall global definitions made at the top
ARG OF_FORK
ARG OF_VERSION
ARG BUILD_FILES_DIR
# Auxiliary arguments
ARG RECIPE_FILE="${OF_FORK}--${OF_VERSION}.dockerfile"
# Copy all files used to build the image into the internal backup directory
RUN mkdir -p "$BUILD_FILES_DIR"
COPY $RECIPE_FILE \
     $ENTRYPOINT_FILE_TEMPLATE \
     $ENVIRONMENT_FILE_TEMPLATE \
     $BUILD_FILES_DIR

#---------------------------------------------------------------
# H.5 Recording the effective values of the global build arguments in file $BUILD_FILES_DIR/image-build-arguments.txt
# The argument names are read automatically from the global ARG
# declarations located before the first FROM instruction.
# But every global argument MUST ALSO be recalled in this section for the recording to work.
# If a developer adds a new global ARG at the top, but does not recall it here,
# the build stops with an explanatory error instead of generating
# an incomplete build-arguments record.

# Recall all global build arguments defined before the first FROM
# in order to have a full match in the list to be recorded by the RUN instruction immediately below.
ARG OF_FORK
ARG OF_VERSION
ARG BASE_IMAGE_REGISTRY
ARG BASE_IMAGE_NAME
ARG BASE_IMAGE_OS_VERSION
ARG BASE_IMAGE_MPICH_VERSION
ARG BASE_IMAGE_TAG
ARG BASE_IMAGE_FULL
ARG OF_INSTALL_DIR
ARG OF_USER
ARG OF_USER_DIR
ARG OF_BASHRC_FILE
ARG BUILD_FILES_DIR

# Auxiliary arguments
ARG INTERNAL_RECIPE_FILE="${BUILD_FILES_DIR}/${OF_FORK}--${OF_VERSION}.dockerfile"
ARG ARGUMENTS_FILE="${BUILD_FILES_DIR}/image-build-arguments.txt"

# The following RUN instruction reads the list of global ARG names from the recipe file
# and writes their effective values into a record file if they have been recalled in the lines immediately above.
# If a global ARG is not recalled, the build stops with an error.
RUN test -f "$INTERNAL_RECIPE_FILE" \
# Read all global ARG names declared before the first FROM instruction:
 && mapfile -t argumentNames < <( \
      sed -n '1,/^[[:space:]]*FROM[[:space:]]/p' "$INTERNAL_RECIPE_FILE" \
      | grep -E '^[[:space:]]*ARG[[:space:]]+' \
      | sed -E ' \
           s/^[[:space:]]*ARG[[:space:]]+//; \
           s/[[:space:]]*=.*$//; \
           s/[[:space:]].*$// \
        ' \
    ) \
# Verify that global arguments were found:
 && if (( ${#argumentNames[@]} == 0 )); then \
      echo "ERROR: No global ARG declarations were found in $INTERNAL_RECIPE_FILE" >&2; \
      exit 1; \
    fi \
# Create the build-arguments record:
 && printf '%s\n' \
      "# Effective global Dockerfile arguments used in the build process." \
      "# If effective values differ from their defaults (defined at the top before the first FROM instruction)," \
      "#  that means that the user has overridden the default values in the building command line." \
      "#" \
      "# The record was generated during the build process" \
      "#  following the instructions in the last stage in $INTERNAL_RECIPE_FILE ." \
      "" \
      > "$ARGUMENTS_FILE" \
# Write the effective value of every discovered global argument:
 && for argumentName in "${argumentNames[@]}"; do \
      if [[ ! -v "$argumentName" ]]; then \
         echo "ERROR: Global build argument '$argumentName' is defined in the recipe" >&2; \
         echo "       but is not available in the final stage." >&2; \
         echo "       Add a recall instruction: 'ARG $argumentName' in the final stage before this RUN instruction." >&2; \
         exit 1; \
      fi; \
      printf '%s=%q\n' \
         "$argumentName" \
         "${!argumentName}" \
         >> "$ARGUMENTS_FILE"; \
    done \
 && chmod a+r "$ARGUMENTS_FILE" \
 && echo "Created build-argument record: $ARGUMENTS_FILE" \
 && cat "$ARGUMENTS_FILE"

#---------------------------------------------------------------
# H.6 Defining documented labels
# Recall global definitions made at the top
ARG OF_FORK
ARG OF_VERSION
ARG BASE_IMAGE_MPICH_VERSION
ARG BASE_IMAGE_OS_VERSION
ARG BUILD_FILES_DIR

# Labels:
LABEL org.opencontainers.image.authors="Alexis Espinosa <Alexis.Espinosa@pawsey.org.au>"
LABEL org.opencontainers.image.title="${OF_FORK}"
LABEL org.opencontainers.image.version="${OF_VERSION}-mpich${BASE_IMAGE_MPICH_VERSION}-ubuntu${BASE_IMAGE_OS_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers"
LABEL au.org.pawsey.image.build-files-dir="${BUILD_FILES_DIR}"

#---------------------------------------------------------------
# H.7 Starting as OF_USER by default
# Recall global definitions made at the top
ARG OF_USER
# Avoid permission problems with the home directory of OF_USER
RUN chmod -R a+rwX /home/$OF_USER
# Starting as OF_USER by default
USER $OF_USER
WORKDIR /home/$OF_USER
