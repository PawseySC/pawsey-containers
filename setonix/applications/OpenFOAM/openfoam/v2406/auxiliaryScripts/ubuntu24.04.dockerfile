# Auxiliary recipe to test different ENTRYPOINT & LABEL settings
ARG MY_VAR="vvv"

LABEL my.external.label="External values MY_VAR=${MY_VAR}"

FROM ubuntu:24.04

ARG MY_VAR
LABEL my.internal.label="Internal values MY_VAR=${MY_VAR}"

#Testing the use of the complex ENTRYPOINT settings
#RUN ln -s /workingDir/theDockerScript.sh /etc/profile.d/entryScript.sh
#ENTRYPOINT ["/bin/bash", "-l", "-c", "\"$@\"", "--"]
#ENTRYPOINT ["/bin/bash", "-l", "-c", "$@", "--"]
#ENTRYPOINT ["/bin/bash", "-l", "-c", "\"$*\"", "--"]
#ENTRYPOINT ["/bin/bash", "-l", "-c", "$*", "--"]

#Testing the use of a direct entrypoint script
RUN ln -s /workingDir/theDockerScript.sh /usr/local/bin/entryScript.sh
ENTRYPOINT ["/usr/local/bin/entryScript.sh"]

#Testing with Singularity
RUN mkdir -p /.singularity.d/env
RUN ln -s /workingDir/theSingularityScript.sh /.singularity.d/env/91-environment.sh

CMD ["/bin/bash"]