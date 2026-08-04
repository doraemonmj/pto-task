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
install -m 755 "$REPO_DIR/pto-task-auto-update.sh" "$APP_DIR/pto-task-auto-update"
install -m 666 /dev/null "$STATE_DIR/locks/update-reservation.lock"

cat > "$CONFIG_DIR/taskqueue.conf" <<EOF
STATE_DIR="$STATE_DIR"
LOGS_DIR="$LOGS_DIR"
TMP_DIR="$TMP_DIR"
AUTO_UPDATE_REPOSITORY="mock://repository"
AUTO_UPDATE_BRANCH="main"
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
if [[ "${1:-}" == clone ]]; then
    attempts=0
    [[ ! -f "$RETRY_TEST_ROOT/attempts" ]] || attempts="$(<"$RETRY_TEST_ROOT/attempts")"
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" > "$RETRY_TEST_ROOT/attempts"
    if [[ "${RETRY_FAIL_FOREVER:-false}" == true ]] || (( attempts < 3 )); then
        exit 1
    fi
    destination="${*: -1}"
    mkdir -p "$destination"
    touch "$destination/setup.sh"
    exit 0
fi
if [[ "${1:-}" == -C && "${3:-}" == rev-parse && "${4:-}" == HEAD ]]; then
    printf '%s\n' 'remote-revision'
    exit 0
fi
exit 2
EOF

cat > "$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$1" >> "$RETRY_TEST_ROOT/sleeps"
EOF

cat > "$FAKE_BIN/bash" <<'EOF'
#!/usr/bin/bash
if [[ "${1:-}" == */setup.sh ]]; then
    printf '%s\n' "$*" > "$RETRY_TEST_ROOT/install-call"
    exit 0
fi
exec /usr/bin/bash "$@"
EOF
chmod 755 "$FAKE_BIN"/*

config_before="$(sha256sum "$CONFIG_DIR/taskqueue.conf")"
RETRY_TEST_ROOT="$TEST_ROOT" PATH="$FAKE_BIN:$PATH" \
    /usr/bin/bash "$APP_DIR/pto-task-auto-update"
config_after="$(sha256sum "$CONFIG_DIR/taskqueue.conf")"

[[ "$config_before" == "$config_after" ]]
[[ "$(<"$TEST_ROOT/attempts")" == 3 ]]
[[ "$(wc -l < "$TEST_ROOT/sleeps")" -eq 2 ]]
[[ "$(sed -n '1p' "$TEST_ROOT/sleeps")" == 300 ]]
[[ "$(sed -n '2p' "$TEST_ROOT/sleeps")" == 300 ]]
[[ -s "$TEST_ROOT/install-call" ]]
grep -Fq 'update check attempt 1/3 failed; retrying in 300s' "$LOGS_DIR/auto-update.log"
grep -Fq 'update check attempt 2/3 failed; retrying in 300s' "$LOGS_DIR/auto-update.log"
grep -Fq 'updated app to revision remote-revis; daemon was not restarted' "$LOGS_DIR/auto-update.log"
grep -Fq 'LOCAL_SENTINEL="keep-me"' "$CONFIG_DIR/taskqueue.conf"

rm -f "$TEST_ROOT/attempts" "$TEST_ROOT/sleeps" "$TEST_ROOT/install-call"
if RETRY_FAIL_FOREVER=true RETRY_TEST_ROOT="$TEST_ROOT" PATH="$FAKE_BIN:$PATH" \
    /usr/bin/bash "$APP_DIR/pto-task-auto-update"; then
    echo 'error: updater succeeded after every clone attempt failed' >&2
    exit 1
fi
[[ "$(<"$TEST_ROOT/attempts")" == 3 ]]
[[ "$(wc -l < "$TEST_ROOT/sleeps")" -eq 2 ]]
[[ ! -e "$TEST_ROOT/install-call" ]]
grep -Fq 'update check failed after 3 attempts: unable to fetch repository' \
    "$LOGS_DIR/auto-update.log"
[[ "$config_before" == "$(sha256sum "$CONFIG_DIR/taskqueue.conf")" ]]

echo 'auto-update retry tests passed'
