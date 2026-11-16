#!/usr/bin/env bash
# Priority ordering contract: granted users and aged ordinary tasks share the
# head bucket, everything else keeps FIFO, and accounting stays fail-open when
# the file metadata cannot be read.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PENDING_DIR="$TEST_ROOT/pending"
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$PENDING_DIR" "$FAKE_BIN"
LOG_FILE="$TEST_ROOT/scheduler.log"
PRIORITY_FILE="$TEST_ROOT/priority.conf"
PRIORITY_STAT_FIXTURE="$TEST_ROOT/stat.fixture"
PRIORITY_STAT_CALLS="$TEST_ROOT/stat.calls"
export PRIORITY_STAT_FIXTURE PRIORITY_STAT_CALLS

AVAILABLE_DEVICES="0,1,2,3"
RUNTIME_DEVICES=""
IN_USE_SET=","
CURRENT_JOBS=0
MAX_CONCURRENT=4
MAX_CONCURRENT_8_CARD_TASKS=0
RUNNING_8_CARD_TASKS=0
SCHEDULER_MODE=contract_test

fail() {
    echo "error: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" == "$expected" ]] ||
        fail "$label: expected '$expected', got '$actual'"
}

log() {
    printf '%s\n' "$*" >> "$LOG_FILE"
}

read_field() {
    local wanted="$1" file="$2" key value
    [[ -f "$file" ]] || return 1
    while IFS='=' read -r key value; do
        if [[ "$key" == "$wanted" ]]; then
            printf '%s' "$value"
            return 0
        fi
    done < "$file"
    return 1
}

device_request_count() {
    case "$1" in
        ""|none) printf '0' ;;
        *) printf '1' ;;
    esac
}

# The ordering code reads owner and ctime through the external `stat` command,
# so the fixture can script any ownership/age combination without root or sleep.
cat > "$FAKE_BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -c && "${2:-}" == '%U %Z %n' ]]; then
    printf 'called\n' >> "${PRIORITY_STAT_CALLS:?}"
    [[ "${PRIORITY_STAT_FAIL:-0}" == 1 ]] && exit 1
    [[ -r "${PRIORITY_STAT_FIXTURE:-}" ]] || exit 1
    cat "$PRIORITY_STAT_FIXTURE"
    exit 0
fi
exec /usr/bin/stat "$@"
EOF
chmod 755 "$FAKE_BIN/stat"
PATH="$FAKE_BIN:$PATH"

# shellcheck source=../schedulers/_core.sh
source "$REPO_DIR/schedulers/_core.sh"

NOW="$(printf '%(%s)T' -1)"
FUTURE=$((NOW + 86400))
PAST=$((NOW - 86400))

make_task() {
    printf 'DEVICE=none\n' > "$PENDING_DIR/$1"
}

# add_entry <task_id> <owner> <age_seconds>
add_entry() {
    printf '%s %s %s\n' "$2" "$((NOW - $3))" "$PENDING_DIR/$1" \
        >> "$PRIORITY_STAT_FIXTURE"
}

reset_case() {
    rm -f "$PENDING_DIR"/task_*
    : > "$PRIORITY_STAT_FIXTURE"
    rm -f "$PRIORITY_STAT_CALLS"
    : > "$PRIORITY_FILE"
    PRIORITY_AGING_SECONDS=1800
    SCHEDULER_ORDERED_TASKS=()
    unset PRIORITY_STAT_FAIL 2>/dev/null || true
}

ordered_basenames() {
    local file out=""
    scheduler_order_pending_tasks
    for file in "${SCHEDULER_ORDERED_TASKS[@]}"; do
        out+="${out:+ }$(basename "$file")"
    done
    printf '%s' "$out"
}

grant() {
    printf '%s %s %s\n' "$1" "$2" "$NOW" > "$PRIORITY_FILE"
}

OLD=task_20260101_000001_101
NEW=task_20260101_000002_102

# Baseline: below the aging threshold and without a grant, glob order stands.
reset_case
make_task "$OLD"
make_task "$NEW"
add_entry "$OLD" alice 100
add_entry "$NEW" bob 10
assert_eq "$OLD $NEW" "$(ordered_basenames)" "plain FIFO baseline"

# An unexpired grant moves its owner's task into the head bucket.
grant bob "$FUTURE"
assert_eq "$NEW $OLD" "$(ordered_basenames)" "granted owner takes the head"

# An expired grant grants nothing; the ledger needs no cleanup for that.
grant bob "$PAST"
assert_eq "$OLD $NEW" "$(ordered_basenames)" "expired grant is ignored"

# Aging: an ordinary task past the threshold joins the head bucket and keeps
# FIFO order inside it, so a grant can only reorder younger tasks.
reset_case
T1=task_20260101_000001_201
T2=task_20260101_000002_202
T3=task_20260101_000003_203
make_task "$T1"
make_task "$T2"
make_task "$T3"
add_entry "$T1" carol 60
add_entry "$T2" dave 5000
add_entry "$T3" bob 5
grant bob "$FUTURE"
assert_eq "$T2 $T3 $T1" "$(ordered_basenames)" "aged task joins the head bucket"

# Aging disabled: the mechanism is off entirely, including grant evaluation,
# so no file metadata is read at all.
reset_case
make_task "$T1"
make_task "$T2"
make_task "$T3"
add_entry "$T1" carol 60
add_entry "$T2" dave 5000
add_entry "$T3" bob 5
grant bob "$FUTURE"
PRIORITY_AGING_SECONDS=0
assert_eq "$T1 $T2 $T3" "$(ordered_basenames)" "aging 0 restores plain FIFO"
[[ ! -e "$PRIORITY_STAT_CALLS" ]] || fail "aging 0 still read file metadata"

# A non-numeric threshold (core default when the daemon did not vet it) is
# also treated as disabled rather than as "age everything".
PRIORITY_AGING_SECONDS=abc
assert_eq "$T1 $T2 $T3" "$(ordered_basenames)" "invalid threshold disables ordering"

# Fail-open: an unreadable metadata pass must not drop tasks from the tick.
reset_case
make_task "$T1"
make_task "$T3"
add_entry "$T1" carol 5000
add_entry "$T3" bob 10
grant bob "$FUTURE"
export PRIORITY_STAT_FAIL=1
assert_eq "$T1 $T3" "$(ordered_basenames)" "failed metadata keeps FIFO and all tasks"

# Fail-open: a partial metadata pass classifies only what it reports; the
# unlisted task stays in the normal bucket instead of disappearing.
reset_case
make_task "$T1"
make_task "$T3"
add_entry "$T1" carol 5000
grant bob "$FUTURE"
assert_eq "$T1 $T3" "$(ordered_basenames)" "partial metadata keeps unlisted task"
scheduler_order_pending_tasks
assert_eq 2 "${#SCHEDULER_ORDERED_TASKS[@]}" "partial metadata kept both tasks"

# Malformed and unknown-user lines grant nothing; the valid line still counts.
reset_case
make_task "$OLD"
make_task "$NEW"
add_entry "$OLD" alice 100
add_entry "$NEW" bob 10
cat > "$PRIORITY_FILE" <<EOF
# user expiry_epoch granted_epoch
garbage
alice notanumber $NOW
!bad user $FUTURE $NOW
bob $PAST $PAST
bob $FUTURE $NOW
EOF
assert_eq "$NEW $OLD" "$(ordered_basenames)" "malformed ledger lines are ignored"

# A missing ledger is not an error.
reset_case
make_task "$OLD"
make_task "$NEW"
add_entry "$OLD" alice 100
add_entry "$NEW" bob 10
PRIORITY_FILE="$TEST_ROOT/absent.conf"
assert_eq "$OLD $NEW" "$(ordered_basenames)" "missing ledger keeps FIFO"
PRIORITY_FILE="$TEST_ROOT/priority.conf"

# Environment sidecars are not tasks and must not occupy a queue slot.
reset_case
make_task "$OLD"
printf 'K=V\n' > "$PENDING_DIR/$OLD.env"
add_entry "$OLD" alice 100
assert_eq "$OLD" "$(ordered_basenames)" "env sidecar is excluded"

# The tick consumes the computed order, not the raw glob order.
reset_case
make_task "$OLD"
make_task "$NEW"
add_entry "$OLD" alice 100
add_entry "$NEW" bob 10
grant bob "$FUTURE"
CONSIDERED=""
scheduler_consider_task() {
    CONSIDERED+="${CONSIDERED:+ }$(basename "$1")"
    scheduler_plan_defer fixture
}
scheduler_schedule_tick
assert_eq "$NEW $OLD" "$CONSIDERED" "tick traverses the priority order"
unset -f scheduler_consider_task

# Ledger query helpers: only unexpired grants are visible.
reset_case
grant alice "$FUTURE"
printf 'bob %s %s\n' "$PAST" "$PAST" >> "$PRIORITY_FILE"
assert_eq "$FUTURE" "$(priority_expiry_of alice)" "active grant expiry"
if priority_expiry_of bob >/dev/null; then
    fail "expired grant was reported as active"
fi
if priority_expiry_of nobody >/dev/null; then
    fail "ungranted user was reported as active"
fi

echo 'priority queue tests passed'
