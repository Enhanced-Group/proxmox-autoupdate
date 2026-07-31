#!/usr/bin/env bash
# ==============================================================================
# Proxmox Master Auto-Update — with Fancy Output, Stopped Guest Support
# & Windows VM Updates via QEMU Guest Agent
# ==============================================================================

# Read by the web panel's "check for updates" and shown in its footer. Keep the
# literal assignment on one line — it is grepped, not sourced.
PAU_VERSION="3.2.0"

set -u
set -o pipefail

# --- ARGUMENTS ---
# Parsed before anything else so --help works without a config file present.
# CLI_DRY_RUN stays empty unless the flag is given, so the config file remains
# authoritative when it isn't.
CLI_DRY_RUN=""
ONLY_IDS=""
SEND_EMAIL="true"
DETACH="false"
RAW_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run)
            CLI_DRY_RUN="true"
            ;;
        --detach)
            DETACH="true"
            ;;
        --only)
            ONLY_IDS="${2:-}"
            shift
            ;;
        --only=*)
            ONLY_IDS="${1#*=}"
            ;;
        --no-email)
            SEND_EMAIL="false"
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: update-everything.sh [options]

  -n, --dry-run     Report what would be updated without changing anything.
                    No packages are installed, no snapshots are taken and no
                    reboot is scheduled. A report is still emailed.

  --only <ids>      Update only these VM/CT IDs (comma-separated), and skip the
                    Proxmox host entirely. No reboot is ever scheduled in this
                    mode — it is for touching one guest without a full sweep.

  --no-email        Do not send any notification for this run. Useful when the
                    output is already being watched live.

  --detach          Hand the run to systemd and return immediately. Use this
                    from the Proxmox web shell: the run then survives closing
                    the browser tab, and is watchable with
                    'journalctl -fu pve-autoupdate-run'.

  -h, --help        Show this message.

All other settings come from /etc/proxmox-autoupdate.conf
USAGE
            exit 0
            ;;
        *)
            echo "[!] Unknown option: $1 (try --help)"
            exit 1
            ;;
    esac
    shift
done

# Normalise and validate the target list up front — a typo here should fail
# immediately, not halfway through a sweep.
if [ -n "${ONLY_IDS}" ]; then
    ONLY_IDS=$(echo "${ONLY_IDS}" | tr -d '[:space:]')
    if ! echo "${ONLY_IDS}" | grep -qE '^[0-9]+(,[0-9]+)*$'; then
        echo "[!] --only expects comma-separated numeric IDs (got '${ONLY_IDS}')"
        exit 1
    fi
fi

# --- SURVIVE LOSING THE TERMINAL ---
# The Proxmox web shell is a termproxy session: closing the browser tab makes it
# exit and SIGHUP everything in the session. An update killed part way through
# leaves dpkg half-configured, so refuse to die from a hangup.
trap '' HUP

# --detach re-execs the run under systemd so it is owned by the init system
# rather than by the shell that launched it. Nothing else about the run changes.
if [ "${DETACH}" = "true" ]; then
    if ! command -v systemd-run >/dev/null 2>&1; then
        echo "[!] --detach needs systemd-run, which is not available here."
        echo "    Use:  setsid nohup $0 <args> >/var/log/proxmox-autoupdate/detached.log 2>&1 &"
        exit 1
    fi
    DETACHED_ARGS=()
    for a in "${RAW_ARGS[@]}"; do
        [ "${a}" = "--detach" ] || DETACHED_ARGS+=("${a}")
    done
    UNIT_NAME="pve-autoupdate-run"
    systemctl reset-failed "${UNIT_NAME}.service" >/dev/null 2>&1 || true
    if systemd-run --unit="${UNIT_NAME}" --collect --description="Proxmox Auto-Update (detached)" \
            "$0" "${DETACHED_ARGS[@]+"${DETACHED_ARGS[@]}"}" >/dev/null 2>&1; then
        echo "[*] Update started in the background as ${UNIT_NAME}.service"
        echo "    It will keep running if you close this shell."
        echo ""
        echo "    Watch it:   journalctl -fu ${UNIT_NAME}"
        echo "    Check it:   systemctl status ${UNIT_NAME}"
        exit 0
    fi
    echo "[!] Could not start the detached unit — is one already running?"
    echo "    Check:  systemctl status ${UNIT_NAME}"
    exit 1
fi

# Ensure UK timezone formatting for date commands
export TZ="Europe/London"

# Ensure full PATH for cron execution (pct, qm, pveversion live in sbin dirs)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# --- LOCKFILE (prevent concurrent runs) ---
LOCKFILE="/var/run/proxmox-autoupdate.lock"
exec 200>"${LOCKFILE}"
if ! flock -n 200; then
    echo "[!] Another instance of proxmox-autoupdate is already running. Exiting."
    exit 1
fi

# ==============================================================================
# VISUAL OUTPUT LIBRARY
# ==============================================================================

# Detect interactive terminal
INTERACTIVE=false
[ -t 1 ] && INTERACTIVE=true

# ANSI color codes
if [ "${INTERACTIVE}" = true ]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_NC='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_DIM='' C_NC=''
fi

# Spinner state
_SPIN_PID=""

# The spinner writes to /dev/tty rather than stdout so it never lands in the log.
# If the terminal disappears mid-run — closing the Proxmox shell tab does exactly
# that — those writes must not block or kill the run, so the fd is opened once,
# up front, and every write is guarded. If it can't be opened, the spinner is
# simply disabled for the rest of the run.
_TTY_OK=false
if [ "${INTERACTIVE}" = true ] && exec 9>/dev/tty 2>/dev/null; then
    _TTY_OK=true
fi

start_spinner() {
    local msg="$1"
    [ "${_TTY_OK}" = true ] || return 0
    (
        trap 'exit 0' TERM
        trap '' HUP
        local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            printf "\r  \033[0;36m%s\033[0m %s" "${chars:$i:1}" "$msg" >&9 2>/dev/null || exit 0
            i=$(( (i + 1) % ${#chars} ))
            sleep 0.08
        done
    ) &
    _SPIN_PID=$!
    disown "$_SPIN_PID" 2>/dev/null
}

stop_spinner() {
    if [ -n "${_SPIN_PID}" ]; then
        kill "${_SPIN_PID}" 2>/dev/null
        wait "${_SPIN_PID}" 2>/dev/null || true
        _SPIN_PID=""
        [ "${_TTY_OK}" = true ] && { printf "\r\033[K" >&9 2>/dev/null || true; }
    fi
}

# Ensure spinner is killed and the log tee is flushed on script exit.
# Closing stdout/stderr first lets `tee` see EOF, otherwise the tail of the run
# can be lost when the shell exits before the tee has written it out.
cleanup() {
    stop_spinner
    rm -f "${HTML_FILE:-}" "${NOTIFY_RESPONSE_FILE:-}"
    if [ -n "${TEE_PID:-}" ]; then
        exec 1>&- 2>&-
        wait "${TEE_PID}" 2>/dev/null || true
    fi
    # KEEP_LOGS=false: the log existed only so this run could be watched live.
    if [ "${KEEP_LOGS:-true}" = "false" ] && [ -n "${LOG_FILE:-}" ]; then
        rm -f "${LOG_FILE}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Output helpers — these go to both log and terminal
print_ok()     { echo -e "  ${C_GREEN}✓${C_NC} $1"; }
print_fail()   { echo -e "  ${C_RED}✗${C_NC} $1"; }
print_warn()   { echo -e "  ${C_YELLOW}⚠${C_NC} $1"; }
print_skip()   { echo -e "  ${C_DIM}⊘ $1${C_NC}"; }
print_action() { echo -e "  ${C_CYAN}▶${C_NC} $1"; }
print_stop()   { echo -e "  ${C_YELLOW}■${C_NC} $1"; }

section_header() {
    local title="$1"
    local width=60
    local pad_len=$(( width - ${#title} - 2 ))
    [ "${pad_len}" -lt 2 ] && pad_len=2
    local padding=$(printf '─%.0s' $(seq 1 ${pad_len}))
    echo ""
    echo -e "${C_BOLD}${C_CYAN}── ${title} ${padding}${C_NC}"
}

print_box_top() {
    echo -e "${C_BOLD}${C_CYAN}╔═══════════════════════════════════════════════════════════╗${C_NC}"
}

print_box_bottom() {
    echo -e "${C_BOLD}${C_CYAN}╚═══════════════════════════════════════════════════════════╝${C_NC}"
}

print_box_line() {
    local text="$1"
    local raw_text="$2"
    local raw_len=${#raw_text}
    local pad=$(( 57 - raw_len ))
    [ "${pad}" -lt 0 ] && pad=0
    local spaces
    spaces=$(printf '%*s' "${pad}" '')
    echo -e "${C_BOLD}${C_CYAN}║${C_NC}  ${text}${spaces}${C_BOLD}${C_CYAN}║${C_NC}"
}

print_banner() {
    echo ""
    print_box_top
    print_box_line "${C_BOLD}Proxmox Auto-Update${C_NC}" "Proxmox Auto-Update"
    local line2_fmt="Host: ${C_BOLD}${HOST_NAME}${C_NC} │ ${TIMESTAMP}"
    local line2_raw="Host: ${HOST_NAME} | ${TIMESTAMP}"
    print_box_line "${line2_fmt}" "${line2_raw}"
    print_box_bottom
}

# Run a command with a spinner, capturing output
# Usage: run_with_spinner "message" command args...
# Sets: _RUN_OUTPUT (stdout), _RUN_EXIT (exit code)
run_with_spinner() {
    local msg="$1"
    shift
    local tmpfile="/tmp/pve_update_out_$$"
    start_spinner "$msg"
    _RUN_EXIT=0
    _RUN_OUTPUT=$("$@" 2>&1) || _RUN_EXIT=$?
    stop_spinner
}

# ==============================================================================
# CONFIGURATION
# ==============================================================================

CONFIG_FILE="/etc/proxmox-autoupdate.conf"

if [ ! -f "${CONFIG_FILE}" ]; then
    echo -e "${C_RED}[!] FATAL: Configuration file not found: ${CONFIG_FILE}${C_NC}"
    echo "    Run the installer to create it: curl -sSL https://raw.githubusercontent.com/Enhanced-Group/proxmox-autoupdate/main/install.sh | bash"
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# --- NOTIFICATIONS ---
# Notification is a reporting layer, not a prerequisite for updating. Nothing
# here is required: an unconfigured install still updates on schedule, it just
# stays quiet. Channels can be added at any time without reinstalling.
#
# NOTIFY_METHODS is a comma-separated list of: email, discord, slack, webhook.
# Empty or "none" disables notification entirely.
NOTIFY_METHODS="${NOTIFY_METHODS:-}"

MAILGUN_API_KEY="${MAILGUN_API_KEY:-}"
MAILGUN_DOMAIN="${MAILGUN_DOMAIN:-}"
MAILGUN_REGION="${MAILGUN_REGION:-EU}"
SENDER_EMAIL="${SENDER_EMAIL:-}"
RECIPIENT_EMAIL="${RECIPIENT_EMAIL:-}"

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
GENERIC_WEBHOOK_URL="${GENERIC_WEBHOOK_URL:-}"

# Stay silent on clean runs, so the channel only fires when something needs you.
NOTIFY_ON_FAILURE_ONLY="${NOTIFY_ON_FAILURE_ONLY:-false}"

# Backwards compatibility: installs that predate NOTIFY_METHODS configured
# Mailgun and nothing else, so honour that rather than going silent on upgrade.
if [ -z "${NOTIFY_METHODS}" ] && [ -n "${MAILGUN_API_KEY}" ] && [ -n "${RECIPIENT_EMAIL}" ]; then
    NOTIFY_METHODS="email"
fi

# Drop any channel that isn't actually configured, and say so once, rather than
# failing a run over a reporting problem.
NOTIFY_ACTIVE=""
NOTIFY_DISABLED=""
for METHOD in $(echo "${NOTIFY_METHODS}" | tr ',' ' '); do
    case "${METHOD}" in
        none|"") ;;
        email)
            if [ -n "${MAILGUN_API_KEY}" ] && [ -n "${MAILGUN_DOMAIN}" ] \
               && [ -n "${SENDER_EMAIL}" ] && [ -n "${RECIPIENT_EMAIL}" ]; then
                NOTIFY_ACTIVE="${NOTIFY_ACTIVE} email"
            else
                NOTIFY_DISABLED="${NOTIFY_DISABLED} email(incomplete Mailgun settings)"
            fi
            ;;
        discord)
            if [ -n "${DISCORD_WEBHOOK_URL}" ]; then
                NOTIFY_ACTIVE="${NOTIFY_ACTIVE} discord"
            else
                NOTIFY_DISABLED="${NOTIFY_DISABLED} discord(no URL)"
            fi
            ;;
        slack)
            if [ -n "${SLACK_WEBHOOK_URL}" ]; then
                NOTIFY_ACTIVE="${NOTIFY_ACTIVE} slack"
            else
                NOTIFY_DISABLED="${NOTIFY_DISABLED} slack(no URL)"
            fi
            ;;
        webhook)
            if [ -n "${GENERIC_WEBHOOK_URL}" ]; then
                NOTIFY_ACTIVE="${NOTIFY_ACTIVE} webhook"
            else
                NOTIFY_DISABLED="${NOTIFY_DISABLED} webhook(no URL)"
            fi
            ;;
        *)
            NOTIFY_DISABLED="${NOTIFY_DISABLED} ${METHOD}(unknown)"
            ;;
    esac
done
NOTIFY_ACTIVE=$(echo "${NOTIFY_ACTIVE}" | xargs || true)
NOTIFY_DISABLED=$(echo "${NOTIFY_DISABLED}" | xargs || true)

# Resolve Mailgun API base URL from region
if [ "${MAILGUN_REGION}" = "EU" ]; then
    MAILGUN_API_URL="https://api.eu.mailgun.net/v3/${MAILGUN_DOMAIN}/messages"
else
    MAILGUN_API_URL="https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages"
fi

# Optional config values with defaults
EXCLUDE_IDS="${EXCLUDE_IDS:-}"
WINDOWS_UPDATE_TIMEOUT="${WINDOWS_UPDATE_TIMEOUT:-1200}"
START_STOPPED_WINDOWS="${START_STOPPED_WINDOWS:-false}"
START_STOPPED_LXC="${START_STOPPED_LXC:-true}"
START_STOPPED_LINUX_VMS="${START_STOPPED_LINUX_VMS:-true}"
REBOOT_TIME="${REBOOT_TIME:-00:00}"

# How long a Linux guest (VM or LXC) gets to finish its upgrade, in seconds.
# A real dist-upgrade over a slow mirror routinely exceeds five minutes.
LINUX_UPDATE_TIMEOUT="${LINUX_UPDATE_TIMEOUT:-1800}"

# How long apt waits for the dpkg/apt lock inside a guest before giving up.
# Distros with unattended-upgrades enabled (Ubuntu by default) will otherwise
# fail with exit code 100 whenever the two happen to overlap.
APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-600}"

# Dry run: report what would be upgraded without changing anything.
# No packages are installed, no snapshots are taken, no reboot is scheduled.
DRY_RUN="${DRY_RUN:-false}"

# Take a snapshot of each guest before upgrading it ("true" or "false").
# Requires a storage backend that supports snapshots (ZFS, LVM-thin, qcow2...).
SNAPSHOT_BEFORE_UPDATE="${SNAPSHOT_BEFORE_UPDATE:-false}"

# How many auto-generated snapshots to keep per guest before pruning the oldest.
SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-3}"

# Prefix identifying snapshots this script owns. Only these are ever pruned.
SNAPSHOT_PREFIX="autoupdate"

# --- LOGGING ---
# KEEP_LOGS=false still writes a log during the run — the web UI streams it —
# but deletes it on exit, so nothing accumulates on disk.
KEEP_LOGS="${KEEP_LOGS:-true}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-90}"
LOG_DIR="${LOG_DIR:-/var/log/proxmox-autoupdate}"

# Where run history lives, so a report can say "this guest has failed 3 runs"
# instead of treating every run as the first.
STATE_DIR="/var/lib/proxmox-autoupdate"
STATE_FILE="${STATE_DIR}/state.json"

# Normalise booleans so a stray "TRUE"/"yes" in the config still behaves.
normalise_bool() {
    case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        true|yes|y|1|on) echo "true" ;;
        *)               echo "false" ;;
    esac
}
DRY_RUN=$(normalise_bool "${DRY_RUN}")
SNAPSHOT_BEFORE_UPDATE=$(normalise_bool "${SNAPSHOT_BEFORE_UPDATE}")
START_STOPPED_WINDOWS=$(normalise_bool "${START_STOPPED_WINDOWS}")
START_STOPPED_LXC=$(normalise_bool "${START_STOPPED_LXC}")
START_STOPPED_LINUX_VMS=$(normalise_bool "${START_STOPPED_LINUX_VMS}")
KEEP_LOGS=$(normalise_bool "${KEEP_LOGS}")
NOTIFY_ON_FAILURE_ONLY=$(normalise_bool "${NOTIFY_ON_FAILURE_ONLY}")

# --dry-run on the command line overrides the config file, never the reverse.
[ -n "${CLI_DRY_RUN}" ] && DRY_RUN="true"

# Validate the numeric settings — a typo here would otherwise surface as an
# arithmetic error deep inside a poll loop.
for _NUM_VAR in WINDOWS_UPDATE_TIMEOUT LINUX_UPDATE_TIMEOUT APT_LOCK_TIMEOUT \
                SNAPSHOT_KEEP LOG_RETENTION_DAYS; do
    if ! [[ "${!_NUM_VAR}" =~ ^[0-9]+$ ]]; then
        echo -e "${C_RED}[!] FATAL: ${_NUM_VAR} must be a positive integer (got '${!_NUM_VAR}')${C_NC}"
        exit 1
    fi
done

# ==============================================================================
# SYSTEM & LOG SETUP
# ==============================================================================

HOST_NAME=$(hostname -f 2>/dev/null || hostname)
NODE_NAME=$(hostname -s 2>/dev/null || hostname)
TIMESTAMP=$(date '+%d/%m/%Y %H:%M:%S')
HTML_FILE="/tmp/update_report_$$.html"

# Logging: persist all output to a log file
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/update_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
TEE_PID=$!

# Prune old logs. Retention of 0 means "keep forever".
if [ "${LOG_RETENTION_DAYS}" -gt 0 ]; then
    find "${LOG_DIR}" -name '*.log' -mtime +"${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
fi

# --- jq is a hard dependency ---
# Every guest-agent response is parsed as JSON. Hand-rolled regex parsing of
# pvesh output silently returns nothing when the shape changes, which shows up
# as a bogus timeout rather than an error, so refuse to run without jq.
for TOOL in jq python3; do
    if ! command -v "${TOOL}" >/dev/null 2>&1; then
        print_action "${TOOL} not found — installing..."
        DEBIAN_FRONTEND=noninteractive apt-get install -qy "${TOOL}" >/dev/null 2>&1 || true
    fi
    if ! command -v "${TOOL}" >/dev/null 2>&1; then
        echo -e "${C_RED}[!] FATAL: ${TOOL} is required but could not be installed.${C_NC}"
        echo "    Install it manually:  apt-get install -y jq python3"
        exit 1
    fi
done

# Summary counters
LXC_UPDATED=0
LXC_CURRENT=0
LXC_STARTED=0
LXC_ERRORS=0
LXC_SKIPPED=0
LXC_EXCLUDED=0

VM_UPDATED=0
VM_CURRENT=0
VM_STARTED=0
VM_ERRORS=0
VM_SKIPPED=0
VM_EXCLUDED=0
VM_WIN_UPDATED=0
VM_WIN_TIMEOUT=0

HOST_PKG_COUNT=0
SNAPSHOTS_TAKEN=0

# Guests whose upgrade may still be running (timed out, or the agent went away).
# Rebooting the host under them would interrupt dpkg, so this blocks the reboot.
GUESTS_MID_UPDATE=0

ERRORS_OCCURRED=false

# ==============================================================================
# HELPER: Check if an ID is in the exclusion list
# ==============================================================================
# Uses a fixed-string match — EXCLUDE_IDS is user input and would otherwise be
# interpreted as a regex. Whitespace around commas is tolerated.
is_excluded() {
    local id="$1"
    [ -z "${EXCLUDE_IDS}" ] && return 1
    local normalised
    normalised=$(echo "${EXCLUDE_IDS}" | tr -d '[:space:]')
    echo ",${normalised}," | grep -qF ",${id}," && return 0
    return 1
}

# ==============================================================================
# HELPER: Is this guest in scope for this run?
# ==============================================================================
# With --only, everything outside the target list is silently passed over: it is
# not "skipped" in the reporting sense, it simply isn't part of this run.
is_targeted() {
    local id="$1"
    [ -z "${ONLY_IDS}" ] && return 0
    echo ",${ONLY_IDS}," | grep -qF ",${id}," && return 0
    return 1
}

# ==============================================================================
# HELPER: Read a single field from `qm config` / `pct config`
# ==============================================================================
# Keeps values that contain spaces intact, unlike `awk '{print $2}'`.
config_field() {
    local cmd="$1" id="$2" key="$3"
    "${cmd}" config "${id}" 2>/dev/null \
        | sed -n "s/^${key}:[[:space:]]*//p" \
        | head -1
}

# ==============================================================================
# HELPER: Wait for a container/VM to reach a status
# ==============================================================================
wait_for_status() {
    local type="$1"   # "ct" or "vm"
    local id="$2"
    local target="$3" # e.g., "running" or "stopped"
    local timeout="$4"
    local elapsed=0

    while [ ${elapsed} -lt ${timeout} ]; do
        local current=""
        if [ "$type" = "ct" ]; then
            current=$(pct status "$id" 2>/dev/null | awk '{print $2}')
        else
            current=$(qm status "$id" 2>/dev/null | awk '{print $2}')
        fi
        [ "$current" = "$target" ] && return 0
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# ==============================================================================
# HELPER: Wait for QEMU guest agent to respond
# ==============================================================================
wait_for_agent() {
    local vmid="$1"
    local timeout="$2"
    local elapsed=0

    while [ ${elapsed} -lt ${timeout} ]; do
        if qm agent "${vmid}" ping >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

# ==============================================================================
# HELPER: Detect VM operating system via guest agent
# ==============================================================================
detect_vm_os() {
    local vmid="$1"
    local os_info=""
    os_info=$(pvesh get "/nodes/${NODE_NAME}/qemu/${vmid}/agent/get-osinfo" \
        --output-format json 2>/dev/null) || true

    if [ -n "$os_info" ]; then
        if echo "$os_info" | grep -qi "mswindows\|windows\|microsoft"; then
            echo "windows"
            return
        fi
    fi
    echo "linux"
}

# ==============================================================================
# HELPER: Take a pre-update snapshot, pruning old ones we own
# ==============================================================================
# Returns 0 on success (or when snapshots are disabled), 1 on failure.
# Never fatal on its own — the caller decides whether to continue.
take_snapshot() {
    local kind="$1"   # "ct" or "vm"
    local id="$2"
    local cmd="pct"
    [ "${kind}" = "vm" ] && cmd="qm"

    [ "${SNAPSHOT_BEFORE_UPDATE}" != "true" ] && return 0
    if [ "${DRY_RUN}" = "true" ]; then
        print_skip "Snapshot of ${id} skipped ${C_DIM}[dry run]${C_NC}"
        return 0
    fi

    # Prune oldest auto-snapshots first so we stay at SNAPSHOT_KEEP after adding
    # one. Only names carrying our prefix are ever considered.
    local existing prune_count
    existing=$("${cmd}" listsnapshot "${id}" 2>/dev/null \
        | grep -oE "${SNAPSHOT_PREFIX}[0-9_]*" | sort || true)
    if [ -n "${existing}" ]; then
        prune_count=$(( $(echo "${existing}" | wc -l) - SNAPSHOT_KEEP + 1 ))
        if [ "${prune_count}" -gt 0 ]; then
            echo "${existing}" | head -n "${prune_count}" | while read -r snap; do
                [ -z "${snap}" ] && continue
                "${cmd}" delsnapshot "${id}" "${snap}" >/dev/null 2>&1 || true
            done
        fi
    fi

    local snap_name="${SNAPSHOT_PREFIX}_$(date +%Y%m%d_%H%M%S)"
    if "${cmd}" snapshot "${id}" "${snap_name}" \
        --description "Pre-update snapshot taken by proxmox-autoupdate" >/dev/null 2>&1; then
        SNAPSHOTS_TAKEN=$((SNAPSHOTS_TAKEN + 1))
        return 0
    fi
    return 1
}

# ==============================================================================
# HELPER: The update script that runs *inside* a Linux guest
# ==============================================================================
# Emitted once and shared by both the LXC and VM paths so the two can't drift.
#
# It communicates through sentinels rather than through its exit status, because
# apt legitimately exits non-zero for reasons that are not update failures
# (lock contention, needrestart, services that can't restart in a container).
# Sentinels understood by the caller:
#
#   __PKG__ <name> (<old> -> <new>)   a package that was actually upgraded
#   __HELD__ <name>                   still upgradable after the run
#   __RESULT__ OK|FAIL|UNSUPPORTED    overall outcome
#   __DETAIL__ <text>                 one-line reason when FAIL
#   __LOG__ <text>                    trailing diagnostic output
#
# Everything is read from stdin by /bin/bash, so each command gets </dev/null to
# stop apt from swallowing the rest of this script off the shared stdin.
build_guest_update_script() {
    cat <<GUESTSCRIPT
export DEBIAN_FRONTEND=noninteractive
# needrestart interactively prompts about service restarts on Ubuntu 22.04+ and
# can exit non-zero; force it to act automatically and stay quiet.
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFOLD=1

APT_OPTS="-o DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT} -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
DRY_RUN="${DRY_RUN}"
WORK_LOG=\$(mktemp 2>/dev/null || echo /tmp/.pau_log)

emit_log() { tail -n 20 "\${WORK_LOG}" 2>/dev/null | sed 's/^/__LOG__ /' || true; }

# Package name -> "old -> new" from \`apt list --upgradable\` output.
list_upgradable() {
    apt list --upgradable 2>/dev/null | grep '/' || true
}

# Turn "pkg/suite 2.0 amd64 [upgradable from: 1.0]" into "__PKG__ pkg (1.0 -> 2.0)".
# The marker apt actually emits is "upgradable from:", not "from:".
format_upgradable() {
    awk -F'/' '{
        pkg=\$1;
        split(\$2, a, " ");
        new_ver=a[2];
        old_ver="";
        if (match(\$0, /upgradable from: [^]]+/)) {
            old_ver=substr(\$0, RSTART+17, RLENGTH-17);
        }
        if (old_ver == "")
            print "__PKG__ " pkg " (" new_ver ")";
        else
            print "__PKG__ " pkg " (" old_ver " -> " new_ver ")";
    }'
}

if command -v apt-get >/dev/null 2>&1; then
    # The guest may have only just booted, so DNS and routing can lag behind the
    # guest agent coming up. Retry rather than reporting a hard failure.
    UPDATE_RC=1
    ATTEMPT=1
    while [ \${ATTEMPT} -le 5 ]; do
        if apt-get \${APT_OPTS} update -qy </dev/null >"\${WORK_LOG}" 2>&1; then
            UPDATE_RC=0
            break
        fi
        UPDATE_RC=\$?
        sleep 5
        ATTEMPT=\$((ATTEMPT + 1))
    done

    if [ \${UPDATE_RC} -ne 0 ]; then
        echo "__RESULT__ FAIL"
        echo "__DETAIL__ apt-get update failed after 5 attempts (exit \${UPDATE_RC})"
        emit_log
        exit 0
    fi

    BEFORE=\$(list_upgradable)

    if [ -z "\${BEFORE}" ]; then
        echo "__RESULT__ OK"
        exit 0
    fi

    if [ "\${DRY_RUN}" = "true" ]; then
        # Report the pending set without touching the system.
        echo "\${BEFORE}" | format_upgradable
        echo "__RESULT__ OK"
        exit 0
    fi

    if apt-get \${APT_OPTS} dist-upgrade -qy </dev/null >"\${WORK_LOG}" 2>&1; then
        UPGRADE_RC=0
    else
        UPGRADE_RC=\$?
    fi

    apt-get \${APT_OPTS} autoremove -qy </dev/null >/dev/null 2>&1 || true
    apt-get \${APT_OPTS} autoclean -qy </dev/null >/dev/null 2>&1 || true

    # Report what actually changed by diffing the upgradable set, rather than
    # trusting the pre-upgrade list. Anything still listed did not get applied.
    AFTER_NAMES=\$(list_upgradable | cut -d/ -f1)
    echo "\${BEFORE}" | while IFS= read -r line; do
        [ -z "\${line}" ] && continue
        name=\${line%%/*}
        # -x -F: whole-line fixed-string match, so names containing regex
        # metacharacters (python3.12, libstdc++6) compare exactly.
        if echo "\${AFTER_NAMES}" | grep -qxF "\${name}"; then
            echo "__HELD__ \${name}"
        else
            echo "\${line}" | format_upgradable
        fi
    done

    if [ \${UPGRADE_RC} -eq 0 ]; then
        echo "__RESULT__ OK"
    else
        echo "__RESULT__ FAIL"
        echo "__DETAIL__ apt-get dist-upgrade exited \${UPGRADE_RC}"
        emit_log
    fi

elif command -v dnf >/dev/null 2>&1; then
    dnf -q check-update </dev/null 2>/dev/null | awk 'NF==3 {print "__PKG__ " \$1 " (" \$2 ")"}' || true
    if [ "\${DRY_RUN}" = "true" ]; then
        echo "__RESULT__ OK"
    elif dnf -y upgrade -q </dev/null >"\${WORK_LOG}" 2>&1; then
        echo "__RESULT__ OK"
    else
        echo "__RESULT__ FAIL"
        echo "__DETAIL__ dnf upgrade failed"
        emit_log
    fi

elif command -v yum >/dev/null 2>&1; then
    yum -q check-update </dev/null 2>/dev/null | awk 'NF==3 {print "__PKG__ " \$1 " (" \$2 ")"}' || true
    if [ "\${DRY_RUN}" = "true" ]; then
        echo "__RESULT__ OK"
    elif yum -y update -q </dev/null >"\${WORK_LOG}" 2>&1; then
        echo "__RESULT__ OK"
    else
        echo "__RESULT__ FAIL"
        echo "__DETAIL__ yum update failed"
        emit_log
    fi

elif command -v apk >/dev/null 2>&1; then
    apk update -q </dev/null >/dev/null 2>&1 || true
    apk version -l '<' 2>/dev/null | awk 'NR>1 && NF>=3 {print "__PKG__ " \$1}' || true
    if [ "\${DRY_RUN}" = "true" ]; then
        echo "__RESULT__ OK"
    elif apk upgrade -q </dev/null >"\${WORK_LOG}" 2>&1; then
        echo "__RESULT__ OK"
    else
        echo "__RESULT__ FAIL"
        echo "__DETAIL__ apk upgrade failed"
        emit_log
    fi

else
    echo "__RESULT__ UNSUPPORTED"
fi

rm -f "\${WORK_LOG}" 2>/dev/null || true
GUESTSCRIPT
}

# ==============================================================================
# HELPER: Poll a guest-agent exec until it finishes
# ==============================================================================
# Sets the globals GX_STATE, GX_EXITCODE, GX_OUT and GX_ERR.
#
#   GX_STATE = done      the process exited; GX_EXITCODE holds its real status
#              timeout   still running when the budget ran out
#              apierror  exec-status could not be read after repeated retries
#              badjson   exec-status replied, but not with parseable JSON
#
# Note that the agent's "exited" field is a boolean meaning "has finished", not
# an exit status — the status lives in "exitcode". PVE renders it as either 1 or
# true depending on version, so both are accepted.
guest_exec_wait() {
    local vmid="$1"
    local exec_pid="$2"
    local timeout="$3"
    local poll_interval="${4:-5}"

    GX_STATE="timeout"
    GX_EXITCODE=""
    GX_OUT=""
    GX_ERR=""

    local max_polls=$(( timeout / poll_interval ))
    [ "${max_polls}" -lt 1 ] && max_polls=1
    local wait_count=0
    local consecutive_failures=0
    local parse_failures=0

    while [ ${wait_count} -lt ${max_polls} ]; do
        local exec_status=""
        if ! exec_status=$(pvesh get "/nodes/${NODE_NAME}/qemu/${vmid}/agent/exec-status" \
                --pid "${exec_pid}" --output-format json 2>/dev/null); then
            # A single hiccup on the API or the agent socket is not a failed
            # update. Only give up after three consecutive misses.
            consecutive_failures=$((consecutive_failures + 1))
            if [ ${consecutive_failures} -ge 3 ]; then
                GX_STATE="apierror"
                return
            fi
            sleep ${poll_interval}
            wait_count=$((wait_count + 1))
            continue
        fi
        consecutive_failures=0

        # A reply that isn't JSON will never become JSON on a later poll — it
        # means --output-format json isn't being honoured. Fail fast and say so,
        # rather than silently burning the whole timeout and reporting a bogus
        # "timed out" for an update that actually ran.
        local exited=""
        if ! exited=$(echo "${exec_status}" | jq -r '.exited // empty' 2>/dev/null); then
            parse_failures=$((parse_failures + 1))
            if [ ${parse_failures} -ge 2 ]; then
                GX_STATE="badjson"
                GX_OUT="${exec_status}"
                return
            fi
            sleep ${poll_interval}
            wait_count=$((wait_count + 1))
            continue
        fi

        case "${exited}" in
            1|true)
                GX_EXITCODE=$(echo "${exec_status}" | jq -r '.exitcode // 0' 2>/dev/null || echo 0)
                GX_OUT=$(echo "${exec_status}" | jq -r '."out-data" // empty' 2>/dev/null || true)
                GX_ERR=$(echo "${exec_status}" | jq -r '."err-data" // empty' 2>/dev/null || true)
                # Flag truncation so a clipped package list isn't mistaken for a
                # short one.
                if [ "$(echo "${exec_status}" | jq -r '."out-truncated" // empty' 2>/dev/null)" = "true" ]; then
                    GX_OUT="${GX_OUT}
__LOG__ (output truncated by the guest agent)"
                fi
                GX_STATE="done"
                return
                ;;
        esac

        sleep ${poll_interval}
        wait_count=$((wait_count + 1))
    done

    GX_STATE="timeout"
}

# ==============================================================================
# HELPER: Format `apt list --upgradable` output for the host report
# ==============================================================================
# Same transformation the guest script applies, minus the __PKG__ marker (the
# host has no sentinel protocol to speak). Note the marker apt emits is
# "upgradable from:", not "from:".
format_upgradable_host() {
    awk -F'/' '{
        pkg=$1;
        split($2, a, " ");
        new_ver=a[2];
        old_ver="";
        if (match($0, /upgradable from: [^]]+/)) {
            old_ver=substr($0, RSTART+17, RLENGTH-17);
        }
        if (old_ver == "")
            print pkg " (" new_ver ")";
        else
            print pkg " (" old_ver " -> " new_ver ")";
    }'
}

# ==============================================================================
# RUN STATE
# ==============================================================================
# Persists across runs so a report can say "VM 101 has failed 3 runs in a row"
# rather than treating every run as the first, and so the web UI can colour its
# button from the last result without parsing logs.

# Guests that failed this run: "<id>|<name>|<detail>" per line.
FAILED_THIS_RUN=""
REPEAT_OFFENDERS=""

record_guest_failure() {
    FAILED_THIS_RUN="${FAILED_THIS_RUN}$1|$2|$3
"
}

# Merging this run into the stored history is fiddly enough — streaks that reset
# only for guests the run actually covered — that expressing it as a jq pipeline
# made it hard to read and harder to test. Python 3 is already required by the
# web panel and ships with Proxmox, so the merge lives in one readable helper
# that can be exercised directly.
#
# State updates are best-effort throughout: failing to record history must never
# turn a successful update into a failed run.
STATE_HELPER='
import json, os, sys

state_file, result, finished, log, scope = sys.argv[1:6]
counts = json.loads(sys.argv[6])
failures = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    parts = line.split("|", 2)
    failures.append({
        "id": parts[0],
        "name": parts[1] if len(parts) > 1 else "",
        "detail": parts[2] if len(parts) > 2 else "",
    })

try:
    with open(state_file) as fh:
        state = json.load(fh)
    if not isinstance(state, dict):
        raise ValueError
except (OSError, ValueError):
    state = {}

guests = state.get("guests") or {}
if not isinstance(guests, dict):
    guests = {}

failed_ids = {f["id"] for f in failures}
covered = None if scope == "all" else set(scope.split(","))

# A guest only gets its streak cleared if this run actually looked at it — a
# targeted run must not mark untouched guests as recovered.
for gid, entry in list(guests.items()):
    if gid in failed_ids or not isinstance(entry, dict):
        continue
    if covered is None or gid in covered:
        entry["consecutive_failures"] = 0

for f in failures:
    previous = guests.get(f["id"]) or {}
    try:
        streak = int(previous.get("consecutive_failures") or 0)
    except (TypeError, ValueError):
        streak = 0
    guests[f["id"]] = {
        "name": f["name"],
        "detail": f["detail"],
        "last_failed": finished,
        "consecutive_failures": streak + 1,
    }

last_run = {
    "result": result, "finished": finished, "log": log,
    "scope": scope, "counts": counts, "failed": sorted(failed_ids),
}
state["guests"] = guests
state["last_run"] = last_run
state["runs"] = ([last_run] + (state.get("runs") or []))[:20]

tmp = state_file + ".tmp"
with open(tmp, "w") as fh:
    json.dump(state, fh, indent=2)
os.replace(tmp, state_file)
'

state_write() {
    command -v python3 >/dev/null 2>&1 || return 0
    mkdir -p "${STATE_DIR}" 2>/dev/null || return 0

    local result="ok"
    [ "${ERRORS_OCCURRED}" = true ] && result="error"
    [ "${DRY_RUN}" = "true" ] && result="${result}-dryrun"

    local counts
    counts=$(printf '{"lxc_updated":%d,"lxc_errors":%d,"vm_updated":%d,"vm_errors":%d,"host_packages":%d,"mid_update":%d}' \
        "${LXC_UPDATED}" "${LXC_ERRORS}" "${VM_UPDATED}" "${VM_ERRORS}" \
        "${HOST_PKG_COUNT}" "${GUESTS_MID_UPDATE}")

    printf '%s' "${FAILED_THIS_RUN}" | python3 -c "${STATE_HELPER}" \
        "${STATE_FILE}" \
        "${result}" \
        "$(date -Is)" \
        "$([ "${KEEP_LOGS}" = "true" ] && echo "${LOG_FILE}" || echo "")" \
        "$([ -n "${ONLY_IDS}" ] && echo "${ONLY_IDS}" || echo "all")" \
        "${counts}" 2>/dev/null || true

    chmod 644 "${STATE_FILE}" 2>/dev/null || true
}

# Guests that have now failed more than once in a row — the ones worth chasing.
compute_repeat_offenders() {
    [ -s "${STATE_FILE}" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    REPEAT_OFFENDERS=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        guests = (json.load(fh) or {}).get("guests") or {}
except Exception:
    sys.exit(0)
items = [(gid, g) for gid, g in guests.items()
         if isinstance(g, dict) and (g.get("consecutive_failures") or 0) > 1]
items.sort(key=lambda kv: -kv[1]["consecutive_failures"])
print(", ".join("%s (%s) x%d" % (g.get("name") or "guest", gid,
                                 g["consecutive_failures"])
                for gid, g in items))
' "${STATE_FILE}" 2>/dev/null || true)
}

# ==============================================================================
# NOTIFICATIONS
# ==============================================================================
# Every channel receives the same three things: a subject line, a plain-text
# summary, and (for email) the HTML report. Adding a channel means adding one
# notify_<name> function and a case in notify_all — nothing else changes.
#
# A failing notification never fails the run. The updates already happened; not
# being able to talk about them is a lesser problem, reported and moved past.

# Plain-text summary shared by all the webhook channels.
build_text_summary() {
    local status_line
    if [ "${ERRORS_OCCURRED}" = true ]; then
        status_line="Completed with errors"
    else
        status_line="Completed successfully"
    fi
    [ "${DRY_RUN}" = "true" ] && status_line="${status_line} (dry run — nothing installed)"
    [ -n "${ONLY_IDS}" ] && status_line="${status_line} (targeted: ${ONLY_IDS})"

    printf '%s\n\n' "${status_line}"
    printf 'Host: %s\n' "${HOST_NAME}"
    printf 'PVE:  %s\n\n' "${PVE_VERSION_AFTER:-unknown}"
    printf 'LXC:  %s updated, %s current, %s errors\n' "${LXC_UPDATED}" "${LXC_CURRENT}" "${LXC_ERRORS}"
    printf 'VMs:  %s updated, %s current, %s errors\n' "${VM_UPDATED}" "${VM_CURRENT}" "${VM_ERRORS}"
    printf 'Host: %s packages\n' "${HOST_PKG_COUNT}"
    if [ "${GUESTS_MID_UPDATE}" -gt 0 ]; then
        printf '\n%s guest(s) left running mid-update — check them.\n' "${GUESTS_MID_UPDATE}"
    fi
    if [ "${REBOOT_NEEDED}" = true ]; then
        printf '\nReboot scheduled at %s: %s\n' "${REBOOT_TIME}" "${REBOOT_REASON}"
    fi
    if [ -n "${REPEAT_OFFENDERS:-}" ]; then
        printf '\nRepeatedly failing: %s\n' "${REPEAT_OFFENDERS}"
    fi
    if [ "${KEEP_LOGS}" = "true" ]; then
        printf '\nLog: %s\n' "${LOG_FILE}"
    fi
}

# Webhook payloads are built by Python rather than assembled as text, so JSON
# escaping and the per-service length limits are handled by code that can be
# tested directly instead of by string concatenation that cannot.
#
# Reads the message body on stdin; prints one JSON object on stdout.
#   $1 = format (discord|slack|generic)   $2 = subject
PAYLOAD_HELPER='
import json, os, sys

fmt, subject = sys.argv[1], sys.argv[2]
body = sys.stdin.read()
failed = os.environ.get("PAU_FAILED") == "true"
dry = os.environ.get("PAU_DRY") == "true"

if fmt == "discord":
    # Discord rejects an embed description over 4096 characters.
    text = body[:3900]
    if len(body) > 3900:
        text += "\n… truncated, see the log for the rest"
    colour = 9807270 if dry else (15158332 if failed else 3066993)
    payload = {"embeds": [{
        "title": subject[:256],
        "description": "```\n" + text + "\n```",
        "color": colour,
        "footer": {"text": os.environ.get("PAU_FOOTER", "")[:2048]},
    }]}
elif fmt == "slack":
    text = body[:3500]
    if len(body) > 3500:
        text += "\n… truncated, see the log for the rest"
    payload = {"text": "*" + subject + "*\n```" + text + "```"}
else:
    def num(name):
        try:
            return int(os.environ.get(name, "0"))
        except ValueError:
            return 0
    payload = {
        "title": subject,
        "message": body,
        "status": "error" if failed else "success",
        "dry_run": dry,
        "host": os.environ.get("PAU_HOST", ""),
        "timestamp": os.environ.get("PAU_TIMESTAMP", ""),
        "pve_version": os.environ.get("PAU_PVE", ""),
        "log": os.environ.get("PAU_LOG", ""),
        "reboot_scheduled": os.environ.get("PAU_REBOOT") == "true",
        "repeat_offenders": os.environ.get("PAU_OFFENDERS", ""),
        "counts": {
            "lxc_updated": num("PAU_LXC_UPDATED"),
            "lxc_errors": num("PAU_LXC_ERRORS"),
            "vm_updated": num("PAU_VM_UPDATED"),
            "vm_errors": num("PAU_VM_ERRORS"),
            "host_packages": num("PAU_HOST_PKGS"),
        },
    }

sys.stdout.write(json.dumps(payload))
'

build_payload() {
    local fmt="$1" subject="$2" body="$3"
    # Exported in a subshell rather than as a `VAR=x cmd` prefix: in a pipeline
    # that prefix would apply to the left-hand command, not to the python3 on
    # the right, and every field would silently come through empty.
    (
        export PAU_FAILED PAU_DRY PAU_HOST PAU_TIMESTAMP PAU_PVE PAU_LOG \
               PAU_REBOOT PAU_OFFENDERS PAU_FOOTER PAU_LXC_UPDATED \
               PAU_LXC_ERRORS PAU_VM_UPDATED PAU_VM_ERRORS PAU_HOST_PKGS
        PAU_FAILED="$([ "${ERRORS_OCCURRED}" = true ] && echo true || echo false)"
        PAU_DRY="${DRY_RUN}"
        PAU_HOST="${HOST_NAME}"
        PAU_TIMESTAMP="${TIMESTAMP}"
        PAU_PVE="${PVE_VERSION_AFTER:-unknown}"
        PAU_LOG="$([ "${KEEP_LOGS}" = "true" ] && echo "${LOG_FILE}" || echo "")"
        PAU_REBOOT="$([ "${REBOOT_NEEDED}" = true ] && echo true || echo false)"
        PAU_OFFENDERS="${REPEAT_OFFENDERS:-}"
        PAU_FOOTER="${HOST_NAME} · ${TIMESTAMP}"
        PAU_LXC_UPDATED="${LXC_UPDATED}"
        PAU_LXC_ERRORS="${LXC_ERRORS}"
        PAU_VM_UPDATED="${VM_UPDATED}"
        PAU_VM_ERRORS="${VM_ERRORS}"
        PAU_HOST_PKGS="${HOST_PKG_COUNT}"
        printf '%s' "${body}" | python3 -c "${PAYLOAD_HELPER}" "${fmt}" "${subject}"
    )
}

# POST a payload and report the outcome. Never fails the run.
post_webhook() {
    local label="$1" url="$2" payload="$3"
    local code
    code=$(curl -s --max-time 30 -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -X POST --data-binary "${payload}" "${url}" 2>/dev/null) || code="000"
    if [ "${code}" -ge 200 ] 2>/dev/null && [ "${code}" -lt 300 ] 2>/dev/null; then
        print_ok "${label} notified"
    elif [ "${code}" = "000" ]; then
        print_fail "${label} unreachable (network error or timeout)"
    else
        print_fail "${label} returned HTTP ${code}"
    fi
}

notify_email() {
    local subject="$1" html_file="$3"
    NOTIFY_RESPONSE_FILE="/tmp/notify_response_$$.txt"
    local code
    code=$(curl -s --max-time 60 -o "${NOTIFY_RESPONSE_FILE}" -w "%{http_code}" \
        --user "api:${MAILGUN_API_KEY}" \
        "${MAILGUN_API_URL}" \
        -F from="${SENDER_EMAIL}" \
        -F to="${RECIPIENT_EMAIL}" \
        -F subject="${subject}" \
        -F html="<${html_file}" 2>&1) || true

    if [ "${code}" = "200" ]; then
        print_ok "Email sent to ${C_BOLD}${RECIPIENT_EMAIL}${C_NC}"
    else
        print_fail "Mailgun returned HTTP ${code}"
        [ -f "${NOTIFY_RESPONSE_FILE}" ] && echo "     $(head -c 400 "${NOTIFY_RESPONSE_FILE}")"
    fi
    rm -f "${NOTIFY_RESPONSE_FILE}"
}

notify_discord() {
    post_webhook "Discord" "${DISCORD_WEBHOOK_URL}" "$(build_payload discord "$1" "$2")"
}

notify_slack() {
    post_webhook "Slack/Teams" "${SLACK_WEBHOOK_URL}" "$(build_payload slack "$1" "$2")"
}

# Generic: structured JSON, so ntfy/Gotify/Home Assistant/n8n and anything else
# can pick out whichever fields it needs.
notify_webhook() {
    post_webhook "Webhook" "${GENERIC_WEBHOOK_URL}" "$(build_payload generic "$1" "$2")"
}

notify_all() {
    local subject="$1" body="$2" html_file="$3"
    start_spinner "Sending notifications (${NOTIFY_ACTIVE})..."
    stop_spinner
    local channel
    for channel in ${NOTIFY_ACTIVE}; do
        case "${channel}" in
            email)   notify_email   "${subject}" "${body}" "${html_file}" ;;
            discord) notify_discord "${subject}" "${body}" ;;
            slack)   notify_slack   "${subject}" "${body}" ;;
            webhook) notify_webhook "${subject}" "${body}" ;;
        esac
    done
}

# ==============================================================================
# HELPER: Escape text for inclusion in the HTML report
# ==============================================================================
html_escape() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# Render a package list as <li> items, or nothing when the list is empty.
html_list() {
    local items="$1"
    [ -z "${items}" ] && return 0
    echo "${items}" | html_escape | awk 'NF {print "<li>" $0 "</li>"}'
}

# Build the "Summary" cell shared by the LXC and VM tables.
# Reads GU_PKGS / GU_HELD / GU_DETAIL / GU_LOG.
guest_summary_html() {
    local heading="$1"
    local html=""
    local pkg_count=0
    [ -n "${GU_PKGS}" ] && pkg_count=$(echo "${GU_PKGS}" | grep -c . || true)

    if [ "${pkg_count}" -gt 0 ]; then
        html="<strong>${heading}</strong><ul class='pkg-list'>$(html_list "${GU_PKGS}")</ul>"
    fi
    if [ -n "${GU_HELD}" ]; then
        html="${html}<strong>Held back (still upgradable):</strong><ul class='pkg-list'>$(html_list "${GU_HELD}")</ul>"
    fi
    if [ -n "${GU_DETAIL}" ]; then
        html="${html}<div class='detail'>$(echo "${GU_DETAIL}" | html_escape)</div>"
    fi
    if [ -n "${GU_LOG}" ]; then
        html="${html}<pre class='log-snippet'>$(echo "${GU_LOG}" | html_escape)</pre>"
    fi
    echo "${html}"
}

# ==============================================================================
# HELPER: Turn sentinel output from a guest into result globals
# ==============================================================================
# Sets GU_STATE, GU_PKGS, GU_HELD, GU_DETAIL and GU_LOG.
#
# A missing __RESULT__ sentinel means the guest script did not run to
# completion — the process was killed, the agent clipped the output, or the
# shell died part way through. That is reported as "nosentinel" rather than
# being treated as a clean run, because silently reporting "up to date" for a
# guest that never finished is the worst possible failure mode here.
parse_guest_result() {
    local raw="$1"
    GU_PKGS=$(echo "${raw}"   | sed -n 's/^__PKG__ //p'    || true)
    GU_HELD=$(echo "${raw}"   | sed -n 's/^__HELD__ //p'   || true)
    GU_DETAIL=$(echo "${raw}" | sed -n 's/^__DETAIL__ //p' | head -1 || true)
    GU_LOG=$(echo "${raw}"    | sed -n 's/^__LOG__ //p'    || true)

    local result=""
    result=$(echo "${raw}" | sed -n 's/^__RESULT__ //p' | tail -1 || true)
    case "${result}" in
        OK)          GU_STATE="ok" ;;
        FAIL)        GU_STATE="fail" ;;
        UNSUPPORTED) GU_STATE="unsupported" ;;
        *)           GU_STATE="nosentinel" ;;
    esac
}

# ==============================================================================
# HELPER: Run Linux updates inside a VM via guest agent
# ==============================================================================
# Sets the same GU_* globals as parse_guest_result, plus these extra states:
#   execfail  the agent would not accept the command at all
#   timeout   the upgrade was still running when the budget expired
#   apierror  exec-status stopped answering
update_linux_vm() {
    local vmid="$1"

    GU_STATE="execfail"
    GU_PKGS=""; GU_HELD=""; GU_DETAIL=""; GU_LOG=""

    local exec_result=""
    if ! exec_result=$(pvesh create "/nodes/${NODE_NAME}/qemu/${vmid}/agent/exec" \
            --command "/bin/bash" \
            --'input-data' "$(build_guest_update_script)" \
            --output-format json 2>&1); then
        GU_DETAIL="guest agent rejected the exec request: $(echo "${exec_result}" | tail -1)"
        return
    fi

    local exec_pid=""
    exec_pid=$(echo "${exec_result}" | jq -r '.pid // empty' 2>/dev/null || true)
    if [ -z "${exec_pid}" ]; then
        GU_DETAIL="guest agent returned no PID for the exec request"
        return
    fi

    guest_exec_wait "${vmid}" "${exec_pid}" "${LINUX_UPDATE_TIMEOUT}" 5

    case "${GX_STATE}" in
        timeout)
            GU_STATE="timeout"
            return
            ;;
        apierror)
            GU_STATE="apierror"
            GU_DETAIL="exec-status stopped responding while the upgrade was running"
            return
            ;;
        badjson)
            GU_STATE="badjson"
            GU_DETAIL="exec-status did not return JSON — check that this pvesh supports --output-format json"
            GU_LOG=$(echo "${GX_OUT}" | head -n 10)
            return
            ;;
    esac

    parse_guest_result "${GX_OUT}"

    # The guest script deliberately exits 0 and reports through sentinels, so a
    # non-zero exit code here means the shell itself died — worth surfacing.
    if [ "${GU_STATE}" = "nosentinel" ] && [ -n "${GX_EXITCODE}" ] && [ "${GX_EXITCODE}" != "0" ]; then
        GU_DETAIL="guest shell exited ${GX_EXITCODE} without reporting a result"
    fi
    if [ -z "${GU_LOG}" ] && [ -n "${GX_ERR}" ]; then
        GU_LOG=$(echo "${GX_ERR}" | tail -n 20)
    fi
}

# ==============================================================================
# HELPER: Run Windows Update inside a VM via guest agent
# ==============================================================================
update_windows_vm() {
    local vmid="$1"
    local timeout="${2:-${WINDOWS_UPDATE_TIMEOUT}}"

    # PowerShell script for Windows Update (uses COM objects, no modules needed)
    local ps_script='
$ErrorActionPreference = "SilentlyContinue"
try {
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    $SearchResult = $Searcher.Search("IsInstalled=0 and Type='"'"'Software'"'"'")
    if ($SearchResult.Updates.Count -eq 0) {
        Write-Output "NO_UPDATES"
        exit 0
    }
    $Count = $SearchResult.Updates.Count
    $Names = @()
    foreach ($Update in $SearchResult.Updates) {
        $Names += $Update.Title
    }
    if ($env:PAU_DRY_RUN -eq "true") {
        Write-Output "DRYRUN:$Count"
        foreach ($name in $Names) {
            Write-Output $name
        }
        exit 0
    }
    $Downloader = $Session.CreateUpdateDownloader()
    $Downloader.Updates = $SearchResult.Updates
    $DownloadResult = $Downloader.Download()
    $Installer = New-Object -ComObject Microsoft.Update.UpdateInstaller
    $Installer.Updates = $SearchResult.Updates
    $InstallResult = $Installer.Install()
    if ($InstallResult.ResultCode -ne 2) {
        Write-Output "ERROR:Install returned result code $($InstallResult.ResultCode) (HRESULT $($InstallResult.HResult))"
        exit 0
    }
    Write-Output "UPDATED:$Count"
    foreach ($name in $Names) {
        Write-Output $name
    }
} catch {
    Write-Output "ERROR:$($_.Exception.Message)"
}
'

    # Dry run is signalled through an env var so the script body stays identical
    # between the two modes.
    if [ "${DRY_RUN}" = "true" ]; then
        ps_script="\$env:PAU_DRY_RUN = 'true'
${ps_script}"
    fi

    # Encode for PowerShell -EncodedCommand (UTF-16LE base64)
    local encoded_cmd=""
    encoded_cmd=$(echo "${ps_script}" | iconv -t UTF-16LE 2>/dev/null | base64 -w 0 2>/dev/null) || {
        echo "ENCODE_FAILED"
        return
    }

    # Execute via guest agent
    local exec_result=""
    exec_result=$(pvesh create "/nodes/${NODE_NAME}/qemu/${vmid}/agent/exec" \
        --command "powershell.exe -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded_cmd}" \
        --output-format json 2>&1) || {
        echo "EXEC_FAILED"
        return
    }

    local exec_pid=""
    exec_pid=$(echo "${exec_result}" | jq -r '.pid // empty' 2>/dev/null || true)
    if [ -z "${exec_pid}" ]; then
        echo "EXEC_FAILED"
        return
    fi

    guest_exec_wait "${vmid}" "${exec_pid}" "${timeout}" 10

    case "${GX_STATE}" in
        timeout)  echo "TIMEOUT" ;;
        apierror) echo "API_ERROR" ;;
        badjson)  echo "ERROR:exec-status did not return JSON — check that this pvesh supports --output-format json" ;;
        *)
            if [ -n "${GX_OUT}" ]; then
                echo "${GX_OUT}"
            elif [ -n "${GX_ERR}" ]; then
                echo "ERROR:$(echo "${GX_ERR}" | tail -1)"
            else
                echo "ERROR:PowerShell produced no output (exit code ${GX_EXITCODE:-unknown})"
            fi
            ;;
    esac
}

# ==============================================================================
# DISPLAY BANNER
# ==============================================================================

print_banner

if [ "${DRY_RUN}" = "true" ]; then
    echo ""
    echo -e "  ${C_YELLOW}${C_BOLD}DRY RUN${C_NC} — reporting only, nothing will be installed or rebooted"
fi

# Capture Proxmox VE Version BEFORE updates
PVE_VERSION_BEFORE=$(pveversion 2>/dev/null | awk '{print $1}' || dpkg-query -W -f='${Version}' pve-manager 2>/dev/null || echo "Unknown")
echo ""
echo -e "  PVE Version: ${C_BOLD}${PVE_VERSION_BEFORE}${C_NC}"
if [ "${SNAPSHOT_BEFORE_UPDATE}" = "true" ]; then
    echo -e "  Snapshots:   ${C_BOLD}enabled${C_NC} ${C_DIM}(keeping ${SNAPSHOT_KEEP} per guest)${C_NC}"
fi

# ==============================================================================
# 1. UPDATE LXC CONTAINERS
# ==============================================================================
section_header "LXC Containers"
LXC_HTML=""

for CTID in $(pct list | awk 'NR>1 {print $1}'); do
    is_targeted "${CTID}" || continue
    CT_NAME=$(config_field pct "${CTID}" hostname)
    [ -z "${CT_NAME}" ] && CT_NAME="LXC-${CTID}"
    CT_STATUS=$(pct status "${CTID}" | awk '{print $2}')
    CT_WAS_STOPPED=false

    # Check exclusion list
    if is_excluded "${CTID}"; then
        print_skip "LXC ${CTID} (${CT_NAME}) — excluded"
        LXC_EXCLUDED=$((LXC_EXCLUDED + 1))
        LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})</td><td><span class='status-badge badge-dim'>Excluded</span></td><td>Excluded via configuration.</td></tr>"
        continue
    fi

    # Handle stopped containers — start them
    if [ "${CT_STATUS}" != "running" ]; then
        CT_WAS_STOPPED=true
        if [ "${START_STOPPED_LXC:-true}" != "true" ]; then
            print_skip "LXC ${CTID} (${CT_NAME}) — stopped, skipped ${C_DIM}[START_STOPPED_LXC=false]${C_NC}"
            LXC_SKIPPED=$((LXC_SKIPPED + 1))
            LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})</td><td><span class='status-badge badge-warning'>Skipped</span></td><td>Stopped container — auto-start disabled in config.</td></tr>"
            continue
        fi
        print_action "Starting LXC ${CTID} (${CT_NAME}) ${C_DIM}[was stopped]${C_NC}..."

        if pct start "${CTID}" >/dev/null 2>&1; then
            if wait_for_status "ct" "${CTID}" "running" 60; then
                LXC_STARTED=$((LXC_STARTED + 1))
                # Give it a moment to initialize networking
                sleep 3
            else
                print_fail "LXC ${CTID} (${CT_NAME}) — failed to start within 60s"
                LXC_ERRORS=$((LXC_ERRORS + 1))
                ERRORS_OCCURRED=true
                record_guest_failure "${CTID}" "${CT_NAME}" "failed to start within 60s"
                LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})</td><td><span class='status-badge badge-error'>Start Failed</span></td><td>Container did not reach running state within 60 seconds.</td></tr>"
                continue
            fi
        else
            print_fail "LXC ${CTID} (${CT_NAME}) — pct start failed"
            LXC_ERRORS=$((LXC_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${CTID}" "${CT_NAME}" "pct start failed"
            LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})</td><td><span class='status-badge badge-error'>Start Failed</span></td><td>Failed to start container.</td></tr>"
            continue
        fi
    fi

    # Build suffix for display
    local_suffix=""
    [ "${CT_WAS_STOPPED}" = true ] && local_suffix=" ${C_DIM}[was stopped]${C_NC}"
    html_suffix=""
    [ "${CT_WAS_STOPPED}" = true ] && html_suffix=" <em style='color:#6c757d'>[was stopped]</em>"

    # Snapshot before touching anything, if enabled
    if [ "${SNAPSHOT_BEFORE_UPDATE}" = "true" ]; then
        start_spinner "Snapshotting LXC ${CTID} (${CT_NAME})..."
        if take_snapshot ct "${CTID}"; then
            stop_spinner
        else
            stop_spinner
            print_fail "LXC ${CTID} (${CT_NAME}) — snapshot failed, skipping update${local_suffix}"
            LXC_ERRORS=$((LXC_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${CTID}" "${CT_NAME}" "snapshot failed, skipping update"
            LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})${html_suffix}</td><td><span class='status-badge badge-error'>Snapshot Failed</span></td><td>Pre-update snapshot could not be created; the update was skipped rather than run without a rollback point.</td></tr>"
            continue
        fi
    fi

    # Container is now running — perform update.
    # `timeout` bounds the run: pct exec has no timeout of its own, so a guest
    # that wedges on a package prompt would otherwise hang the whole job.
    start_spinner "Updating LXC ${CTID} (${CT_NAME})..."
    CT_OUTPUT=""
    CT_RC=0
    CT_OUTPUT=$(build_guest_update_script | timeout "${LINUX_UPDATE_TIMEOUT}" pct exec "${CTID}" -- /bin/bash 2>&1) || CT_RC=$?
    stop_spinner

    if [ "${CT_RC}" -eq 124 ]; then
        GU_STATE="timeout"
        GU_PKGS=""; GU_HELD=""; GU_DETAIL=""; GU_LOG=""
    else
        parse_guest_result "${CT_OUTPUT}"
        if [ "${GU_STATE}" = "nosentinel" ] && [ "${CT_RC}" -ne 0 ]; then
            GU_DETAIL="pct exec exited ${CT_RC} without a result from the guest"
            GU_LOG=$(echo "${CT_OUTPUT}" | tail -n 20)
        fi
    fi

    CT_LABEL="<strong>${CTID}</strong> ($(echo "${CT_NAME}" | html_escape))${html_suffix}"
    PKG_COUNT=0
    [ -n "${GU_PKGS}" ] && PKG_COUNT=$(echo "${GU_PKGS}" | grep -c . || true)

    case "${GU_STATE}" in
        unsupported)
            print_warn "LXC ${CTID} (${CT_NAME}) — unsupported package manager${local_suffix}"
            LXC_SKIPPED=$((LXC_SKIPPED + 1))
            LXC_HTML="${LXC_HTML}<tr><td>${CT_LABEL}</td><td><span class='status-badge badge-warning'>Unsupported</span></td><td>No supported package manager found (apt/dnf/yum/apk).</td></tr>"
            ;;
        timeout)
            print_warn "LXC ${CTID} (${CT_NAME}) — update timed out after ${LINUX_UPDATE_TIMEOUT}s${local_suffix}"
            LXC_ERRORS=$((LXC_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${CTID}" "${CT_NAME}" "update timed out"
            GUESTS_MID_UPDATE=$((GUESTS_MID_UPDATE + 1))
            # An interrupted dpkg run must not be followed by a shutdown.
            CT_WAS_STOPPED=false
            LXC_HTML="${LXC_HTML}<tr><td>${CT_LABEL}</td><td><span class='status-badge badge-warning'>Timeout</span></td><td>Update did not finish within ${LINUX_UPDATE_TIMEOUT}s. Container left running so dpkg can complete — check it manually.</td></tr>"
            ;;
        nosentinel)
            print_fail "LXC ${CTID} (${CT_NAME}) — update did not report a result${local_suffix}"
            LXC_ERRORS=$((LXC_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${CTID}" "${CT_NAME}" "update did not report a result"
            [ -z "${GU_DETAIL}" ] && GU_DETAIL="The guest update script produced no __RESULT__ marker."
            LXC_HTML="${LXC_HTML}<tr><td>${CT_LABEL}</td><td><span class='status-badge badge-error'>Error</span></td><td>$(guest_summary_html "${PKG_COUNT} package(s) upgraded before the failure:")</td></tr>"
            ;;
        fail)
            print_fail "LXC ${CTID} (${CT_NAME}) — ${GU_DETAIL:-update failed}${local_suffix}"
            LXC_ERRORS=$((LXC_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${CTID}" "${CT_NAME}" "${GU_DETAIL:-update failed}"
            LXC_HTML="${LXC_HTML}<tr><td>${CT_LABEL}</td><td><span class='status-badge badge-error'>Error</span></td><td>$(guest_summary_html "${PKG_COUNT} package(s) upgraded before the failure:")</td></tr>"
            ;;
        *)
            if [ "${PKG_COUNT}" -gt 0 ] && [ "${DRY_RUN}" = "true" ]; then
                print_ok "LXC ${CTID} (${CT_NAME}) — ${C_BOLD}${PKG_COUNT} packages pending${C_NC} ${C_DIM}[dry run]${C_NC}${local_suffix}"
                LXC_UPDATED=$((LXC_UPDATED + 1))
                LXC_HTML="${LXC_HTML}<tr><td>${CT_LABEL}</td><td><span class='status-badge badge-warning'>Pending</span></td><td>$(guest_summary_html "${PKG_COUNT} package(s) would be upgraded:")</td></tr>"
            elif [ "${PKG_COUNT}" -gt 0 ]; then
                print_ok "LXC ${CTID} (${CT_NAME}) — ${C_BOLD}${PKG_COUNT} packages updated${C_NC}${local_suffix}"
                LXC_UPDATED=$((LXC_UPDATED + 1))
                LXC_HTML="${LXC_HTML}<tr><td>${CT_LABEL}</td><td><span class='status-badge badge-success'>Updated</span></td><td>$(guest_summary_html "${PKG_COUNT} package(s) updated:")</td></tr>"
            else
                print_ok "LXC ${CTID} (${CT_NAME}) — already up to date${local_suffix}"
                LXC_CURRENT=$((LXC_CURRENT + 1))
                LXC_HTML="${LXC_HTML}<tr><td>${CT_LABEL}</td><td><span class='status-badge badge-no-updates'>No Updates</span></td><td>System fully up to date.</td></tr>"
            fi
            ;;
    esac

    # Restore stopped state if needed
    if [ "${CT_WAS_STOPPED}" = true ]; then
        print_stop "Stopping LXC ${CTID} (${CT_NAME}) ${C_DIM}[restoring state]${C_NC}..."
        pct shutdown "${CTID}" >/dev/null 2>&1 || pct stop "${CTID}" >/dev/null 2>&1 || true
        wait_for_status "ct" "${CTID}" "stopped" 120 || {
            print_warn "LXC ${CTID} — shutdown timeout, forcing stop..."
            pct stop "${CTID}" >/dev/null 2>&1 || true
        }
    fi
done

# ==============================================================================
# 2. UPDATE VIRTUAL MACHINES
# ==============================================================================
section_header "Virtual Machines"
VM_HTML=""

for VMID in $(qm list | awk 'NR>1 {print $1}'); do
    is_targeted "${VMID}" || continue
    VM_NAME=$(config_field qm "${VMID}" name)
    [ -z "${VM_NAME}" ] && VM_NAME="VM-${VMID}"
    VM_STATUS=$(qm status "${VMID}" | awk '{print $2}')
    VM_WAS_STOPPED=false
    VM_OS_TYPE="linux"

    # Check exclusion list
    if is_excluded "${VMID}"; then
        print_skip "VM ${VMID} (${VM_NAME}) — excluded"
        VM_EXCLUDED=$((VM_EXCLUDED + 1))
        VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})</td><td><span class='status-badge badge-dim'>Excluded</span></td><td>Excluded via configuration.</td></tr>"
        continue
    fi

    # Handle stopped VMs — start them
    if [ "${VM_STATUS}" != "running" ]; then
        VM_WAS_STOPPED=true

        # Check if this is a Windows VM before starting (from config)
        VM_OSTYPE_CONFIG=$(config_field qm "${VMID}" ostype)
        if echo "${VM_OSTYPE_CONFIG}" | grep -qi "win"; then
            VM_OS_TYPE="windows"
            # Respect START_STOPPED_WINDOWS setting
            if [ "${START_STOPPED_WINDOWS}" != "true" ]; then
                print_skip "VM ${VMID} (${VM_NAME}) — stopped Windows VM, skipped ${C_DIM}[START_STOPPED_WINDOWS=false]${C_NC}"
                VM_SKIPPED=$((VM_SKIPPED + 1))
                VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME}) 🪟</td><td><span class='status-badge badge-warning'>Skipped</span></td><td>Stopped Windows VM — auto-start disabled in config.</td></tr>"
                continue
            fi
        else
            # Respect START_STOPPED_LINUX_VMS setting
            if [ "${START_STOPPED_LINUX_VMS:-true}" != "true" ]; then
                print_skip "VM ${VMID} (${VM_NAME}) — stopped Linux VM, skipped ${C_DIM}[START_STOPPED_LINUX_VMS=false]${C_NC}"
                VM_SKIPPED=$((VM_SKIPPED + 1))
                VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})</td><td><span class='status-badge badge-warning'>Skipped</span></td><td>Stopped Linux VM — auto-start disabled in config.</td></tr>"
                continue
            fi
        fi

        print_action "Starting VM ${VMID} (${VM_NAME}) ${C_DIM}[was stopped]${C_NC}..."

        if qm start "${VMID}" >/dev/null 2>&1; then
            if wait_for_status "vm" "${VMID}" "running" 60; then
                VM_STARTED=$((VM_STARTED + 1))
                # Wait for guest agent
                agent_timeout=120
                [ "${VM_OS_TYPE}" = "windows" ] && agent_timeout=300
                start_spinner "Waiting for guest agent on VM ${VMID} (${VM_NAME})..."
                if ! wait_for_agent "${VMID}" "${agent_timeout}"; then
                    stop_spinner
                    print_fail "VM ${VMID} (${VM_NAME}) — guest agent not responding after ${agent_timeout}s"
                    VM_ERRORS=$((VM_ERRORS + 1))
                    ERRORS_OCCURRED=true
                    record_guest_failure "${VMID}" "${VM_NAME}" "guest agent not responding"
                    VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})</td><td><span class='status-badge badge-error'>Agent Timeout</span></td><td>VM started but QEMU Guest Agent did not respond within ${agent_timeout} seconds.</td></tr>"
                    # Shut it back down
                    print_stop "Stopping VM ${VMID} (${VM_NAME}) ${C_DIM}[restoring state]${C_NC}..."
                    qm shutdown "${VMID}" >/dev/null 2>&1 || true
                    wait_for_status "vm" "${VMID}" "stopped" 120 || qm stop "${VMID}" >/dev/null 2>&1 || true
                    continue
                fi
                stop_spinner
            else
                print_fail "VM ${VMID} (${VM_NAME}) — failed to start within 60s"
                VM_ERRORS=$((VM_ERRORS + 1))
                ERRORS_OCCURRED=true
                record_guest_failure "${VMID}" "${VM_NAME}" "failed to start within 60s"
                VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})</td><td><span class='status-badge badge-error'>Start Failed</span></td><td>VM did not reach running state within 60 seconds.</td></tr>"
                continue
            fi
        else
            print_fail "VM ${VMID} (${VM_NAME}) — qm start failed"
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${VMID}" "${VM_NAME}" "qm start failed"
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})</td><td><span class='status-badge badge-error'>Start Failed</span></td><td>Failed to start VM.</td></tr>"
            continue
        fi
    fi

    # VM is now running — detect OS type if not already determined
    if [ "${VM_WAS_STOPPED}" = false ]; then
        if ! qm agent "${VMID}" ping >/dev/null 2>&1; then
            print_skip "VM ${VMID} (${VM_NAME}) — agent offline"
            VM_SKIPPED=$((VM_SKIPPED + 1))
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})</td><td><span class='status-badge badge-warning'>Agent Offline</span></td><td>QEMU Guest Agent not responding.</td></tr>"
            continue
        fi
        VM_OS_TYPE=$(detect_vm_os "${VMID}")
    elif [ "${VM_OS_TYPE}" = "linux" ]; then
        # Double-check via agent for stopped VMs that weren't pre-identified as Windows
        VM_OS_TYPE=$(detect_vm_os "${VMID}")
    fi

    # Build display suffix
    local_suffix=""
    [ "${VM_WAS_STOPPED}" = true ] && local_suffix=" ${C_DIM}[was stopped]${C_NC}"
    html_suffix=""
    [ "${VM_WAS_STOPPED}" = true ] && html_suffix=" <em style='color:#6c757d'>[was stopped]</em>"
    os_icon=""
    [ "${VM_OS_TYPE}" = "windows" ] && os_icon=" 🪟"

    VM_LABEL="<strong>${VMID}</strong> ($(echo "${VM_NAME}" | html_escape))${os_icon}${html_suffix}"

    # Snapshot before touching anything, if enabled
    if [ "${SNAPSHOT_BEFORE_UPDATE}" = "true" ]; then
        start_spinner "Snapshotting VM ${VMID} (${VM_NAME})..."
        if take_snapshot vm "${VMID}"; then
            stop_spinner
        else
            stop_spinner
            print_fail "VM ${VMID} (${VM_NAME}) — snapshot failed, skipping update${local_suffix}"
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${VMID}" "${VM_NAME}" "snapshot failed, skipping update"
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-error'>Snapshot Failed</span></td><td>Pre-update snapshot could not be created; the update was skipped rather than run without a rollback point.</td></tr>"
            continue
        fi
    fi

    # Route to the correct update handler
    if [ "${VM_OS_TYPE}" = "windows" ]; then
        # ---- WINDOWS VM UPDATE ----
        start_spinner "Updating VM ${VMID} (${VM_NAME}) [Windows]..."
        WIN_OUTPUT=$(update_windows_vm "${VMID}" "${WINDOWS_UPDATE_TIMEOUT}")
        stop_spinner

        if [ "${WIN_OUTPUT}" = "EXEC_FAILED" ] || [ "${WIN_OUTPUT}" = "ENCODE_FAILED" ]; then
            print_fail "VM ${VMID} (${VM_NAME}) — Windows Update exec failed${local_suffix}"
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${VMID}" "${VM_NAME}" "Windows Update exec failed"
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-error'>Error</span></td><td>Failed to execute Windows Update via guest agent.</td></tr>"
        elif [ "${WIN_OUTPUT}" = "API_ERROR" ]; then
            print_fail "VM ${VMID} (${VM_NAME}) — exec-status stopped responding${local_suffix}"
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${VMID}" "${VM_NAME}" "exec-status stopped responding"
            GUESTS_MID_UPDATE=$((GUESTS_MID_UPDATE + 1))
            # The update may well still be running — do not shut this VM down.
            VM_WAS_STOPPED=false
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-error'>Agent Lost</span></td><td>The guest agent stopped answering while Windows Update was running. The VM was left running; its state is unknown.</td></tr>"
        elif [ "${WIN_OUTPUT}" = "TIMEOUT" ]; then
            print_warn "VM ${VMID} (${VM_NAME}) — Windows Update timed out after ${WINDOWS_UPDATE_TIMEOUT}s${local_suffix}"
            VM_WIN_TIMEOUT=$((VM_WIN_TIMEOUT + 1))
            GUESTS_MID_UPDATE=$((GUESTS_MID_UPDATE + 1))
            # Don't shut down a Windows VM mid-update! Leave it running.
            VM_WAS_STOPPED=false
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-warning'>Timeout</span></td><td>Windows Update did not complete within ${WINDOWS_UPDATE_TIMEOUT}s. VM left running to finish.</td></tr>"
        elif [ "${WIN_OUTPUT}" = "NO_UPDATES" ]; then
            print_ok "VM ${VMID} (${VM_NAME}) — Windows already up to date${local_suffix}"
            VM_CURRENT=$((VM_CURRENT + 1))
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-no-updates'>No Updates</span></td><td>Windows is fully up to date.</td></tr>"
        elif echo "${WIN_OUTPUT}" | grep -q "^ERROR:"; then
            ERROR_MSG=$(echo "${WIN_OUTPUT}" | head -1 | sed 's/^ERROR://')
            print_fail "VM ${VMID} (${VM_NAME}) — ${ERROR_MSG}${local_suffix}"
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${VMID}" "${VM_NAME}" "${ERROR_MSG}"
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-error'>Error</span></td><td>$(echo "${ERROR_MSG}" | html_escape)</td></tr>"
        elif echo "${WIN_OUTPUT}" | grep -q "^DRYRUN:"; then
            WIN_COUNT=$(echo "${WIN_OUTPUT}" | head -1 | sed 's/^DRYRUN://')
            WIN_NAMES=$(echo "${WIN_OUTPUT}" | tail -n +2)
            print_ok "VM ${VMID} (${VM_NAME}) — ${C_BOLD}${WIN_COUNT} Windows updates pending${C_NC} ${C_DIM}[dry run]${C_NC}${local_suffix}"
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-warning'>Pending</span></td><td><strong>${WIN_COUNT} update(s) would be installed:</strong><ul class='pkg-list'>$(html_list "${WIN_NAMES}")</ul></td></tr>"
        elif echo "${WIN_OUTPUT}" | grep -q "^UPDATED:"; then
            WIN_COUNT=$(echo "${WIN_OUTPUT}" | head -1 | sed 's/^UPDATED://')
            WIN_NAMES=$(echo "${WIN_OUTPUT}" | tail -n +2)
            print_ok "VM ${VMID} (${VM_NAME}) — ${C_BOLD}${WIN_COUNT} Windows updates installed${C_NC}${local_suffix}"
            VM_WIN_UPDATED=$((VM_WIN_UPDATED + 1))
            VM_UPDATED=$((VM_UPDATED + 1))
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-success'>Updated</span></td><td><strong>${WIN_COUNT} update(s) installed:</strong><ul class='pkg-list'>$(html_list "${WIN_NAMES}")</ul></td></tr>"
        else
            # Unrecognised output means the PowerShell script did not finish.
            # Treating that as "up to date" would hide a broken guest.
            print_fail "VM ${VMID} (${VM_NAME}) — unrecognised Windows Update output${local_suffix}"
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${VMID}" "${VM_NAME}" "unrecognised Windows Update output"
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-error'>Error</span></td><td>Windows Update returned output that could not be interpreted:<pre class='log-snippet'>$(echo "${WIN_OUTPUT}" | tail -n 20 | html_escape)</pre></td></tr>"
        fi
    else
        # ---- LINUX VM UPDATE ----
        start_spinner "Updating VM ${VMID} (${VM_NAME})..."
        update_linux_vm "${VMID}"
        stop_spinner

        PKG_COUNT=0
        [ -n "${GU_PKGS}" ] && PKG_COUNT=$(echo "${GU_PKGS}" | grep -c . || true)

        case "${GU_STATE}" in
            execfail)
                print_fail "VM ${VMID} (${VM_NAME}) — guest exec failed${local_suffix}"
                VM_ERRORS=$((VM_ERRORS + 1))
                ERRORS_OCCURRED=true
                record_guest_failure "${VMID}" "${VM_NAME}" "guest exec failed"
                VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-error'>Error</span></td><td>Failed to execute update command via guest agent.<div class='detail'>$(echo "${GU_DETAIL}" | html_escape)</div></td></tr>"
                ;;
            apierror)
                print_fail "VM ${VMID} (${VM_NAME}) — ${GU_DETAIL}${local_suffix}"
                VM_ERRORS=$((VM_ERRORS + 1))
                ERRORS_OCCURRED=true
                record_guest_failure "${VMID}" "${VM_NAME}" "${GU_DETAIL}"
                GUESTS_MID_UPDATE=$((GUESTS_MID_UPDATE + 1))
                VM_WAS_STOPPED=false
                VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-error'>Agent Lost</span></td><td>The guest agent stopped answering while the upgrade was running. The VM was left running; its state is unknown.</td></tr>"
                ;;
            badjson)
                print_fail "VM ${VMID} (${VM_NAME}) — ${GU_DETAIL}${local_suffix}"
                VM_ERRORS=$((VM_ERRORS + 1))
                ERRORS_OCCURRED=true
                record_guest_failure "${VMID}" "${VM_NAME}" "${GU_DETAIL}"
                GUESTS_MID_UPDATE=$((GUESTS_MID_UPDATE + 1))
                VM_WAS_STOPPED=false
                VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-error'>Unreadable Reply</span></td><td>$(echo "${GU_DETAIL}" | html_escape)<pre class='log-snippet'>$(echo "${GU_LOG}" | html_escape)</pre></td></tr>"
                ;;
            timeout)
                print_warn "VM ${VMID} (${VM_NAME}) — update timed out after ${LINUX_UPDATE_TIMEOUT}s${local_suffix}"
                VM_ERRORS=$((VM_ERRORS + 1))
                ERRORS_OCCURRED=true
                record_guest_failure "${VMID}" "${VM_NAME}" "update timed out"
                GUESTS_MID_UPDATE=$((GUESTS_MID_UPDATE + 1))
                # Shutting down here would interrupt dpkg and break the guest.
                VM_WAS_STOPPED=false
                VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-warning'>Timeout</span></td><td>Update did not finish within ${LINUX_UPDATE_TIMEOUT}s. VM left running so dpkg can complete — check it manually.</td></tr>"
                ;;
            unsupported)
                print_warn "VM ${VMID} (${VM_NAME}) — unsupported package manager${local_suffix}"
                VM_SKIPPED=$((VM_SKIPPED + 1))
                VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-warning'>Unsupported</span></td><td>No supported package manager found (apt/dnf/yum/apk).</td></tr>"
                ;;
            nosentinel)
                print_fail "VM ${VMID} (${VM_NAME}) — update did not report a result${local_suffix}"
                VM_ERRORS=$((VM_ERRORS + 1))
                ERRORS_OCCURRED=true
                record_guest_failure "${VMID}" "${VM_NAME}" "update did not report a result"
                [ -z "${GU_DETAIL}" ] && GU_DETAIL="The guest update script produced no __RESULT__ marker."
                VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-error'>Error</span></td><td>$(guest_summary_html "${PKG_COUNT} package(s) upgraded before the failure:")</td></tr>"
                ;;
            fail)
                print_fail "VM ${VMID} (${VM_NAME}) — ${GU_DETAIL:-update failed}${local_suffix}"
                VM_ERRORS=$((VM_ERRORS + 1))
                ERRORS_OCCURRED=true
                record_guest_failure "${VMID}" "${VM_NAME}" "${GU_DETAIL:-update failed}"
                VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-error'>Error</span></td><td>$(guest_summary_html "${PKG_COUNT} package(s) upgraded before the failure:")</td></tr>"
                ;;
            *)
                if [ "${PKG_COUNT}" -gt 0 ] && [ "${DRY_RUN}" = "true" ]; then
                    print_ok "VM ${VMID} (${VM_NAME}) — ${C_BOLD}${PKG_COUNT} packages pending${C_NC} ${C_DIM}[dry run]${C_NC}${local_suffix}"
                    VM_UPDATED=$((VM_UPDATED + 1))
                    VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-warning'>Pending</span></td><td>$(guest_summary_html "${PKG_COUNT} package(s) would be upgraded:")</td></tr>"
                elif [ "${PKG_COUNT}" -gt 0 ]; then
                    print_ok "VM ${VMID} (${VM_NAME}) — ${C_BOLD}${PKG_COUNT} packages updated${C_NC}${local_suffix}"
                    VM_UPDATED=$((VM_UPDATED + 1))
                    VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-success'>Updated</span></td><td>$(guest_summary_html "${PKG_COUNT} package(s) updated:")</td></tr>"
                else
                    print_ok "VM ${VMID} (${VM_NAME}) — already up to date${local_suffix}"
                    VM_CURRENT=$((VM_CURRENT + 1))
                    VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-no-updates'>No Updates</span></td><td>System fully up to date.</td></tr>"
                fi
                ;;
        esac
    fi

    # Restore stopped state if needed
    if [ "${VM_WAS_STOPPED}" = true ]; then
        print_stop "Stopping VM ${VMID} (${VM_NAME}) ${C_DIM}[restoring state]${C_NC}..."
        qm shutdown "${VMID}" >/dev/null 2>&1 || true
        if ! wait_for_status "vm" "${VMID}" "stopped" 180; then
            print_warn "VM ${VMID} — ACPI shutdown timeout, forcing stop..."
            qm stop "${VMID}" >/dev/null 2>&1 || true
        fi
    fi
done

# ==============================================================================
# 3. UPDATE PROXMOX HOST NODE
# ==============================================================================
HOST_UPDATE_FAILED=false

# A targeted run deliberately leaves the host alone — the point of --only is to
# touch one guest without a full sweep.
if [ -n "${ONLY_IDS}" ]; then
    section_header "Proxmox Host (${HOST_NAME})"
    print_skip "Host update skipped ${C_DIM}[--only ${ONLY_IDS}]${C_NC}"
    HOST_STATUS_BADGE="<span class='status-badge badge-dim'>Skipped</span>"
    HOST_SUMMARY_TEXT="Host update skipped — this run targeted only ${ONLY_IDS}."
    PVE_VERSION_AFTER="${PVE_VERSION_BEFORE}"
    PVE_VERSION_CHANGE="${PVE_VERSION_AFTER} (Unchanged)"
else

section_header "Proxmox Host (${HOST_NAME})"

# Same apt hardening the guests get: wait for the lock instead of failing, keep
# existing conffiles, and let needrestart act without prompting.
HOST_APT_OPTS=(
    -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}"
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

start_spinner "Checking for host updates..."
HOST_UPDATE_RC=0
apt-get "${HOST_APT_OPTS[@]}" update -qy >/dev/null 2>&1 || HOST_UPDATE_RC=$?
HOST_UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep '/' || true)
stop_spinner

if [ "${HOST_UPDATE_RC}" -ne 0 ]; then
    print_warn "Host apt-get update exited ${HOST_UPDATE_RC} — package list may be stale"
fi

if [ -n "${HOST_UPGRADABLE}" ]; then
    HOST_UPDATES=$(echo "${HOST_UPGRADABLE}" | format_upgradable_host)

    HOST_PKG_COUNT=$(echo "${HOST_UPDATES}" | wc -l)

    if [ "${DRY_RUN}" = "true" ]; then
        print_warn "${C_BOLD}${HOST_PKG_COUNT} host packages pending${C_NC} ${C_DIM}[dry run — nothing installed]${C_NC}"
        HOST_STATUS_BADGE="<span class='status-badge badge-warning'>Pending</span>"
        HOST_SUMMARY_TEXT="<strong>${HOST_PKG_COUNT} host package(s) would be updated:</strong><ul class='pkg-list'>$(html_list "${HOST_UPDATES}")</ul>"
    else
        start_spinner "Installing ${HOST_PKG_COUNT} host updates..."
        if apt-get "${HOST_APT_OPTS[@]}" dist-upgrade -qy </dev/null 2>&1; then
            apt-get "${HOST_APT_OPTS[@]}" autoremove -qy </dev/null >/dev/null 2>&1 || true
            apt-get "${HOST_APT_OPTS[@]}" autoclean -qy </dev/null >/dev/null 2>&1 || true
            stop_spinner

            # Verify rather than trust: anything still upgradable was held back.
            HOST_HELD=$(apt list --upgradable 2>/dev/null | grep '/' | cut -d/ -f1 || true)
            print_ok "${C_BOLD}${HOST_PKG_COUNT} host packages updated${C_NC}"
            HOST_STATUS_BADGE="<span class='status-badge badge-success'>Updated</span>"
            HOST_SUMMARY_TEXT="<strong>${HOST_PKG_COUNT} host package(s) updated:</strong><ul class='pkg-list'>$(html_list "${HOST_UPDATES}")</ul>"
            if [ -n "${HOST_HELD}" ]; then
                print_warn "Some host packages were held back: $(echo "${HOST_HELD}" | tr '\n' ' ')"
                HOST_SUMMARY_TEXT="${HOST_SUMMARY_TEXT}<strong>Held back (still upgradable):</strong><ul class='pkg-list'>$(html_list "${HOST_HELD}")</ul>"
            fi
        else
            HOST_APT_RC=$?
            stop_spinner
            HOST_UPDATE_FAILED=true
            ERRORS_OCCURRED=true
            HOST_STATUS_BADGE="<span class='status-badge badge-error'>Failed</span>"
            HOST_SUMMARY_TEXT="<strong>apt-get dist-upgrade failed (exit ${HOST_APT_RC})!</strong> Check log: ${LOG_FILE}"
            print_fail "${C_RED}Host apt-get dist-upgrade FAILED (exit ${HOST_APT_RC}) — reboot will NOT be scheduled${C_NC}"
        fi
    fi
else
    print_ok "Host is already fully up to date"
    HOST_STATUS_BADGE="<span class='status-badge badge-no-updates'>No Updates</span>"
    HOST_SUMMARY_TEXT="Host node is fully up to date."
fi

# Capture Proxmox VE Version AFTER updates
PVE_VERSION_AFTER=$(pveversion 2>/dev/null | awk '{print $1}' || dpkg-query -W -f='${Version}' pve-manager 2>/dev/null || echo "Unknown")

if [ "${PVE_VERSION_BEFORE}" != "${PVE_VERSION_AFTER}" ]; then
    PVE_VERSION_CHANGE="${PVE_VERSION_BEFORE} &rarr; <strong>${PVE_VERSION_AFTER}</strong> (Upgraded)"
    print_warn "Proxmox VE upgraded: ${C_BOLD}${PVE_VERSION_BEFORE} → ${PVE_VERSION_AFTER}${C_NC}"
else
    PVE_VERSION_CHANGE="${PVE_VERSION_AFTER} (Unchanged)"
fi

fi   # end of full-sweep-only host section

# --- Determine if a reboot is needed ---
REBOOT_NEEDED=false
REBOOT_REASON=""
RUNNING_KERNEL=$(uname -r)
LATEST_KERNEL=$(ls -t /boot/vmlinuz-* 2>/dev/null | head -1 | sed 's|/boot/vmlinuz-||' || true)

if [ -n "${ONLY_IDS}" ]; then
    # Never reboot the host because of a targeted guest run.
    REBOOT_REASON="Reboot not considered — targeted run (--only ${ONLY_IDS})"
elif [ -n "${LATEST_KERNEL}" ] && [ "${RUNNING_KERNEL}" != "${LATEST_KERNEL}" ]; then
    REBOOT_NEEDED=true
    REBOOT_REASON="Kernel updated: ${RUNNING_KERNEL} &rarr; ${LATEST_KERNEL}"
    print_warn "Kernel change detected: ${C_BOLD}${RUNNING_KERNEL} → ${LATEST_KERNEL}${C_NC}"
fi

if [ -z "${ONLY_IDS}" ] && [ -f /var/run/reboot-required ]; then
    REBOOT_NEEDED=true
    [ -z "${REBOOT_REASON}" ] && REBOOT_REASON="System flagged reboot-required"
fi

if [ "${HOST_UPDATE_FAILED}" = true ]; then
    REBOOT_NEEDED=false
    REBOOT_REASON="Reboot SKIPPED — host update failed"
elif [ "${GUESTS_MID_UPDATE}" -gt 0 ]; then
    # Guests were left running because their upgrade had not finished. Taking
    # the host down now would kill dpkg part way through inside them.
    REBOOT_NEEDED=false
    REBOOT_REASON="Reboot SKIPPED — ${GUESTS_MID_UPDATE} guest(s) may still be updating"
    print_warn "Reboot suppressed: ${GUESTS_MID_UPDATE} guest(s) left running mid-update"
elif [ "${DRY_RUN}" = "true" ] && [ "${REBOOT_NEEDED}" = true ]; then
    REBOOT_NEEDED=false
    REBOOT_REASON="Reboot would have been scheduled — suppressed by dry run"
fi

if [ "${REBOOT_NEEDED}" = true ]; then
    REBOOT_STATUS_HTML="<span class='status-badge badge-warning'>Reboot Scheduled</span> at ${REBOOT_TIME}<br><em>${REBOOT_REASON}</em>"
else
    REBOOT_STATUS_HTML="<span class='status-badge badge-no-updates'>No Reboot Needed</span>"
    [ -n "${REBOOT_REASON}" ] && REBOOT_STATUS_HTML="${REBOOT_STATUS_HTML}<br><em>${REBOOT_REASON}</em>"
fi

# ==============================================================================
# 4. BUILD HTML REPORT & SEND VIA MAILGUN
# ==============================================================================
section_header "Report & Email"

DRY_RUN_BANNER_HTML=""
if [ "${DRY_RUN}" = "true" ]; then
    DRY_RUN_BANNER_HTML="<div class='dry-run-box'>DRY RUN — nothing was installed, snapshotted or rebooted. This report lists what <em>would</em> have been done.</div>"
fi
if [ -n "${ONLY_IDS}" ]; then
    DRY_RUN_BANNER_HTML="${DRY_RUN_BANNER_HTML}<div class='dry-run-box'>TARGETED RUN — only guest(s) <strong>${ONLY_IDS}</strong> were considered. The Proxmox host was not updated and no reboot was scheduled.</div>"
fi

SNAPSHOT_SUMMARY_HTML=""
if [ "${SNAPSHOTS_TAKEN}" -gt 0 ]; then
    SNAPSHOT_SUMMARY_HTML="<br>Snapshots: ${SNAPSHOTS_TAKEN} taken (keeping ${SNAPSHOT_KEEP} per guest)"
fi

MID_UPDATE_SUMMARY_HTML=""
if [ "${GUESTS_MID_UPDATE}" -gt 0 ]; then
    MID_UPDATE_SUMMARY_HTML="<br><strong>${GUESTS_MID_UPDATE} guest(s) left running mid-update — check them before the next run.</strong>"
fi

REPEAT_SUMMARY_HTML=""
if [ -n "${REPEAT_OFFENDERS:-}" ]; then
    REPEAT_SUMMARY_HTML="<br><strong>Failing repeatedly:</strong> $(echo "${REPEAT_OFFENDERS}" | html_escape)"
fi

cat <<EOF > "${HTML_FILE}"
<!DOCTYPE html>
<html>
<head>
<style>
  body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f4f6f9; color: #333; margin: 0; padding: 20px; }
  .container { max-width: 850px; background: #ffffff; padding: 25px; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); margin: 0 auto; }
  .header { border-bottom: 2px solid #e65c00; padding-bottom: 15px; margin-bottom: 20px; }
  h1 { color: #e65c00; margin: 0 0 10px 0; font-size: 22px; }
  .pve-box { background: #fff3cd; border-left: 4px solid #e65c00; padding: 12px 15px; margin-bottom: 20px; border-radius: 0 4px 4px 0; font-size: 15px; font-weight: bold; color: #856404; }
  .meta-info { background: #eef6fc; border-left: 4px solid #0066cc; padding: 12px 15px; margin-bottom: 20px; border-radius: 0 4px 4px 0; font-size: 14px; line-height: 1.6; }
  .section-title { color: #2c3e50; font-size: 16px; margin-top: 20px; margin-bottom: 10px; border-bottom: 1px solid #eee; padding-bottom: 5px; font-weight: bold; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 15px; font-size: 13px; }
  th { background-color: #f8f9fa; color: #495057; text-align: left; padding: 10px; border: 1px solid #dee2e6; }
  td { padding: 9px 10px; border: 1px solid #dee2e6; vertical-align: top; }
  tr:nth-child(even) { background-color: #fbfbfb; }
  .status-badge { display: inline-block; padding: 3px 8px; border-radius: 4px; font-weight: bold; font-size: 11px; }
  .badge-success { background: #d4edda; color: #155724; }
  .badge-no-updates { background: #e2e3e5; color: #383d41; }
  .badge-warning { background: #fff3cd; color: #856404; }
  .badge-error { background: #f8d7da; color: #721c24; }
  .badge-dim { background: #e9ecef; color: #6c757d; }
  .pkg-list { font-size: 12px; margin: 5px 0 0 15px; padding: 0; list-style-type: disc; }
  .pkg-list li { font-family: 'Courier New', Courier, monospace; font-size: 11px; padding: 1px 0; }
  .detail { margin-top: 8px; font-size: 12px; color: #721c24; }
  .log-snippet { margin: 8px 0 0 0; padding: 8px; background: #f8f9fa; border: 1px solid #dee2e6; border-radius: 4px; font-family: 'Courier New', Courier, monospace; font-size: 11px; white-space: pre-wrap; word-break: break-word; max-height: 220px; overflow: auto; color: #495057; }
  .dry-run-box { background: #e2e3e5; border-left: 4px solid #6c757d; padding: 12px 15px; margin-bottom: 20px; border-radius: 0 4px 4px 0; font-size: 14px; font-weight: bold; color: #383d41; }
  .summary-box { background: #f8f9fa; border: 1px solid #dee2e6; padding: 15px; border-radius: 6px; margin: 15px 0; font-size: 13px; line-height: 1.8; }
  .footer { margin-top: 25px; font-size: 12px; color: #6c757d; text-align: center; border-top: 1px solid #eee; padding-top: 15px; }
</style>
</head>
<body>
  <div class='container'>
    <div class='header'>
      <h1>Proxmox VE Maintenance Report</h1>
    </div>

    ${DRY_RUN_BANNER_HTML}

    <div class='pve-box'>
      Proxmox VE Version: ${PVE_VERSION_CHANGE}
    </div>

    <div class='meta-info'>
      <strong>Proxmox Node Name:</strong> ${HOST_NAME}<br>
      <strong>Execution Timestamp:</strong> ${TIMESTAMP}<br>
      <strong>Reboot Status:</strong> ${REBOOT_STATUS_HTML}
    </div>

    <div class='summary-box'>
      <strong>Summary:</strong><br>
      LXC: ${LXC_UPDATED} updated, ${LXC_CURRENT} current, ${LXC_STARTED} started from stopped, ${LXC_ERRORS} errors, ${LXC_SKIPPED} skipped, ${LXC_EXCLUDED} excluded<br>
      VMs: ${VM_UPDATED} updated, ${VM_CURRENT} current, ${VM_STARTED} started from stopped, ${VM_ERRORS} errors, ${VM_SKIPPED} skipped, ${VM_EXCLUDED} excluded<br>
      Host: ${HOST_PKG_COUNT} packages${SNAPSHOT_SUMMARY_HTML}${MID_UPDATE_SUMMARY_HTML}${REPEAT_SUMMARY_HTML}
    </div>

    <div class='section-title'>1. Proxmox Host Node (${HOST_NAME})</div>
    <table>
      <tr><th style='width: 25%;'>Node</th><th style='width: 15%;'>Status</th><th>Summary</th></tr>
      <tr><td><strong>${HOST_NAME}</strong></td><td>${HOST_STATUS_BADGE}</td><td>${HOST_SUMMARY_TEXT}</td></tr>
    </table>

    <div class='section-title'>2. LXC Containers</div>
    <table>
      <tr><th style='width: 25%;'>CT ID / Name</th><th style='width: 15%;'>Status</th><th>Summary</th></tr>
      ${LXC_HTML}
    </table>

    <div class='section-title'>3. Virtual Machines</div>
    <table>
      <tr><th style='width: 25%;'>VM ID / Name</th><th style='width: 15%;'>Status</th><th>Summary</th></tr>
      ${VM_HTML}
    </table>

    <div class='footer'>
      Automated report delivered via Mailgun ${MAILGUN_REGION} API by <strong>${HOST_NAME}</strong>.
    </div>
  </div>
</body>
</html>
EOF

# Fold this run into the persistent state before notifying, so the summary can
# mention guests that have been failing for several runs.
state_write
compute_repeat_offenders
if [ -n "${REPEAT_OFFENDERS}" ]; then
    print_warn "Repeatedly failing: ${C_BOLD}${REPEAT_OFFENDERS}${C_NC}"
fi

SUBJECT_PREFIX="[Proxmox]"
[ "${DRY_RUN}" = "true" ] && SUBJECT_PREFIX="${SUBJECT_PREFIX}[DRY RUN]"
[ -n "${ONLY_IDS}" ] && SUBJECT_PREFIX="${SUBJECT_PREFIX}[${ONLY_IDS}]"

if [ "${ERRORS_OCCURRED}" = true ]; then
    EMAIL_SUBJECT="${SUBJECT_PREFIX} ⚠ Update Report (ERRORS) - ${HOST_NAME} (${TIMESTAMP})"
else
    EMAIL_SUBJECT="${SUBJECT_PREFIX} ✓ Update Report - ${HOST_NAME} (${TIMESTAMP})"
fi

if [ "${SEND_EMAIL}" != "true" ]; then
    print_skip "Notifications suppressed ${C_DIM}[--no-email]${C_NC}"
elif [ -z "${NOTIFY_ACTIVE}" ]; then
    if [ -n "${NOTIFY_DISABLED}" ]; then
        print_warn "No usable notification channel: ${NOTIFY_DISABLED}"
        echo -e "     ${C_DIM}Updates ran normally. Configure a channel in the web panel or ${CONFIG_FILE}.${C_NC}"
    else
        print_skip "No notification channel configured ${C_DIM}(updates still ran)${C_NC}"
    fi
elif [ "${NOTIFY_ON_FAILURE_ONLY}" = "true" ] && [ "${ERRORS_OCCURRED}" != true ]; then
    print_skip "Clean run — notification suppressed ${C_DIM}[NOTIFY_ON_FAILURE_ONLY]${C_NC}"
else
    [ -n "${NOTIFY_DISABLED}" ] && print_warn "Skipping unconfigured channel(s): ${NOTIFY_DISABLED}"
    notify_all "${EMAIL_SUBJECT}" "$(build_text_summary)" "${HTML_FILE}"
fi

# ==============================================================================
# 5. CONDITIONAL REBOOT
# ==============================================================================
if [ "${REBOOT_NEEDED}" = true ]; then
    echo ""
    print_warn "Scheduling reboot at ${REBOOT_TIME} (${REBOOT_REASON})"
    CURRENT_EPOCH=$(date +%s)
    TARGET_EPOCH=$(date -d "today ${REBOOT_TIME}" +%s 2>/dev/null || echo "0")
    if [ "${TARGET_EPOCH}" -le "${CURRENT_EPOCH}" ]; then
        TARGET_EPOCH=$(date -d "tomorrow ${REBOOT_TIME}" +%s 2>/dev/null || date -d "${REBOOT_TIME} + 1 day" +%s 2>/dev/null || echo "0")
    fi

    if [ "${TARGET_EPOCH}" -gt "${CURRENT_EPOCH}" ] 2>/dev/null; then
        MINS_UNTIL_REBOOT=$(( (TARGET_EPOCH - CURRENT_EPOCH) / 60 ))
        shutdown -r +"${MINS_UNTIL_REBOOT}" "Scheduled reboot (${REBOOT_TIME}): ${REBOOT_REASON}" 2>/dev/null || \
            shutdown -r "${REBOOT_TIME}" "Scheduled reboot: ${REBOOT_REASON}" 2>/dev/null || true
    else
        shutdown -r "${REBOOT_TIME}" "Scheduled reboot: ${REBOOT_REASON}" 2>/dev/null || true
    fi
fi

# ==============================================================================
# 6. SUMMARY TABLE
# ==============================================================================
section_header "Summary"

TOTAL_UPDATED=$((LXC_UPDATED + VM_UPDATED))
TOTAL_ERRORS=$((LXC_ERRORS + VM_ERRORS))

echo -e "  ${C_CYAN}LXC:${C_NC}  ${C_GREEN}${LXC_UPDATED} updated${C_NC}, ${LXC_CURRENT} current, ${LXC_STARTED} started+stopped, ${LXC_ERRORS} errors, ${LXC_EXCLUDED} excluded"
echo -e "  ${C_CYAN}VMs:${C_NC}  ${C_GREEN}${VM_UPDATED} updated${C_NC} (${VM_WIN_UPDATED} Windows), ${VM_CURRENT} current, ${VM_STARTED} started+stopped, ${VM_ERRORS} errors, ${VM_WIN_TIMEOUT} timeouts"
echo -e "  ${C_CYAN}Host:${C_NC} ${C_GREEN}${HOST_PKG_COUNT} packages${C_NC}"

if [ "${SNAPSHOTS_TAKEN}" -gt 0 ]; then
    echo -e "  ${C_CYAN}Snaps:${C_NC} ${SNAPSHOTS_TAKEN} taken (keeping ${SNAPSHOT_KEEP} per guest)"
fi

if [ "${GUESTS_MID_UPDATE}" -gt 0 ]; then
    echo -e "  ${C_YELLOW}⚠ ${GUESTS_MID_UPDATE} guest(s) left running mid-update — check them manually${C_NC}"
fi

if [ "${REBOOT_NEEDED}" = true ]; then
    echo -e "  ${C_YELLOW}⚠ Reboot scheduled at ${REBOOT_TIME}${C_NC}"
elif [ -n "${REBOOT_REASON}" ]; then
    echo -e "  ${C_DIM}${REBOOT_REASON}${C_NC}"
fi

echo ""
echo -e "${C_BOLD}${C_CYAN}══════════════════════════════════════════════════════════════${C_NC}"
DRY_SUFFIX=""
[ "${DRY_RUN}" = "true" ] && DRY_SUFFIX=" ${C_DIM}[dry run — nothing was changed]${C_NC}"
if [ "${ERRORS_OCCURRED}" = true ]; then
    echo -e "  ${C_RED}${C_BOLD}Update sequence complete — with errors${C_NC}${DRY_SUFFIX}"
else
    echo -e "  ${C_GREEN}${C_BOLD}Update sequence complete — all clear ✓${C_NC}${DRY_SUFFIX}"
fi
echo -e "${C_BOLD}${C_CYAN}══════════════════════════════════════════════════════════════${C_NC}"
echo ""