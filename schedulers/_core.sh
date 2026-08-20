# Shared scheduler planning and validation core.
#
# This file is sourced by task-daemon before the selected policy module. It is
# deliberately named with a leading underscore so it cannot be selected by the
# SCHEDULER_MODE identifier grammar. Policies decide whether to start, defer, or
# stop; daemon core owns queue traversal, validates every start decision, and
# performs the atomic pending -> running transition.

SCHEDULER_CORE_API_VERSION=1

SCHEDULER_DECISION=""
SCHEDULER_DECISION_DEVICES=""
SCHEDULER_DECISION_REASON=""

scheduler_reset_decision() {
    SCHEDULER_DECISION=""
    SCHEDULER_DECISION_DEVICES=""
    SCHEDULER_DECISION_REASON=""
}

scheduler_set_decision() {
    local decision="$1" devices="${2:-}" reason="${3:-}"
    if [[ -n "$SCHEDULER_DECISION" ]]; then
        log "scheduler error: policy returned more than one decision"
        return 1
    fi
    SCHEDULER_DECISION="$decision"
    SCHEDULER_DECISION_DEVICES="$devices"
    SCHEDULER_DECISION_REASON="$reason"
}

scheduler_plan_start() {
    scheduler_set_decision start "${1:-}" "${2:-}"
}

scheduler_plan_defer() {
    scheduler_set_decision defer "" "${1:-}"
}

scheduler_plan_stop() {
    scheduler_set_decision stop "" "${1:-}"
}

# Print the effective auto pool in global allocation order: runtime/configured
# devices intersected with the task's DEVICE_POOL from task-submit.conf policy.
scheduler_effective_pool() {
    local pool="${1:-}"
    local id candidate joined
    local -a candidates pool_arr
    local -a effective=()
    local -A allowed=() seen=()

    if [[ -n "${RUNTIME_DEVICES:-}" ]]; then
        IFS=',' read -ra candidates <<< "$RUNTIME_DEVICES"
    elif [[ -n "${AVAILABLE_DEVICES:-}" ]]; then
        IFS=',' read -ra candidates <<< "$AVAILABLE_DEVICES"
    else
        local num
        num=$(detect_device_count)
        candidates=($(seq 0 $((num-1))))
    fi

    if [[ -n "$pool" ]]; then
        IFS=',' read -ra pool_arr <<< "$pool"
        for id in "${pool_arr[@]}"; do
            [[ -n "$id" ]] && allowed["$id"]=1
        done
    fi

    for candidate in "${candidates[@]}"; do
        [[ -n "$candidate" ]] || continue
        if [[ -n "$pool" && -z "${allowed[$candidate]:-}" ]]; then
            continue
        fi
        [[ -n "${seen[$candidate]:-}" ]] && continue
        seen["$candidate"]=1
        effective+=("$candidate")
    done
    joined=$(IFS=,; echo "${effective[*]}")
    printf '%s' "$joined"
}

scheduler_pool_capacity() {
    local effective
    effective=$(scheduler_effective_pool "${1:-}")
    device_request_count "$effective"
}

scheduler_devices_intersect() {
    local left="$1" right="$2" id
    local wrapped=",$right,"
    local -a ids
    IFS=',' read -ra ids <<< "$left"
    for id in "${ids[@]}"; do
        [[ -n "$id" && "$wrapped" == *",$id,"* ]] && return 0
    done
    return 1
}

scheduler_devices_subset() {
    local devices="$1" pool="$2" id
    local wrapped=",$pool,"
    local -a ids
    IFS=',' read -ra ids <<< "$devices"
    for id in "${ids[@]}"; do
        [[ -n "$id" && "$wrapped" == *",$id,"* ]] || return 1
    done
    return 0
}

# Allocate an auto request from its effective pool while optionally excluding a
# reservation pool. The result is concrete and suitable for scheduler_plan_start.
scheduler_find_free_devices() {
    local need="$1" pool="${2:-}" excluded="${3:-}"
    local effective id joined
    local wrapped=",$excluded,"
    local -a candidates selected=()
    (( need > 0 )) || return 1
    effective=$(scheduler_effective_pool "$pool")
    IFS=',' read -ra candidates <<< "$effective"
    for id in "${candidates[@]}"; do
        [[ -n "$id" ]] || continue
        [[ "$wrapped" == *",$id,"* ]] && continue
        any_device_in_use "$id" || selected+=("$id")
        if (( ${#selected[@]} >= need )); then
            joined=$(IFS=,; echo "${selected[*]}")
            printf '%s' "$joined"
            return 0
        fi
    done
    return 1
}

# Re-read and validate a policy start decision immediately before claiming the
# task. This prevents a buggy or future policy from double-allocating a device,
# escaping an auto pool, changing the requested cardinality, or exceeding a
# host admission limit. Explicit requests retain their historical semantics.
scheduler_start_planned_task() {
    local task_file="$1" task_id="$2" pending_request="$3"
    local pending_device_count="$4" device_pool="$5" assigned="$6"
    local current_request current_pool effective assigned_count
    local -a assigned_ids=()

    if [[ "$task_file" != "$PENDING_DIR/$task_id" || "$(basename "$task_file")" != "$task_id" ||
          ! -f "$task_file" ]]; then
        log "scheduler reject $task_id: pending task identity changed before claim"
        return 1
    fi

    current_request=$(read_field DEVICE "$task_file" || true)
    current_pool=$(read_field DEVICE_POOL "$task_file" || true)
    if [[ "$current_request" != "$pending_request" || "$current_pool" != "$device_pool" ]]; then
        log "scheduler reject $task_id: task device metadata changed during planning"
        return 1
    fi

    if (( CURRENT_JOBS >= MAX_CONCURRENT )); then
        log "scheduler reject $task_id: concurrent limit changed during planning"
        return 1
    fi
    if (( MAX_CONCURRENT_8_CARD_TASKS > 0 )) &&
       (( pending_device_count == 8 )) &&
       (( RUNNING_8_CARD_TASKS >= MAX_CONCURRENT_8_CARD_TASKS )); then
        log "scheduler reject $task_id: eight-card admission limit changed during planning"
        return 1
    fi

    case "$pending_request" in
        ""|none)
            if [[ -n "$assigned" && "$assigned" != none ]]; then
                log "scheduler reject $task_id: no-device task was assigned '$assigned'"
                return 1
            fi
            ;;
        auto|auto:*)
            assigned_count=$(device_request_count "$assigned")
            IFS=',' read -ra assigned_ids <<< "$assigned"
            if (( pending_device_count <= 0 ||
                  assigned_count != pending_device_count ||
                  ${#assigned_ids[@]} != assigned_count )); then
                log "scheduler reject $task_id: auto request '$pending_request' received invalid allocation '$assigned'"
                return 1
            fi
            effective=$(scheduler_effective_pool "$device_pool")
            if ! scheduler_devices_subset "$assigned" "$effective"; then
                log "scheduler reject $task_id: allocation '$assigned' is outside effective pool [$effective]"
                return 1
            fi
            ;;
        *)
            if [[ "$assigned" != "$pending_request" ]]; then
                log "scheduler reject $task_id: explicit request '$pending_request' changed to '$assigned'"
                return 1
            fi
            ;;
    esac

    if [[ -n "$assigned" && "$assigned" != none ]] && any_device_in_use "$assigned"; then
        log "scheduler reject $task_id: planned device $assigned is already in use"
        return 1
    fi

    start_pending_task "$task_file" "$task_id" "$assigned" "$pending_device_count"
}

# Traverse the pending queue once. Policy modules see a stable per-task snapshot
# and return exactly one decision; all mutation remains in daemon core.
scheduler_schedule_tick() {
    local task_file task_id pending_request pending_device_count device_pool
    local policy_failed=0

    if declare -F scheduler_begin_tick >/dev/null && ! scheduler_begin_tick; then
        log "scheduler error: $SCHEDULER_MODE failed to begin tick"
        return 1
    fi

    for task_file in "$PENDING_DIR"/task_*; do
        [[ -f "$task_file" ]] || continue
        [[ "$task_file" == *.env ]] && continue

        if (( CURRENT_JOBS >= MAX_CONCURRENT )); then
            log "concurrent limit ($MAX_CONCURRENT), deferring"
            break
        fi

        task_id=$(basename "$task_file")
        pending_request=$(read_field DEVICE "$task_file" || true)
        pending_device_count=$(device_request_count "$pending_request")
        device_pool=$(read_field DEVICE_POOL "$task_file" || true)

        # This is a host admission invariant, not a policy choice. Keeping it in
        # core prevents future schedulers from accidentally bypassing the cap.
        if (( MAX_CONCURRENT_8_CARD_TASKS > 0 )) &&
           (( pending_device_count == 8 )) &&
           (( RUNNING_8_CARD_TASKS >= MAX_CONCURRENT_8_CARD_TASKS )); then
            continue
        fi

        scheduler_reset_decision
        if ! scheduler_consider_task "$task_file" "$task_id" "$pending_request" \
            "$pending_device_count" "$device_pool"; then
            log "scheduler error: $SCHEDULER_MODE failed while considering $task_id"
            policy_failed=1
            break
        fi

        case "$SCHEDULER_DECISION" in
            start)
                scheduler_start_planned_task "$task_file" "$task_id" "$pending_request" \
                    "$pending_device_count" "$device_pool" "$SCHEDULER_DECISION_DEVICES" || continue
                if declare -F scheduler_task_started >/dev/null; then
                    scheduler_task_started "$task_id" "$SCHEDULER_DECISION_DEVICES" ||
                        log "scheduler warning: $SCHEDULER_MODE start notification failed for $task_id"
                fi
                ;;
            defer)
                continue
                ;;
            stop)
                break
                ;;
            *)
                log "scheduler error: $SCHEDULER_MODE returned invalid decision '${SCHEDULER_DECISION:-<empty>}' for $task_id"
                policy_failed=1
                break
                ;;
        esac
    done

    if declare -F scheduler_end_tick >/dev/null && ! scheduler_end_tick; then
        log "scheduler error: $SCHEDULER_MODE failed to end tick"
        return 1
    fi
    (( policy_failed == 0 ))
}
