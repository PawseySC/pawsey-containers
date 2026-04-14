# Auxiliary recipe to test different ENTRYPOINT settings
FROM ubuntu:24.04

#RUN ln -s /workingDir/theDockerScript.sh /usr/local/bin/entryScript.sh
#ENTRYPOINT [/usr/local/bin/entryScript.sh]

RUN ln -s /workingDir/theDockerScript.sh /etc/profile.d/entryScript.sh
ENTRYPOINT ["/bin/bash", "-l", "-c", "\"$@\"", "--"]
#ENTRYPOINT ["/bin/bash", "-l", "-c", "$@", "--"]
#ENTRYPOINT ["/bin/bash", "-l", "-c", "\"$*\"", "--"]
#ENTRYPOINT ["/bin/bash", "-l", "-c", "$*", "--"]

CMD ["/bin/bash"]