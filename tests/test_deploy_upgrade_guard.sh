#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

TEST_REPO="$TEST_ROOT/repo"
TOOLS_ROOT="$TEST_ROOT/tools"
INSTALL_ROOT="$TOOLS_ROOT/pto-task"
INSTALL_BIN="$TEST_ROOT/install-bin"
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_REPO" "$FAKE_BIN" "$INSTALL_BIN" "$INSTALL_ROOT/config" \
    "$INSTALL_ROOT/state/locks" "$INSTALL_ROOT/state/running"
install -m 755 "$REPO_DIR/deploy.sh" "$TEST_REPO/deploy.sh"
install -m 666 /dev/null "$INSTALL_ROOT/state/locks/update-reservation.lock"
cat > "$INSTALL_ROOT/config/taskqueue.conf" <<EOF
STATE_DIR="$INSTALL_ROOT/state"
EOF

cat > "$TEST_REPO/setup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -e "$DEPLOY_TEST_INSTALL_ROOT/state/maintenance" ]]

# Drop the deployment lock descriptor inherited from the parent, then prove a
# separately opened shared reservation cannot pass while setup is running.
for inherited_fd in $(seq 3 255); do
    eval "exec ${inherited_fd}>&-" 2>/dev/null || true
done
exec 9>>"$DEPLOY_TEST_INSTALL_ROOT/state/locks/update-reservation.lock"
if flock -s -n 9; then
    echo 'error: setup was not protected by the exclusive upgrade lock' >&2
    exit 1
fi
mkdir -p "$DEPLOY_TEST_INSTALL_ROOT/app"
: > "$DEPLOY_TEST_INSTALL_ROOT/app/pto-task.service"
: > "$DEPLOY_TEST_ROOT/setup-guard-observed"
EOF
chmod 755 "$TEST_REPO/setup.sh"

cat > "$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -u ]]; then
    printf '0\n'
    exit 0
fi
exec /usr/bin/id "$@"
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DEPLOY_TEST_ROOT/systemctl-calls"
case "${1:-}" in
    is-active) exit 0 ;;
    restart)
        [[ -e "$DEPLOY_TEST_INSTALL_ROOT/state/maintenance" ]]
        exit 0
        ;;
esac
exit 0
EOF
chmod 755 "$FAKE_BIN/id" "$FAKE_BIN/systemctl"
cat > "$INSTALL_BIN/task-submit" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$INSTALL_BIN/task-submit"

DEPLOY_TEST_ROOT="$TEST_ROOT" DEPLOY_TEST_INSTALL_ROOT="$INSTALL_ROOT" \
    PATH="$FAKE_BIN:$PATH" bash "$TEST_REPO/deploy.sh" \
    --tools-root "$TOOLS_ROOT" --bin-dir "$INSTALL_BIN" \
    --non-interactive >/dev/null

[[ -e "$TEST_ROOT/setup-guard-observed" ]]
grep -Fqx 'restart pto-task.service' "$TEST_ROOT/systemctl-calls"
[[ ! -e "$INSTALL_ROOT/state/maintenance" ]]

echo 'deploy upgrade guard tests passed'
