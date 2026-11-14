#!/usr/bin/env bash
# Project: LogWatch - สคริปต์สำหรับ crontab

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_CONFIG="/etc/logwatch/logwatch.conf"
CONFIG_FILE="$DEFAULT_CONFIG"
LOG_FILE="/var/log/logwatch.log"
VERBOSE=0
NO_ACTION=0

log() {
    local level="$1"; shift
    local line
    line="$(date '+%F %T') [$level] $*"
    echo "$line" >&2
    { echo "$line" >> "$LOG_FILE"; } 2>/dev/null || true
}

debug() {
    if (( VERBOSE )); then log DEBUG "$*"; fi
}

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [-c config] [-v] [-n] [-h]

เก็บข้อมูล SSH login ที่ล้มเหลวทุกชั่วโมง และสร้าง report รายวัน
  -c FILE   ระบุไฟล์ config (ค่าเริ่มต้น: $DEFAULT_CONFIG)
  -v        แสดงรายละเอียดการทำงาน
  -n        dry-run (แสดงสิ่งที่จะทำ แต่ไม่ทำจริง)
  -h        แสดงวิธีใช้

Exit code: 0 = สำเร็จ, 1 = เกิดข้อผิดพลาด, 2 = ใช้งานผิดวิธี
USAGE
}

usage_error() {
    echo "$SCRIPT_NAME: $1" >&2
    echo "Try '$SCRIPT_NAME -h' for help." >&2
    exit 2
}
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -c|--config)
                if [[ $# -lt 2 || -z "$2" ]]; then usage_error "option $1 requires a file"; fi
                CONFIG_FILE="$2"
                shift 2 ;;
            -v|--verbose) VERBOSE=1;   shift ;;
            -n|--dry-run) NO_ACTION=1; shift ;;
            *)            usage_error "unknown option: $1" ;;
        esac
    done
}
is_posint() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

load_config() {
    local file="$1" var

    if [[ ! -e "$file" ]]; then log ERROR "config file not found: $file"; exit 1; fi
    if [[ ! -r "$file" ]]; then log ERROR "cannot read config file: $file"; exit 1; fi

    # shellcheck source=/dev/null
    source "$file"

    TOP_N="${TOP_N:-10}"
    MAX_ATTEMPT="${MAX_ATTEMPT:-5}"
    DRY_RUN="${DRY_RUN:-ON}"
    WHITELIST="${WHITELIST:-127.0.0.1}"

    for var in AUTH_LOG AUTO_LOG_DIR MANUAL_LOG_DIR LOG_FILE; do
        if [[ "${!var:-}" != /* ]]; then
            log ERROR "config: $var must be an absolute path (got '${!var:-}')"
            exit 1
        fi
    done
    if ! is_posint "$TOP_N"; then
        log ERROR "config: TOP_N must be a positive integer (got '$TOP_N')"; exit 1
    fi
    if ! is_posint "$MAX_ATTEMPT"; then
        log ERROR "config: MAX_ATTEMPT must be a positive integer (got '$MAX_ATTEMPT')"; exit 1
    fi
    case "${DRY_RUN,,}" in
        on|true|yes|1)  DRY_RUN=1 ;;
        off|false|no|0) DRY_RUN=0 ;;
        *) log ERROR "config: DRY_RUN must be ON or OFF (got '$DRY_RUN')"; exit 1 ;;
    esac
}

main() {
    parse_args "$@"
    load_config "$CONFIG_FILE"
    debug "config loaded: $CONFIG_FILE"
    debug "TOP_N=$TOP_N MAX_ATTEMPT=$MAX_ATTEMPT DRY_RUN=$DRY_RUN NO_ACTION=$NO_ACTION"

    # TODO(เพื่อน): collect_log   ใช้ $AUTH_LOG, $AUTO_LOG_DIR, $NO_ACTION
    # TODO(เพื่อน): daily_report  ใช้ $AUTO_LOG_DIR, $TOP_N, $MAX_ATTEMPT

    log INFO "done"
}
main "$@"
