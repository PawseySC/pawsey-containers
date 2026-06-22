#!/bin/bash --login
#SBATCH --job-name=T02-osu-2nodes
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:15:00
##SBATCH --partition=work
#SBATCH --partition=debug
#SBATCH --output=slurm-test_02-%j.out

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

echo "=== OSU binaries ==="
singularity exec "${SINGULARITY_IMAGE}" bash -lc '
which osu_latency
which osu_bw
which osu_allreduce
'

echo
echo "=== Linkage check ==="
fileOutLinkage="res_test_02.linkage.out"
singularity exec "${SINGULARITY_IMAGE}" bash -lc '
ldd $(which osu_latency) | egrep "mpi|fabric|cxi|pmi|pmix|pals|xpmem" || true
' | tee $fileOutLinkage

grep -q "/opt/cray/pe/mpich" $fileOutLinkage
grep -q "/opt/cray/libfabric" $fileOutLinkage

echo
echo "=== OSU latency: 2 nodes, 1 rank per node ==="
fileOutLatency="res_test_02.osu_latency.out"
srun -N 2 --ntasks-per-node=1 \
    singularity exec "${SINGULARITY_IMAGE}" osu_latency | tee $fileOutLatency
echo

grep -q "# OSU MPI Latency Test" $fileOutLatency
grep -q "^4[[:space:]]" $fileOutLatency
grep -q "^1048576[[:space:]]" $fileOutLatency

echo
echo "=== OSU bandwidth: 2 nodes, 1 rank per node ==="
fileOutBW="res_test_02.osu_bw.out"
srun -N 2 --ntasks-per-node=1 \
    singularity exec "${SINGULARITY_IMAGE}" osu_bw | tee $fileOutBW

grep -q "# OSU MPI Bandwidth Test" $fileOutBW
grep -q "^1048576[[:space:]]" $fileOutBW

echo
echo "=== OSU allreduce: 2 nodes, 4 ranks per node ==="
fileOutReduce="res_test_02.osu_allreduce.out"
srun -N 2 --ntasks-per-node="${SLURM_NTASKS_PER_NODE}" \
    singularity exec "${SINGULARITY_IMAGE}" osu_allreduce | tee $fileOutReduce

grep -q "# OSU MPI Allreduce Latency Test" $fileOutReduce
grep -q "^4[[:space:]]" $fileOutReduce
grep -q "^1048576[[:space:]]" $fileOutReduce

echo
echo "TEST_02_SUCCESS"
