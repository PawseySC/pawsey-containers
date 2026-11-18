#!/bin/bash
#
# Run CP2K RPA benchmark (32-H2O) with two stages using ssitaram/cp2k:pr22 container
# Stage 1 (init): H2O-32-PBE-TZ.inp - 1 rank, 4 threads, 1 GPU
# Stage 2 (solver): H2O-32-RI-dRPA-TZ.inp - 16 ranks, 8 threads, 8 GPUs
#

set -e

SINGULARITY_IMAGE=$1
CP2K_BRANCH="v2026.2"
export BENCHMARK_DIR="/cp2k_source/benchmarks/QS_mp2_rpa/32-H2O"

SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularity/4.1.0-mpi}"
module load "${SINGULARITY_MODULE}"

# Stage 1: Init
export INIT_INPUT="${BENCHMARK_DIR}/H2O-32-PBE-TZ.inp"
export INIT_OUTPUT="/tmp/H2O-32-PBE-TZ-output.txt"
INIT_RANKS=1
INIT_THREADS=8
INIT_GPUS=1
INIT_CPUS=64

# Stage 2: Solver
export SOLVER_INPUT="${BENCHMARK_DIR}/H2O-32-RI-dRPA-TZ.inp"
export SOLVER_OUTPUT="/tmp/H2O-32-RI-dRPA-TZ-output.txt"
SOLVER_RANKS=8
SOLVER_THREADS=8
SOLVER_GPUS=8
SOLVER_CPUS=64

echo "=========================================="
echo "CP2K RPA Benchmark (32-H2O)"
echo "Container: $SINGULARITY_IMAGE"
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

echo ""
echo "=========================================="
echo "STAGE 1: Init (H2O-32-PBE-TZ.inp)"
echo "Ranks: $INIT_RANKS, Threads: $INIT_THREADS, GPUs: $INIT_GPUS"
echo "=========================================="

export OMP_NUM_THREADS="$INIT_THREADS"

srun -N 1 -n "$INIT_RANKS" -c "$INIT_THREADS" --gres=gpu:"$INIT_GPUS" singularity exec \
    --pwd "$BENCHMARK_DIR" \
    -B "$BASE_DIR/cp2k_repo":/cp2k_source \
    -B "$SCRIPT_DIR":/scripts \
    "$SINGULARITY_IMAGE" \
    cp2k.psmp -i "$INIT_INPUT" -o "$INIT_OUTPUT"
rc=$?
    
if [ $rc -eq 0 ]; then
    echo ''
    echo '=========================================='
    echo 'Init Stage completed successfully!'
    echo '=========================================='
    echo 'FORCE_EVAL timing:'
    grep 'FORCE_EVAL' $INIT_OUTPUT || echo 'No FORCE_EVAL timing found'
    echo ''
    echo 'CP2K timing:'
    grep 'CP2K             ' $INIT_OUTPUT | tail -n 1 || echo 'No timing found'

    # Extract FOM
    FOM_LINE=$(grep 'CP2K             ' $INIT_OUTPUT | tail -n 1)
    if [ -n "$FOM_LINE" ]; then
        FOM=$(echo "$FOM_LINE" | awk '{print $NF}')
        echo "Init Stage FOM: $FOM seconds"
    fi
else
    echo 'Init stage failed, aborting solver stage'
    exit 1
fi


echo ""
echo "=========================================="
echo "STAGE 2: Solver (H2O-32-RI-dRPA-TZ.inp)"
echo "Ranks: $SOLVER_RANKS, Threads: $SOLVER_THREADS, GPUs: $SOLVER_GPUS"
echo "=========================================="

export OMP_NUM_THREADS="$SOLVER_THREADS"

srun -N 1 -n "$SOLVER_RANKS" -c "$SOLVER_THREADS" --gres=gpu:"$SOLVER_GPUS" singularity exec \
    --pwd "$BENCHMARK_DIR" \
    -B "$BASE_DIR/cp2k_repo":/cp2k_source \
    -B "$SCRIPT_DIR":/scripts \
    "$SINGULARITY_IMAGE" \
    cp2k.psmp -i "$SOLVER_INPUT" -o "$SOLVER_OUTPUT"
rc=$?
        
if [ $rc -eq 0 ]; then
    echo ''
    echo '=========================================='
    echo 'Solver Stage completed successfully!'
    echo '=========================================='
    echo 'FORCE_EVAL timing:'
    grep 'FORCE_EVAL' $SOLVER_OUTPUT || echo 'No FORCE_EVAL timing found'
    echo ''
    echo 'CP2K timing:'
    grep 'CP2K             ' $SOLVER_OUTPUT | tail -n 1 || echo 'No timing found'
    
    # Extract FOM
    FOM_LINE=$(grep 'CP2K             ' $SOLVER_OUTPUT | tail -n 1)
    if [ -n "$FOM_LINE" ]; then
        FOM=$(echo "$FOM_LINE" | awk '{print $NF}')
        echo "Solver Stage FOM: $FOM seconds"
    fi
else
    echo 'Solver stage failed!'
    exit 1
fi

echo ""
echo "=========================================="
echo "RPA Benchmark Complete!"
echo "=========================================="
echo "Init output: $INIT_OUTPUT"
echo "Solver output: $SOLVER_OUTPUT"
echo ""
echo "Summary:"
echo "--------"
echo "Init Stage:"
grep 'FORCE_EVAL' "$INIT_OUTPUT" 2>/dev/null || echo "  FORCE_EVAL: Not available"
grep 'CP2K             ' "$INIT_OUTPUT" 2>/dev/null | tail -n 1 | awk '{print "  CP2K FOM: " $NF " seconds"}' || echo "  FOM: Not available"
echo ""
echo "Solver Stage:"
grep 'FORCE_EVAL' "$SOLVER_OUTPUT" 2>/dev/null || echo "  FORCE_EVAL: Not available"
grep 'CP2K             ' "$SOLVER_OUTPUT" 2>/dev/null | tail -n 1 | awk '{print "  CP2K FOM: " $NF " seconds"}' || echo "  FOM: Not available"

