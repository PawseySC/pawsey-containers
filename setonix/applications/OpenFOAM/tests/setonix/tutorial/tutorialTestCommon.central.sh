#!/bin/bash
# Shared central tutorial schema and execution engine. Sourcing defines functions
# only. Configurations are trusted Bash data files using ordinary assignments
# (not function-local declare statements); they must not execute commands.
#
# Operation arrays are (OP ARG...). Contracts:
# extract_unique; extract_relative RELPATH (EXTRACT only, first step, exactly one).
# require_directory RELPATH; require_file RELPATH; require_initial_conditions.
# restore_initial_conditions SOURCE DEST; remove_decomposition;
# set_dictionary FILE ENTRY EXPECTED [scalar|vector] (PRE only).
# run LOGID COMMAND [ARGS...] (serial; EXTRACT does not use srun).
# require_log_text LOGID TEXT; check_collated_decomposition (PRE/RUN).
# run_parallel LOGID COMMAND [ARGS...]; require_final_time LOGID TIME;
# warn_execution_time LOGID LIMIT; require_final_initial_residual LOGID FIELD LIMIT
# (RUN only). Log checks refer to an earlier command in the same stage.
# Scalar dictionary comparisons are exact; vectors ignore whitespace/parentheses.
# Runtime limits warn, residual limits fail, both using strict less-than.

central_error() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
central_identifier() { [[ "$1" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]]; }
central_log_id() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; }
central_positive_integer() { [[ "$1" =~ ^[1-9][0-9]{0,6}$ ]]; }
central_number() { [[ "$1" =~ ^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]]; }
central_nonnegative() {
    central_number "$1" && awk -v n="$1" 'BEGIN { exit !(n >= 0 && n < 1e300) }'
}
central_relative_path() {
    [[ -n "$1" && "$1" != /* && "$1" != -* &&
       "$1" != *$'\n'* && "$1" != *$'\r'* &&
       "/$1/" != *"/../"* && "/$1/" != *"/./"* && "$1" != */ ]]
}
central_array() {
    local declaration
    declaration=$(declare -p "$1" 2>/dev/null) || return 1
    [[ "$declaration" == "declare -a "* ]]
}
central_scalar() {
    local declaration
    declaration=$(declare -p "$1" 2>/dev/null) || return 1
    [[ "$declaration" != "declare -a "* && "$declaration" != "declare -A "* &&
       "$declaration" != "declare -n "* && -n "${!1:-}" ]]
}
central_vector() {
    local text="$1" x y z rest
    [[ "$text" =~ ^[[:space:]]*\(.*\)[[:space:]]*$ && "$text" != *$'\n'* ]] || return 1
    text=${text//[()]/}
    read -r x y z rest <<< "$text"
    [[ -z "$rest" ]] && central_number "$x" && central_number "$y" && central_number "$z"
}
central_normalize_vector() {
    local text="${1//[()]/}" x y z rest
    read -r x y z rest <<< "$text"
    printf '%s %s %s' "$x" "$y" "$z"
}

# Public API: load a trusted config and validate the entire tutorial schema.
# No modules, runtime commands, directories, logs, or traps are created here.
central_load_config() {
    [[ $# == 1 && -f "$1" && -r "$1" ]] || { central_error "Configuration is not readable: ${1:-}"; return 1; }
    local central_config_input="$1" central_old_name
    while IFS= read -r central_old_name; do
        unset "$central_old_name" || return 1
    done < <(compgen -A variable TUTORIAL_)
    unset OPENFOAM_FORK OPENFOAM_VERSION
    # shellcheck source=/dev/null
    source "$central_config_input" || { central_error "Cannot source $central_config_input"; return 1; }
    central_validate_config
}

central_validate_config() {
    local key value stage id array_name operation argc mode file entry expected
    local -A seen_ids=() seen_logs=()
    for key in OPENFOAM_FORK OPENFOAM_VERSION TUTORIAL_CASE_NAME \
        TUTORIAL_NPROCS TUTORIAL_IO_GROUP_SIZE TUTORIAL_PRE_NODES TUTORIAL_PRE_TASKS \
        TUTORIAL_PRE_CPUS_PER_TASK TUTORIAL_PRE_MEMORY TUTORIAL_PRE_TIME \
        TUTORIAL_RUN_NODES TUTORIAL_RUN_TASKS TUTORIAL_RUN_CPUS_PER_TASK TUTORIAL_RUN_TIME; do
        central_scalar "$key" || { central_error "Missing or invalid scalar $key"; return 1; }
    done
    [[ "$OPENFOAM_FORK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ &&
       "$OPENFOAM_VERSION" =~ ^v?[0-9][0-9A-Za-z.-]*$ &&
       "$TUTORIAL_CASE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] ||
        { central_error "Unsafe fork, version, or tutorial case name"; return 1; }
    for key in TUTORIAL_NPROCS TUTORIAL_IO_GROUP_SIZE TUTORIAL_PRE_NODES \
        TUTORIAL_PRE_TASKS TUTORIAL_PRE_CPUS_PER_TASK TUTORIAL_RUN_NODES \
        TUTORIAL_RUN_TASKS TUTORIAL_RUN_CPUS_PER_TASK; do
        central_positive_integer "${!key}" || { central_error "$key must be a positive integer"; return 1; }
    done
    (( TUTORIAL_IO_GROUP_SIZE <= TUTORIAL_NPROCS &&
       TUTORIAL_RUN_TASKS == TUTORIAL_NPROCS &&
       TUTORIAL_RUN_TASKS % TUTORIAL_RUN_NODES == 0 &&
       TUTORIAL_PRE_TASKS >= TUTORIAL_PRE_NODES )) ||
        { central_error "Inconsistent decomposition or allocation sizes"; return 1; }
    [[ "$TUTORIAL_PRE_MEMORY" =~ ^[1-9][0-9]*([KMGTP]([Bb])?|[KMGTP][iI][Bb])?$ ]] ||
        { central_error "Invalid TUTORIAL_PRE_MEMORY"; return 1; }
    for key in TUTORIAL_PRE_TIME TUTORIAL_RUN_TIME; do
        value=${!key}
        [[ "$value" =~ ^([0-9]+-)?[0-9]{1,3}:[0-5][0-9]:[0-5][0-9]$ &&
           "$value" =~ [1-9] ]] || { central_error "Invalid $key"; return 1; }
    done
    for stage in EXTRACT PRE RUN; do
        array_name="TUTORIAL_${stage}_STEPS"
        central_array "$array_name" || { central_error "$array_name must be an indexed array"; return 1; }
        local -n steps="$array_name"
        (( ${#steps[@]} > 0 )) || { central_error "$array_name is empty"; return 1; }
        seen_ids=(); seen_logs=()
        local extract_count=0 index=0 step_index
        for step_index in "${!steps[@]}"; do
            [[ "$step_index" == "$index" ]] || { central_error "Sparse step array: $array_name"; return 1; }
            index=$((index + 1))
        done
        index=0
        for id in "${steps[@]}"; do
            central_identifier "$id" || { central_error "Invalid step ID: $id"; return 1; }
            [[ ! ${seen_ids[$id]+present} ]] || { central_error "Duplicate step: $id"; return 1; }
            seen_ids[$id]=1
            array_name="TUTORIAL_${stage}_${id}"
            central_array "$array_name" || { central_error "$array_name must be an indexed array"; return 1; }
            local -n args="$array_name"
            (( ${#args[@]} > 0 )) || { central_error "Empty operation: $array_name"; return 1; }
            # Indexed arrays must be dense: positional operation arguments matter.
            local arg_index=0 actual_index
            for actual_index in "${!args[@]}"; do
                [[ "$actual_index" == "$arg_index" ]] || { central_error "Sparse array: $array_name"; return 1; }
                arg_index=$((arg_index + 1))
            done
            operation=${args[0]}; argc=$((${#args[@]} - 1))
            case "$operation" in
                extract_unique|extract_relative)
                    [[ "$stage" == EXTRACT && "$index" == 0 ]] ||
                        { central_error "Extraction must be the first EXTRACT step"; return 1; }
                    if [[ "$operation" == extract_unique ]]; then
                        [[ "$argc" == 0 ]] || { central_error "extract_unique takes no arguments"; return 1; }
                    else
                        [[ "$argc" == 1 ]] && central_relative_path "${args[1]}" ||
                            { central_error "extract_relative requires a safe relative path"; return 1; }
                    fi
                    extract_count=$((extract_count + 1)) ;;
                require_directory|require_file)
                    [[ "$argc" == 1 ]] && central_relative_path "${args[1]}" || { central_error "Invalid $array_name path/arity"; return 1; } ;;
                require_initial_conditions)
                    [[ "$argc" == 0 ]] || { central_error "Invalid $array_name arity"; return 1; } ;;
                restore_initial_conditions)
                    [[ "$stage" == PRE && "$argc" == 2 ]] &&
                        central_relative_path "${args[1]}" && central_relative_path "${args[2]}" &&
                        [[ "${args[1]}" != "${args[2]}" && "${args[1]}/" != "${args[2]}/"* &&
                           "${args[2]}/" != "${args[1]}/"* ]] ||
                        { central_error "Invalid restore operation: $array_name"; return 1; } ;;
                remove_decomposition)
                    [[ "$stage" == PRE && "$argc" == 0 ]] || { central_error "Invalid remove_decomposition stage/arity"; return 1; } ;;
                set_dictionary)
                    [[ "$stage" == PRE && ( "$argc" == 3 || "$argc" == 4 ) ]] ||
                        { central_error "Invalid set_dictionary stage/arity"; return 1; }
                    file=${args[1]}; entry=${args[2]}; expected=${args[3]}; mode=${args[4]:-scalar}
                    central_relative_path "$file" && central_relative_path "$entry" &&
                        [[ -n "$expected" && "$expected" != *$'\n'* ]] ||
                        { central_error "Invalid dictionary arguments"; return 1; }
                    case "$mode" in
                        scalar) ;;
                        vector) central_vector "$expected" || { central_error "Invalid dictionary vector"; return 1; } ;;
                        *) central_error "Unknown dictionary type $mode"; return 1 ;;
                    esac
                    if [[ "$file" == system/decomposeParDict ]]; then
                        if [[ "$entry" == numberOfSubdomains ]]; then
                            [[ "$mode" == scalar && "$expected" == "$TUTORIAL_NPROCS" ]] ||
                                { central_error "numberOfSubdomains must match TUTORIAL_NPROCS"; return 1; }
                        elif [[ "$entry" == */n && "$mode" == vector ]]; then
                            local x y z remainder vector_text="${expected//[()]/}"
                            read -r x y z remainder <<< "$vector_text"
                            central_positive_integer "$x" && central_positive_integer "$y" &&
                                central_positive_integer "$z" &&
                                (( x * y * z == TUTORIAL_NPROCS )) ||
                                { central_error "Decomposition vector does not produce TUTORIAL_NPROCS subdomains"; return 1; }
                        fi
                    fi ;;
                run|run_parallel)
                    (( argc >= 2 )) || { central_error "Invalid run arity"; return 1; }
                    [[ "$operation" != run_parallel || "$stage" == RUN ]] ||
                        { central_error "run_parallel is only valid in RUN"; return 1; }
                    central_log_id "${args[1]}" && [[ "${args[2]}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.+-]*$ ]] ||
                        { central_error "Unsafe log ID or command"; return 1; }
                    [[ ! ${seen_logs[${args[1]}]+present} ]] || { central_error "Duplicate log ID ${args[1]}"; return 1; }
                    seen_logs[${args[1]}]=1 ;;
                require_log_text|require_final_time|warn_execution_time|require_final_initial_residual)
                    local required_arity=2
                    [[ "$operation" != require_final_initial_residual ]] || required_arity=3
                    [[ "$argc" == "$required_arity" ]] && central_log_id "${args[1]}" ||
                        { central_error "Invalid log check arity/ID"; return 1; }
                    [[ ${seen_logs[${args[1]}]+present} ]] || { central_error "Log ${args[1]} has not been produced in $stage"; return 1; }
                    if [[ "$operation" == require_log_text ]]; then
                        [[ -n "${args[2]}" ]] || { central_error "Empty log text"; return 1; }
                    else
                        [[ "$stage" == RUN ]] || { central_error "$operation is only valid in RUN"; return 1; }
                        central_nonnegative "${args[$required_arity]}" || { central_error "Invalid numeric log threshold"; return 1; }
                        if [[ "$operation" == require_final_initial_residual ]]; then
                            central_identifier "${args[2]}" || { central_error "Invalid residual field"; return 1; }
                        fi
                    fi ;;
                check_collated_decomposition)
                    [[ "$stage" != EXTRACT && "$argc" == 0 ]] ||
                        { central_error "Invalid collated decomposition stage/arity"; return 1; } ;;
                *) central_error "Unknown operation '$operation' in $array_name"; return 1 ;;
            esac
            index=$((index + 1))
        done
        [[ "$stage" != EXTRACT || "$extract_count" == 1 ]] ||
            { central_error "Exactly one extraction operation is required"; return 1; }
    done
    return 0
}

central_usage() {
    cat <<'USAGE'
Usage: STAGE (--recipe-dir|-r DIR | --config FILE)
             (--image|-i FILE | --shpc | --bare-metal)
             [--work-root|-w DIR] [--test-artifacts-dir DIR] [--help|-h]
Extraction also accepts --overwrite to replace only its target case.
Recipe config: buildAndValidationConfig/openfoamBuildAndValidation.central.config
Default workspace: ${MYSCRATCH:-${HOME}}/OpenFOAM-central/<user>-<version>
Default artifacts: <work-root>/test-output.central
Stages validate all configured operations before loading a runtime.
USAGE
}

central_parse_cli() {
    local config_count=0 runtime_count=0
    CENTRAL_CONFIG="" CENTRAL_IMAGE="" CENTRAL_RUNTIME="" CENTRAL_WORK_ROOT=""
    CENTRAL_OUTPUT="" CENTRAL_OVERWRITE=false CENTRAL_HELP=false
    while (( $# )); do
        case "$1" in
            --help|-h) central_usage; CENTRAL_HELP=true; return 0 ;;
            --recipe-dir|-r|--config|--image|-i|--work-root|-w|--test-artifacts-dir)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { central_error "$1 requires a value"; return 1; }
                case "$1" in
                    --recipe-dir|-r) CENTRAL_CONFIG="$2/buildAndValidationConfig/openfoamBuildAndValidation.central.config"; config_count=$((config_count + 1)) ;;
                    --config) CENTRAL_CONFIG="$2"; config_count=$((config_count + 1)) ;;
                    --image|-i) CENTRAL_IMAGE="$2"; CENTRAL_RUNTIME=image; runtime_count=$((runtime_count + 1)) ;;
                    --work-root|-w) CENTRAL_WORK_ROOT="$2" ;;
                    --test-artifacts-dir) CENTRAL_OUTPUT="$2" ;;
                esac
                shift 2 ;;
            --shpc|--bare-metal)
                CENTRAL_RUNTIME=${1#--}; runtime_count=$((runtime_count + 1)); shift ;;
            --overwrite)
                [[ "$CENTRAL_STAGE" == EXTRACT ]] || { central_error "--overwrite is extraction-only"; return 1; }
                CENTRAL_OVERWRITE=true; shift ;;
            *) central_error "Unknown option $1"; return 1 ;;
        esac
    done
    [[ "$config_count" == 1 && "$runtime_count" == 1 ]] ||
        { central_error "Choose exactly one configuration and exactly one runtime"; return 1; }
    central_load_config "$CENTRAL_CONFIG" || return 1
    if [[ "$CENTRAL_RUNTIME" == image ]]; then
        [[ -f "$CENTRAL_IMAGE" && -r "$CENTRAL_IMAGE" ]] || { central_error "Image not readable: $CENTRAL_IMAGE"; return 1; }
        CENTRAL_IMAGE=$(realpath "$CENTRAL_IMAGE") || return 1
    fi
    CENTRAL_WORK_ROOT=$(realpath -m "${CENTRAL_WORK_ROOT:-${MYSCRATCH:-${HOME}}/OpenFOAM-central/${USER:-$(id -un)}-${OPENFOAM_VERSION}}") || return 1
    [[ "$CENTRAL_WORK_ROOT" != / ]] || { central_error "Work root cannot be /"; return 1; }
    CENTRAL_CASE="$CENTRAL_WORK_ROOT/run/$TUTORIAL_CASE_NAME"
    CENTRAL_OUTPUT=$(realpath -m "${CENTRAL_OUTPUT:-$CENTRAL_WORK_ROOT/test-output.central}") || return 1
    [[ "$CENTRAL_OUTPUT" != "$CENTRAL_CASE" && "$CENTRAL_OUTPUT" != "$CENTRAL_CASE/"* ]] ||
        { central_error "Artifacts cannot be inside the tutorial case"; return 1; }
}

central_status_exit() {
    local status=$?
    trap - EXIT
    if (( status == 0 )); then
        printf 'SUCCESS\n' > "$CENTRAL_STATUS" || status=1
    else
        printf 'FAILED\n' > "$CENTRAL_STATUS"
    fi
    exit "$status"
}
central_start_artifacts() {
    local stage_name
    case "$CENTRAL_STAGE" in EXTRACT) stage_name=extractCase ;; PRE) stage_name=preFoam ;; RUN) stage_name=runFoam ;; esac
    mkdir -p "$CENTRAL_OUTPUT" || return 1
    CENTRAL_STATUS="$CENTRAL_OUTPUT/$stage_name.status.txt"
    printf 'RUNNING\n' > "$CENTRAL_STATUS" || return 1
    trap central_status_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    exec > >(tee "$CENTRAL_OUTPUT/$stage_name.run.log") 2>&1
    printf 'Stage: %s\nArtifacts: %s\nCase: %s\n' "$stage_name" "$CENTRAL_OUTPUT" "$CENTRAL_CASE"
}

# Generic commands enter the SHPC image; OpenFOAM tools instead use its wrappers.
central_generic() {
    case "$CENTRAL_RUNTIME" in
        image) singularity exec "$CENTRAL_IMAGE" "$@" ;;
        shpc) "${OPENFOAM_FORK}-exec" "$@" ;;
        bare-metal) "$@" ;;
    esac
}
central_setup_runtime() {
    case "$CENTRAL_RUNTIME" in
        image)
            module load "${SINGULARITY_MODULE:-singularity/4.3.5-mpi}" || return 1
            command -v singularity >/dev/null || return 1
            export SINGULARITY_CONTAINER="$CENTRAL_IMAGE" ;;
        shpc)
            module load "${OPENFOAM_FORK}-container/${OPENFOAM_VERSION}" || return 1
            command -v "${OPENFOAM_FORK}-exec" >/dev/null || return 1
            [[ -n "${SINGULARITY_CONTAINER:-}" && -r "$SINGULARITY_CONTAINER" ]] ||
                { central_error "SHPC backing image is unavailable"; return 1; } ;;
        bare-metal)
            module load "${OPENFOAM_FORK}/${OPENFOAM_VERSION}" || return 1 ;;
    esac
    module list || return 1
    local version
    version=$(central_generic bash -c 'printf "%s" "$WM_PROJECT_VERSION"') || return 1
    [[ "$version" == "$OPENFOAM_VERSION" ]] ||
        { central_error "Runtime version '$version' does not match '$OPENFOAM_VERSION'"; return 1; }
    printf 'PASS: Runtime WM_PROJECT_VERSION=%s\n' "$version"
    local rank ranks=0
    for ((rank=TUTORIAL_IO_GROUP_SIZE; rank<=TUTORIAL_NPROCS; rank+=TUTORIAL_IO_GROUP_SIZE)); do ranks+=" $rank"; done
    export FOAM_IORANKS="($ranks)"
    # Singularity's explicit environment overrides also survive --cleanenv wrappers.
    export SINGULARITYENV_FOAM_IORANKS="$FOAM_IORANKS"
    printf 'FOAM_IORANKS=%s\n' "$FOAM_IORANKS"
}
central_validate_allocation() {
    [[ "$CENTRAL_STAGE" != EXTRACT ]] || return 0
    local key expected actual
    for key in NODES TASKS CPUS_PER_TASK; do
        local config_key="TUTORIAL_${CENTRAL_STAGE}_${key}"
        expected=${!config_key}
        case "$key" in
            NODES) actual=${SLURM_JOB_NUM_NODES:-${SLURM_NNODES:-0}} ;;
            TASKS) actual=${SLURM_NTASKS:-0} ;;
            CPUS_PER_TASK) actual=${SLURM_CPUS_PER_TASK:-0} ;;
        esac
        [[ "$actual" == "$expected" ]] ||
            { central_error "$CENTRAL_STAGE allocation $key=$actual; expected $expected"; return 1; }
    done
}
central_tool() {
    local parallel="$1"; shift
    local -a command_prefix=() allocation=()
    [[ "$CENTRAL_RUNTIME" != image ]] || command_prefix=(singularity exec "$CENTRAL_IMAGE")
    if [[ "$CENTRAL_STAGE" == EXTRACT ]]; then
        central_generic "$@"
    else
        if [[ "$parallel" == true ]]; then
            allocation=(-l -u -N "$TUTORIAL_RUN_NODES" -n "$TUTORIAL_RUN_TASKS"
                -c "$TUTORIAL_RUN_CPUS_PER_TASK" "--ntasks-per-node=$((TUTORIAL_RUN_TASKS / TUTORIAL_RUN_NODES))")
        else
            allocation=(-N 1 -n 1 -c 1)
        fi
        srun "${allocation[@]}" "${command_prefix[@]}" "$@"
    fi
}
central_safe_case_path() {
    local resolved
    central_relative_path "$1" || { central_error "Unsafe case path: $1"; return 1; }
    resolved=$(realpath -m "$CENTRAL_CASE/$1") || return 1
    [[ "$resolved" == "$CENTRAL_CASE/"* ]] ||
        { central_error "Case path escapes workspace: $1"; return 1; }
}
central_run_logged() {
    local parallel="$1" log_id="$2"; shift 2
    local logfile="$CENTRAL_OUTPUT/$log_id.log"
    local -a pipeline_status
    central_tool "$parallel" "$@" 2>&1 | tee "$logfile"
    pipeline_status=("${PIPESTATUS[@]}")
    [[ "${pipeline_status[0]}" == 0 && "${pipeline_status[1]}" == 0 ]] ||
        { central_error "Command or log writer failed for $log_id"; return 1; }
    [[ "$parallel" != true || -s "$logfile" ]] || { central_error "Empty solver log: $logfile"; return 1; }
    if grep -qE 'FOAM FATAL (ERROR|IO ERROR)' "$logfile"; then
        central_error "OpenFOAM fatal error in $logfile"; return 1
    fi
}
central_extract_case() {
    local kind="$1" relative="${2:-}" output source
    local -a matches=()
    mkdir -p "$CENTRAL_WORK_ROOT/run" || return 1
    [[ ! -L "$CENTRAL_WORK_ROOT/run" ]] || { central_error "Run directory cannot be a symlink"; return 1; }
    if [[ -e "$CENTRAL_CASE" || -L "$CENTRAL_CASE" ]]; then
        [[ "$CENTRAL_OVERWRITE" == true ]] || { central_error "Case exists; use --overwrite: $CENTRAL_CASE"; return 1; }
        rm -rf -- "$CENTRAL_CASE" || return 1
    fi
    if [[ "$kind" == extract_unique ]]; then
        output=$(central_generic bash -c '[[ -n "$FOAM_TUTORIALS" && -d "$FOAM_TUTORIALS" ]] && find "$FOAM_TUTORIALS" -type d -name "$1" -print' bash "$TUTORIAL_CASE_NAME") || return 1
        [[ -z "$output" ]] || mapfile -t matches <<< "$output"
        [[ ${#matches[@]} == 1 ]] || { central_error "Expected one $TUTORIAL_CASE_NAME tutorial; found ${#matches[@]}"; return 1; }
        source=${matches[0]}
    else
        source=$(central_generic bash -c '
            [[ -n "$FOAM_TUTORIALS" && -d "$FOAM_TUTORIALS" ]] || exit 1
            root=$(realpath -- "$FOAM_TUTORIALS") || exit 1
            source=$(realpath -- "$root/$1") || exit 1
            [[ "$source" == "$root/"* && -d "$source" ]] || exit 1
            printf "%s" "$source"
        ' bash "$relative") || { central_error "Invalid relative tutorial source: $relative"; return 1; }
    fi
    central_generic cp -a --no-preserve=timestamps -- "$source" "$CENTRAL_CASE" || return 1
    [[ -d "$CENTRAL_CASE" && ! -L "$CENTRAL_CASE" ]] || return 1
    cd "$CENTRAL_CASE" || return 1
}
central_collated() {
    local start end directory
    for ((start=0; start<TUTORIAL_NPROCS; start+=TUTORIAL_IO_GROUP_SIZE)); do
        end=$((start + TUTORIAL_IO_GROUP_SIZE - 1))
        (( end < TUTORIAL_NPROCS )) || end=$((TUTORIAL_NPROCS - 1))
        directory="processors${TUTORIAL_NPROCS}_${start}-${end}"
        central_safe_case_path "$directory" && [[ -d "$directory" ]] ||
            { central_error "Missing collated directory: $directory"; return 1; }
    done
}
central_log_number() {
    local logfile="$1" kind="$2" field="${3:-}"
    # Match numeric tokens explicitly: malformed/missing values never become zero.
    awk -v kind="$kind" -v field="$field" '
        kind == "execution" && /ExecutionTime =/ {
            text=$0; sub(/^.*ExecutionTime = */, "", text); split(text,a,/[[:space:]]/); value=a[1]
        }
        kind == "residual" && index($0, "Solving for " field ",") {
            text=$0
            if (text ~ /Initial residual =/) {
                sub(/^.*Initial residual = */, "", text); split(text,a,/[,[:space:]]/); value=a[1]
            }
        }
        END { if (value == "") exit 1; print value }
    ' "$logfile"
}
central_dispatch() {
    local operation="$1"; shift
    local actual expected mode path value limit logfile
    case "$operation" in
        extract_unique|extract_relative) central_extract_case "$operation" "$@" ;;
        require_directory|require_file)
            central_safe_case_path "$1" || return 1
            if [[ "$operation" == require_directory ]]; then [[ -d "$1" ]]; else [[ -f "$1" ]]; fi ;;
        require_initial_conditions)
            central_safe_case_path 0 && central_safe_case_path 0.orig &&
                [[ -d 0 || -d 0.orig ]] ;;
        restore_initial_conditions)
            central_safe_case_path "$1" && central_safe_case_path "$2" && [[ -d "$1" ]] || return 1
            rm -rf -- "$2" || return 1
            cp -a -- "$1" "$2" ;;
        remove_decomposition)
            local -a paths=()
            for path in processor[0-9]* processors[0-9]*; do
                [[ -e "$path" || -L "$path" ]] || continue
                central_safe_case_path "$path" || return 1
                paths+=("$path")
            done
            (( ${#paths[@]} == 0 )) || rm -rf -- "${paths[@]}" ;;
        set_dictionary)
            central_safe_case_path "$1" && [[ -f "$1" ]] || return 1
            expected="$3"; mode="${4:-scalar}"
            central_tool false foamDictionary "$1" -entry "$2" -set "$expected" || return 1
            actual=$(central_tool false foamDictionary "$1" -entry "$2" -value) || return 1
            if [[ "$mode" == vector ]]; then
                central_vector "$actual" || return 1
                actual=$(central_normalize_vector "$actual") || return 1
                expected=$(central_normalize_vector "$expected") || return 1
            fi
            [[ "$actual" == "$expected" ]] || { central_error "Dictionary $1:$2 expected '$expected', got '$actual'"; return 1; } ;;
        run) central_run_logged false "$@" ;;
        run_parallel) central_run_logged true "$@" ;;
        require_log_text) grep -Fq -- "$2" "$CENTRAL_OUTPUT/$1.log" ;;
        check_collated_decomposition) central_collated ;;
        require_final_time)
            awk -v expected="$2" '
                { for (i=1; i<=NF-2; i++) if ($i=="Time" && $(i+1)=="=") {
                    time=$(i+2); sub(/s$/, "", time)
                    if (time ~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/ && time+0==expected+0) found=1
                } }
                END { exit !found }
            ' "$CENTRAL_OUTPUT/$1.log" ;;
        warn_execution_time|require_final_initial_residual)
            logfile="$CENTRAL_OUTPUT/$1.log"
            if [[ "$operation" == warn_execution_time ]]; then
                value=$(central_log_number "$logfile" execution) || return 1
                limit="$2"
            else
                value=$(central_log_number "$logfile" residual "$2") || return 1
                limit="$3"
            fi
            central_nonnegative "$value" || { central_error "Invalid numeric log result: $value"; return 1; }
            if ! awk -v value="$value" -v limit="$limit" 'BEGIN { exit !(value < limit) }'; then
                if [[ "$operation" == warn_execution_time ]]; then
                    printf 'WARNING: ExecutionTime is high: %ss; expected less than %ss\n' "$value" "$limit" >&2
                else
                    central_error "Final $2 initial residual $value is not below $limit"; return 1
                fi
            fi ;;
        *) central_error "Unknown operation: $operation"; return 1 ;;
    esac
}

central_stage_main() {
    CENTRAL_STAGE="$1"; shift
    central_parse_cli "$@" || return 1
    [[ "$CENTRAL_HELP" != true ]] || return 0
    central_start_artifacts || return 1
    central_validate_allocation || return 1
    central_setup_runtime || return 1
    if [[ "$CENTRAL_STAGE" != EXTRACT ]]; then
        [[ -d "$CENTRAL_CASE" && ! -L "$CENTRAL_CASE" && ! -L "$CENTRAL_WORK_ROOT/run" ]] ||
            { central_error "Missing or unsafe case: $CENTRAL_CASE"; return 1; }
        cd "$CENTRAL_CASE" || return 1
    fi
    local list_name="TUTORIAL_${CENTRAL_STAGE}_STEPS" id operation_name
    local -n stage_steps="$list_name"
    for id in "${stage_steps[@]}"; do
        operation_name="TUTORIAL_${CENTRAL_STAGE}_${id}"
        local -n operation_args="$operation_name"
        printf 'Step %s: %s\n' "$id" "${operation_args[0]}"
        central_dispatch "${operation_args[@]}" ||
            { central_error "Stage $CENTRAL_STAGE step $id failed"; return 1; }
    done
    printf 'ALL STEPS PASSED: central tutorial %s\n' "$CENTRAL_STAGE"
}
