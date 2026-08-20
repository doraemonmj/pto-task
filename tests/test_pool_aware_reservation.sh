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
    for _ in $(seq 1 120); do
        [[ -e "$path" ]] && return 0
        sleep 0.05
    done
    echo "error: timed out waiting for $path" >&2
    return 1
}

stop_daemon() {
    kill -TERM "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    DAEMON_PID=""
}

# Source-layout integration tests run unprivileged, while daemon startup still
# checks production config ownership. Fake only those startup metadata reads.
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -c && "$2" == %u ]] &&
   [[ "$3" == "$POOL_RESERVATION_TEST_CONFIG_DIR" || "$3" == "$POOL_RESERVATION_TEST_CONFIG" ]]; then
    printf '0\n'
elif [[ "$1" == -c && "$2" == %a && "$3" == "$FAIR_TEST_CONFIG_DIR" ]]; then
    printf '755\n'
elif [[ "$1" == -c && "$2" == %a && "$3" == "$FAIR_TEST_CONFIG" ]]; then
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

start_daemon() {
    local config="$1"
    POOL_RESERVATION_TEST_CONFIG_DIR="$(dirname "$config")" \
    POOL_RESERVATION_TEST_CONFIG="$config" TASKQUEUE_ALLOW_USER=1 \
    TASKQUEUE_CONF="$config" PATH="$FAKE_BIN:$PATH" \
        bash "$REPO_DIR/task-daemon.sh" &
    DAEMON_PID=$!
}

prepare_case() {
    local case_root="$1" scheduler="$2" min_devices="${3:-2}"
    local available_devices="${4:-0,1,2,3,4,5,6,7}"
    local state="$case_root/state" logs="$case_root/logs" config_dir="$case_root/config"
    mkdir -p "$config_dir" "$logs" "$state"/{pending,running,done,locks,kill,fifo,usage}
    chmod 1777 "$state"/{pending,locks,kill,fifo}
    cat > "$config_dir/taskqueue.conf" <<EOF
STATE_DIR="$state"
LOGS_DIR="$logs"
MAX_CONCURRENT=4
SCHEDULER_MODE="$scheduler"
POOL_AWARE_RESERVATION_MIN_DEVICES=$min_devices
MAX_CONCURRENT_8_CARD_TASKS=0
MAX_TIME_HARD_CAP=0
TASK_EXECUTION_MODE=root
AVAILABLE_DEVICES="$available_devices"
EOF
}

run_accumulation_case() {
    local case_root="$TEST_ROOT/accumulation"
    local state="$case_root/state" config="$case_root/config/taskqueue.conf"
    local release_blocker="$case_root/release-blocker" release_large="$case_root/release-large"
    local blocker_started="$case_root/blocker-started" large_started="$case_root/large-started"
    local small_started="$case_root/small-started" disjoint_started="$case_root/disjoint-started"
    local cpu_started="$case_root/cpu-started"
    prepare_case "$case_root" pool_aware_reservation 2

    cat > "$state/pending/task_20260101_000001_1" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:01+00:00
WORK_DIR=$case_root
COMMAND=touch '$blocker_started'; while [[ ! -f '$release_blocker' ]]; do sleep 0.05; done
DEVICE=0,1
DEVICE_AUTO=0
DEVICE_POOL=
MAX_TIME=0
INTERACTIVE=0
EOF
    cat > "$state/pending/task_20260101_000002_2" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:02+00:00
WORK_DIR=$case_root
COMMAND=touch '$large_started'; while [[ ! -f '$release_large' ]]; do sleep 0.05; done
DEVICE=auto:4
DEVICE_AUTO=1
DEVICE_POOL=0,1,2,3
MAX_TIME=0
INTERACTIVE=0
EOF
    cat > "$state/pending/task_20260101_000003_3" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:03+00:00
WORK_DIR=$case_root
COMMAND=touch '$disjoint_started'; true
DEVICE=auto:2
DEVICE_AUTO=1
DEVICE_POOL=4,5
MAX_TIME=0
INTERACTIVE=0
EOF
    cat > "$state/pending/task_20260101_000004_4" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:04+00:00
WORK_DIR=$case_root
COMMAND=touch '$small_started'; true
DEVICE=auto
DEVICE_AUTO=1
DEVICE_POOL=0,1,2,3
MAX_TIME=0
INTERACTIVE=0
EOF
    cat > "$state/pending/task_20260101_000005_5" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:05+00:00
WORK_DIR=$case_root
COMMAND=touch '$cpu_started'
DEVICE=none
DEVICE_AUTO=0
DEVICE_POOL=
MAX_TIME=0
INTERACTIVE=0
EOF
    chmod 644 "$state/pending"/task_*

    start_daemon "$config"
    wait_for_path "$blocker_started"
    wait_for_path "$disjoint_started"
    wait_for_path "$state/done/task_20260101_000003_3"
    grep -Fq 'DEVICE=4,5' "$state/done/task_20260101_000003_3"
    wait_for_path "$cpu_started"
    [[ ! -e "$small_started" ]]
    [[ -f "$state/pending/task_20260101_000004_4" ]]

    touch "$release_blocker"
    wait_for_path "$large_started"
    [[ ! -e "$small_started" ]]
    [[ -f "$state/pending/task_20260101_000004_4" ]]

    touch "$release_large"
    wait_for_path "$small_started"
    stop_daemon

    [[ "$(grep -c 'reserve: task_20260101_000002_2 waiting for 4 devices' "$case_root/logs/taskqueue.log")" -eq 1 ]]
    grep -Fq 'reserve: task_20260101_000002_2 acquired its devices' "$case_root/logs/taskqueue.log"
}

run_impossible_request_case() {
    local case_root="$TEST_ROOT/impossible"
    local state="$case_root/state" config="$case_root/config/taskqueue.conf"
    local small_started="$case_root/small-started"
    prepare_case "$case_root" pool_aware_reservation 2

    cat > "$state/pending/task_20260101_000001_1" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:01+00:00
WORK_DIR=$case_root
COMMAND=true
DEVICE=auto:5
DEVICE_AUTO=1
DEVICE_POOL=0,1,2,3
MAX_TIME=0
INTERACTIVE=0
EOF
    cat > "$state/pending/task_20260101_000002_2" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:02+00:00
WORK_DIR=$case_root
COMMAND=touch '$small_started'; true
DEVICE=auto
DEVICE_AUTO=1
DEVICE_POOL=
MAX_TIME=0
INTERACTIVE=0
EOF
    chmod 644 "$state/pending"/task_*

    start_daemon "$config"
    wait_for_path "$small_started"
    [[ -f "$state/pending/task_20260101_000001_1" ]]
    stop_daemon
}

run_shared_capacity_case() {
    local large_count="$1" expect_concurrent="$2"
    local case_root="$TEST_ROOT/shared-$large_count"
    local state="$case_root/state" config="$case_root/config/taskqueue.conf"
    local release_large="$case_root/release-large" release_small="$case_root/release-small"
    local large_started="$case_root/large-started" small_started="$case_root/small-started"
    prepare_case "$case_root" pool_aware_reservation 2 "0,1,2,3,4"

    cat > "$state/pending/task_20260101_000001_1" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:01+00:00
WORK_DIR=$case_root
COMMAND=touch '$large_started'; while [[ ! -f '$release_large' ]]; do sleep 0.05; done
DEVICE=auto:$large_count
DEVICE_AUTO=1
DEVICE_POOL=0,1,2,3,4
MAX_TIME=0
INTERACTIVE=0
EOF
    cat > "$state/pending/task_20260101_000002_2" <<EOF
SUBMIT_USER=$(id -un)
SUBMIT_TIME=2026-01-01T00:00:02+00:00
WORK_DIR=$case_root
COMMAND=touch '$small_started'; while [[ ! -f '$release_small' ]]; do sleep 0.05; done
DEVICE=auto:2
DEVICE_AUTO=1
DEVICE_POOL=0,1,2,3,4
MAX_TIME=0
INTERACTIVE=0
EOF
    chmod 644 "$state/pending"/task_*

    start_daemon "$config"
    wait_for_path "$large_started"
    if [[ "$expect_concurrent" == 1 ]]; then
        # 3 + 2 exactly fits the shared five-card pool.
        wait_for_path "$small_started"
    else
        # 4 + 2 exceeds the shared pool, so the younger task must wait.
        sleep 0.5
        [[ ! -e "$small_started" ]]
        [[ -f "$state/pending/task_20260101_000002_2" ]]
    fi

    touch "$release_large"
    wait_for_path "$small_started"
    touch "$release_small"
    stop_daemon
}

run_invalid_config_case() {
    local case_root="$TEST_ROOT/invalid-config"
    local config="$case_root/config/taskqueue.conf" output
    prepare_case "$case_root" pool_aware_reservation 1
    if output=$(POOL_RESERVATION_TEST_CONFIG_DIR="$(dirname "$config")" POOL_RESERVATION_TEST_CONFIG="$config" \
        TASKQUEUE_ALLOW_USER=1 TASKQUEUE_CONF="$config" PATH="$FAKE_BIN:$PATH" \
        bash "$REPO_DIR/task-daemon.sh" 2>&1); then
        echo 'error: daemon accepted POOL_AWARE_RESERVATION_MIN_DEVICES=1' >&2
        return 1
    fi
    grep -Fq 'POOL_AWARE_RESERVATION_MIN_DEVICES must be an integer greater than or equal to 2' <<< "$output"
}

run_accumulation_case
run_impossible_request_case
run_shared_capacity_case 4 0
run_shared_capacity_case 3 1
run_invalid_config_case

echo 'pool-aware reservation tests passed'
