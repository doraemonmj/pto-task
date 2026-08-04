#!/usr/bin/env bash
# Daily, idle-only app updater. It deliberately never restarts the daemon.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TOOL_ROOT="$(dirname "$APP_DIR")"
CONFIG_FILE="$TOOL_ROOT/config/taskqueue.conf"
STATE_DIR="$TOOL_ROOT/state"
LOGS_DIR="$TOOL_ROOT/logs"
TMP_DIR="$TOOL_ROOT/tmp"

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
IDLE_WAIT_SECONDS="${AUTO_UPDATE_IDLE_WAIT_SECONDS:-21600}"
IDLE_RETRY_SECONDS="${AUTO_UPDATE_IDLE_RETRY_SECONDS:-300}"

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
if ! git clone --depth 1 --branch "$UPDATE_BRANCH" "$UPDATE_REPOSITORY" "$checkout/repo" >/dev/null 2>&1; then
    log 'update check failed: unable to fetch repository'
    exit 1
fi

remote_revision="$(git -C "$checkout/repo" rev-parse HEAD)"
installed_revision="$(cat "$APP_DIR/.pto-task-release" 2>/dev/null || true)"
if [[ "$remote_revision" == "$installed_revision" ]]; then
    log 'no update available'
    exit 0
fi

# Fetch first, then wait for an idle queue. Ignore .env sidecars; any actual
# pending/running task defers the app update without affecting current work.
if [[ ! "$IDLE_WAIT_SECONDS" =~ ^[0-9]+$ || ! "$IDLE_RETRY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    log 'skip update: invalid idle wait configuration'
    exit 1
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
if bash "$checkout/repo/setup.sh" --tools-root "$(dirname "$TOOL_ROOT")" \
    --bin-dir "$BIN_DIR" --sbin-dir "$SBIN_DIR" >/dev/null 2>&1; then
    log "updated app to revision ${remote_revision:0:12}; daemon was not restarted"
else
    log 'update failed while installing app; existing deployment was retained where possible'
    exit 1
fi
