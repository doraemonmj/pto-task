#!/bin/bash
# deploy.sh: 一键同步所有文件到部署位置
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root 权限，请用: sudo bash deploy.sh"
    exit 1
fi

echo ">>> 同步脚本"
cp "$SCRIPT_DIR/task-daemon.sh"  /usr/local/sbin/task-daemon
cp "$SCRIPT_DIR/task-submit.sh"  /usr/local/bin/task-submit
cp "$SCRIPT_DIR/npu_lock.sh"     /usr/local/bin/npu-lock
chmod +x /usr/local/sbin/task-daemon /usr/local/bin/task-submit /usr/local/bin/npu-lock

echo ">>> 同步 systemd 服务"
cp "$SCRIPT_DIR/taskqueue.service" /etc/systemd/system/
systemctl daemon-reload

echo ">>> 同步 udev 规则"
cp "$SCRIPT_DIR/99-npu-taskqueue.rules" /etc/udev/rules.d/
udevadm control --reload-rules
udevadm trigger

echo ">>> 同步 profile.d 脚本"
cp "$SCRIPT_DIR/taskqueue-npu.sh" /etc/profile.d/

echo ">>> 同步配置文件"
CONF_DIR="$SCRIPT_DIR/conf"
BASE_DIR=$(grep '^BASE_DIR=' "$CONF_DIR/taskqueue.conf" | cut -d'"' -f2)
BASE_DIR="${BASE_DIR:-/var/lib/taskqueue}"
cp "$CONF_DIR/taskqueue.conf"     /etc/taskqueue.conf
cp "$CONF_DIR/available_devices"  "$BASE_DIR/available_devices"
if [ -f "$CONF_DIR/restricted-users" ]; then
    cp "$CONF_DIR/restricted-users"   /etc/taskqueue-restricted-users
else
    echo "    警告: conf/restricted-users 不存在（已被 .gitignore 排除），"
    echo "          用 restricted-users.example 占位。请复制并填入真实名单后重新部署。"
    cp "$CONF_DIR/restricted-users.example" /etc/taskqueue-restricted-users
fi
chmod 644 /etc/taskqueue.conf "$BASE_DIR/available_devices" /etc/taskqueue-restricted-users

echo ">>> 重启 daemon"
systemctl restart taskqueue

echo ">>> 当前状态"
systemctl status taskqueue --no-pager

echo ""
echo "=== 部署完成 ==="
echo "注意：用户需要重新登录才能生效环境变量变更"
