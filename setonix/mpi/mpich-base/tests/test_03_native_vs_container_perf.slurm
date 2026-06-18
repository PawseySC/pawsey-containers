#!/bin/bash
#SBATCH --job-name=T03_ctnr-vs-native
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --time=00:20:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-test_03-%j.out

set -euo pipefail

MPICH_VERSION="3.4.3"
#MPICH_VERSION="4.2.2"
SINGULARITY_IMAGE="${MYSCRATCH}/pawsey-containers/setonix/mpi/mpich-base/mpich-base_${MPICH_VERSION}.sif"
echo "Using image: $SINGULARITY_IMAGE"

module load singularity/4.1.0-mpi
module list

echo "=== Build native binary with Cray wrapper cc ==="
cc -O3 mpi_perf_compare.c -o mpi_perf_native

echo
echo "=== Build container binary with container mpicc ==="
singularity exec "${SINGULARITY_IMAGE}" mpicc -O3 mpi_perf_compare.c -o mpi_perf_container

echo
echo "=== Container binary linkage ==="
singularity exec "${SINGULARITY_IMAGE}" bash -lc '
ldd ./mpi_perf_container | egrep "mpi|fabric|cxi|pmi|pmix|pals|xpmem" || true
' | tee container_linkage.out.txt

grep -q "/opt/cray/pe/mpich" container_linkage.out.txt
grep -q "/opt/cray/libfabric" container_linkage.out.txt

echo
echo "============================================================"
echo "NATIVE_SINGLE_NODE: 1 node, 8 ranks"
echo "============================================================"
srun -N 1 -n 8 ./mpi_perf_native | tee native_single_node.out

echo
echo "============================================================"
echo "CONTAINER_SINGLE_NODE: 1 node, 8 ranks"
echo "============================================================"
srun -N 1 -n 8 singularity exec "${SINGULARITY_IMAGE}" ./mpi_perf_container | tee container_single_node.out

echo
echo "============================================================"
echo "NATIVE_TWO_NODE: 2 nodes, 8 ranks per node"
echo "============================================================"
srun -N 2 --ntasks-per-node=8 ./mpi_perf_native | tee native_two_node.out

echo
echo "============================================================"
echo "CONTAINER_TWO_NODE: 2 nodes, 8 ranks per node"
echo "============================================================"
srun -N 2 --ntasks-per-node=8 singularity exec "${SINGULARITY_IMAGE}" ./mpi_perf_container | tee container_two_node.out

echo
echo "=== Validate successful runs ==="
grep -q "MPI_PERF_TEST_SUCCESS size=8" native_single_node.out
grep -q "MPI_PERF_TEST_SUCCESS size=8" container_single_node.out
grep -q "MPI_PERF_TEST_SUCCESS size=16" native_two_node.out
grep -q "MPI_PERF_TEST_SUCCESS size=16" container_two_node.out

echo
echo "=== Summary ==="
echo "--- native single node ---"
grep -E "PINGPONG|ALLREDUCE" native_single_node.out

echo
echo "--- container single node ---"
grep -E "PINGPONG|ALLREDUCE" container_single_node.out

echo
echo "--- native two node ---"
grep -E "PINGPONG|ALLREDUCE" native_two_node.out

echo
echo "--- container two node ---"
grep -E "PINGPONG|ALLREDUCE" container_two_node.out

echo
echo "TEST_03_SUCCESS"
