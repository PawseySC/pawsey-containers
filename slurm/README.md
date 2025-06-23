# How to use this container

This container provides slurm inside a container so jobs can be launched from a container. It does this by providing slurm 
in a container (that needs to match that outside). Then by mounting the appropriate paths for authentication and configuration
slurm can be run from inside the container and behave like slurm on the host. 

For completeness, here we provide how the lmod module would add various paths for binding the libraries into the host

```lua
-- Singularity configuration START
-- LD_LIBRARY_PATH addition
local singularity_ld_path = ""
setenv("SINGULARITYENV_LD_LIBRARY_PATH", singularity_ld_path)

-- add SLURM START
singularity_bindpath = singularity_bindpath .. ",/var/run/munge/munge.socket.2,/etc/slurm"
-- add SLURM END

setenv("SINGULARITY_BINDPATH",singularity_bindpath)
```
