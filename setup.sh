#!/usr/bin/env bash
# Install the task queue without starting or restarting the main daemon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_ROOT="/home/pypto-tools"
TOOL_NAME="pto-task"
INIT_CONFIG=true
BIN_DIR="/usr/local/bin"
SBIN_DIR="/usr/local/sbin"
ENABLE_AUTO_UPDATE=true
MAX_CONCURRENT_OVERRIDE=""
MAX_TIME_HARD_CAP_OVERRIDE=""
AVAILABLE_DEVICES_OVERRIDE=""
AVAILABLE_DEVICES_SET=false
TASK_EXECUTION_MODE_OVERRIDE=""
PTOAS_BASE_OVERRIDE=""
INTERACTIVE_CONFIG="auto"

usage() {
    cat <<'EOF'
Usage: sudo bash setup.sh [OPTIONS]

Install program files below DIR/pto-task/app (default: /home/pypto-tools) and
create config/taskqueue.conf when it is missing. Existing configuration and
queue state are preserved unless a configuration option below is explicitly
passed. The installer never starts the main daemon.
The daily idle-only update timer is enabled by default for root installations.
Use --disable-auto-update to opt out.

  --tools-root DIR             Installation parent directory
  --no-init-config             Do not create a missing configuration
  --max-concurrent N           Set maximum simultaneously running jobs
  --max-time-hard-cap SECONDS  Set server-side task duration cap (0 = unlimited)
  --available-devices LIST     Set the auto-allocation pool (for example 0,1,2,3)
  --task-execution-mode MODE   HwHiAiUser or root
  --ptoas-base DIR             Root containing installed PTOAS versions
  --interactive-config        Prompt for first-install host settings
  --non-interactive           Never prompt; use options/detected defaults
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tools-root)
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "--tools-root needs a directory" >&2; exit 2; }
            TOOLS_ROOT="$2"; shift 2 ;;
        --init-config) INIT_CONFIG=true; shift ;; # Kept for compatibility.
        --no-init-config) INIT_CONFIG=false; shift ;;
        --max-concurrent)
            [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "--max-concurrent needs a positive integer" >&2; exit 2; }
            MAX_CONCURRENT_OVERRIDE="$2"; shift 2 ;;
        --max-time-hard-cap)
            [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "--max-time-hard-cap needs a non-negative integer" >&2; exit 2; }
            MAX_TIME_HARD_CAP_OVERRIDE="$2"; shift 2 ;;
        --available-devices)
            [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "--available-devices needs a comma-separated list or auto" >&2; exit 2; }
            if [[ "$2" == auto ]]; then
                AVAILABLE_DEVICES_OVERRIDE=""
            elif [[ "$2" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                AVAILABLE_DEVICES_OVERRIDE="$2"
            else
                echo "--available-devices must be auto or comma-separated device numbers" >&2
                exit 2
            fi
            AVAILABLE_DEVICES_SET=true; shift 2 ;;
        --task-execution-mode)
            [[ "${2:-}" == HwHiAiUser || "${2:-}" == root ]] || { echo "--task-execution-mode must be HwHiAiUser or root" >&2; exit 2; }
            TASK_EXECUTION_MODE_OVERRIDE="$2"; shift 2 ;;
        --ptoas-base)
            [[ "${2:-}" == /* ]] || { echo "--ptoas-base needs an absolute path" >&2; exit 2; }
            PTOAS_BASE_OVERRIDE="${2%/}"; shift 2 ;;
        --interactive-config) INTERACTIVE_CONFIG=true; shift ;;
        --non-interactive) INTERACTIVE_CONFIG=false; shift ;;
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
SOURCE_UPDATE_REPOSITORY="https://github.com/pypto-tools/npu-taskqueue.git"
LEGACY_CONFIG_FILE="/etc/taskqueue.conf"

# Read the simple KEY=value format used by the former /etc/taskqueue.conf
# without sourcing shell code as root.
read_simple_config_key() {
    local key="$1" file="$2" line value
    [[ -f "$file" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == "$key="* ]] || continue
        value="${line#*=}"
        value="${value%%[[:space:]]#*}"
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"
        printf '%s' "$value"
        return 0
    done < "$file"
    return 1
}

set_config_value() {
    local key="$1" value="$2" rendered tmp
    printf -v rendered '%s=%q' "$key" "$value"
    tmp="$(mktemp "$CONFIG_DIR/.taskqueue.conf.XXXXXX")"
    CONFIG_KEY="$key" CONFIG_RENDERED="$rendered" awk '
        BEGIN { key = ENVIRON["CONFIG_KEY"]; rendered = ENVIRON["CONFIG_RENDERED"] }
        index($0, key "=") == 1 { if (!seen++) print rendered; next }
        { print }
        END { if (!seen) print rendered }
    ' "$CONFIG_FILE" > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

detect_device_count() {
    local count=0
    local devices=(/dev/davinci[0-9]*)
    if [[ -e "${devices[0]}" ]]; then
        count="${#devices[@]}"
    elif command -v npu-smi >/dev/null 2>&1; then
        count="$(timeout 5 npu-smi info -l 2>/dev/null | grep -c 'NPU ID' || true)"
    fi
    [[ "$count" =~ ^[1-9][0-9]*$ ]] || count=0
    printf '%s' "$count"
}

device_list_for_count() {
    local count="$1" id list=""
    for ((id = 0; id < count; id++)); do
        list+="${list:+,}$id"
    done
    printf '%s' "$list"
}

prompt_initial_config() {
    local detected_count card_default card_count concurrency_default answer
    detected_count="$(detect_device_count)"
    card_default="$detected_count"
    [[ "$card_default" -gt 0 ]] || card_default=0

    printf '\n首次部署配置（直接回车使用方括号内的值）\n' >&2
    if [[ "$AVAILABLE_DEVICES_SET" == false ]]; then
        if (( card_default > 0 )); then
            read -r -p "NPU 卡数量，卡号按 0..N-1 配置 [$card_default]: " answer
        else
            read -r -p 'NPU 卡数量（0 表示运行时自动探测） [0]: ' answer
        fi
        card_count="${answer:-$card_default}"
        [[ "$card_count" =~ ^[0-9]+$ ]] || {
            echo "error: NPU 卡数量必须是非负整数" >&2
            exit 2
        }
        if (( card_count > 0 )); then
            AVAILABLE_DEVICES_OVERRIDE="$(device_list_for_count "$card_count")"
            AVAILABLE_DEVICES_SET=true
        fi
    else
        card_count="$(awk -F, '{ print NF }' <<< "$AVAILABLE_DEVICES_OVERRIDE")"
    fi

    if [[ -z "$MAX_CONCURRENT_OVERRIDE" ]]; then
        concurrency_default="${card_count:-0}"
        (( concurrency_default > 0 )) || concurrency_default=10
        read -r -p "最大并发任务数 [$concurrency_default]: " answer
        MAX_CONCURRENT_OVERRIDE="${answer:-$concurrency_default}"
        [[ "$MAX_CONCURRENT_OVERRIDE" =~ ^[1-9][0-9]*$ ]] || {
            echo "error: 最大并发任务数必须是正整数" >&2
            exit 2
        }
    fi
    printf '\n' >&2
}

# Reinstalling normally preserves local data and modes. The four client-facing
# state directories are an exception: their sticky, world-writable mode is a
# runtime requirement, so repair it on every install (including migrations
# from older releases that created them with the caller's umask).
ensure_dir() {
    local mode="$1" dir="$2"
    [[ -d "$dir" ]] || install -d -m "$mode" "$dir"
}

prepare_state_layout() {
    local state_dir="$1" lock_file unsafe_lock
    [[ "$state_dir" == /* && "$state_dir" != / ]] || {
        echo "error: STATE_DIR must be an absolute directory other than /" >&2
        exit 1
    }
    ensure_dir 755 "$state_dir"
    ensure_dir 1777 "$state_dir/pending"
    ensure_dir 1777 "$state_dir/locks"
    ensure_dir 1777 "$state_dir/kill"
    ensure_dir 1777 "$state_dir/fifo"
    ensure_dir 755 "$state_dir/running"
    ensure_dir 755 "$state_dir/done"
    ensure_dir 755 "$state_dir/usage"
    chmod 1777 "$state_dir/pending" "$state_dir/locks" "$state_dir/kill" "$state_dir/fifo"

    lock_file="$state_dir/locks/update-reservation.lock"
    if [[ ! -e "$lock_file" ]]; then
        [[ ! -L "$lock_file" ]] || {
            echo "error: update reservation lock must not be a symlink" >&2
            exit 1
        }
        install -m 666 /dev/null "$lock_file"
    fi
    if [[ -L "$lock_file" || ! -f "$lock_file" ||
          "$(stat -c %h "$lock_file" 2>/dev/null || true)" != 1 ]]; then
        echo "error: update reservation lock must be a regular file with one link" >&2
        exit 1
    fi
    chmod 666 "$lock_file"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown root:root "$lock_file"
    fi

    # Device locks are intentionally persistent. Older versions could leave a
    # user-owned 0600/0644 file behind, preventing the next submitter from
    # opening the same device lock. Refuse links instead of changing metadata
    # through an attacker-controlled name.
    unsafe_lock="$(find "$state_dir/locks" -maxdepth 1 -name 'npu_device_*.lock' \
        ! \( -type f -links 1 \) -print -quit)"
    if [[ -n "$unsafe_lock" ]]; then
        echo "error: device lock must be a regular file with one link: $unsafe_lock" >&2
        exit 1
    fi
    find "$state_dir/locks" -maxdepth 1 -type f -links 1 -name 'npu_device_*.lock' \
        -exec chmod 666 {} +
    if [[ "$(id -u)" -eq 0 ]]; then
        find "$state_dir/locks" -maxdepth 1 -type f -links 1 -name 'npu_device_*.lock' \
            -exec chown root:root {} +
    fi
}

precreate_device_locks() {
    local state_dir="$1" configured_devices="$2" count id lock_file
    local -a device_ids=()
    if [[ -n "$configured_devices" ]]; then
        IFS=',' read -r -a device_ids <<< "$configured_devices"
    else
        count="$(detect_device_count)"
        for ((id = 0; id < count; id++)); do
            device_ids+=("$id")
        done
    fi

    for id in "${device_ids[@]}"; do
        [[ "$id" =~ ^[0-9]+$ ]] || {
            echo "error: invalid device id in AVAILABLE_DEVICES: $id" >&2
            exit 2
        }
        lock_file="$state_dir/locks/npu_device_${id}.lock"
        if [[ ! -e "$lock_file" ]]; then
            [[ ! -L "$lock_file" ]] || {
                echo "error: device lock must not be a symlink: $lock_file" >&2
                exit 1
            }
            install -m 666 /dev/null "$lock_file"
        fi
        if [[ -L "$lock_file" || ! -f "$lock_file" ||
              "$(stat -c %h "$lock_file" 2>/dev/null || true)" != 1 ]]; then
            echo "error: device lock must be a regular file with one link: $lock_file" >&2
            exit 1
        fi
        chmod 666 "$lock_file"
        if [[ "$(id -u)" -eq 0 ]]; then
            chown root:root "$lock_file"
        fi
    done
}

if [[ "$INIT_CONFIG" == true && ! -e "$CONFIG_FILE" ]]; then
    if [[ "$INTERACTIVE_CONFIG" == true ||
          ("$INTERACTIVE_CONFIG" == auto && -t 0) ]]; then
        prompt_initial_config
    fi
fi

ensure_dir 755 "$APP_DIR"
ensure_dir 755 "$CONFIG_DIR"
ensure_dir 755 "$LOGS_DIR"
ensure_dir 755 "$TMP_DIR"
prepare_state_layout "$STATE_DIR"

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
# setup.sh deliberately does not restart the daemon. Leave a persistent marker
# so deploy.sh or the idle-only updater can activate these files safely. This
# also bridges upgrades initiated by an older updater that did not restart.
: > "$APP_DIR/.pto-task-restart-required"
chmod 600 "$APP_DIR/.pto-task-restart-required"
printf '%s\n' "$SOURCE_UPDATE_REPOSITORY" > "$APP_DIR/.pto-task-update-repository"
chmod 600 "$APP_DIR/.pto-task-update-repository"
printf 'BIN_DIR=%q\nSBIN_DIR=%q\n' "$BIN_DIR" "$SBIN_DIR" > "$APP_DIR/.pto-task-install-options"
chmod 600 "$APP_DIR/.pto-task-install-options"

if [[ "$INIT_CONFIG" == true && ! -e "$CONFIG_FILE" ]]; then
    initial_state_dir="$STATE_DIR"
    initial_logs_dir="$LOGS_DIR"
    legacy_max_concurrent=""
    if [[ "$(id -u)" -eq 0 && -f "$LEGACY_CONFIG_FILE" ]]; then
        legacy_config_safe=true
        if [[ -L "$LEGACY_CONFIG_FILE" ]] ||
           [[ "$(stat -c %u "$LEGACY_CONFIG_FILE")" -ne 0 ]] ||
           [[ $((8#$(stat -c %a "$LEGACY_CONFIG_FILE") & 8#022)) -ne 0 ]]; then
            legacy_config_safe=false
            printf 'Warning: ignored unsafe legacy configuration: %s\n' "$LEGACY_CONFIG_FILE" >&2
        fi
        if [[ "$legacy_config_safe" == true ]]; then
            legacy_base_dir="$(read_simple_config_key BASE_DIR "$LEGACY_CONFIG_FILE" || true)"
            if [[ "$legacy_base_dir" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
                initial_state_dir="${legacy_base_dir%/}"
                initial_logs_dir="${legacy_base_dir%/}/logs"
                legacy_max_concurrent="$(read_simple_config_key MAX_CONCURRENT "$LEGACY_CONFIG_FILE" || true)"
                printf 'Importing legacy queue state from: %s\n' "$initial_state_dir"
            fi
        fi
    fi
    umask 077
    {
        printf '# Local taskqueue configuration. Preserved by setup.sh updates.\n'
        printf 'STATE_DIR=%q # 队列持久状态目录\n' "$initial_state_dir"
        printf 'LOGS_DIR=%q # 任务与 daemon 日志目录\n' "$initial_logs_dir"
        sed -n '/^MAX_CONCURRENT=/,$p' "$SCRIPT_DIR/config/default.conf" |
            sed '/^AUTO_UPDATE_REPOSITORY=/d'
        if [[ -n "$SOURCE_UPDATE_REPOSITORY" ]]; then
            printf 'AUTO_UPDATE_REPOSITORY=%q # 自动更新远端（官方仓库）\n' "$SOURCE_UPDATE_REPOSITORY"
        fi
    } > "$CONFIG_FILE"
    # Clients source this non-secret queue configuration before submitting a
    # task, so every local user needs read access.  Credentials must never be
    # stored here.
    chmod 644 "$CONFIG_FILE"
    if [[ "$legacy_max_concurrent" =~ ^[1-9][0-9]*$ ]]; then
        set_config_value MAX_CONCURRENT "$legacy_max_concurrent"
    fi
fi

# A root daemon sources this file as shell code. Refuse symlinks and enforce
# administrator-only write access before editing it or installing system units.
if [[ "$(id -u)" -eq 0 && -e "$CONFIG_FILE" ]]; then
    [[ ! -L "$CONFIG_DIR" && ! -L "$CONFIG_FILE" ]] || {
        echo "error: configuration directory and file must not be symlinks" >&2
        exit 1
    }
    chown root:root "$CONFIG_DIR" "$CONFIG_FILE"
    chmod go-w "$CONFIG_DIR" "$CONFIG_FILE"
fi

if [[ -f "$CONFIG_FILE" ]]; then
    [[ -z "$MAX_CONCURRENT_OVERRIDE" ]] || set_config_value MAX_CONCURRENT "$MAX_CONCURRENT_OVERRIDE"
    [[ -z "$MAX_TIME_HARD_CAP_OVERRIDE" ]] || set_config_value MAX_TIME_HARD_CAP "$MAX_TIME_HARD_CAP_OVERRIDE"
    [[ "$AVAILABLE_DEVICES_SET" == false ]] || set_config_value AVAILABLE_DEVICES "$AVAILABLE_DEVICES_OVERRIDE"
    [[ -z "$TASK_EXECUTION_MODE_OVERRIDE" ]] || set_config_value TASK_EXECUTION_MODE "$TASK_EXECUTION_MODE_OVERRIDE"
    [[ -z "$PTOAS_BASE_OVERRIDE" ]] || set_config_value PTOAS_BASE "$PTOAS_BASE_OVERRIDE"
fi

# The unified installation tree is always created above. If an existing or
# migrated configuration deliberately points at a legacy state/log location,
# create and repair that active runtime layout as well.
if [[ -f "$CONFIG_FILE" ]]; then
    mapfile -t configured_paths < <(bash -c '
        source "$1"
        active_state="${STATE_DIR:-${BASE_DIR:-$2}}"
        active_logs="${LOGS_DIR:-${active_state%/state}/logs}"
        printf "%s\n%s\n%s\n" "$active_state" "$active_logs" "${AVAILABLE_DEVICES:-}"
    ' _ "$CONFIG_FILE" "$STATE_DIR")
    configured_state_dir="${configured_paths[0]:-$STATE_DIR}"
    configured_logs_dir="${configured_paths[1]:-$LOGS_DIR}"
    configured_devices="${configured_paths[2]:-}"
    prepare_state_layout "$configured_state_dir"
    [[ "$configured_logs_dir" == /* && "$configured_logs_dir" != / ]] || {
        echo "error: LOGS_DIR must be an absolute directory other than /" >&2
        exit 1
    }
    ensure_dir 755 "$configured_logs_dir"
    precreate_device_locks "$configured_state_dir" "$configured_devices"
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
    printf 'Configuration not initialized; rerun setup.sh without --no-init-config.\n'
fi
services_started=false
if [[ -f "$CONFIG_FILE" && "$(id -u)" -eq 0 ]]; then
    usage_sampling_enabled="$(bash -c 'source "$1"; printf "%s" "${USAGE_SAMPLING_ENABLED:-false}"' _ "$CONFIG_FILE")"
    install -d -m 755 /etc/systemd/system
    ln -sfn "$APP_DIR/pto-task.service" /etc/systemd/system/pto-task.service
    # Keep the historical service name as a systemd alias during migration.
    ln -sfn "$APP_DIR/pto-task.service" /etc/systemd/system/taskqueue.service
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
