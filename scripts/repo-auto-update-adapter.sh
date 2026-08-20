#!/usr/bin/env bash
# pto-task adapter for the generic repo_auto_update module.
set -Eeuo pipefail

CHECKOUT=${1:?missing checkout}
TARGET=${2:?missing target}
SCRATCH_DIR=${3:?missing scratch directory}
MODE=${REPO_AUTO_UPDATE_ADAPTER_MODE:-}

case "$MODE" in
    verify)
        cd -- "$CHECKOUT"
        exec bash tests/verify_update_candidate.sh
        ;;
    apply)
        ((EUID == 0)) || {
            echo "pto-task repository-controlled updates must be applied as root" >&2
            exit 1
        }
        SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
        APP_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
        PTO_TASK_UPDATE_CHECKOUT="$CHECKOUT" \
        PTO_TASK_UPDATE_TARGET="$TARGET" \
            exec "$APP_DIR/pto-task-repo-update-deploy"
        ;;
    *)
        echo "REPO_AUTO_UPDATE_ADAPTER_MODE must be verify or apply" >&2
        exit 2
        ;;
esac
