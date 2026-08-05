#!/usr/bin/env bash
# One-command first install/update, activation, and verification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_ROOT="/home/pypto-tools"
BIN_DIR="/usr/local/bin"

# setup.sh owns option validation; this pass only locates the installed config
# needed for a safe restart check.
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        --help|-h) exec bash "$SCRIPT_DIR/setup.sh" "$@" ;;
    esac
    [[ $((i + 1)) -lt ${#args[@]} ]] || continue
    case "${args[$i]}" in
        --tools-root) TOOLS_ROOT="${args[$((i + 1))]}" ;;
        --bin-dir) BIN_DIR="${args[$((i + 1))]}" ;;
    esac
done
CONFIG_FILE="${TOOLS_ROOT%/}/pto-task/config/taskqueue.conf"
maintenance_file=""
deployment_set_maintenance=false

cleanup() {
    if [[ "$deployment_set_maintenance" == true && -n "$maintenance_file" ]]; then
        rm -f "$maintenance_file"
    fi
}
trap cleanup EXIT

if [[ "$(id -u)" -ne 0 ]]; then
    echo "error: deployment requires root; run: sudo bash deploy.sh" >&2
    exit 1
fi

# Remember whether this is an upgrade before setup installs the compatibility
# alias and reloads systemd.
daemon_was_active=false
if systemctl is-active --quiet pto-task.service || systemctl is-active --quiet taskqueue.service; then
    daemon_was_active=true
fi

# setup.sh initializes only a missing config and preserves an existing one.
bash "$SCRIPT_DIR/setup.sh" "$@"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "error: configuration was not initialized: $CONFIG_FILE" >&2
    exit 1
fi

systemctl enable pto-task.service

# The daemon's TERM handler kills its children, so an upgrade restart is only
# safe after maintenance mode has stopped new submissions and running/ is empty.
if [[ "$daemon_was_active" == true ]]; then
    state_dir="$(bash -c 'source "$1"; printf "%s" "${STATE_DIR:-${BASE_DIR:-}}"' _ "$CONFIG_FILE")"
    [[ -n "$state_dir" ]] || state_dir="${TOOLS_ROOT%/}/pto-task/state"
    maintenance_file="$state_dir/maintenance"
    if [[ ! -e "$maintenance_file" ]]; then
        printf '%s\n' 'deploying pto-task update' > "$maintenance_file"
        deployment_set_maintenance=true
    fi
    sleep 1
    running_task="$(find "$state_dir/running" -maxdepth 1 -type f ! -name '*.env' -print -quit 2>/dev/null || true)"
    if [[ -n "$running_task" ]]; then
        echo 'Application files were updated, but the daemon was not restarted because a task is running.' >&2
        echo 'Run sudo bash deploy.sh again after running tasks finish.' >&2
        exit 3
    fi
    echo 'Restarting pto-task.service to activate the updated daemon...'
    # On the first migration the active process may still belong to the old
    # canonical taskqueue.service unit loaded before its alias was installed.
    # Stopping the compatibility name is also safe on later deployments, when
    # it resolves to pto-task.service.
    if systemctl is-active --quiet taskqueue.service; then
        systemctl stop taskqueue.service
    fi
    systemctl restart pto-task.service
    cleanup
    deployment_set_maintenance=false
else
    echo 'Starting pto-task.service...'
    systemctl start pto-task.service
fi

echo 'Verifying deployment...'
if ! systemctl is-active --quiet pto-task.service; then
    systemctl status pto-task.service --no-pager || true
    echo 'error: pto-task.service did not become active' >&2
    exit 1
fi
systemctl status pto-task.service --no-pager
"${BIN_DIR%/}/task-submit" --list
rm -f "${TOOLS_ROOT%/}/pto-task/app/.pto-task-restart-required" \
    "${TOOLS_ROOT%/}/pto-task/app/.pto-task-activation-retry"

echo 'Deployment complete. taskqueue.service remains available as a compatibility alias.'
