#!/usr/bin/env bash
# ==============================================================================
# Dynamic Interactive Installer for Proxmox Auto-Update Service
# ==============================================================================

set -euo pipefail

TARGET_PATH="/usr/local/bin/update-everything.sh"
CONFIG_FILE="/etc/proxmox-autoupdate.conf"
LOG_DIR="/var/log/proxmox-autoupdate"
GITHUB_RAW_URL="https://raw.githubusercontent.com/Enhanced-Group/proxmox-autoupdate/main/update-everything.sh"

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
echo -e "  ${C_CYAN}Schedule:${C_NC}   ${UPDATE_SCHEDULE_CRON}"
echo -e "  ${C_CYAN}Reboot:${C_NC}     ${REBOOT_TIME} (if kernel updated)"
echo ""

# 8. Interactive Test Run Option
read -rp "  Would you like to trigger a test run now? (y/N): " RUN_TEST < /dev/tty
if [[ "${RUN_TEST}" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${C_BOLD}── Test Run ────────────────────────────────────────────────${C_NC}"
    echo ""
    "${TARGET_PATH}"

    echo ""
    print_action "Cancelling queued midnight reboot timer..."
    shutdown -c 2>/dev/null || true
    print_ok "Pending reboot cancelled"
    echo ""
    echo -e "  ${C_GREEN}${C_BOLD}Test complete! ✓${C_NC}"
    echo ""
fi