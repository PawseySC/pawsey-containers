#!/bin/bash --login
# Generate and validate the scaled 3D base mesh for the OpenFOAM strong-scaling
# workflow using an explicit Singularity image, the installed SHPC container
# module, or the corresponding bare-metal OpenFOAM module.
#
# This Slurm job is the second stage of the version-specific strong-scaling
# workflow. It expects extractCase.sh to have copied the base tutorial case to
# <work-root>/run/baseCase/<CASE_NAME>. It scales the horizontal channel
# dimensions (x and z) while keeping the vertical wall separation (y in [0, 2])
# fixed, refines the cell counts in all three directions (Nx, Ny, Nz) to reach
# the requested target cell count in millions (--cells-millions, default 10),
# runs blockMesh, renumberMesh, and checkMesh once on the shared base case, and
# records the resulting mesh metadata in <work-root>/run/baseCase/mesh-info.env
# for the downstream decomposition and solver jobs.
#
# Usage:
#   sbatch meshFoam.slurm.sh --image <file> --config <file> [options]
#   sbatch meshFoam.slurm.sh --shpc --config <file> [options]
#   sbatch meshFoam.slurm.sh --bare-metal --config <file> [options]
#   sbatch meshFoam.slurm.sh --image <file> --recipe-dir <directory> [options]
#   sbatch meshFoam.slurm.sh --shpc --recipe-dir <directory> [options]
#   sbatch meshFoam.slurm.sh --bare-metal --recipe-dir <directory> [options]
#
# Exit status:
#   0  The scaled 3D base mesh was generated, renumbered, and validated.
#   1  Invalid input, runtime setup failure, command failure, or validation failure.
#
# NOTE: This script was originally developed under the supervision of Alexis Espinosa at Pawsey Supercomputing Centre with the aid of Microsoft 365 Copilot (GPT 5.6).
#       This script has been fully reviewed, understood and tested by Alexis Espinosa at Pawsey Supercomputing Centre.

#SBATCH --job-name=meshFoam-strongScaling
#SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=64GB
#SBATCH --time=01:00:00

set -u

# --- Version-specific strong-scaling base mesh settings
CASE_NAME="periodicPlaneChannel"
DEFAULT_CELLS_MILLIONS="10"

# Base tutorial geometry and cell counts per block (2 blocks stacked in y):
#   x in [0, 4]   -> BASE_LX=4,   BASE_NX=40
#   y in [0, 2]   -> fixed height (y=0, 1, 2), BASE_NY_BLOCK=25 (total Ny = 50)
#   z in [0, 2]   -> BASE_LZ=2,   BASE_NZ=30
#   Total base cells = 40 * (2 * 25) * 30 = 60,000
BASE_LX=4
BASE_LZ=2
BASE_NX=40
BASE_NY_BLOCK=25
BASE_NZ=30
GRAD_Y="10.7028"

# --- Initial settings
thisScript=$(basename "$0")
imageInput=""
useSHPC=false
useBareMetal=false
workRootInput=""
recipeDirInput=""
configFileInput=""
testArtifactsDirInput=""
cellsMillionsInput="$DEFAULT_CELLS_MILLIONS"
singularityModule="singularity/4.3.5-mpi"
singularityModuleSpecified=false

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  sbatch $thisScript --image <file> --config <file> [options]
  sbatch $thisScript --shpc --config <file> [options]
  sbatch $thisScript --bare-metal --config <file> [options]
  sbatch $thisScript --image <file> --recipe-dir <directory> [options]
  sbatch $thisScript --shpc --recipe-dir <directory> [options]
  sbatch $thisScript --bare-metal --recipe-dir <directory> [options]
  $thisScript --help

Runtime selection (choose exactly one):
  --image, -i <file>          Use the supplied Singularity image directly
  --singularity-module <module>
                              Singularity module for --image mode, or an override
                              applied after loading the SHPC OpenFOAM module.
                              Default for --image: singularity/4.3.5-mpi
  --shpc                      Load <OPENFOAM_FORK>-container/<OPENFOAM_VERSION>
  --bare-metal                Load <OPENFOAM_FORK>/<OPENFOAM_VERSION> and use the
                              OpenFOAM tools directly

Configuration selection (choose exactly one):
  --recipe-dir, -r <directory>  OpenFOAM version directory containing the
                                buildAndValidationConfig configuration file
  --config <file>             Version configuration file defining OPENFOAM_FORK
                              and OPENFOAM_VERSION

Mesh and path options:
  --cells-millions <number>   Target total mesh size in millions of cells
                              (positive integer or decimal, default: $DEFAULT_CELLS_MILLIONS)
  --work-root, -w <directory> Override the shared host work root. By default:
                              MYSCRATCH/OpenFOAM-strong-scaling/<user>-<configured-version>
  --test-artifacts-dir <directory>
                              Test-artifact destination; defaults to
                              <work-root>/test-output
  --help, -h                  Show this help message and exit

Expected extracted base case:
  <work-root>/run/baseCase/$CASE_NAME
USAGE
}

# --- Parse command-line arguments
while [[ $# -gt 0 ]]; do
   case "$1" in
      --image|-i)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --image requires <file>" >&2; usage >&2; exit 1; }
         imageInput="$2"
         shift 2
         ;;
      --singularity-module)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --singularity-module requires <module>" >&2; usage >&2; exit 1; }
         singularityModule="$2"
         singularityModuleSpecified=true
         shift 2
         ;;
      --shpc)
         useSHPC=true
         shift
         ;;
      --bare-metal)
         useBareMetal=true
         shift
         ;;
      --cells-millions)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --cells-millions requires <number>" >&2; usage >&2; exit 1; }
         cellsMillionsInput="$2"
         shift 2
         ;;
      --work-root|-w)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --work-root requires <directory>" >&2; usage >&2; exit 1; }
         workRootInput="$2"
         shift 2
         ;;
      --recipe-dir|-r)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --recipe-dir requires <directory>" >&2; usage >&2; exit 1; }
         recipeDirInput="$2"
         shift 2
         ;;
      --config)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --config requires <file>" >&2; usage >&2; exit 1; }
         configFileInput="$2"
         shift 2
         ;;
      --test-artifacts-dir)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --test-artifacts-dir requires <directory>" >&2; usage >&2; exit 1; }
         testArtifactsDirInput="$2"
         shift 2
         ;;
      -h|--help)
         usage
         exit 0
         ;;
      *)
         echo "ERROR: Unknown option '$1'" >&2
         usage >&2
         exit 1
         ;;
   esac
done

# --- Validate --cells-millions
awk -v m="$cellsMillionsInput" 'BEGIN { exit (m ~ /^[0-9]+([.][0-9]+)?$/ && m + 0 > 0 ? 0 : 1) }' || {
   echo "ERROR: --cells-millions must be a positive number; got '$cellsMillionsInput'" >&2
   exit 1
}

# --- Validate common inputs and load version identity
locationSelectorCount=0
[[ -n "$recipeDirInput" ]] && ((locationSelectorCount += 1))
[[ -n "$configFileInput" ]] && ((locationSelectorCount += 1))
[[ $locationSelectorCount -eq 1 ]] || {
   echo "ERROR: Choose exactly one of --recipe-dir <directory> or --config <file>" >&2
   usage >&2
   exit 1
}
if [[ -n "$recipeDirInput" ]]; then
   [[ -d "$recipeDirInput" ]] || { echo "ERROR: Recipe directory not found: $recipeDirInput" >&2; exit 1; }
   recipeDir=$(realpath "$recipeDirInput")
   configFileInput="${recipeDir}/buildAndValidationConfig/openfoamBuildAndValidation.config"
fi
[[ -r "$configFileInput" ]] || { echo "ERROR: Configuration is not readable: $configFileInput" >&2; usage >&2; exit 1; }
configFile=$(realpath "$configFileInput")
unset OPENFOAM_FORK OPENFOAM_VERSION
# shellcheck source=/dev/null
source "$configFile"
for requiredSetting in OPENFOAM_FORK OPENFOAM_VERSION; do
   [[ -n "${!requiredSetting:-}" ]] || { echo "ERROR: $requiredSetting is not defined in $configFile" >&2; exit 1; }
done

runtimeSelectorCount=0
[[ -n "$imageInput" ]] && ((runtimeSelectorCount += 1))
[[ "$useSHPC" == true ]] && ((runtimeSelectorCount += 1))
[[ "$useBareMetal" == true ]] && ((runtimeSelectorCount += 1))
[[ $runtimeSelectorCount -eq 1 ]] || {
   echo "ERROR: Choose exactly one of --image <file>, --shpc, or --bare-metal" >&2
   usage >&2
   exit 1
}

if [[ "$singularityModuleSpecified" == true && "$useBareMetal" == true ]]; then
   echo "ERROR: --singularity-module cannot be used with --bare-metal" >&2
   usage >&2
   exit 1
fi

if [[ -n "$imageInput" ]]; then
   [[ -f "$imageInput" ]] || { echo "ERROR: Singularity image not found: $imageInput" >&2; exit 1; }
   SINGULARITY_IMAGE=$(realpath "$imageInput")
fi

if [[ -n "$workRootInput" ]]; then
   workRoot=$(realpath -m "$workRootInput")
else
   baseWorkDir=${MYSCRATCH:-${TMPDIR:-$HOME}}
   workRoot="${baseWorkDir}/OpenFOAM-strong-scaling/${USER}-${OPENFOAM_VERSION}"
fi
BASE_CASE_DIR="${workRoot}/run/baseCase/${CASE_NAME}"
MESH_INFO_FILE="${workRoot}/run/baseCase/mesh-info.env"

# --- Resolve the persistent test-artifact directory
workOutputPath="${workRoot}/test-output"
if [[ -n "$testArtifactsDirInput" ]]; then
   outputDir=$(realpath -m "$testArtifactsDirInput")
   mkdir -p "$outputDir" || { echo "ERROR: Could not create test-artifact directory: $outputDir" >&2; exit 1; }
   mkdir -p "$workRoot"
   if [[ -e "$workOutputPath" && ! -L "$workOutputPath" ]]; then
      echo "ERROR: Refusing to replace non-symbolic-link output path: $workOutputPath" >&2
      exit 1
   fi
   ln -sfn "$outputDir" "$workOutputPath"
else
   outputDir="$workOutputPath"
   mkdir -p "$outputDir" || { echo "ERROR: Could not create default test-artifact directory: $outputDir" >&2; exit 1; }
fi

stageName="meshFoam"
stageRunLog="${outputDir}/${stageName}.run.log"
stageStatusFile="${outputDir}/${stageName}.status.txt"
printf '%s\n' RUNNING > "$stageStatusFile"
record_stage_status() {
   local exitStatus=$?
   trap - EXIT
   if [[ $exitStatus -eq 0 ]]; then
      printf '%s\n' SUCCESS > "$stageStatusFile"
   else
      printf '%s\n' FAILED > "$stageStatusFile"
   fi
   exit "$exitStatus"
}
trap record_stage_status EXIT
exec > >(tee "$stageRunLog") 2>&1

echo "Test artifacts: $outputDir"
echo "Stage run log: $stageRunLog"
echo "Stage status: $stageStatusFile"
echo

# --- Set up and validate the selected OpenFOAM runtime
if [[ "$useSHPC" == true ]]; then
   runtimeMode="SHPC module"
   shpcModule="${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}"
   shpcExec="${OPENFOAM_FORK}-exec"
   openfoamCommandPrefix=()
   module load "$shpcModule" || { echo "ERROR: Failed to load SHPC module: $shpcModule" >&2; exit 1; }
   command -v "$shpcExec" >/dev/null 2>&1 || { echo "ERROR: SHPC execution wrapper is unavailable: $shpcExec" >&2; exit 1; }
   for openfoamTool in foamDictionary blockMesh renumberMesh checkMesh; do
      command -v "$openfoamTool" >/dev/null 2>&1 || { echo "ERROR: OpenFOAM wrapper is unavailable: $openfoamTool" >&2; exit 1; }
   done
   [[ -n "${SINGULARITY_CONTAINER:-}" && -r "$SINGULARITY_CONTAINER" ]] || {
      echo "ERROR: Invalid SHPC backing image" >&2
      exit 1
   }
   SINGULARITY_IMAGE=$(realpath "$SINGULARITY_CONTAINER")
   if [[ "$singularityModuleSpecified" == true ]]; then
      module load "$singularityModule" || { echo "ERROR: Failed to switch to Singularity module: $singularityModule" >&2; exit 1; }
   fi
elif [[ "$useBareMetal" == true ]]; then
   runtimeMode="Bare-metal module"
   bareMetalModule="${OPENFOAM_FORK}/${OPENFOAM_VERSION}"
   shpcModule=""
   shpcExec=""
   openfoamCommandPrefix=()
   module load "$bareMetalModule" || { echo "ERROR: Failed to load bare-metal module: $bareMetalModule" >&2; exit 1; }
   for openfoamTool in foamDictionary blockMesh renumberMesh checkMesh; do
      command -v "$openfoamTool" >/dev/null 2>&1 || { echo "ERROR: OpenFOAM tool is unavailable: $openfoamTool" >&2; exit 1; }
   done
else
   runtimeMode="Explicit Singularity image"
   bareMetalModule=""
   shpcModule=""
   shpcExec=""
   openfoamCommandPrefix=(singularity exec "$SINGULARITY_IMAGE")
   module load "$singularityModule" || { echo "ERROR: Failed to load $singularityModule" >&2; exit 1; }
   command -v singularity >/dev/null 2>&1 || { echo "ERROR: singularity is unavailable after loading $singularityModule" >&2; exit 1; }
fi

echo "Loaded modules:"
module list
echo "Execution mode: $runtimeMode"
[[ "$useBareMetal" != true ]] && echo "Backing image: $SINGULARITY_IMAGE"

if [[ "$useSHPC" == true ]]; then
   WM_PROJECT_VERSION=$("$shpcExec" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || exit 1
elif [[ "$useBareMetal" != true ]]; then
   WM_PROJECT_VERSION=$(singularity exec "$SINGULARITY_IMAGE" bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || exit 1
else
   WM_PROJECT_VERSION=${WM_PROJECT_VERSION:-}
fi
[[ "$WM_PROJECT_VERSION" == "$OPENFOAM_VERSION" ]] || {
   echo "ERROR: Runtime version '$WM_PROJECT_VERSION' does not match configured '$OPENFOAM_VERSION'" >&2
   exit 1
}
echo "PASS: Runtime WM_PROJECT_VERSION matches OPENFOAM_VERSION='$OPENFOAM_VERSION'"
echo

# --- Validate extracted base case
[[ -d "$BASE_CASE_DIR" ]] || { echo "ERROR: Base case directory not found: $BASE_CASE_DIR" >&2; exit 1; }
[[ -d "${BASE_CASE_DIR}/system" ]] || { echo "ERROR: Missing directory: ${BASE_CASE_DIR}/system" >&2; exit 1; }
[[ -d "${BASE_CASE_DIR}/constant" ]] || { echo "ERROR: Missing directory: ${BASE_CASE_DIR}/constant" >&2; exit 1; }
[[ -d "${BASE_CASE_DIR}/0.orig" ]] || { echo "ERROR: Missing directory: ${BASE_CASE_DIR}/0.orig" >&2; exit 1; }

cd "$BASE_CASE_DIR" || { echo "ERROR: Could not enter base case directory: $BASE_CASE_DIR" >&2; exit 1; }
rm -rf 0
cp -a 0.orig 0 || { echo "ERROR: Failed to restore 0 from 0.orig" >&2; exit 1; }

# --- Convert hardcoded 60,000-cell nonuniform initial fields in 0/ to uniform fields
# The upstream periodicPlaneChannel tutorial stores 60,000-element nonuniform
# lists in 0.orig/{U,p,k,nut}.gz that only match the unscaled 40x50x30 mesh.
# Uncompress 0/*.gz and replace those internalFields with uniform initial
# values so decomposePar and pimpleFoam work for any scaled mesh size.
shopt -s nullglob
for gzFile in 0/*.gz; do
   gunzip -f "$gzFile" || { echo "ERROR: Failed to gunzip $gzFile" >&2; exit 1; }
done
shopt -u nullglob

srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary 0/U -entry internalField -set "uniform (0.1335 0 0)" || {
      echo "ERROR: Failed to set uniform internalField in 0/U" >&2; exit 1;
   }
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary 0/p -entry internalField -set "uniform 0" || {
      echo "ERROR: Failed to set uniform internalField in 0/p" >&2; exit 1;
   }
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary 0/k -entry internalField -set "uniform 5e-04" || {
      echo "ERROR: Failed to set uniform internalField in 0/k" >&2; exit 1;
   }
srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
   foamDictionary 0/nut -entry internalField -set "uniform 5e-05" || {
      echo "ERROR: Failed to set uniform internalField in 0/nut" >&2; exit 1;
   }
echo "PASS: Initial fields in 0/ configured with mesh-independent uniform internalFields"
echo

# --- Compute scaled 3D channel geometry and cell counts
# Keep vertical wall distance fixed (y in [0, 2], midline at y=1), extend Lx and
# Lz by the linear scaling factor k = (targetCells / 60000)^(1/3), and scale
# (Nx, Ny_block, Nz) in all three directions so scotch sees a full 3D mesh.
read -r targetCells scaleFactor scaledLx scaledLz scaledNx scaledNyBlock scaledNyTotal scaledNz actualCells <<< "$(
   awk -v m="$cellsMillionsInput" \
       -v baseLx="$BASE_LX" -v baseLz="$BASE_LZ" \
       -v baseNx="$BASE_NX" -v baseNyBlock="$BASE_NY_BLOCK" -v baseNz="$BASE_NZ" '
   BEGIN {
      target = int(m * 1000000 + 0.5)
      baseCells = baseNx * (2 * baseNyBlock) * baseNz
      k = (target / baseCells) ^ (1.0 / 3.0)
      nx = int(baseNx * k + 0.5); if (nx < 1) nx = 1
      nyBlock = int(baseNyBlock * k + 0.5); if (nyBlock < 1) nyBlock = 1
      nz = int(baseNz * k + 0.5); if (nz < 1) nz = 1
      nyTotal = 2 * nyBlock
      lx = baseLx * (nx / baseNx)
      lz = baseLz * (nz / baseNz)
      actual = nx * nyTotal * nz
      printf "%d %.6f %.6g %.6g %d %d %d %d %d\n", target, k, lx, lz, nx, nyBlock, nyTotal, nz, actual
   }'
)"

echo "======================================================"
echo "3D Periodic Plane Channel Mesh Scaling Summary"
echo "======================================================"
echo "Target cell count (millions): $cellsMillionsInput ($targetCells cells)"
echo "Linear 3D scaling factor k  : $scaleFactor"
echo "Streamwise length Lx        : $scaledLx (base: $BASE_LX)"
echo "Vertical wall height Ly     : 2 (fixed: bottomWall y=0, midline y=1, topWall y=2)"
echo "Spanwise width Lz           : $scaledLz (base: $BASE_LZ)"
echo "Cells in X (Nx)             : $scaledNx"
echo "Cells in Y (Ny = 2*Ny_block): $scaledNyTotal (2 blocks of $scaledNyBlock)"
echo "Cells in Z (Nz)             : $scaledNz"
echo "Resulting total cells       : $actualCells"
echo "======================================================"
echo

# --- Write the scaled system/blockMeshDict
cat > system/blockMeshDict <<EOF
/*--------------------------------*- C++ -*----------------------------------*\\
| =========                 |                                                 |
| \\\\      /  F ield         | OpenFOAM: The Open Source CFD Toolbox           |
|  \\\\    /   O peration     | Version:  ${OPENFOAM_VERSION}                   |
|   \\\\  /    A nd           | Website:  www.openfoam.com                      |
|    \\\\/     M anipulation  |                                                 |
\\*---------------------------------------------------------------------------*/
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      blockMeshDict;
}
// * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * //

scale   1;

vertices
(
    (0 0 0)
    (${scaledLx} 0 0)
    (0 1 0)
    (${scaledLx} 1 0)
    (0 2 0)
    (${scaledLx} 2 0)
    (0 0 ${scaledLz})
    (${scaledLx} 0 ${scaledLz})
    (0 1 ${scaledLz})
    (${scaledLx} 1 ${scaledLz})
    (0 2 ${scaledLz})
    (${scaledLx} 2 ${scaledLz})
);

blocks
(
    hex (0 1 3 2 6 7 9 8)   (${scaledNx} ${scaledNyBlock} ${scaledNz}) simpleGrading (1  ${GRAD_Y} 1)
    hex (2 3 5 4 8 9 11 10) (${scaledNx} ${scaledNyBlock} ${scaledNz}) simpleGrading (1 -${GRAD_Y} 1)
);

edges
(
);

boundary
(
    bottomWall
    {
        type            wall;
        faces           ((0 1 7 6));
    }
    topWall
    {
        type            wall;
        faces           ((4 10 11 5));
    }

    sides1_half0
    {
        type            cyclic;
        neighbourPatch  sides1_half1;
        faces           ((0 2 3 1));
    }
    sides1_half1
    {
        type            cyclic;
        neighbourPatch  sides1_half0;
        faces           ((6 7 9 8));
    }

    sides2_half0
    {
        type            cyclic;
        neighbourPatch  sides2_half1;
        faces           ((2 4 5 3));
    }
    sides2_half1
    {
        type            cyclic;
        neighbourPatch  sides2_half0;
        faces           ((8 9 11 10));
    }

    inout1_half0
    {
        type            cyclic;
        neighbourPatch  inout1_half1;
        faces           ((1 3 9 7));
    }
    inout1_half1
    {
        type            cyclic;
        neighbourPatch  inout1_half0;
        faces           ((0 6 8 2));
    }

    inout2_half0
    {
        type            cyclic;
        neighbourPatch  inout2_half1;
        faces           ((3 5 11 9));
    }
    inout2_half1
    {
        type            cyclic;
        neighbourPatch  inout2_half0;
        faces           ((2 8 10 4));
    }
);

// ************************************************************************* //
EOF

# --- Helper to run serial OpenFOAM mesh preparation steps
runOpenFOAMStep() {
   local stepName="$1"
   shift
   local logFile="${outputDir}/${stepName}.log"
   local stepStatus

   echo "Running: $*"
   srun -N 1 -n 1 -c 1 "${openfoamCommandPrefix[@]}" \
      "$@" 2>&1 | tee "$logFile"
   stepStatus=${PIPESTATUS[0]}

   [[ $stepStatus -eq 0 ]] || {
      echo "ERROR: $stepName failed with exit status $stepStatus" >&2
      exit 1
   }

   grep -qE 'FOAM FATAL (ERROR|IO ERROR)' "$logFile" && {
      echo "ERROR: $stepName reported an OpenFOAM fatal error" >&2
      exit 1
   }

   echo "PASS: $stepName completed successfully"
   echo
}

# --- Generate, optimize bandwidth (Cuthill-McKee), and validate the base mesh
runOpenFOAMStep blockMesh blockMesh
runOpenFOAMStep renumberMesh_serial renumberMesh -overwrite -constant
runOpenFOAMStep checkMesh checkMesh -constant

checkMeshLog="${outputDir}/checkMesh.log"
grep -q "Mesh OK" "$checkMeshLog" || {
   echo "ERROR: checkMesh did not report 'Mesh OK'" >&2
   exit 1
}
echo "PASS: checkMesh reported 'Mesh OK'"
echo

# --- Persist base mesh metadata for downstream decomposition and solver jobs
cat > "$MESH_INFO_FILE" <<EOF
CASE_NAME=${CASE_NAME}
TARGET_CELLS_MILLIONS=${cellsMillionsInput}
TARGET_CELLS=${targetCells}
ACTUAL_CELLS=${actualCells}
SCALED_LX=${scaledLx}
SCALED_LY=2
SCALED_LZ=${scaledLz}
SCALED_NX=${scaledNx}
SCALED_NY_BLOCK=${scaledNyBlock}
SCALED_NY_TOTAL=${scaledNyTotal}
SCALED_NZ=${scaledNz}
EOF

cp -f "$MESH_INFO_FILE" "${outputDir}/mesh-info.env"

echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Tutorial case        : $CASE_NAME"
echo "Base case directory  : $BASE_CASE_DIR"
echo "Mesh metadata file   : $MESH_INFO_FILE"
echo "Target cells (M)     : ${cellsMillionsInput}M ($targetCells)"
echo "Actual mesh cells    : $actualCells (${scaledNx} x ${scaledNyTotal} x ${scaledNz})"
echo "Domain dimensions    : ${scaledLx} x 2 x ${scaledLz}"
echo "ALL STEPS PASSED: Base strong-scaling mesh generated and validated."
exit 0
