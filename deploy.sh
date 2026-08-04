#!/usr/bin/env bash
# Backward-compatible update entry point. setup.sh performs code-only updates.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/setup.sh" "$@"
