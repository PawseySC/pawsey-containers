#!/bin/bash --login
# Compare selective host-library binds without changing the normal compile test.
# See README-link-diagnostics.md for submission and interpretation.

#SBATCH --job-name=openfoam-link-diagnostics
#SBATCH --partition=work
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=14GB
#SBATCH --time=00:15:00

set -euo pipefail

usage() {
   echo "Usage: sbatch $0 --image <sif> --output-dir <directory> [--singularity-module <module>]"
}

image=""
outputDir=""
singularityModule="singularity/4.3.5-mpi"
while [[ $# -gt 0 ]]; do
   case "$1" in
      --image|--output-dir|--singularity-module)
         [[ $# -ge 2 && -n "$2" ]] || {
            echo "ERROR: $1 requires a value" >&2
            exit 1
         }
         case "$1" in
            --image) image="$2" ;;
            --output-dir) outputDir="$2" ;;
            --singularity-module) singularityModule="$2" ;;
         esac
         shift 2
         ;;
      --help|-h) usage; exit 0 ;;
      *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 1 ;;
   esac
done
[[ -f "$image" && -n "$outputDir" ]] || {
   echo "ERROR: An existing --image and an --output-dir are required" >&2
   usage >&2
   exit 1
}
image=$(realpath "$image")
mkdir -p "$outputDir"
outputDir=$(realpath "$outputDir")
runDir=$(mktemp -d "${outputDir}/$(date +%Y%m%dT%H%M%S%z)_${SLURM_JOB_ID:-local}_XXXXXX")
exec > >(tee "$runDir/job.log") 2>&1
recordExitStatus() {
   local status=$?
   printf '%s\n' "$status" > "$runDir/job.exit-status.txt"
}
trap recordExitStatus EXIT
echo "Artifacts: $runDir"

module load "$singularityModule"
module list
module show "$singularityModule" > "$runDir/module.txt" 2>&1
singularity --version
printf 'Image: %s\n' "$image"
sha256sum "$image" > "$runDir/image.sha256"
baselineBind=${SINGULARITY_BINDPATH:?ERROR: Module did not set SINGULARITY_BINDPATH}
[[ "$baselineBind" != *"/usr/lib64:/host_lib64"* ]] || {
   echo "ERROR: Select a module with selective binds, not the broad /host_lib64 directory bind" >&2
   exit 1
}
[[ -z "${SINGULARITY_BIND:-}" && -z "${APPTAINER_BIND:-}" && -z "${APPTAINER_BINDPATH:-}" ]] || {
   echo "ERROR: Unset additional SINGULARITY_BIND/APPTAINER binds before running this controlled test" >&2
   exit 1
}
for lib in /usr/lib64/libcxi.so.1 /usr/lib64/libnl-3.so.200 /usr/lib64/libnl-genl-3.so.200; do
   {
      printf '\n=== %s ===\n' "$lib"
      readlink -f "$lib"
      readelf -d "$lib"
      readelf --dyn-syms --wide "$lib"
   } >> "$runDir/host-libraries.txt"
done
printf 'case\tcompile_exit\thelp_exit\n' > "$runDir/results.tsv"
failed=0

for caseName in A-selective B-host-libnl C-host-libnl-pair D-host-directory; do
   caseDir="$runDir/$caseName"
   mkdir -p "$caseDir/work"
   export SINGULARITY_BINDPATH="$baselineBind"
   case "$caseName" in
      B-host-libnl)
         SINGULARITY_BINDPATH+=",/usr/lib64/libnl-3.so.200:/host_lib64/libnl-3.so.200"
         ;;
      C-host-libnl-pair)
         SINGULARITY_BINDPATH+=",/usr/lib64/libnl-3.so.200:/host_lib64/libnl-3.so.200"
         SINGULARITY_BINDPATH+=",/usr/lib64/libnl-genl-3.so.200:/host_lib64/libnl-genl-3.so.200"
         ;;
      D-host-directory)
         SINGULARITY_BINDPATH=${baselineBind//\/usr\/lib64\/liblustreapi.so:\/host_lib64\/liblustreapi.so/\/usr\/lib64:\/host_lib64}
         if [[ "$SINGULARITY_BINDPATH" == "$baselineBind" ]]; then
            SINGULARITY_BINDPATH+=",/usr/lib64:/host_lib64"
         fi
         ;;
   esac
   {
      printf 'SINGULARITY_BINDPATH=%s\n' "$SINGULARITY_BINDPATH"
      printf 'SINGULARITYENV_LD_LIBRARY_PATH=%s\n' "${SINGULARITYENV_LD_LIBRARY_PATH:-}"
      printf 'SINGULARITYENV_LD_PRELOAD=%s\n' "${SINGULARITYENV_LD_PRELOAD:-}"
   } > "$caseDir/host-environment.txt"
   echo "Running $caseName"
   if singularity exec -B "$caseDir:/openfoam-link-diagnostic" "$image" bash -s \
      > "$caseDir/compile.log" 2>&1 <<'CONTAINER'
set -euo pipefail
cd /openfoam-link-diagnostic
printf 'LD_LIBRARY_PATH=%s\nLD_PRELOAD=%s\n' "${LD_LIBRARY_PATH:-}" "${LD_PRELOAD:-}" > container-environment.txt
printf 'WM_PROJECT_DIR=%s\nWM_OPTIONS=%s\n' "$WM_PROJECT_DIR" "$WM_OPTIONS" >> container-environment.txt
for lib in /lib64/libcxi.so.1 /usr/lib64/libnl-3.so.200 /usr/lib/x86_64-linux-gnu/libnl-3.so.200 /host_lib64/libnl-3.so.200; do
   {
      printf '\n=== %s ===\n' "$lib"
      if [[ -e "$lib" ]]; then
         readlink -f "$lib"
         readelf -d "$lib"
         readelf --dyn-syms --wide "$lib"
      else
         echo "Not present"
      fi
   } >> container-libraries.txt
done
template="$FOAM_APP/solvers/incompressible/icoFoam"
[[ -f "$template/icoFoam.C" ]] || {
   echo "ERROR: This diagnostic requires the OpenFOAM icoFoam source at $template" >&2
   exit 1
}
cp -a "$template"/. work/
cd work
mv icoFoam.C diagnosticIcoFoam.C
sed -i 's/icoFoam/diagnosticIcoFoam/g; s/FOAM_APPBIN/FOAM_USER_APPBIN/g' Make/files
export FOAM_USER_APPBIN=/openfoam-link-diagnostic/bin
mkdir -p "$FOAM_USER_APPBIN"
printf '\nEXE_LIBS += -Wl,--trace -Wl,--verbose\n' >> Make/options
wclean
if wmake; then
   echo 0 > ../compile.exit-status.txt
else
   status=$?
   echo "$status" > ../compile.exit-status.txt
   exit "$status"
fi
ldd "$FOAM_USER_APPBIN/diagnosticIcoFoam" > ../binary-ldd.txt
CONTAINER
   then
      compileStatus=0
   else
      compileStatus=$?
      echo "ERROR: $caseName compilation/diagnostics exited with status $compileStatus"
   fi
   helpStatus="not-run"
   if [[ $compileStatus -eq 0 ]]; then
      if singularity exec -B "$caseDir:/openfoam-link-diagnostic" "$image" \
         /openfoam-link-diagnostic/bin/diagnosticIcoFoam -help > "$caseDir/help.log" 2>&1; then
         if grep -q '^Usage:' "$caseDir/help.log"; then
            helpStatus=0
         else
            echo "ERROR: $caseName help output has no Usage line"
            helpStatus=1
         fi
      else
         helpStatus=$?
         echo "ERROR: $caseName help command exited with status $helpStatus"
      fi
   fi
   printf '%s\t%s\t%s\n' "$caseName" "$compileStatus" "$helpStatus" >> "$runDir/results.tsv"
   if [[ $compileStatus -ne 0 || "$helpStatus" != 0 ]]; then
      failed=1
   fi
done
cat "$runDir/results.tsv"
echo "Artifacts: $runDir"
# A failing baseline is expected, but must not be reported as job success.
exit "$failed"
