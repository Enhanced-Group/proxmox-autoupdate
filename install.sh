#!/usr/bin/env bash
# ==============================================================================
# Dynamic Interactive Installer for Proxmox Auto-Update Service
# ==============================================================================

set -euo pipefail

TARGET_PATH="/usr/local/bin/update-everything.sh"
CONFIG_FILE="/etc/proxmox-autoupdate.conf"
LOG_DIR="/var/log/proxmox-autoupdate"
# Branch to fetch from when running via `curl | bash`. Override to test a branch
# before merging:  curl -sSL .../<branch>/install.sh | PAU_BRANCH=<branch> bash
PAU_BRANCH="${PAU_BRANCH:-main}"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/Enhanced-Group/proxmox-autoupdate/${PAU_BRANCH}"
GITHUB_RAW_URL="${GITHUB_RAW_BASE}/update-everything.sh"

# Web control panel
UI_BIN="/usr/local/bin/pve-autoupdate-ui"
UI_PATCHER="/usr/local/bin/pve-autoupdate-patch-webui"
UI_SERVICE="/etc/systemd/system/pve-autoupdate-ui.service"
UI_APT_HOOK="/etc/apt/apt.conf.d/99-proxmox-autoupdate-webui"
PVE_JS="/usr/share/pve-manager/js/pvemanagerlib.js"

# --- ANSI Colors ---
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_NC='\033[0m'

print_ok()     { echo -e "  ${C_GREEN}✓${C_NC} $1"; }
print_fail()   { echo -e "  ${C_RED}✗${C_NC} $1"; }
print_action() { echo -e "  ${C_CYAN}▶${C_NC} $1"; }

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

echo ""
print_box_top
print_box_line "${C_BOLD}Proxmox Auto-Update — Installer${C_NC}" "Proxmox Auto-Update - Installer"
print_box_bottom

# 0. Root check
if [ "$(id -u)" -ne 0 ]; then
    echo ""
    print_fail "This installer must be run as ${C_BOLD}root${C_NC}."
    exit 1
fi

# 1. Load any previously saved configuration
PREV_KEY=""
PREV_DOMAIN=""
PREV_REGION=""
PREV_SENDER=""
PREV_RECIPIENT=""
PREV_EXCLUDE=""
PREV_WIN_TIMEOUT=""
PREV_START_WIN=""
PREV_CRON=""
PREV_REBOOT_TIME=""
PREV_START_LXC=""
PREV_START_LINUX_VMS=""
PREV_LINUX_TIMEOUT=""
PREV_APT_LOCK=""
PREV_SNAPSHOT=""
PREV_SNAPSHOT_KEEP=""
PREV_WEBUI=""
PREV_WEBUI_PORT=""

if [ -f "${CONFIG_FILE}" ]; then
    echo ""
    print_ok "Found existing configuration at ${C_DIM}${CONFIG_FILE}${C_NC}"
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
    PREV_KEY="${MAILGUN_API_KEY:-}"
    PREV_DOMAIN="${MAILGUN_DOMAIN:-}"
    PREV_REGION="${MAILGUN_REGION:-}"
    PREV_SENDER="${SENDER_EMAIL:-}"
    PREV_RECIPIENT="${RECIPIENT_EMAIL:-}"
    PREV_EXCLUDE="${EXCLUDE_IDS:-}"
    PREV_WIN_TIMEOUT="${WINDOWS_UPDATE_TIMEOUT:-}"
    PREV_START_WIN="${START_STOPPED_WINDOWS:-}"
    PREV_START_LXC="${START_STOPPED_LXC:-}"
    PREV_START_LINUX_VMS="${START_STOPPED_LINUX_VMS:-}"
    PREV_CRON="${UPDATE_SCHEDULE_CRON:-}"
    PREV_REBOOT_TIME="${REBOOT_TIME:-}"
    PREV_LINUX_TIMEOUT="${LINUX_UPDATE_TIMEOUT:-}"
    PREV_APT_LOCK="${APT_LOCK_TIMEOUT:-}"
    PREV_SNAPSHOT="${SNAPSHOT_BEFORE_UPDATE:-}"
    PREV_SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-}"
    PREV_WEBUI="${ENABLE_WEB_UI:-}"
    PREV_WEBUI_PORT="${WEB_UI_PORT:-}"
fi

# 1b. Dependencies
# jq is required: the update script parses every guest-agent reply as JSON, and
# regex-scraping that output fails silently in ways that look like timeouts.
echo ""
print_action "Checking dependencies..."
if command -v jq >/dev/null 2>&1; then
    print_ok "jq present"
else
    print_action "Installing jq..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -qy jq >/dev/null 2>&1; then
        print_ok "jq installed"
    else
        print_fail "Could not install jq — run 'apt-get update && apt-get install -y jq' and re-run this installer."
        exit 1
    fi
fi

echo ""
echo -e "${C_BOLD}── Mailgun Configuration ───────────────────────────────────${C_NC}"
echo ""

# 2. Prompt for each value, using < /dev/tty to work inside curl | bash

# --- API Key ---
MAILGUN_API_KEY=""
while [ -z "${MAILGUN_API_KEY}" ]; do
    if [ -n "${PREV_KEY}" ]; then
        MASKED_KEY="${PREV_KEY:0:4}...${PREV_KEY: -4}"
        read -rp "  Mailgun API Key [Enter to keep ${MASKED_KEY}]: " INPUT_KEY < /dev/tty
    else
        read -rp "  Mailgun API Key: " INPUT_KEY < /dev/tty
    fi
    MAILGUN_API_KEY="${INPUT_KEY:-${PREV_KEY}}"
    [ -z "${MAILGUN_API_KEY}" ] && print_fail "Mailgun API Key is required."
done
print_ok "API Key set"

# --- Domain ---
MAILGUN_DOMAIN=""
while [ -z "${MAILGUN_DOMAIN}" ]; do
    if [ -n "${PREV_DOMAIN}" ]; then
        read -rp "  Mailgun Domain [Enter for ${PREV_DOMAIN}]: " INPUT_DOMAIN < /dev/tty
    else
        read -rp "  Mailgun Domain (e.g., mg.example.com): " INPUT_DOMAIN < /dev/tty
    fi
    MAILGUN_DOMAIN="${INPUT_DOMAIN:-${PREV_DOMAIN}}"
    [ -z "${MAILGUN_DOMAIN}" ] && print_fail "Mailgun Domain is required."
done
print_ok "Domain: ${MAILGUN_DOMAIN}"

# --- Region (1 = EU, 2 = US) ---
MAILGUN_REGION=""
while [ -z "${MAILGUN_REGION}" ]; do
    echo ""
    if [ -n "${PREV_REGION}" ]; then
        echo -e "  ${C_BOLD}Mailgun API Region${C_NC} ${C_DIM}[current: ${PREV_REGION}]${C_NC}"
    else
        echo -e "  ${C_BOLD}Mailgun API Region:${C_NC}"
    fi
    echo -e "    ${C_CYAN}1)${C_NC} EU  ${C_DIM}(api.eu.mailgun.net)${C_NC}"
    echo -e "    ${C_CYAN}2)${C_NC} US  ${C_DIM}(api.mailgun.net)${C_NC}"
    if [ -n "${PREV_REGION}" ]; then
        read -rp "  Select 1 or 2 [Enter to keep ${PREV_REGION}]: " INPUT_REGION < /dev/tty
    else
        read -rp "  Select 1 or 2: " INPUT_REGION < /dev/tty
    fi
    case "${INPUT_REGION}" in
        1) MAILGUN_REGION="EU" ;;
        2) MAILGUN_REGION="US" ;;
        "")
            if [ -n "${PREV_REGION}" ]; then
                MAILGUN_REGION="${PREV_REGION}"
            else
                print_fail "Please select 1 (EU) or 2 (US)."
            fi
            ;;
        *) print_fail "Please select 1 (EU) or 2 (US)." ;;
    esac
done
print_ok "Region: ${MAILGUN_REGION}"

# --- Sender Email ---
echo ""
SENDER_EMAIL=""
while [ -z "${SENDER_EMAIL}" ]; do
    if [ -n "${PREV_SENDER}" ]; then
        read -rp "  Sender Email [Enter for ${PREV_SENDER}]: " INPUT_SENDER < /dev/tty
    else
        read -rp "  Sender Email (e.g., noreply@example.com): " INPUT_SENDER < /dev/tty
    fi
    SENDER_EMAIL="${INPUT_SENDER:-${PREV_SENDER}}"
    [ -z "${SENDER_EMAIL}" ] && print_fail "Sender Email is required."
done
print_ok "Sender: ${SENDER_EMAIL}"

# --- Recipient Email ---
RECIPIENT_EMAIL=""
while [ -z "${RECIPIENT_EMAIL}" ]; do
    if [ -n "${PREV_RECIPIENT}" ]; then
        read -rp "  Recipient Email [Enter for ${PREV_RECIPIENT}]: " INPUT_RECIPIENT < /dev/tty
    else
        read -rp "  Recipient Email (e.g., admin@example.com): " INPUT_RECIPIENT < /dev/tty
    fi
    RECIPIENT_EMAIL="${INPUT_RECIPIENT:-${PREV_RECIPIENT}}"
    [ -z "${RECIPIENT_EMAIL}" ] && print_fail "Recipient Email is required."
done
print_ok "Recipient: ${RECIPIENT_EMAIL}"

# --- Advanced Settings ---
echo ""
echo -e "${C_BOLD}── Advanced Settings ───────────────────────────────────────${C_NC}"
echo ""

# --- Exclude IDs ---
EXCLUDE_IDS=""
if [ -n "${PREV_EXCLUDE}" ]; then
    read -rp "  Exclude VM/CT IDs from updates [Enter for ${PREV_EXCLUDE}]: " INPUT_EXCLUDE < /dev/tty
else
    read -rp "  Exclude VM/CT IDs (comma-separated, or blank for none): " INPUT_EXCLUDE < /dev/tty
fi
EXCLUDE_IDS="${INPUT_EXCLUDE:-${PREV_EXCLUDE}}"
if [ -n "${EXCLUDE_IDS}" ]; then
    print_ok "Excluding: ${EXCLUDE_IDS}"
else
    print_ok "No exclusions"
fi

# --- Windows Update Timeout ---
WINDOWS_UPDATE_TIMEOUT=""
DEFAULT_WIN_TIMEOUT="${PREV_WIN_TIMEOUT:-1200}"
read -rp "  Windows Update timeout in seconds [Enter for ${DEFAULT_WIN_TIMEOUT}]: " INPUT_WIN_TIMEOUT < /dev/tty
WINDOWS_UPDATE_TIMEOUT="${INPUT_WIN_TIMEOUT:-${DEFAULT_WIN_TIMEOUT}}"
print_ok "Windows timeout: ${WINDOWS_UPDATE_TIMEOUT}s"

# --- Start Stopped Windows VMs ---
echo ""
echo -e "  ${C_BOLD}Start stopped Windows VMs for updates?${C_NC}"
echo -e "  ${C_DIM}(Windows Update can take 30+ minutes — not recommended for short maintenance windows)${C_NC}"
DEFAULT_START_WIN="${PREV_START_WIN:-false}"
if [ "${DEFAULT_START_WIN}" = "true" ]; then
    echo -e "    ${C_CYAN}1)${C_NC} Yes  ${C_DIM}(current)${C_NC}"
    echo -e "    ${C_CYAN}2)${C_NC} No"
else
    echo -e "    ${C_CYAN}1)${C_NC} Yes"
    echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}(current)${C_NC}"
fi
read -rp "  Select 1 or 2 [Enter to keep current]: " INPUT_START_WIN < /dev/tty
case "${INPUT_START_WIN}" in
    1) START_STOPPED_WINDOWS="true" ;;
    2) START_STOPPED_WINDOWS="false" ;;
    "") START_STOPPED_WINDOWS="${DEFAULT_START_WIN}" ;;
    *) START_STOPPED_WINDOWS="${DEFAULT_START_WIN}" ;;
esac
print_ok "Start stopped Windows VMs: ${START_STOPPED_WINDOWS}"

# --- Start Stopped LXC Containers ---
echo ""
echo -e "  ${C_BOLD}Start stopped LXC Containers for updates?${C_NC}"
DEFAULT_START_LXC="${PREV_START_LXC:-true}"
if [ "${DEFAULT_START_LXC}" = "true" ]; then
    echo -e "    ${C_CYAN}1)${C_NC} Yes  ${C_DIM}(current)${C_NC}"
    echo -e "    ${C_CYAN}2)${C_NC} No"
else
    echo -e "    ${C_CYAN}1)${C_NC} Yes"
    echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}(current)${C_NC}"
fi
read -rp "  Select 1 or 2 [Enter to keep current]: " INPUT_START_LXC < /dev/tty
case "${INPUT_START_LXC}" in
    1) START_STOPPED_LXC="true" ;;
    2) START_STOPPED_LXC="false" ;;
    "") START_STOPPED_LXC="${DEFAULT_START_LXC}" ;;
    *) START_STOPPED_LXC="${DEFAULT_START_LXC}" ;;
esac
print_ok "Start stopped LXC: ${START_STOPPED_LXC}"

# --- Start Stopped Linux VMs ---
echo ""
echo -e "  ${C_BOLD}Start stopped Linux VMs for updates?${C_NC}"
DEFAULT_START_LINUX_VMS="${PREV_START_LINUX_VMS:-true}"
if [ "${DEFAULT_START_LINUX_VMS}" = "true" ]; then
    echo -e "    ${C_CYAN}1)${C_NC} Yes  ${C_DIM}(current)${C_NC}"
    echo -e "    ${C_CYAN}2)${C_NC} No"
else
    echo -e "    ${C_CYAN}1)${C_NC} Yes"
    echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}(current)${C_NC}"
fi
read -rp "  Select 1 or 2 [Enter to keep current]: " INPUT_START_LINUX_VMS < /dev/tty
case "${INPUT_START_LINUX_VMS}" in
    1) START_STOPPED_LINUX_VMS="true" ;;
    2) START_STOPPED_LINUX_VMS="false" ;;
    "") START_STOPPED_LINUX_VMS="${DEFAULT_START_LINUX_VMS}" ;;
    *) START_STOPPED_LINUX_VMS="${DEFAULT_START_LINUX_VMS}" ;;
esac
print_ok "Start stopped Linux VMs: ${START_STOPPED_LINUX_VMS}"

# --- Linux Update Timeout ---
echo ""
DEFAULT_LINUX_TIMEOUT="${PREV_LINUX_TIMEOUT:-1800}"
echo -e "  ${C_DIM}How long a Linux guest gets to finish its upgrade before being"
echo -e "  reported as timed out. A large dist-upgrade on a slow mirror can"
echo -e "  easily exceed 10 minutes.${C_NC}"
read -rp "  Linux update timeout in seconds [Enter for ${DEFAULT_LINUX_TIMEOUT}]: " INPUT_LINUX_TIMEOUT < /dev/tty
LINUX_UPDATE_TIMEOUT="${INPUT_LINUX_TIMEOUT:-${DEFAULT_LINUX_TIMEOUT}}"
print_ok "Linux timeout: ${LINUX_UPDATE_TIMEOUT}s"

# --- APT Lock Timeout ---
echo ""
DEFAULT_APT_LOCK="${PREV_APT_LOCK:-600}"
echo -e "  ${C_DIM}How long apt waits for the dpkg lock inside a guest. Distros with"
echo -e "  unattended-upgrades enabled (Ubuntu by default) fail with exit code"
echo -e "  100 if this is 0 and the two happen to overlap.${C_NC}"
read -rp "  APT lock wait in seconds [Enter for ${DEFAULT_APT_LOCK}]: " INPUT_APT_LOCK < /dev/tty
APT_LOCK_TIMEOUT="${INPUT_APT_LOCK:-${DEFAULT_APT_LOCK}}"
print_ok "APT lock wait: ${APT_LOCK_TIMEOUT}s"

# --- Pre-update Snapshots ---
echo ""
echo -e "  ${C_BOLD}Take a snapshot of each guest before updating it?${C_NC}"
echo -e "  ${C_DIM}(Needs a snapshot-capable storage backend: ZFS, LVM-thin, qcow2.${C_NC}"
echo -e "  ${C_DIM} Uses disk space, but gives you a one-command rollback.)${C_NC}"
DEFAULT_SNAPSHOT="${PREV_SNAPSHOT:-false}"
if [ "${DEFAULT_SNAPSHOT}" = "true" ]; then
    echo -e "    ${C_CYAN}1)${C_NC} Yes  ${C_DIM}(current)${C_NC}"
    echo -e "    ${C_CYAN}2)${C_NC} No"
else
    echo -e "    ${C_CYAN}1)${C_NC} Yes"
    echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}(current)${C_NC}"
fi
read -rp "  Select 1 or 2 [Enter to keep current]: " INPUT_SNAPSHOT < /dev/tty
case "${INPUT_SNAPSHOT}" in
    1) SNAPSHOT_BEFORE_UPDATE="true" ;;
    2) SNAPSHOT_BEFORE_UPDATE="false" ;;
    *) SNAPSHOT_BEFORE_UPDATE="${DEFAULT_SNAPSHOT}" ;;
esac
print_ok "Pre-update snapshots: ${SNAPSHOT_BEFORE_UPDATE}"

DEFAULT_SNAPSHOT_KEEP="${PREV_SNAPSHOT_KEEP:-3}"
if [ "${SNAPSHOT_BEFORE_UPDATE}" = "true" ]; then
    read -rp "  Snapshots to keep per guest [Enter for ${DEFAULT_SNAPSHOT_KEEP}]: " INPUT_SNAPSHOT_KEEP < /dev/tty
    SNAPSHOT_KEEP="${INPUT_SNAPSHOT_KEEP:-${DEFAULT_SNAPSHOT_KEEP}}"
    print_ok "Keeping ${SNAPSHOT_KEEP} snapshot(s) per guest"
else
    SNAPSHOT_KEEP="${DEFAULT_SNAPSHOT_KEEP}"
fi

# --- Web Control Panel ---
echo ""
echo -e "  ${C_BOLD}Add an 'Auto-Update' button to the Proxmox web UI?${C_NC}"
echo -e "  ${C_DIM}Places a button in the toolbar, left of Documentation. It opens a${C_NC}"
echo -e "  ${C_DIM}panel to run updates, edit the schedule and config, and read logs.${C_NC}"
echo -e "  ${C_DIM}Only root@pam can use it; access is authorised by your existing${C_NC}"
echo -e "  ${C_DIM}Proxmox login session.${C_NC}"
DEFAULT_WEBUI="${PREV_WEBUI:-false}"
if [ "${DEFAULT_WEBUI}" = "true" ]; then
    echo -e "    ${C_CYAN}1)${C_NC} Yes  ${C_DIM}(current)${C_NC}"
    echo -e "    ${C_CYAN}2)${C_NC} No"
else
    echo -e "    ${C_CYAN}1)${C_NC} Yes"
    echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}(current)${C_NC}"
fi
read -rp "  Select 1 or 2 [Enter to keep current]: " INPUT_WEBUI < /dev/tty
case "${INPUT_WEBUI}" in
    1) ENABLE_WEB_UI="true" ;;
    2) ENABLE_WEB_UI="false" ;;
    *) ENABLE_WEB_UI="${DEFAULT_WEBUI}" ;;
esac

WEB_UI_PORT="${PREV_WEBUI_PORT:-8007}"
if [ "${ENABLE_WEB_UI}" = "true" ]; then
    read -rp "  Port for the control panel [Enter for ${WEB_UI_PORT}]: " INPUT_WEBUI_PORT < /dev/tty
    WEB_UI_PORT="${INPUT_WEBUI_PORT:-${WEB_UI_PORT}}"
    print_ok "Web control panel: enabled on port ${WEB_UI_PORT}"
else
    print_ok "Web control panel: disabled"
fi

# --- Validate numeric inputs before writing them out ---
for NUM_PAIR in "WINDOWS_UPDATE_TIMEOUT:${WINDOWS_UPDATE_TIMEOUT}" \
                "LINUX_UPDATE_TIMEOUT:${LINUX_UPDATE_TIMEOUT}" \
                "APT_LOCK_TIMEOUT:${APT_LOCK_TIMEOUT}" \
                "SNAPSHOT_KEEP:${SNAPSHOT_KEEP}" \
                "WEB_UI_PORT:${WEB_UI_PORT}"; do
    NUM_NAME="${NUM_PAIR%%:*}"
    NUM_VALUE="${NUM_PAIR#*:}"
    if ! [[ "${NUM_VALUE}" =~ ^[0-9]+$ ]]; then
        echo ""
        print_fail "${NUM_NAME} must be a positive integer (got '${NUM_VALUE}')"
        exit 1
    fi
done

# --- Schedule & Reboot Settings ---
echo ""
echo -e "${C_BOLD}── Schedule & Reboot Timing ────────────────────────────────${C_NC}"
echo ""

# --- Cron Schedule ---
DEFAULT_CRON="${PREV_CRON:-0 23 * * 5}"
echo -e "  ${C_BOLD}Select Update Cron Schedule:${C_NC} ${C_DIM}[current: ${DEFAULT_CRON}]${C_NC}"
echo -e "    ${C_CYAN}1)${C_NC} Friday at 23:00  ${C_DIM}(0 23 * * 5)${C_NC}"
echo -e "    ${C_CYAN}2)${C_NC} Friday at 22:00  ${C_DIM}(0 22 * * 5)${C_NC}"
echo -e "    ${C_CYAN}3)${C_NC} Friday at 20:00  ${C_DIM}(0 20 * * 5)${C_NC}"
echo -e "    ${C_CYAN}4)${C_NC} Friday at 10:00  ${C_DIM}(0 10 * * 5)${C_NC}"
echo -e "    ${C_CYAN}5)${C_NC} Custom cron expression / time"

read -rp "  Select 1-5 [Enter for ${DEFAULT_CRON}]: " INPUT_SCHED_CHOICE < /dev/tty
case "${INPUT_SCHED_CHOICE:-0}" in
    1) UPDATE_SCHEDULE_CRON="0 23 * * 5" ;;
    2) UPDATE_SCHEDULE_CRON="0 22 * * 5" ;;
    3) UPDATE_SCHEDULE_CRON="0 20 * * 5" ;;
    4) UPDATE_SCHEDULE_CRON="0 10 * * 5" ;;
    5)
        read -rp "  Enter 5-field cron expression (e.g. 0 10 * * 5): " CUSTOM_CRON < /dev/tty
        UPDATE_SCHEDULE_CRON="${CUSTOM_CRON:-${DEFAULT_CRON}}"
        ;;
    "") UPDATE_SCHEDULE_CRON="${DEFAULT_CRON}" ;;
    *) UPDATE_SCHEDULE_CRON="${DEFAULT_CRON}" ;;
esac
print_ok "Update schedule: ${UPDATE_SCHEDULE_CRON}"

# --- Reboot Time ---
DEFAULT_REBOOT_TIME="${PREV_REBOOT_TIME:-00:00}"
read -rp "  Reboot time if kernel is updated (HH:MM format, e.g. 00:00, 01:00, 02:00) [Enter for ${DEFAULT_REBOOT_TIME}]: " INPUT_REBOOT_TIME < /dev/tty
REBOOT_TIME="${INPUT_REBOOT_TIME:-${DEFAULT_REBOOT_TIME}}"
print_ok "Scheduled reboot time: ${REBOOT_TIME}"

# 3. Write credentials to a secure config file
echo ""
echo -e "${C_BOLD}── Deploying ───────────────────────────────────────────────${C_NC}"
echo ""
print_action "Saving configuration to ${C_DIM}${CONFIG_FILE}${C_NC}..."
cat > "${CONFIG_FILE}" <<CONF
# Proxmox Auto-Update — Configuration
# Generated by installer on $(date '+%d/%m/%Y %H:%M:%S')

# Mailgun API credentials
MAILGUN_API_KEY="${MAILGUN_API_KEY}"
MAILGUN_DOMAIN="${MAILGUN_DOMAIN}"
MAILGUN_REGION="${MAILGUN_REGION}"

# Email addresses
SENDER_EMAIL="${SENDER_EMAIL}"
RECIPIENT_EMAIL="${RECIPIENT_EMAIL}"

# Comma-separated VM/CT IDs to exclude from updates (e.g., "100,201,305")
EXCLUDE_IDS="${EXCLUDE_IDS}"

# Windows Update timeout in seconds (default: 1200 = 20 minutes)
WINDOWS_UPDATE_TIMEOUT="${WINDOWS_UPDATE_TIMEOUT}"

# How long a Linux guest gets to finish its upgrade (default: 1800 = 30 minutes)
LINUX_UPDATE_TIMEOUT="${LINUX_UPDATE_TIMEOUT}"

# How long apt waits for the dpkg lock inside a guest, in seconds.
# Prevents spurious "exit code 100" failures when unattended-upgrades is
# running at the same time (default: 600 = 10 minutes)
APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT}"

# Take a snapshot of each guest before updating it? ("true" or "false")
# Requires snapshot-capable storage (ZFS, LVM-thin, qcow2).
SNAPSHOT_BEFORE_UPDATE="${SNAPSHOT_BEFORE_UPDATE}"

# How many auto-generated snapshots to keep per guest before pruning the oldest
SNAPSHOT_KEEP="${SNAPSHOT_KEEP}"

# Report what would be updated without changing anything ("true" or "false").
# Leave this false for the scheduled run — use 'update-everything.sh --dry-run'
# when you want a one-off preview.
DRY_RUN="false"

# Web control panel (toolbar button in the Proxmox UI)
ENABLE_WEB_UI="${ENABLE_WEB_UI}"
WEB_UI_PORT="${WEB_UI_PORT}"

# Start stopped Windows VMs to update them? ("true" or "false")
START_STOPPED_WINDOWS="${START_STOPPED_WINDOWS}"

# Start stopped LXC Containers to update them? ("true" or "false")
START_STOPPED_LXC="${START_STOPPED_LXC}"

# Start stopped Linux VMs to update them? ("true" or "false")
START_STOPPED_LINUX_VMS="${START_STOPPED_LINUX_VMS}"

# Cron schedule (default: "0 23 * * 5" = Fridays at 23:00)
UPDATE_SCHEDULE_CRON="${UPDATE_SCHEDULE_CRON}"

# Scheduled reboot time if kernel is updated (default: "00:00")
REBOOT_TIME="${REBOOT_TIME}"
CONF

chmod 600 "${CONFIG_FILE}"
chown root:root "${CONFIG_FILE}"
print_ok "Config saved ${C_DIM}(chmod 600, root-only)${C_NC}"

# 4. Fetch the update script
print_action "Fetching update script..."
if [ -f "update-everything.sh" ]; then
    cp -f update-everything.sh "${TARGET_PATH}"
    print_ok "Copied from local file"
else
    curl -sSL "${GITHUB_RAW_URL}" -o "${TARGET_PATH}"
    print_ok "Downloaded from GitHub"
fi
chmod +x "${TARGET_PATH}"

# 5. Create log directory
mkdir -p "${LOG_DIR}"
print_ok "Log directory: ${C_DIM}${LOG_DIR}/${C_NC}"

# 5b. Web control panel
# Fetch a support file either from the checkout we were run from, or from GitHub.
# Downloads go to a temp file first so a failed fetch can't leave a truncated
# executable in place of a working one.
fetch_asset() {
    local rel="$1" dest="$2"
    if [ -f "${rel}" ]; then
        cp -f "${rel}" "${dest}"
        return 0
    fi
    local tmp
    tmp=$(mktemp) || return 1
    if curl -fsSL "${GITHUB_RAW_BASE}/${rel}" -o "${tmp}" && [ -s "${tmp}" ]; then
        mv -f "${tmp}" "${dest}"
        return 0
    fi
    rm -f "${tmp}"
    print_fail "Could not download ${rel} from ${GITHUB_RAW_BASE}"
    return 1
}

if [ "${ENABLE_WEB_UI}" = "true" ]; then
    print_action "Installing web control panel..."

    if ! command -v python3 >/dev/null 2>&1; then
        print_fail "python3 not found — required by the control panel."
        print_fail "Install it with 'apt-get install -y python3', then re-run this installer."
        exit 1
    fi

    UI_FETCH_OK=true
    fetch_asset "webui/pve-autoupdate-ui" "${UI_BIN}"              || UI_FETCH_OK=false
    fetch_asset "webui/patch-webui.sh" "${UI_PATCHER}"             || UI_FETCH_OK=false
    fetch_asset "webui/pve-autoupdate-ui.service" "${UI_SERVICE}"  || UI_FETCH_OK=false
    fetch_asset "webui/99-proxmox-autoupdate-webui" "${UI_APT_HOOK}" || UI_FETCH_OK=false
    if [ "${UI_FETCH_OK}" != true ]; then
        print_fail "Web control panel files could not be installed — skipping it."
        print_fail "The scheduled updates themselves are unaffected."
        ENABLE_WEB_UI="false"
    fi
fi

if [ "${ENABLE_WEB_UI}" = "true" ]; then
    chmod +x "${UI_BIN}" "${UI_PATCHER}"
    chmod 644 "${UI_SERVICE}" "${UI_APT_HOOK}"

    # The port lives in the unit file's environment, not the shell config, so the
    # service picks it up without sourcing a root-only file.
    if ! grep -q "^Environment=PAU_UI_PORT=" "${UI_SERVICE}"; then
        sed -i "/^\[Service\]/a Environment=PAU_UI_PORT=${WEB_UI_PORT}" "${UI_SERVICE}"
    else
        sed -i "s|^Environment=PAU_UI_PORT=.*|Environment=PAU_UI_PORT=${WEB_UI_PORT}|" "${UI_SERVICE}"
    fi

    systemctl daemon-reload
    systemctl enable pve-autoupdate-ui.service >/dev/null 2>&1 || true
    if systemctl restart pve-autoupdate-ui.service; then
        print_ok "Service running on port ${WEB_UI_PORT}"
    else
        print_fail "Service failed to start — check: journalctl -u pve-autoupdate-ui -n 50"
    fi

    # --- Certificate situation ---
    # The panel is on its own port, which browsers treat as a separate site. If
    # the node has a publicly-trusted certificate there is nothing to do; if it
    # is still on the Proxmox self-signed one, say exactly how to fix it rather
    # than leaving the user with a blank window.
    CERT_PATH=""
    for CANDIDATE in /etc/pve/local/pveproxy-ssl.pem /etc/pve/local/pve-ssl.pem; do
        if [ -f "${CANDIDATE}" ]; then CERT_PATH="${CANDIDATE}"; break; fi
    done

    CERT_KIND="unknown"
    if [ -n "${CERT_PATH}" ] && command -v openssl >/dev/null 2>&1; then
        CERT_ISSUER=$(openssl x509 -in "${CERT_PATH}" -noout -issuer 2>/dev/null || true)
        if echo "${CERT_ISSUER}" | grep -q "Proxmox Virtual Environment"; then
            CERT_KIND="selfsigned"
        elif [ -n "${CERT_ISSUER}" ]; then
            CERT_KIND="ca"
        fi
    fi

    case "${CERT_KIND}" in
        ca)
            print_ok "Certificate is CA-signed ${C_DIM}(${CERT_PATH})${C_NC}"
            print_ok "No certificate step needed — the panel is trusted on port ${WEB_UI_PORT}"
            ;;
        selfsigned)
            print_action "Certificate is the Proxmox self-signed one"
            ;;
        *)
            print_action "Could not determine the certificate type"
            ;;
    esac

    # The toolbar button. Non-fatal: the panel is still reachable by URL if the
    # patch cannot be applied.
    if [ -f "${PVE_JS}" ]; then
        if "${UI_PATCHER}" apply; then
            print_ok "Apt hook installed ${C_DIM}(re-applies the button after pve-manager upgrades)${C_NC}"
        else
            print_fail "Could not patch the Proxmox UI — the panel is still usable directly:"
            print_fail "  https://$(hostname -f 2>/dev/null || hostname):${WEB_UI_PORT}/"
        fi
    else
        print_fail "${PVE_JS} not found — skipping the toolbar button."
    fi
else
    # Cleanly tear down a previously enabled panel.
    if [ -f "${UI_SERVICE}" ] || [ -x "${UI_PATCHER}" ]; then
        print_action "Removing previously installed web control panel..."
        [ -x "${UI_PATCHER}" ] && "${UI_PATCHER}" remove >/dev/null 2>&1 || true
        systemctl disable --now pve-autoupdate-ui.service >/dev/null 2>&1 || true
        rm -f "${UI_SERVICE}" "${UI_APT_HOOK}" "${UI_BIN}" "${UI_PATCHER}"
        systemctl daemon-reload
        print_ok "Web control panel removed"
    fi
fi

# 6. Idempotent Cron Configuration
print_action "Configuring cron schedule..."
CRON_MARKER="# proxmox-autoupdate"
CRON_JOB="${UPDATE_SCHEDULE_CRON} ${TARGET_PATH} >> ${LOG_DIR}/cron.log 2>&1"

CRON_TMP=$(mktemp)
crontab -l 2>/dev/null | grep -v "${TARGET_PATH}" | grep -v "${CRON_MARKER}" > "${CRON_TMP}" || true
echo "${CRON_MARKER}" >> "${CRON_TMP}"
echo "${CRON_JOB}" >> "${CRON_TMP}"
if ! crontab "${CRON_TMP}" 2>/tmp/cron_err.log; then
    print_fail "Invalid cron schedule! crontab rejected it:"
    sed 's/^/    /' /tmp/cron_err.log
    rm -f "${CRON_TMP}" /tmp/cron_err.log
    exit 1
fi
rm -f "${CRON_TMP}" /tmp/cron_err.log

# Verify crontab entry was written successfully
if INSTALLED_CRON=$(crontab -l 2>/dev/null | grep "${TARGET_PATH}"); then
    print_ok "Crontab active: ${C_DIM}${INSTALLED_CRON}${C_NC}"
else
    print_fail "Failed to register cron job in crontab!"
    exit 1
fi

# 7. Deployment summary
echo ""
print_box_top
print_box_line "${C_GREEN}${C_BOLD}Deployment successful! ✓${C_NC}" "Deployment successful! X"
print_box_bottom
echo ""
echo -e "  ${C_CYAN}Script:${C_NC}     ${TARGET_PATH}"
echo -e "  ${C_CYAN}Config:${C_NC}     ${CONFIG_FILE} ${C_DIM}(600, root-only)${C_NC}"
echo -e "  ${C_CYAN}Logs:${C_NC}       ${LOG_DIR}/"
echo -e "  ${C_CYAN}Region:${C_NC}     ${MAILGUN_REGION}"
echo -e "  ${C_CYAN}Sender:${C_NC}     ${SENDER_EMAIL}"
echo -e "  ${C_CYAN}Recipient:${C_NC}  ${RECIPIENT_EMAIL}"
echo -e "  ${C_CYAN}Excluded:${C_NC}   ${EXCLUDE_IDS:-none}"
echo -e "  ${C_CYAN}LXC:${C_NC}        Start stopped=${START_STOPPED_LXC}"
echo -e "  ${C_CYAN}Linux VMs:${C_NC}  Start stopped=${START_STOPPED_LINUX_VMS}"
echo -e "  ${C_CYAN}Win VMs:${C_NC}    Start stopped=${START_STOPPED_WINDOWS}, timeout=${WINDOWS_UPDATE_TIMEOUT}s"
echo -e "  ${C_CYAN}Timeouts:${C_NC}   Linux=${LINUX_UPDATE_TIMEOUT}s, apt lock wait=${APT_LOCK_TIMEOUT}s"
if [ "${SNAPSHOT_BEFORE_UPDATE}" = "true" ]; then
    echo -e "  ${C_CYAN}Snapshots:${C_NC}  enabled, keeping ${SNAPSHOT_KEEP} per guest"
else
    echo -e "  ${C_CYAN}Snapshots:${C_NC}  disabled"
fi
echo -e "  ${C_CYAN}Schedule:${C_NC}   ${UPDATE_SCHEDULE_CRON}"
echo -e "  ${C_CYAN}Reboot:${C_NC}     ${REBOOT_TIME} (if kernel updated)"
if [ "${ENABLE_WEB_UI}" = "true" ]; then
    PANEL_URL="https://$(hostname -f 2>/dev/null || hostname):${WEB_UI_PORT}/"
    echo -e "  ${C_CYAN}Web panel:${C_NC}  ${PANEL_URL}"
    echo ""
    if [ "${CERT_KIND:-unknown}" = "ca" ]; then
        echo -e "  ${C_GREEN}Certificate:${C_NC} CA-signed — nothing to accept, the panel just works."
        echo -e "  ${C_DIM}Renewals are picked up automatically without restarting the service.${C_NC}"
    else
        echo -e "  ${C_YELLOW}Certificate:${C_NC} this node uses the Proxmox self-signed certificate."
        echo -e "  Browsers scope certificate exceptions per port, so port ${WEB_UI_PORT} needs"
        echo -e "  approving once even though you already trust port 8006."
        echo ""
        echo -e "  ${C_BOLD}Pick one:${C_NC}"
        echo -e "    ${C_CYAN}a)${C_NC} Open ${PANEL_URL} once and accept the warning."
        echo -e "       ${C_DIM}Per browser, per machine. The UI prompts you if you skip this.${C_NC}"
        echo -e "    ${C_CYAN}b)${C_NC} Set up ACME: ${C_BOLD}Datacenter → ACME${C_NC}, then Node → Certificates → Order."
        echo -e "       ${C_DIM}Permanent, applies to every browser, and also removes the${C_NC}"
        echo -e "       ${C_DIM}warning on the Proxmox UI itself. This service picks the new${C_NC}"
        echo -e "       ${C_DIM}certificate up automatically when it renews.${C_NC}"
        echo -e "    ${C_CYAN}c)${C_NC} Install the Proxmox root CA on your computer:"
        echo -e "       ${C_DIM}/etc/pve/pve-root-ca.pem → your OS trust store. Also fixes 8006.${C_NC}"
    fi
    echo ""
    echo -e "  ${C_DIM}Hard-refresh the Proxmox UI (Ctrl+Shift+R) to see the new button.${C_NC}"
fi
echo ""

# 8. Interactive Test Run Option
# Both run modes send the report email, so either one verifies that the Mailgun
# credentials, region and recipient are actually working end to end.
echo -e "${C_BOLD}── Test Run ────────────────────────────────────────────────${C_NC}"
echo ""
echo -e "  ${C_BOLD}Run now to verify the setup?${C_NC}"
echo -e "    ${C_CYAN}1)${C_NC} Dry run   ${C_DIM}— check everything and email the report,${C_NC}"
echo -e "                  ${C_DIM}but install nothing and never reboot${C_NC}"
echo -e "    ${C_CYAN}2)${C_NC} Full run  ${C_DIM}— update the host and every guest now,${C_NC}"
echo -e "                  ${C_DIM}then email the report${C_NC}"
echo -e "    ${C_CYAN}3)${C_NC} Skip      ${C_DIM}— wait for the scheduled run (${UPDATE_SCHEDULE_CRON})${C_NC}"
echo ""
read -rp "  Select 1-3 [Enter for 1]: " RUN_CHOICE < /dev/tty

RUN_MODE=""
case "${RUN_CHOICE:-1}" in
    1) RUN_MODE="dry" ;;
    2) RUN_MODE="full" ;;
    3) RUN_MODE="skip" ;;
    *)
        print_fail "Unrecognised choice '${RUN_CHOICE}' — skipping the test run."
        RUN_MODE="skip"
        ;;
esac

if [ "${RUN_MODE}" = "full" ]; then
    echo ""
    echo -e "  ${C_YELLOW}${C_BOLD}This will update the host and every guest right now.${C_NC}"
    read -rp "  Type 'yes' to confirm: " CONFIRM_FULL < /dev/tty
    if [ "${CONFIRM_FULL}" != "yes" ]; then
        print_action "Not confirmed — falling back to a dry run."
        RUN_MODE="dry"
    fi
fi

case "${RUN_MODE}" in
    dry)
        echo ""
        echo -e "${C_BOLD}── Dry Run ─────────────────────────────────────────────────${C_NC}"
        echo ""
        RUN_RC=0
        "${TARGET_PATH}" --dry-run || RUN_RC=$?
        echo ""
        if [ "${RUN_RC}" -eq 0 ]; then
            print_ok "Dry run complete — nothing was installed or rebooted"
            print_ok "Check ${C_BOLD}${RECIPIENT_EMAIL}${C_NC} for the report email"
        else
            print_fail "Dry run exited with code ${RUN_RC} — see ${LOG_DIR}/"
        fi
        echo ""
        ;;
    full)
        echo ""
        echo -e "${C_BOLD}── Full Run ────────────────────────────────────────────────${C_NC}"
        echo ""
        RUN_RC=0
        "${TARGET_PATH}" || RUN_RC=$?

        # A kernel update during this run would have queued a reboot. The user
        # is sitting at the console right now, so cancel it and let them choose.
        echo ""
        print_action "Cancelling any queued reboot from this run..."
        shutdown -c 2>/dev/null || true
        print_ok "Pending reboot cancelled — reboot manually if the kernel changed"

        echo ""
        if [ "${RUN_RC}" -eq 0 ]; then
            print_ok "Full run complete"
            print_ok "Check ${C_BOLD}${RECIPIENT_EMAIL}${C_NC} for the report email"
        else
            print_fail "Run exited with code ${RUN_RC} — see ${LOG_DIR}/"
        fi
        echo ""
        ;;
    skip)
        echo ""
        print_ok "Skipped. First run: ${C_BOLD}${UPDATE_SCHEDULE_CRON}${C_NC}"
        echo -e "  ${C_DIM}Test it any time with:  ${TARGET_PATH} --dry-run${C_NC}"
        echo ""
        ;;
esac