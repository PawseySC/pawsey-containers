#-------------------------------
This case was shared by: Enzu Zheng
As discussed in ticket: https://support.pawsey.org.au/portal/browse/GS-14038
(Originally named: singularity_test_case_share)

#-------------------------------
To execute it, you need to double check the job setting in the script: runScript.sh
In principle, the only line to adapt is the setting for what container image to use
(containerImage)
And then just submit the job: sbatch runScript.sh

#-------------------------------
Reconstruction was forced to be done with -noLagrangian flag to avoid an error in the reconstruction

#-------------------------------
In CFD.base/system/controlDict the following settings were forced (following Pawsey Best Practices)
purgeWrite 10;
writeFormat binary;
runTimeModifiable no;

#-------------------------------
Use the script cleanHere.sh to remove the result and leave a clean directory
(slurm-XXX.out files should be removed by the user separately)
