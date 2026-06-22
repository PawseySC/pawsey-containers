#!/bin/bash --login
#SBATCH --job-name=T03_metal-vs-cntr
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --time=00:20:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-test_03-%j.out

set -euo pipefail

MPICH_VERSION="3.4.3"
#MPICH_VERSION="4.2.2"
OS_VERSION="24.04"
IMAGE_NAME="mpich-base"
IMAGE_BRANCH="${MPICH_VERSION}-ubuntu${OS_VERSION}"
IMAGE_DIR="${MYSCRATCH}/pawsey-containers/setonix/mpi/mpich-base/ignore/singularity"
#IMAGE_DIR="../ignore/singularity"
SINGULARITY_IMAGE="${IMAGE_DIR}/${IMAGE_NAME}--${IMAGE_BRANCH}.sif"
if [[ -f $SINGULARITY_IMAGE ]]; then
    echo "Using image: $SINGULARITY_IMAGE"
else
    echo "Singularity image not found: $SINGULARITY_IMAGE"
    exit 1
fi

module load singularity/4.1.0-mpi
[[ "$PAWSEY_CLUSTER" == "joey" ]] && source common.Joey.settings.sh
module list

echo "=== Build native binary with Cray wrapper cc ==="
theMetalExe="mpi_perf_compare.metal.exe"
cc -O3 "${theMetalExe%.metal.exe}.c" -o $theMetalExe

echo
echo "=== Build container binary with container mpicc ==="
theImageExe="mpi_perf_compare.image.exe"
singularity exec "${SINGULARITY_IMAGE}" mpicc -O3 "${theImageExe%.image.exe}.c" -o $theImageExe

echo
echo "=== Container binary linkage ==="
fileOutLinkage="res_test_03.linkage.out"
singularity exec "${SINGULARITY_IMAGE}" bash -lc "
ldd ./${theImageExe}"' | egrep "mpi|fabric|cxi|pmi|pmix|pals|xpmem" || true
' | tee $fileOutLinkage

grep -q "/opt/cray/pe/mpich" $fileOutLinkage
grep -q "/opt/cray/libfabric" $fileOutLinkage

echo
echo "============================================================"
echo "METAL_1NODE: 1 node, 8 ranks"
echo "============================================================"
fileOutMetal1Node=res_metal_1node.out
srun -N 1 -n 8 "./${theMetalExe}" | tee $fileOutMetal1Node

echo
echo "============================================================"
echo "CONTAINER_1NODE: 1 node, 8 ranks"
echo "============================================================"
fileOutCtnr1Node=res_ctnr_1node.out
srun -N 1 -n 8 singularity exec "${SINGULARITY_IMAGE}" "./${theImageExe}" | tee $fileOutCtnr1Node

echo
echo "============================================================"
echo "METAL_2NODE: 2 nodes, 8 ranks per node"
echo "============================================================"
fileOutMetal2Node=res_metal_2node.out
srun -N 2 --ntasks-per-node=8 "./${theMetalExe}" | tee $fileOutMetal2Node

echo
echo "============================================================"
echo "CONTAINER_2NODE: 2 nodes, 8 ranks per node"
echo "============================================================"
fileOutCtnr2Node=res_ctnr_2node.out
srun -N 2 --ntasks-per-node=8 singularity exec "${SINGULARITY_IMAGE}" "./${theImageExe}" | tee $fileOutCtnr2Node

echo
echo "=== Validate successful runs ==="
grep -q "MPI_PERF_TEST_SUCCESS size=8" $fileOutMetal1Node
grep -q "MPI_PERF_TEST_SUCCESS size=8" $fileOutCtnr1Node
grep -q "MPI_PERF_TEST_SUCCESS size=16" $fileOutMetal2Node
grep -q "MPI_PERF_TEST_SUCCESS size=16" $fileOutCtnr2Node

echo
echo "=== Summary ==="
echo "--- native single node ---"
grep -E "PINGPONG|ALLREDUCE" $fileOutMetal1Node

echo
echo "--- container single node ---"
grep -E "PINGPONG|ALLREDUCE" $fileOutCtnr1Node

echo
echo "--- native two node ---"
grep -E "PINGPONG|ALLREDUCE" $fileOutMetal2Node

echo
echo "--- container two node ---"
grep -E "PINGPONG|ALLREDUCE" $fileOutCtnr2Node

echo
echo "TEST_03_SUCCESS"
