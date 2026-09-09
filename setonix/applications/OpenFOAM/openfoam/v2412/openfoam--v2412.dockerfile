#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition of global parameters
# IMPORTANT: Global arguments marked with USER_BUILD_ARG can be overridden with `--build-arg <Name>=<Value>` when using the building script.
# IMPORTANT: Other global arguments are fixed recipe settings and are not supported as user overrides.
# IMPORTANT: Recipe needs to re-call global arguments at each stage to recover their values.
# IMPORTANT: Developers should check that ALL the ARG definitions here are recalled in the "recording_arguments" section of the final stage.
# 0.1 Main global arguments related to the OpenFOAM version and compiler
# USER_BUILD_ARG
ARG OF_FORK="openfoam"
# USER_BUILD_ARG
ARG OF_VERSION="v2412"
# GCC version fixed for this recipe and used for package installation, compiler selection, validation and image naming
ARG GCC_VERSION="13"

# 0.2 OpenFOAM compilation settings supported as user build-argument overrides
# USER_BUILD_ARG
ARG WM_LABEL_SIZE="32"
# USER_BUILD_ARG
ARG WM_PRECISION_OPTION="DP"
# USER_BUILD_ARG
ARG WM_COMPILE_OPTION="Opt"

# 0.3 Main arguments related to the base container to use
# Defining the base container to use
# IMPORTANT: Setonix mpi containers need at least ubuntu24.04 (From August 2025)
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

#---------------------------------------------------------------
# 0.4 Auxiliary global arguments of definitions used in multiple stages
ARG OF_INSTALL_DIR="/opt/OpenFOAM"
ARG OF_USER="ofuser"
ARG OF_USER_DIR="/home/${OF_USER}/OpenFOAM/${OF_USER}-${OF_VERSION}"
ARG OF_BASHRC_FILE="${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/bashrc"

# 0.5 Other auxiliary variables
ARG IMAGE_BUILD_INFO_DIR="/opt/build-info-and-recipes"


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

### Use the following block anywhere in the script during developing whenever the tools are needed
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
# Recall global definitions made at the top
ARG GCC_VERSION
# OpenFOAM v2412+ dependencies for Ubuntu 24.04 LTS
# Aggregated from:
# [1] https://develop.openfoam.com/Development/openfoam/-/blob/maintenance-v2412/doc/Build.md
# [2] https://develop.openfoam.com/Development/ThirdParty-common/-/blob/v2412/Requirements.md
# [3] https://www.openfoam.com/news/main-news/openfoam-v2412
# [4] https://gitlab.com/openfoam/core/openfoam/-/blob/master/doc/Build.md
# [5] https://develop.openfoam.com/Development/ThirdParty-common/blob/develop/BUILD.md
# [6] https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-v1806/Ubuntu (Last documented instructions in the wiki)
RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq \
 && apt-get --no-install-recommends --no-install-suggests --yes install \
    build-essential gcc-${GCC_VERSION} g++-${GCC_VERSION} gfortran-${GCC_VERSION} \
    flex bison cmake ca-certificates wget \
    zlib1g-dev libboost-system-dev libboost-thread-dev \
    #NoOpenMPI as MPICH will be used: libopenmpi-dev openmpi-bin \
    gnuplot libreadline-dev libncurses-dev libxt-dev \
    qtbase5-dev qtchooser qt5-qmake qtbase5-dev-tools \
    libqt5opengl5-dev \
    libgl1-mesa-dev libglu1-mesa-dev freeglut3-dev \
    libcgal-dev libfftw3-dev \
    #For Catalyst (and therefore ParaView):
    python3-dev \
# Additional dependencies listed in ThirdParty-xxx/Requirements.md (not repeating):
    qttools5-dev qttools5-dev-tools libqt5x11extras5-dev \
# Additional dependencies found when building the image:
    #For compiling ParaView (Qt5 GUI support & xmlpatterns library):
    libqt5svg5-dev qtxmlpatterns5-dev-tools \
    #For compiling OpenFOAM (to include FlexLexer.h):
    libfl-dev \
# cleaning at the end:
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*


#---------------------------------------------------------------
# B.2 Select the Ubuntu 24.04 default compiler family for all subsequent build stages
# GCC 13 is the default GCC family for Ubuntu 24.04.
# Versioned packages and an isolated command directory ensure that this exact
# compiler family is selected explicitly instead of relying on unversioned defaults.
# Recall global definitions made at the top
ARG GCC_VERSION
# Create an isolated command directory for the selected compiler version
RUN mkdir -p /opt/gcc${GCC_VERSION}/bin \
 && ln -sf /usr/bin/gcc-${GCC_VERSION} /opt/gcc${GCC_VERSION}/bin/gcc \
 && ln -sf /usr/bin/g++-${GCC_VERSION} /opt/gcc${GCC_VERSION}/bin/g++ \
 && ln -sf /usr/bin/gcc-${GCC_VERSION} /opt/gcc${GCC_VERSION}/bin/cc \
 && ln -sf /usr/bin/g++-${GCC_VERSION} /opt/gcc${GCC_VERSION}/bin/c++ \
 && ln -sf /usr/bin/gfortran-${GCC_VERSION} /opt/gcc${GCC_VERSION}/bin/gfortran \
 && ln -sf /usr/bin/gfortran-${GCC_VERSION} /opt/gcc${GCC_VERSION}/bin/f95 \
 && ln -sf /usr/bin/gfortran-${GCC_VERSION} /opt/gcc${GCC_VERSION}/bin/f77

ENV PATH="/opt/gcc${GCC_VERSION}/bin:${PATH}"
ENV CC="gcc"
ENV CXX="g++"
ENV FC="gfortran"
ENV F77="gfortran"
ENV F90="gfortran"

# Validate the selected compiler family and display the compilers used by the MPI wrappers
RUN test "$(command -v gcc)" = "/opt/gcc${GCC_VERSION}/bin/gcc" \
 && test "$(command -v g++)" = "/opt/gcc${GCC_VERSION}/bin/g++" \
 && test "$(command -v gfortran)" = "/opt/gcc${GCC_VERSION}/bin/gfortran" \
 && test "$(gcc -dumpfullversion -dumpversion | cut -d. -f1)" = "$GCC_VERSION" \
 && test "$(g++ -dumpfullversion -dumpversion | cut -d. -f1)" = "$GCC_VERSION" \
 && test "$(gfortran -dumpfullversion -dumpversion | cut -d. -f1)" = "$GCC_VERSION" \
 && gcc -dumpfullversion -dumpversion \
 && g++ -dumpfullversion -dumpversion \
 && gfortran -dumpfullversion -dumpversion \
 && mpicc -show \
 && mpicxx -show


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
#Change to the installation dir, download OpenFOAM and untar
WORKDIR $OF_INSTALL_DIR
RUN wget --no-hsts -O OpenFOAM-${OF_VERSION}.tgz \
    "https://sourceforge.net/projects/openfoam/files/OpenFOAM-${OF_VERSION}.tgz/download" \
 && tar -xvzf OpenFOAM-${OF_VERSION}.tgz \
 && rm -f OpenFOAM-${OF_VERSION}.tgz

RUN wget --no-hsts -O ThirdParty-${OF_VERSION}.tgz \
    "https://sourceforge.net/projects/openfoam/files/ThirdParty-${OF_VERSION}.tgz/download" \
 && tar -xvzf ThirdParty-${OF_VERSION}.tgz \
 && rm -f ThirdParty-${OF_VERSION}.tgz


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
ARG WM_LABEL_SIZE
ARG WM_PRECISION_OPTION
ARG WM_COMPILE_OPTION
# Auxiliary arguments
ARG OF_PREFS_TEMPLATE="${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/config.sh/example/prefs.sh"
ARG OF_PREFS_FILE="${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/prefs.sh"
ARG OF_PREFS_HEADER_LINES=26

# Validate the supported OpenFOAM compilation settings before using them
RUN case "$WM_LABEL_SIZE" in \
      32|64) ;; \
      *) echo "ERROR: Invalid WM_LABEL_SIZE='$WM_LABEL_SIZE'. Supported values: 32, 64." >&2; exit 1 ;; \
    esac \
 && case "$WM_PRECISION_OPTION" in \
      DP|SP|SPDP) ;; \
      *) echo "ERROR: Invalid WM_PRECISION_OPTION='$WM_PRECISION_OPTION'. Supported values: DP, SP, SPDP." >&2; exit 1 ;; \
    esac \
 && case "$WM_COMPILE_OPTION" in \
      Opt|Debug|Prof) ;; \
      *) echo "ERROR: Invalid WM_COMPILE_OPTION='$WM_COMPILE_OPTION'. Supported values: Opt, Debug, Prof." >&2; exit 1 ;; \
    esac

#Updating the prefs.sh file
RUN head -${OF_PREFS_HEADER_LINES} $OF_PREFS_TEMPLATE > $OF_PREFS_FILE \
 && echo '#------------------------------------------------------------------------------' >> ${OF_PREFS_FILE} \
#Defining the OpenFOAM compilation settings selected for this image:
 && echo "export WM_LABEL_SIZE=${WM_LABEL_SIZE}" >> ${OF_PREFS_FILE} \
 && echo "export WM_PRECISION_OPTION=${WM_PRECISION_OPTION}" >> ${OF_PREFS_FILE} \
 && echo "export WM_COMPILE_OPTION=${WM_COMPILE_OPTION}" >> ${OF_PREFS_FILE} \
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
 && echo 'export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX -DOMPI_SKIP_MPICXX"' >> ${OF_PREFS_FILE} \
## && echo 'export MPI_ARCH_INC="-isystem $MPI_ROOT/include"' >> ${OF_PREFS_FILE} \
## && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpi -lrt"' >> ${OF_PREFS_FILE} \
#
#  ~(C)Even further modifications needed for some OpenFOAM and compiler versions:
#..If the gcc compiler has problems with the -isystem flag, use -I instead:
 && echo 'export MPI_ARCH_INC="-I ${MPI_ROOT}/include"' >> ${OF_PREFS_FILE} \
#..Use only one library path and plus -lmpich
## && echo 'export MPI_ARCH_LIBS="-L$MPI_ROOT/lib -lmpich"' >> ${OF_PREFS_FILE} \
#..Use the two library paths and plus -lmpich
 && echo 'export MPI_ARCH_LIBS="-L${MPI_ROOT}/lib${WM_COMPILER_LIB_ARCH} -L${MPI_ROOT}/lib -lmpich -lrt"' >> ${OF_PREFS_FILE} \
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
 && sed -i 's/^projectDir=/# projectDir=/g' ${OF_BASHRC_FILE} \
 && sed -i '0,/\[ -n "$projectDir"/s//# \[ -n "$projectDir"/' ${OF_BASHRC_FILE} \
 && sed -i '0,/^# projectDir="$HOME.*/!b;//a\projectDir="'"${OF_INSTALL_DIR}"'/OpenFOAM-$WM_PROJECT_VERSION"' ${OF_BASHRC_FILE} \
#Changing the place for your own tools/solvers (WM_PROJECT_USER_DIR directory) within the bashrc file
#IMPORTANT:When using this container, you have two options when building your own tools/solvers:
#   1. You can mount a directory of your local-host into this directory (as explained at the end of the Dockerfile)
#   2. Or you can include and build stuff inside the container and save it as your own image for later use.
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
FROM update_settings AS third_party_install
#---------------------------------------------------------------
# Recall global definitions made at the top
ARG OF_BASHRC_FILE
ARG WM_LABEL_SIZE
ARG WM_PRECISION_OPTION
ARG WM_COMPILE_OPTION
# Auxiliary arguments
ARG BASHRC_OPTIONS=""
# USER_BUILD_ARG
ARG TP_COMPILE_TASKS="16"

#---------------------------------------------------------------
#Using bash to interpret OpenFOAM scripts
#Also, using the `pipefail` option to avoid losing errors in the compilation commands when using `tee` and/or piped commands
SHELL ["/bin/bash","-o","pipefail","-c"]

#---------------------------------------------------------------
# E.1 Validate and display the effective OpenFOAM compilation settings
# These 3 settings have been defined as USER_BUILD_ARG and can be set at the top
# or overridden with `--build-arg` when using the building script. Or directly
# in the command line when using `docker build` or `podman build`.
RUN expectedWM_LABEL_SIZE="${WM_LABEL_SIZE}" \
 && expectedWM_PRECISION_OPTION="${WM_PRECISION_OPTION}" \
 && expectedWM_COMPILE_OPTION="${WM_COMPILE_OPTION}" \
 && source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
 && test "$WM_LABEL_SIZE" = "$expectedWM_LABEL_SIZE" \
 && test "$WM_PRECISION_OPTION" = "$expectedWM_PRECISION_OPTION" \
 && test "$WM_COMPILE_OPTION" = "$expectedWM_COMPILE_OPTION" \
 && echo "WM_LABEL_SIZE=$WM_LABEL_SIZE" \
 && echo "WM_PRECISION_OPTION=$WM_PRECISION_OPTION" \
 && echo "WM_COMPILE_OPTION=$WM_COMPILE_OPTION" \
 && echo "WM_OPTIONS=$WM_OPTIONS"

#---------------------------------------------------------------
# E.2 Third-Party compilation
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
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
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
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
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
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
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
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
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
# Recall global definitions made at the top
ARG OF_BASHRC_FILE
# Auxiliary arguments
ARG BASHRC_OPTIONS=""
# Defining the maximum number of parallel tasks to use for compilation
# USER_BUILD_ARG
ARG PV_COMPILE_TASKS=16
#NotAcceptedBy makeParaView:#ARG PV_COMPILE_OPTIONS="-j${PV_COMPILE_TASKS}"
#NotWorkingAsWished: #ARG PV_COMPILE_OPTIONS="-DCMAKE_BUILD_PARALLEL_LEVEL=${PV_COMPILE_TASKS}"
#                    Then, CMAKE_BUILD_PARALLEL_LEVEL will be exported directly in the RUN instruction with the correct value


#---------------------------------------------------------------
#ParaView or VTK historically needed for runTimePostprocessing of OpenFOAM to properly compile
#Paraview needed for graphical postprocessing to be available in the container
#Paraview needed for catalyst module to properly compile (wont work with just VTK)

#---------------------------------------------------------------
#Using bash to interpret OpenFOAM scripts
#Also, using the `pipefail` option to avoid losing errors in the compilation commands when using `tee` and/or piped commands
SHELL ["/bin/bash","-o","pipefail","-c"]

#---------------------------------------------------------------
# F.1 Validate and prepare the ParaView build environment.
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Bootstrap the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
# Continue from the ThirdParty directory:
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt5 \
# Change makeParaView to use Bash because it has historically contained bashisms:
 && cp makeParaView makeParaView.original \
 && sed -i '1s|/bin/sh|/bin/bash|' makeParaView \
# Create the basic python command name required by the ParaView build:
 && ln -sf /usr/bin/python3 /usr/bin/python \
# Find and validate the Python shared library:
 && PYTHON_LIB=$(find /usr/lib/x86_64-linux-gnu \
      -name 'libpython3.*.so' | head -1) \
 && test -n "$PYTHON_LIB" \
 && test -f "$PYTHON_LIB" \
 && echo "Using PYTHON_LIB=$PYTHON_LIB" \
# Find and validate the MPI compiler wrappers supplied by the MPICH base image:
 && MPI_C_COMPILER=$(command -v mpicc) \
 && MPI_CXX_COMPILER=$(command -v mpicxx) \
 && test -n "$MPI_C_COMPILER" \
 && test -n "$MPI_CXX_COMPILER" \
 && test -x "$MPI_C_COMPILER" \
 && test -x "$MPI_CXX_COMPILER" \
 && echo "Using MPI_C_COMPILER=$MPI_C_COMPILER" \
 && echo "Using MPI_CXX_COMPILER=$MPI_CXX_COMPILER" \
# Display the compiler, include, and library settings used by the MPI wrappers:
 && "$MPI_C_COMPILER" -show \
 && "$MPI_CXX_COMPILER" -show \
# Display build-resource information:
 && echo "Available processors: $(nproc)" \
 && echo "Configured parallel compilation tasks: ${PV_COMPILE_TASKS}" \
 && echo "Open file soft limit: $(ulimit -Sn)" \
 && echo "Open file hard limit: $(ulimit -Hn)" \
 && grep -i 'Max open files' /proc/self/limits

#---------------------------------------------------------------
# F.2 ParaView compilation
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

# First ParaView preliminary compilation pass, performed in parallel.
# A compilation failure is recorded but does not stop the image build,
# allowing partial build products to be committed into this layer.
ARG PV_PASS_NUMBER="1"
ARG PV_PASS_TASKS="${PV_COMPILE_TASKS}"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Continue from the component source directory:
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt5 \
 && PYTHON_LIB=$(find /usr/lib/x86_64-linux-gnu \
      -name 'libpython3.*.so' | head -1) \
 && MPI_C_COMPILER=$(command -v mpicc) \
 && MPI_CXX_COMPILER=$(command -v mpicxx) \
 && export CMAKE_BUILD_PARALLEL_LEVEL=${PV_PASS_TASKS} \
 && { \
      passInfo="pass-${PV_PASS_NUMBER}-tasks-${PV_PASS_TASKS}"; \
      passLog="log.makePV.${passInfo}"; \
      sentinelFile="$WM_THIRD_PARTY_DIR/.paraview-preliminary-compilation-succeeded"; \
      if [[ -f "$sentinelFile" ]]; then \
          echo "Skipping ParaView preliminary compilation $passInfo."; \
          echo "First successful preliminary compilation: $(cat "$sentinelFile")"; \
          printf '%s\n' "SKIPPED" > "${passLog}.status"; \
          exit 0; \
      fi; \
      echo "Starting ParaView preliminary compilation $passInfo"; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_BEGIN component=ParaView pass=${PV_PASS_NUMBER}"; \
      rebuildOption=""; \
      if (( PV_PASS_NUMBER > 1 )); then rebuildOption="-rebuild"; fi; \
      # ----- The compilation command:
      ./makeParaView $rebuildOption \
          -mpi \
          -python \
          -python-lib "$PYTHON_LIB" \
          -DMPI_C_COMPILER="$MPI_C_COMPILER" \
          -DMPI_CXX_COMPILER="$MPI_CXX_COMPILER" 2>&1 | tee "$passLog"; \
      compileStatus=${PIPESTATUS[0]}; \
      echo "ParaView preliminary compilation $passInfo exit status: $compileStatus"; \
      printf '%s\n' "$compileStatus" > "${passLog}.exit-status"; \
      if [[ $compileStatus -eq 0 ]]; then \
          printf '%s\n' "$passInfo" > "$sentinelFile"; \
          echo "ParaView preliminary compilation $passInfo completed successfully."; \
          echo "Later preliminary compilation passes can be skipped."; \
      else \
          echo "WARNING: ParaView preliminary compilation $passInfo failed with exit status $compileStatus."; \
          echo "Partial compilation results will be retained for the next compilation pass."; \
      fi; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_END component=ParaView pass=${PV_PASS_NUMBER}"; \
      exit 0; \
    }

# Second ParaView preliminary compilation pass, performed in parallel.
# A compilation failure is recorded but does not stop the image build,
# allowing partial build products to be committed into this layer.
ARG PV_PASS_NUMBER="2"
ARG PV_PASS_TASKS="${PV_COMPILE_TASKS}"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Continue from the component source directory:
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt5 \
 && PYTHON_LIB=$(find /usr/lib/x86_64-linux-gnu \
      -name 'libpython3.*.so' | head -1) \
 && MPI_C_COMPILER=$(command -v mpicc) \
 && MPI_CXX_COMPILER=$(command -v mpicxx) \
 && export CMAKE_BUILD_PARALLEL_LEVEL=${PV_PASS_TASKS} \
 && { \
      passInfo="pass-${PV_PASS_NUMBER}-tasks-${PV_PASS_TASKS}"; \
      passLog="log.makePV.${passInfo}"; \
      sentinelFile="$WM_THIRD_PARTY_DIR/.paraview-preliminary-compilation-succeeded"; \
      if [[ -f "$sentinelFile" ]]; then \
          echo "Skipping ParaView preliminary compilation $passInfo."; \
          echo "First successful preliminary compilation: $(cat "$sentinelFile")"; \
          printf '%s\n' "SKIPPED" > "${passLog}.status"; \
          exit 0; \
      fi; \
      echo "Starting ParaView preliminary compilation $passInfo"; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_BEGIN component=ParaView pass=${PV_PASS_NUMBER}"; \
      rebuildOption=""; \
      if (( PV_PASS_NUMBER > 1 )); then rebuildOption="-rebuild"; fi; \
      # ----- The compilation command:
      ./makeParaView $rebuildOption \
          -mpi \
          -python \
          -python-lib "$PYTHON_LIB" \
          -DMPI_C_COMPILER="$MPI_C_COMPILER" \
          -DMPI_CXX_COMPILER="$MPI_CXX_COMPILER" 2>&1 | tee "$passLog"; \
      compileStatus=${PIPESTATUS[0]}; \
      echo "ParaView preliminary compilation $passInfo exit status: $compileStatus"; \
      printf '%s\n' "$compileStatus" > "${passLog}.exit-status"; \
      if [[ $compileStatus -eq 0 ]]; then \
          printf '%s\n' "$passInfo" > "$sentinelFile"; \
          echo "ParaView preliminary compilation $passInfo completed successfully."; \
          echo "Later preliminary compilation passes can be skipped."; \
      else \
          echo "WARNING: ParaView preliminary compilation $passInfo failed with exit status $compileStatus."; \
          echo "Partial compilation results will be retained for the next compilation pass."; \
      fi; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_END component=ParaView pass=${PV_PASS_NUMBER}"; \
      exit 0; \
    }

# Third ParaView preliminary compilation pass, performed in serial.
# A compilation failure is recorded but does not stop the image build,
# allowing partial build products to be committed into this layer.
ARG PV_PASS_NUMBER="3"
ARG PV_PASS_TASKS="1"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Continue from the component source directory:
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt5 \
 && PYTHON_LIB=$(find /usr/lib/x86_64-linux-gnu \
      -name 'libpython3.*.so' | head -1) \
 && MPI_C_COMPILER=$(command -v mpicc) \
 && MPI_CXX_COMPILER=$(command -v mpicxx) \
 && export CMAKE_BUILD_PARALLEL_LEVEL=${PV_PASS_TASKS} \
 && { \
      passInfo="pass-${PV_PASS_NUMBER}-tasks-${PV_PASS_TASKS}"; \
      passLog="log.makePV.${passInfo}"; \
      sentinelFile="$WM_THIRD_PARTY_DIR/.paraview-preliminary-compilation-succeeded"; \
      if [[ -f "$sentinelFile" ]]; then \
          echo "Skipping ParaView preliminary compilation $passInfo."; \
          echo "First successful preliminary compilation: $(cat "$sentinelFile")"; \
          printf '%s\n' "SKIPPED" > "${passLog}.status"; \
          exit 0; \
      fi; \
      echo "Starting ParaView preliminary compilation $passInfo"; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_BEGIN component=ParaView pass=${PV_PASS_NUMBER}"; \
      rebuildOption=""; \
      if (( PV_PASS_NUMBER > 1 )); then rebuildOption="-rebuild"; fi; \
      # ----- The compilation command:
      ./makeParaView $rebuildOption \
          -mpi \
          -python \
          -python-lib "$PYTHON_LIB" \
          -DMPI_C_COMPILER="$MPI_C_COMPILER" \
          -DMPI_CXX_COMPILER="$MPI_CXX_COMPILER" 2>&1 | tee "$passLog"; \
      compileStatus=${PIPESTATUS[0]}; \
      echo "ParaView preliminary compilation $passInfo exit status: $compileStatus"; \
      printf '%s\n' "$compileStatus" > "${passLog}.exit-status"; \
      if [[ $compileStatus -eq 0 ]]; then \
          printf '%s\n' "$passInfo" > "$sentinelFile"; \
          echo "ParaView preliminary compilation $passInfo completed successfully."; \
          echo "Later preliminary compilation passes can be skipped."; \
      else \
          echo "WARNING: ParaView preliminary compilation $passInfo failed with exit status $compileStatus."; \
          echo "Partial compilation results will be retained for the next compilation pass."; \
      fi; \
      echo "OPENFOAM_BUILD_SCAN_IGNORE_END component=ParaView pass=${PV_PASS_NUMBER}"; \
      exit 0; \
    }

# This final pass is performed in parallel and its failure is not masked.
# With pipefail enabled, a failure from makeParaView stops the building process.
ARG PV_PASS_NUMBER="authoritative"
ARG PV_PASS_TASKS="${PV_COMPILE_TASKS}"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt5 \
 && PYTHON_LIB=$(find /usr/lib/x86_64-linux-gnu \
      -name 'libpython3.*.so' | head -1) \
 && export CMAKE_BUILD_PARALLEL_LEVEL=${PV_PASS_TASKS} \
 && echo "Starting authoritative ParaView compilation pass" \
 && echo "CMAKE_BUILD_PARALLEL_LEVEL=$CMAKE_BUILD_PARALLEL_LEVEL" \
 && ./makeParaView \
      -rebuild \
      -mpi \
      -python \
      -python-lib "$PYTHON_LIB" \
      2>&1 | tee log.makePV.AuthoritativeSummary


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# G. OpenFOAM compilation
FROM pv_install AS of_install
#FROM third_party_install AS of_install
#---------------------------------------------------------------
# Recall global definitions made at the top
ARG OF_BASHRC_FILE
ARG WM_LABEL_SIZE
ARG WM_PRECISION_OPTION
ARG WM_COMPILE_OPTION
# Auxiliary arguments
# USER_BUILD_ARG
ARG OF_COMPILE_TASKS=16
ARG BASHRC_OPTIONS=""

#---------------------------------------------------------------
#Using bash to interpret OpenFOAM scripts
#Also, using the `pipefail` option to avoid losing errors in the compilation commands when using `tee` and/or piped commands
SHELL ["/bin/bash","-o","pipefail","-c"]

#---------------------------------------------------------------
# G.1 Preparatory updates
# Setting shebang to bash in Allwmake.
# This because compilation of "Additional components/modules" used to fail in previous versions due to bash-isms.
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && cp Allwmake Allwmake.original \
 && sed -i '1s|/bin/sh|/bin/bash|' Allwmake

#---------------------------------------------------------------
# G.2 Validate and display the effective OpenFOAM compilation settings
# These 3 settings have been defined as USER_BUILD_ARG and can be set at the top
# or overridden with `--build-arg` when using the building script. Or directly
# in the command line when using `docker build` or `podman build`.
RUN expectedWM_LABEL_SIZE="${WM_LABEL_SIZE}" \
 && expectedWM_PRECISION_OPTION="${WM_PRECISION_OPTION}" \
 && expectedWM_COMPILE_OPTION="${WM_COMPILE_OPTION}" \
 && source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
 && test "$WM_LABEL_SIZE" = "$expectedWM_LABEL_SIZE" \
 && test "$WM_PRECISION_OPTION" = "$expectedWM_PRECISION_OPTION" \
 && test "$WM_COMPILE_OPTION" = "$expectedWM_COMPILE_OPTION" \
 && echo "WM_LABEL_SIZE=$WM_LABEL_SIZE" \
 && echo "WM_PRECISION_OPTION=$WM_PRECISION_OPTION" \
 && echo "WM_COMPILE_OPTION=$WM_COMPILE_OPTION" \
 && echo "WM_OPTIONS=$WM_OPTIONS"

#---------------------------------------------------------------
# G.3 OpenFOAM compilation
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
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
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
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
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
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
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
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
# Continue:
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && echo "Starting authoritative OpenFOAM summary compilation pass" \
 && ./Allwmake -j"$OF_PASS_TASKS" 2>&1 | tee log.Allwmake.AuthoritativeSummary

#---------------------------------------------------------------
# G.4 Checking if a popular executable is working
ARG OF_TOOL="icoFoam"
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && $OF_TOOL -help 2>&1 | tee log.OF_TOOL

#---------------------------------------------------------------
# G.5 Printing out the environment variables for the installation so far:
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
ARG IMAGE_BUILD_INFO_DIR
# Auxiliary arguments
ARG RECIPE_FILE="${OF_FORK}--${OF_VERSION}.dockerfile"
ARG FORK_IMAGE_BUILD_INFO_DIR="${IMAGE_BUILD_INFO_DIR}/${OF_FORK}"
# Copy all files used to build the image into the internal backup directory
RUN mkdir -p "$FORK_IMAGE_BUILD_INFO_DIR"
COPY $RECIPE_FILE \
     $ENTRYPOINT_FILE_TEMPLATE \
     $ENVIRONMENT_FILE_TEMPLATE \
     $FORK_IMAGE_BUILD_INFO_DIR

#---------------------------------------------------------------
# H.5 Recording the effective values of the global build arguments in file $IMAGE_BUILD_INFO_DIR/image-build-arguments.txt
# The argument names are read automatically from the global ARG
# declarations located before the first FROM instruction.
# Global arguments marked with USER_BUILD_ARG are supported user overrides.
# Other global arguments are fixed recipe settings, but their effective values are also recorded.
# Every global argument MUST ALSO be recalled in this section for the recording to work.
# If a developer adds a new global ARG at the top, but does not recall it here,
# the build stops with an explanatory error instead of generating
# an incomplete build-arguments record.

# Recall all global build arguments defined before the first FROM
# in order to have a full match in the list to be recorded by the RUN instruction immediately below.
ARG OF_FORK
ARG OF_VERSION
ARG GCC_VERSION
ARG WM_LABEL_SIZE
ARG WM_PRECISION_OPTION
ARG WM_COMPILE_OPTION
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
ARG IMAGE_BUILD_INFO_DIR

# Auxiliary arguments
ARG INTERNAL_RECIPE_FILE="${FORK_IMAGE_BUILD_INFO_DIR}/${OF_FORK}--${OF_VERSION}.dockerfile"
ARG ARGUMENTS_FILE="${FORK_IMAGE_BUILD_INFO_DIR}/image-build-arguments.txt"

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
      "# Arguments marked with USER_BUILD_ARG in the recipe are supported user overrides." \
      "# Other arguments are fixed recipe settings whose effective values are recorded for provenance." \
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
ARG GCC_VERSION
ARG WM_LABEL_SIZE
ARG WM_PRECISION_OPTION
ARG WM_COMPILE_OPTION
ARG BASE_IMAGE_MPICH_VERSION
ARG BASE_IMAGE_OS_VERSION
ARG IMAGE_BUILD_INFO_DIR

# Labels:
LABEL org.opencontainers.image.authors="Alexis Espinosa <Alexis.Espinosa@pawsey.org.au>"
LABEL org.opencontainers.image.title="${OF_FORK}"
LABEL org.opencontainers.image.version="${OF_VERSION}-gcc${GCC_VERSION}${WM_PRECISION_OPTION}Int${WM_LABEL_SIZE}${WM_COMPILE_OPTION}-mpich${BASE_IMAGE_MPICH_VERSION}-ubuntu${BASE_IMAGE_OS_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/PawseySC/pawsey-containers"
LABEL au.org.pawsey.image.build-info-dir="${IMAGE_BUILD_INFO_DIR}"

#---------------------------------------------------------------
# H.7 Starting as OF_USER by default
# Recall global definitions made at the top
ARG OF_USER
# Avoid permission problems with the home directory of OF_USER
RUN chmod -R a+rwX /home/$OF_USER
# Starting as OF_USER by default
USER $OF_USER
WORKDIR /home/$OF_USER
