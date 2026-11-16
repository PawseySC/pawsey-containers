#!/bin/bash
#Use this until the default cpe 26.03
module load cpe/26.03
#Use this until the fix is done in the singularity module of the new (2026) software stack:
export SINGULARITYENV_LD_LIBRARY_PATH=:/host_lib64:/opt/cray/pe/mpich/9.1.0/ofi/gnu/12.3/lib-abi-mpich:/opt/cray/pe/mpich/9.1.0/gtl/lib:/opt/cray/xpmem/default/lib64:/opt/cray/pe/pmi/default/lib:/opt/cray/pe/pals/default/lib:/opt/cray/libfabric/2.3.1/lib64/:$LD_LIBRARY_PATH
