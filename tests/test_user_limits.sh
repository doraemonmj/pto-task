#!/usr/bin/env bash
# Isolated CLI and daemon integration. All device workloads are file markers;
# no NPU management interface or runtime is invoked.
set -euo pipefail
if [[ -z "${USER_LIMIT_TEST_MODE:-}" ]]; then
    for mode in backfill pool_aware_reservation; do
        USER_LIMIT_TEST_MODE="$mode" bash "$0"
    done
    exit 0
fi
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
DAEMON_PID=""
cleanup() {
    if [[ -n "$DAEMON_PID" ]]; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
export LIMIT_TEST_ROOT="$TEST_ROOT"
ACTUAL_UID=$(id -u)
ACTUAL_USER=$(id -un)
export LIMIT_TEST_OTHER_UID=$(id -u nobody)
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/config" "$TEST_ROOT/logs" "$TEST_ROOT/state"/{pending,running,done,locks,kill,fifo,usage}
chmod 1777 "$TEST_ROOT/state"/{pending,locks,kill,fifo}
CONF="$TEST_ROOT/config/taskqueue.conf"
LEDGER="$TEST_ROOT/config/taskqueue-user-limits.conf"
cat > "$CONF" <<CONF
STATE_DIR="$TEST_ROOT/state"
LOGS_DIR="$TEST_ROOT/logs"
MAX_CONCURRENT=8
SCHEDULER_MODE=$USER_LIMIT_TEST_MODE
TASK_EXECUTION_MODE=root
AVAILABLE_DEVICES="0,1,2,3,4,5,6,7"
CONF
# Only fake startup/ledger ownership in this unprivileged fixture. Actual task
# ownership is always read from the filesystem, including spoofing checks.
cat > "$TEST_ROOT/bin/stat" <<'SH'
#!/usr/bin/env bash
args=("$@")
path="${args[$#-1]}"
if [[ "$1" == -c && "$2" == %u && "$path" == */task_99999999_other ]]; then
    printf '%s\n' "$LIMIT_TEST_OTHER_UID"; exit 0
fi
if [[ "$1" == -c && ( "$path" == "$LIMIT_TEST_ROOT/config" || "$path" == "$LIMIT_TEST_ROOT/config/"* ) ]]; then
    case "$2" in
        %u) printf '0\n'; exit 0 ;;
        '%u %a') printf '0 '; /usr/bin/stat -c %a -- "$path"; exit ;;
    esac
fi
exec /usr/bin/stat "$@"
SH
cat > "$TEST_ROOT/bin/id" <<'SH'
#!/usr/bin/env bash
if [[ "${LIMIT_TEST_ADMIN:-0}" == 1 && "$#" == 1 && "$1" == -u ]]; then
    printf '0\n'
else
    exec /usr/bin/id "$@"
fi
SH
cat > "$TEST_ROOT/bin/chown" <<'SH'
#!/usr/bin/env bash
[[ "$1" == 0:0 && "$2" == "$LIMIT_TEST_ROOT/config/"* ]] || exit 1
SH
chmod 755 "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH" TASKQUEUE_CONF="$CONF"
submit() { bash "$REPO_DIR/task-submit.sh" "$@"; }
admin() { LIMIT_TEST_ADMIN=1 submit --user-limit "$@"; }
fail() { echo "error: $*" >&2; exit 1; }
wait_for() {
    local file="$1"
    for ((i=0;i<150;i++)); do
        [[ -f "$file" ]] && return 0
        sleep 0.05
    done
    fail "timed out waiting for $file"
}

# Administrative authorization, validation, persistence and public listing.
if (( ACTUAL_UID != 0 )) && submit --user-limit set "$ACTUAL_USER" 2 >"$TEST_ROOT/error" 2>&1; then
    fail 'ordinary user changed a restriction'
fi
admin set "$ACTUAL_USER" 2
[[ "$(/usr/bin/stat -c %a "$LEDGER")" == 644 ]]
submit --user-limit list | grep -Fq '上限 2 张'
for invalid in -1 01 abc 999999999999999999999; do
    if admin set "$ACTUAL_USER" "$invalid" >"$TEST_ROOT/error" 2>&1; then fail "accepted $invalid"; fi
done
for args in '--device auto --device-num 3' '--device 0,1,2' '--device auto --device-num 18446744073709551617'; do
    # Deliberately split a fixed fixture option string, never user input.
    if submit $args ':' >"$TEST_ROOT/error" 2>&1; then fail 'oversized request accepted'; fi
done
# Injecting client environment cannot override the root-managed ledger.
if USER_LIMITS_FILE=/nonexistent submit --device 0,1,2 ':' >"$TEST_ROOT/error" 2>&1; then
    fail 'caller redirected quota ledger'
fi

# A zero limit permits CPU jobs but denies even one-card requests.
admin set "$ACTUAL_USER" 0
submit --no-device ':' >/dev/null
if submit --device 0 ':' >"$TEST_ROOT/error" 2>&1; then fail 'zero limit allowed NPU request'; fi
rm -f "$TEST_ROOT/state/pending/"*
admin set "$ACTUAL_USER" 2

# The real scheduler enforces the sum of running allocations. Fake command
# workload uses no hardware, but goes through normal task claim/accounting.
first=$(submit --device 0,1 "touch '$TEST_ROOT/first'; while [[ ! -f '$TEST_ROOT/release' ]]; do sleep 0.05; done")
second=$(submit --device 2,3 "touch '$TEST_ROOT/second'")
# Forge a different user and UID in metadata: real file ownership must win.
sed -i 's/^SUBMIT_USER=.*/SUBMIT_USER=root/' "$TEST_ROOT/state/pending/$second"
printf 'SUBMIT_UID=0\n' >> "$TEST_ROOT/state/pending/$second"
# A modified/old client bypasses submission checks with an impossible request.
cat > "$TEST_ROOT/state/pending/task_99999999_oversized" <<TASK
SUBMIT_USER=root
SUBMIT_UID=0
DEVICE=3,4,5
COMMAND=touch '$TEST_ROOT/forbidden'
WORK_DIR=$TEST_ROOT
TASK
cat > "$TEST_ROOT/state/pending/task_99999999_other" <<TASK
SUBMIT_USER=nobody
DEVICE=2
COMMAND=touch '$TEST_ROOT/other'
WORK_DIR=$TEST_ROOT
TASK
# A duplicated DEVICE field cannot smuggle an allocation past planning as a
# CPU job. The daemon must retain only the exact allocation it admitted.
cat > "$TEST_ROOT/state/pending/task_99999999_duplicate" <<TASK
SUBMIT_USER=$ACTUAL_USER
DEVICE=none
DEVICE=3,4,5
COMMAND=touch '$TEST_ROOT/duplicate'
WORK_DIR=$TEST_ROOT
TASK
LIMIT_TEST_ADMIN=1 TASKQUEUE_ALLOW_USER=1 bash "$REPO_DIR/task-daemon.sh" &
DAEMON_PID=$!
wait_for "$TEST_ROOT/first"
wait_for "$TEST_ROOT/state/done/task_99999999_oversized"
wait_for "$TEST_ROOT/other"
wait_for "$TEST_ROOT/state/done/task_99999999_duplicate"
grep -q '^DEVICE=none$' "$TEST_ROOT/state/done/task_99999999_duplicate"
[[ ! -f "$TEST_ROOT/second" && ! -f "$TEST_ROOT/forbidden" ]]
grep -q '^EXIT_CODE=126$' "$TEST_ROOT/state/done/task_99999999_oversized"
grep -q 'user device limit exceeded' "$TEST_ROOT/logs/task_99999999_oversized.log"
[[ -f "$TEST_ROOT/state/pending/$second" ]]
grep -q "^SUBMIT_UID=$ACTUAL_UID$" "$TEST_ROOT/state/running/$first"
# CPU work can proceed while the user's device allowance is fully used.
cpu=$(submit --no-device "touch '$TEST_ROOT/cpu'")
wait_for "$TEST_ROOT/cpu"
[[ ! -f "$TEST_ROOT/second" ]]
touch "$TEST_ROOT/release"
wait_for "$TEST_ROOT/second"
wait_for "$TEST_ROOT/state/done/$second"
grep -q "^SUBMIT_USER=$ACTUAL_USER$" "$TEST_ROOT/state/done/$second"

# A changed cap is enforced without a daemon restart. Removing a restriction
# lets an already pending task start even while another job keeps its cards.
third=$(submit --device 0,1 "touch '$TEST_ROOT/third'; while [[ ! -f '$TEST_ROOT/release3' ]]; do sleep 0.05; done")
wait_for "$TEST_ROOT/third"
admin set "$ACTUAL_USER" 1
fourth=$(submit --device 2 "touch '$TEST_ROOT/fourth'")
wait_for "$TEST_ROOT/state/pending/$fourth"
sleep 0.4
[[ ! -f "$TEST_ROOT/fourth" ]]
admin remove "$ACTUAL_USER"
wait_for "$TEST_ROOT/fourth"
touch "$TEST_ROOT/release3"
submit --device 0,1,2 ':' >/dev/null
# Malformed/writable ledgers must not silently disable restrictions.
printf 'broken entry\n' > "$LEDGER"
if submit --device 0 ':' >"$TEST_ROOT/error" 2>&1; then fail 'malformed ledger allowed NPU work'; fi
printf '%s %s 2\n' "$ACTUAL_UID" "$ACTUAL_USER" > "$LEDGER"
chmod 666 "$LEDGER"
if submit --device 0 ':' >"$TEST_ROOT/error" 2>&1; then fail 'writable ledger allowed NPU work'; fi

echo "user device limit tests passed ($USER_LIMIT_TEST_MODE)"
