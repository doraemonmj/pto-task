# Existing opportunistic backfill policy.
#
# The shared scheduler core traverses pending tasks and owns all queue mutation.
# This policy only decides whether the current task can start with the current
# resource snapshot; blocked tasks do not prevent younger tasks from backfilling.

# Upgrade bridge: an API-v1 daemon does not preload _core.sh. Source the new
# core locally and advertise v1 so an interrupted file-by-file installation
# still leaves a runnable scheduler. The API-v2 daemon preloads and validates
# the same root-managed core before sourcing this module.
if [[ "${SCHEDULER_CORE_API_VERSION:-}" == 1 ]]; then
    SCHEDULER_MODULE_API_VERSION=2
else
    # shellcheck source=_core.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_core.sh"
    SCHEDULER_MODULE_API_VERSION=1
fi
SCHEDULER_MODULE_NAME=backfill

scheduler_consider_task() {
    local task_file="$1" task_id="$2" pending_request="$3"
    local pending_device_count="$4" device_pool="$5"
    local assigned="$pending_request"

    # Resolve auto requests against the current in-memory device snapshot. The
    # pending file remains untouched until daemon core validates and claims it.
    if [[ "$pending_request" == auto || "$pending_request" == auto:* ]]; then
        assigned=$(resolve_device_request "" "$task_id" "$pending_request" "$device_pool") || {
            scheduler_plan_defer no_free_device
            return
        }
    fi

    if [[ -n "$assigned" && "$assigned" != none ]] && any_device_in_use "$assigned"; then
        log "defer $task_id: device $assigned in use"
        scheduler_plan_defer device_in_use
        return
    fi

    scheduler_plan_start "$assigned" runnable
}
