#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
fail() { echo "error: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }

# Exercise the scheduler without starting a daemon or touching device state.
source "$REPO_DIR/schedulers/_core.sh"
AVAILABLE_DEVICES="0,1,2,3,4,5,6,7"
DEVICE_GROUPS=""
SCHEDULER_TASK_ALLOCATION_POOLS="0,1,2,3;4,5,6,7"
SCHEDULER_TASK_GROUP_AFFINITY=0
IN_USE=""
scheduler_effective_pool() { printf '%s' "${1:-$AVAILABLE_DEVICES}"; }
any_device_in_use() {
    local id
    local -a ids
    IFS=',' read -ra ids <<< "$1"
    for id in "${ids[@]}"; do
        [[ ",$IN_USE," == *",$id,"* ]] && return 0
    done
    return 1
}
device_request_count() {
    local -a ids
    case "$1" in
        auto) printf 1 ;;
        auto:*) printf '%s' "${1#auto:}" ;;
        ""|none) printf 0 ;;
        *) IFS=',' read -ra ids <<< "$1"; printf '%s' "${#ids[@]}" ;;
    esac
}

IN_USE="0,1"
assert_eq "4,5,6,7" "$(scheduler_find_free_devices 4 '' '')" "back pool selected"
IN_USE="0,4"
scheduler_find_free_devices 4 '' '' >/dev/null && fail "combined two partial pools"
assert_eq "4" "$(scheduler_pool_capacity '')" "capacity is one pool, not both"
IN_USE="0"
assert_eq "1" "$(scheduler_find_free_devices 1 '' '')" "single-card task uses fragmented pool"
scheduler_devices_same_allocation_pool "0,3" || fail "rejected same-pool explicit request"
scheduler_devices_same_allocation_pool "0,4" && fail "accepted cross-pool explicit request"

PENDING_DIR="$TEST_ROOT/pending"
mkdir -p "$PENDING_DIR"
MAX_CONCURRENT=4
CURRENT_JOBS=0
MAX_CONCURRENT_8_CARD_TASKS=0
RUNNING_8_CARD_TASKS=0
STARTED=""
read_field() { sed -n "s/^$1=//p" "$2" | head -1; }
log() { :; }
start_pending_task() { STARTED="$3"; }
cat > "$PENDING_DIR/task_1" <<'EOF'
DEVICE=auto:4
DEVICE_POOL=0,1,2,3,4,5,6,7
DEVICE_ALLOCATION_POOLS=0,1,2,3;4,5,6,7
DEVICE_GROUP_AFFINITY=0
EOF
IN_USE=""
if scheduler_start_planned_task "$PENDING_DIR/task_1" task_1 auto:4 4 \
    0,1,2,3,4,5,6,7 0,1,4,5; then fail "claim-time check allowed cross-pool allocation"; fi
assert_eq "" "$STARTED" "cross-pool plan did not start"
scheduler_start_planned_task "$PENDING_DIR/task_1" task_1 auto:4 4 \
    0,1,2,3,4,5,6,7 4,5,6,7
assert_eq "4,5,6,7" "$STARTED" "same-pool plan started"

# Exercise the actual backfill queue walk: a blocked large task must not block
# a younger small task, while an available whole pool must satisfy the large one.
source "$REPO_DIR/schedulers/backfill.sh"
SCHEDULER_MODE=backfill
resolve_device_request() {
    scheduler_find_free_devices "$(device_request_count "$3")" "$4" ""
}
start_pending_task() {
    STARTED="${STARTED}${2}:${3};"
    CURRENT_JOBS=$((CURRENT_JOBS + 1))
    IN_USE="${IN_USE:+$IN_USE,}${3}"
}
cat > "$PENDING_DIR/task_2" <<'EOF'
DEVICE=auto:2
DEVICE_POOL=0,1,2,3,4,5,6,7
DEVICE_ALLOCATION_POOLS=0,1,2,3;4,5,6,7
DEVICE_GROUP_AFFINITY=0
EOF
IN_USE="0,4"
STARTED=""
scheduler_schedule_tick
assert_eq "task_2:1,2;" "$STARTED" "backfill starts small task while both pools are partial"

IN_USE="0,1"
CURRENT_JOBS=0
STARTED=""
scheduler_schedule_tick
assert_eq "task_1:4,5,6,7;task_2:2,3;" "$STARTED" \
    "backfill starts large task in the available pool, then small task in the other"

# Intersect logical pools with hardware affinity when both are present.
DEVICE_GROUPS="0,1;2,3;4,5,6,7"
SCHEDULER_TASK_GROUP_AFFINITY=1
IN_USE=""
assert_eq "4,5,6,7" "$(scheduler_find_free_devices 4 '' '')" "physical and logical constraints intersect"

# Exercise submission parsing and permanent-capacity rejection.
mkdir -p "$TEST_ROOT"/{config,project,state/{pending,running,done,locks,kill,fifo},logs}
cat > "$TEST_ROOT/config/taskqueue.conf" <<EOF
STATE_DIR="$TEST_ROOT/state"
LOGS_DIR="$TEST_ROOT/logs"
AVAILABLE_DEVICES="0,1,2,3,4,5,6,7"
MAX_CONCURRENT=4
EOF
cat > "$TEST_ROOT/project/task-submit.conf" <<'EOF'
DEVICE_WHITELIST="0,1,2,3;4,5,6,7"
EOF
submit() { (cd "$TEST_ROOT/project" && TASKQUEUE_CONF="$TEST_ROOT/config/taskqueue.conf" "$REPO_DIR/task-submit.sh" "$@"); }
task_id=$(submit --device auto --device-num 4 'echo hello')
task_file="$TEST_ROOT/state/pending/$task_id"
grep -Fxq 'DEVICE_POOL=0,1,2,3,4,5,6,7' "$task_file" || fail "flattened candidate pool missing"
grep -Fxq 'DEVICE_ALLOCATION_POOLS=0,1,2,3;4,5,6,7' "$task_file" || fail "logical pools missing"
explicit_id=$(submit --device 0,1 'echo explicit')
grep -Fxq 'DEVICE=0,1' "$TEST_ROOT/state/pending/$explicit_id" || fail "same-pool explicit request was not accepted"
status=$(submit --devices status)
grep -Fq '分池单次上限 4 张' <<< "$status" || fail "status did not show per-pool capacity"
[[ "$status" != *INVALID* ]] || fail "valid grouped whitelist was marked invalid"
ignored_status=$(submit --ignore-whitelist --devices status)
grep -Fq 'INVALID: 分池白名单不可使用 --ignore-whitelist' <<< "$ignored_status" || fail "status hid incompatible override"
if submit --device 0,4 'echo bad' >"$TEST_ROOT/out" 2>&1; then fail "accepted cross-pool explicit request"; fi
grep -Fq '不在同一个 DEVICE_WHITELIST 分池' "$TEST_ROOT/out" || fail "missing cross-pool error"
if submit --ignore-whitelist --device auto --device-num 4 'echo bad' >"$TEST_ROOT/out" 2>&1; then fail "override bypassed pools"; fi
grep -Fq '不支持 --ignore-whitelist' "$TEST_ROOT/out" || fail "missing override error"
cpu_id=$(submit --ignore-whitelist 'echo cpu-only')
grep -Fxq 'DEVICE=' "$TEST_ROOT/state/pending/$cpu_id" || fail "device-free task was blocked by grouping"
cat >> "$TEST_ROOT/project/task-submit.conf" <<'EOF'
DEVICE_SEQ_4=0,1,4,5
EOF
if submit --device auto --device-num 4 'echo bad' >"$TEST_ROOT/out" 2>&1; then fail "accepted cross-pool fixed sequence"; fi
grep -Fq '不在同一个 DEVICE_WHITELIST 分池' "$TEST_ROOT/out" || fail "missing sequence error"
cat > "$TEST_ROOT/project/task-submit.conf" <<'EOF'
DEVICE_WHITELIST="0,1,2,3;4,5,6,7"
DEVICE_SEQ_4=4,5,6,7
EOF
same_pool_id=$(submit --device auto --device-num 4 'echo same-pool')
grep -Fxq 'DEVICE=4,5,6,7' "$TEST_ROOT/state/pending/$same_pool_id" || fail "same-pool sequence was not accepted"

cat > "$TEST_ROOT/project/task-submit.conf" <<'EOF'
DEVICE_WHITELIST="0,1,2,3;4,5,6,7"
DEVICE_BLACKLIST=0,4
EOF
if submit --device auto --device-num 4 'echo bad' >"$TEST_ROOT/out" 2>&1; then fail "accepted impossible request"; fi
grep -Fq '最大的有效池只有 3 张' "$TEST_ROOT/out" || fail "missing capacity error"

cat > "$TEST_ROOT/project/task-submit.conf" <<'EOF'
DEVICE_WHITELIST="0,1,2,3;"
EOF
if submit --device auto --device-num 2 'echo bad' >"$TEST_ROOT/out" 2>&1; then fail "accepted trailing empty pool"; fi
grep -Fq '分池格式无效' "$TEST_ROOT/out" || fail "missing malformed-pool error"
bad_status=$(submit --devices status)
grep -Fq 'INVALID: DEVICE_WHITELIST 分池格式无效' <<< "$bad_status" || fail "status did not diagnose malformed pools"
cat > "$TEST_ROOT/project/task-submit.conf" <<'EOF'
DEVICE_WHITELIST="0,00;1,2"
EOF
if submit --device auto --device-num 2 'echo bad' >"$TEST_ROOT/out" 2>&1; then fail "accepted alias card id with leading zero"; fi
grep -Fq '分池格式无效' "$TEST_ROOT/out" || fail "missing canonical-card error"

cat >> "$TEST_ROOT/config/taskqueue.conf" <<'EOF'
DEVICE_GROUPS="0,1;2,3;4,5;6,7"
EOF
cat > "$TEST_ROOT/project/task-submit.conf" <<'EOF'
DEVICE_WHITELIST="0,1,2,3;4,5,6,7"
DEVICE_GROUP_AFFINITY=1
EOF
if submit --device auto --device-num 4 'echo bad' >"$TEST_ROOT/out" 2>&1; then fail "accepted impossible logical/physical intersection"; fi
grep -Fq '最大的有效池只有 2 张' "$TEST_ROOT/out" || fail "missing intersection capacity error"
if submit --ignore-group-affinity --device 0,4 'echo bad' >"$TEST_ROOT/out" 2>&1; then fail "hardware override bypassed logical pools"; fi
grep -Fq '不在同一个 DEVICE_WHITELIST 分池' "$TEST_ROOT/out" || fail "logical pool error missing under hardware override"

cat > "$TEST_ROOT/project/task-submit.conf" <<'EOF'
DEVICE_WHITELIST=0,1,2,3,4,5,6,7
EOF
legacy_id=$(submit --device auto --device-num 4 'echo legacy')
grep -Fxq 'DEVICE_ALLOCATION_POOLS=' "$TEST_ROOT/state/pending/$legacy_id" || fail "legacy format enabled grouping"
echo 'whitelist pool tests passed'
