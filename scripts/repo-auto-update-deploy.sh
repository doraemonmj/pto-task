#!/usr/bin/env bash
# Deploy an exact repository-controlled target after verification. Installation
# and daemon activation happen only while the queue is empty and new submissions
# are blocked by the update reservation lock.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TOOL_ROOT="$(dirname "$APP_DIR")"
CONFIG_FILE="$TOOL_ROOT/config/taskqueue.conf"
STATE_DIR="$TOOL_ROOT/state"
LOGS_DIR="$TOOL_ROOT/logs"
TMP_DIR="$TOOL_ROOT/tmp"
RESTART_MARKER="$APP_DIR/.pto-task-restart-required"
ACTIVATION_RETRY_MARKER="$APP_DIR/.pto-task-activation-retry"
CONTROLLED_CHECKOUT="${PTO_TASK_UPDATE_CHECKOUT:-}"
CONTROLLED_TARGET="${PTO_TASK_UPDATE_TARGET:-}"

root_control_path_is_safe() {
    local path="$1" expected_type="$2" mode
    [[ ! -L "$path" ]] || return 1
    case "$expected_type" in
        directory) [[ -d "$path" ]] || return 1 ;;
        file) [[ -f "$path" && "$(stat -c %h "$path" 2>/dev/null || true)" == 1 ]] || return 1 ;;
        *) return 1 ;;
    esac
    [[ "$(stat -c %u "$path" 2>/dev/null || true)" == 0 ]] || return 1
    mode="$(stat -c %a "$path" 2>/dev/null || true)"
    [[ "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 8#022) == 0 ))
}

root_shared_directory_is_safe() {
    local path="$1"
    [[ ! -L "$path" && -d "$path" ]] || return 1
    [[ "$(stat -c %u "$path" 2>/dev/null || true)" == 0 ]] || return 1
    [[ "$(stat -c %a "$path" 2>/dev/null || true)" == 1777 ]]
}

path_exists_or_is_link() {
    [[ -e "$1" || -L "$1" ]]
}

replace_root_empty_file() {
    local destination="$1" mode="$2" parent temp
    parent="$(dirname "$destination")"
    if [[ -d "$destination" && ! -L "$destination" ]]; then
        echo "error: managed control file is a directory: $destination" >&2
        return 1
    fi
    temp="$(mktemp "$parent/.pto-task-write.XXXXXX")"
    chmod "$mode" "$temp"
    chown root:root "$temp"
    mv -Tf -- "$temp" "$destination"
}

[ -f "$CONFIG_FILE" ] || exit 0
CONFIG_DIR="$(dirname "$CONFIG_FILE")"
if [[ "$(id -u)" -ne 0 ]] ||
   ! root_control_path_is_safe "$TOOL_ROOT" directory ||
   ! root_control_path_is_safe "$APP_DIR" directory ||
   ! root_control_path_is_safe "$CONFIG_DIR" directory ||
   ! root_control_path_is_safe "$CONFIG_FILE" file; then
    echo "error: updater paths and configuration must be root-owned and not group/world-writable" >&2
    exit 1
fi
source "$CONFIG_FILE"
STATE_DIR="${STATE_DIR:-$TOOL_ROOT/state}"
LOGS_DIR="${LOGS_DIR:-$TOOL_ROOT/logs}"
TMP_DIR="${TMP_DIR:-$TOOL_ROOT/tmp}"
IDLE_WAIT_SECONDS="${AUTO_UPDATE_IDLE_WAIT_SECONDS:-7200}"
IDLE_WAIT_MAX_SECONDS="${AUTO_UPDATE_IDLE_WAIT_MAX_SECONDS:-7200}"
IDLE_RETRY_SECONDS="${AUTO_UPDATE_IDLE_RETRY_SECONDS:-300}"
IDLE_WAIT_HARD_MAX_SECONDS=7200

mkdir -p "$LOGS_DIR" "$TMP_DIR"
if ! root_control_path_is_safe "$STATE_DIR" directory ||
   ! root_control_path_is_safe "$LOGS_DIR" directory ||
   ! root_control_path_is_safe "$TMP_DIR" directory ||
   ! root_control_path_is_safe "$STATE_DIR/running" directory ||
   ! root_shared_directory_is_safe "$STATE_DIR/pending" ||
   ! root_shared_directory_is_safe "$STATE_DIR/locks"; then
    echo "error: updater state, log, and temporary directories must be root-owned and not group/world-writable" >&2
    exit 1
fi
LOG_FILE="$LOGS_DIR/auto-update.log"
if path_exists_or_is_link "$LOG_FILE"; then
    if ! root_control_path_is_safe "$LOG_FILE" file; then
        echo "error: automatic-update log must be a root-owned, single-link regular file and not group/world-writable" >&2
        exit 1
    fi
else
    replace_root_empty_file "$LOG_FILE" 644
fi
log() { printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG_FILE"; }
short_revision() {
    local revision="${1:-unknown}"
    printf '%s' "${revision:0:12}"
}
append_setup_log() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        log "setup: $line"
    done < "$1"
}

if path_exists_or_is_link "$APP_DIR/.pto-task-install-options" &&
   ! root_control_path_is_safe "$APP_DIR/.pto-task-install-options" file; then
    log 'update aborted: unsafe installer-options control file'
    exit 1
fi
for control_file in "$APP_DIR/.pto-task-release" "$RESTART_MARKER" "$ACTIVATION_RETRY_MARKER"; do
    if path_exists_or_is_link "$control_file" &&
       ! root_control_path_is_safe "$control_file" file; then
        log "update aborted: unsafe root control file: $control_file"
        exit 1
    fi
done

if ! command -v git >/dev/null 2>&1; then
    log 'skip update: git is unavailable'
    exit 1
fi

if [[ -z "$CONTROLLED_CHECKOUT" || -z "$CONTROLLED_TARGET" ||
      ! "$CONTROLLED_TARGET" =~ ^[0-9a-f]{40,64}$ ]]; then
    log 'controlled update aborted: checkout and full target are required'
    exit 1
fi
if ! root_control_path_is_safe "$CONTROLLED_CHECKOUT" directory; then
    log 'controlled update aborted: candidate checkout is unsafe'
    exit 1
fi
checkout_repo="$CONTROLLED_CHECKOUT"
remote_revision="$(git -C "$checkout_repo" rev-parse HEAD 2>/dev/null || true)"
if [[ "$remote_revision" != "$CONTROLLED_TARGET" ]]; then
    log "controlled update aborted: checkout revision does not match target $(short_revision "$CONTROLLED_TARGET")"
    exit 1
fi

installed_revision="$(cat "$APP_DIR/.pto-task-release" 2>/dev/null || true)"
update_required=false
if [[ "$remote_revision" != "$installed_revision" ]]; then
    update_required=true
    log "update available: installed=$(short_revision "${installed_revision:-unknown}") remote=$(short_revision "$remote_revision")"
fi
if [[ "$update_required" == false && ! -e "$RESTART_MARKER" ]]; then
    log 'no update available'
    exit 0
fi

# The module has already fetched and verified this exact candidate. Wait for an
# idle queue; ignore .env sidecars, while any real task defers the deployment.
if [[ ! "$IDLE_WAIT_SECONDS" =~ ^[0-9]+$ ||
      ! "$IDLE_WAIT_MAX_SECONDS" =~ ^[0-9]+$ ||
      ! "$IDLE_RETRY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    log 'skip update: invalid idle wait configuration'
    exit 1
fi
if (( IDLE_WAIT_MAX_SECONDS > IDLE_WAIT_HARD_MAX_SECONDS )); then
    log "idle wait maximum capped from ${IDLE_WAIT_MAX_SECONDS}s to ${IDLE_WAIT_HARD_MAX_SECONDS}s"
    IDLE_WAIT_MAX_SECONDS="$IDLE_WAIT_HARD_MAX_SECONDS"
fi
if (( IDLE_WAIT_SECONDS > IDLE_WAIT_MAX_SECONDS )); then
    log "idle wait capped from ${IDLE_WAIT_SECONDS}s to ${IDLE_WAIT_MAX_SECONDS}s"
    IDLE_WAIT_SECONDS="$IDLE_WAIT_MAX_SECONDS"
fi
elapsed=0
lock_file="$STATE_DIR/locks/update-reservation.lock"
if [[ -L "$lock_file" || ! -f "$lock_file" ||
      "$(stat -c %h "$lock_file" 2>/dev/null || true)" != 1 ||
      "$(stat -c %u "$lock_file" 2>/dev/null || true)" != 0 ||
      "$(stat -c %a "$lock_file" 2>/dev/null || true)" != 666 ]]; then
    log "update aborted: reservation lock must be a root-owned, single-link regular file with mode 0666"
    exit 1
fi
exec 8>>"$lock_file"
flock -x 8
while :; do
    busy=false
    for queue_dir in "$STATE_DIR/pending" "$STATE_DIR/running"; do
        if find "$queue_dir" -maxdepth 1 -type f ! -name '*.env' -print -quit 2>/dev/null | grep -q .; then
            busy=true
            break
        fi
    done
    if [[ "$busy" == false ]]; then
        break
    fi
    if (( elapsed >= IDLE_WAIT_SECONDS )); then
        log "skip update: queue remained busy for ${IDLE_WAIT_SECONDS}s after fetch"
        exit 0
    fi
    sleep "$IDLE_RETRY_SECONDS"
    elapsed=$((elapsed + IDLE_RETRY_SECONDS))
done

BIN_DIR=/usr/local/bin
SBIN_DIR=/usr/local/sbin
INSTALL_ENABLE_AUTO_UPDATE=true
if [[ -f "$APP_DIR/.pto-task-install-options" ]]; then
    source "$APP_DIR/.pto-task-install-options"
fi
# Preserve automatic polling when upgrading a host that briefly used the
# two-channel option file (`auto=false`, `repo-auto=true`).
if [[ "${INSTALL_ENABLE_REPO_AUTO_UPDATE:-false}" == true ]]; then
    INSTALL_ENABLE_AUTO_UPDATE=true
fi
setup_update_args=(
    --non-interactive
    --tools-root "$(dirname "$TOOL_ROOT")"
    --bin-dir "$BIN_DIR"
    --sbin-dir "$SBIN_DIR"
)
if [[ "$INSTALL_ENABLE_AUTO_UPDATE" == true ]]; then
    setup_update_args+=(--enable-auto-update)
else
    setup_update_args+=(--disable-auto-update)
fi
if [[ "$update_required" == true ]]; then
    setup_log="$(mktemp "$TMP_DIR/controlled-update-setup.XXXXXX")"
    trap 'rm -f "$setup_log"' EXIT
    setup_rc=0
    if bash "$checkout_repo/setup.sh" "${setup_update_args[@]}" >"$setup_log" 2>&1; then
        setup_rc=0
    else
        setup_rc=$?
    fi
    append_setup_log "$setup_log"
    if (( setup_rc == 0 )); then
        # New setup.sh creates this marker itself. Creating it here as well
        # keeps activation reliable for repositories with an older installer.
        if path_exists_or_is_link "$RESTART_MARKER" &&
           ! root_control_path_is_safe "$RESTART_MARKER" file; then
            log "update aborted: installer produced an unsafe restart marker"
            exit 1
        fi
        replace_root_empty_file "$RESTART_MARKER" 600
    else
        log "update failed while installing app (rc=$setup_rc target=$(short_revision "$remote_revision")); previous revision remains retryable"
        exit 1
    fi
    if ! root_control_path_is_safe "$APP_DIR/.pto-task-release" file; then
        log 'update verification failed: installer did not produce a safe release file'
        exit 1
    fi
    installed_after="$(cat "$APP_DIR/.pto-task-release" 2>/dev/null || true)"
    if [[ "$installed_after" != "$remote_revision" ]]; then
        log "update verification failed: installed=$(short_revision "${installed_after:-unknown}") expected=$(short_revision "$remote_revision")"
        exit 1
    fi
fi

if [[ -e "$RESTART_MARKER" ]]; then
    daemon_should_activate=false
    if systemctl is-active --quiet pto-task.service ||
       systemctl is-active --quiet taskqueue.service; then
        daemon_should_activate=true
    elif [[ -e "$ACTIVATION_RETRY_MARKER" ]]; then
        # A previous restart may have stopped the old process before the new
        # daemon failed to start. Keep retrying instead of treating that state
        # as an intentionally disabled service.
        daemon_should_activate=true
    fi

    if [[ "$daemon_should_activate" == true ]]; then
        if path_exists_or_is_link "$ACTIVATION_RETRY_MARKER" &&
           ! root_control_path_is_safe "$ACTIVATION_RETRY_MARKER" file; then
            log 'update aborted: unsafe activation-retry marker'
            exit 1
        fi
        replace_root_empty_file "$ACTIVATION_RETRY_MARKER" 600
        # During the first migration taskqueue.service can still be the old
        # canonical unit. On later installs it is just the compatibility alias.
        if systemctl is-active --quiet taskqueue.service; then
            systemctl stop taskqueue.service
        fi
        if systemctl restart pto-task.service &&
           systemctl is-active --quiet pto-task.service; then
            rm -f "$RESTART_MARKER" "$ACTIVATION_RETRY_MARKER"
            if [[ "$update_required" == true ]]; then
                log "updated app to revision ${remote_revision:0:12}; daemon restarted"
            else
                log "activated installed revision ${installed_revision:0:12}; daemon restarted"
            fi
        else
            log 'daemon restart failed; activation will be retried'
            exit 1
        fi
    elif [[ "$update_required" == true ]]; then
        log "updated app to revision ${remote_revision:0:12}; daemon is inactive, activation remains pending"
    else
        log 'daemon is inactive; activation remains pending'
    fi
fi
