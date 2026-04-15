# Auxiliary recipe to test different ENTRYPOINT settings
FROM ubuntu:24.04

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