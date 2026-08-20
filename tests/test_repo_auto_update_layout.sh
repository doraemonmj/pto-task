#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
TOOLS_ROOT="$TEST_ROOT/tools"
BIN_DIR="$TEST_ROOT/bin"
SBIN_DIR="$TEST_ROOT/sbin"
mkdir -p "$BIN_DIR" "$SBIN_DIR"

bash "$REPO_DIR/setup.sh" --no-init-config --disable-auto-update \
    --tools-root "$TOOLS_ROOT" \
    --bin-dir "$BIN_DIR" --sbin-dir "$SBIN_DIR" >/dev/null
install_root="$TOOLS_ROOT/pto-task"
[[ -x "$install_root/app/lib/repo-auto-update/updater.sh" ]]
[[ -x "$install_root/app/lib/repo-auto-update/manifest.py" ]]
[[ -x "$install_root/app/pto-task-repo-update-verify" ]]
[[ -x "$install_root/app/pto-task-repo-update-apply" ]]
[[ -x "$install_root/app/pto-task-repo-update-deploy" ]]
[[ -d "$install_root/update" ]]
grep -Fqx "REPO_AUTO_UPDATE_STATE_DIR=$install_root/update" \
    "$install_root/config/repo-auto-update.env"
grep -Fqx "REPO_AUTO_UPDATE_TMP_DIR=$install_root/tmp" \
    "$install_root/config/repo-auto-update.env"
grep -Fqx 'INSTALL_ENABLE_AUTO_UPDATE=false' \
    "$install_root/app/.pto-task-install-options"
grep -Fqx 'TimeoutStartSec=infinity' \
    "$install_root/app/pto-task-auto-update.service"
grep -Fqx "ExecStart=$install_root/app/lib/repo-auto-update/updater.sh $install_root/config/repo-auto-update.env" \
    "$install_root/app/pto-task-auto-update.service"
grep -Fqx 'OnCalendar=*-*-* 03:37:00 Asia/Shanghai' \
    "$install_root/app/pto-task-auto-update.timer"
grep -Fqx 'RandomizedDelaySec=20min' \
    "$install_root/app/pto-task-auto-update.timer"

echo 'repository-controlled update layout tests passed'
