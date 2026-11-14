#!/usr/bin/env bash
# LogWatch installer. Must be run as root (the program reads the ssh auth log).
#
# Installs:
#   /usr/local/bin/logwatch.sh, logwatch-auto.sh, logwatch-lib.sh   (all in one dir;
#                                                                    the scripts find the lib next to themselves)
#   /etc/logwatch/logwatch.conf        (never overwritten; a new copy goes to .conf.new)
#   /etc/cron.d/logwatch               (schedule)
#   /etc/logrotate.d/logwatch          (log rotation)
# Created by the program itself at run time (not by this script):
#   LOG_FILE, AUTO_REPORT_DIR, MANUAL_REPORT_DIR  (paths come from the config file)
#
# Safe to run again: scripts, cron and logrotate files are replaced, config is kept.
set -euo pipefail

readonly PROJECT="logwatch"
readonly BIN_DIR="/usr/local/bin"
readonly CONF_DIR="/etc/${PROJECT}"
readonly CONF_FILE="${CONF_DIR}/${PROJECT}.conf"
readonly CRON_FILE="/etc/cron.d/${PROJECT}"
readonly LOGROTATE_FILE="/etc/logrotate.d/${PROJECT}"

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }
info() { echo "==> $*"; }

usage() {
    cat <<USAGE
Usage: sudo ./install.sh [-h]

Installs LogWatch (scripts, config, cron job, logrotate rule). Must be run as root.
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "")        ;;
    *)         usage >&2; exit 2 ;;
esac

# 1. root ---------------------------------------------------------------------
if (( EUID != 0 )); then die "must be run as root (try: sudo ./install.sh)"; fi

# 2. source files -------------------------------------------------------------
# The scripts folder is "binn" in this repo; fall back to "bin".
SCRIPTS_SRC=""
for d in binn bin; do
    if [[ -d "$SRC_DIR/$d" ]]; then SCRIPTS_SRC="$SRC_DIR/$d"; break; fi
done
[[ -n "$SCRIPTS_SRC" ]] || die "scripts folder (binn/ or bin/) not found in $SRC_DIR"

readonly CONF_SRC="$SRC_DIR/config/logwatch.conf"
readonly CRON_SRC="$SRC_DIR/cron/logwatch.crontab"
readonly LOGROTATE_SRC="$SRC_DIR/config/logwatch.logrotate"

for f in "$SCRIPTS_SRC/logwatch.sh" "$SCRIPTS_SRC/logwatch-auto.sh" "$SCRIPTS_SRC/logwatch-lib.sh" \
         "$CONF_SRC" "$CRON_SRC" "$LOGROTATE_SRC"; do
    [[ -f "$f" ]] || die "missing source file: $f"
done

# 3. dependencies -------------------------------------------------------------
if (( BASH_VERSINFO[0] < 4 )); then die "bash >= 4 is required (found $BASH_VERSION)"; fi

missing=()
for c in bash awk sort gzip stat date mktemp flock install readlink sed grep tail; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if (( ${#missing[@]} > 0 )); then die "required command(s) not found: ${missing[*]}"; fi

# The scripts use GNU extensions (date -d, readlink -f); BusyBox/BSD versions fail.
date -d "1 day ago" +%F >/dev/null 2>&1 || die "GNU date is required (date -d is not supported here)"
readlink -f -- "$SRC_DIR" >/dev/null 2>&1 || die "GNU readlink is required (readlink -f is not supported here)"

# Optional: only some features need these.
command -v logger >/dev/null 2>&1 || warn "'logger' not found: alerts will not reach the journal"
for c in ufw iptables ip6tables; do
    command -v "$c" >/dev/null 2>&1 || warn "'$c' not found: logwatch.sh --block will not work"
done

HAVE_CRON=1
if [[ ! -d /etc/cron.d ]]; then
    HAVE_CRON=0
    warn "/etc/cron.d not found: cron is not installed, the schedule will NOT be set up (install cron, then run this again)"
fi
HAVE_LOGROTATE=1
if [[ ! -d /etc/logrotate.d ]]; then
    HAVE_LOGROTATE=0
    warn "/etc/logrotate.d not found: logrotate is not installed, the log file will grow without limit"
fi

# 4. ssh log ------------------------------------------------------------------
AUTH_LOG_FOUND=""
for f in /var/log/auth.log /var/log/secure; do
    if [[ -r "$f" ]]; then AUTH_LOG_FOUND="$f"; break; fi
done
if [[ -z "$AUTH_LOG_FOUND" ]]; then
    warn "no ssh log found (/var/log/auth.log or /var/log/secure). Set AUTH_LOG in $CONF_FILE after installing."
fi

# 5. directories --------------------------------------------------------------
info "creating $CONF_DIR"
install -d -m 755 -o root -g root "$CONF_DIR"

# 6. scripts (lib sits next to the scripts; it is sourced, not executed) -------
info "installing scripts to $BIN_DIR"
install -m 755 -o root -g root "$SCRIPTS_SRC/logwatch.sh"      "$BIN_DIR/logwatch.sh"
install -m 755 -o root -g root "$SCRIPTS_SRC/logwatch-auto.sh" "$BIN_DIR/logwatch-auto.sh"
install -m 644 -o root -g root "$SCRIPTS_SRC/logwatch-lib.sh"  "$BIN_DIR/logwatch-lib.sh"

# 7. config (keep the admin's file) -------------------------------------------
if [[ -e "$CONF_FILE" ]]; then
    info "config exists, keeping it: $CONF_FILE (new default saved as ${CONF_FILE}.new)"
    install -m 644 -o root -g root "$CONF_SRC" "${CONF_FILE}.new"
else
    info "installing config: $CONF_FILE"
    install -m 644 -o root -g root "$CONF_SRC" "$CONF_FILE"
    if [[ -n "$AUTH_LOG_FOUND" && "$AUTH_LOG_FOUND" != "/var/log/auth.log" ]]; then
        sed -i "s|^AUTH_LOG=\"[^\"]*\"|AUTH_LOG=\"${AUTH_LOG_FOUND}\"|" "$CONF_FILE"
        info "AUTH_LOG set to $AUTH_LOG_FOUND"
    fi
fi

# 8. cron ---------------------------------------------------------------------
if (( HAVE_CRON )); then
    info "installing cron job: $CRON_FILE"
    install -m 644 -o root -g root "$CRON_SRC" "$CRON_FILE"
fi

# 9. logrotate ----------------------------------------------------------------
if (( HAVE_LOGROTATE )); then
    info "installing logrotate rule: $LOGROTATE_FILE"
    install -m 644 -o root -g root "$LOGROTATE_SRC" "$LOGROTATE_FILE"
fi

# 10. SELinux labels (RHEL/Fedora); harmless elsewhere ------------------------
if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$BIN_DIR/logwatch.sh" "$BIN_DIR/logwatch-auto.sh" "$BIN_DIR/logwatch-lib.sh" \
        "$CONF_DIR" "$CRON_FILE" "$LOGROTATE_FILE" 2>/dev/null || true
fi

# 11. check -------------------------------------------------------------------
info "checking the install"
"$BIN_DIR/logwatch.sh" -h      >/dev/null || die "installed logwatch.sh does not run"
"$BIN_DIR/logwatch-auto.sh" -h >/dev/null || die "installed logwatch-auto.sh does not run"

# 12. summary -----------------------------------------------------------------
cat <<DONE

LogWatch installed.
  scripts   : $BIN_DIR/logwatch.sh, logwatch-auto.sh, logwatch-lib.sh
  config    : $CONF_FILE
  cron      : $( ((HAVE_CRON)) && echo "$CRON_FILE" || echo "(not installed)" )
  logrotate : $( ((HAVE_LOGROTATE)) && echo "$LOGROTATE_FILE" || echo "(not installed)" )
Logs and reports are created on first run (see LOG_FILE / *_REPORT_DIR in the config).
Edit WHITELIST in the config to add your admin IPs, then try: sudo logwatch.sh -h
DONE
