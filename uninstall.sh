#!/usr/bin/env bash
# ==============================================================================
# Uninstaller for Proxmox Auto-Update
#
# Removes the update script, the cron entry, the web control panel and the
# Proxmox UI patch. Configuration and logs are kept unless --purge is given,
# because they hold your Mailgun credentials and your update history.
#
# Usage: uninstall.sh [--yes] [--purge]
#   --yes     Don't prompt for confirmation.
#   --purge   Also delete /etc/proxmox-autoupdate.conf and the log directory.
# ==============================================================================

set -uo pipefail

TARGET_PATH="/usr/local/bin/update-everything.sh"
CONFIG_FILE="/etc/proxmox-autoupdate.conf"
LOG_DIR="/var/log/proxmox-autoupdate"
LOCKFILE="/var/run/proxmox-autoupdate.lock"
STATE_DIR="/var/lib/proxmox-autoupdate"

UI_BIN="/usr/local/bin/pve-autoupdate-ui"
UI_PATCHER="/usr/local/bin/pve-autoupdate-patch-webui"
UI_SERVICE="/etc/systemd/system/pve-autoupdate-ui.service"
UI_APT_HOOK="/etc/apt/apt.conf.d/99-proxmox-autoupdate-webui"
PVE_JS="/usr/share/pve-manager/js/pvemanagerlib.js"

BEGIN_MARKER="/* ==== BEGIN proxmox-autoupdate button ==== */"
END_MARKER="/* ==== END proxmox-autoupdate button ==== */"
SENTINEL="PVE.StdWorkspace"

# Colour only when stdout is a terminal that can show it, and bright black
# rather than the faint attribute — xterm.js, which the Proxmox web shell is
# built on, renders faint text at very low contrast on a dark background, so
# the "will keep" detail lines were near-invisible exactly where they matter.
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_DIM='\033[90m'; C_NC='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_DIM='' C_NC=''
fi

print_ok()     { echo -e "  ${C_GREEN}✓${C_NC} $1"; }
print_fail()   { echo -e "  ${C_RED}✗${C_NC} $1"; }
print_warn()   { echo -e "  ${C_YELLOW}⚠${C_NC} $1"; }
print_skip()   { echo -e "  ${C_DIM}⊘ $1${C_NC}"; }
print_action() { echo -e "  ${C_CYAN}▶${C_NC} $1"; }

print_box_top()    { echo -e "${C_BOLD}${C_CYAN}╔═══════════════════════════════════════════════════════════╗${C_NC}"; }
print_box_bottom() { echo -e "${C_BOLD}${C_CYAN}╚═══════════════════════════════════════════════════════════╝${C_NC}"; }
print_box_line() {
    local text="$1" raw="$2"
    local pad=$(( 57 - ${#raw} ))
    [ "${pad}" -lt 0 ] && pad=0
    echo -e "${C_BOLD}${C_CYAN}║${C_NC}  ${text}$(printf '%*s' "${pad}" '')${C_BOLD}${C_CYAN}║${C_NC}"
}

ASSUME_YES=false
PURGE=false
for arg in "$@"; do
    case "${arg}" in
        -y|--yes)   ASSUME_YES=true ;;
        --purge)    PURGE=true ;;
        -h|--help)
            cat <<'USAGE'
Uninstaller for Proxmox Auto-Update

Removes the update script, the cron entry, the web control panel and the
Proxmox UI patch.

Usage: uninstall.sh [--yes] [--purge]

  -y, --yes     Don't prompt for confirmation.
      --purge   Also delete /etc/proxmox-autoupdate.conf and the log
                directory. Without this they are kept, because they hold
                your Mailgun credentials and your update history.
  -h, --help    Show this message.
USAGE
            exit 0
            ;;
        *)
            echo "Unknown option: ${arg} (try --help)"
            exit 1
            ;;
    esac
done

echo ""
print_box_top
print_box_line "${C_BOLD}Proxmox Auto-Update — Uninstaller${C_NC}" "Proxmox Auto-Update - Uninstaller"
print_box_bottom

if [ "$(id -u)" -ne 0 ]; then
    echo ""
    print_fail "This uninstaller must be run as ${C_BOLD}root${C_NC}."
    exit 1
fi

# --- Show what will happen before doing any of it ---
echo ""
echo -e "${C_BOLD}── Will remove ─────────────────────────────────────────────${C_NC}"
echo ""
echo -e "  ${TARGET_PATH}"
echo -e "  the cron entry"
echo -e "  the web control panel (service, patcher, apt hook)"
echo -e "  the Auto-Update button and tabs from the Proxmox UI"
echo -e "  the uninstaller itself"
if [ "${PURGE}" = true ]; then
    echo -e "  ${C_YELLOW}${CONFIG_FILE}${C_NC} ${C_DIM}(your credentials and settings)${C_NC}"
    echo -e "  ${C_YELLOW}${LOG_DIR}/${C_NC} ${C_DIM}(every past update report)${C_NC}"
    echo -e "  ${C_YELLOW}${STATE_DIR}/${C_NC} ${C_DIM}(run history)${C_NC}"
fi
echo ""
echo -e "${C_BOLD}── Will keep ───────────────────────────────────────────────${C_NC}"
echo ""
if [ "${PURGE}" = true ]; then
    # These are deleted by --purge. Listing them here said the opposite of what
    # was about to happen: "Will keep — nothing, --purge was given" followed by
    # the two files it was about to delete. They belong in the remove list, and
    # they are printed there now.
    echo -e "  ${C_YELLOW}nothing — --purge was given${C_NC}"
else
    echo -e "  ${CONFIG_FILE} ${C_DIM}(your Mailgun credentials and settings)${C_NC}"
    echo -e "  ${LOG_DIR}/ ${C_DIM}(past update reports)${C_NC}"
    echo -e "  ${C_DIM}Pass --purge to delete these too.${C_NC}"
fi
echo ""
echo -e "  ${C_DIM}Guest snapshots named autoupdate_* are never touched — remove them${C_NC}"
echo -e "  ${C_DIM}yourself with 'qm delsnapshot' / 'pct delsnapshot' if you want them gone.${C_NC}"
echo ""

if [ "${ASSUME_YES}" != true ]; then
    # CONFIRM must be initialised: without a controlling terminal the read fails
    # outright, and `set -u` then turned the test below into a fatal
    # "CONFIRM: unbound variable" instead of a clean cancellation.
    CONFIRM=""
    if ! read -rp "  Proceed? (y/N): " CONFIRM < /dev/tty 2>/dev/null; then
        echo ""
        print_skip "No terminal to confirm on — nothing was changed."
        echo -e "  ${C_DIM}Re-run with --yes to uninstall non-interactively.${C_NC}"
        echo ""
        exit 0
    fi
    if ! [[ "${CONFIRM}" =~ ^[Yy]$ ]]; then
        echo ""
        print_skip "Cancelled — nothing was changed."
        echo ""
        exit 0
    fi
fi

echo ""
echo -e "${C_BOLD}── Removing ────────────────────────────────────────────────${C_NC}"
echo ""

# --- 1. Refuse to pull the rug out from under a running update ---
if [ -f "${LOCKFILE}" ] && command -v fuser >/dev/null 2>&1; then
    if fuser "${LOCKFILE}" >/dev/null 2>&1; then
        print_fail "An update is currently running (lock held on ${LOCKFILE})."
        print_fail "Wait for it to finish, then run this again."
        exit 1
    fi
fi

# --- 2. Un-patch the Proxmox UI first, while the patcher still exists ---
if [ -f "${PVE_JS}" ] && grep -qF "${BEGIN_MARKER}" "${PVE_JS}" 2>/dev/null; then
    if [ -x "${UI_PATCHER}" ] && "${UI_PATCHER}" remove >/dev/null 2>&1; then
        print_ok "Proxmox UI patch removed"
    else
        # Fall back to doing it inline, so a missing or broken patcher can't
        # leave the button stranded in pve-manager's file forever.
        TMP_JS=$(mktemp)
        awk -v b="${BEGIN_MARKER}" -v e="${END_MARKER}" '
            index($0, b) { skip = 1 }
            !skip        { print }
            index($0, e) { skip = 0 }
        ' "${PVE_JS}" > "${TMP_JS}"
        if grep -qF "${SENTINEL}" "${TMP_JS}" && ! grep -qF "${BEGIN_MARKER}" "${TMP_JS}"; then
            cat "${TMP_JS}" > "${PVE_JS}"
            print_ok "Proxmox UI patch removed ${C_DIM}(inline fallback)${C_NC}"
        else
            print_fail "Could not safely un-patch ${PVE_JS} — left untouched."
            print_fail "Reinstall pve-manager to restore it: apt-get install --reinstall pve-manager"
        fi
        rm -f "${TMP_JS}"
    fi
else
    print_skip "Proxmox UI was not patched"
fi

# --- 3. Web control panel service ---
if systemctl list-unit-files 2>/dev/null | grep -q '^pve-autoupdate-ui\.service'; then
    systemctl disable --now pve-autoupdate-ui.service >/dev/null 2>&1 || true
    print_ok "Web control panel service stopped and disabled"
else
    print_skip "Web control panel service not installed"
fi

REMOVED_FILES=0
# The last three were created by install.sh but never removed here, so after a
# "complete" uninstall the pve-autoupdate-uninstall command stayed on PATH
# forever and the systemd drop-in directory was orphaned.
for FILE in "${UI_SERVICE}" "${UI_APT_HOOK}" "${UI_BIN}" "${UI_PATCHER}" \
            "/usr/local/bin/pve-autoupdate-uninstall" \
            "/etc/logrotate.d/proxmox-autoupdate"; do
    if [ -e "${FILE}" ]; then
        rm -f "${FILE}"
        REMOVED_FILES=$((REMOVED_FILES + 1))
    fi
done
for DIR in "${UI_SERVICE}.d" "/usr/local/share/proxmox-autoupdate"; do
    if [ -d "${DIR}" ]; then
        rm -rf "${DIR}"
        REMOVED_FILES=$((REMOVED_FILES + 1))
    fi
done
if [ "${REMOVED_FILES}" -gt 0 ]; then
    print_ok "Removed ${REMOVED_FILES} web panel file(s)"
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

# --- 4. Cron entry ---
if crontab -l 2>/dev/null | grep -q "${TARGET_PATH}"; then
    CRON_TMP=$(mktemp)
    crontab -l 2>/dev/null \
        | grep -v "${TARGET_PATH}" \
        | grep -v '^# proxmox-autoupdate$' > "${CRON_TMP}" || true
    if crontab "${CRON_TMP}"; then
        print_ok "Cron entry removed"
    else
        print_fail "Could not update crontab — remove the entry manually with 'crontab -e'"
    fi
    rm -f "${CRON_TMP}"
else
    print_skip "No cron entry found"
fi

# --- 5. The update script itself ---
if [ -e "${TARGET_PATH}" ]; then
    rm -f "${TARGET_PATH}"
    print_ok "Removed ${TARGET_PATH}"
else
    print_skip "${TARGET_PATH} not present"
fi

# --- 6. State directory (holds the pristine pvemanagerlib.js backup) ---
if [ -d "${STATE_DIR}" ]; then
    rm -rf "${STATE_DIR}"
    print_ok "Removed ${STATE_DIR}"
fi

# Deliberately not removing the lockfile. If a run is still going, unlinking it
# lets the next invocation create a fresh inode and take its own flock, so two
# runs end up driving pct and qm at once. It is a zero-byte file; leaving it is
# harmless.

# --- 7. Config and logs, only with --purge ---
if [ "${PURGE}" = true ]; then
    if [ -e "${CONFIG_FILE}" ]; then
        rm -f "${CONFIG_FILE}"
        print_ok "Removed ${CONFIG_FILE}"
    fi
    if [ -d "${LOG_DIR}" ]; then
        rm -rf "${LOG_DIR}"
        print_ok "Removed ${LOG_DIR}/"
    fi
else
    [ -e "${CONFIG_FILE}" ] && print_skip "Kept ${CONFIG_FILE}"
    [ -d "${LOG_DIR}" ]    && print_skip "Kept ${LOG_DIR}/"
fi

# --- 8. Cancel any reboot this tool scheduled ---
# Only if one is actually pending. A bare `shutdown -c` cancels whatever is
# queued regardless of who queued it, and on systemd it exits 0 with nothing
# scheduled, so the "Cancelled a pending scheduled reboot" line printed on
# essentially every uninstall whether or not anything had been cancelled.
if [ -e /run/systemd/shutdown/scheduled ] && shutdown -c 2>/dev/null; then
    print_ok "Cancelled a pending scheduled reboot"
fi

echo ""
print_box_top
print_box_line "${C_GREEN}${C_BOLD}Uninstall complete ✓${C_NC}" "Uninstall complete"
print_box_bottom
echo ""
if [ -f "${PVE_JS}" ]; then
    echo -e "  ${C_DIM}Hard-refresh the Proxmox UI (Ctrl+Shift+R) to clear the cached button.${C_NC}"
fi
if [ "${PURGE}" != true ] && [ -e "${CONFIG_FILE}" ]; then
    echo -e "  ${C_DIM}Config kept at ${CONFIG_FILE} — re-running install.sh will reuse it.${C_NC}"
fi
echo ""
