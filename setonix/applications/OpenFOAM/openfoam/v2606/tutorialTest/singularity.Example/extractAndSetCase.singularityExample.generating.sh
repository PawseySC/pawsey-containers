#!/bin/bash --login
# Extract the tutorial and apply its test settings. No Slurm allocation is needed.
# Override SINGULARITY_IMAGE and TUTORIAL_WORK_ROOT to use another image or workspace.

set -Eeuo pipefail
trap 'echo "ERROR: ${0##*/}: line $LINENO: command failed: $BASH_COMMAND" >&2' ERR

printSection() {
   printf '\n\n================================================================\n'
   printf 'extractAndSetCase | %s\n' "$1"
   printf '================================================================\n\n'
}

# =============================================================================
# 1. Tutorial settings
# =============================================================================
OPENFOAM_VERSION="v2606"
CASE_NAME="periodicPlaneChannel"
nProcs=4
newEndTime=100
newWriteControl="runTime"
newWriteInterval=20
newMethod="simple"
decompositionX=1
decompositionY=2
decompositionZ=2

# =============================================================================
# 2. Options
# =============================================================================
thisScript=${0##*/}
overwriteCase=false
usage() {
   cat <<USAGE
Usage: $thisScript [--overwrite] [--help]

Extract and configure the tutorial without submitting or launching Slurm tasks.
Environment overrides:
  SINGULARITY_MODULE   Runtime module (default: singularity/4.3.5-mpi)
  SINGULARITY_IMAGE    Image file
  TUTORIAL_WORK_ROOT  Work root containing run/$CASE_NAME

An existing case is refused unless --overwrite is explicitly supplied.
Overwriting also removes the case's previous results and case-local logs.
The caller is responsible for capturing this script's stdout and stderr.
USAGE
}
while (($#)); do
   case "$1" in
      --overwrite) overwriteCase=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
   esac
done

printSection "1. Tutorial settings"
printf 'Case: %s | Version: %s | Domains: %s\n' "$CASE_NAME" "$OPENFOAM_VERSION" "$nProcs"
printSection "2. Options"
echo "Overwrite existing case: $overwriteCase"

# =============================================================================
# 3. Load the runtime and verify the image
# =============================================================================
printSection "3. Load the runtime and verify the image"
SINGULARITY_MODULE=${SINGULARITY_MODULE:-singularity/4.3.5-mpi}
module load "$SINGULARITY_MODULE"
module list
export SINGULARITY_IMAGE=${SINGULARITY_IMAGE:-"${MYSCRATCH}/pawsey-containers/setonix/applications/OpenFOAM/openfoam/v2606/artifacts/singularity/latest/openfoam--v2606-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04.sif"}
[[ -r "$SINGULARITY_IMAGE" && -f "$SINGULARITY_IMAGE" ]] || {
   echo "ERROR: Image is not a readable file: $SINGULARITY_IMAGE" >&2; exit 1;
}
SINGULARITY_IMAGE=$(realpath -- "$SINGULARITY_IMAGE")
runtimeVersion=$(singularity exec "$SINGULARITY_IMAGE" bash -c 'printf "%s" "$WM_PROJECT_VERSION"')
[[ "$runtimeVersion" == "$OPENFOAM_VERSION" ]] || {
   echo "ERROR: Expected runtime $OPENFOAM_VERSION; found $runtimeVersion" >&2; exit 1;
}
echo "SINGULARITY_IMAGE=$SINGULARITY_IMAGE"

# =============================================================================
# 4. Find the tutorial inside the image
# =============================================================================
printSection "4. Find the tutorial inside the image"
internalCaseOutput=$(singularity exec "$SINGULARITY_IMAGE" \
   bash -c 'find "$FOAM_TUTORIALS" -type d -name "$1" -print' bash "$CASE_NAME")
internalCases=()
if [[ -n "$internalCaseOutput" ]]; then
   mapfile -t internalCases <<< "$internalCaseOutput"
fi
[[ ${#internalCases[@]} -eq 1 ]] || {
   echo "ERROR: Expected one tutorial named $CASE_NAME; found ${#internalCases[@]}" >&2; exit 1;
}
(( decompositionX * decompositionY * decompositionZ == nProcs )) || {
   echo "ERROR: Decomposition does not produce $nProcs subdomains" >&2; exit 1;
}
echo "Tutorial source: ${internalCases[0]}"

# =============================================================================
# 5. Copy the tutorial to the workspace
# =============================================================================
printSection "5. Copy the tutorial to the workspace"
TUTORIAL_WORK_ROOT=${TUTORIAL_WORK_ROOT:-"${MYSCRATCH}/OpenFOAM/${USER}-${OPENFOAM_VERSION}/tutorialTesting"}
mkdir -p -- "$TUTORIAL_WORK_ROOT/run"
hostRunDir=$(cd -- "$TUTORIAL_WORK_ROOT/run" && pwd)
TEST_CASE="$hostRunDir/$CASE_NAME"
echo "Case directory: $TEST_CASE"
if [[ -e "$TEST_CASE" || -L "$TEST_CASE" ]]; then
   [[ "$overwriteCase" == true ]] || {
      echo "ERROR: Case exists: $TEST_CASE; use --overwrite or another TUTORIAL_WORK_ROOT" >&2; exit 1;
   }
   rm -rf -- "$TEST_CASE"
fi
singularity exec "$SINGULARITY_IMAGE" cp -a --no-preserve=timestamps "${internalCases[0]}" "$TEST_CASE"
for directory in system constant 0.orig; do
   [[ -d "$TEST_CASE/$directory" ]] || {
      echo "ERROR: Missing extracted directory: $TEST_CASE/$directory" >&2; exit 1;
   }
done
for dictionary in controlDict decomposeParDict; do
   [[ -f "$TEST_CASE/system/$dictionary" ]] || {
      echo "ERROR: Missing extracted dictionary: $dictionary" >&2; exit 1;
   }
done

# =============================================================================
# 6. Set the simulation controls and decomposition
# =============================================================================
printSection "6. Set the simulation controls and decomposition"
cd -- "$TEST_CASE"

singularity exec "$SINGULARITY_IMAGE" foamDictionary system/controlDict \
   -entry runTimeModifiable -set no
singularity exec "$SINGULARITY_IMAGE" foamDictionary system/controlDict \
   -entry endTime -set "$newEndTime"
# runTime makes writeInterval count simulation time, not time steps.
singularity exec "$SINGULARITY_IMAGE" foamDictionary system/controlDict \
   -entry writeControl -set "$newWriteControl"
singularity exec "$SINGULARITY_IMAGE" foamDictionary system/controlDict \
   -entry writeInterval -set "$newWriteInterval"
singularity exec "$SINGULARITY_IMAGE" foamDictionary system/decomposeParDict \
   -entry numberOfSubdomains -set "$nProcs"
singularity exec "$SINGULARITY_IMAGE" foamDictionary system/decomposeParDict \
   -entry method -set "$newMethod"
singularity exec "$SINGULARITY_IMAGE" foamDictionary system/decomposeParDict \
   -entry coeffs/n -set "($decompositionX $decompositionY $decompositionZ)"

# =============================================================================
# 7. Read back the settings to confirm the updates
# =============================================================================
printSection "7. Read back the settings to confirm the updates"
runTimeModifiable=$(singularity exec "$SINGULARITY_IMAGE" \
   foamDictionary system/controlDict -entry runTimeModifiable -value)
endTime=$(singularity exec "$SINGULARITY_IMAGE" \
   foamDictionary system/controlDict -entry endTime -value)
writeControl=$(singularity exec "$SINGULARITY_IMAGE" \
   foamDictionary system/controlDict -entry writeControl -value)
writeInterval=$(singularity exec "$SINGULARITY_IMAGE" \
   foamDictionary system/controlDict -entry writeInterval -value)
numberOfSubdomains=$(singularity exec "$SINGULARITY_IMAGE" \
   foamDictionary system/decomposeParDict -entry numberOfSubdomains -value)
decompositionMethod=$(singularity exec "$SINGULARITY_IMAGE" \
   foamDictionary system/decomposeParDict -entry method -value)
decompositionN=$(singularity exec "$SINGULARITY_IMAGE" \
   foamDictionary system/decomposeParDict -entry coeffs/n -value)

[[ "$runTimeModifiable" == no ]] || {
   echo "ERROR: Expected runTimeModifiable=no; found $runTimeModifiable" >&2; exit 1;
}
[[ "$endTime" == "$newEndTime" ]] || {
   echo "ERROR: endTime read-back mismatch: $endTime" >&2; exit 1;
}
[[ "$writeControl" == "$newWriteControl" ]] || {
   echo "ERROR: writeControl read-back mismatch: $writeControl" >&2; exit 1;
}
[[ "$writeInterval" == "$newWriteInterval" ]] || {
   echo "ERROR: writeInterval read-back mismatch: $writeInterval" >&2; exit 1;
}
[[ "$numberOfSubdomains" == "$nProcs" ]] || {
   echo "ERROR: numberOfSubdomains read-back mismatch: $numberOfSubdomains" >&2; exit 1;
}
[[ "$decompositionMethod" == "$newMethod" ]] || {
   echo "ERROR: method read-back mismatch: $decompositionMethod" >&2; exit 1;
}
read -r actualX actualY actualZ extraValue <<< "${decompositionN//[()]/}"
[[ "$actualX" == "$decompositionX" && "$actualY" == "$decompositionY" &&
   "$actualZ" == "$decompositionZ" && -z "$extraValue" ]] || {
   echo "ERROR: Decomposition vector read-back mismatch: $decompositionN" >&2; exit 1;
}
echo "All settings confirmed in system/controlDict and system/decomposeParDict"

# =============================================================================
# 8. Summary
# =============================================================================
printSection "8. Summary"
echo "$thisScript: EXTRACTION AND SETUP COMPLETE"
echo "Case directory: $TEST_CASE"
echo "runTimeModifiable=$runTimeModifiable"
echo "endTime=$endTime, writeControl=$writeControl, writeInterval=$writeInterval"
echo "numberOfSubdomains=$numberOfSubdomains, method=$decompositionMethod, n=$decompositionN"
