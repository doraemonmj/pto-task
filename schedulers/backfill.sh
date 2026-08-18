# Existing opportunistic backfill policy.
#
# Scheduler modules are sourced once by task-daemon. They may choose which
# pending task to try, but claiming the task and starting it remain daemon-core
# responsibilities through start_pending_task().

SCHEDULER_MODULE_API_VERSION=1

scheduler_schedule_tick() {
    local task_file task_id pending_dev pending_device_count device_pool

    for task_file in "$PENDING_DIR"/task_*; do
        [ -f "$task_file" ] || continue
        # Environment snapshots live beside task files but are not queue items.
        [[ "$task_file" == *.env ]] && continue

        if [[ $CURRENT_JOBS -ge $MAX_CONCURRENT ]]; then
            log "concurrent limit ($MAX_CONCURRENT), deferring"
            break
        fi

        task_id=$(basename "$task_file")
        pending_dev=$(read_field DEVICE "$task_file")
        pending_device_count=$(device_request_count "$pending_dev")

        # Preserve the host-local eight-card admission policy. A blocked large
        # task does not prevent later smaller tasks from backfilling.
        if (( MAX_CONCURRENT_8_CARD_TASKS > 0 )) &&
           [[ "$pending_device_count" -eq 8 ]] &&
           (( RUNNING_8_CARD_TASKS >= MAX_CONCURRENT_8_CARD_TASKS )); then
            continue
        fi

        # Resolve auto requests against the current in-memory device snapshot.
        # The pending file remains untouched until daemon core claims it.
        if [[ "$pending_dev" == "auto" || "$pending_dev" == auto:* ]]; then
            device_pool=$(read_field DEVICE_POOL "$task_file")
            pending_dev=$(resolve_device_request "" "$task_id" "$pending_dev" "$device_pool") || continue
        fi

        if [[ -n "$pending_dev" && "$pending_dev" != "none" ]] &&
           any_device_in_use "$pending_dev"; then
            log "defer $task_id: device $pending_dev in use"
            continue
        fi

        start_pending_task "$task_file" "$task_id" "$pending_dev" "$pending_device_count" || continue
    done
}
