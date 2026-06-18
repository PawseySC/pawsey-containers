#!/bin/bash
#SBATCH --job-name=T02-osu-2nodes
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:15:00
#SBATCH --partition=work
#SBATCH --output=slurm-test_02-%j.out

set -euo pipefail

MPICH_VERSION="3.4.3"
#MPICH_VERSION="4.2.2"
SINGULARITY_IMAGE="${MYSCRATCH}/pawsey-containers/setonix/mpi/mpich-base/mpich-base_${MPICH_VERSION}.sif"
echo "Using image: $SINGULARITY_IMAGE"

module load singularity/4.1.0-mpi
module list

echo "=== OSU binaries ==="
singularity exec "${SINGULARITY_IMAGE}" bash -lc '
which osu_latency
which osu_bw
which osu_allreduce
'

echo
echo "=== Linkage check ==="
singularity exec "${SINGULARITY_IMAGE}" bash -lc '
ldd $(which osu_latency) | egrep "mpi|fabric|cxi|pmi|pmix|pals|xpmem" || true
' | tee out.test_02.linkage.txt

grep -q "/opt/cray/pe/mpich" out.test_02.linkage.txt
grep -q "/opt/cray/libfabric" out.test_02.linkage.txt

echo
echo "=== OSU latency: 2 nodes, 1 rank per node ==="
srun -N 2 --ntasks-per-node=1 \
    singularity exec "${SINGULARITY_IMAGE}" osu_latency | tee out.test_02.osu_latency.txt

grep -q "# OSU MPI Latency Test" out.test_02.osu_latency.txt
grep -q "^0[[:space:]]" out.test_02.osu_latency.txt
grep -q "^1048576[[:space:]]" out.test_02.osu_latency.txt

echo
echo "=== OSU bandwidth: 2 nodes, 1 rank per node ==="
srun -N 2 --ntasks-per-node=1 \
    singularity exec "${SINGULARITY_IMAGE}" osu_bw | tee out.test_02.osu_bw.txt

grep -q "# OSU MPI Bandwidth Test" out.test_02.osu_bw.txt
grep -q "^1048576[[:space:]]" out.test_02.osu_bw.txt

echo
echo "=== OSU allreduce: 2 nodes, 4 ranks per node ==="
srun -N 2 --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
    singularity exec "${SINGULARITY_IMAGE}" osu_allreduce | tee out.test_02.osu_allreduce.txt

grep -q "# OSU MPI Allreduce Latency Test" out.test_02.osu_allreduce.txt
grep -q "^0[[:space:]]" out.test_02.osu_allreduce.txt
grep -q "^1048576[[:space:]]" out.test_02.osu_allreduce.txt

echo
echo "TEST_02_SUCCESS"
