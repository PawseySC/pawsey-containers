#!/bin/bash
#SBATCH --job-name="rfm_tensorflow_gpu_check_job"
#SBATCH --ntasks=4
#SBATCH --output=rfm_tensorflow_gpu_check_job.out
#SBATCH --error=rfm_tensorflow_gpu_check_job.err
#SBATCH --time=0:10:0
#SBATCH --partition=gpu
#SBATCH --gpus-per-node=4
#SBATCH --nodes=1
#SBATCH --account=pawsey0001-gpu
export OMP_NUM_THREADS=8
module load singularity/4.3.5-mpi
export TF_NUM_INTEROP_THREADS=1
export TF_NUM_INTRAOP_THREADS=1
export MIOPEN_USER_DB_PATH="/tmp/${SLURM_JOB_ID}"
export MIOPEN_CUSTOM_CACHE_DIR=${MIOPEN_USER_DB_PATH}
rm -rf ${MIOPEN_USER_DB_PATH}
mkdir -p ${MIOPEN_USER_DB_PATH}
module list
rocm-smi --showhw
srun -n 1 -c 32 --gres=gpu:4 singularity exec tensorflow-2.21.0-rocm7.2.4.sif python3 distributed.py 
rm -rf ${MIOPEN_USER_DB_PATH}
