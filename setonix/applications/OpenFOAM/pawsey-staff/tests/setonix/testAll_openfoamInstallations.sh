#!/usr/bin/env bash
# =============================================================================
# OpenFOAM installation functional-test orchestrator
# =============================================================================
#
# Purpose
# -------
# Coordinate the existing compile-tool and tutorial launchers across a selected
# matrix of OpenFOAM recipes and runtime modes. This script does not build images
# and does not reproduce any test logic already owned by those launchers.
#
# Matrix dimensions
# -----------------
# Each selected recipe is tested with every selected runtime and test type:
#
#   recipes x runtimes x tests
#
# Runtimes:
#   image       use the single SIF below artifacts/singularity/latest;
#   shpc        use the SHPC module derived by the launcher from the recipe;
#   bare-metal  use the native module derived by the launcher from the recipe.
#
# Image mode always receives the selected/default Singularity module. Plain SHPC
# mode retains the module loaded by the containerized OpenFOAM module. When
# --singularity-module is explicitly supplied, that override is also passed to
# SHPC tests. Bare-metal mode never receives a Singularity-module option.
#
# Tests:
#   compile     build and execute a copied OpenFOAM application;
#   tutorial    extract, prepare, and run the configured tutorial case.
#
# Execution and failure model
# ---------------------------
# Tests run sequentially. By default, each launcher waits for its Slurm work and
# returns an authoritative final result. Failures are recorded without stopping
# later entries, and the campaign exits nonzero after the complete summary if any
# entry failed.
#
# With --submit-only, launchers return after successful submission. Those entries
# are reported as SUBMITTED, never PASS, because final job results are not read.
#
# Required layout
# ---------------
# Store this script beside the two canonical launchers under tests/setonix. Unless
# --root-directory is supplied, the project root is inferred as two levels above
# this script.

# Detect accidental references to unset variables. Individual test failures remain
# under explicit status handling so later matrix entries can continue.
set -u

# =============================================================================
# Script identity and default matrix
# =============================================================================
# Resolve the script directory independently of the caller's working directory.
thisScript=$(basename "$0")
scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Maintained default recipe order. --only-directories replaces this array for one
# invocation without changing the file.
recipeDirectories=(
   openfoam/v2012
   openfoam/v2206
   openfoam/v2212
   openfoam/v2406
   openfoam/v2412
   openfoam/v2606
   openfoam-org/10
   openfoam-org/12
   openfoam-org/14
)

# Maintained default runtime and test selections. The corresponding user list
# options replace these arrays only after command-line parsing succeeds.
selectedRuntimes=(image)
#selectedRuntimes=(image shpc bare-metal)
selectedTests=(compile tutorial)

# Default values for user-supplied options.
rootDirectoryInput=""
onlyDirectoriesInput=""
runtimesInput=""
testsInput=""
singularityModule="singularity/4.3.5-mpi"
singularityModuleSpecified=false
partitionInput=""
reservationInput=""
submitOnly=false

# =============================================================================
# Command-line interface
# =============================================================================
# Keep this help contract synchronized with parser values and runtime defaults.
usage() {
   cat <<USAGE
Usage:
  $thisScript [options]

Selection options:
  --only-directories <list>      Comma-separated recipe directories. The supplied
                                 order is preserved.
  --runtimes <list>              Comma-separated subset of:
                                 image,shpc,bare-metal
                                 Default: image
  --tests <list>                 Comma-separated subset of:
                                 compile,tutorial
                                 Default: compile,tutorial

Container-runtime option:
  --singularity-module <module>  Module used for image tests, or an explicit SHPC override
                                 Default for image mode: singularity/4.3.5-mpi

Path and Slurm options:
  --root-directory <directory>   Project root containing openfoam/, openfoam-org/
                                 and tests/setonix/. By default, derive it from
                                 this script's tests/setonix location.
  --partition, -p <name>         Pass a partition override to both launchers
  --reservation <name>           Pass a reservation to both launchers
  --submit-only                  Submit tests without waiting. Summary entries
                                 are reported as SUBMITTED rather than PASS.
  --help, -h                     Show this help message and exit

Examples:
  $thisScript

  $thisScript \
     --only-directories openfoam/v2406,openfoam-org/10 \
     --runtimes image,shpc,bare-metal

  $thisScript \
     --runtimes image \
     --singularity-module singularity/4.3.5-mpi

  $thisScript --runtimes shpc --tests compile
USAGE
}

# Parse all supported options and reject incomplete or unknown arguments early.
while [[ $# -gt 0 ]]; do
   case "$1" in
      --only-directories)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --only-directories requires <list>" >&2; usage >&2; exit 1; }
         onlyDirectoriesInput="$2"
         shift 2
         ;;
      --runtimes)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --runtimes requires <list>" >&2; usage >&2; exit 1; }
         runtimesInput="$2"
         shift 2
         ;;
      --tests)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --tests requires <list>" >&2; usage >&2; exit 1; }
         testsInput="$2"
         shift 2
         ;;
      --singularity-module)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --singularity-module requires <module>" >&2; usage >&2; exit 1; }
         singularityModule="$2"
         singularityModuleSpecified=true
         shift 2
         ;;
      --root-directory)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --root-directory requires <directory>" >&2; usage >&2; exit 1; }
         rootDirectoryInput="$2"
         shift 2
         ;;
      --partition|-p)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --partition requires <name>" >&2; usage >&2; exit 1; }
         partitionInput="$2"
         shift 2
         ;;
      --reservation)
         [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --reservation requires <name>" >&2; usage >&2; exit 1; }
         reservationInput="$2"
         shift 2
         ;;
      --submit-only)
         submitOnly=true
         shift
         ;;
      --help|-h)
         usage
         exit 0
         ;;
      *)
         echo "ERROR: Unknown option: $1" >&2
         usage >&2
         exit 1
         ;;
   esac
done

# Convert an ordered comma-separated value into the named array. Empty elements
# are rejected because they otherwise create ambiguous matrix selections.
parseCommaList() {
   local input=$1
   local outputName=$2
   local -n outputRef=$outputName
   local item
   local -a rawItems=()

   IFS=',' read -r -a rawItems <<< "$input"
   outputRef=()
   for item in "${rawItems[@]}"; do
      [[ -n "$item" ]] || { echo "ERROR: Empty item in comma-separated list: $input" >&2; exit 1; }
      outputRef+=("$item")
   done
}

# =============================================================================
# Selection normalization and validation
# =============================================================================
# Apply only the lists explicitly supplied by the caller; omitted dimensions keep
# their documented defaults.
if [[ -n "$onlyDirectoriesInput" ]]; then
   parseCommaList "$onlyDirectoriesInput" recipeDirectories
fi
if [[ -n "$runtimesInput" ]]; then
   parseCommaList "$runtimesInput" selectedRuntimes
fi
if [[ -n "$testsInput" ]]; then
   parseCommaList "$testsInput" selectedTests
fi

# Validate every requested matrix value before locating files or submitting work.
for runtime in "${selectedRuntimes[@]}"; do

   # Runtime mode supplies exactly one mutually exclusive launcher selector. Image
   # mode always passes the selected/default module. SHPC passes it only when the
   # caller explicitly requested an override; bare-metal never passes it.
   case "$runtime" in
      image|shpc|bare-metal) ;;
      *) echo "ERROR: Unsupported runtime '$runtime'; choose image, shpc, or bare-metal" >&2; exit 1 ;;
   esac
done
for testName in "${selectedTests[@]}"; do
   # Test type selects the launcher; that launcher retains ownership of the
   # detailed compile or tutorial workflow and its persistent artifacts.
   case "$testName" in
      compile|tutorial) ;;
      *) echo "ERROR: Unsupported test '$testName'; choose compile or tutorial" >&2; exit 1 ;;
   esac
done

# =============================================================================
# Project and launcher discovery
# =============================================================================
# An explicit root is authoritative. Otherwise derive the project root from the
# required tests/setonix placement of this orchestrator.
if [[ -n "$rootDirectoryInput" ]]; then
   [[ -d "$rootDirectoryInput" ]] || { echo "ERROR: Root directory not found: $rootDirectoryInput" >&2; exit 1; }
   rootDirectory=$(realpath "$rootDirectoryInput")
else
   rootDirectory=$(realpath "${scriptDir}/../..")
fi

# The canonical launchers must be executable siblings. Check their shell syntax
# now to avoid discovering a launcher defect part-way through a long campaign.
compileLauncher="${scriptDir}/openfoamCompileToolTestLauncher.sh"
tutorialLauncher="${scriptDir}/openfoamTutorialTestLauncher.sh"
for launcher in "$compileLauncher" "$tutorialLauncher"; do
   [[ -x "$launcher" ]] || { echo "ERROR: Launcher is missing or not executable: $launcher" >&2; exit 1; }
   bash -n "$launcher" || { echo "ERROR: Bash syntax check failed: $launcher" >&2; exit 1; }
done

# Assemble Slurm and submission-mode overrides once. Runtime selectors are added
# separately for each matrix entry so exactly one runtime reaches each launcher.
commonLauncherArgs=()
[[ -n "$partitionInput" ]] && commonLauncherArgs+=(--partition "$partitionInput")
[[ -n "$reservationInput" ]] && commonLauncherArgs+=(--reservation "$reservationInput")
[[ "$submitOnly" == true ]] && commonLauncherArgs+=(--submit-only)

# =============================================================================
# Result and artifact helpers
# =============================================================================
# Retain one ordered result record per matrix entry and separate completed passes
# from jobs accepted in submission-only mode.
results=()
failedCount=0
submittedCount=0
passedCount=0

# Append one result and increment exactly one aggregate counter.
recordResult() {
   local recipe=$1
   local runtime=$2
   local testName=$3
   local result=$4
   local detail=${5:-}

   results+=("${recipe}|${runtime}|${testName}|${result}|${detail}")
   case "$result" in
      PASS) ((passedCount += 1)) ;;
      SUBMITTED) ((submittedCount += 1)) ;;
      FAIL) ((failedCount += 1)) ;;
   esac
}

# Resolve image mode through the recipe's stable latest directory. Requiring one
# SIF prevents arbitrary selection when artifacts are missing or conflicting.
resolveImage() {
   local recipePath=$1
   local latestDirectory="${recipePath}/artifacts/singularity/latest"
   local -a images=()

   [[ -d "$latestDirectory" ]] || return 1
   shopt -s nullglob
   images=("${latestDirectory}"/*.sif)
   shopt -u nullglob
   [[ ${#images[@]} -eq 1 ]] || return 2
   realpath "${images[0]}"
}

# =============================================================================
# Single matrix-entry execution
# =============================================================================
# Select the authoritative launcher, construct one runtime selector plus any
# compatible runtime override, invoke it, and translate its exit status into
# PASS, SUBMITTED, or FAIL.
runMatrixEntry() {
   local recipe=$1
   local recipePath=$2
   local runtime=$3
   local testName=$4
   local launcher
   local -a runtimeArgs=()
   local image=""
   local status

   case "$testName" in
      compile) launcher=$compileLauncher ;;
      tutorial) launcher=$tutorialLauncher ;;
   esac

   case "$runtime" in
      image)
         image=$(resolveImage "$recipePath")
         status=$?
         if [[ $status -ne 0 ]]; then
            if [[ $status -eq 1 ]]; then
               recordResult "$recipe" "$runtime" "$testName" FAIL "missing artifacts/singularity/latest"
            else
               recordResult "$recipe" "$runtime" "$testName" FAIL "expected exactly one SIF under artifacts/singularity/latest"
            fi
            return
         fi
         runtimeArgs=(--image "$image" --singularity-module "$singularityModule")
         ;;
      shpc)
         runtimeArgs=(--shpc)
         if [[ "$singularityModuleSpecified" == true ]]; then
            runtimeArgs+=(--singularity-module "$singularityModule")
         fi
         ;;
      bare-metal)
         runtimeArgs=(--bare-metal)
         ;;
   esac

   echo
   echo "================================================================"
   echo "Recipe : $recipe"
   echo "Runtime: $runtime"
   echo "Test   : $testName"
   [[ -n "$image" ]] && echo "Image  : $image"
   echo "================================================================"

   # Normal launcher success is authoritative. Under --submit-only, success means
   # only that Slurm accepted the workflow, so record SUBMITTED instead of PASS.
   if "$launcher" \
      --recipe-dir "$recipePath" \
      "${runtimeArgs[@]}" \
      "${commonLauncherArgs[@]}"; then
      if [[ "$submitOnly" == true ]]; then
         recordResult "$recipe" "$runtime" "$testName" SUBMITTED
      else
         recordResult "$recipe" "$runtime" "$testName" PASS
      fi
   else
      status=$?
      recordResult "$recipe" "$runtime" "$testName" FAIL "launcher exit status $status"
   fi
}

# =============================================================================
# Resolved campaign plan
# =============================================================================
# Print the complete plan before execution so the campaign can be reconstructed
# from its console log.
echo "============================================================"
echo "OpenFOAM installation functional-test matrix"
echo "============================================================"
echo "Project root       : $rootDirectory"
echo "Compile launcher   : $compileLauncher"
echo "Tutorial launcher  : $tutorialLauncher"
echo "Recipes            : ${recipeDirectories[*]}"
echo "Runtimes           : ${selectedRuntimes[*]}"
echo "Tests              : ${selectedTests[*]}"
if [[ " ${selectedRuntimes[*]} " == *" image "* ]]; then
   echo "Image Singularity module : $singularityModule"
fi
if [[ " ${selectedRuntimes[*]} " == *" shpc "* ]]; then
   if [[ "$singularityModuleSpecified" == true ]]; then
      echo "SHPC Singularity override: $singularityModule"
   else
      echo "SHPC Singularity override: none"
   fi
fi
echo "Partition override : ${partitionInput:-none}"
echo "Reservation        : ${reservationInput:-none}"
echo "Mode               : $([[ "$submitOnly" == true ]] && echo 'submit only' || echo 'submit and wait')"

# =============================================================================
# Matrix traversal
# =============================================================================
# Traverse recipes, then runtimes, then tests. A missing recipe records all of its
# requested entries as failures without preventing later recipes from running.
for recipe in "${recipeDirectories[@]}"; do
   recipePath="${rootDirectory}/${recipe}"
   if [[ ! -d "$recipePath" ]]; then
      for runtime in "${selectedRuntimes[@]}"; do
         for testName in "${selectedTests[@]}"; do
            recordResult "$recipe" "$runtime" "$testName" FAIL "recipe directory not found"
         done
      done
      continue
   fi

   recipePath=$(realpath "$recipePath")
   for runtime in "${selectedRuntimes[@]}"; do
      for testName in "${selectedTests[@]}"; do
         runMatrixEntry "$recipe" "$recipePath" "$runtime" "$testName"
      done
   done
done

# =============================================================================
# Final summary and process status
# =============================================================================
# Preserve selection order in the report. The final exit status represents the
# complete campaign rather than only the last launcher invocation.
echo
echo "================================================================"
echo "OpenFOAM installation functional-test summary"
echo "================================================================"
printf '%-20s  %-10s  %-9s  %-10s  %s\n' "RECIPE" "RUNTIME" "TEST" "RESULT" "DETAIL"
printf '%-20s  %-10s  %-9s  %-10s  %s\n' "--------------------" "----------" "---------" "----------" "------"
for entry in "${results[@]}"; do
   IFS='|' read -r recipe runtime testName result detail <<< "$entry"
   printf '%-20s  %-10s  %-9s  %-10s  %s\n' "$recipe" "$runtime" "$testName" "$result" "$detail"
done

echo
echo "Passed    : $passedCount"
echo "Submitted : $submittedCount"
echo "Failed    : $failedCount"

# Any failed entry fails the campaign. Otherwise retain the semantic difference
# between completed tests and workflows that were only submitted.
if (( failedCount > 0 )); then
   echo "RESULT: One or more OpenFOAM installation tests failed." >&2
   exit 1
fi
if [[ "$submitOnly" == true ]]; then
   echo "RESULT: All selected tests were submitted successfully; final job results were not collected."
else
   echo "RESULT: All selected OpenFOAM installation tests passed."
fi
