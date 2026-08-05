#!/bin/bash
# npu-lock — NPU 设备互斥锁
# 作为 app/ 内部组件由 task-daemon 调用，不公开安装。
#
# 用法:
#   npu-lock <device_id> -- <command...>       锁卡执行（支持逗号分隔多卡: 0,1）
#   npu-lock <device_id> -- "cmd1 && cmd2"     锁卡执行复合命令（引号包裹）
#   npu-lock <device_id> -c "cmd1 && cmd2"     锁卡执行复合命令（等价写法）
#   npu-lock <device_id> --timeout 60 -- cmd   自定义超时
#   npu-lock <device_id>                       锁卡进子 shell，exit 释放
#   npu-lock --status                          查看所有设备锁状态

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -n "${TASKQUEUE_LOCK_STATE_DIR:-}" ]]; then
    # The daemon appends this trusted value after the submitted environment.
    # Do not source a submitter-controlled TASKQUEUE_CONF in queued workloads.
    STATE_DIR="$TASKQUEUE_LOCK_STATE_DIR"
else
    if [[ -n "${TASKQUEUE_CONF:-}" ]]; then
        CONF_FILE="$TASKQUEUE_CONF"
    elif [[ -f "$SCRIPT_DIR/../config/taskqueue.conf" ]]; then
        CONF_FILE="$SCRIPT_DIR/../config/taskqueue.conf"
    else
        CONF_FILE="$SCRIPT_DIR/runtime/config/taskqueue.conf"
    fi
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
    STATE_DIR="${STATE_DIR:-${BASE_DIR:-}}"
    if [[ -z "$STATE_DIR" ]]; then
        if [[ -f "$SCRIPT_DIR/../config/taskqueue.conf" ]]; then STATE_DIR="$SCRIPT_DIR/../state"; else STATE_DIR="$SCRIPT_DIR/runtime/state"; fi
    fi
fi
LOCK_DIR="$STATE_DIR/locks"

# 颜色（仅终端）
if [[ -t 2 ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_RED="" C_GREEN="" C_YELLOW="" C_DIM="" C_RESET=""
fi

# 自动发现 NPU 设备数量
detect_device_count() {
    local count=0
    # 优先通过 npu-smi 获取
    if command -v npu-smi &>/dev/null; then
        count=$(npu-smi info -l 2>/dev/null | grep -c "NPU ID" || true)
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    # 回退到 /dev/davinci* 设备文件
    if [[ $count -eq 0 ]]; then
        count=$(ls -1 /dev/davinci[0-9]* 2>/dev/null | wc -l)
    fi
    # 兜底：至少 2 个设备
    [[ $count -lt 1 ]] && count=2
    echo "$count"
}

show_status() {
    local num_devices
    num_devices=$(detect_device_count)
    echo "NPU 设备锁状态 (共 ${num_devices} 个设备):"
    echo ""
    for ((id=0; id<num_devices; id++)); do
        local f="${LOCK_DIR}/npu_device_${id}.lock"
        if [[ ! -f "$f" ]]; then
            echo "  设备 ${id}: ${C_GREEN}空闲${C_RESET} (无锁文件)"
            continue
        fi
        local pid
        pid=$(grep -oP 'pid=\K[0-9]+' "$f" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            local info
            info=$(cat "$f")
            echo "  设备 ${id}: ${C_RED}已锁${C_RESET} ($info)"
        else
            echo "  设备 ${id}: ${C_GREEN}空闲${C_RESET}"
        fi
    done
}

# 校验 device_id 为非负整数
validate_device_id() {
    local id="$1"
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        echo "${C_RED}错误: 无效的 device_id '$id'，必须为非负整数${C_RESET}" >&2
        exit 1
    fi
}

device_ids_raw=""
timeout=600
cmd=()
cmd_string=""

# 从 cmd 数组构建 bash -c 命令字符串
# 单参数: 直接传递（支持 && || ; 等 shell 语法）
# 多参数: 用 printf '%q' 安全拼接（保留含空格的参数边界）
build_cmd_string() {
    if [[ ${#cmd[@]} -eq 1 ]]; then
        echo "${cmd[0]}"
    else
        local quoted=""
        for arg in "${cmd[@]}"; do
            quoted+="$(printf '%q' "$arg") "
        done
        echo "$quoted"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout|-t) timeout="$2"; shift 2 ;;
        --status)     show_status; exit 0 ;;
        -c)           cmd_string="$2"; shift 2 ;;
        --)           shift; cmd=("$@"); break ;;
        --help|-h)
            cat <<'EOF'
npu-lock — NPU 设备互斥锁

用法:
  npu-lock <device_id> -- <command...>       锁定设备后执行命令
  npu-lock <device_id> -- "cmd1 && cmd2"     锁定设备后执行复合命令（引号包裹）
  npu-lock <device_id> -c "cmd1 && cmd2"     锁定设备后执行复合命令（等价写法）
  npu-lock <device_id> --timeout 60 -- cmd   自定义锁等待超时(秒，默认 600)
  npu-lock <device_id>                       锁定设备并进入子 shell，exit 释放
  npu-lock --status                          查看所有设备锁状态

  device_id 支持逗号分隔的多卡: npu-lock 0,1 -- command
  多卡按编号升序加锁，避免死锁。

原理:
  使用 flock 对 $LOCK_DIR/npu_device_N.lock 加排他锁。
  同一时刻只有一个进程能持有某设备的锁，其他进程排队等待。
  进程退出后锁自动释放（即使异常退出）。

示例:
  # 锁定设备 0 执行 Python 脚本
  npu-lock 0 -- python run_example.py -p a5 -d 0

  # 锁定设备 0 执行复合命令（用引号包裹，-- 和 -c 等价）
  npu-lock 0 -- "export FOO=bar && python run_example.py -p a5 -d 0"
  npu-lock 0 -c "export FOO=bar && python run_example.py -p a5 -d 0"

  # 同时锁定设备 0 和 1
  npu-lock 0,1 -- python train.py --devices 0,1

  # 交互式：锁定设备 1，在子 shell 里操作，exit 释放
  npu-lock 1
  # ... 操作 NPU 设备 ...
  exit

  # 配合 task-submit 使用（提权 + 锁卡）
  task-submit --device 0 --run "python train.py"
EOF
            exit 0
            ;;
        *)
            if [[ -z "$device_ids_raw" ]]; then
                device_ids_raw="$1"
            else
                echo "${C_RED}错误: 未知参数 '$1'，命令放在 -- 后面${C_RESET}" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$device_ids_raw" ]]; then
    echo "${C_RED}错误: 需要指定 device_id${C_RESET}" >&2
    echo "用法: npu-lock <device_id>[,<device_id>...] [--timeout N] [-c \"cmd\" | -- <command...>]" >&2
    exit 1
fi

if [[ -n "$cmd_string" && ${#cmd[@]} -gt 0 ]]; then
    echo "${C_RED}错误: -c 和 -- 不能同时使用${C_RESET}" >&2
    exit 1
fi

# 解析逗号分隔的设备列表，校验并按升序排序（防死锁）
IFS=',' read -ra raw_ids <<< "$device_ids_raw"
for id in "${raw_ids[@]}"; do
    validate_device_id "$id"
done
sorted_ids=($(printf '%s\n' "${raw_ids[@]}" | sort -n -u))

# 确保锁目录存在
mkdir -p "$LOCK_DIR" 2>/dev/null

# 重入检测：过滤掉父进程已锁的设备
need_lock=()
IFS=',' read -ra already_locked <<< "${NPU_LOCKED_DEVICE:-}"
for dev in "${sorted_ids[@]}"; do
    skip=false
    for locked in "${already_locked[@]}"; do
        if [[ "$dev" == "$locked" ]]; then
            skip=true
            break
        fi
    done
    if $skip; then
        echo "${C_DIM}[npu-lock] 设备 ${dev} 已被父进程锁定，跳过${C_RESET}" >&2
    else
        need_lock+=("$dev")
    fi
done

# 锁序校验：新锁的设备号必须都大于已持有的，否则嵌套调用可能死锁
if [[ ${#already_locked[@]} -gt 0 && ${#need_lock[@]} -gt 0 ]]; then
    max_locked=0
    for locked in "${already_locked[@]}"; do
        [[ -n "$locked" ]] && (( locked > max_locked )) && max_locked=$locked
    done
    for dev in "${need_lock[@]}"; do
        if (( dev < max_locked )); then
            echo "${C_RED}[npu-lock] 错误: 设备 ${dev} < 已锁设备 ${max_locked}，违反锁序（会死锁）${C_RESET}" >&2
            echo "${C_YELLOW}[npu-lock] 请改用: npu-lock ${already_locked[*]},${need_lock[*]} -- <command>${C_RESET}" >&2
            exit 1
        fi
    done
fi

# 所有设备都已锁定，直接执行
if [[ ${#need_lock[@]} -eq 0 ]]; then
    if [[ -n "$cmd_string" ]]; then
        bash -c "$cmd_string"
        exit $?
    elif [[ ${#cmd[@]} -gt 0 ]]; then
        bash -c "$(build_cmd_string)"
        exit $?
    else
        NPU_LOCKED_DEVICE="${sorted_ids[*]}" bash
        exit $?
    fi
fi

# 按升序依次加锁
lock_fds=()
for dev in "${need_lock[@]}"; do
    lock_file="${LOCK_DIR}/npu_device_${dev}.lock"
    if [[ -L "$lock_file" ]]; then
        echo "${C_RED}[npu-lock] 错误: 锁文件不能是符号链接: $lock_file${C_RESET}" >&2
        exit 1
    fi

    # O_CREAT applies the mode after umask atomically. This removes the window
    # where another user could observe a newly-created 0600 lock before a
    # follow-up chmod. Append mode also avoids truncating the holder metadata
    # before this process has actually acquired flock.
    previous_umask=$(umask)
    umask 000
    exec {fd}>>"$lock_file"
    open_rc=$?
    umask "$previous_umask"
    if (( open_rc != 0 )); then
        echo "${C_RED}[npu-lock] 错误: 无法打开共享锁 $lock_file${C_RESET}" >&2
        echo "${C_DIM}[npu-lock] 请管理员重新执行 sudo bash deploy.sh 修复历史锁权限${C_RESET}" >&2
        for prev_fd in "${lock_fds[@]}"; do
            exec {prev_fd}>&-
        done
        exit 1
    fi
    chmod 666 "$lock_file" 2>/dev/null || true

    if [[ $timeout -eq 0 ]]; then
        echo "${C_DIM}[npu-lock] 获取设备 ${dev} 的锁 (无超时)...${C_RESET}" >&2
        flock "$fd"
    else
        echo "${C_DIM}[npu-lock] 获取设备 ${dev} 的锁 (timeout=${timeout}s)...${C_RESET}" >&2
        if ! flock -w "$timeout" "$fd" 2>/dev/null; then
            echo "${C_RED}[npu-lock] 超时: 设备 ${dev} 被占用 (等待 ${timeout}s)${C_RESET}" >&2
            holder=$(cat "$lock_file" 2>/dev/null)
            [[ -n "$holder" ]] && echo "${C_DIM}[npu-lock] 当前持有者: $holder${C_RESET}" >&2
            # 释放已获取的锁
            for prev_fd in "${lock_fds[@]}"; do
                exec {prev_fd}>&-
            done
            exec {fd}>&-
            exit 1
        fi
    fi

    # Replace stale metadata only after flock succeeds. /proc/self/fd keeps the
    # write tied to the inode we locked instead of resolving the path again.
    printf 'pid=%s user=%s time=%s\n' "$$" "$(whoami)" "$(date -Iseconds)" \
        > "/proc/self/fd/$fd"
    echo "${C_GREEN}[npu-lock] 已获取设备 ${dev} 的锁 (pid=$$)${C_RESET}" >&2
    lock_fds+=("$fd")
done

# 导出已锁设备列表（合并父进程已锁 + 本次新锁）
all_locked=("${already_locked[@]}" "${need_lock[@]}")
export NPU_LOCKED_DEVICE=$(IFS=','; echo "${all_locked[*]}")

# workload 不能继承锁 fd。否则它派生出的后台进程可能在 npu-lock 退出后继续持锁，
# 表现为设备已空闲但永远无法重新分配。父 npu-lock 仍持有 fd，锁语义不变。
spawn_without_lock_fds() {
    (
        local fd
        for fd in "${lock_fds[@]}"; do
            exec {fd}>&-
        done
        exec "$@"
    ) &
}

# 信号处理：转发给子进程并清理
child_pid=""
cleanup() {
    if [[ -n "$child_pid" ]]; then
        kill -TERM "$child_pid" 2>/dev/null
        wait "$child_pid" 2>/dev/null
    fi
    for fd in "${lock_fds[@]}"; do
        exec {fd}>&-
    done
    echo "${C_DIM}[npu-lock] 已释放设备 ${need_lock[*]} 的锁${C_RESET}" >&2
    exit 130
}
trap cleanup SIGINT SIGTERM

exit_code=0
if [[ -n "$cmd_string" ]]; then
    spawn_without_lock_fds bash -c "$cmd_string"
    child_pid=$!
    while wait "$child_pid" 2>/dev/null; ret=$?; do break; done
    # wait 可能被信号中断，循环确保子进程真正退出后才继续
    while kill -0 "$child_pid" 2>/dev/null; do wait "$child_pid" 2>/dev/null; done
    exit_code=${ret:-$?}
    child_pid=""
elif [[ ${#cmd[@]} -gt 0 ]]; then
    spawn_without_lock_fds bash -c "$(build_cmd_string)"
    child_pid=$!
    while wait "$child_pid" 2>/dev/null; ret=$?; do break; done
    while kill -0 "$child_pid" 2>/dev/null; do wait "$child_pid" 2>/dev/null; done
    exit_code=${ret:-$?}
    child_pid=""
else
    echo "[npu-lock] 进入子 shell (设备 ${need_lock[*]})，exit 释放锁" >&2
    (
        for fd in "${lock_fds[@]}"; do
            exec {fd}>&-
        done
        exec env NPU_LOCKED_DEVICE="$NPU_LOCKED_DEVICE" bash
    )
    exit_code=$?
fi

trap - SIGINT SIGTERM
for fd in "${lock_fds[@]}"; do
    exec {fd}>&-
done
echo "${C_DIM}[npu-lock] 已释放设备 ${need_lock[*]} 的锁${C_RESET}" >&2
exit $exit_code
