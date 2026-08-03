#!/usr/bin/env bash
# Independent, read-only sampler for NPU cards assigned to running tasks.
set -u

APP_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -f "$APP_DIR/../config/taskqueue.conf" ]]; then
    TOOL_ROOT="$(dirname "$APP_DIR")"
    CONF_FILE="${TASKQUEUE_CONF:-$TOOL_ROOT/config/taskqueue.conf}"
else
    TOOL_ROOT="$APP_DIR/runtime"
    CONF_FILE="${TASKQUEUE_CONF:-$TOOL_ROOT/config/taskqueue.conf}"
fi
[ -f "$CONF_FILE" ] && source "$CONF_FILE"
STATE_DIR="${STATE_DIR:-$TOOL_ROOT/state}"
RUNNING_DIR="$STATE_DIR/running"
USAGE_DIR="$STATE_DIR/usage"
mkdir -p "$USAGE_DIR" 2>/dev/null
case "${USAGE_SAMPLING_ENABLED:-false}" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *) exit 0 ;;
esac
exec 9>"$USAGE_DIR/.sampler.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0
command -v npu-smi >/dev/null 2>&1 || exit 0

sample_timeout="${USAGE_SAMPLE_TIMEOUT:-5}"
[[ "$sample_timeout" =~ ^[1-9][0-9]*$ ]] || sample_timeout=5
read_usage() {
    local phy="$1" out util aicore hbm
    out=$(timeout "$sample_timeout" npu-smi info -t usages -i "$((phy / 2))" -c "$((phy % 2))" 2>/dev/null) || return 1
    util=$(awk -F: '/NPU Utilization/ {gsub(/ /,"",$2); print $2; exit}' <<< "$out")
    aicore=$(awk -F: '/Aicore Usage Rate/ {gsub(/ /,"",$2); print $2; exit}' <<< "$out")
    hbm=$(awk -F: '/HBM Usage Rate/ {gsub(/ /,"",$2); print $2; exit}' <<< "$out")
    [[ -n "$util" ]] || return 1
    printf '%s,%s,%s' "$util" "$aicore" "$hbm"
}

out_file="$USAGE_DIR/$(date +%Y%m%d).csv"
now=$(date +%s)
for task_file in "$RUNNING_DIR"/task_*; do
    [[ -f "$task_file" && "$task_file" != *.env ]] || continue
    task_id=$(basename "$task_file")
    device=$(awk -F= '$1=="DEVICE" {print substr($0,index($0,"=")+1); exit}' "$task_file")
    user=$(awk -F= '$1=="SUBMIT_USER" {print substr($0,index($0,"=")+1); exit}' "$task_file")
    [[ -n "$device" && "$device" != none && "$device" != auto* ]] || continue
    IFS=, read -r -a devices <<< "$device"
    for phy in "${devices[@]}"; do
        [[ "$phy" =~ ^[0-9]+$ ]] || continue
        sample=$(read_usage "$phy") || continue
        printf '%s,%s,%s,%s,%s\n' "$now" "$phy" "$sample" "$task_id" "${user:-unknown}" >> "$out_file"
    done
done
[[ -f "$out_file" ]] && chmod 644 "$out_file"
