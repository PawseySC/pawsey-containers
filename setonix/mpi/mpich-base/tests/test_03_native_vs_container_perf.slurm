#!/bin/bash
#SBATCH --job-name=ctnr-vs-native
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --time=00:20:00
#SBATCH --output=test_03_%j.out
#SBATCH --error=test_03_%j.err

set -euo pipefail

SINGULARITY_IMAGE=${SINGULARITY_IMAGE:-/path/to/mpich-base_3.4.3.sif}

module load singularity/4.1.0-mpi

WORKDIR="${SLURM_SUBMIT_DIR}/test_03_${SLURM_JOB_ID}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

cp "${SLURM_SUBMIT_DIR}/mpi_perf_compare.c" .

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
