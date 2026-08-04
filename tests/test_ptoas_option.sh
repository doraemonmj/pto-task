#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -e "$REPO_DIR/runtime" ]]; then
    echo "error: $REPO_DIR/runtime already exists; refusing to overwrite source-mode state" >&2
    exit 1
fi
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT" "$REPO_DIR/runtime"' EXIT

STATE_DIR="$REPO_DIR/runtime/state"
LOGS_DIR="$REPO_DIR/runtime/logs"
PTOAS_BASE="$TEST_ROOT/ptoas"
mkdir -p "$REPO_DIR/runtime/config" "$STATE_DIR/pending" "$STATE_DIR/locks" \
    "$LOGS_DIR" "$PTOAS_BASE/0.54/bin"
printf '#!/usr/bin/env bash\n' > "$PTOAS_BASE/0.54/bin/ptoas"
chmod 755 "$PTOAS_BASE/0.54/bin/ptoas"
install -m 666 /dev/null "$STATE_DIR/locks/update-reservation.lock"
cat > "$REPO_DIR/runtime/config/taskqueue.conf" <<EOF
STATE_DIR="$STATE_DIR"
LOGS_DIR="$LOGS_DIR"
MAX_CONCURRENT=1
PTOAS_BASE="$TEST_ROOT/server-default-ptoas"
EOF

task_id="$(env -u PTOAS_ROOT PTOAS_BASE="$PTOAS_BASE" \
    "$REPO_DIR/task-submit.sh" --ptoas 0.54 'true')"
env_file="$STATE_DIR/pending/${task_id}.env"
[[ -f "$env_file" ]]
[[ "$(tr '\0' '\n' < "$env_file" | grep '^PTOAS_BASE=' | tail -n1)" == \
    "PTOAS_BASE=$PTOAS_BASE" ]]
[[ "$(tr '\0' '\n' < "$env_file" | grep '^PTOAS_ROOT=' | tail -n1)" == \
    "PTOAS_ROOT=$PTOAS_BASE/0.54" ]]
[[ "$(tr '\0' '\n' < "$env_file" | grep '^PATH=' | tail -n1)" == \
    "PATH=$PTOAS_BASE/0.54:$PTOAS_BASE/0.54/bin:$PATH" ]]

# Legacy installations expose a root-level wrapper that configures lib/ before
# delegating to bin/ptoas. The root must precede bin in the submitted PATH.
mkdir -p "$PTOAS_BASE/0.48/bin"
printf '#!/usr/bin/env bash\n' > "$PTOAS_BASE/0.48/ptoas"
chmod 755 "$PTOAS_BASE/0.48/ptoas"
legacy_task_id="$(env -u PTOAS_ROOT PTOAS_BASE="$PTOAS_BASE" \
    "$REPO_DIR/task-submit.sh" --ptoas 0.48 'true')"
legacy_env_file="$STATE_DIR/pending/${legacy_task_id}.env"
[[ "$(tr '\0' '\n' < "$legacy_env_file" | grep '^PATH=' | tail -n1)" == \
    "PATH=$PTOAS_BASE/0.48:$PTOAS_BASE/0.48/bin:$PATH" ]]

plain_task_id="$(env -u PTOAS_ROOT PTOAS_BASE="$PTOAS_BASE" \
    "$REPO_DIR/task-submit.sh" 'true')"
plain_env_file="$STATE_DIR/pending/${plain_task_id}.env"
if tr '\0' '\n' < "$plain_env_file" | grep -q '^PTOAS_ROOT='; then
    echo 'error: PTOAS_ROOT was injected without --ptoas' >&2
    exit 1
fi

manual_root="$TEST_ROOT/manual-root"
manual_path="$TEST_ROOT/manual-bin:$PATH"
manual_task_id="$(PTOAS_BASE="$PTOAS_BASE" PTOAS_ROOT="$manual_root" PATH="$manual_path" \
    "$REPO_DIR/task-submit.sh" --ptoas 0.54 'true' 2> "$TEST_ROOT/manual.err")"
manual_env_file="$STATE_DIR/pending/${manual_task_id}.env"
[[ "$(tr '\0' '\n' < "$manual_env_file" | grep '^PTOAS_ROOT=' | tail -n1)" == \
    "PTOAS_ROOT=$manual_root" ]]
[[ "$(tr '\0' '\n' < "$manual_env_file" | grep '^PATH=' | tail -n1)" == \
    "PATH=$manual_path" ]]
grep -Fq "忽略 --ptoas 0.54" "$TEST_ROOT/manual.err"

mkdir -p "$PTOAS_BASE/0.55"
if env -u PTOAS_ROOT PTOAS_BASE="$PTOAS_BASE" \
    "$REPO_DIR/task-submit.sh" --ptoas 0.55 'true' \
    > "$TEST_ROOT/unusable.out" 2>&1; then
    echo 'error: PTOAS version without bin/ptoas was accepted' >&2
    exit 1
fi
grep -Fq "未找到可用的 PTOAS 版本 '0.55'" "$TEST_ROOT/unusable.out"
if grep -Fq '可用版本: 0.54,0.55' "$TEST_ROOT/unusable.out"; then
    echo 'error: unusable PTOAS version was listed as available' >&2
    exit 1
fi

mkdir -p "$TEST_ROOT/outside/0.56/bin"
printf '#!/usr/bin/env bash\n' > "$TEST_ROOT/outside/0.56/bin/ptoas"
chmod 755 "$TEST_ROOT/outside/0.56/bin/ptoas"
ln -s "$TEST_ROOT/outside/0.56" "$PTOAS_BASE/0.56"
if env -u PTOAS_ROOT PTOAS_BASE="$PTOAS_BASE" \
    "$REPO_DIR/task-submit.sh" --ptoas 0.56 'true' \
    > "$TEST_ROOT/outside.out" 2>&1; then
    echo 'error: PTOAS version resolving outside the configured base was accepted' >&2
    exit 1
fi

if env -u PTOAS_ROOT PTOAS_BASE="$PTOAS_BASE" \
    "$REPO_DIR/task-submit.sh" --ptoas 0.99 'true' \
    > "$TEST_ROOT/missing.out" 2>&1; then
    echo 'error: missing PTOAS version was accepted' >&2
    exit 1
fi
grep -Fq "未找到可用的 PTOAS 版本 '0.99'" "$TEST_ROOT/missing.out"
grep -Fq '可用版本: 0.48,0.54' "$TEST_ROOT/missing.out"

echo 'PTOAS option tests passed'
