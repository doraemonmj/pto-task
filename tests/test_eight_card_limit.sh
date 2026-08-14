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

wait_for_path() {
    local path="$1"
    for _ in $(seq 1 100); do
        [[ -e "$path" ]] && return 0
        sleep 0.05
    done
    echo "error: timed out waiting for $path" >&2
    return 1
}

# task-daemon requires a production config to be root-owned. This wrapper only
# fakes those four startup metadata reads, allowing the integration scenario to
# run unprivileged; all runtime stat calls still use the real binary.
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -c && "$2" == %u ]] &&
   [[ "$3" == "$EIGHT_CARD_TEST_CONFIG_DIR" || "$3" == "$EIGHT_CARD_TEST_CONFIG" ]]; then
    printf '0\n'
elif [[ "$1" == -c && "$2" == %a && "$3" == "$EIGHT_CARD_TEST_CONFIG_DIR" ]]; then
    printf '755\n'
elif [[ "$1" == -c && "$2" == %a && "$3" == "$EIGHT_CARD_TEST_CONFIG" ]]; then
    printf '644\n'
else
    exec /usr/bin/stat "$@"
fi
EOF
chmod 755 "$FAKE_BIN/stat"
cat > "$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == -u ]]; then
    printf '0\n'
else
    exec /usr/bin/id "$@"
fi
EOF
chmod 755 "$FAKE_BIN/id"

run_enabled_case() {
    local case_root="$TEST_ROOT/enabled"
    local state="$case_root/state"
    local logs="$case_root/logs"
    local config_dir="$case_root/config"
    local config="$config_dir/taskqueue.conf"
    local release="$case_root/release"
    local small_started="$case_root/small-started"
    local second_started="$case_root/second-started"
    mkdir -p "$config_dir" "$logs" "$state"/{pending,running,done,locks,kill,fifo,usage}
    chmod 1777 "$state"/{pending,locks,kill,fifo}
    cat > "$config" <<EOF
STATE_DIR="$state"
LOGS_DIR="$logs"
MAX_CONCURRENT=3
MAX_CONCURRENT_8_CARD_TASKS=1
MAX_TIME_HARD_CAP=0
TASK_EXECUTION_MODE=root
AVAILABLE_DEVICES="0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15"
EOF

    cat > "$state/pending/task_20260101_000001_1" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:01+00:00
WORK_DIR=$case_root
COMMAND=while [[ ! -f '$release' ]]; do sleep 0.05; done
DEVICE=0,1,2,3,4,5,6,7
DEVICE_AUTO=0
DEVICE_POOL=
MAX_TIME=0
INTERACTIVE=0
EOF
    cat > "$state/pending/task_20260101_000002_2" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:02+00:00
WORK_DIR=$case_root
COMMAND=: > '$second_started'
DEVICE=8,9,10,11,12,13,14,15
DEVICE_AUTO=0
DEVICE_POOL=
MAX_TIME=0
INTERACTIVE=0
EOF
    cat > "$state/pending/task_20260101_000003_3" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:03+00:00
WORK_DIR=$case_root
COMMAND=: > '$small_started'
DEVICE=8
DEVICE_AUTO=0
DEVICE_POOL=
MAX_TIME=0
INTERACTIVE=0
EOF
    chmod 644 "$state/pending"/task_*

    EIGHT_CARD_TEST_CONFIG_DIR="$config_dir" \
    EIGHT_CARD_TEST_CONFIG="$config" \
    TASKQUEUE_ALLOW_USER=1 TASKQUEUE_CONF="$config" \
    PATH="$FAKE_BIN:$PATH" bash "$REPO_DIR/task-daemon.sh" &
    DAEMON_PID=$!

    wait_for_path "$small_started"
    [[ ! -e "$second_started" ]]
    [[ -f "$state/pending/task_20260101_000002_2" ]]
    if grep -Fq 'eight-card task(s) may run concurrently' "$logs/taskqueue.log"; then
        echo 'error: eight-card queue policy emitted repeated daemon log output' >&2
        return 1
    fi

    touch "$release"
    wait_for_path "$second_started"
    kill -TERM "$DAEMON_PID"
    wait "$DAEMON_PID" || true
    DAEMON_PID=""

    local notice
    notice=$(TASKQUEUE_CONF="$config" "$REPO_DIR/task-submit.sh" \
        --device 0,1,2,3,4,5,6,7 'true' 2>&1 >/dev/null)
    grep -Fq '当前服务器同时只运行一个 8 卡用例' <<< "$notice"
}

run_disabled_case() {
    local case_root="$TEST_ROOT/disabled"
    local state="$case_root/state"
    local logs="$case_root/logs"
    local config_dir="$case_root/config"
    local config="$config_dir/taskqueue.conf"
    local release="$case_root/release"
    local second_started="$case_root/second-started"
    mkdir -p "$config_dir" "$logs" "$state"/{pending,running,done,locks,kill,fifo,usage}
    chmod 1777 "$state"/{pending,locks,kill,fifo}
    # Deliberately omit MAX_CONCURRENT_8_CARD_TASKS: an existing server that
    # auto-updates code must retain the historical unlimited behavior.
    cat > "$config" <<EOF
STATE_DIR="$state"
LOGS_DIR="$logs"
MAX_CONCURRENT=2
MAX_TIME_HARD_CAP=0
TASK_EXECUTION_MODE=root
AVAILABLE_DEVICES="0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15"
EOF
    cat > "$state/pending/task_20260101_000001_1" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:01+00:00
WORK_DIR=$case_root
COMMAND=while [[ ! -f '$release' ]]; do sleep 0.05; done
DEVICE=0,1,2,3,4,5,6,7
DEVICE_AUTO=0
DEVICE_POOL=
MAX_TIME=0
INTERACTIVE=0
EOF
    cat > "$state/pending/task_20260101_000002_2" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:02+00:00
WORK_DIR=$case_root
COMMAND=: > '$second_started'
DEVICE=8,9,10,11,12,13,14,15
DEVICE_AUTO=0
DEVICE_POOL=
MAX_TIME=0
INTERACTIVE=0
EOF
    chmod 644 "$state/pending"/task_*

    EIGHT_CARD_TEST_CONFIG_DIR="$config_dir" \
    EIGHT_CARD_TEST_CONFIG="$config" \
    TASKQUEUE_ALLOW_USER=1 TASKQUEUE_CONF="$config" \
    PATH="$FAKE_BIN:$PATH" bash "$REPO_DIR/task-daemon.sh" &
    DAEMON_PID=$!

    wait_for_path "$second_started"
    touch "$release"
    kill -TERM "$DAEMON_PID"
    wait "$DAEMON_PID" || true
    DAEMON_PID=""
}

grep -Fq 'MAX_CONCURRENT_8_CARD_TASKS=0' "$REPO_DIR/config/default.conf"
run_enabled_case
run_disabled_case

echo 'eight-card limit tests passed'
