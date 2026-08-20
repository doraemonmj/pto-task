# Pool-Aware Reservation Scheduling policy for multi-device tasks.
#
# Once the oldest satisfiable multi-device request cannot run because its
# devices are fragmented across current jobs, its effective device pool becomes
# a reservation barrier. Younger jobs may still use enough free devices outside
# that pool, while released devices inside it accumulate naturally. The shared
# scheduler core validates allocations and owns atomic queue transitions.

# Keep upgrades restart-safe across the API transition. An API-v1 daemon can
# source the newly installed core through this module if setup is interrupted;
# the API-v2 daemon preloads and validates the core itself.
if [[ "${SCHEDULER_CORE_API_VERSION:-}" == 1 ]]; then
    SCHEDULER_MODULE_API_VERSION=2
else
    # shellcheck source=_core.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_core.sh"
    SCHEDULER_MODULE_API_VERSION=1
fi
SCHEDULER_MODULE_NAME=pool_aware_reservation

POOL_AWARE_RESERVATION_MIN_DEVICES=${POOL_AWARE_RESERVATION_MIN_DEVICES:-2}
POOL_AWARE_RESERVATION_RESERVED_TASK=""
POOL_AWARE_RESERVATION_ACTIVE=0
POOL_AWARE_RESERVATION_SEEN=0
POOL_AWARE_RESERVATION_DEVICES=""

scheduler_validate_config() {
    if [[ ! "$POOL_AWARE_RESERVATION_MIN_DEVICES" =~ ^[0-9]+$ ]] ||
       (( POOL_AWARE_RESERVATION_MIN_DEVICES < 2 )); then
        echo "error: POOL_AWARE_RESERVATION_MIN_DEVICES must be an integer greater than or equal to 2" >&2
        return 1
    fi
}

pool_aware_reservation_mark_reserved() {
    local task_id="$1" device_count="$2" detail="$3"
    if [[ "$POOL_AWARE_RESERVATION_RESERVED_TASK" != "$task_id" ]]; then
        log "reserve: $task_id waiting for $device_count devices${detail:+ ($detail)}; accumulating cards"
        POOL_AWARE_RESERVATION_RESERVED_TASK="$task_id"
    fi
}

scheduler_begin_tick() {
    POOL_AWARE_RESERVATION_ACTIVE=0
    POOL_AWARE_RESERVATION_SEEN=0
    POOL_AWARE_RESERVATION_DEVICES=""
}

scheduler_consider_task() {
    local task_file="$1" task_id="$2" pending_request="$3"
    local pending_device_count="$4" device_pool="$5"
    local assigned="$pending_request" capacity

    # After a reservation barrier, younger jobs may use only devices outside
    # its effective pool. Keep one concurrency slot available so the reserved
    # task can start as soon as its cards have accumulated.
    if (( POOL_AWARE_RESERVATION_ACTIVE )); then
        if (( CURRENT_JOBS >= MAX_CONCURRENT - 1 )); then
            scheduler_plan_defer reserved_concurrency_slot
            return
        fi
        if [[ -z "$pending_request" || "$pending_request" == none ]]; then
            scheduler_plan_start "$pending_request" outside_reservation
            return
        fi
        if [[ "$pending_request" == auto || "$pending_request" == auto:* ]]; then
            (( pending_device_count > 0 )) || {
                scheduler_plan_defer invalid_device_request
                return
            }
            assigned=$(scheduler_find_free_devices "$pending_device_count" "$device_pool" \
                "$POOL_AWARE_RESERVATION_DEVICES") || {
                scheduler_plan_defer reserved_pool_overlap
                return
            }
            log "assign $task_id: $pending_request -> $assigned (outside reservation [$POOL_AWARE_RESERVATION_DEVICES])"
        else
            (( pending_device_count > 0 )) || {
                scheduler_plan_defer invalid_device_request
                return
            }
            if scheduler_devices_intersect "$assigned" "$POOL_AWARE_RESERVATION_DEVICES" ||
               any_device_in_use "$assigned"; then
                scheduler_plan_defer reserved_pool_overlap
                return
            fi
        fi
        scheduler_plan_start "$assigned" outside_reservation
        return
    fi

    if [[ "$pending_request" == auto || "$pending_request" == auto:* ]]; then
        if ! assigned=$(resolve_device_request "" "$task_id" "$pending_request" "$device_pool"); then
            capacity=$(scheduler_pool_capacity "$device_pool")
            if (( pending_device_count >= POOL_AWARE_RESERVATION_MIN_DEVICES &&
                  capacity >= pending_device_count )); then
                POOL_AWARE_RESERVATION_DEVICES=$(scheduler_effective_pool "$device_pool")
                pool_aware_reservation_mark_reserved "$task_id" "$pending_device_count" \
                    "devices=$POOL_AWARE_RESERVATION_DEVICES, capacity=$capacity"
                POOL_AWARE_RESERVATION_ACTIVE=1
                POOL_AWARE_RESERVATION_SEEN=1
                scheduler_plan_defer reservation_created
                return
            fi
            scheduler_plan_defer no_free_device
            return
        fi
    fi

    if [[ -n "$assigned" && "$assigned" != none ]] && any_device_in_use "$assigned"; then
        log "defer $task_id: device $assigned in use"
        if (( pending_device_count >= POOL_AWARE_RESERVATION_MIN_DEVICES )); then
            POOL_AWARE_RESERVATION_DEVICES="$assigned"
            pool_aware_reservation_mark_reserved "$task_id" "$pending_device_count" "devices=$assigned"
            POOL_AWARE_RESERVATION_ACTIVE=1
            POOL_AWARE_RESERVATION_SEEN=1
            scheduler_plan_defer reservation_created
            return
        fi
        scheduler_plan_defer device_in_use
        return
    fi

    scheduler_plan_start "$assigned" runnable
}

scheduler_end_tick() {
    # Reservation state is only an edge-triggered logging aid. Scheduling is
    # recomputed from pending/running files every tick, so restart and cancel do
    # not require persistent scheduler state.
    if (( POOL_AWARE_RESERVATION_SEEN == 0 )) &&
       [[ -n "$POOL_AWARE_RESERVATION_RESERVED_TASK" ]] &&
       [[ ! -f "$PENDING_DIR/$POOL_AWARE_RESERVATION_RESERVED_TASK" ]]; then
        POOL_AWARE_RESERVATION_RESERVED_TASK=""
    fi
}

scheduler_task_started() {
    local task_id="$1"
    if [[ "$POOL_AWARE_RESERVATION_RESERVED_TASK" == "$task_id" ]]; then
        log "reserve: $task_id acquired its devices"
        POOL_AWARE_RESERVATION_RESERVED_TASK=""
    fi
}
