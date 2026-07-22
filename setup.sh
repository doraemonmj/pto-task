#!/bin/bash
# setup.sh: 部署脚本
#
# 系统级（需要 root）:
#   sudo bash setup.sh [--max-concurrent N]
#
# 个人用户级（无需 root）:
#   bash setup.sh --local [--max-concurrent N] [--base-dir DIR]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAX_CONCURRENT=""
LOCAL_MODE=false
BASE_DIR=""

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)          LOCAL_MODE=true; shift ;;
        --max-concurrent) MAX_CONCURRENT="$2"; shift 2 ;;
        --base-dir)       BASE_DIR="$2"; shift 2 ;;
        *) echo "未知参数: $1"
           echo "用法:"
           echo "  sudo bash setup.sh [--max-concurrent N]              系统级"
           echo "  bash setup.sh --local [--max-concurrent N] [--base-dir DIR]  个人用户级"
           exit 1 ;;
    esac
done

# 系统级需要 root
if [[ "$LOCAL_MODE" == "false" ]] && [ "$(id -u)" -ne 0 ]; then
    echo "系统级部署需要 root，请用: sudo bash setup.sh"
    echo "个人用户部署请用: bash setup.sh --local"
    exit 1
fi

# 未指定则要求输入
if [ -z "$MAX_CONCURRENT" ]; then
    read -p "最大并发任务数 (通常等于 NPU 卡数，默认 2): " MAX_CONCURRENT
    MAX_CONCURRENT="${MAX_CONCURRENT:-2}"
fi
if ! [[ "$MAX_CONCURRENT" =~ ^[1-9][0-9]*$ ]]; then
    echo "错误: --max-concurrent 必须为正整数"
    exit 1
fi

if [[ "$LOCAL_MODE" == "true" ]]; then
    # ===== 个人用户级部署 =====
    BASE_DIR="${BASE_DIR:-$HOME/.taskqueue}"
    CONF_FILE="$HOME/.config/taskqueue.conf"
    BIN_DIR="$HOME/.local/bin"
    SERVICE_DIR="$HOME/.config/systemd/user"

    echo ">>> 个人用户级部署 (无需 root)"
    echo "    BASE_DIR : $BASE_DIR"
    echo "    CONF     : $CONF_FILE"
    echo "    BIN      : $BIN_DIR"

    mkdir -p "$BASE_DIR"/{pending,running,done,logs,locks,kill,fifo}
    chmod 700 "$BASE_DIR" "$BASE_DIR"/{running,done,logs}
    chmod 700 "$BASE_DIR"/{pending,locks,kill}

    mkdir -p "$(dirname "$CONF_FILE")"
    cat > "$CONF_FILE" <<EOF
# taskqueue 个人配置（由 setup.sh --local 生成）
BASE_DIR="$BASE_DIR"
MAX_CONCURRENT=$MAX_CONCURRENT
EOF

    mkdir -p "$BIN_DIR"
    # npu-lock 包装脚本（注入配置路径）
    cat > "$BIN_DIR/npu-lock" <<WRAPPER
#!/bin/bash
export TASKQUEUE_CONF="$CONF_FILE"
exec bash "$SCRIPT_DIR/npu_lock.sh" "\$@"
WRAPPER
    chmod +x "$BIN_DIR/npu-lock"

    # task-daemon 包装脚本（注入必要的环境变量）
    cat > "$BIN_DIR/task-daemon" <<WRAPPER
#!/bin/bash
export TASKQUEUE_CONF="$CONF_FILE"
export TASKQUEUE_ALLOW_USER=1
exec bash "$SCRIPT_DIR/task-daemon.sh" "\$@"
WRAPPER
    chmod +x "$BIN_DIR/task-daemon"

    # task-submit 包装脚本（注入配置路径）
    cat > "$BIN_DIR/task-submit" <<WRAPPER
#!/bin/bash
export TASKQUEUE_CONF="$CONF_FILE"
exec bash "$SCRIPT_DIR/task-submit.sh" "\$@"
WRAPPER
    chmod +x "$BIN_DIR/task-submit"

    # systemd user service（可选）
    mkdir -p "$SERVICE_DIR"
    cat > "$SERVICE_DIR/taskqueue.service" <<EOF
[Unit]
Description=taskqueue daemon (user)
After=default.target

[Service]
Type=simple
Environment=TASKQUEUE_CONF=$CONF_FILE
Environment=TASKQUEUE_ALLOW_USER=1
ExecStart=bash $SCRIPT_DIR/task-daemon.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    echo ""
    echo ">>> 启动方式（选其一）"
    echo ""
    echo "  方式1 - systemd user service（推荐，开机自启）:"
    echo "    systemctl --user daemon-reload"
    echo "    systemctl --user enable --now taskqueue"
    echo "    systemctl --user status taskqueue"
    echo ""
    echo "  方式2 - 后台直接运行:"
    echo "    nohup task-daemon &"
    echo ""
    echo ">>> 确保 $BIN_DIR 在 PATH 中:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"   # 加入 ~/.bashrc"
    echo ""
    echo "=== 个人部署完成 ==="
    echo "用法:"
    echo "  task-submit --device auto --run \"python train.py\""
    echo "  task-submit --list"

else
    # ===== 系统级部署（原有逻辑）=====
    BASE_DIR="${BASE_DIR:-/var/lib/taskqueue}"
    CONF_FILE="/etc/taskqueue.conf"

    echo ">>> 写入配置 $CONF_FILE"
    cat > "$CONF_FILE" <<EOF
# taskqueue 配置（由 setup.sh 自动生成）
BASE_DIR="$BASE_DIR"
MAX_CONCURRENT=$MAX_CONCURRENT
EOF
    chmod 644 "$CONF_FILE"

    echo ">>> 创建数据目录 ($BASE_DIR)"
    mkdir -p "$BASE_DIR"/{pending,running,done,logs,locks,kill,fifo}
    chmod 1777 "$BASE_DIR"/pending
    chmod 755  "$BASE_DIR"/{running,done,logs}
    chmod 1777 "$BASE_DIR"/{locks,kill,fifo}

    echo ">>> 配置 NPU 设备访问控制"
    # HwHiAiUser 组由 CANN 驱动安装时创建，拥有 /dev/davinci* 访问权限
    # 将用户从该组移除后，只能通过 task-submit 提交任务（daemon 临时注入该组）
    if ! getent group HwHiAiUser &>/dev/null; then
        echo "    警告: HwHiAiUser 组不存在，CANN 驱动可能未安装"
    else
        echo "    HwHiAiUser 组已存在 (CANN 驱动组)"
    fi
    if [ -f "$SCRIPT_DIR/99-npu-taskqueue.rules" ]; then
        cp "$SCRIPT_DIR/99-npu-taskqueue.rules" /etc/udev/rules.d/
        udevadm control --reload-rules
        udevadm trigger
        echo "    已安装 udev 规则（受限卡仅可通过 task-submit 访问）"
    fi

    echo ">>> 安装脚本"
    cp "$SCRIPT_DIR/task-submit.sh" /usr/local/bin/task-submit
    cp "$SCRIPT_DIR/task-daemon.sh" /usr/local/sbin/task-daemon
    cp "$SCRIPT_DIR/npu_lock.sh"    /usr/local/bin/npu-lock
    chmod +x /usr/local/bin/task-submit /usr/local/sbin/task-daemon /usr/local/bin/npu-lock

    echo ">>> 安装定时清理 cron"
    cp "$SCRIPT_DIR/taskqueue-clean.cron" /etc/cron.d/taskqueue-clean
    chmod 644 /etc/cron.d/taskqueue-clean

    echo ">>> 安装 systemd 服务"
    cp "$SCRIPT_DIR/taskqueue.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now taskqueue

    echo ">>> 检查服务状态"
    systemctl status taskqueue --no-pager

    echo ""
    echo "=== 系统级部署完成 ==="
    echo "用法:"
    echo "  task-submit --device auto --run \"python train.py\""
    echo "  task-submit --list"
fi
