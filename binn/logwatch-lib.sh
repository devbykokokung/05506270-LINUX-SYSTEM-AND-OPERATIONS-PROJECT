#!/usr/bin/env bash
# logwatch-lib.sh - shared code for logwatch.sh and logwatch-auto.sh.
# Source it; do not run it. The calling script must set SCRIPT_NAME first.
#
# Counted event: sshd "Failed password for [invalid user ]NAME from IP port N ssh2"
# (including rsyslog's "message repeated N times: [ ... ]" form).
# Log format expected: rsyslog ISO 8601 timestamps (2026-11-10T20:26:53.171685+07:00).

# Variables below are used by the scripts that source this file, so shellcheck
# cannot see their use when it checks this file alone.
# shellcheck disable=SC2034
set -euo pipefail

PATH="${LOGWATCH_TEST_PATH:+$LOGWATCH_TEST_PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
export LC_ALL=C
umask 077
shopt -s nullglob

readonly DEFAULT_CONFIG="/etc/logwatch/logwatch.conf"
readonly TAB=$'\t'
readonly ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'

CONFIG_FILE="$DEFAULT_CONFIG"
LOG_FILE="/var/log/logwatch.log"
VERBOSE=0
NO_ACTION=0
CONFIRM=0
WORK=""
TMP_REPORT=""
NOW=""
TODAY=""
WSTART=""
WEND=""
RPT_KIND=""
REPORT_PATH=""

# ---------------------------------------------------------------- logging

# log LEVEL MSG...   levels: ERROR WARN INFO DEBUG
# Always appended to LOG_FILE and sent to syslog/journal (tag "logwatch", facility user).
# Printed to stderr only for ERROR or with -v, so cron does not mail every hour.
log() {
    local level="$1"; shift
    local msg="$*" prio line
    if [[ $level == DEBUG ]] && (( ! VERBOSE )); then return 0; fi
    case "$level" in
        ERROR) prio=user.err ;;
        WARN)  prio=user.warning ;;
        INFO)  prio=user.info ;;
        *)     prio=user.debug ;;
    esac
    line="$(date '+%F %T') [$level] $msg"
    if (( VERBOSE )) || [[ $level == ERROR ]]; then printf '%s\n' "$line" >&2; fi
    { printf '%s\n' "$line" >> "$LOG_FILE"; } 2>/dev/null || true
    logger -t logwatch -p "$prio" -- "$msg" 2>/dev/null || true
}

debug() { log DEBUG "$*"; }
die()   { log ERROR "$*"; exit 1; }

usage_error() {
    echo "$SCRIPT_NAME: $1" >&2
    echo "Try '$SCRIPT_NAME -h' for help." >&2
    exit 2
}

# need_arg OPT VALUE...  (value must exist and must not look like another option)
need_arg() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        usage_error "option $1 requires an argument"
    fi
}

cleanup() {
    if [[ -n "$WORK" ]]; then rm -rf -- "$WORK"; fi
    if [[ -n "$TMP_REPORT" ]]; then rm -f -- "$TMP_REPORT"; fi
}
trap cleanup EXIT

require_root() {
    if (( EUID != 0 )); then
        echo "$SCRIPT_NAME: must be run as root (try: sudo $SCRIPT_NAME ...)" >&2
        exit 1
    fi
}

# Commands every run needs. ufw/iptables are checked only when blocking, logger is optional.
REQUIRED_CMDS=(awk sort gzip stat date mktemp)

require_cmds() {
    local c
    for c in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$c" >/dev/null 2>&1; then die "required command not found: $c"; fi
    done
}

# ---------------------------------------------------------------- config

is_posint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# Strict KEY=value parser. The file is NOT sourced, so it cannot run code or
# overwrite command-line state. Unknown keys are errors (catches typos).
load_config() {
    local file="$1" line key val lineno=0 var
    local re_key='^([A-Z][A-Z0-9_]*)=(.*)$'
    local re_quoted='^"([^"]*)"[[:space:]]*(#.*)?$'
    local re_bare='^([^[:space:]#"'"'"']*)[[:space:]]*(#.*)?$'

    if [[ ! -f "$file" ]]; then die "config file not found: $file"; fi
    if [[ ! -r "$file" ]]; then die "cannot read config file: $file"; fi

    # defaults
    AUTH_LOG="/var/log/auth.log"
    LOG_FILE="/var/log/logwatch.log"
    AUTO_REPORT_DIR="/var/lib/logwatch/auto"
    MANUAL_REPORT_DIR="/var/lib/logwatch/manual"
    TOP_N=10
    MAX_ATTEMPT=5
    BLOCK_MODE="temporary"
    WHITELIST="127.0.0.1 ::1"
    BLOCK_CHAIN="ufw-before-input"
    BLOCK_CHAIN6="ufw6-before-input"

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        if [[ -z "$line" || "$line" == \#* ]]; then continue; fi
        if [[ ! "$line" =~ $re_key ]]; then
            die "config line $lineno: expected KEY=value"
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        if [[ "$val" == \"* ]]; then
            if [[ "$val" =~ $re_quoted ]]; then val="${BASH_REMATCH[1]}"
            else die "config line $lineno: bad quoted value for $key"; fi
        else
            if [[ "$val" =~ $re_bare ]]; then val="${BASH_REMATCH[1]}"
            else die "config line $lineno: bad value for $key (quote it with \"...\")"; fi
        fi
        case "$key" in
            AUTH_LOG|LOG_FILE|AUTO_REPORT_DIR|MANUAL_REPORT_DIR|TOP_N|MAX_ATTEMPT|BLOCK_MODE|WHITELIST|BLOCK_CHAIN|BLOCK_CHAIN6)
                printf -v "$key" '%s' "$val" ;;
            MAX_ATTEMP)                  die "config line $lineno: MAX_ATTEMP is a typo, use MAX_ATTEMPT" ;;
            DRY_RUN|DRY_RUN_BLOCK)       die "config line $lineno: $key was replaced by BLOCK_MODE=temporary|permanent" ;;
            AUTO_LOG_DIR)                die "config line $lineno: AUTO_LOG_DIR was renamed to AUTO_REPORT_DIR" ;;
            MANUAL_LOG_DIR)              die "config line $lineno: MANUAL_LOG_DIR was renamed to MANUAL_REPORT_DIR" ;;
            *)                           die "config line $lineno: unknown key '$key'" ;;
        esac
    done < "$file"

    for var in AUTH_LOG LOG_FILE AUTO_REPORT_DIR MANUAL_REPORT_DIR; do
        val="${!var}"
        if [[ "$val" != /* || "$val" == "/" || "$val" == *..* ]]; then
            die "config: $var must be an absolute path, not '/' and without '..' (got '$val')"
        fi
    done
    if ! is_posint "$TOP_N"; then die "config: TOP_N must be a positive integer (got '$TOP_N')"; fi
    if ! is_posint "$MAX_ATTEMPT"; then die "config: MAX_ATTEMPT must be a positive integer (got '$MAX_ATTEMPT')"; fi
    BLOCK_MODE="${BLOCK_MODE,,}"
    case "$BLOCK_MODE" in
        temporary|permanent) ;;
        *) die "config: BLOCK_MODE must be temporary or permanent (got '$BLOCK_MODE')" ;;
    esac
    WHITELIST="${WHITELIST,,}"
    WHITELIST="${WHITELIST//,/ }"
    if [[ ! "$WHITELIST" =~ ^[0-9a-f:.\ ]*$ ]]; then
        die "config: WHITELIST may contain only IP addresses separated by spaces or commas"
    fi
    for var in BLOCK_CHAIN BLOCK_CHAIN6; do
        if [[ ! "${!var}" =~ ^[A-Za-z0-9_-]+$ ]]; then die "config: $var has invalid characters"; fi
    done
    debug "config loaded: $file"
    debug "TOP_N=$TOP_N MAX_ATTEMPT=$MAX_ATTEMPT BLOCK_MODE=$BLOCK_MODE NO_ACTION=$NO_ACTION"
}

# ---------------------------------------------------------------- time

# NOW is captured once; every section of a run uses it. Windows are half-open
# [start, end): a line stamped exactly "end" belongs to the next window.
init_time() {
    NOW="${LOGWATCH_NOW:-$(date '+%Y-%m-%dT%H:%M:%S')}"
    if [[ ! "$NOW" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        die "LOGWATCH_NOW must look like 2026-11-14T16:53:00 (got '$NOW')"
    fi
    TODAY="${NOW%%T*}"
}

is_valid_date() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$(date -d "$1" +%F 2>/dev/null)" == "$1" ]]
}

# ---------------------------------------------------------------- collect + aggregate

# One awk pass. Writes in $out: win.tsv and all.tsv (ip<TAB>user<TAB>count), meta.tsv (oldest, newest).
read -r -d '' AWK_AGG <<'AWK' || true
function clean(s) {
    gsub(/[^[:print:]]/, "?", s)
    if (length(s) > 64) s = substr(s, 1, 61) "..."
    return s
}
BEGIN {
    isore = "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"
    printf "" > (out "/win.tsv")
    printf "" > (out "/all.tsv")
    printf "" > (out "/meta.tsv")
}
{
    ts = substr($1, 1, 19)
    if (ts !~ isore) next
    if (ts >= aend) next
    if (mn == "" || ts < mn) mn = ts
    if (ts > mx) mx = ts
    if (index($0, "Failed password for ") == 0) next
    sub(/\r$/, "")
    if ($3 !~ /^(sshd|sshd-session)\[[0-9]+\]:$/) next
    msg = $0
    sub(/^[^ ]+ +[^ ]+ +[^ ]+ +/, "", msg)
    n = 1
    if (substr(msg, 1, 17) == "message repeated ") {
        if (!match(msg, /^message repeated [0-9]+ times: \[ ?/)) next
        hdr = substr(msg, 1, RLENGTH)
        msg = substr(msg, RLENGTH + 1)
        sub(/\]$/, "", msg)
        gsub(/[^0-9]/, "", hdr)
        n = hdr + 0
        if (n < 1) next
    }
    if (substr(msg, 1, 20) != "Failed password for ") next
    rest = substr(msg, 21)
    if (!match(rest, / port [0-9]+ ssh2$/)) next
    rest = substr(rest, 1, RSTART - 1)
    pos = 0; off = 0; t = rest
    while ((i = index(t, " from ")) > 0) { pos = off + i; off += i; t = substr(t, i + 1) }
    if (pos == 0) next
    user = substr(rest, 1, pos - 1)
    ip = tolower(substr(rest, pos + 6))
    if (ip !~ /^[0-9a-f:.]+$/) next
    if (ip !~ /[.:]/) next
    if (ip ~ /^::ffff:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip = substr(ip, 8)
    if (substr(user, 1, 13) == "invalid user ") user = substr(user, 14)
    if (user == "") user = "(empty)"
    key = ip "\t" clean(user)
    if (need_all) all[key] += n
    if (ts >= start && ts < wend) win[key] += n
}
END {
    for (k in win) print k "\t" win[k] > (out "/win.tsv")
    for (k in all) print k "\t" all[k] > (out "/all.tsv")
    print mn "\t" mx > (out "/meta.tsv")
}
AWK

# analyze_window START WEND NEED_ALL
#   START/WEND: YYYY-MM-DDTHH:MM:SS, window is [START, WEND). All-time ends at NOW.
#   NEED_ALL=0 skips old rotated files and the all-time table (hourly analyze stays fast).
analyze_window() {
    local start="$1" wend="$2" need_all="$3"
    local f first mt start_epoch
    local -a cand=() files=()

    WSTART="$start"; WEND="$wend"
    if [[ ! -f "$AUTH_LOG" || ! -r "$AUTH_LOG" ]]; then
        die "auth log not found or unreadable: $AUTH_LOG"
    fi
    start_epoch="$(date -d "${start/T/ }" +%s)"
    cand=("$AUTH_LOG" "$AUTH_LOG".*)

    for f in "${cand[@]}"; do
        if [[ ! -f "$f" || ! -r "$f" ]]; then continue; fi
        if [[ "$f" != "$AUTH_LOG" && "$need_all" == 0 ]]; then
            mt="$(stat -c %Y -- "$f")"
            if (( mt < start_epoch - 3600 )); then debug "skip (older than window): $f"; continue; fi
        fi
        first=""
        IFS= read -r first < <(gzip -cdf -- "$f" 2>/dev/null) || true
        if [[ -z "$first" ]]; then debug "skip (empty): $f"; continue; fi
        if [[ ! "$first" =~ $ISO_RE ]]; then
            if [[ "$f" == "$AUTH_LOG" ]]; then die "$f does not use ISO 8601 timestamps (rsyslog RSYSLOG_FileFormat required)"; fi
            log WARN "skipping $f: not ISO 8601 timestamps"
            continue
        fi
        debug "reading: $f"
        files+=("$f")
    done

    WORK="$(mktemp -d)"
    if ! {
        for f in "${files[@]}"; do
            gzip -cdf -- "$f" 2>/dev/null || log WARN "could not read $f"
            printf '\n'    # a file without a final newline must not glue its last line to the next file
        done
    } | awk -v out="$WORK" -v start="$start" -v wend="$wend" -v aend="$NOW" -v need_all="$need_all" "$AWK_AGG"; then
        die "log analysis failed"
    fi
    debug "window [$start, $wend) read ${#files[@]} file(s)"
}

# ---------------------------------------------------------------- render

sum_by() {   # $1=file $2=1(ip)|2(user)  ->  key<TAB>sum
    awk -F'\t' -v f="$2" '{ s[$f] += $3 } END { for (k in s) print k "\t" s[k] }' "$1"
}

# IPs whose failures are strictly greater than MAX_ATTEMPT, heaviest first (ties by IP)
exceed_list() {
    sum_by "$1" 1 | awk -F'\t' -v m="$MAX_ATTEMPT" '$2 > m' | sort -t "$TAB" -k2,2nr -k1,1
}

render_scope() {   # $1 = pair table
    local f="$1" total ips users nex
    read -r total ips users < <(awk -F'\t' '
        { t += $3; if (!($1 in a)) { a[$1]; ni++ } if (!($2 in b)) { b[$2]; nu++ } }
        END { printf "%d %d %d\n", t, ni, nu }' "$f")
    printf 'Failed password attempts: %s   distinct IPs: %s   distinct usernames: %s\n' "$total" "$ips" "$users"

    printf '\n1) Top %s (IP, username) pairs\n' "$TOP_N"
    sort -t "$TAB" -k3,3nr -k1,1 -k2,2 "$f" |
        awk -F'\t' -v n="$TOP_N" 'NR <= n { printf "   %7d  %-39s  %s\n", $3, $1, $2 } END { if (NR == 0) print "   (none)" }'

    printf '\n2) Top %s IPs by failed attempts (any username)\n' "$TOP_N"
    sum_by "$f" 1 | sort -t "$TAB" -k2,2nr -k1,1 |
        awk -F'\t' -v n="$TOP_N" 'NR <= n { printf "   %7d  %s\n", $2, $1 } END { if (NR == 0) print "   (none)" }'

    printf '\n3) Top %s usernames tried (from any IP)\n' "$TOP_N"
    sum_by "$f" 2 | sort -t "$TAB" -k2,2nr -k1,1 |
        awk -F'\t' -v n="$TOP_N" 'NR <= n { printf "   %7d  %s\n", $2, $1 } END { if (NR == 0) print "   (none)" }'

    nex="$(exceed_list "$f" | awk 'END { print NR }')"
    printf '\n4) IPs with more than %s failed attempts (MAX_ATTEMPT): %s in total\n' "$MAX_ATTEMPT" "$nex"
    exceed_list "$f" |
        awk -F'\t' -v n="$TOP_N" -v wl="$WHITELIST" '
            BEGIN { m = split(wl, w, " "); for (i = 1; i <= m; i++) ok[w[i]] = 1 }
            NR <= n { printf "   %7d  %s%s\n", $2, $1, ($1 in ok) ? "  (whitelisted)" : "" }
            END { if (NR == 0) print "   (none)"; else if (NR > n) printf "   +%d more\n", NR - n }'
}

report_header() {
    printf 'LogWatch %s\n' "$RPT_KIND"
    printf 'Generated: %s (server local time)\n' "$NOW"
    printf 'Source:    %s (+ rotated files)\n' "$AUTH_LOG"
    printf 'Counted:   sshd "Failed password" events (valid and invalid users)\n'
    printf 'Settings:  TOP_N=%s  MAX_ATTEMPT=%s (flagged when failures > MAX_ATTEMPT)\n' "$TOP_N" "$MAX_ATTEMPT"
}

# Window only (used by logwatch.sh --analyze)
build_window_only() {
    report_header
    printf '\n== Period %s to %s (end exclusive) ==\n\n' "$WSTART" "$WEND"
    render_scope "$WORK/win.tsv"
}

# Window + all available logs (used by --report)
build_report() {
    local mn mx
    IFS="$TAB" read -r mn mx < "$WORK/meta.tsv" || true
    report_header
    printf '\n== Period %s to %s (end exclusive) ==\n\n' "$WSTART" "$WEND"
    render_scope "$WORK/win.tsv"
    printf '\n\n== All available logs ==\n'
    printf 'Coverage: %s to %s (only as old as the rotated logs still on disk)\n\n' "${mn:-n/a}" "${mx:-n/a}"
    render_scope "$WORK/all.tsv"
}

# emit_report DIR FILENAME   (builds with build_report; atomic write; -n prints instead)
emit_report() {
    local dir="$1" name="$2"
    if (( NO_ACTION )); then
        echo "[dry-run] would write $dir/$name" >&2
        build_report
        return 0
    fi
    mkdir -p -- "$dir" || die "cannot create report directory: $dir"
    TMP_REPORT="$(mktemp -- "$dir/.$name.XXXXXX")" || die "cannot write in $dir"
    build_report > "$TMP_REPORT"
    mv -f -- "$TMP_REPORT" "$dir/$name"
    TMP_REPORT=""
    REPORT_PATH="$dir/$name"
    log INFO "report written: $REPORT_PATH"
}

# ---------------------------------------------------------------- blocking

is_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [[ "$o" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( o <= 255 )) || return 1
    done
    [[ "$ip" != "0.0.0.0" ]]
}

# groups_ok STR : every ':'-separated group is 1-4 hex digits; sets GROUPS_N
groups_ok() {
    local s="$1" g
    local -a arr=()
    GROUPS_N=0
    if [[ -z "$s" ]]; then return 0; fi
    IFS=: read -r -a arr <<< "$s"
    for g in "${arr[@]}"; do
        [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        GROUPS_N=$((GROUPS_N + 1))
    done
}

is_ipv6() {
    local ip="${1,,}" left right n
    [[ "$ip" =~ ^[0-9a-f:]+$ ]] || return 1
    [[ "$ip" != *:::* ]] || return 1
    if [[ "$ip" == *::* ]]; then
        left="${ip%%::*}"
        right="${ip#*::}"
        [[ "$right" != *::* ]] || return 1
        groups_ok "$left" || return 1; n=$GROUPS_N
        groups_ok "$right" || return 1; n=$((n + GROUPS_N))
        (( n >= 1 && n <= 7 ))          # "::" alone (unspecified) is refused
    else
        groups_ok "$ip" || return 1
        (( GROUPS_N == 8 ))
    fi
}

in_whitelist() {
    local w
    for w in $WHITELIST; do
        if [[ "$w" == "$1" ]]; then return 0; fi
    done
    return 1
}

quote_cmd() { printf '%q ' "$@"; printf '\n'; }

block_temporary() {   # $1=ip $2=4|6   raw iptables rule in ufw's own chain: gone on ufw reload/restart/reboot
    local ip="$1" fam="$2" bin chain
    if [[ "$fam" == 4 ]]; then bin=iptables;  chain="$BLOCK_CHAIN"; else bin=ip6tables; chain="$BLOCK_CHAIN6"; fi
    local -a rule=(-s "$ip" -m comment --comment logwatch -j DROP)
    if (( NO_ACTION )); then
        echo "[dry-run] mode=temporary (add -y for a permanent ufw rule)"
        printf '[dry-run] '; quote_cmd "$bin" -w -I "$chain" 1 "${rule[@]}"
        return 0
    fi
    command -v "$bin" >/dev/null 2>&1 || die "$bin not found"
    "$bin" -w -n -L "$chain" >/dev/null 2>&1 || die "chain '$chain' not found ($bin); is ufw enabled?"
    if "$bin" -w -C "$chain" "${rule[@]}" 2>/dev/null; then
        log INFO "already blocked (temporary): $ip"
        echo "$ip is already blocked (temporary rule)"
        return 0
    fi
    "$bin" -w -I "$chain" 1 "${rule[@]}" || die "failed to add $bin rule for $ip"
    log INFO "blocked $ip temporarily ($bin chain $chain; cleared by ufw reload/restart or reboot)"
    echo "Blocked $ip temporarily (removed on ufw reload/restart or reboot)"
}

block_permanent() {   # $1=ip
    local ip="$1" st
    if (( NO_ACTION )); then
        echo "[dry-run] mode=permanent"
        printf '[dry-run] '; quote_cmd ufw insert 1 deny from "$ip" comment logwatch
        return 0
    fi
    command -v ufw >/dev/null 2>&1 || die "ufw not found"
    st="$(ufw status 2>&1 || true)"
    if [[ "$st" != "Status: active"* ]]; then die "ufw is not active; a rule added now would not be enforced"; fi
    if ! ufw insert 1 deny from "$ip" comment logwatch; then
        log WARN "ufw insert failed (empty rule set?), retrying: ufw deny from $ip"
        ufw deny from "$ip" comment logwatch || die "ufw could not add a deny rule for $ip"
    fi
    log INFO "blocked $ip permanently (ufw deny from, comment logwatch)"
    echo "Blocked $ip permanently (ufw rule labelled 'logwatch'; remove: sudo ufw status numbered, then sudo ufw delete <number>)"
}

# block_ip IP : BLOCK_MODE=temporary -> iptables rule (permanent only with -y)
#               BLOCK_MODE=permanent -> always ufw.   -n previews the command only.
block_ip() {
    local ip="${1,,}" fam perm=0
    if [[ "$ip" =~ ^::ffff:([0-9.]+)$ ]]; then ip="${BASH_REMATCH[1]}"; fi
    if is_ipv4 "$ip"; then fam=4
    elif is_ipv6 "$ip"; then fam=6
    else usage_error "not a single valid IPv4/IPv6 address: $1"; fi
    if in_whitelist "$ip"; then die "refusing to block $ip: it is in WHITELIST"; fi
    if [[ -n "${SSH_CONNECTION:-}" && "${SSH_CONNECTION%% *}" == "$ip" ]]; then
        die "refusing to block $ip: it is your current SSH connection"
    fi
    if [[ "$BLOCK_MODE" == permanent ]] || (( CONFIRM )); then perm=1; fi
    if (( perm )); then block_permanent "$ip"; else block_temporary "$ip" "$fam"; fi
}