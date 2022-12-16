FROM ubuntu:22.04

LABEL maintainer="marco.delapierre@pawsey.org.au"

RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get clean all && \
	apt-get update && \
	apt-get upgrade -y && \
	apt-get install -y \
		pandoc \
		texlive \
		texlive-bibtex-extra \
		texlive-extra-utils \
		texlive-font-utils \
		texlive-lang-english \
		texlive-pictures \
		texlive-publishers \
		texlive-science \
		texlive-xetex \
		vim \
	&& apt-get clean all && \
	apt-get purge && \
	rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

CMD ["/bin/bash"]
