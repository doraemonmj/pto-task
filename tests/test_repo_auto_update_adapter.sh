#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

target=dddddddddddddddddddddddddddddddddddddddd
checkout="$TEST_ROOT/checkout"
scratch="$TEST_ROOT/scratch"
mkdir -p "$checkout/tests" "$scratch"
cat > "$checkout/tests/verify_update_candidate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'verified\n' > "$VERIFY_MARKER"
EOF
chmod 755 "$checkout/tests/verify_update_candidate.sh"

VERIFY_MARKER="$TEST_ROOT/verified" REPO_AUTO_UPDATE_ADAPTER_MODE=verify \
    bash "$REPO_DIR/scripts/repo-auto-update-adapter.sh" \
    "$checkout" "$target" "$scratch"
grep -Fqx verified "$TEST_ROOT/verified"

if [[ "$(id -u)" -eq 0 ]]; then
    app="$TEST_ROOT/app"
    mkdir -p "$app"
    cp "$REPO_DIR/scripts/repo-auto-update-adapter.sh" \
        "$app/pto-task-repo-update-apply"
    cat > "$app/pto-task-repo-update-deploy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n%s\n' "$PTO_TASK_UPDATE_CHECKOUT" \
    "$PTO_TASK_UPDATE_TARGET" > "$APPLY_RECORD"
EOF
    chmod 755 "$app/pto-task-repo-update-apply" \
        "$app/pto-task-repo-update-deploy"
    APPLY_RECORD="$TEST_ROOT/applied" REPO_AUTO_UPDATE_ADAPTER_MODE=apply \
        "$app/pto-task-repo-update-apply" "$checkout" "$target" "$scratch"
    mapfile -t applied < "$TEST_ROOT/applied"
    [[ "${applied[0]}" == "$checkout" ]]
    [[ "${applied[1]}" == "$target" ]]
fi

echo 'repository-controlled update adapter tests passed'
