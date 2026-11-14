#!/usr/bin/env bash
# Project: LogWatch - สคริปต์สำหรับ crontab

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_CONFIG="/etc/logwatch/logwatch.conf"
CONFIG_FILE="$DEFAULT_CONFIG"
LOG_FILE="/var/log/logwatch.log"
VERBOSE=0
NO_ACTION=0
CONFIRM=0
SINCE=""
BLOCK_IP=""
OPT_TOP=""

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
Usage: $SCRIPT_NAME [-c config] [-v] [-n] [-h] [-t N] [--since DATE]
       $SCRIPT_NAME [-c config] [-v] [-n] [-y] --block IP
ดูรายงาน SSH login ที่ล้มเหลว และ block IP ด้วย ufw
  -c FILE        ระบุไฟล์ config (ค่าเริ่มต้น: $DEFAULT_CONFIG)
  -v             แสดงรายละเอียดการทำงาน
  -n             dry-run (แสดงสิ่งที่จะทำ แต่ไม่ทำจริง)
  -h             แสดงวิธีใช้
  -t N           จำนวนอันดับที่แสดง (แทนค่า TOP_N ใน config)
  --since DATE   ดูข้อมูลตั้งแต่วันที่ DATE ถึงปัจจุบัน
  --block IP     สั่ง ufw deny IP (ถ้า DRY_RUN=ON จะเป็น dry-run)
  -y             ยืนยันให้ block จริง

Exit code: 0 = สำเร็จ, 1 = เกิดข้อผิดพลาด, 2 = ใช้งานผิดวิธี
USAGE
}

usage_error() {
    echo "$SCRIPT_NAME: $1" >&2
    echo "Try '$SCRIPT_NAME -h' for help." >&2
    exit 2
}
need_arg() {
    if [[ $# -lt 2 || -z "$2" ]]; then usage_error "option $1 requires an argument"; fi
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -c|--config)  need_arg "$@"; CONFIG_FILE="$2"; shift 2 ;;
            -v|--verbose) VERBOSE=1;   shift ;;
            -n|--dry-run) NO_ACTION=1; shift ;;
            -y|--yes)     CONFIRM=1;   shift ;;
            -t|--top)     need_arg "$@"; OPT_TOP="$2"; shift 2 ;;
            --since)      need_arg "$@"; SINCE="$2";    shift 2 ;;
            --block)      need_arg "$@"; BLOCK_IP="$2"; shift 2 ;;
            *)            usage_error "unknown option: $1" ;;
        esac
    done

    if [[ -n "$SINCE" && -n "$BLOCK_IP" ]]; then
        usage_error "--since and --block cannot be used together"
    fi
    if (( CONFIRM )) && [[ -z "$BLOCK_IP" ]]; then
        usage_error "-y is only used with --block"
    fi
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

check_deps() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log ERROR "required command not found: $cmd"
            exit 1
        fi
    done
}

main() {
    parse_args "$@"
    load_config "$CONFIG_FILE"

    check_deps awk grep sed sort uniq cut date
    if [[ -n "$OPT_TOP" ]]; then
        if ! is_posint "$OPT_TOP"; then usage_error "-t needs a positive integer (got '$OPT_TOP')"; fi
        TOP_N="$OPT_TOP"
    fi

    debug "config loaded: $CONFIG_FILE"
    debug "TOP_N=$TOP_N MAX_ATTEMPT=$MAX_ATTEMPT DRY_RUN=$DRY_RUN NO_ACTION=$NO_ACTION"
    debug "SINCE='$SINCE' BLOCK_IP='$BLOCK_IP' CONFIRM=$CONFIRM"

    if [[ -n "$BLOCK_IP" ]]; then
        # TODO(เพื่อน): block_ip  ใช้ $BLOCK_IP, $DRY_RUN, $CONFIRM, $NO_ACTION, $WHITELIST
        log INFO "block $BLOCK_IP (ยังไม่ได้เขียน)"
    else
        # TODO(เพื่อน): make_report  ใช้ $SINCE, $AUTO_LOG_DIR, $MANUAL_LOG_DIR, $TOP_N, $MAX_ATTEMPT
        log INFO "report since '${SINCE:-today}' (ยังไม่ได้เขียน)"
    fi
}
main "$@"
