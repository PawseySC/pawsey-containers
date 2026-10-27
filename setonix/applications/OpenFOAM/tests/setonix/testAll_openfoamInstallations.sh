#!/usr/bin/env bash
# =============================================================================
# OpenFOAM installation functional-test orchestrator
# =============================================================================
#
# Run the existing compile-tool and tutorial functional-test launchers across a
# selected matrix of OpenFOAM recipe directories and installed runtime modes.
# This script does not build images and does not reimplement either test.
#
# By default, it tests all configured recipes with:
#   - the SIF below <recipe>/artifacts/singularity/latest;
#   - the SHPC module derived by each launcher;
#   - the bare-metal module derived by each launcher.
#
# Tests run sequentially and wait for authoritative final results unless
# --submit-only is selected. Every matrix entry is attempted even after earlier
# failures. The final exit status is nonzero if any test fails.

set -u

thisScript=$(basename "$0")
scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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

selectedRuntimes=(image shpc bare-metal)
selectedTests=(compile tutorial)
rootDirectoryInput=""
onlyDirectoriesInput=""
runtimesInput=""
testsInput=""
singularityModule="singularity/4.3.5-mpi"
partitionInput=""
reservationInput=""
submitOnly=false

usage() {
   cat <<USAGE
Usage:
  $thisScript [options]

Selection options:
  --only-directories <list>      Comma-separated recipe directories. The supplied
                                 order is preserved.
  --runtimes <list>              Comma-separated subset of:
                                 image,shpc,bare-metal
                                 Default: image,shpc,bare-metal
  --tests <list>                 Comma-separated subset of:
                                 compile,tutorial
                                 Default: compile,tutorial

Image-runtime option:
  --singularity-module <module>  Singularity module used for image-mode tests
                                 Default: singularity/4.3.5-mpi

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
     --singularity-module singularity/4.1.0-mpi

  $thisScript --runtimes shpc --tests compile
USAGE
}

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

if [[ -n "$onlyDirectoriesInput" ]]; then
   parseCommaList "$onlyDirectoriesInput" recipeDirectories
fi
if [[ -n "$runtimesInput" ]]; then
   parseCommaList "$runtimesInput" selectedRuntimes
fi
if [[ -n "$testsInput" ]]; then
   parseCommaList "$testsInput" selectedTests
fi

for runtime in "${selectedRuntimes[@]}"; do
   case "$runtime" in
      image|shpc|bare-metal) ;;
      *) echo "ERROR: Unsupported runtime '$runtime'; choose image, shpc, or bare-metal" >&2; exit 1 ;;
   esac
done
for testName in "${selectedTests[@]}"; do
   case "$testName" in
      compile|tutorial) ;;
      *) echo "ERROR: Unsupported test '$testName'; choose compile or tutorial" >&2; exit 1 ;;
   esac
done

if [[ -n "$rootDirectoryInput" ]]; then
   [[ -d "$rootDirectoryInput" ]] || { echo "ERROR: Root directory not found: $rootDirectoryInput" >&2; exit 1; }
   rootDirectory=$(realpath "$rootDirectoryInput")
else
   rootDirectory=$(realpath "${scriptDir}/../..")
fi

compileLauncher="${scriptDir}/openfoamCompileToolTestLauncher.sh"
tutorialLauncher="${scriptDir}/openfoamTutorialTestLauncher.sh"
for launcher in "$compileLauncher" "$tutorialLauncher"; do
   [[ -x "$launcher" ]] || { echo "ERROR: Launcher is missing or not executable: $launcher" >&2; exit 1; }
   bash -n "$launcher" || { echo "ERROR: Bash syntax check failed: $launcher" >&2; exit 1; }
done

commonLauncherArgs=()
[[ -n "$partitionInput" ]] && commonLauncherArgs+=(--partition "$partitionInput")
[[ -n "$reservationInput" ]] && commonLauncherArgs+=(--reservation "$reservationInput")
[[ "$submitOnly" == true ]] && commonLauncherArgs+=(--submit-only)

results=()
failedCount=0
submittedCount=0
passedCount=0

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
   echo "Singularity module : $singularityModule"
fi
echo "Partition override : ${partitionInput:-none}"
echo "Reservation        : ${reservationInput:-none}"
echo "Mode               : $([[ "$submitOnly" == true ]] && echo 'submit only' || echo 'submit and wait')"

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

if (( failedCount > 0 )); then
   echo "RESULT: One or more OpenFOAM installation tests failed." >&2
   exit 1
fi
if [[ "$submitOnly" == true ]]; then
   echo "RESULT: All selected tests were submitted successfully; final job results were not collected."
else
   echo "RESULT: All selected OpenFOAM installation tests passed."
fi
