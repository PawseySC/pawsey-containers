#!/bin/bash -l
#SBATCH --export=NONE
#SBATCH --time=00:15:00
#SBATCH --ntasks=48
#SBATCH --ntasks-per-node=24
#SBATCH --partition=debugq

#------------------------
#Loading the right singularity module
#module load singularity/3.5.2
module load singularity

#------------------------
#Choosing the container image to use
export containerImage=$MYGROUP/../singularity/groupRepository/OpenFOAM/openfoam-org-5.x_CFDEM-pawsey.sif

#------------------------
#Properly delete the existing working directories
find -P ./CFD -type f -print0 -o -type l -print0 | xargs -0 munlink
find -P ./DEM -type f -print0 -o -type l -print0 | xargs -0 munlink
find ./CFD -depth -type d -empty -delete
find ./DEM -depth -type d -empty -delete

#------------------------
#Copy fresh directories into new clean working directories
cp -r CFD.base CFD
cp -r DEM.base DEM

#------------------------
#Running the several steps
cd CFD
#Decomposition is a serial substep
srun --export=all -n 1 -N 1 singularity exec $containerImage decomposePar 2>&1 | tee log.decomposePar

#The solver runs in parallel using supercomputer mpi (hybrid mode)
srun --export=all -n 48 -N 2 singularity exec $containerImage cfdemSolverPiso -parallel 2>&1 | tee log.cfdemSolver

#The reconstruction is a serial substep
srun --export=all -n 1 -N 1 singularity exec $containerImage reconstructPar -noLagrangian -latestTime 2>&1 | tee log.reconstructPar
