#!/bin/bash
#SBATCH --job-name=T01-compile-run
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:10:00
#SBATCH --partition=work
#SBATCH --output=slurm-test_01-%j.out

set -euo pipefail

#MPICH_VERSION="3.4.3"
MPICH_VERSION="4.2.2"
SINGULARITY_IMAGE="${MYSCRATCH}/pawsey-containers/setonix/mpi/mpich-base/mpich-base_${MPICH_VERSION}.sif"
echo "Using image: $SINGULARITY_IMAGE"

module load singularity/4.1.0-mpi
module list

echo "=== Building with container mpicc ==="
singularity exec "${SINGULARITY_IMAGE}" mpicc -O2 mpi_acceptance.c -o mpi_acceptance

echo
echo "=== Linkage check ==="
singularity exec "${SINGULARITY_IMAGE}" bash -lc '
ldd ./mpi_acceptance | egrep "mpi|fabric|cxi|pmi|pmix|pals|xpmem" || true
' | tee out.test_01.linkage.txt

grep -q "/opt/cray/pe/mpich" out.test_01.linkage.txt
grep -q "/opt/cray/libfabric" out.test_01.linkage.txt

echo
echo "=== Running on 2 nodes ==="
TOTAL_TASKS=$((SLURM_NNODES * SLURM_NTASKS_PER_NODE))

srun -N 2 --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
    singularity exec "${SINGULARITY_IMAGE}" ./mpi_acceptance | tee out.test_01.run.txt

grep -q "TEST_01_MPI_CONTAINER_BUILD_RUN_SUCCESS size=${TOTAL_TASKS}" out.test_01.run.txt

RANK_COUNT=$(grep -c "^RANK_OK " out.test_01.run.txt)
if [[ "${RANK_COUNT}" -ne "${TOTAL_TASKS}" ]]; then
    echo "FAIL: expected ${TOTAL_TASKS} RANK_OK lines, got ${RANK_COUNT}"
    exit 1
fi

echo
echo "TEST_01_SUCCESS"
