#!/usr/bin/env bash
set -Eeuo pipefail
ARTIFACTS=""
PUBLISH=false
JOBS=()
PUBLICATION_STAGE=""
while (($#)); do
    case "$1" in
        --artifacts-dir)
            [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --artifacts-dir requires a directory" >&2; exit 2; }
            ARTIFACTS=$2; shift 2 ;;
        --jobs) shift; while (($#)) && [[ "$1" != --* ]]; do JOBS+=("$1"); shift; done ;;
        --publish) PUBLISH=true; shift ;;
        *) echo "ERROR: unknown validator option: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$ARTIFACTS" && -d "$ARTIFACTS" ]] || { echo "ERROR: invalid artifact directory" >&2; exit 2; }
if ((${#JOBS[@]} == 0)) && [[ -f "$ARTIFACTS/jobs.generating" ]]; then
    mapfile -t JOBS < "$ARTIFACTS/jobs.generating"
fi
write_final_status() {
    rc=$?
    if [[ -n "$PUBLICATION_STAGE" && -d "$PUBLICATION_STAGE" ]]; then
        rm -rf -- "$PUBLICATION_STAGE"
    fi
    printf '%s\n' "$rc" > "$ARTIFACTS/final.status.generating"
    return "$rc"
}
trap write_final_status EXIT
rm -f -- "$ARTIFACTS/validation.generating.record"
if ((${#JOBS[@]})); then
    ((${#JOBS[@]} >= 2)) || { echo "ERROR: both preparation and solver job IDs are required"; exit 1; }
    for job in "${JOBS[@]:0:2}"; do
        [[ "$job" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid job ID"; exit 1; }
        for ((attempt=0; attempt<12; attempt++)); do
            result=$(sacct -n -P -j "$job" --format=JobIDRaw,State,ExitCode) || {
                echo "ERROR: could not query Slurm accounting for $job"; exit 1;
            }
            if printf '%s\n' "$result" | awk -F'|' -v id="$job" '$1==id {found=1} END {exit !found}'; then break; fi
            sleep "${POLL_INTERVAL_SECONDS:-5}"
        done
        printf '%s\n' "$result" | awk -F'|' -v id="$job" \
            '$1==id && $2=="COMPLETED" && $3=="0:0" {ok=1} END {exit !ok}' || {
            echo "ERROR: Slurm job $job is not recorded as successfully completed"; exit 1;
        }
    done
elif [[ "$PUBLISH" == true ]]; then
    echo "ERROR: publication requires completed Slurm job records"
    exit 1
fi
mapfile -t manifest < "$ARTIFACTS/manifest.generating"
[[ ${#manifest[@]} -eq 9 ]] || { echo "ERROR: malformed manifest"; exit 1; }
image=${manifest[0]}
case_dir=${manifest[3]}
[[ "$(sha256sum -- "$image" | awk '{print $1}')" == "${manifest[1]}" ]] || { echo "ERROR: image digest mismatch"; exit 1; }
[[ "$(sha256sum -- "$ARTIFACTS/openfoamBuildAndValidation.generating.config" | awk '{print $1}')" == "${manifest[2]}" ]] || {
    echo "ERROR: configuration digest mismatch"; exit 1;
}
# shellcheck disable=SC1090
source "$ARTIFACTS/openfoamBuildAndValidation.generating.config"
[[ "$OPENFOAM_FORK" == openfoam && "$OPENFOAM_VERSION" == v2606 ]] || { echo "ERROR: unsupported saved recipe"; exit 1; }
files=(extractCase.generating.sh preFoam.generating.slurm.sh runFoam.generating.slurm.sh)
for i in 0 1 2; do
    actual=$(sha256sum -- "$ARTIFACTS/${files[$i]}" | awk '{print $1}')
    [[ "$actual" == "${manifest[$((5+i))]}" ]] || { echo "ERROR: candidate digest mismatch: ${files[$i]}"; exit 1; }
done
for status in extract.status.generating pre.status.generating run.status.generating; do
    [[ -f "$ARTIFACTS/$status" && "$(cat "$ARTIFACTS/$status")" == 0 ]] ||
        { echo "ERROR: stage incomplete or failed: $status"; exit 1; }
done
prelog="$ARTIFACTS/pre.generating.log"
solverlog="$ARTIFACTS/solver.generating.log"
meshlog="$ARTIFACTS/checkMesh.generating.log"
[[ -f "$prelog" && -f "$solverlog" && -f "$meshlog" ]] ||
    { echo "ERROR: preparation, mesh or solver log is missing"; exit 1; }
grep -q 'Mesh OK' "$meshlog" || { echo "ERROR: mesh acceptance failed"; exit 1; }
if grep -Ei 'FOAM FATAL|MPI_ABORT|Segmentation fault|Floating point exception' "$prelog" "$solverlog" "$meshlog"; then
    echo "ERROR: fatal runtime message in tutorial logs"
    exit 1
fi
for ((i=0; i<TUTORIAL_NPROCS; i+=TUTORIAL_IO_GROUP_SIZE)); do
    end=$((i+TUTORIAL_IO_GROUP_SIZE-1))
    ((end<TUTORIAL_NPROCS)) || end=$((TUTORIAL_NPROCS-1))
    directory="processors${TUTORIAL_NPROCS}_${i}-${end}"
    [[ -d "$case_dir/$directory" ]] || { echo "ERROR: missing $directory"; exit 1; }
done
last_time=$(sed -nE 's/^[[:space:]]*Time[[:space:]]*=[[:space:]]*(.*)/\1/p' "$solverlog" | sed -E 's/[[:space:]]+$//' | tail -1)
finite_number() { awk -v n="$1" 'BEGIN { if (n !~ /^[+]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/) exit 1; x=n+0; if (x != x || x > 1e300 || x < 0) exit 1; }'; }
finite_number "$last_time" || { echo "ERROR: invalid/missing final solver time"; exit 1; }
awk -v t="$last_time" -v expected="$TUTORIAL_END_TIME" 'BEGIN { exit !(t+0 == expected+0) }' ||
    { echo "ERROR: solver final time does not equal $TUTORIAL_END_TIME"; exit 1; }
final_time_line=$(grep -nE '^[[:space:]]*Time[[:space:]]*=' "$solverlog" | tail -1 | cut -d: -f1)
execution=$(sed -nE 's/.*ExecutionTime[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$solverlog" | tail -1)
residual=$(tail -n +"$final_time_line" "$solverlog" | sed -nE '/Solving for Ux/ s/.*Initial residual[[:space:]]*=[[:space:]]*([^,[:space:]]+).*/\1/p' | tail -1)
finite_number "$execution" || { echo "ERROR: invalid/missing executionTime"; exit 1; }
finite_number "$residual" || { echo "ERROR: invalid/missing final Ux initial residual"; exit 1; }
awk -v r="$residual" -v limit="$TUTORIAL_MAX_UX_INITIAL_RESIDUAL" 'BEGIN { exit !(r < limit) }' ||
    { echo "ERROR: final Ux initial residual exceeds $TUTORIAL_MAX_UX_INITIAL_RESIDUAL"; exit 1; }
result=PASS
warning=none
if awk -v t="$execution" -v limit="$TUTORIAL_MAX_EXECUTION_TIME" 'BEGIN { exit !(t >= limit) }'; then
    warning="executionTime=$execution is at/above ${TUTORIAL_MAX_EXECUTION_TIME}s"
fi
record="$ARTIFACTS/validation.generating.record"
{
    printf 'result=%s\n' "$result"
    printf 'image_sha256=%s\nconfig_sha256=%s\n' "${manifest[1]}" "${manifest[2]}"
    printf 'extract_candidate_sha256=%s\npre_candidate_sha256=%s\nrun_candidate_sha256=%s\n' \
        "${manifest[5]}" "${manifest[6]}" "${manifest[7]}"
    printf 'execution_time=%s\nfinal_ux_initial_residual=%s\nwarning=%s\n' "$execution" "$residual" "$warning"
    printf 'checksum_scope=candidate_script_digests_in_manifest;_publication_hash_covers_triplet_and_record\n'
    printf 'interpretation=invocation-specific_result_not_a_universal_pass_guarantee\n'
    printf 'validated_at=%s\njob_ids=%s\n' "$(date -Is)" "${JOBS[*]:-not-recorded}"
} > "$record"
if [[ "$PUBLISH" == true ]]; then
    recipe_dir=${manifest[8]}
    target="$recipe_dir/tutorialTest/singularity-generating"
    [[ ! -e "$target" && ! -L "$target" ]] || { echo "ERROR: refusing to replace existing publication: $target"; exit 1; }
    mkdir -p -- "$recipe_dir/tutorialTest"
    PUBLICATION_STAGE="$recipe_dir/tutorialTest/.singularity-generating.$$.generating"
    mkdir -- "$PUBLICATION_STAGE"
    cp -- "$ARTIFACTS/${files[0]}" "$PUBLICATION_STAGE/extractCase.generating.sh"
    cp -- "$ARTIFACTS/${files[1]}" "$PUBLICATION_STAGE/preFoam.generating.slurm.sh"
    cp -- "$ARTIFACTS/${files[2]}" "$PUBLICATION_STAGE/runFoam.generating.slurm.sh"
    cp -- "$record" "$PUBLICATION_STAGE/validation.generating.record"
    (cd "$PUBLICATION_STAGE" && sha256sum -- *.generating.sh *.generating.slurm.sh validation.generating.record > publication.generating.sha256)
    chmod 755 "$PUBLICATION_STAGE/"*.generating.sh "$PUBLICATION_STAGE/"*.generating.slurm.sh
    mv -T -- "$PUBLICATION_STAGE" "$target"
    PUBLICATION_STAGE=""
    printf 'PUBLISHED: %s\n' "$target"
fi
printf 'PASS: v2606 tutorial acceptance checks completed\n'
[[ "$warning" == none ]] || printf 'WARNING: %s\n' "$warning"
