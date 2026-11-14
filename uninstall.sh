#!/usr/bin/env bash
# LogWatch uninstaller. Must be run as root.
#
# Always removes what install.sh put in place: the 3 scripts, the cron job and the
# logrotate rule. Config, logs and reports are removed only with --purge (or after a
# "y" answer). Their paths are read from the config file BEFORE it is deleted, so
# custom LOG_FILE / AUTO_REPORT_DIR / MANUAL_REPORT_DIR values are covered too.
# The config is read with grep (never sourced), same rule as the program itself.
set -euo pipefail

readonly PROJECT="logwatch"
readonly BIN_DIR="/usr/local/bin"
readonly CONF_DIR="/etc/${PROJECT}"
readonly CONF_FILE="${CONF_DIR}/${PROJECT}.conf"
readonly CRON_FILE="/etc/cron.d/${PROJECT}"
readonly LOGROTATE_FILE="/etc/logrotate.d/${PROJECT}"

# Same defaults as logwatch-lib.sh
LOG_FILE="/var/log/logwatch.log"
AUTO_REPORT_DIR="/var/lib/logwatch/auto"
MANUAL_REPORT_DIR="/var/lib/logwatch/manual"

PURGE=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
    cat <<USAGE
Usage: sudo ./uninstall.sh [--purge] [-h]

  --purge   also delete config, log files and reports without asking
  -h        this help

Without --purge you are asked whether to delete config, logs and reports.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --purge)   PURGE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; exit 2 ;;
    esac
done

if (( EUID != 0 )); then die "must be run as root (try: sudo ./uninstall.sh)"; fi

# conf_get KEY : last KEY="value" or KEY=value in the config (comments stripped)
conf_get() {
    [[ -r "$CONF_FILE" ]] || return 0
    sed -n "s/^$1=\"\{0,1\}\([^\"# ]*\).*/\1/p" "$CONF_FILE" | tail -n 1
}

# 1. read paths from the config before it is deleted ---------------------------
if [[ -r "$CONF_FILE" ]]; then
    v="$(conf_get LOG_FILE)";          if [[ -n "$v" ]]; then LOG_FILE="$v"; fi
    v="$(conf_get AUTO_REPORT_DIR)";   if [[ -n "$v" ]]; then AUTO_REPORT_DIR="$v"; fi
    v="$(conf_get MANUAL_REPORT_DIR)"; if [[ -n "$v" ]]; then MANUAL_REPORT_DIR="$v"; fi
    info "paths read from $CONF_FILE"
else
    info "no config at $CONF_FILE, using default paths"
fi

# safe_path P : absolute, not "/", no "..", and the name must contain "logwatch"
safe_path() {
    local p="$1"
    if [[ -z "$p" || "$p" != /* || "$p" == "/" || "$p" == *..* ]]; then
        echo "skip (unsafe path): '$p'" >&2; return 1
    fi
    if [[ "$p" != *"$PROJECT"* ]]; then
        echo "skip (path has no '$PROJECT' in it, delete by hand if you want): $p" >&2; return 1
    fi
}

remove_dir() {
    local p="$1"
    safe_path "$p" || return 0
    if [[ -e "$p" ]]; then rm -rf -- "$p"; info "removed $p"; fi
}

remove_logs() {
    local f
    shopt -s nullglob
    for f in "$LOG_FILE" "$LOG_FILE".* ; do
        [[ -e "$f" ]] || continue
        safe_path "$f" || continue
        rm -f -- "$f"; info "removed $f"
    done
    for f in /var/log/logwatch-cron.log /var/log/logwatch-cron.log.*; do
        [[ -e "$f" ]] || continue
        rm -f -- "$f"; info "removed $f"
    done
    shopt -u nullglob
}

# 2. always remove what install.sh put in place --------------------------------
for f in "$BIN_DIR/logwatch.sh" "$BIN_DIR/logwatch-auto.sh" "$BIN_DIR/logwatch-lib.sh" \
         "$CRON_FILE" "$LOGROTATE_FILE" \
         /run/lock/logwatch-analyze.lock /run/lock/logwatch-report.lock; do
    if [[ -e "$f" ]]; then rm -f -- "$f"; info "removed $f"; fi
done

# 3. config, logs, reports: only after a yes ----------------------------------
DO_PURGE=0
if (( PURGE )); then
    DO_PURGE=1
elif [[ -t 0 ]]; then
    echo
    echo "These hold your data and settings and cannot be recovered:"
    echo "  config  : $CONF_DIR"
    echo "  log     : $LOG_FILE (+ rotated copies, logwatch-cron.log)"
    echo "  reports : $AUTO_REPORT_DIR, $MANUAL_REPORT_DIR"
    read -r -p "Delete them too? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then DO_PURGE=1; fi
fi

if (( DO_PURGE )); then
    remove_logs
    remove_dir "$AUTO_REPORT_DIR"
    remove_dir "$MANUAL_REPORT_DIR"
    rmdir --ignore-fail-on-non-empty "/var/lib/${PROJECT}" 2>/dev/null || true
    remove_dir "$CONF_DIR"
else
    info "kept config, logs and reports (run with --purge to delete them)"
fi

echo "LogWatch uninstalled."
