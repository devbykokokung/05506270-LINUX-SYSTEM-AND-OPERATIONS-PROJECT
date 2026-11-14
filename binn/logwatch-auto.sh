#!/usr/bin/env bash
# Project: LogWatch - crontab version: hourly --analyze (alerts to log/journal), daily --report.
# Needs root. Shared code lives in logwatch-lib.sh.
#
# Scheduling: see logwatch.crontab (install as /etc/cron.d/logwatch). It sets PATH,
# uses absolute paths, wraps each job in flock and redirects output to a log file.
# Log rotation: see logwatch.logrotate (install as /etc/logrotate.d/logwatch).

# VERBOSE, NO_ACTION and RPT_KIND are defined/used in logwatch-lib.sh, which plain
# `shellcheck` (without -x) does not follow.
# shellcheck disable=SC1091,SC2034
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
LIB_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=logwatch-lib.sh
source "$LIB_DIR/logwatch-lib.sh"

MODE=""

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [-c FILE] [-v] [-n] --analyze
       $SCRIPT_NAME [-c FILE] [-v] [-n] --report

Counts sshd "Failed password" events from the auth log and its rotated copies.
Exactly one of --analyze / --report.

Modes:
  --analyze   midnight today until now. Logs the IPs with more than MAX_ATTEMPT
              failures to LOG_FILE and the journal (journalctl -t logwatch),
              at most TOP_N of them, then "+N more".
  --report    the whole previous day (00:00:00 up to 00:00:00 today), plus an
              "all available logs" section, written to
              AUTO_REPORT_DIR/logwatch-report-YYYY-MM-DD.txt (the day covered).
              Re-running replaces that day's file.

Options (mostly for debugging):
  -c FILE     config file (default: $DEFAULT_CONFIG)
  -v          verbose (also prints log lines to stderr)
  -n          dry-run. --report: print the report instead of writing a file.
              --analyze: print the alerts instead of logging them.
  -h          this help

Exit code: 0 = ok, 1 = error, 2 = usage error
USAGE
}

set_mode() {
    if [[ -n "$MODE" ]]; then usage_error "--analyze and --report are mutually exclusive (one only)"; fi
    MODE="$1"
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -c|--config)  need_arg "$@"; CONFIG_FILE="$2"; shift 2 ;;
            -v|--verbose) VERBOSE=1;   shift ;;
            -n|--dry-run) NO_ACTION=1; shift ;;
            --analyze)    set_mode analyze; shift ;;
            --report)     set_mode report;  shift ;;
            *)            usage_error "unknown option: $1" ;;
        esac
    done
    if [[ -z "$MODE" ]]; then usage_error "choose one of --analyze, --report"; fi
}

# alert LEVEL MSG : log it (file + journal); with -n just print it and write nothing
alert() {
    if (( NO_ACTION )); then printf '[dry-run] [%s] %s\n' "$1" "$2"; else log "$1" "$2"; fi
}

notify_exceed() {
    local -a lines=()
    local line ip cnt tag total
    mapfile -t lines < <(exceed_list "$WORK/win.tsv")
    total=${#lines[@]}
    if (( total == 0 )); then
        alert INFO "analyze $WSTART to $NOW: no IP exceeded $MAX_ATTEMPT failed SSH password attempts"
        return 0
    fi
    alert WARN "analyze $WSTART to $NOW: $total IP(s) exceeded $MAX_ATTEMPT failed SSH password attempts"
    for line in "${lines[@]:0:TOP_N}"; do
        ip="${line%%"$TAB"*}"
        cnt="${line##*"$TAB"}"
        tag=""
        if in_whitelist "$ip"; then tag=" whitelisted=yes"; fi
        alert WARN "ALERT ip=$ip failures=$cnt max=$MAX_ATTEMPT$tag"
    done
    if (( total > TOP_N )); then alert WARN "ALERT +$((total - TOP_N)) more IP(s) not listed"; fi
}

main() {
    local yesterday
    parse_args "$@"
    require_root
    require_cmds
    load_config "$CONFIG_FILE"
    init_time

    case "$MODE" in
        analyze)
            analyze_window "${TODAY}T00:00:00" "$NOW" 0
            notify_exceed
            ;;
        report)
            yesterday="$(date -d "$TODAY -1 day" +%F)"
            RPT_KIND="daily report for $yesterday"
            analyze_window "${yesterday}T00:00:00" "${TODAY}T00:00:00" 1
            emit_report "$AUTO_REPORT_DIR" "logwatch-report-${yesterday}.txt"
            ;;
    esac
}
main "$@"