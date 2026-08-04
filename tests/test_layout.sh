#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -e "$REPO_DIR/runtime" ]]; then
    echo "error: $REPO_DIR/runtime already exists; refusing to overwrite a possible live source-layout deployment" >&2
    exit 1
fi
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT" "$REPO_DIR/runtime"' EXIT

TOOLS_ROOT="$TEST_ROOT/tools"
BIN_DIR="$TEST_ROOT/bin"
SBIN_DIR="$TEST_ROOT/sbin"
mkdir -p "$BIN_DIR" "$SBIN_DIR"
touch "$BIN_DIR/task-submit" "$BIN_DIR/npu-lock" "$BIN_DIR/pto-taskqueue" "$SBIN_DIR/task-daemon"

bash "$REPO_DIR/setup.sh" --tools-root "$TOOLS_ROOT" --bin-dir "$BIN_DIR" --sbin-dir "$SBIN_DIR" --init-config
INSTALL_ROOT="$TOOLS_ROOT/pto-task"

[[ -L "$BIN_DIR/task-submit" && -L "$BIN_DIR/pto-task" ]]
[[ ! -e "$BIN_DIR/npu-lock" && ! -e "$BIN_DIR/pto-taskqueue" && ! -e "$SBIN_DIR/task-daemon" ]]
[[ "$(readlink -f "$BIN_DIR/task-submit")" == "$INSTALL_ROOT/app/task-submit" ]]
[[ "$(readlink -f "$BIN_DIR/pto-task")" == "$INSTALL_ROOT/app/task-submit" ]]
[[ -x "$INSTALL_ROOT/app/task-submit" ]]
[[ -x "$INSTALL_ROOT/app/pto-task-stats" && -x "$INSTALL_ROOT/app/pto-task-usage-sampler" ]]
[[ -f "$INSTALL_ROOT/app/pto-task.service" && -f "$INSTALL_ROOT/app/pto-task-clean.cron" ]]
grep -Fqx "ExecStart=$INSTALL_ROOT/app/task-daemon" "$INSTALL_ROOT/app/pto-task.service"
grep -Fq "$BIN_DIR/task-submit --clean" "$INSTALL_ROOT/app/pto-task-clean.cron"
grep -Fqx "BIN_DIR=$BIN_DIR" "$INSTALL_ROOT/app/.pto-task-install-options"
[[ -f "$INSTALL_ROOT/app/pto-task-usage-sampler.service" && -f "$INSTALL_ROOT/app/pto-task-usage-sampler.timer" ]]
[[ -x "$INSTALL_ROOT/app/pto-task-auto-update" ]]
[[ -f "$INSTALL_ROOT/app/pto-task-auto-update.service" && -f "$INSTALL_ROOT/app/pto-task-auto-update.timer" ]]
grep -Fqx "ExecStart=$INSTALL_ROOT/app/pto-task-auto-update" "$INSTALL_ROOT/app/pto-task-auto-update.service"
[[ -d "$INSTALL_ROOT/config" && -d "$INSTALL_ROOT/state" && -d "$INSTALL_ROOT/logs" && -d "$INSTALL_ROOT/tmp" ]]
grep -q '^TASK_EXECUTION_MODE="HwHiAiUser"[[:space:]]*#' "$INSTALL_ROOT/config/taskqueue.conf"
grep -q '^PTOAS_BASE="/usr/local/ptoas"[[:space:]]*#' "$INSTALL_ROOT/config/taskqueue.conf"
grep -q '^AUTO_UPDATE_REPOSITORY=' "$INSTALL_ROOT/config/taskqueue.conf"
[[ "$(grep -c '^AUTO_UPDATE_REPOSITORY=' "$INSTALL_ROOT/config/taskqueue.conf")" -eq 1 ]]
grep -q '^AUTO_UPDATE_BRANCH="main"' "$INSTALL_ROOT/config/taskqueue.conf"
[[ "$(stat -c %a "$INSTALL_ROOT/state/locks/update-reservation.lock")" == 666 ]]
grep -Fqx 'https://github.com/pypto-tools/npu-taskqueue.git' "$INSTALL_ROOT/app/.pto-task-update-repository"
grep -Fq 'AUTO_UPDATE_REPOSITORY=https://github.com/pypto-tools/npu-taskqueue.git' "$INSTALL_ROOT/config/taskqueue.conf"
"$BIN_DIR/task-submit" 'true' >/dev/null
"$BIN_DIR/pto-task" 'true' >/dev/null
compgen -G "$INSTALL_ROOT/state/pending/task_*" >/dev/null

# Task metadata is shared for queue listings, while environment snapshots stay
# private, regardless of the submitting user's umask.
strict_task_id="$(umask 077; "$BIN_DIR/task-submit" 'true')"
[[ "$(stat -c %a "$INSTALL_ROOT/state/pending/$strict_task_id")" == 644 ]]
[[ "$(stat -c %a "$INSTALL_ROOT/state/pending/${strict_task_id}.env")" == 600 ]]

exec 9>"$INSTALL_ROOT/state/locks/update-reservation.lock"
flock -x 9
if timeout 0.2 "$BIN_DIR/pto-task" 'true' >/dev/null 2>&1; then
    echo 'error: submission did not wait for the update reservation lock' >&2
    exit 1
fi
flock -u 9
"$INSTALL_ROOT/app/pto-task-usage-sampler"
printf 'SUBMIT_USER=tester\nSUBMIT_TIME=%s\nSTART_TIME=%s\nFINISH_TIME=%s\nDEVICE=0\n' "$(date -Iseconds -d '2 minutes ago')" "$(date -Iseconds -d '1 minute ago')" "$(date -Iseconds)" > "$INSTALL_ROOT/state/done/task_stats_test"
printf 'SUBMIT_USER=%s\nSUBMIT_TIME=%s\nSTART_TIME=%s\nFINISH_TIME=%s\nDEVICE=0\n' "$(id -un)" "$(date -Iseconds -d '2 minutes ago')" "$(date -Iseconds -d '1 minute ago')" "$(date -Iseconds)" > "$INSTALL_ROOT/state/done/task_stats_self"
stats_output="$("$BIN_DIR/pto-task" --stats --days 1)"
grep -q '总卡时' <<< "$stats_output"
if [[ "$(id -u)" -ne 0 ]]; then
    grep -q "$(id -un)" <<< "$stats_output"
    if grep -q 'tester' <<< "$stats_output"; then
        echo 'error: stats exposed another user' >&2
        exit 1
    fi
fi

printf 'MAX_CONCURRENT=23\n' >> "$INSTALL_ROOT/config/taskqueue.conf"
mkdir -p "$INSTALL_ROOT/state/pending"
printf 'keep\n' > "$INSTALL_ROOT/state/pending/sentinel"
bash "$REPO_DIR/setup.sh" --tools-root "$TOOLS_ROOT" --bin-dir "$BIN_DIR" --sbin-dir "$SBIN_DIR"
grep -qx 'MAX_CONCURRENT=23' "$INSTALL_ROOT/config/taskqueue.conf"
[[ "$(<"$INSTALL_ROOT/state/pending/sentinel")" == keep ]]

bash "$REPO_DIR/tests/test_ptoas_option.sh"

mkdir -p "$REPO_DIR/runtime/config" "$REPO_DIR/runtime/state/pending" "$REPO_DIR/runtime/state/locks" "$REPO_DIR/runtime/logs" "$REPO_DIR/runtime/tmp"
install -m 666 /dev/null "$REPO_DIR/runtime/state/locks/update-reservation.lock"
cat > "$REPO_DIR/runtime/config/taskqueue.conf" <<EOF
STATE_DIR="$REPO_DIR/runtime/state"
LOGS_DIR="$REPO_DIR/runtime/logs"
MAX_CONCURRENT=1
EOF
"$REPO_DIR/task-submit.sh" 'true' >/dev/null
compgen -G "$REPO_DIR/runtime/state/pending/task_*" >/dev/null
"$REPO_DIR/task-submit.sh" --stats --days 1 >/dev/null

# A daemon-provided lock state must override submitted configuration.
mkdir -p "$TEST_ROOT/trusted-locks/locks" "$TEST_ROOT/evil-locks/locks"
printf 'STATE_DIR="%s/evil-locks"\n' "$TEST_ROOT" > "$TEST_ROOT/evil.conf"
TASKQUEUE_LOCK_STATE_DIR="$TEST_ROOT/trusted-locks" \
TASKQUEUE_CONF="$TEST_ROOT/evil.conf" \
    bash "$REPO_DIR/npu_lock.sh" 0 --timeout 0 -- true >/dev/null
[[ -e "$TEST_ROOT/trusted-locks/locks/npu_device_0.lock" ]]
[[ ! -e "$TEST_ROOT/evil-locks/locks/npu_device_0.lock" ]]

# Invalid or disabled timeout values must fall back to a finite deadline.
mkdir -p "$TEST_ROOT/fake-bin" "$REPO_DIR/runtime/state/running" "$REPO_DIR/runtime/state/usage"
cat >> "$REPO_DIR/runtime/config/taskqueue.conf" <<EOF
USAGE_SAMPLING_ENABLED=true
USAGE_SAMPLE_TIMEOUT=0
EOF
printf 'SUBMIT_USER=%s\nDEVICE=0\n' "$(id -un)" > "$REPO_DIR/runtime/state/running/task_sampler_test"
cat > "$TEST_ROOT/fake-bin/timeout" <<EOF
#!/usr/bin/env bash
printf '%s' "\$1" > "$TEST_ROOT/timeout-value"
shift
exec "\$@"
EOF
cat > "$TEST_ROOT/fake-bin/npu-smi" <<'EOF'
#!/usr/bin/env bash
printf 'NPU Utilization: 10\nAicore Usage Rate: 20\nHBM Usage Rate: 30\n'
EOF
chmod 755 "$TEST_ROOT/fake-bin/timeout" "$TEST_ROOT/fake-bin/npu-smi"
PATH="$TEST_ROOT/fake-bin:$PATH" bash "$REPO_DIR/pto-task-usage-sampler.sh"
[[ "$(<"$TEST_ROOT/timeout-value")" == 5 ]]

if bash "$REPO_DIR/tests/test_layout.sh" >/dev/null 2>&1; then
    echo 'error: layout test did not reject an existing source runtime' >&2
    exit 1
fi

bash "$REPO_DIR/tests/test_auto_update_retry.sh"

echo 'layout tests passed'
