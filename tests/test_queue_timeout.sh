#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
DAEMON_PID=""
cleanup() {
    if [[ -n "$DAEMON_PID" ]]; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

STATE_DIR="$TEST_ROOT/state"
LOGS_DIR="$TEST_ROOT/logs"
mkdir -p "$TEST_ROOT/config" "$LOGS_DIR" "$STATE_DIR"/{pending,running,done,kill,fifo}
cat > "$TEST_ROOT/config/taskqueue.conf" <<EOF
STATE_DIR="$STATE_DIR"
LOGS_DIR="$LOGS_DIR"
EOF
# Queue time is bounded and a timed-out pending task is canceled with its env.
queue_id=task_20260101_000001_1
touch "$STATE_DIR/pending/$queue_id" "$STATE_DIR/pending/$queue_id.env"
if timeout 8 bash -c 'TASKQUEUE_CONF="$1" bash "$2" --timeout 1 --wait "$3"' \
    _ "$TEST_ROOT/config/taskqueue.conf" "$REPO_DIR/task-submit.sh" "$queue_id" \
    > "$TEST_ROOT/queue.out" 2>&1; then
    echo 'error: pending task did not time out' >&2
    exit 1
fi
grep -Fq '排队等待超时 (1s)' "$TEST_ROOT/queue.out"
[[ ! -e "$STATE_DIR/pending/$queue_id" && ! -e "$STATE_DIR/pending/$queue_id.env" ]]

# A daemon claim during cancellation must keep the task's environment snapshot.
race_id=task_20260101_000004_4
race_bin="$TEST_ROOT/race-bin"
mkdir -p "$race_bin"
touch "$STATE_DIR/pending/$race_id" "$STATE_DIR/pending/$race_id.env"
cat > "$race_bin/rm" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -f && "${2:-}" == "$RACE_PENDING" ]]; then
    mv "$RACE_PENDING" "$RACE_RUNNING"
fi
exec /usr/bin/rm "$@"
EOF
chmod 755 "$race_bin/rm"
(
    while [[ ! -f "$STATE_DIR/running/$race_id" ]]; do sleep 0.05; done
    mv "$STATE_DIR/pending/$race_id.env" "$STATE_DIR/running/$race_id.env"
    printf 'task started\n' > "$LOGS_DIR/$race_id.log"
    printf 'EXIT_CODE=0\n' > "$STATE_DIR/done/$race_id"
) &
transition_pid=$!
timeout 8 env TASKQUEUE_CONF="$TEST_ROOT/config/taskqueue.conf" \
    RACE_PENDING="$STATE_DIR/pending/$race_id" \
    RACE_RUNNING="$STATE_DIR/running/$race_id" PATH="$race_bin:$PATH" \
    bash "$REPO_DIR/task-submit.sh" --timeout 1 --wait "$race_id" \
    > "$TEST_ROOT/race.out" 2>&1
wait "$transition_pid"
[[ -f "$STATE_DIR/running/$race_id.env" ]] || {
    echo 'error: daemon claim lost the environment snapshot' >&2
    exit 1
}

# A queued task starts before its queue deadline, then runs beyond that deadline.
running_id=task_20260101_000002_2
touch "$STATE_DIR/pending/$running_id"
(
    sleep 0.4
    mv "$STATE_DIR/pending/$running_id" "$STATE_DIR/running/$running_id"
    printf 'task started\n' > "$LOGS_DIR/$running_id.log"
    sleep 1.2
    printf 'EXIT_CODE=0\n' > "$STATE_DIR/done/$running_id"
    rm "$STATE_DIR/running/$running_id"
) &
transition_pid=$!
timeout 8 bash -c 'TASKQUEUE_CONF="$1" bash "$2" --timeout 1 --wait "$3"' \
    _ "$TEST_ROOT/config/taskqueue.conf" "$REPO_DIR/task-submit.sh" "$running_id" \
    > "$TEST_ROOT/running.out" 2>&1
wait "$transition_pid"
grep -Fq '任务完成 (exit=0)' "$TEST_ROOT/running.out"
if grep -Fq '排队等待超时' "$TEST_ROOT/running.out"; then
    echo 'error: running task consumed queue timeout' >&2
    exit 1
fi

# Reconnecting to a running task has no queue budget; its exit code survives.
reconnect_id=task_20260101_000003_3
touch "$STATE_DIR/running/$reconnect_id"
printf 'task started\n' > "$LOGS_DIR/$reconnect_id.log"
(
    sleep 1.2
    printf 'EXIT_CODE=7\n' > "$STATE_DIR/done/$reconnect_id"
    rm "$STATE_DIR/running/$reconnect_id"
) &
transition_pid=$!
set +e
timeout 8 bash -c 'TASKQUEUE_CONF="$1" bash "$2" --timeout 1 --wait "$3"' \
    _ "$TEST_ROOT/config/taskqueue.conf" "$REPO_DIR/task-submit.sh" "$reconnect_id" \
    > "$TEST_ROOT/reconnect.out" 2>&1
exit_code=$?
set -e
wait "$transition_pid"
[[ "$exit_code" -eq 7 ]] || { echo "error: running task returned $exit_code instead of 7" >&2; exit 1; }
grep -Fq '任务失败 (exit=7)' "$TEST_ROOT/reconnect.out"

# The daemon still enforces --max-time on a CPU-only task after it starts.
daemon_root="$TEST_ROOT/daemon"
daemon_state="$daemon_root/state"
daemon_logs="$daemon_root/logs"
daemon_config="$daemon_root/config/taskqueue.conf"
fake_bin="$daemon_root/fake-bin"
mkdir -p "$daemon_root/config" "$daemon_logs" "$fake_bin" \
    "$daemon_state"/{pending,running,done,locks,kill,fifo,usage}
chmod 1777 "$daemon_state"/{pending,locks,kill,fifo}
cat > "$daemon_config" <<EOF
STATE_DIR="$daemon_state"
LOGS_DIR="$daemon_logs"
MAX_CONCURRENT=1
SCHEDULER_MODE=backfill
TASK_EXECUTION_MODE=root
AVAILABLE_DEVICES="0"
EOF
cat > "$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == -u ]]; then
    printf '0\n'
else
    exec /usr/bin/id "$@"
fi
EOF
cat > "$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -c && "$2" == %u ]] &&
   [[ "$3" == "$QUEUE_TIMEOUT_CONFIG_DIR" || "$3" == "$QUEUE_TIMEOUT_CONFIG" ]]; then
    printf '0\n'
else
    exec /usr/bin/stat "$@"
fi
EOF
chmod 755 "$fake_bin"/{id,stat}
QUEUE_TIMEOUT_CONFIG_DIR="$daemon_root/config" \
QUEUE_TIMEOUT_CONFIG="$daemon_config" TASKQUEUE_ALLOW_USER=1 \
TASKQUEUE_CONF="$daemon_config" PATH="$fake_bin:$PATH" \
    bash "$REPO_DIR/task-daemon.sh" &
DAEMON_PID=$!
set +e
timeout 10 env TASKQUEUE_CONF="$daemon_config" bash "$REPO_DIR/task-submit.sh" \
    --timeout 1 --max-time 1 --run 'sleep 3' > "$TEST_ROOT/max-time.out" 2>&1
exit_code=$?
set -e
[[ "$exit_code" -eq 143 ]] || {
    echo "error: execution watchdog returned $exit_code instead of 143" >&2
    cat "$TEST_ROOT/max-time.out" >&2
    exit 1
}
grep -Fq '任务超时 (1s)' "$TEST_ROOT/max-time.out"
if grep -Fq '排队等待超时' "$TEST_ROOT/max-time.out"; then
    echo 'error: execution timeout was reported as queue timeout' >&2
    exit 1
fi

echo 'queue timeout tests passed'
