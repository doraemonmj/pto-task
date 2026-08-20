# Pool-Aware Reservation Scheduling policy for multi-device tasks.
#
# Once the oldest satisfiable multi-device request cannot run because its
# devices are fragmented across current jobs, its effective device pool becomes
# a reservation barrier. Younger jobs may still use enough free devices outside
# that pool, while released devices inside it accumulate naturally. No device
# locks are held by the scheduler: allocation and atomic queue transitions
# remain daemon-core responsibilities.

SCHEDULER_MODULE_API_VERSION=1

POOL_AWARE_RESERVATION_MIN_DEVICES=${POOL_AWARE_RESERVATION_MIN_DEVICES:-2}
POOL_AWARE_RESERVATION_RESERVED_TASK=""

scheduler_validate_config() {
    if [[ ! "$POOL_AWARE_RESERVATION_MIN_DEVICES" =~ ^[0-9]+$ ]] ||
       (( POOL_AWARE_RESERVATION_MIN_DEVICES < 2 )); then
        echo "error: POOL_AWARE_RESERVATION_MIN_DEVICES must be an integer greater than or equal to 2" >&2
        return 1
    fi
}

# Print the effective auto pool in global allocation order: runtime/configured
# devices intersected with the task's DEVICE_POOL from task-submit.conf policy.
pool_aware_reservation_effective_pool() {
    local pool="${1:-}"
    local id candidate
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
    local joined
    joined=$(IFS=,; echo "${effective[*]}")
    printf '%s' "$joined"
}

# Count distinct devices an auto request could ever receive, ignoring current
# allocations. Impossible auto:N metadata must not freeze every younger task.
pool_aware_reservation_pool_capacity() {
    local effective
    effective=$(pool_aware_reservation_effective_pool "${1:-}")
    device_request_count "$effective"
}

pool_aware_reservation_devices_intersect() {
    local left="$1" right="$2" id
    local wrapped=",$right,"
    local -a ids
    IFS=',' read -ra ids <<< "$left"
    for id in "${ids[@]}"; do
        [[ -n "$id" && "$wrapped" == *",$id,"* ]] && return 0
    done
    return 1
}

# Allocate an auto request only from its effective pool outside a reservation.
# The returned concrete list can be passed directly to start_pending_task().
pool_aware_reservation_find_free_devices() {
    local need="$1" pool="$2" excluded="$3"
    local effective id joined
    local wrapped=",$excluded,"
    local -a candidates selected=()
    (( need > 0 )) || return 1
    effective=$(pool_aware_reservation_effective_pool "$pool")
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

pool_aware_reservation_mark_reserved() {
    local task_id="$1" device_count="$2" detail="$3"
    if [[ "$POOL_AWARE_RESERVATION_RESERVED_TASK" != "$task_id" ]]; then
        log "reserve: $task_id waiting for $device_count devices${detail:+ ($detail)}; accumulating cards"
        POOL_AWARE_RESERVATION_RESERVED_TASK="$task_id"
    fi
}

scheduler_schedule_tick() {
    local task_file task_id pending_dev pending_request pending_device_count device_pool capacity
    local reservation_active=0 reservation_seen=0 reservation_devices=""

    for task_file in "$PENDING_DIR"/task_*; do
        [ -f "$task_file" ] || continue
        [[ "$task_file" == *.env ]] && continue

        if [[ $CURRENT_JOBS -ge $MAX_CONCURRENT ]]; then
            log "concurrent limit ($MAX_CONCURRENT), deferring"
            break
        fi

        task_id=$(basename "$task_file")
        pending_dev=$(read_field DEVICE "$task_file")
        pending_device_count=$(device_request_count "$pending_dev")

        # After a reservation barrier, younger jobs may use only devices outside
        # its effective pool. Keep one concurrency slot available so the
        # reserved task can start as soon as its cards have accumulated.
        if (( reservation_active )); then
            (( CURRENT_JOBS < MAX_CONCURRENT - 1 )) || continue
            if [[ -z "$pending_dev" || "$pending_dev" == "none" ]]; then
                start_pending_task "$task_file" "$task_id" "$pending_dev" "$pending_device_count" || continue
                continue
            fi
            if (( MAX_CONCURRENT_8_CARD_TASKS > 0 )) &&
               [[ "$pending_device_count" -eq 8 ]] &&
               (( RUNNING_8_CARD_TASKS >= MAX_CONCURRENT_8_CARD_TASKS )); then
                continue
            fi
            if [[ "$pending_dev" == "auto" || "$pending_dev" == auto:* ]]; then
                (( pending_device_count > 0 )) || continue
                pending_request="$pending_dev"
                device_pool=$(read_field DEVICE_POOL "$task_file")
                pending_dev=$(pool_aware_reservation_find_free_devices "$pending_device_count" \
                    "$device_pool" "$reservation_devices") || continue
                log "assign $task_id: $pending_request -> $pending_dev (outside reservation [$reservation_devices])"
            else
                (( pending_device_count > 0 )) || continue
                pool_aware_reservation_devices_intersect "$pending_dev" "$reservation_devices" && continue
                any_device_in_use "$pending_dev" && continue
            fi
            start_pending_task "$task_file" "$task_id" "$pending_dev" "$pending_device_count" || continue
            continue
        fi

        # The dedicated eight-card admission cap is not resource fragmentation.
        # Keep historical backfill behavior until that cap opens; only then may
        # this task reserve devices if it still cannot assemble its allocation.
        if (( MAX_CONCURRENT_8_CARD_TASKS > 0 )) &&
           [[ "$pending_device_count" -eq 8 ]] &&
           (( RUNNING_8_CARD_TASKS >= MAX_CONCURRENT_8_CARD_TASKS )); then
            continue
        fi

        if [[ "$pending_dev" == "auto" || "$pending_dev" == auto:* ]]; then
            device_pool=$(read_field DEVICE_POOL "$task_file")
            if ! pending_dev=$(resolve_device_request "" "$task_id" "$pending_dev" "$device_pool"); then
                capacity=$(pool_aware_reservation_pool_capacity "$device_pool")
                if (( pending_device_count >= POOL_AWARE_RESERVATION_MIN_DEVICES &&
                      capacity >= pending_device_count )); then
                    reservation_devices=$(pool_aware_reservation_effective_pool "$device_pool")
                    pool_aware_reservation_mark_reserved "$task_id" "$pending_device_count" \
                        "devices=$reservation_devices, capacity=$capacity"
                    reservation_active=1
                    reservation_seen=1
                fi
                continue
            fi
        fi

        if [[ -n "$pending_dev" && "$pending_dev" != "none" ]] &&
           any_device_in_use "$pending_dev"; then
            log "defer $task_id: device $pending_dev in use"
            if (( pending_device_count >= POOL_AWARE_RESERVATION_MIN_DEVICES )); then
                reservation_devices="$pending_dev"
                pool_aware_reservation_mark_reserved "$task_id" "$pending_device_count" "devices=$pending_dev"
                reservation_active=1
                reservation_seen=1
            fi
            continue
        fi

        start_pending_task "$task_file" "$task_id" "$pending_dev" "$pending_device_count" || continue
        if [[ "$POOL_AWARE_RESERVATION_RESERVED_TASK" == "$task_id" ]]; then
            log "reserve: $task_id acquired its devices"
            POOL_AWARE_RESERVATION_RESERVED_TASK=""
        fi
    done

    # Reservation state is only an edge-triggered logging aid. Scheduling is
    # recomputed from pending/running files every tick, so restart and cancel do
    # not require persistent scheduler state.
    if (( reservation_seen == 0 )) && [[ -n "$POOL_AWARE_RESERVATION_RESERVED_TASK" ]] &&
       [[ ! -f "$PENDING_DIR/$POOL_AWARE_RESERVATION_RESERVED_TASK" ]]; then
        POOL_AWARE_RESERVATION_RESERVED_TASK=""
    fi
}
