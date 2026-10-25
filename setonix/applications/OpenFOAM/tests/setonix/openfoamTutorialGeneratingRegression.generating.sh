#!/bin/bash --login
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
openfoam_root=$(cd -- "$script_dir/../.." && pwd -P)
launcher="$script_dir/openfoamTutorialTestLauncher.generating.sh"
config="$openfoam_root/openfoam/v2606/buildAndValidationConfig/openfoamBuildAndValidation.generating.config"
fixture="$script_dir/.tutorial-generating-regression-$$.generating"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/mockbin.generating" "$fixture/tutorial path/incompressible/example/periodicPlaneChannel"/{system,constant,0.orig}
printf 'mock image\n' > "$fixture/image.generating.sif"
printf 'endTime 10;\nwriteInterval 1;\n' > "$fixture/tutorial path/incompressible/example/periodicPlaneChannel/system/controlDict"
printf 'numberOfSubdomains 1;\nmethod simple;\n' > "$fixture/tutorial path/incompressible/example/periodicPlaneChannel/system/decomposeParDict"
printf 'mock\n' > "$fixture/tutorial path/incompressible/example/periodicPlaneChannel/0.orig/U"
printf 'mock\n' > "$fixture/tutorial path/incompressible/example/periodicPlaneChannel/constant/transportProperties"
export MOCK_TUTORIAL="$fixture/tutorial path/incompressible/example/periodicPlaneChannel"
export MOCK_LOG="$fixture/mock-calls.generating.log"
export MOCK_VERSION=v2606
export MOCK_BIN="$fixture/mockbin.generating"
export PATH="$MOCK_BIN:$PATH"
: > "$MOCK_LOG"
cat > "$MOCK_BIN/module-loader.generating" <<'MOCK'
#!/bin/bash
printf 'module %q\n' "$*" >> "$MOCK_LOG"
MOCK
cat > "$fixture/bash-env.generating.sh" <<'MOCK'
export PATH="$MOCK_BIN:$PATH"
module() { "$MOCK_BIN/module-loader.generating" "$@"; }
MOCK
export BASH_ENV="$fixture/bash-env.generating.sh"
cat > "$MOCK_BIN/singularity" <<'MOCK'
#!/bin/bash
[[ ${1:-} == exec ]] || exit 2
shift
while [[ ${1:-} == --env || ${1:-} == --bind ]]; do
    if [[ $1 == --env ]]; then export FOAM_IORANKS=${2#*=}; fi
    shift 2
done
image=$1; shift
[[ $image == *.sif ]] || exit 2
script=${3:-}
printf 'singularity exec ' >> "$MOCK_LOG"
printf '%q ' "$image" "$@" >> "$MOCK_LOG"
printf '\n' >> "$MOCK_LOG"
printf 'FOAM_IORANKS=%s\n' "${FOAM_IORANKS:-unset}" >> "$MOCK_LOG"
if [[ "$script" == *'find "$FOAM_TUTORIALS"'* ]]; then
    printf '%s\n' "$MOCK_TUTORIAL"
elif [[ "$script" == *'tar -C '* ]]; then
    tar -C "$(dirname "$MOCK_TUTORIAL")" -cf - "$(basename "$MOCK_TUTORIAL")"
elif [[ "$script" == *'printf "%s" "$WM_PROJECT_VERSION"'* ]]; then
    printf '%s' "$MOCK_VERSION"
elif [[ "$script" == *'test "$WM_PROJECT_VERSION"'* ]]; then
    [[ "$MOCK_VERSION" == "$5" ]]
else
    exec "$@"
fi
MOCK
cat > "$MOCK_BIN/srun" <<'MOCK'
#!/bin/bash
while [[ ${1:-} == -* ]]; do
    case "$1" in
        -N|-n|-c) shift 2 ;;
        --ntasks-per-node=*) shift ;;
        *) exit 2 ;;
    esac
done
exec "$@"
MOCK
cat > "$MOCK_BIN/foamDictionary" <<'MOCK'
#!/bin/bash
set -euo pipefail
file=$1
entry=$3
key="${file//\//_}.${entry//\//_}.generating"
if [[ "$4" == -set ]]; then
    printf '%s\n' "$5" > "$key"
else
    [[ ${MOCK_BAD_DICTIONARY:-false} != true ]] || { echo incorrect; exit 0; }
    cat "$key"
fi
MOCK
cat > "$MOCK_BIN/blockMesh" <<'MOCK'
#!/bin/bash
echo blockMesh
MOCK
cp "$MOCK_BIN/blockMesh" "$MOCK_BIN/renumberMesh"
cat > "$MOCK_BIN/checkMesh" <<'MOCK'
#!/bin/bash
[[ ${MOCK_FAIL_PRE:-false} != true ]] || exit 17
echo 'Mesh OK'
MOCK
cat > "$MOCK_BIN/decomposePar" <<'MOCK'
#!/bin/bash
[[ "$FOAM_IORANKS" == '(0 2)' ]] || exit 19
mkdir -p processors4_0-1 processors4_2-3
MOCK
cat > "$MOCK_BIN/pimpleFoam" <<'MOCK'
#!/bin/bash
[[ "$FOAM_IORANKS" == '(0 2)' ]] || exit 19
[[ ${MOCK_FATAL_SOLVER:-false} != true ]] || { echo 'FOAM FATAL ERROR'; exit 0; }
echo 'Time = 100'
echo 'Solving for Ux, Initial residual = 0.001'
echo 'ExecutionTime = 20 s'
MOCK
cat > "$MOCK_BIN/sacct" <<'MOCK'
#!/bin/bash
while (($#)); do
    if [[ "$1" == -j ]]; then job=$2; break; fi
    shift
done
printf '%s|%s|%s\n' "$job" "${MOCK_JOB_STATE:-COMPLETED}" "${MOCK_JOB_EXIT:-0:0}"
MOCK
cat > "$MOCK_BIN/squeue" <<'MOCK'
#!/bin/bash
exit 0
MOCK
cat > "$MOCK_BIN/sbatch" <<'MOCK'
#!/bin/bash
printf '%q ' "$@" >> "$SBATCH_CALL_LOG"
printf '\n' >> "$SBATCH_CALL_LOG"
id=$(($(cat "$SBATCH_ID_FILE" 2>/dev/null || echo 99) + 1))
printf '%s\n' "$id" > "$SBATCH_ID_FILE"
while (($#)); do
    case "$1" in
        --parsable|--export=NONE) shift ;;
        --partition|--reservation|--dependency|--output) shift 2 ;;
        --dependency=*) shift ;;
        --kill-on-invalid-dep=yes) shift ;;
        *) script=$1; shift; break ;;
    esac
done
[[ -n ${script:-} ]] || exit 2
if [[ "$MOCK_EXECUTE_SBATCH" == true ]]; then
    if [[ "$script" == *preFoam* ]]; then
        export SLURM_JOB_NUM_NODES=1 SLURM_NTASKS=1
    elif [[ "$script" == *runFoam* ]]; then
        export SLURM_JOB_NUM_NODES=2 SLURM_NTASKS=4
    fi
    "$script" "$@" > "$script.execution.generating.log" 2>&1 || exit 1
fi
printf '%s\n' "$id"
MOCK
chmod +x "$MOCK_BIN/"*
export SINGULARITY_MODULE=mock-singularity
export SLURM_CPUS_PER_TASK=1
run_pre() {
    SLURM_JOB_NUM_NODES=1 SLURM_NTASKS=1 "$GEN_ART/preFoam.generating.slurm.sh" \
        --image "$fixture/image.generating.sif" --work-root "$GEN_WORK" --test-artifacts-dir "$GEN_ART"
}
run_solver() {
    SLURM_JOB_NUM_NODES=2 SLURM_NTASKS=4 "$GEN_ART/runFoam.generating.slurm.sh" \
        --image "$fixture/image.generating.sif" --work-root "$GEN_WORK" --test-artifacts-dir "$GEN_ART"
}

assert() { "$@" || { echo "FAIL: $*" >&2; exit 1; }; }
generate_case() {
    local tag=$1
    GEN_WORK="$fixture/$tag work"
    GEN_ART="$fixture/$tag artifacts"
    : > "$MOCK_LOG"
    "$launcher" --config "$config" --image "$fixture/image.generating.sif" \
        --work-root "$GEN_WORK" --artifacts-dir "$GEN_ART" --generate-only
    assert test -x "$GEN_ART/extractCase.generating.sh"
    assert bash -n "$GEN_ART/extractCase.generating.sh"
    assert bash -n "$GEN_ART/preFoam.generating.slurm.sh"
    assert bash -n "$GEN_ART/runFoam.generating.slurm.sh"
    assert test -f "$GEN_ART/candidates.generating.sha256"
    ! grep -Eq 'tutorialTestCommon|\.central|openfoamBuildAndValidation.*config' \
        "$GEN_ART"/{extractCase.generating.sh,preFoam.generating.slurm.sh,runFoam.generating.slurm.sh} ||
        { echo "FAIL: generated candidate depends on repository tooling" >&2; exit 1; }
    ! grep -q . "$MOCK_LOG" || { echo "FAIL: generate-only executed a runtime command" >&2; exit 1; }
}

generate_case "standalone"
GEN_WORK="$fixture/standalone work"
GEN_ART="$fixture/standalone artifacts"
"$GEN_ART/extractCase.generating.sh" --image "$fixture/image.generating.sif" --work-root "$GEN_WORK" --test-artifacts-dir "$GEN_ART"
run_pre
run_solver
"$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART"
assert grep -q '^result=PASS$' "$GEN_ART/validation.generating.record"
assert grep -q '^FOAM_IORANKS=(0 2)$' "$MOCK_LOG"
assert awk '
    /singularity exec .* blockMesh/ {b=NR}
    /singularity exec .* renumberMesh/ {r=NR}
    /singularity exec .* checkMesh/ {c=NR}
    /singularity exec .* decomposePar/ {d=NR}
    END {exit !(b && b<r && r<c && c<d)}
' "$MOCK_LOG"
cp "$GEN_ART/solver.generating.log" "$fixture/good-solver.generating.log"
for residual in 0.012 0.02 NaN 0.001invalid; do
    sed "s/Initial residual = 0.001/Initial residual = $residual/" "$fixture/good-solver.generating.log" > "$GEN_ART/solver.generating.log"
    if "$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART" >/dev/null 2>&1; then
        echo "FAIL: invalid or boundary residual $residual accepted" >&2; exit 1
    fi
    assert test ! -e "$GEN_ART/validation.generating.record"
done
cp "$fixture/good-solver.generating.log" "$GEN_ART/solver.generating.log"
printf 'FOAM FATAL ERROR\n' >> "$GEN_ART/solver.generating.log"
if "$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART" >/dev/null 2>&1; then
    echo "FAIL: fatal solver log accepted" >&2; exit 1
fi
cp "$fixture/good-solver.generating.log" "$GEN_ART/solver.generating.log"
sed 's/ExecutionTime = 20/ExecutionTime = 55/' "$GEN_ART/solver.generating.log" > "$fixture/slow-solver.generating.log"
cp "$fixture/slow-solver.generating.log" "$GEN_ART/solver.generating.log"
"$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART"
assert grep -q '^warning=executionTime=55' "$GEN_ART/validation.generating.record"
run_solver
"$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART"

cp "$GEN_ART/runFoam.generating.slurm.sh" "$fixture/run-backup.generating"
printf '\n# tamper check\n' >> "$GEN_ART/runFoam.generating.slurm.sh"
if "$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART" >/dev/null 2>&1; then
    echo "FAIL: candidate digest alteration was accepted" >&2; exit 1
fi
mv "$fixture/run-backup.generating" "$GEN_ART/runFoam.generating.slurm.sh"

cp "$GEN_ART/openfoamBuildAndValidation.generating.config" "$fixture/config-backup.generating"
printf '\n# provenance tamper\n' >> "$GEN_ART/openfoamBuildAndValidation.generating.config"
if "$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART" >/dev/null 2>&1; then
    echo "FAIL: configuration digest alteration was accepted" >&2; exit 1
fi
mv "$fixture/config-backup.generating" "$GEN_ART/openfoamBuildAndValidation.generating.config"
cp "$fixture/image.generating.sif" "$fixture/image-backup.generating"
printf 'changed image\n' > "$fixture/image.generating.sif"
if "$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART" >/dev/null 2>&1; then
    echo "FAIL: image digest alteration was accepted" >&2; exit 1
fi
mv "$fixture/image-backup.generating" "$fixture/image.generating.sif"

printf 'Time = 100\nSolving for Ux, Initial residual = NaN\nExecutionTime = 20 s\n' > "$GEN_ART/solver.generating.log"
if "$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART" >/dev/null 2>&1; then
    echo "FAIL: non-finite residual was accepted" >&2; exit 1
fi
run_solver
"$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART"

generate_case "wrong-version"
GEN_WORK="$fixture/wrong-version work"
GEN_ART="$fixture/wrong-version artifacts"
export MOCK_VERSION=v2406
if "$GEN_ART/extractCase.generating.sh" --image "$fixture/image.generating.sif" --work-root "$GEN_WORK" --test-artifacts-dir "$GEN_ART"; then
    echo "FAIL: image runtime version mismatch was accepted" >&2; exit 1
fi
export MOCK_VERSION=v2606

generate_case "readback"
"$GEN_ART/extractCase.generating.sh"
export MOCK_BAD_DICTIONARY=true
if run_pre >/dev/null 2>&1; then
    echo "FAIL: dictionary read-back mismatch accepted" >&2; exit 1
fi
unset MOCK_BAD_DICTIONARY
assert test "$(cat "$GEN_ART/pre.status.generating")" != 0

original_config=$config
sed 's/TUTORIAL_PRE_blockMesh=(blockMesh)/TUTORIAL_PRE_blockMesh=(blockMesh -custom-generating)/' "$config" > "$fixture/custom.generating.config"
config="$fixture/custom.generating.config"
generate_case "custom"
"$GEN_ART/extractCase.generating.sh"
run_pre
assert grep -q 'blockMesh -custom-generating' "$MOCK_LOG"
config=$original_config
printf 'keep\n' > "$GEN_WORK/run/sibling.generating"
if "$GEN_ART/extractCase.generating.sh" >/dev/null 2>&1; then
    echo "FAIL: extraction silently overwrote existing case" >&2; exit 1
fi
"$GEN_ART/extractCase.generating.sh" --overwrite
assert test -f "$GEN_WORK/run/sibling.generating"

generate_case "failed"
GEN_WORK="$fixture/failed work"
GEN_ART="$fixture/failed artifacts"
"$GEN_ART/extractCase.generating.sh" --image "$fixture/image.generating.sif" --work-root "$GEN_WORK" --test-artifacts-dir "$GEN_ART"
export MOCK_FAIL_PRE=true
if run_pre; then
    echo "FAIL: preparation failure was swallowed by tee" >&2; exit 1
fi
unset MOCK_FAIL_PRE
assert test "$(cat "$GEN_ART/pre.status.generating")" != 0
if "$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART" >/dev/null 2>&1; then
    echo "FAIL: failed stage passed finalization" >&2; exit 1
fi
failed_pub="$fixture/failed publication recipe"
mkdir -p "$failed_pub/tutorialTest"
sed "9c\\$failed_pub" "$GEN_ART/manifest.generating" > "$fixture/failed-manifest.generating"
cp "$fixture/failed-manifest.generating" "$GEN_ART/manifest.generating"
if "$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART" --publish >/dev/null 2>&1; then
    echo "FAIL: failed stage was published" >&2; exit 1
fi
assert test ! -e "$failed_pub/tutorialTest/singularity-generating"

export SBATCH_CALL_LOG="$fixture/sbatch-calls.generating.log"
export SBATCH_ID_FILE="$fixture/sbatch-id.generating"
export MOCK_EXECUTE_SBATCH=false
pub="$fixture/publication recipe"
mkdir -p "$pub/buildAndValidationConfig" "$pub/tutorialTest"
cp "$config" "$pub/buildAndValidationConfig/openfoamBuildAndValidation.generating.config"
"$launcher" --config "$pub/buildAndValidationConfig/openfoamBuildAndValidation.generating.config" \
    --image "$fixture/image.generating.sif" \
    --work-root "$fixture/async work" --artifacts-dir "$fixture/async artifacts" \
    --submit-only --publish-examples
assert test -f "$fixture/async artifacts/jobs.generating"
assert grep -q -- '--dependency=afterok:100' "$SBATCH_CALL_LOG"
assert grep -q -- '--dependency=afterany:100:101' "$SBATCH_CALL_LOG"
assert grep -q -- 'pre-%j.generating.log' "$SBATCH_CALL_LOG"
assert grep -q -- 'run-%j.generating.log' "$SBATCH_CALL_LOG"
assert grep -q -- 'finalize-%j.generating.log' "$SBATCH_CALL_LOG"
# Submit-only is pending, not a passing result. Complete the generated jobs and
# invoke the persisted validator to exercise the same manual finalization path.
GEN_ART="$fixture/async artifacts"
GEN_WORK="$fixture/async work"
run_pre
run_solver
export MOCK_JOB_STATE=RUNNING
if "$GEN_ART/validate.generating.sh" --artifacts-dir "$GEN_ART" --jobs 100 101 --publish >/dev/null 2>&1; then
    echo "FAIL: running Slurm jobs were accepted for publication" >&2; exit 1
fi
unset MOCK_JOB_STATE
"$fixture/async artifacts/finalize.generating.slurm.sh"
assert test "$(cat "$fixture/async artifacts/final.status.generating")" = 0
"$launcher" --finalize "$fixture/async artifacts"

# Publication uses a temporary recipe tree, never the real v2606 tutorialTest.
assert test -f "$pub/tutorialTest/singularity-generating/runFoam.generating.slurm.sh"
assert test -f "$pub/tutorialTest/singularity-generating/validation.generating.record"
(cd "$pub/tutorialTest/singularity-generating" && sha256sum -c publication.generating.sha256)
if "$launcher" --finalize "$fixture/async artifacts" --publish-examples >/dev/null 2>&1; then
    echo "FAIL: existing publication was replaced" >&2; exit 1
fi

export MOCK_EXECUTE_SBATCH=true
"$launcher" --config "$pub/buildAndValidationConfig/openfoamBuildAndValidation.generating.config" \
    --image "$fixture/image.generating.sif" \
    --work-root "$fixture/wait work" --artifacts-dir "$fixture/wait artifacts"
assert test "$(cat "$fixture/wait artifacts/final.status.generating")" = 0
export MOCK_FATAL_SOLVER=true
GEN_ART="$fixture/wait artifacts"
GEN_WORK="$fixture/wait work"
if run_solver >/dev/null 2>&1; then
    echo "FAIL: zero-exit solver with fatal log accepted" >&2; exit 1
fi
unset MOCK_FATAL_SOLVER
assert test "$(cat "$GEN_ART/run.status.generating")" != 0

# Unsupported recipe identity must fail before any runtime activity.
sed 's/OPENFOAM_VERSION="v2606"/OPENFOAM_VERSION="v2406"/' "$config" > "$fixture/unsupported.generating.config"
if "$launcher" --config "$fixture/unsupported.generating.config" --image "$fixture/image.generating.sif" --generate-only \
    --work-root "$fixture/bad work" --artifacts-dir "$fixture/bad artifacts" >/dev/null 2>&1; then
    echo "FAIL: unsupported version was accepted" >&2; exit 1
fi
if "$openfoam_root/buildAll_openfoam.generating.slurm.sh" --only-directories openfoam/v2412 >/dev/null 2>&1; then
    echo "FAIL: buildAll generating copy accepted unsupported recipe" >&2; exit 1
fi
echo "PASS: generating tutorial regression suite"
