#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

INSTALL_ROOT="$TEST_ROOT/tools/pto-task"
APP_DIR="$INSTALL_ROOT/app"
CONFIG_DIR="$INSTALL_ROOT/config"
STATE_DIR="$INSTALL_ROOT/state"
LOGS_DIR="$INSTALL_ROOT/logs"
TMP_DIR="$INSTALL_ROOT/tmp"
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$APP_DIR" "$CONFIG_DIR" "$STATE_DIR/locks" "$STATE_DIR/pending" \
    "$STATE_DIR/running" "$LOGS_DIR" "$TMP_DIR" "$FAKE_BIN"
chmod 1777 "$STATE_DIR/locks" "$STATE_DIR/pending"
install -m 755 "$REPO_DIR/scripts/repo-auto-update-deploy.sh" \
    "$APP_DIR/pto-task-repo-update-deploy"
install -m 666 /dev/null "$STATE_DIR/locks/update-reservation.lock"
CONTROLLED_TARGET=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CONTROLLED_CHECKOUT="$TEST_ROOT/controlled-checkout"
mkdir -p "$CONTROLLED_CHECKOUT"
export PTO_TASK_UPDATE_CHECKOUT="$CONTROLLED_CHECKOUT"
export PTO_TASK_UPDATE_TARGET="$CONTROLLED_TARGET"

cat > "$CONFIG_DIR/taskqueue.conf" <<EOF
STATE_DIR="$STATE_DIR"
LOGS_DIR="$LOGS_DIR"
TMP_DIR="$TMP_DIR"
# Simulate an existing server that still carries the former six-hour value.
AUTO_UPDATE_IDLE_WAIT_SECONDS=21600
AUTO_UPDATE_IDLE_WAIT_MAX_SECONDS=21600
LOCAL_SENTINEL="keep-me"
EOF
printf '%s\n' 'installed-revision' > "$APP_DIR/.pto-task-release"

cat > "$FAKE_BIN/id" <<'EOF'
#!/usr/bin/bash
if [[ "${1:-}" == -u ]]; then
    echo 0
    exit 0
fi
exec /usr/bin/id "$@"
EOF

cat > "$FAKE_BIN/chown" <<'EOF'
#!/usr/bin/bash
exit 0
EOF

cat > "$FAKE_BIN/stat" <<'EOF'
#!/usr/bin/bash
if [[ "${1:-}" == -c && "${2:-}" == %u ]]; then
    echo 0
    exit 0
fi
exec /usr/bin/stat "$@"
EOF

cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/bash
if [[ "${1:-}" == -C && "${3:-}" == rev-parse && "${4:-}" == HEAD ]]; then
    printf '%s\n' "$PTO_TASK_UPDATE_TARGET"
    exit 0
fi
exit 2
EOF

cat > "$FAKE_BIN/bash" <<'EOF'
#!/usr/bin/bash
if [[ "${1:-}" == */setup.sh ]]; then
    printf '%s\n' "$*" > "$RETRY_TEST_ROOT/install-call"
    if [[ "${RETRY_SETUP_FAIL:-false}" == true ]]; then
        printf '%s\n' 'simulated setup permission failure'
        exit 42
    fi
    printf '%s\n' "${PTO_TASK_UPDATE_TARGET:-remote-revision}" \
        > "$RETRY_APP_DIR/.pto-task-release"
    touch "$RETRY_APP_DIR/.pto-task-restart-required"
    exit 0
fi
exec /usr/bin/bash "$@"
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "$RETRY_TEST_ROOT/systemctl-calls"
case "${1:-}" in
    is-active)
        [[ "${SYSTEMCTL_INACTIVE:-false}" != true || -e "$RETRY_TEST_ROOT/restarted" ]]
        exit $?
        ;;
    stop) exit 0 ;;
    restart)
        if [[ "${SYSTEMCTL_RESTART_FAIL:-false}" == true ]]; then
            exit 1
        fi
        touch "$RETRY_TEST_ROOT/restarted"
        exit 0
        ;;
esac
exit 0
EOF
chmod 755 "$FAKE_BIN"/*

config_before="$(sha256sum "$CONFIG_DIR/taskqueue.conf")"
RETRY_TEST_ROOT="$TEST_ROOT" RETRY_APP_DIR="$APP_DIR" PATH="$FAKE_BIN:$PATH" \
    /usr/bin/bash "$APP_DIR/pto-task-repo-update-deploy"
config_after="$(sha256sum "$CONFIG_DIR/taskqueue.conf")"

[[ "$config_before" == "$config_after" ]]
[[ -s "$TEST_ROOT/install-call" ]]
grep -Fq 'idle wait maximum capped from 21600s to 7200s' "$LOGS_DIR/auto-update.log"
grep -Fq 'idle wait capped from 21600s to 7200s' "$LOGS_DIR/auto-update.log"
grep -Fq 'updated app to revision aaaaaaaaaaaa; daemon restarted' "$LOGS_DIR/auto-update.log"
grep -Fq 'LOCAL_SENTINEL="keep-me"' "$CONFIG_DIR/taskqueue.conf"
grep -Fq -- '--non-interactive' "$TEST_ROOT/install-call"
grep -Fq -- '--enable-auto-update' "$TEST_ROOT/install-call"
grep -Fq 'restart pto-task.service' "$TEST_ROOT/systemctl-calls"
[[ ! -e "$APP_DIR/.pto-task-restart-required" ]]
[[ ! -e "$APP_DIR/.pto-task-activation-retry" ]]

# Installer stderr/stdout and its real exit status must survive in the updater
# log. A failed install must not be mistaken for an activated new revision.
printf '%s\n' 'installed-revision' > "$APP_DIR/.pto-task-release"
rm -f "$APP_DIR/.pto-task-restart-required" "$APP_DIR/.pto-task-activation-retry" \
    "$TEST_ROOT/install-call"
if RETRY_SETUP_FAIL=true RETRY_TEST_ROOT="$TEST_ROOT" RETRY_APP_DIR="$APP_DIR" \
    PATH="$FAKE_BIN:$PATH" /usr/bin/bash "$APP_DIR/pto-task-repo-update-deploy"; then
    echo 'error: updater succeeded after setup failed' >&2
    exit 1
fi
[[ "$(<"$APP_DIR/.pto-task-release")" == installed-revision ]]
grep -Fq 'setup: simulated setup permission failure' "$LOGS_DIR/auto-update.log"
grep -Fq 'update failed while installing app (rc=42 target=aaaaaaaaaaaa)' \
    "$LOGS_DIR/auto-update.log"

# The root updater must never source installer options that another user can
# modify. This is a root-code-execution boundary, not merely a mode preference.
printf '%s\n' 'touch "$RETRY_TEST_ROOT/unsafe-options-executed"' \
    > "$APP_DIR/.pto-task-install-options"
chmod 666 "$APP_DIR/.pto-task-install-options"
rm -f "$TEST_ROOT/unsafe-options-executed"
if RETRY_TEST_ROOT="$TEST_ROOT" RETRY_APP_DIR="$APP_DIR" PATH="$FAKE_BIN:$PATH" \
    /usr/bin/bash "$APP_DIR/pto-task-repo-update-deploy"; then
    echo 'error: updater accepted writable installer options' >&2
    exit 1
fi
[[ ! -e "$TEST_ROOT/unsafe-options-executed" ]]
grep -Fq 'update aborted: unsafe installer-options control file' \
    "$LOGS_DIR/auto-update.log"
rm -f "$APP_DIR/.pto-task-install-options"

# A setup performed by an older updater leaves a restart marker. Even when the
# installed revision already matches remote, the new updater must activate it.
printf '%s\n' "$CONTROLLED_TARGET" > "$APP_DIR/.pto-task-release"
touch "$APP_DIR/.pto-task-restart-required"
rm -f "$TEST_ROOT/install-call" "$TEST_ROOT/systemctl-calls"
RETRY_TEST_ROOT="$TEST_ROOT" RETRY_APP_DIR="$APP_DIR" PATH="$FAKE_BIN:$PATH" \
    /usr/bin/bash "$APP_DIR/pto-task-repo-update-deploy"
[[ ! -e "$TEST_ROOT/install-call" ]]
grep -Fq 'restart pto-task.service' "$TEST_ROOT/systemctl-calls"
grep -Fq 'activated installed revision aaaaaaaaaaaa; daemon restarted' \
    "$LOGS_DIR/auto-update.log"
[[ ! -e "$APP_DIR/.pto-task-restart-required" ]]

# If activation fails after stopping the old daemon, keep both markers. A later
# run retries activation even when systemctl now reports the daemon inactive.
touch "$APP_DIR/.pto-task-restart-required"
rm -f "$TEST_ROOT/systemctl-calls" "$TEST_ROOT/restarted"
if SYSTEMCTL_RESTART_FAIL=true RETRY_TEST_ROOT="$TEST_ROOT" \
    RETRY_APP_DIR="$APP_DIR" PATH="$FAKE_BIN:$PATH" \
    /usr/bin/bash "$APP_DIR/pto-task-repo-update-deploy"; then
    echo 'error: updater succeeded after daemon restart failed' >&2
    exit 1
fi
[[ -e "$APP_DIR/.pto-task-restart-required" ]]
[[ -e "$APP_DIR/.pto-task-activation-retry" ]]
grep -Fq 'daemon restart failed; activation will be retried' "$LOGS_DIR/auto-update.log"

rm -f "$TEST_ROOT/systemctl-calls" "$TEST_ROOT/restarted"
SYSTEMCTL_INACTIVE=true RETRY_TEST_ROOT="$TEST_ROOT" RETRY_APP_DIR="$APP_DIR" \
    PATH="$FAKE_BIN:$PATH" /usr/bin/bash "$APP_DIR/pto-task-repo-update-deploy"
grep -Fq 'restart pto-task.service' "$TEST_ROOT/systemctl-calls"
[[ -e "$TEST_ROOT/restarted" ]]
[[ ! -e "$APP_DIR/.pto-task-restart-required" ]]
[[ ! -e "$APP_DIR/.pto-task-activation-retry" ]]

# Never append root updater logs or write markers through historical leaf
# symlinks. The external targets must remain untouched.
printf '%s\n' 'log-target-unchanged' > "$TEST_ROOT/log-target"
rm -f "$LOGS_DIR/auto-update.log"
ln -s "$TEST_ROOT/log-target" "$LOGS_DIR/auto-update.log"
if RETRY_TEST_ROOT="$TEST_ROOT" PATH="$FAKE_BIN:$PATH" \
    /usr/bin/bash "$APP_DIR/pto-task-repo-update-deploy" \
    >/dev/null 2>"$TEST_ROOT/unsafe-log.stderr"; then
    echo 'error: updater accepted a symlinked log file' >&2
    exit 1
fi
[[ "$(<"$TEST_ROOT/log-target")" == log-target-unchanged ]]
grep -Fq 'automatic-update log must be a root-owned' "$TEST_ROOT/unsafe-log.stderr"

rm -f "$LOGS_DIR/auto-update.log"
install -m 644 /dev/null "$LOGS_DIR/auto-update.log"
printf '%s\n' 'marker-target-unchanged' > "$TEST_ROOT/marker-target"
ln -s "$TEST_ROOT/marker-target" "$APP_DIR/.pto-task-restart-required"
if RETRY_TEST_ROOT="$TEST_ROOT" PATH="$FAKE_BIN:$PATH" \
    /usr/bin/bash "$APP_DIR/pto-task-repo-update-deploy"; then
    echo 'error: updater accepted a symlinked restart marker' >&2
    exit 1
fi
[[ "$(<"$TEST_ROOT/marker-target")" == marker-target-unchanged ]]
grep -Fq 'update aborted: unsafe root control file:' "$LOGS_DIR/auto-update.log"

echo 'auto-update retry tests passed'
