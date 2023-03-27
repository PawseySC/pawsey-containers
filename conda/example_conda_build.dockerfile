FROM continuumio/miniconda3

#update and install dependencies
RUN apt-get update && \
    apt-get install -y tar git wget libncurses-dev libbz2-dev liblzma-dev \
    gcc make zlib1g-dev libncurses5-dev libncursesw5-dev python3-pip && \
    rm -r /var/lib/apt/lists/* && \
    apt-get autoremove && \ 
    apt-get autoclean && \
    mkdir /app

WORKDIR /app

# Edit the name of the environment to suit you
RUN conda create -y --name psvcp && \
      echo "conda activate psvcp" >> ~/.bashrc

# Enable RUN commands to use the new environment
SHELL ["/bin/bash", "--login", "-c"]

# Install packages with conda. These will depend on which packages you need, so these are just an example
RUN conda install -n psvcp -y -c bioconda -c conda-forge -c r mummer4=4.0.0 \
    assemblytics=1.2.1 bwa=0.7.17 bedtools=2.29.2  seqkit  picard \
    blast=2.2.31  r-base  mosdepth  r-hash  r-parallelly r-snowfall \
    pandas  gzip && conda clean --all -y

# Install pip packages example. Delete if not needed. 
RUN pip3 install argparse regex biopython

# Example to download repo from github. Delete if not needed. 
RUN git clone https://github.com/wjian8/psvcp_v1.01.git

# Example to install samtools 1.9 from source. 
RUN wget https://sourceforge.net/projects/samtools/files/samtools/1.9/samtools-1.9.tar.bz2 && \
    tar xvjf samtools-1.9.tar.bz2 && \
    rm samtools-1.9.tar.bz2 && \
    cd samtools-1.9 && \
    make && \
    cp samtools /usr/local/bin && \
    cd ..

# The code to run when container is started. Change to the environment name you created above. 
# This command will make sure the environment will be actiated everytime you run the container. 
ENTRYPOINT ["conda", "run", "--no-capture-output", "-n", "psvcp"]
