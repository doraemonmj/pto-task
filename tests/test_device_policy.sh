#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
DAEMON_PID=""

cleanup() {
    if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

wait_for_done() {
    local task_id="$1"
    for _ in $(seq 1 100); do
        [[ -f "$STATE_DIR/done/$task_id" ]] && return 0
        sleep 0.05
    done
    echo "error: timed out waiting for $task_id" >&2
    return 1
}

STATE_DIR="$TEST_ROOT/state"
LOGS_DIR="$TEST_ROOT/logs"
CONFIG_DIR="$TEST_ROOT/config"
CONFIG_FILE="$CONFIG_DIR/taskqueue.conf"
PROJECT_DIR="$TEST_ROOT/project"
mkdir -p "$CONFIG_DIR" "$LOGS_DIR" "$PROJECT_DIR/subdir" \
    "$STATE_DIR"/{pending,running,done,locks,kill,fifo,usage}
install -m 666 /dev/null "$STATE_DIR/locks/update-reservation.lock"

cat > "$CONFIG_FILE" <<EOF
STATE_DIR="$STATE_DIR"
LOGS_DIR="$LOGS_DIR"
MAX_CONCURRENT=1
AVAILABLE_DEVICES="0,1,2,3"
EOF

cat > "$PROJECT_DIR/task-submit.conf" <<'EOF'
DEVICE_WHITELIST=1,2,4
DEVICE_BLACKLIST=2
DEVICE_SEQ_2=0,4
EOF

status_output=$(
    cd "$PROJECT_DIR/subdir"
    TASKQUEUE_CONF="$CONFIG_FILE" TASKQUEUE_DEVICE_POOL=3 \
        "$REPO_DIR/task-submit.sh" --devices status
)
grep -Fq "静态配置   [0,1,2,3] (4 张)" <<< "$status_output"
grep -Fq "仓库配置   $PROJECT_DIR/task-submit.conf" <<< "$status_output"
grep -Fq "最终 auto 候选 [1] (1 张)" <<< "$status_output"
grep -Fq "仓库白名单优先于 TASKQUEUE_DEVICE_POOL" <<< "$status_output"
grep -Fq "DEVICE_SEQ_2=[0,4] (2 张)" <<< "$status_output"
grep -Fq "[4] (1 张) 超出全局 auto 池" <<< "$status_output"

# Status is a diagnostic command: malformed lists must be identified at their
# source instead of being fed into the set calculations and producing a
# plausible but incorrect final candidate pool.
INVALID_DIR="$TEST_ROOT/invalid"
mkdir -p "$INVALID_DIR"
cat > "$INVALID_DIR/task-submit.conf" <<'EOF'
DEVICE_WHITELIST=0,not-a-device
DEVICE_BLACKLIST=2,2
DEVICE_SEQ_2=0,0
EOF
invalid_output=$(
    cd "$INVALID_DIR"
    TASKQUEUE_CONF="$CONFIG_FILE" "$REPO_DIR/task-submit.sh" --devices status
)
grep -Fq 'INVALID: DEVICE_WHITELIST 格式无效' <<< "$invalid_output"
grep -Fq '警告: DEVICE_BLACKLIST 包含重复卡号 [2]' <<< "$invalid_output"
grep -Fq '最终 auto 候选无法计算' <<< "$invalid_output"
grep -Fq 'INVALID: 配置了 1 张不同的卡，但键名要求 2 张' <<< "$invalid_output"
grep -Fq 'INVALID: 包含重复卡号 [0]' <<< "$invalid_output"

# Invalid inactive sources remain visible but must not make the displayed
# result diverge from the historical precedence used for real submissions.
overridden_env_output=$(
    cd "$PROJECT_DIR/subdir"
    TASKQUEUE_CONF="$CONFIG_FILE" TASKQUEUE_DEVICE_POOL=not-a-device \
        "$REPO_DIR/task-submit.sh" --devices status
)
grep -Fq 'INVALID: TASKQUEUE_DEVICE_POOL 格式无效' <<< "$overridden_env_output"
grep -Fq '最终 auto 候选 [1] (1 张)' <<< "$overridden_env_output"
if grep -Fq '最终 auto 候选无法计算' <<< "$overridden_env_output"; then
    echo 'error: overridden invalid environment pool blocked status calculation' >&2
    exit 1
fi

ignored_whitelist_output=$(
    cd "$INVALID_DIR"
    TASKQUEUE_CONF="$CONFIG_FILE" "$REPO_DIR/task-submit.sh" \
        --ignore-whitelist --devices status
)
grep -Fq 'INVALID: DEVICE_WHITELIST 格式无效' <<< "$ignored_whitelist_output"
grep -Fq '最终 auto 候选 [0,1,3] (3 张)' <<< "$ignored_whitelist_output"
if grep -Fq '最终 auto 候选无法计算' <<< "$ignored_whitelist_output"; then
    echo 'error: explicitly ignored invalid whitelist blocked status calculation' >&2
    exit 1
fi

printf '2,3\n' > "$STATE_DIR/available_devices"
runtime_output=$(
    cd "$PROJECT_DIR/subdir"
    TASKQUEUE_CONF="$CONFIG_FILE" "$REPO_DIR/task-submit.sh" --devices list
)
grep -Fq "当前可用设备白名单: 2,3" <<< "$runtime_output"
grep -Fq "运行时覆盖 [2,3] (2 张)" <<< "$runtime_output"
grep -Fq "静态配置   [0,1,2,3] (4 张)" <<< "$runtime_output"
grep -Fq "被运行时覆盖" <<< "$runtime_output"
grep -Fq "各层策略交集为空" <<< "$runtime_output"

BAD_CONFIG_FILE="$CONFIG_DIR/bad-static.conf"
NO_PROJECT_POLICY_DIR="$TEST_ROOT/no-project-policy"
mkdir -p "$NO_PROJECT_POLICY_DIR"
cat > "$BAD_CONFIG_FILE" <<EOF
STATE_DIR="$STATE_DIR"
LOGS_DIR="$LOGS_DIR"
MAX_CONCURRENT=1
AVAILABLE_DEVICES="not-a-device"
EOF
inactive_static_output=$(
    cd "$NO_PROJECT_POLICY_DIR"
    TASKQUEUE_CONF="$BAD_CONFIG_FILE" "$REPO_DIR/task-submit.sh" --devices status
)
grep -Fq 'INVALID: AVAILABLE_DEVICES 格式无效' <<< "$inactive_static_output"
grep -Fq '全局生效池 [2,3] (2 张)' <<< "$inactive_static_output"
grep -Fq '最终 auto 候选 [2,3] (2 张)' <<< "$inactive_static_output"
if grep -Fq '最终 auto 候选无法计算' <<< "$inactive_static_output"; then
    echo 'error: overridden invalid static pool blocked status calculation' >&2
    exit 1
fi

: > "$STATE_DIR/available_devices"
empty_runtime_output=$(
    cd "$PROJECT_DIR/subdir"
    TASKQUEUE_CONF="$CONFIG_FILE" "$REPO_DIR/task-submit.sh" --devices status
)
grep -Fq "运行时文件为空，回退静态配置 $CONFIG_FILE" <<< "$empty_runtime_output"
grep -Fq "全局生效池 [0,1,2,3] (4 张)" <<< "$empty_runtime_output"
rm -f "$STATE_DIR/available_devices"

# Submission-side validation must honor configured AVAILABLE_DEVICES when no
# runtime override file exists, matching the daemon instead of auto-detection.
CONFLICT_DIR="$TEST_ROOT/conflict"
mkdir -p "$CONFLICT_DIR"
cat > "$CONFLICT_DIR/task-submit.conf" <<'EOF'
DEVICE_WHITELIST=4,5
EOF
if conflict_output=$(
    cd "$CONFLICT_DIR"
    TASKQUEUE_CONF="$CONFIG_FILE" "$REPO_DIR/task-submit.sh" \
        --device auto --device-num 1 'true' 2>&1
); then
    echo 'error: static global auto pool conflict was accepted' >&2
    exit 1
fi
grep -Fq "与系统可用设备白名单 [0,1,2,3] 无交集" <<< "$conflict_output"
grep -Fq "config:$CONFIG_FILE" <<< "$conflict_output"

# Preserve legacy DEVICE_SEQ behavior while recording how the concrete request
# was derived so pending/running/done metadata remains diagnosable.
SEQUENCE_DIR="$TEST_ROOT/sequence"
mkdir -p "$SEQUENCE_DIR"
cat > "$SEQUENCE_DIR/task-submit.conf" <<'EOF'
DEVICE_WHITELIST=0,1,2,3
DEVICE_SEQ_2=0,2
EOF
task_id=$(
    cd "$SEQUENCE_DIR"
    TASKQUEUE_CONF="$CONFIG_FILE" "$REPO_DIR/task-submit.sh" \
        --device auto --device-num 2 'true'
)
task_file="$STATE_DIR/pending/$task_id"
grep -Fxq 'DEVICE=0,2' "$task_file"
grep -Fxq 'DEVICE_AUTO=0' "$task_file"
grep -Fxq 'DEVICE_REQUEST_RAW=auto:2' "$task_file"
grep -Fxq 'DEVICE_REQUEST_ORIGIN=sequence' "$task_file"
grep -Fxq "DEVICE_SEQUENCE_SOURCE=DEVICE_SEQ_2@$SEQUENCE_DIR/task-submit.conf" "$task_file"
grep -Fxq "DEVICE_POLICY_CONF=$SEQUENCE_DIR/task-submit.conf" "$task_file"
grep -Fxq 'DEVICE_POLICY_WHITELIST=0,1,2,3' "$task_file"
grep -Fxq 'DEVICE_POLICY_BLACKLIST=' "$task_file"
grep -Fxq 'DEVICE_POLICY_IGNORE_WHITELIST=0' "$task_file"
grep -Fxq 'DEVICE_POLICY_ENV_POOL=' "$task_file"
grep -Fxq 'DEVICE_GLOBAL_POOL=0,1,2,3' "$task_file"
grep -Fxq "DEVICE_GLOBAL_POOL_SOURCE=config:$CONFIG_FILE" "$task_file"

# Keep the original repository lists and the override switch, even though the
# active policy mutates/ignores the whitelist while deriving the request.
IGNORE_DIR="$TEST_ROOT/ignore"
mkdir -p "$IGNORE_DIR"
cat > "$IGNORE_DIR/task-submit.conf" <<'EOF'
DEVICE_WHITELIST=0
DEVICE_BLACKLIST=3
DEVICE_SEQ_1=1
EOF
ignore_task_id=$(
    cd "$IGNORE_DIR"
    TASKQUEUE_CONF="$CONFIG_FILE" TASKQUEUE_DEVICE_POOL=2 \
        "$REPO_DIR/task-submit.sh" --ignore-whitelist \
        --device auto --device-num 1 'true'
)
ignore_task_file="$STATE_DIR/pending/$ignore_task_id"
grep -Fxq 'DEVICE=1' "$ignore_task_file"
grep -Fxq 'DEVICE_REQUEST_RAW=auto' "$ignore_task_file"
grep -Fxq 'DEVICE_REQUEST_ORIGIN=sequence' "$ignore_task_file"
grep -Fxq 'DEVICE_POLICY_WHITELIST=0' "$ignore_task_file"
grep -Fxq 'DEVICE_POLICY_BLACKLIST=3' "$ignore_task_file"
grep -Fxq 'DEVICE_POLICY_IGNORE_WHITELIST=1' "$ignore_task_file"
grep -Fxq 'DEVICE_POLICY_ENV_POOL=2' "$ignore_task_file"

# Exercise the real daemon state transitions. npu_lock.sh only takes temporary
# filesystem locks here; this test does not query a device-management interface.
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -c && "$2" == %u ]] &&
   [[ "$3" == "$DEVICE_POLICY_TEST_CONFIG_DIR" || "$3" == "$DEVICE_POLICY_TEST_CONFIG" ]]; then
    printf '0\n'
elif [[ "$1" == -c && "$2" == %a && "$3" == "$DEVICE_POLICY_TEST_CONFIG_DIR" ]]; then
    printf '755\n'
elif [[ "$1" == -c && "$2" == %a && "$3" == "$DEVICE_POLICY_TEST_CONFIG" ]]; then
    printf '644\n'
else
    exec /usr/bin/stat "$@"
fi
EOF
cat > "$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == -u ]]; then
    printf '0\n'
else
    exec /usr/bin/id "$@"
fi
EOF
chmod 755 "$FAKE_BIN/stat" "$FAKE_BIN/id"

DEVICE_POLICY_TEST_CONFIG_DIR="$CONFIG_DIR" \
DEVICE_POLICY_TEST_CONFIG="$CONFIG_FILE" \
TASKQUEUE_ALLOW_USER=1 TASKQUEUE_CONF="$CONFIG_FILE" \
PATH="$FAKE_BIN:$PATH" bash "$REPO_DIR/task-daemon.sh" &
DAEMON_PID=$!
wait_for_done "$task_id"
wait_for_done "$ignore_task_id"
kill -TERM "$DAEMON_PID"
wait "$DAEMON_PID" || true
DAEMON_PID=""

done_file="$STATE_DIR/done/$task_id"
grep -Fxq 'DEVICE_POLICY_WHITELIST=0,1,2,3' "$done_file"
grep -Fxq 'DEVICE_POLICY_BLACKLIST=' "$done_file"
grep -Fxq 'DEVICE_POLICY_IGNORE_WHITELIST=0' "$done_file"
grep -Fxq 'DEVICE_POLICY_ENV_POOL=' "$done_file"

ignore_done_file="$STATE_DIR/done/$ignore_task_id"
grep -Fxq 'DEVICE_POLICY_WHITELIST=0' "$ignore_done_file"
grep -Fxq 'DEVICE_POLICY_BLACKLIST=3' "$ignore_done_file"
grep -Fxq 'DEVICE_POLICY_IGNORE_WHITELIST=1' "$ignore_done_file"
grep -Fxq 'DEVICE_POLICY_ENV_POOL=2' "$ignore_done_file"

echo 'device policy tests passed'
