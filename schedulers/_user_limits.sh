# Root-managed per-UID limits, read on each scheduling tick.
# Ledger: <uid> <username-at-setting-time> <maximum-concurrent-devices>.
# Missing entries are unrestricted; zero forbids device work, not CPU jobs.
declare -A USER_DEVICE_LIMITS=()
USER_LIMITS_ERROR=""

user_limits_load() {
    local line uid user limit extra mode owner
    USER_DEVICE_LIMITS=()
    USER_LIMITS_ERROR=""
    [[ -n "${USER_LIMITS_FILE:-}" ]] || return 0
    [[ -e "$USER_LIMITS_FILE" || -L "$USER_LIMITS_FILE" ]] || return 0
    if [[ -L "$USER_LIMITS_FILE" || ! -f "$USER_LIMITS_FILE" || ! -r "$USER_LIMITS_FILE" ]]; then
        USER_LIMITS_ERROR="unsafe or unreadable user limits file"
        return 1
    fi
    if ! read -r owner mode < <(stat -c '%u %a' -- "$USER_LIMITS_FILE"); then
        USER_LIMITS_ERROR="cannot read user limits file ownership/permissions"
        return 1
    fi
    if [[ "$owner" != 0 || ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 8#022) != 0 )); then
        USER_LIMITS_ERROR="user limits file must be root-owned and not group/world-writable"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        read -r uid user limit extra <<< "$line"
        if [[ ! "$uid" =~ ^(0|[1-9][0-9]{0,9})$ ||
              ! "$user" =~ ^[A-Za-z0-9._-]+\$?$ ||
              ! "$limit" =~ ^(0|[1-9][0-9]{0,5})$ || -n "$extra" ||
              -n "${USER_DEVICE_LIMITS[$uid]+set}" ]]; then
            USER_LIMITS_ERROR="malformed or duplicate entry in user limits file"
            USER_DEVICE_LIMITS=()
            return 1
        fi
        USER_DEVICE_LIMITS["$uid"]="$limit"
    done < "$USER_LIMITS_FILE"
}

# Caller must be root. Lock the complete read/modify/rename transaction so
# simultaneous administrators cannot lose each other's changes.
user_limits_write() {
    local uid="$1" user="$2" limit="$3" dir="${USER_LIMITS_FILE%/*}"
    (
        flock -x 9 || exit 1
        user_limits_load || { echo "$USER_LIMITS_ERROR" >&2; exit 1; }
        local tmp line first
        tmp=$(mktemp "$dir/.user-limits.XXXXXX") || exit 1
        {
            printf '# uid username max_concurrent_devices\n'
            if [[ -f "$USER_LIMITS_FILE" ]]; then
                while IFS= read -r line || [[ -n "$line" ]]; do
                    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
                    read -r first _ <<< "$line"
                    [[ "$first" == "$uid" ]] || printf '%s\n' "$line"
                done < "$USER_LIMITS_FILE"
            fi
            [[ "$limit" == remove ]] || printf '%s %s %s\n' "$uid" "$user" "$limit"
            :
        } > "$tmp" || { rm -f "$tmp"; exit 1; }
        chmod 0644 "$tmp" && chown 0:0 "$tmp" && mv -f -- "$tmp" "$USER_LIMITS_FILE" || {
            rm -f "$tmp"; exit 1;
        }
    ) 9>>"$dir/.user-limits.lock"
}
