#!/usr/bin/env bash
# Daily updater. Installation and daemon activation happen only while the queue
# is empty and new submissions are blocked by the update reservation lock.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TOOL_ROOT="$(dirname "$APP_DIR")"
CONFIG_FILE="$TOOL_ROOT/config/taskqueue.conf"
STATE_DIR="$TOOL_ROOT/state"
LOGS_DIR="$TOOL_ROOT/logs"
TMP_DIR="$TOOL_ROOT/tmp"
RESTART_MARKER="$APP_DIR/.pto-task-restart-required"
ACTIVATION_RETRY_MARKER="$APP_DIR/.pto-task-activation-retry"

[ -f "$CONFIG_FILE" ] || exit 0
CONFIG_DIR="$(dirname "$CONFIG_FILE")"
if [[ "$(id -u)" -ne 0 || -L "$CONFIG_DIR" || -L "$CONFIG_FILE" ||
      "$(stat -c %u "$CONFIG_DIR")" -ne 0 || "$(stat -c %u "$CONFIG_FILE")" -ne 0 ||
      $((8#$(stat -c %a "$CONFIG_DIR") & 8#022)) -ne 0 ||
      $((8#$(stat -c %a "$CONFIG_FILE") & 8#022)) -ne 0 ]]; then
    echo "error: updater configuration must be root-owned and not group/world-writable" >&2
    exit 1
fi
source "$CONFIG_FILE"
STATE_DIR="${STATE_DIR:-$TOOL_ROOT/state}"
LOGS_DIR="${LOGS_DIR:-$TOOL_ROOT/logs}"
TMP_DIR="${TMP_DIR:-$TOOL_ROOT/tmp}"
UPDATE_REPOSITORY="${AUTO_UPDATE_REPOSITORY:-}"
if [[ -z "$UPDATE_REPOSITORY" && -f "$APP_DIR/.pto-task-update-repository" ]]; then
    UPDATE_REPOSITORY="$(<"$APP_DIR/.pto-task-update-repository")"
fi
UPDATE_BRANCH="${AUTO_UPDATE_BRANCH:-main}"
IDLE_WAIT_SECONDS="${AUTO_UPDATE_IDLE_WAIT_SECONDS:-7200}"
IDLE_WAIT_MAX_SECONDS="${AUTO_UPDATE_IDLE_WAIT_MAX_SECONDS:-7200}"
IDLE_RETRY_SECONDS="${AUTO_UPDATE_IDLE_RETRY_SECONDS:-300}"
IDLE_WAIT_HARD_MAX_SECONDS=7200
FETCH_ATTEMPTS=3
FETCH_RETRY_SECONDS=300

mkdir -p "$LOGS_DIR" "$TMP_DIR"
LOG_FILE="$LOGS_DIR/auto-update.log"
log() { printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG_FILE"; }

if [[ -z "$UPDATE_REPOSITORY" ]]; then
    log 'automatic update disabled: AUTO_UPDATE_REPOSITORY is empty'
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    log 'skip update: git is unavailable'
    exit 1
fi

checkout="$(mktemp -d "$TMP_DIR/auto-update.XXXXXX")"
trap 'rm -rf "$checkout"' EXIT
checkout_repo=""
for ((attempt = 1; attempt <= FETCH_ATTEMPTS; attempt++)); do
    candidate="$checkout/repo-$attempt"
    if git clone --depth 1 --branch "$UPDATE_BRANCH" "$UPDATE_REPOSITORY" "$candidate" >/dev/null 2>&1; then
        checkout_repo="$candidate"
        break
    fi
    if (( attempt < FETCH_ATTEMPTS )); then
        log "update check attempt ${attempt}/${FETCH_ATTEMPTS} failed; retrying in ${FETCH_RETRY_SECONDS}s"
        sleep "$FETCH_RETRY_SECONDS"
    fi
done
if [[ -z "$checkout_repo" ]]; then
    log "update check failed after ${FETCH_ATTEMPTS} attempts: unable to fetch repository"
    exit 1
fi

remote_revision="$(git -C "$checkout_repo" rev-parse HEAD)"
installed_revision="$(cat "$APP_DIR/.pto-task-release" 2>/dev/null || true)"
update_required=false
if [[ "$remote_revision" != "$installed_revision" ]]; then
    update_required=true
fi
if [[ "$update_required" == false && ! -e "$RESTART_MARKER" ]]; then
    log 'no update available'
    exit 0
fi

# Fetch first, then wait for an idle queue. Ignore .env sidecars; any actual
# pending/running task defers the app update without affecting current work.
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
if [[ ! -e "$lock_file" ]]; then
    install -m 666 /dev/null "$lock_file"
fi
exec 8>"$lock_file"
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
if [[ -f "$APP_DIR/.pto-task-install-options" ]]; then
    source "$APP_DIR/.pto-task-install-options"
fi
if [[ "$update_required" == true ]]; then
    if bash "$checkout_repo/setup.sh" --non-interactive \
        --tools-root "$(dirname "$TOOL_ROOT")" \
        --bin-dir "$BIN_DIR" --sbin-dir "$SBIN_DIR" >/dev/null 2>&1; then
        # New setup.sh creates this marker itself. Creating it here as well
        # keeps activation reliable for repositories with an older installer.
        : > "$RESTART_MARKER"
        chmod 600 "$RESTART_MARKER"
    else
        log 'update failed while installing app; existing deployment was retained where possible'
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
        : > "$ACTIVATION_RETRY_MARKER"
        chmod 600 "$ACTIVATION_RETRY_MARKER"
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
