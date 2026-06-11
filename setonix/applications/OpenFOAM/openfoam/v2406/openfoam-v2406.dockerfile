#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# 0. Initial main definition of global parameters
# IMPORTANT: All these settings can be overriden with the use of `--build-arg <Name>=<Value>`
# IMPORTANT: Recipe needs to re-call them at each stage to recover their values
# 0.1 Main global arguments (related to the OpenFOAM version)
ARG OF_FORK="openfoam"
ARG OF_VERSION="v2406"

# 0.1 Main arguments related to the base container to use
# Defining the base container to use
# IMPORTANT: Setonix mpi containers need at least ubuntu24.04 (From August 2025)
ARG BASE_IMAGE_REGISTRY="quay.io/pawsey"
ARG BASE_IMAGE_NAME="mpich-base"
ARG BASE_IMAGE_OS_VERSION="24.04"
ARG BASE_IMAGE_MPICH_VERSION="3.4.3"
ARG BASE_IMAGE_TAG="${BASE_IMAGE_MPICH_VERSION}_ubuntu${BASE_IMAGE_OS_VERSION}"
ARG BASE_IMAGE_FULL="${BASE_IMAGE_REGISTRY}/${BASE_IMAGE_NAME}:${BASE_IMAGE_TAG}"

#---------------------------------------------------------------
# 0.2 Auxiliary global arguments of definitions used in multiple stages
ARG OF_INSTALL_DIR="/opt/OpenFOAM"
ARG OF_USER="ofuser"
ARG OF_USER_DIR="/home/${OF_USER}/OpenFOAM/${OF_USER}-${OF_VERSION}"
ARG OF_BASHRC_FILE="${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/bashrc"
ARG OF_PREFS_FILE="${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/prefs.sh"
ARG OF_CONTROL_FILE="${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/controlDict"

# 0.3 Other auxiliary variables to ease building
ARG COMPILE_TASKS="16"
ARG DOCKER_RECIPES_DIR="/opt/docker-recipes"
ARG OS_VERSION=$BASE_IMAGE_OS_VERSION


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# A. Basic Stage.
FROM $BASE_IMAGE_FULL AS basic_stage
#---------------------------------------------------------------
# A.1 Defining documented labels
# Recall global definitions made at the top
ARG OF_FORK
ARG OF_VERSION
ARG OS_VERSION
ARG DOCKER_RECIPES_DIR

# Labels:
LABEL org.opencontainers.image.authors="Alexis Espinosa <Alexis.Espinosa@pawsey.org.au>"
LABEL org.opencontainers.image.name="${OF_FORK}"
LABEL org.opencontainers.image.branch="${OF_VERSION}-ubuntu${OS_VERSION}"
LABEL org.opencontainers.image.dockerfile-internal-backup="${DOCKER_RECIPES_DIR}"
LABEL org.opencontainers.image.git-repository="https://github.com/PawseySC/pawsey-containers"

#---------------------------------------------------------------
# A.2 Installing additional tools useful for interactive sessions
#     and the check of bashisms in scripts
RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq \
 &&  apt-get -y --no-install-recommends install \
            vim time \
            cron gosu \
            bc curl wget \
            git devscripts \
# cleaning at the end:
 && apt-get clean all \
 && rm -r /var/lib/apt/lists/*
             
#---------------------------------------------------------------
# A.3 Setting a user for interactive sessions and development of own tools
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
# OpenFOAM v2406+ dependencies for Ubuntu 24.04 LTS
# Aggregated from:
# [1] https://develop.openfoam.com/Development/openfoam/-/blob/maintenance-v2406/doc/Build.md
# [2] https://develop.openfoam.com/Development/ThirdParty-common/-/blob/v2406/Requirements.md
# [3] https://www.openfoam.com/news/main-news/openfoam-v2406
# [4] https://gitlab.com/openfoam/core/openfoam/-/blob/master/doc/Build.md
# [5] https://develop.openfoam.com/Development/ThirdParty-common/blob/develop/BUILD.md
# [6] https://openfoamwiki.net/index.php/Installation/Linux/OpenFOAM-v1806/Ubuntu (Last documented instructions in the wiki)
RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq \
 && apt-get --no-install-recommends --no-install-suggests --yes install \
    build-essential flex bison cmake ca-certificates wget \
    zlib1g-dev libboost-system-dev libboost-thread-dev \
    #NoOpenMPI as MPICH will be used: libopenmpi-dev openmpi-bin \
    libopenmpi-dev openmpi-bin \
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
#---------------------------------------------------------------
#---------------------------------------------------------------
# C. Download OpenFOAM source-files
FROM install_dependencies AS download
#---------------------------------------------------------------
# C.1 Download
# Recall global definitions made on the top
ARG OF_VERSION
ARG OF_INSTALL_DIR
#Change to the installation dir, download OpenFOAM and untar
WORKDIR $OF_INSTALL_DIR
RUN wget --no-check-certificate -O OpenFOAM-${OF_VERSION}.tgz \
    "https://sourceforge.net/projects/openfoam/files/OpenFOAM-${OF_VERSION}.tgz/download" \
 && tar -xvzf OpenFOAM-${OF_VERSION}.tgz \
 && rm -f OpenFOAM-${OF_VERSION}.tgz \
 && wget --no-check-certificate -O ThirdParty-${OF_VERSION}.tgz \
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
ARG OF_PREFS_FILE
# Defining the template
ARG OF_PREFS_TEMPLATE=${OF_INSTALL_DIR}/OpenFOAM-${OF_VERSION}/etc/config.sh/example/prefs.sh
ARG OF_PREFS_HEADER_LINES=26

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
ARG OF_CONTROL_FILE

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
#Install Third Party tools (preferred to do it as a separate step and not together with the full openfoam compilation) 
FROM update_settings AS third_party_install
#---------------------------------------------------------------
# Recall global definitions made at the top
ARG OF_BASHRC_FILE
ARG COMPILE_TASKS
# Auxiliary arguments
ARG BASHRC_OPTIONS=""
ARG TP_COMPILE_OPTIONS="-j${COMPILE_TASKS}"

#---------------------------------------------------------------
#Using bash to interpret OpenFOAM scripts
SHELL ["/bin/bash","-c"]

#---------------------------------------------------------------
# Third party compilation
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Bootstrap to the wmake toolchain (see ThirdParty-xx/README.md):
 && $WM_PROJECT_DIR/wmake/src/Allmake \
# Install the ThirdParty tools:
 && cd $WM_THIRD_PARTY_DIR \
 && ./Allwmake $TP_COMPILE_OPTIONS 2>&1 | tee log.Allwmake

# Obtaining a Summary in a final compilation pass
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Bootstrap to the wmake toolchain (see ThirdParty-xx/README.md):
 && $WM_PROJECT_DIR/wmake/src/Allmake \
# Install the ThirdParty tools:
 && cd $WM_THIRD_PARTY_DIR \
 && ./Allwmake 2>&1 | tee log.AllwmakeSummary


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# F. ParaView installation
FROM third_party_install AS pv_install
#---------------------------------------------------------------
# Recall global definitions made at the top
ARG OF_BASHRC_FILE
ARG COMPILE_TASKS
# Auxiliary arguments
ARG BASHRC_OPTIONS=""
#NotAcceptedBy makeParaView:#ARG PV_COMPILE_OPTIONS="-j${COMPILE_TASKS}"
ARG PV_COMPILE_OPTIONS="-DCMAKE_BUILD_PARALLEL_LEVEL=${COMPILE_TASKS}"
#---------------------------------------------------------------
#ParaView or VTK historically needed for runTimePostprocessing of OpenFOAM to properly compile
#Paraview needed for graphical postprocessing to be available in the container
#Paraview needed for catalyst module to properly compile (wont work with just VTK)

#---------------------------------------------------------------
#Using bash to interpret OpenFOAM scripts
SHELL ["/bin/bash","-c"]

#---------------------------------------------------------------
# Paraview compilation. Adapted from OpenFoamWiki v1806 (last version documented in the wiki)
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
# Continue:
 && cd $WM_THIRD_PARTY_DIR \
 && export QT_SELECT=qt5 \
# As makeParaView failed in the past due to bash-isms, changing the script shell explicitly to bash:
 && cp makeParaView makeParaView.original \
 && sed -i '1s|/bin/sh|/bin/bash|' makeParaView \
# Create a link for basic `python` name
 && ln -sf /usr/bin/python3 /usr/bin/python \
# Obtaining the python shared library path
 && PYTHON_LIB=$(find /usr/lib/x86_64-linux-gnu -name 'libpython3.*.so' | head -1) \
 && echo "Using PYTHON_LIB in Paraview installation: $PYTHON_LIB" \
# Installing with mpi capabilities. Also with python bindings (to be able to properly compile Catalyst later)
 && ./makeParaView $PV_COMPILE_OPTIONS -mpi -python -python-lib "$PYTHON_LIB" 2>&1 | tee log.makePV


#---------------------------------------------------------------
#---------------------------------------------------------------
#---------------------------------------------------------------
# G. OpenFOAM compilation
FROM pv_install AS of_install
#FROM third_party_install AS of_install
#---------------------------------------------------------------
# Recall global definitions made at the top
ARG OF_BASHRC_FILE
ARG COMPILE_TASKS
# Auxiliary arguments
ARG OF_COMPILE_OPTIONS="-j${COMPILE_TASKS}"
ARG BASHRC_OPTIONS=""

#---------------------------------------------------------------
#Using bash to interpret OpenFOAM scripts
SHELL ["/bin/bash","-c"]

#---------------------------------------------------------------
# G.1 Updating script to bash shell.
#     This because compilation of "Additional components/modules" used to fail in previous versions due to bash-isms.
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
 && cd $WM_PROJECT_DIR \
 && cp Allwmake Allwmake.original \
 && sed -i '1s|/bin/sh|/bin/bash|' Allwmake

#---------------------------------------------------------------
# G.2 OpenFOAM compilation 
#     Adapted from OpenFoamWiki v1806 (last version documented in the wiki)
#     Using 2 compilation passes as some compilation race conditions were found.
# First pass compilation in parallel:
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
# Continue:
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && ./Allwmake $OF_COMPILE_OPTIONS 2>&1 | tee log.Allwmake.1st_pass-parallel

# Second pass compilation in serial to recover from race conditions (if any in the first pass):
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
# Bootstrap to the wmake toolchain:
 && $WM_PROJECT_DIR/wmake/src/Allmake \
# Continue:
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && ./Allwmake 2>&1 | tee log.Allwmake.2nd_pass-serial

# Obtaining a summary 
RUN source ${OF_BASHRC_FILE} ${BASHRC_OPTIONS} \
 && $WM_PROJECT_DIR/wmake/src/Allmake \
 && cd $WM_PROJECT_DIR \
 && export QT_SELECT=qt5 \
 && ./Allwmake 2>&1 | tee log.AllwmakeSummary

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
SHELL ["/bin/bash","-c"]

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
#ENTRYPOINT ["/bin/bash", "-l", "-c", "\"$@\"", "--"]
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
ARG DOCKER_RECIPES_DIR
# Copy all files used to build the image into the internal backup directory
RUN mkdir -p $DOCKER_RECIPES_DIR
COPY ${OF_FORK}-${OF_VERSION}.dockerfile \
     $ENTRYPOINT_FILE_TEMPLATE \
     $ENVIRONMENT_FILE_TEMPLATE \
     $DOCKER_RECIPES_DIR
RUN chmod -R a+rwX $DOCKER_RECIPES_DIR

#---------------------------------------------------------------
# H.5 Starting as OF_USER by default
# Recall global definitions made at the top
ARG OF_USER
# Avoid permission problems with the home directory of OF_USER
RUN chmod -R a+rwX /home/$OFUSER
# Starting as OF_USER by default
USER $OF_USER
WORKDIR /home/$OF_USER