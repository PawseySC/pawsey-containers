#!/bin/bash --login

# --- Tutorial settings
OPENFOAM_VERSION="v2606"
CASE_NAME="periodicPlaneChannel"
nProcs=4   #Number of total processors in decomposition for this case
mGroup=2   #Size of the groups for collated fileHandling (check recommendation for Setonix in Pawsey documentation)
newEndTime=100
newWriteInterval=20
newMethod="simple"
decompositionX=1
decompositionY=2
decompositionZ=2

# --- Initial settings
thisScript=$(basename "$0")
overwriteCase=false

# --- Command-line help
usage() {
   cat <<USAGE
Usage:
  $thisScript [options]
  $thisScript --help

Optional settings:
  --overwrite                 Remove and replace only the existing target case
  --help, -h                  Show this help message and exit

USAGE
}

# --- Parse command-line arguments
while [[ $# -gt 0 ]]; do
   case "$1" in
      --overwrite)
         overwriteCase=true
         shift
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

#--- Load neccessary modules and/or image:
SINGULARITY_MODULE=${SINGULARITY_MODULE:-singularity/4.3.5-mpi}
module load $SINGULARITY_MODULE
module list
export SINGULARITY_IMAGE=${SINGULARITY_IMAGE:-"${MYSCRATCH}/pawsey-containers/setonix/applications/OpenFOAM/openfoam/v2606/artifacts/singularity/latest/openfoam--v2606-gcc13DPInt32Opt-mpich4.2.2-ubuntu24.04.sif"}
echo "Using openfoam singularity image:"
echo "SINGULARITY_IMAGE=$SINGULARITY_IMAGE"
echo

#--- Path definitions
TUTORIAL_WORK_ROOT=${TUTORIAL_WORK_ROOT:-"${MYSCRATCH}/OpenFOAM/${USER}-${OPENFOAM_VERSION}/tutorialTesting"}
hostRunDir="$TUTORIAL_WORK_ROOT/run"
TEST_CASE="${hostRunDir}/${CASE_NAME}"


# --- Step 2: Prepare a clean host destination
# Do not overwrite an existing case. The launcher must use an isolated work root
# or remove a previous test run explicitly before starting this stage.
echo "$thisScript: -----------------------------------------"
echo "Step 2 - Preparing the host destination"

mkdir -p "$hostRunDir" || {
   echo "ERROR: Could not create host run directory: $hostRunDir" >&2
   exit 1
}

if [[ -e "$TEST_CASE" ]]; then
   if [[ "$overwriteCase" == "true" ]]; then
      echo "Removing existing target case: $TEST_CASE"
      rm -rf "$TEST_CASE" || {
         echo "ERROR: Failed to remove existing target case: $TEST_CASE" >&2
         exit 1
      }
   else
      echo "ERROR: Target case already exists: $TEST_CASE" >&2
      echo "       Use --overwrite to replace it, or select another --work-root." >&2
      exit 1
   fi
fi

echo "Host run directory: $hostRunDir"
echo "Target case: $TEST_CASE"
echo "PASS: Host destination ready"
echo

# --- Step 3: Locate the tutorial case inside the image
# Exactly one match is required. Multiple matches would make case selection
# ambiguous and could cause a different tutorial to be tested across versions.
echo "$thisScript: -----------------------------------------"
echo "Step 3 - Finding the '$CASE_NAME' tutorial inside the image"
internalCaseOutput=$(singularity exec "$SINGULARITY_IMAGE" \
   bash -c 'find "$FOAM_TUTORIALS" -type d -name "$1" -print' bash "$CASE_NAME") || {
      echo "ERROR: Failed to search FOAM_TUTORIALS inside the image" >&2
      exit 1
   }

internalCases=()
if [[ -n "$internalCaseOutput" ]]; then
   mapfile -t internalCases <<< "$internalCaseOutput"
fi

[[ ${#internalCases[@]} -eq 1 ]] || {
   echo "ERROR: Expected exactly one tutorial directory named '$CASE_NAME'; found ${#internalCases[@]}" >&2
   printf '  %s\n' "${internalCases[@]}" >&2
   exit 1
}
internalCase=${internalCases[0]}

echo "Tutorial source: $internalCase"
echo "PASS: Unique tutorial case found"
echo

# --- Step 4: Copy the tutorial case to the host
echo "$thisScript: -----------------------------------------"
echo "Step 4 - Copying the tutorial case to the host"
singularity exec "$SINGULARITY_IMAGE" cp -a --no-preserve=timestamps "$internalCase" "$TEST_CASE" || {
   echo "ERROR: Failed to copy the tutorial case" >&2
   exit 1
}

echo "PASS: Tutorial case copied"
echo

# --- Step 5: Validate the extracted case
# These checks establish the minimum case structure required by preFoam.slurm.sh
# and runFoam.slurm.sh. Version-specific scripts may perform additional checks themselves.
echo "$thisScript: -----------------------------------------"
echo "Step 5 - Validating the extracted tutorial case"
[[ -d "$TEST_CASE" ]] || { echo "ERROR: Extracted case directory not found: $TEST_CASE" >&2; exit 1; }
[[ -d "${TEST_CASE}/system" ]] || { echo "ERROR: Missing directory: ${TEST_CASE}/system" >&2; exit 1; }
[[ -d "${TEST_CASE}/constant" ]] || { echo "ERROR: Missing directory: ${TEST_CASE}/constant" >&2; exit 1; }
[[ -d "${TEST_CASE}/0" || -d "${TEST_CASE}/0.orig" ]] || {
   echo "ERROR: Missing initial-condition directory: ${TEST_CASE}/0 or ${TEST_CASE}/0.orig" >&2
   exit 1
}
[[ -f "${TEST_CASE}/system/controlDict" ]] || {
   echo "ERROR: Missing dictionary: ${TEST_CASE}/system/controlDict" >&2
   exit 1
}
[[ -f "${TEST_CASE}/system/decomposeParDict" ]] || {
   echo "ERROR: Missing dictionary: ${TEST_CASE}/system/decomposeParDict" >&2
   exit 1
}

echo "Extracted case: $TEST_CASE"
echo "PASS: Extracted tutorial case is complete"
echo

# --- Step 6: Update the tutorial case for the functional test
echo "$thisScript: -----------------------------------------"
echo "Step 6 - Updating the extracted tutorial case"
# --- Shorten the tutorial execution and set a suitable output interval
echo "Updating system/controlDict for the functional test"
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_IMAGE \
   foamDictionary "${TEST_CASE}/system/controlDict" -entry endTime -set $newEndTime || {
      echo "ERROR: Failed to set endTime in system/controlDict" >&2
      exit 1
   }
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_IMAGE \
   foamDictionary "${TEST_CASE}/system/controlDict" -entry writeInterval -set $newWriteInterval || {
      echo "ERROR: Failed to set writeInterval in system/controlDict" >&2
      exit 1
   }
endTime=$(singularity exec $SINGULARITY_IMAGE \
   foamDictionary "${TEST_CASE}/system/controlDict" -entry endTime -value) || {
      echo "ERROR: Failed to read endTime from system/controlDict" >&2
      exit 1
   }
writeInterval=$(singularity exec $SINGULARITY_IMAGE \
   foamDictionary "${TEST_CASE}/system/controlDict" -entry writeInterval -value) || {
      echo "ERROR: Failed to read writeInterval from system/controlDict" >&2
      exit 1
   }
[[ "$endTime" == "$newEndTime" ]] || {
   echo "ERROR: Expected endTime=$newEndTime; found endTime=$endTime" >&2
   exit 1
}
[[ "$writeInterval" == "$newWriteInterval" ]] || {
   echo "ERROR: Expected writeInterval=$newWriteInterval; found writeInterval=$writeInterval" >&2
   exit 1
}
echo "PASS: controlDict updated with endTime=$endTime and writeInterval=$writeInterval"
echo

# --- Set the decomposition size and distribution for this functional test
echo "Updating system/decomposeParDict for $nProcs processor tasks"
(( decompositionX * decompositionY * decompositionZ == nProcs )) || {
   echo "ERROR: Decomposition ($decompositionX $decompositionY $decompositionZ) does not produce $nProcs subdomains" >&2
   exit 1
}
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_IMAGE \
   foamDictionary "${TEST_CASE}/system/decomposeParDict" \
   -entry numberOfSubdomains -set "$nProcs" || {
      echo "ERROR: Failed to set numberOfSubdomains" >&2
      exit 1
   }
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_IMAGE \
   foamDictionary "${TEST_CASE}/system/decomposeParDict" \
   -entry method -set $newMethod || {
      echo "ERROR: Failed to set the decomposition method" >&2
      exit 1
   }
srun -N 1 -n 1 -c 1 singularity exec $SINGULARITY_IMAGE \
   foamDictionary "${TEST_CASE}/system/decomposeParDict" \
   -entry coeffs/n \
   -set "($decompositionX $decompositionY $decompositionZ)" || {
      echo "ERROR: Failed to set the simple decomposition coefficients" >&2
      exit 1
   }
numberOfSubdomains=$(singularity exec $SINGULARITY_IMAGE \
   foamDictionary "${TEST_CASE}/system/decomposeParDict" \
   -entry numberOfSubdomains -value) || {
      echo "ERROR: Failed to read numberOfSubdomains" >&2
      exit 1
   }
decompositionMethod=$(singularity exec $SINGULARITY_IMAGE \
   foamDictionary "${TEST_CASE}/system/decomposeParDict" \
   -entry method -value) || {
      echo "ERROR: Failed to read the decomposition method" >&2
      exit 1
   }
decompositionN=$(singularity exec $SINGULARITY_IMAGE \
   foamDictionary "${TEST_CASE}/system/decomposeParDict" \
   -entry coeffs/n -value) || {
      echo "ERROR: Failed to read the decomposition coefficients" >&2
      exit 1
   }
[[ "$numberOfSubdomains" == "$nProcs" ]] || {
   echo "ERROR: Expected numberOfSubdomains=$nProcs; found $numberOfSubdomains" >&2
   exit 1
}
[[ "$decompositionMethod" == "$newMethod" ]] || {
   echo "ERROR: Expected method=$newMethod; found $decompositionMethod" >&2
   exit 1
}
# Parse the returned vector so harmless whitespace differences are ignored.
read -r actualX actualY actualZ extraValue <<< "${decompositionN//[()]/}"
[[ "$actualX" == "$decompositionX" &&
   "$actualY" == "$decompositionY" &&
   "$actualZ" == "$decompositionZ" &&
   -z "$extraValue" ]] || {
   echo "ERROR: Expected coeffs/n=($decompositionX $decompositionY $decompositionZ); found $decompositionN" >&2
   exit 1
}
echo "PASS: decomposeParDict configured for $numberOfSubdomains subdomains"
echo "      method=$decompositionMethod, n=$decompositionN"
echo

# --- Final summary
echo "======================================================"
echo "$thisScript: FINAL SUMMARY"
echo "======================================================"
echo "Tutorial case: $CASE_NAME"
echo "Extracted case: $TEST_CASE"
echo "ALL STEPS PASSED: OpenFOAM tutorial case extracted successfully."
exit 0
