#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

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
grep -Fxq 'DEVICE_GLOBAL_POOL=0,1,2,3' "$task_file"
grep -Fxq "DEVICE_GLOBAL_POOL_SOURCE=config:$CONFIG_FILE" "$task_file"

echo 'device policy tests passed'
