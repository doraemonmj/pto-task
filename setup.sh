#!/usr/bin/env bash
# Install the task queue without starting, restarting, or reconfiguring it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_ROOT="/home/pypto-tools"
TOOL_NAME="pto-task"
INIT_CONFIG=false
BIN_DIR="/usr/local/bin"
SBIN_DIR="/usr/local/sbin"
ENABLE_AUTO_UPDATE=true

usage() {
    cat <<'EOF'
Usage: sudo bash setup.sh [--tools-root DIR] [--init-config] [--disable-auto-update]

Install program files below DIR/pto-task/app (default: /home/pypto-tools).
--init-config creates config/taskqueue.conf only when it does not already
exist.  The installer never starts services or changes queue state.
The daily idle-only update timer is enabled by default for root installations.
Use --disable-auto-update to opt out.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tools-root)
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "--tools-root needs a directory" >&2; exit 2; }
            TOOLS_ROOT="$2"; shift 2 ;;
        --init-config) INIT_CONFIG=true; shift ;;
        --enable-auto-update) ENABLE_AUTO_UPDATE=true; shift ;;
        --disable-auto-update) ENABLE_AUTO_UPDATE=false; shift ;;
        --bin-dir) # Test hook; production default is /usr/local/bin.
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "--bin-dir needs a directory" >&2; exit 2; }
            BIN_DIR="$2"; shift 2 ;;
        --sbin-dir) # Test hook for removing the former daemon alias.
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "--sbin-dir needs a directory" >&2; exit 2; }
            SBIN_DIR="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

TOOL_ROOT="${TOOLS_ROOT%/}/$TOOL_NAME"
APP_DIR="$TOOL_ROOT/app"
CONFIG_DIR="$TOOL_ROOT/config"
STATE_DIR="$TOOL_ROOT/state"
LOGS_DIR="$TOOL_ROOT/logs"
TMP_DIR="$TOOL_ROOT/tmp"
CONFIG_FILE="$CONFIG_DIR/taskqueue.conf"
SOURCE_UPDATE_REPOSITORY="$(git -C "$SCRIPT_DIR" config --get remote.origin.url 2>/dev/null || true)"
# Never copy embedded HTTP credentials into config or app files. SSH remotes do
# not contain a secret and continue to use the host's normal SSH credentials.
SOURCE_UPDATE_REPOSITORY="$(printf '%s' "$SOURCE_UPDATE_REPOSITORY" | sed -E 's#^(https?://)[^/@]+@#\1#')"

# Reinstalling copies only code. Create missing directories on first install,
# but do not even change modes of existing config or state directories.
ensure_dir() {
    local mode="$1" dir="$2"
    [[ -d "$dir" ]] || install -d -m "$mode" "$dir"
}
ensure_dir 755 "$APP_DIR"
ensure_dir 755 "$CONFIG_DIR"
ensure_dir 755 "$STATE_DIR"
ensure_dir 755 "$LOGS_DIR"
ensure_dir 755 "$TMP_DIR"
ensure_dir 1777 "$STATE_DIR/pending"
ensure_dir 1777 "$STATE_DIR/locks"
ensure_dir 1777 "$STATE_DIR/kill"
ensure_dir 1777 "$STATE_DIR/fifo"
ensure_dir 755 "$STATE_DIR/running"
ensure_dir 755 "$STATE_DIR/done"

# Root system units execute files from APP_DIR, so keep the installed code
# directories root-owned and non-writable by other users.
if [[ "$(id -u)" -eq 0 ]]; then
    [[ ! -L "$TOOL_ROOT" && ! -L "$APP_DIR" ]] || {
        echo "error: application directories must not be symlinks" >&2
        exit 1
    }
    chown root:root "$TOOL_ROOT" "$APP_DIR"
    chmod go-w "$TOOL_ROOT" "$APP_DIR"
fi
if [[ ! -e "$STATE_DIR/locks/update-reservation.lock" ]]; then
    install -m 666 /dev/null "$STATE_DIR/locks/update-reservation.lock"
fi
chmod 666 "$STATE_DIR/locks/update-reservation.lock"
if [[ "$(id -u)" -eq 0 ]]; then
    chown root:root "$STATE_DIR/locks/update-reservation.lock"
fi

install -m 755 "$SCRIPT_DIR/task-submit.sh" "$APP_DIR/task-submit"
install -m 755 "$SCRIPT_DIR/task-daemon.sh" "$APP_DIR/task-daemon"
install -m 755 "$SCRIPT_DIR/npu_lock.sh" "$APP_DIR/npu_lock.sh"
install -m 755 "$SCRIPT_DIR/pto-task-auto-update.sh" "$APP_DIR/pto-task-auto-update"
install -m 755 "$SCRIPT_DIR/pto-task-usage-sampler.sh" "$APP_DIR/pto-task-usage-sampler"
install -m 755 "$SCRIPT_DIR/pto-task-stats.sh" "$APP_DIR/pto-task-stats"
sed "s|/home/pypto-tools/pto-task/app|$APP_DIR|g" "$SCRIPT_DIR/pto-task.service" > "$APP_DIR/pto-task.service"
chmod 644 "$APP_DIR/pto-task.service"
sed "s|/home/pypto-tools/pto-task/app|$APP_DIR|g" "$SCRIPT_DIR/pto-task-auto-update.service" > "$APP_DIR/pto-task-auto-update.service"
chmod 644 "$APP_DIR/pto-task-auto-update.service"
install -m 644 "$SCRIPT_DIR/pto-task-auto-update.timer" "$APP_DIR/pto-task-auto-update.timer"
sed "s|/home/pypto-tools/pto-task/app|$APP_DIR|g" "$SCRIPT_DIR/pto-task-usage-sampler.service" > "$APP_DIR/pto-task-usage-sampler.service"
chmod 644 "$APP_DIR/pto-task-usage-sampler.service"
install -m 644 "$SCRIPT_DIR/pto-task-usage-sampler.timer" "$APP_DIR/pto-task-usage-sampler.timer"
sed "s|/usr/local/bin/task-submit|$BIN_DIR/task-submit|g" "$SCRIPT_DIR/pto-task-clean.cron" > "$APP_DIR/pto-task-clean.cron"
chmod 644 "$APP_DIR/pto-task-clean.cron"
git -C "$SCRIPT_DIR" rev-parse HEAD > "$APP_DIR/.pto-task-release" 2>/dev/null || :
printf '%s\n' "$SOURCE_UPDATE_REPOSITORY" > "$APP_DIR/.pto-task-update-repository"
chmod 600 "$APP_DIR/.pto-task-update-repository"
printf 'BIN_DIR=%q\nSBIN_DIR=%q\n' "$BIN_DIR" "$SBIN_DIR" > "$APP_DIR/.pto-task-install-options"
chmod 600 "$APP_DIR/.pto-task-install-options"

if [[ "$INIT_CONFIG" == true && ! -e "$CONFIG_FILE" ]]; then
    umask 077
    {
        printf '# Local taskqueue configuration. Preserved by setup.sh updates.\n'
        printf 'STATE_DIR="%s" # 队列持久状态目录\n' "$STATE_DIR"
        printf 'LOGS_DIR="%s" # 任务与 daemon 日志目录\n' "$LOGS_DIR"
        sed -n '/^MAX_CONCURRENT=/,$p' "$SCRIPT_DIR/config/default.conf" |
            sed '/^AUTO_UPDATE_REPOSITORY=/d'
        if [[ -n "$SOURCE_UPDATE_REPOSITORY" ]]; then
            printf 'AUTO_UPDATE_REPOSITORY=%q # 自动更新远端（由安装时 Git origin 自动识别）\n' "$SOURCE_UPDATE_REPOSITORY"
        fi
    } > "$CONFIG_FILE"
    # Clients source this non-secret queue configuration before submitting a
    # task, so every local user needs read access.  Credentials must never be
    # stored here.
    chmod 644 "$CONFIG_FILE"
fi

# A root daemon sources this file as shell code. Refuse symlinks and enforce
# administrator-only write access before installing system units.
if [[ "$(id -u)" -eq 0 && -e "$CONFIG_FILE" ]]; then
    [[ ! -L "$CONFIG_DIR" && ! -L "$CONFIG_FILE" ]] || {
        echo "error: configuration directory and file must not be symlinks" >&2
        exit 1
    }
    chown root:root "$CONFIG_DIR" "$CONFIG_FILE"
    chmod go-w "$CONFIG_DIR" "$CONFIG_FILE"
fi

ensure_dir 755 "$BIN_DIR"
ln -sfn "$APP_DIR/task-submit" "$BIN_DIR/task-submit"
ln -sfn "$APP_DIR/task-submit" "$BIN_DIR/pto-task"

# Remove only retired auxiliary aliases. task-submit remains a supported user
# command for compatibility, alongside pto-task.
for legacy in "$BIN_DIR/npu-lock" "$BIN_DIR/pto-taskqueue" "$SBIN_DIR/task-daemon"; do
    [[ ! -e "$legacy" && ! -L "$legacy" ]] || rm -f "$legacy"
done

printf 'Installed application: %s\n' "$APP_DIR"
printf 'User commands: %s/task-submit and %s/pto-task -> %s/task-submit\n' "$BIN_DIR" "$BIN_DIR" "$APP_DIR"
if [[ -f "$CONFIG_FILE" ]]; then
    printf 'Configuration: %s (preserved)\n' "$CONFIG_FILE"
else
    printf 'Configuration not initialized; rerun with --init-config when ready.\n'
fi
services_started=false
if [[ -f "$CONFIG_FILE" && "$(id -u)" -eq 0 ]]; then
    usage_sampling_enabled="$(bash -c 'source "$1"; printf "%s" "${USAGE_SAMPLING_ENABLED:-false}"' _ "$CONFIG_FILE")"
    install -d -m 755 /etc/systemd/system
    ln -sfn "$APP_DIR/pto-task.service" /etc/systemd/system/pto-task.service
    if [[ "$ENABLE_AUTO_UPDATE" == true ]]; then
        ln -sfn "$APP_DIR/pto-task-auto-update.service" /etc/systemd/system/pto-task-auto-update.service
        ln -sfn "$APP_DIR/pto-task-auto-update.timer" /etc/systemd/system/pto-task-auto-update.timer
    else
        systemctl disable --now pto-task-auto-update.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/pto-task-auto-update.service /etc/systemd/system/pto-task-auto-update.timer
    fi
    case "$usage_sampling_enabled" in
        1|true|TRUE|yes|YES|on|ON)
            ln -sfn "$APP_DIR/pto-task-usage-sampler.service" /etc/systemd/system/pto-task-usage-sampler.service
            ln -sfn "$APP_DIR/pto-task-usage-sampler.timer" /etc/systemd/system/pto-task-usage-sampler.timer
            ;;
        *)
            systemctl disable --now pto-task-usage-sampler.timer >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/pto-task-usage-sampler.service /etc/systemd/system/pto-task-usage-sampler.timer
            ;;
    esac
    systemctl daemon-reload
    if [[ "$ENABLE_AUTO_UPDATE" == true ]]; then
        systemctl enable --now pto-task-auto-update.timer
        services_started=true
        printf 'Automatic update timer enabled.\n'
    fi
    case "$usage_sampling_enabled" in
        1|true|TRUE|yes|YES|on|ON)
            systemctl enable --now pto-task-usage-sampler.timer
            services_started=true
            printf 'Usage sampling timer enabled.\n'
            ;;
        *) printf 'Usage sampling timer not enabled (USAGE_SAMPLING_ENABLED is false).\n' ;;
    esac
elif [[ "$ENABLE_AUTO_UPDATE" == true ]]; then
    printf 'Automatic update timer not enabled (requires root and initialized config).\n'
fi
if [[ "$services_started" == true ]]; then
    printf 'The task daemon was not started or restarted.\n'
else
    printf 'No daemon or service was started.\n'
fi
