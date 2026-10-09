#!/bin/bash
#
# Run CP2K DFT benchmark with 4 MPI ranks using ssitaram/cp2k:pr22 container
#

set -e

SINGULARITY_IMAGE=$1
CP2K_BRANCH="v2026.2"
export BENCHMARK_DIR="/cp2k_source/benchmarks/QS_DM_LS"

SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/4.1.0-mpi}"
module load "${SINGULARITY_MODULE}"

NUM_RANKS=${NUM_RANKS:-8}
NUM_GPUS=${NUM_GPUS:-8}
NUM_CPUS=${NUM_CPUS:-64}
OMP_NUM_THREADS=${OMP_NUM_THREADS:-8}
export BENCHMARK_INPUT="${BENCHMARK_DIR}/H2O-dft-ls.NREP2.inp"
export OUTPUT_FILE="/tmp/H2O-DFT-LS-NREP2-${NUM_RANKS}ranks.txt"

echo "=========================================="
echo "Running CP2K DFT Benchmark"
echo "Container: $SINGULARITY_IMAGE"
echo "MPI Ranks: $NUM_RANKS"
echo "OpenMP Threads per rank: $OMP_NUM_THREADS"
echo "Executable: $CP2K_EXECUTABLE"
echo "CP2K Branch: $CP2K_BRANCH"
echo "=========================================="

# Get the script directory (where this script is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the base directory (parent of scripts)
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Clone CP2K repository if not already present
if [ ! -d "$BASE_DIR/cp2k_repo" ]; then
    echo "Cloning CP2K repository (branch ${CP2K_BRANCH})..."
    cd "$BASE_DIR"
    git clone --recursive -b ${CP2K_BRANCH} https://github.com/cp2k/cp2k.git cp2k_repo
else
    echo "CP2K repository already exists, skipping clone..."
fi

# Ensure scripts have execute permission
if [ -d "$SCRIPT_DIR" ]; then
    echo "Setting execute permissions on scripts..."
    chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
fi


srun -N 1 -n "$NUM_RANKS" -c "$OMP_NUM_THREADS" --gres=gpu:"$NUM_GPUS" singularity exec \
    --pwd "$BENCHMARK_DIR" \
    -B "$BASE_DIR/cp2k_repo":/cp2k_source \
    -B "$SCRIPT_DIR":/scripts \
    $SINGULARITY_IMAGE \
    cp2k.psmp -i "$BENCHMARK_INPUT" -o "$OUTPUT_FILE"
rc=$?
        
if [ $rc -eq 0 ]; then
    echo ''
    echo '=========================================='
    echo 'Benchmark completed successfully!'
    echo '=========================================='
    echo "Output file: $OUTPUT_FILE"
    echo ''
    echo 'FORCE_EVAL timing:'
    grep 'FORCE_EVAL' $OUTPUT_FILE || echo 'No FORCE_EVAL timing found'
    echo ''
    echo 'All CP2K timing lines:'
    grep 'CP2K             ' $OUTPUT_FILE || echo 'No timing information found'
    echo ''
    
    # Extract FOM: last time value from the last line matching 'CP2K             '
    FOM_LINE=$(grep 'CP2K             ' $OUTPUT_FILE | tail -n 1)
    if [ -n "$FOM_LINE" ]; then
        # Extract the last numeric value (time) from the line
        # This assumes the time is the last field/word in the line
        FOM=$(echo "$FOM_LINE" | awk '{print $NF}')
        echo '=========================================='
        echo "FOM (Figure of Merit): $FOM seconds"
        echo '=========================================='
    else
        echo 'Warning: Could not extract FOM from output file'
    fi
else
    echo 'Benchmark failed!'
    exit 1
fi

echo ""
echo "Output file saved to: ${OUTPUT_FILE}"
