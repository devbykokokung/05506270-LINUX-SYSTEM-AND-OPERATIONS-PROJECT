#!/usr/bin/env bash
# Project: LogWatch - interactive tool: analyze / report on failed SSH logins, block an IP.
# Needs root (sudo). Shared code lives in logwatch-lib.sh.

# VERBOSE, NO_ACTION and RPT_KIND are defined/used in logwatch-lib.sh, which plain
# `shellcheck` (without -x) does not follow.
# shellcheck disable=SC1091,SC2034
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
LIB_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=logwatch-lib.sh
source "$LIB_DIR/logwatch-lib.sh"

MODE=""
SINCE=""
BLOCK_IP=""

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [-c FILE] [-v] [-n] --analyze [--since YYYY-MM-DD]
       $SCRIPT_NAME [-c FILE] [-v] [-n] --report  [--since YYYY-MM-DD]
       $SCRIPT_NAME [-c FILE] [-v] [-n] [-y] --block IP

Counts sshd "Failed password" events (valid and invalid users) from the auth log
and its rotated/compressed copies. Exactly one of --analyze / --report / --block.

Modes:
  --analyze      print to the terminal, for midnight today (or --since) until now:
                 top (IP,user) pairs, top IPs, top usernames, IPs over MAX_ATTEMPT
  --report       same, plus an "all available logs" section, written to
                 MANUAL_REPORT_DIR/logwatch-report-YYYY-MM-DDTHH-MM-SS.txt
  --block IP     block one IPv4/IPv6 address (see BLOCK_MODE below)

Options:
  -c FILE        config file (default: $DEFAULT_CONFIG)
  -v             verbose
  -n             dry-run. --report: print the report instead of writing a file.
                 --block: print the command instead of running it.
                 --analyze: no effect (it only prints anyway).
  -y             with --block: make the block permanent (ufw rule)
  --since DATE   start at DATE 00:00:00 instead of today (with --analyze/--report)
  -h             this help

BLOCK_MODE in the config:
  temporary   --block IP     iptables rule, gone on ufw reload/restart/reboot
              --block IP -y  permanent ufw rule
  permanent   --block IP     permanent ufw rule (-y changes nothing)
IPs in WHITELIST (exact match) and your current SSH client IP are never blocked.

Exit code: 0 = ok, 1 = error, 2 = usage error
USAGE
}

set_mode() {
    if [[ -n "$MODE" ]]; then usage_error "--analyze, --report and --block are mutually exclusive (one only)"; fi
    MODE="$1"
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -c|--config)  need_arg "$@"; CONFIG_FILE="$2"; shift 2 ;;
            -v|--verbose) VERBOSE=1;   shift ;;
            -n|--dry-run) NO_ACTION=1; shift ;;
            -y|--yes)     CONFIRM=1;   shift ;;
            --analyze)    set_mode analyze; shift ;;
            --report)     set_mode report;  shift ;;
            --block)      need_arg "$@"; set_mode block; BLOCK_IP="$2"; shift 2 ;;
            --since)      need_arg "$@"; SINCE="$2"; shift 2 ;;
            *)            usage_error "unknown option: $1" ;;
        esac
    done

    if [[ -z "$MODE" ]]; then usage_error "choose one of --analyze, --report, --block"; fi
    if [[ -n "$SINCE" && "$MODE" == block ]]; then usage_error "--since cannot be used with --block"; fi
    if (( CONFIRM )) && [[ "$MODE" != block ]]; then usage_error "-y is only used with --block"; fi
}

main() {
    local start
    parse_args "$@"
    require_root
    require_cmds
    load_config "$CONFIG_FILE"
    init_time

    if [[ "$MODE" == block ]]; then
        block_ip "$BLOCK_IP"
        return 0
    fi

    if [[ -n "$SINCE" ]]; then
        if ! is_valid_date "$SINCE"; then usage_error "--since needs a real date, YYYY-MM-DD (got '$SINCE')"; fi
        if [[ "$SINCE" > "$TODAY" ]]; then usage_error "--since $SINCE is in the future"; fi
        start="${SINCE}T00:00:00"
    else
        start="${TODAY}T00:00:00"
    fi

    case "$MODE" in
        analyze)
            RPT_KIND="analysis"
            analyze_window "$start" "$NOW" 0
            build_window_only
            ;;
        report)
            RPT_KIND="report"
            analyze_window "$start" "$NOW" 1
            emit_report "$MANUAL_REPORT_DIR" "logwatch-report-${NOW//:/-}.txt"
            if [[ -n "$REPORT_PATH" ]]; then echo "$REPORT_PATH"; fi
            ;;
    esac
}
main "$@"