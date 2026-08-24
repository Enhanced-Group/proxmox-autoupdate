#!/usr/bin/env bash
# ==============================================================================
# Dynamic Interactive Installer for Proxmox Auto-Update Service
# ==============================================================================

set -euo pipefail

TARGET_PATH="/usr/local/bin/update-everything.sh"
CONFIG_FILE="/etc/proxmox-autoupdate.conf"
LOG_DIR="/var/log/proxmox-autoupdate"
STATE_DIR="/var/lib/proxmox-autoupdate"
REPO_SLUG="Enhanced-Group/proxmox-autoupdate"

# Which revision to install.
#
# This used to be hardcoded to `main`, and the panel's "Install update" button
# ran it unattended as root. That made every push to main immediately live on
# every installation — an unreviewed commit, or a half-finished one, went
# straight into a root cron job everywhere. Installs now track *released tags*
# by default.
#
#   PAU_CHANNEL=release   (default) install the latest published release
#   PAU_CHANNEL=main                track main, for development
#   PAU_REF=v1.0.0                  pin an exact tag, branch or commit
#
# PAU_BRANCH is still honoured so existing documentation and scripts keep
# working.
PAU_FALLBACK_REF="v1.10.0"
PAU_CHANNEL="${PAU_CHANNEL:-release}"
PAU_REF="${PAU_REF:-${PAU_BRANCH:-}}"

# Ask GitHub for the newest published release. Deliberately tolerant: no jq (it
# may not be installed yet), short timeout, and any failure falls back to the
# tag baked in above rather than silently reaching for main.
# Tags from the retired numbering.
#
# This project released under a 2.x–4.x scheme before settling on the 1.x line.
# Those tags are still on GitHub — the history is worth keeping — but they sort
# numerically *above* every 1.x release, so "newest tag wins" would install the
# retired code on every fresh machine, forever. They are filtered out by number
# rather than deleted.
#
# If this ever legitimately reaches 2.0, this filter has to go with it.
RETIRED_TAG_RE='^v?[234]\.'

is_retired_tag() {
    [ -n "$1" ] && echo "$1" | grep -qE "${RETIRED_TAG_RE}"
}

resolve_ref() {
    if [ -n "${PAU_REF}" ]; then
        echo "${PAU_REF}"
        return
    fi
    if [ "${PAU_CHANNEL}" = "main" ]; then
        echo "main"
        return
    fi
    local tag=""
    tag=$(curl -fsSL -m 15 "https://api.github.com/repos/${REPO_SLUG}/releases/latest" 2>/dev/null \
          | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    is_retired_tag "${tag}" && tag=""
    # Take whichever is newer of the published Release and the highest git tag.
    #
    # /releases/latest only knows about published Release objects, so tagging
    # without also publishing leaves it pointing at an older version and every
    # install silently gets that instead of the newest. Comparing the two, and
    # comparing tags by version rather than by the order GitHub returns them,
    # means neither a missing Release nor an odd ordering can install backwards.
    local newest_tag=""
    newest_tag=$(curl -fsSL -m 15 "https://api.github.com/repos/${REPO_SLUG}/tags?per_page=100" 2>/dev/null \
          | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
          | sed -n 's/.*"\([^"]*\)"$/\1/p' \
          | grep -E '^v?[0-9]+(\.[0-9]+)*$' \
          | grep -vE "${RETIRED_TAG_RE}" \
          | sort -V | tail -1)
    if [ -z "${tag}" ]; then
        tag="${newest_tag}"
    elif [ -n "${newest_tag}" ] && [ "${tag}" != "${newest_tag}" ]; then
        # sort -V puts the higher version last; if that is the tag, prefer it.
        if [ "$(printf '%s\n%s\n' "${tag}" "${newest_tag}" | sort -V | tail -1)" = "${newest_tag}" ]; then
            tag="${newest_tag}"
        fi
    fi
    if echo "${tag}" | grep -qE '^[A-Za-z0-9._/-]{1,64}$'; then
        echo "${tag}"
    else
        echo "${PAU_FALLBACK_REF}"
    fi
}

PAU_RESOLVED_REF="$(resolve_ref)"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}/${PAU_RESOLVED_REF}"
GITHUB_RAW_URL="${GITHUB_RAW_BASE}/update-everything.sh"

# Web control panel
UI_BIN="/usr/local/bin/pve-autoupdate-ui"
UI_PATCHER="/usr/local/bin/pve-autoupdate-patch-webui"
UI_SERVICE="/etc/systemd/system/pve-autoupdate-ui.service"
UI_APT_HOOK="/etc/apt/apt.conf.d/99-proxmox-autoupdate-webui"
PVE_JS="/usr/share/pve-manager/js/pvemanagerlib.js"

# --- Output ------------------------------------------------------------------
#
# Colour only when stdout is a terminal that can render it. Piping the installer
# into a file, or running it from Ansible, previously produced a wall of raw
# escape sequences.
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    # Bright black, not the "faint" attribute.
    #
    # This was \033[2m, and it is the main reason the installer looked
    # half-empty: xterm.js — which is what the Proxmox web shell uses — renders
    # faint text at very low contrast on a dark background, so every
    # explanatory line in this script was effectively invisible in the terminal
    # most people run it from. Bright black is a real colour and stays legible
    # on both dark and light themes.
    C_DIM='\033[90m'
    C_NC='\033[0m'
    HAS_TTY_OUT=true
else
    C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_DIM='' C_NC=''
    HAS_TTY_OUT=false
fi

print_ok()     { echo -e "  ${C_GREEN}✓${C_NC} $1"; }
print_skip()   { echo -e "  ${C_DIM}⊘ $1${C_NC}"; }

# --- Progress ----------------------------------------------------------------
#
# The installer downloads several files, can install packages, patches the
# Proxmox UI and restarts a service — and did all of it in silence. On a slow
# link the whole thing looked hung, and there was no way to tell how far
# through it was. Steps are numbered, and anything that can take more than a
# moment runs behind a spinner that degrades to a plain line without a
# terminal.
STEP_TOTAL=10
STEP_NOW=0
_SPIN_PID=""

step() {
    STEP_NOW=$((STEP_NOW + 1))
    echo ""
    echo -e "${C_CYAN}${C_BOLD}[${STEP_NOW}/${STEP_TOTAL}]${C_NC} ${C_BOLD}$1${C_NC}"
}

spin_start() {
    local msg="$1"
    if [ "${HAS_TTY_OUT}" != true ]; then
        echo -e "  ${C_CYAN}▶${C_NC} ${msg}"
        return 0
    fi
    (
        trap 'exit 0' TERM
        local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
        while :; do
            printf "\r  \033[0;36m%s\033[0m %s" "${frames:$i:1}" "${msg}"
            i=$(( (i + 1) % ${#frames} ))
            sleep 0.08
        done
    ) 2>/dev/null &
    _SPIN_PID=$!
}

spin_stop() {
    [ -n "${_SPIN_PID}" ] || return 0
    kill "${_SPIN_PID}" 2>/dev/null || true
    wait "${_SPIN_PID}" 2>/dev/null || true
    _SPIN_PID=""
    [ "${HAS_TTY_OUT}" = true ] && printf "\r\033[K"
    return 0
}

# Run a command behind a spinner and report the outcome. Returns the command's
# own status, so a caller can still decide what a failure means; on failure the
# last few lines of its output are shown, which is what was missing when these
# ran silently and only their absence of a tick told you anything.
run_step() {
    local msg="$1"; shift
    spin_start "${msg}"
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    spin_stop
    if [ "${rc}" -eq 0 ]; then
        print_ok "${msg}"
    else
        print_fail "${msg} ${C_DIM}(exit ${rc})${C_NC}"
        [ -n "${out}" ] && echo "${out}" | tail -n 4 | sed "s/^/      ${C_DIM}/;s/\$/${C_NC}/"
    fi
    return "${rc}"
}

# Never leave a spinner spinning if the script aborts.
trap 'spin_stop' EXIT INT TERM

# Ask a question on fd 3.
#
# `read -p` cannot be used for this, and using it was the single worst bug in
# this installer. Bash prints a -p prompt *only when stdin is a terminal* — and
# under the documented install, `curl -fsSL … | bash`, stdin is the script being
# piped in. Every one of the forty-odd questions here therefore printed nothing
# at all: the terminal sat at a blank line, cursor waiting, for an answer to a
# question it had never shown. Whole sections looked empty. Prompts are written
# out explicitly here, so they are visible however the installer was started.
#
# The prompt goes through %b so ${C_BOLD} and friends still render.
ask() {
    local __var="$1" __prompt="$2" __ans=""
    printf '%b' "${__prompt}"
    # On EOF — no terminal, or an answer file that has run out — read leaves the
    # line half-written, so close it here.
    read -r __ans <&3 || { __ans=""; echo ""; }
    printf -v "${__var}" '%s' "${__ans}"
}

# The same, without echoing what is typed. For tokens, passwords and API keys.
ask_secret() {
    local __var="$1" __prompt="$2" __ans=""
    printf '%b' "${__prompt}"
    read -rs __ans <&3 || __ans=""
    echo ""
    printf -v "${__var}" '%s' "${__ans}"
}

# Render a value as a single-quoted shell literal, for writing into the config.
#
# The config file is `source`d as root by every cron run. Values used to be
# written into a double-quoted heredoc raw, so whatever was typed at a prompt
# was re-interpreted by the shell on the way back in:
#
#   a password containing $      ->  every run dies with "unbound variable",
#                                    before notify_fatal, so silently
#   a token containing `cmd`     ->  cmd runs as root, weekly, forever
#   a value containing "         ->  the file stops being valid shell
#
# None of it is visible: the file on disk shows the right password. The panel
# has always written single-quoted values through sh_quote(), and
# update-everything.sh's comment already asserts "anything the panel or
# installer wrote is single-quoted" — this makes that true of the installer.
sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# --- Schedules -----------------------------------------------------------
#
# UPDATE_SCHEDULES holds one or more schedules, ';'-separated, each of them
# '<5-field cron>|<mode>|<label>', where mode is one of:
#
#   yes    update, and reboot if this run installs a kernel   (no flag)
#   no     update, never reboot                               (--no-reboot)
#   only   do not update; reboot if one is owed               (--reboot-window)
#
# For example:
#
#   UPDATE_SCHEDULES='0 23 * * 5|no|Weekly updates;0 3 1 * *|only|Reboot window'
#
# which installs updates every Friday night, leaving any new kernel waiting, and
# takes the host down for it on the first of the month without touching a
# package. 'only' is the schedule to use when the outage needs its own slot
# rather than riding along with an update run.
#
# Empty means a pre-1.9 install: one schedule, taken from UPDATE_SCHEDULE_CRON,
# allowed to reboot, which is what that config always meant.
#
# Emits one tab-separated 'cron<TAB>reboot<TAB>label' line per schedule.
parse_schedules() {
    local raw="$1" entry rest cron reboot label
    if [ -z "${raw}" ]; then
        if [ -n "${UPDATE_SCHEDULE_CRON:-}" ]; then
            printf '%s\tyes\tUpdates\n' "${UPDATE_SCHEDULE_CRON}"
        fi
        return 0
    fi
    local OLD_IFS="${IFS}"
    IFS=';'
    # shellcheck disable=SC2086
    set -- ${raw}
    IFS="${OLD_IFS}"
    for entry in "$@"; do
        [ -n "${entry}" ] || continue
        case "${entry}" in
            *\|*)
                cron="${entry%%|*}"
                rest="${entry#*|}"
                reboot="${rest%%|*}"
                case "${rest}" in
                    *\|*) label="${rest#*|}" ;;
                    *)    label="" ;;
                esac
                ;;
            *)
                # A bare cron expression, from a hand-edited config.
                cron="${entry}"; reboot="yes"; label=""
                ;;
        esac
        case "${reboot}" in
            no|only) : ;;
            *)       reboot="yes" ;;
        esac
        [ -n "${cron}" ] || continue
        printf '%s\t%s\t%s\n' "${cron}" "${reboot}" "${label}"
    done
}

# Prompt for a value that must not end up empty, falling back to whatever is
# already configured.
#
# Bounded deliberately. The previous `while [ -z "$X" ]; do read ...; done`
# loops relied entirely on a human eventually typing something: with fd 3 on
# /dev/null every read returns instantly and empty, so anything that reached
# them without a terminal would spin forever printing an error. They are not
# currently reachable that way — an empty channel selection short-circuits
# earlier — but that is one edit away from being untrue, and a hung installer
# is a miserable failure mode.
ask_required() {
    local var="$1" label="$2" prev="$3" attempts=0 answer=""
    while [ "${attempts}" -lt 5 ]; do
        attempts=$((attempts + 1))
        if [ -n "${prev}" ]; then
            ask answer "  ${label} [Enter to keep existing]: "
        else
            ask answer "  ${label}: "
        fi
        answer="${answer:-${prev}}"
        if [ -n "${answer}" ]; then
            printf -v "${var}" '%s' "${answer}"
            return 0
        fi
        if [ "${HAVE_TTY}" != true ]; then
            print_fail "${label} is required and there is no terminal to ask on."
            return 1
        fi
        print_fail "${label} is required."
    done
    print_fail "No value given for ${label} after ${attempts} attempts — giving up."
    return 1
}

# Say where the report actually went, rather than pointing at an email address
# that may be empty and a channel that may not be configured. This used to
# unconditionally print "Check  for the report email" even when the user had
# chosen to set up no notifications at all.
report_delivery_hint() {
    if [ -z "${NOTIFY_METHODS}" ] || [ "${NOTIFY_METHODS}" = "none" ]; then
        echo -e "  ${C_DIM}No notification channel is configured, so no report was sent.${C_NC}"
        echo -e "  ${C_DIM}The full output is above, and in ${LOG_DIR}/.${C_NC}"
        return
    fi
    if [ "${NOTIFY_ON_FAILURE_ONLY}" = "true" ]; then
        echo -e "  ${C_DIM}Notifications are set to failures only, so a clean run sends nothing.${C_NC}"
        return
    fi
    case ",${NOTIFY_METHODS}," in
        *,email,*) print_ok "Check ${C_BOLD}${RECIPIENT_EMAIL}${C_NC} for the report email" ;;
    esac
    case ",${NOTIFY_METHODS}," in
        *,discord,*) print_ok "A report was sent to Discord" ;;
    esac
    case ",${NOTIFY_METHODS}," in
        *,slack,*) print_ok "A report was sent to Slack" ;;
    esac
    case ",${NOTIFY_METHODS}," in
        *,teams,*) print_ok "A report was sent to Microsoft Teams" ;;
    esac
    case ",${NOTIFY_METHODS}," in
        *,ntfy,*) print_ok "A report was sent to ntfy" ;;
    esac
    case ",${NOTIFY_METHODS}," in
        *,gotify,*) print_ok "A report was sent to Gotify" ;;
    esac
    case ",${NOTIFY_METHODS}," in
        *,telegram,*) print_ok "A report was sent to Telegram" ;;
    esac
    case ",${NOTIFY_METHODS}," in
        *,webhook,*) print_ok "A report was posted to the configured webhook" ;;
    esac
}
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

# --unattended reuses the existing configuration and asks nothing. Used by the
# web panel's self-update, where there is no terminal to prompt on.
UNATTENDED=false
for ARG in "$@"; do
    case "${ARG}" in
        --unattended) UNATTENDED=true ;;
        -h|--help)
            echo "Usage: install.sh [--unattended]"
            echo "  --unattended  Reuse the existing config, prompt for nothing."
            exit 0
            ;;
    esac
done

# Prompts read from fd 3 rather than stdin, because stdin is the script itself
# under `curl | bash`. In unattended mode every prompt must return immediately
# with the default, so point fd 3 at an always-EOF source.
#
# HAVE_TTY records whether we actually got a terminal. Without one — `ssh host
# 'curl … | bash'` with no -t, Ansible, cloud-init, cron — /dev/tty fails with
# ENXIO, every read returns EOF immediately, and bash does not even print the
# prompt, so the transcript shows only success ticks while defaults are silently
# taken. Anything with side effects has to check this, not just UNATTENDED.
HAVE_TTY=false
if [ "${UNATTENDED}" = true ]; then
    exec 3</dev/null
elif exec 3</dev/tty 2>/dev/null; then
    HAVE_TTY=true
else
    exec 3</dev/null
fi

echo ""
print_box_top
print_box_line "${C_BOLD}Proxmox Auto-Update — Installer${C_NC}" "Proxmox Auto-Update - Installer"
print_box_bottom
# Say which version this is going to install, before it installs it. The
# installer previously never mentioned one, so there was no way to tell what
# you were getting or to check afterwards that you got it.
echo -e "  ${C_DIM}Installing ${PAU_RESOLVED_REF} from github.com/${REPO_SLUG}${C_NC}"
if [ "${UNATTENDED}" = true ]; then
    echo ""
    print_action "Unattended mode — reusing the existing configuration"
fi

# 0. Root check
if [ "$(id -u)" -ne 0 ]; then
    echo ""
    print_fail "This installer must be run as ${C_BOLD}root${C_NC}."
    exit 1
fi

# 0a. Is this actually a Proxmox VE host?
#
# There was no check at all, so installing on plain Debian, on a Proxmox Backup
# Server, or — a common mistake — inside a container on the host rather than on
# the host itself, printed every success tick and finished with "Deployment
# successful". The scheduled run then found no guests and reported a clean sweep
# of nothing, forever.
if [ "${PAU_SKIP_PVE_CHECK:-false}" != "true" ]; then
    if ! command -v pveversion >/dev/null 2>&1 || [ ! -d /etc/pve ]; then
        echo ""
        print_fail "This does not look like a Proxmox VE host."
        print_fail "Both ${C_BOLD}pveversion${C_NC} and ${C_BOLD}/etc/pve${C_NC} are required."
        echo ""
        echo -e "  Run this on the Proxmox host itself — not inside a VM or container,"
        echo -e "  and not on a Proxmox Backup Server."
        echo -e "  ${C_DIM}Set PAU_SKIP_PVE_CHECK=true to override.${C_NC}"
        echo ""
        exit 1
    fi
    print_ok "Proxmox VE detected: ${C_DIM}$(pveversion 2>/dev/null | head -1)${C_NC}"
fi

# 0b. Refuse to install from a world-writable working directory.
#
# fetch_asset and the update-script step both prefer a local file over the
# download, so `cd /tmp; curl … | bash` would copy an attacker-planted
# ./update-everything.sh into /usr/local/bin, chmod it +x, install it into
# root's crontab and run it. Only trust local files when the directory is ours.
LOCAL_SOURCE_OK=true
_CWD_OWNER="$(stat -c '%u' . 2>/dev/null || echo 65534)"
_CWD_MODE="$(stat -c '%a' . 2>/dev/null || echo 777)"
# Last octal digit carries the "other" bits; the write bit is 2, so 2/3/6/7 all
# mean any user can drop a file here.
case "${_CWD_MODE}" in
    *[2367]) LOCAL_SOURCE_OK=false ;;
esac
[ "${_CWD_OWNER}" != "0" ] && LOCAL_SOURCE_OK=false
if [ "${LOCAL_SOURCE_OK}" != true ]; then
    print_action "Working directory is world-writable or not root-owned"
    print_action "Ignoring local files and fetching everything from GitHub"
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
PREV_SCHEDULES=""
PREV_REBOOT_TIME=""
PREV_START_LXC=""
PREV_START_LINUX_VMS=""
PREV_LINUX_TIMEOUT=""
PREV_APT_LOCK=""
PREV_SNAPSHOT=""
PREV_SNAPSHOT_KEEP=""
PREV_WEBUI=""
PREV_WEBUI_PORT=""
PREV_DRY_RUN=""
PREV_LOG_DIR=""
PREV_TRANSPORT=""
PREV_TEAMS=""
PREV_NTFY_URL=""
PREV_NTFY_TOKEN=""
PREV_GOTIFY_URL=""
PREV_GOTIFY_TOKEN=""
PREV_TG_TOKEN=""
PREV_TG_CHAT=""
PREV_SMTP_HOST=""
PREV_SMTP_PORT=""
PREV_SMTP_USER=""
PREV_SMTP_PASSWORD=""
PREV_SMTP_SECURITY=""
PREV_NOTIFY_METHODS=""
PREV_FAIL_ONLY=""
PREV_DISCORD=""
PREV_SLACK=""
PREV_GENERIC=""
PREV_KEEP_LOGS=""
PREV_LOG_RETENTION=""
PREV_BOT_TOKEN=""
PREV_USER_ID=""
PREV_CONFIRM=""

# On a fresh box the built-in defaults are not "current" — nothing is current
# yet — and labelling them that way made the installer look like it had found a
# configuration it had not.
MARK_CURRENT="(default)"
WORD_CURRENT="default"
if [ -f "${CONFIG_FILE}" ]; then
    MARK_CURRENT="(current)"
    WORD_CURRENT="current"
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
    PREV_SCHEDULES="${UPDATE_SCHEDULES:-}"
    PREV_REBOOT_TIME="${REBOOT_TIME:-}"
    PREV_LINUX_TIMEOUT="${LINUX_UPDATE_TIMEOUT:-}"
    PREV_APT_LOCK="${APT_LOCK_TIMEOUT:-}"
    PREV_SNAPSHOT="${SNAPSHOT_BEFORE_UPDATE:-}"
    PREV_SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-}"
    PREV_WEBUI="${ENABLE_WEB_UI:-}"
    PREV_WEBUI_PORT="${WEB_UI_PORT:-}"
    PREV_NOTIFY_METHODS="${NOTIFY_METHODS:-}"
    PREV_FAIL_ONLY="${NOTIFY_ON_FAILURE_ONLY:-}"
    PREV_DISCORD="${DISCORD_WEBHOOK_URL:-}"
    PREV_SLACK="${SLACK_WEBHOOK_URL:-}"
    PREV_GENERIC="${GENERIC_WEBHOOK_URL:-}"
    PREV_KEEP_LOGS="${KEEP_LOGS:-}"
    PREV_LOG_RETENTION="${LOG_RETENTION_DAYS:-}"
    PREV_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
    PREV_USER_ID="${DISCORD_USER_ID:-}"
    PREV_CONFIRM="${CONFIRM_UPDATES:-}"
    # These two were not carried across, and the config below emits literals for
    # them. So a re-install — including the unattended one the panel's "Install
    # update" button runs — silently flipped a node that was deliberately in
    # dry-run mode back to live dist-upgrades with reboot scheduling, and threw
    # away a custom log directory, after which cron redirected into the old
    # directory while the script logged to the default one.
    PREV_DRY_RUN="${DRY_RUN:-}"
    PREV_LOG_DIR="${LOG_DIR:-}"
    PREV_TRANSPORT="${EMAIL_TRANSPORT:-}"
    PREV_TEAMS="${TEAMS_WEBHOOK_URL:-}"
    PREV_NTFY_URL="${NTFY_URL:-}"
    PREV_NTFY_TOKEN="${NTFY_TOKEN:-}"
    PREV_GOTIFY_URL="${GOTIFY_URL:-}"
    PREV_GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"
    PREV_TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    PREV_TG_CHAT="${TELEGRAM_CHAT_ID:-}"
    PREV_SMTP_HOST="${SMTP_HOST:-}"
    PREV_SMTP_PORT="${SMTP_PORT:-}"
    PREV_SMTP_USER="${SMTP_USER:-}"
    PREV_SMTP_PASSWORD="${SMTP_PASSWORD:-}"
    PREV_SMTP_SECURITY="${SMTP_SECURITY:-}"

    # Installs predating NOTIFY_METHODS had Mailgun and nothing else.
    if [ -z "${PREV_NOTIFY_METHODS}" ] && [ -n "${MAILGUN_API_KEY:-}" ]; then
        PREV_NOTIFY_METHODS="email"
    fi
fi

# 1a. Typical or Custom
#
# Asked before anything else is decided, because it decides everything else.
# Most people want a working scheduled updater and a button in the Proxmox UI,
# and answering fifteen questions to get it is a way to lose them at question
# four. Typical asks nothing and prints exactly what it is choosing, so it is
# not a black box — every value below is visible before it is written.
#
# Notifications stay off in Typical. There is no safe guess at somebody's mail
# server, and a channel configured wrongly is worse than no channel: it reports
# nothing and looks configured.
INSTALL_MODE="typical"

apply_typical_profile() {
    NOTIFY_METHODS=""
    NOTIFY_ON_FAILURE_ONLY="false"
    EXCLUDE_IDS=""
    WINDOWS_UPDATE_TIMEOUT="1200"
    LINUX_UPDATE_TIMEOUT="1800"
    APT_LOCK_TIMEOUT="600"
    START_STOPPED_WINDOWS="false"
    START_STOPPED_LXC="true"
    START_STOPPED_LINUX_VMS="true"
    SNAPSHOT_BEFORE_UPDATE="false"
    SNAPSHOT_KEEP="3"
    ENABLE_WEB_UI="true"
    WEB_UI_PORT="8007"
    KEEP_LOGS="true"
    LOG_RETENTION_DAYS="90"
    UPDATE_SCHEDULES="0 23 * * 5|yes|Weekly updates"
    UPDATE_SCHEDULE_CRON="0 23 * * 5"
    REBOOT_TIME="02:00"
    CONFIRM_UPDATES="${PREV_CONFIRM:-true}"
}

# Keep mode: every value comes from the existing config, with the same fallbacks
# the prompts would have offered.
#
# This is not optional bookkeeping. Keep mode skips the prompt blocks, and those
# blocks are where NOTIFY_METHODS and friends were being set — so without this
# the installer sourced the config, relied on that source having incidentally
# bound the variables, and died with "NOTIFY_METHODS: unbound variable" the
# moment the config was empty or predated a key. It had already truncated the
# config file by then, because the heredoc opens before it fails.
apply_keep_profile() {
    NOTIFY_METHODS="${PREV_NOTIFY_METHODS}"
    NOTIFY_ON_FAILURE_ONLY="${PREV_FAIL_ONLY:-false}"
    EXCLUDE_IDS="${PREV_EXCLUDE}"
    WINDOWS_UPDATE_TIMEOUT="${PREV_WIN_TIMEOUT:-1200}"
    LINUX_UPDATE_TIMEOUT="${PREV_LINUX_TIMEOUT:-1800}"
    APT_LOCK_TIMEOUT="${PREV_APT_LOCK:-600}"
    START_STOPPED_WINDOWS="${PREV_START_WIN:-false}"
    START_STOPPED_LXC="${PREV_START_LXC:-true}"
    START_STOPPED_LINUX_VMS="${PREV_START_LINUX_VMS:-true}"
    SNAPSHOT_BEFORE_UPDATE="${PREV_SNAPSHOT:-false}"
    SNAPSHOT_KEEP="${PREV_SNAPSHOT_KEEP:-3}"
    ENABLE_WEB_UI="${PREV_WEBUI:-false}"
    WEB_UI_PORT="${PREV_WEBUI_PORT:-8007}"
    KEEP_LOGS="${PREV_KEEP_LOGS:-true}"
    LOG_RETENTION_DAYS="${PREV_LOG_RETENTION:-90}"
    UPDATE_SCHEDULE_CRON="${PREV_CRON:-0 23 * * 5}"
    REBOOT_TIME="${PREV_REBOOT_TIME:-00:00}"
    CONFIRM_UPDATES="${PREV_CONFIRM:-true}"
    # A config from before 1.9.0 has no schedule list, only the single
    # expression. Synthesise the list rather than writing an empty one, or the
    # crontab this run rebuilds would lose the schedule entirely.
    if [ -n "${PREV_SCHEDULES}" ]; then
        UPDATE_SCHEDULES="${PREV_SCHEDULES}"
    else
        UPDATE_SCHEDULES="${UPDATE_SCHEDULE_CRON}|yes|Updates"
    fi
}

print_typical_profile() {
    echo -e "  ${C_CYAN}Schedule${C_NC}       Fridays at 23:00, and reboot at 02:00 if a kernel"
    echo -e "                 was installed. Nothing reboots otherwise."
    echo -e "  ${C_CYAN}Guests${C_NC}         Stopped containers and Linux VMs are started, updated"
    echo -e "                 and put back as they were. Windows VMs are left alone —"
    echo -e "                 Windows Update can run for well over half an hour."
    echo -e "  ${C_CYAN}Web panel${C_NC}      Installed on port ${C_BOLD}8007${C_NC}, with the Update Everything"
    echo -e "                 button added to the Proxmox toolbar."
    echo -e "  ${C_CYAN}Notifications${C_NC}  ${C_BOLD}Off.${C_NC} Updates run quietly. Add email, Discord, Slack,"
    echo -e "                 Teams, ntfy, Gotify, Telegram or a webhook later from"
    echo -e "                 the panel — nothing here guesses at your mail server."
    echo -e "  ${C_CYAN}Snapshots${C_NC}      Off. They need ZFS, LVM-thin or qcow2 and real disk"
    echo -e "                 space, which is not a safe assumption to make for you."
    echo -e "  ${C_CYAN}Logs${C_NC}           Kept in /var/log/proxmox-autoupdate/ for 90 days."
    echo -e "  ${C_CYAN}Exclusions${C_NC}     None. Every guest is updated."
    echo ""
    echo -e "  ${C_DIM}All of it is editable afterwards, in the panel or in${C_NC}"
    echo -e "  ${C_DIM}/etc/proxmox-autoupdate.conf. Re-running this installer offers to${C_NC}"
    echo -e "  ${C_DIM}keep whatever you end up with.${C_NC}"
}

if [ "${UNATTENDED}" = true ]; then
    # The panel's self-update path. Reuse everything; ask nothing.
    INSTALL_MODE="keep"
else
    echo ""
    print_box_top
    print_box_line "${C_BOLD}How would you like to install?${C_NC}" "How would you like to install?"
    print_box_bottom
    echo ""
    if [ -f "${CONFIG_FILE}" ]; then
        # A configured host must not be reset by accident. Keeping what is there
        # is the default, because "Typical" on a machine somebody has already
        # set up means silently discarding their settings.
        echo -e "    ${C_CYAN}1)${C_NC} ${C_BOLD}Keep my current settings${C_NC}  ${C_DIM}— just update the files${C_NC}"
        echo -e "    ${C_CYAN}2)${C_NC} ${C_BOLD}Typical${C_NC}  ${C_DIM}— reset to the recommended defaults${C_NC}"
        echo -e "    ${C_CYAN}3)${C_NC} ${C_BOLD}Custom${C_NC}   ${C_DIM}— go through every question${C_NC}"
        echo ""
        ask INPUT_MODE "  Select 1-3 [Enter for 1]: "
        case "${INPUT_MODE}" in
            2) INSTALL_MODE="typical" ;;
            3) INSTALL_MODE="custom" ;;
            *) INSTALL_MODE="keep" ;;
        esac
    else
        echo -e "    ${C_CYAN}1)${C_NC} ${C_BOLD}Typical${C_NC}  ${C_DIM}— recommended defaults, nothing to answer${C_NC}"
        echo -e "    ${C_CYAN}2)${C_NC} ${C_BOLD}Custom${C_NC}   ${C_DIM}— choose everything yourself${C_NC}"
        echo ""
        ask INPUT_MODE "  Select 1 or 2 [Enter for 1]: "
        case "${INPUT_MODE}" in
            2) INSTALL_MODE="custom" ;;
            *) INSTALL_MODE="typical" ;;
        esac
    fi
fi

case "${INSTALL_MODE}" in
    typical)
        apply_typical_profile
        echo ""
        print_ok "Typical install. Here is exactly what that means:"
        echo ""
        print_typical_profile
        ;;
    keep)
        apply_keep_profile
        print_ok "Keeping the existing configuration ${C_DIM}(${CONFIG_FILE})${C_NC}"
        print_skip "Nothing will be asked; the files are refreshed and the schedule re-applied."
        ;;
    *)
        print_ok "Custom install — every setting is asked."
        ;;
esac

# True only when the installer should be putting questions to a human. Every
# prompt block below is gated on this, so Typical and the panel's unattended
# self-update take exactly the same path through the rest of the script.
asking() { [ "${INSTALL_MODE}" = "custom" ]; }

# 1b. Dependencies
#   jq      — every guest-agent reply is parsed as JSON; regex-scraping that
#             output fails silently in ways that look like timeouts.
#   python3 — builds webhook payloads and merges run history, and runs the web
#             control panel.
echo ""
step "Checking dependencies"
for DEP in jq python3; do
    if command -v "${DEP}" >/dev/null 2>&1; then
        print_ok "${DEP} present"
        continue
    fi
    print_action "Installing ${DEP}..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -qy "${DEP}" >/dev/null 2>&1; then
        print_ok "${DEP} installed"
    else
        print_fail "Could not install ${DEP}."
        print_fail "Run 'apt-get update && apt-get install -y jq python3', then re-run this installer."
        exit 1
    fi
done

# Honour an existing custom log directory for the cron redirect and mkdir below,
# so the two never end up pointing at different places.
LOG_DIR="${PREV_LOG_DIR:-${LOG_DIR}}"

# Everything the config file needs, seeded from whatever is already installed.
#
# These used to sit inside the Notifications prompts. Typical and unattended
# installs skip those prompts, and under `set -u` an unset key here is not a
# missing default, it is an immediate abort partway through writing the config.
DISCORD_BOT_TOKEN="${PREV_BOT_TOKEN}"
DISCORD_USER_ID="${PREV_USER_ID}"
CONFIRM_UPDATES="${PREV_CONFIRM:-true}"
MAILGUN_API_KEY="${PREV_KEY}"
MAILGUN_DOMAIN="${PREV_DOMAIN}"
MAILGUN_REGION="${PREV_REGION:-EU}"
EMAIL_TRANSPORT="${PREV_TRANSPORT}"
SMTP_HOST="${PREV_SMTP_HOST}"
SMTP_PORT="${PREV_SMTP_PORT:-587}"
SMTP_USER="${PREV_SMTP_USER}"
SMTP_PASSWORD="${PREV_SMTP_PASSWORD}"
# Every other key carries the previous value forward; this one did not, so a
# re-install — including the panel's unattended self-update — silently rewrote
# an SSL/465 or unauthenticated-relay setup back to STARTTLS, and mail stopped
# going out with nothing on screen to say so.
SMTP_SECURITY="${PREV_SMTP_SECURITY:-starttls}"
TEAMS_WEBHOOK_URL="${PREV_TEAMS}"
NTFY_URL="${PREV_NTFY_URL}"
NTFY_TOKEN="${PREV_NTFY_TOKEN}"
GOTIFY_URL="${PREV_GOTIFY_URL}"
GOTIFY_TOKEN="${PREV_GOTIFY_TOKEN}"
TELEGRAM_BOT_TOKEN="${PREV_TG_TOKEN}"
TELEGRAM_CHAT_ID="${PREV_TG_CHAT}"
SENDER_EMAIL="${PREV_SENDER}"
RECIPIENT_EMAIL="${PREV_RECIPIENT}"
DISCORD_WEBHOOK_URL="${PREV_DISCORD}"
SLACK_WEBHOOK_URL="${PREV_SLACK}"
GENERIC_WEBHOOK_URL="${PREV_GENERIC}"

echo ""
step "Notifications"
if asking; then
    echo ""
    echo -e "  ${C_DIM}Optional. Updates run on schedule whether or not a channel is set${C_NC}"
    echo -e "  ${C_DIM}up — without one they simply run quietly. You can add or change${C_NC}"
    echo -e "  ${C_DIM}channels later from the web panel or the config file.${C_NC}"
    echo ""

    DEFAULT_METHODS="${PREV_NOTIFY_METHODS:-}"
    if [ -n "${DEFAULT_METHODS}" ]; then
        echo -e "  ${C_DIM}Currently enabled: ${DEFAULT_METHODS}${C_NC}"
    fi
    echo -e "  ${C_CYAN}1)${C_NC} Skip for now  ${C_DIM}(updates still run; add a channel later)${C_NC}"
    echo -e "  ${C_CYAN}2)${C_NC} Email  ${C_DIM}(any SMTP server, or the Mailgun API)${C_NC}"
    echo -e "  ${C_CYAN}3)${C_NC} Discord  ${C_DIM}(webhook, or a bot DM)${C_NC}"
    echo -e "  ${C_CYAN}4)${C_NC} Slack  ${C_DIM}(incoming webhook)${C_NC}"
    echo -e "  ${C_CYAN}5)${C_NC} Microsoft Teams  ${C_DIM}(separate — Teams cannot read Slack's format)${C_NC}"
    echo -e "  ${C_CYAN}6)${C_NC} ntfy  ${C_DIM}(self-hosted or ntfy.sh)${C_NC}"
    echo -e "  ${C_CYAN}7)${C_NC} Gotify"
    echo -e "  ${C_CYAN}8)${C_NC} Telegram  ${C_DIM}(bot)${C_NC}"
    echo -e "  ${C_CYAN}9)${C_NC} Generic webhook  ${C_DIM}(JSON POST)${C_NC}"
    echo ""
    echo -e "  ${C_DIM}Enter one or more numbers, e.g. \"3\" or \"2,3\".${C_NC}"
    # "[Enter to keep current]" was meaningless on a fresh install, where there is
    # no current — it read as though pressing Enter would keep something.
    if [ -n "${DEFAULT_METHODS}" ]; then
        ask INPUT_METHODS "  Select [Enter to keep ${DEFAULT_METHODS}]: "
    else
        ask INPUT_METHODS "  Select [Enter for 1, skip]: "
    fi


    if [ -z "${INPUT_METHODS}" ]; then
        NOTIFY_METHODS="${DEFAULT_METHODS}"
        if [ -z "${NOTIFY_METHODS}" ]; then
            print_ok "Notifications: none ${C_DIM}(updates will run silently)${C_NC}"
        else
            print_ok "Notifications unchanged: ${NOTIFY_METHODS}"
        fi
    else
        NOTIFY_METHODS=""
        for CHOICE in $(echo "${INPUT_METHODS}" | tr ',' ' '); do
            case "${CHOICE}" in
                1) NOTIFY_METHODS=""; break ;;
                2) NOTIFY_METHODS="${NOTIFY_METHODS},email" ;;
                3) NOTIFY_METHODS="${NOTIFY_METHODS},discord" ;;
                4) NOTIFY_METHODS="${NOTIFY_METHODS},slack" ;;
                5) NOTIFY_METHODS="${NOTIFY_METHODS},teams" ;;
                6) NOTIFY_METHODS="${NOTIFY_METHODS},ntfy" ;;
                7) NOTIFY_METHODS="${NOTIFY_METHODS},gotify" ;;
                8) NOTIFY_METHODS="${NOTIFY_METHODS},telegram" ;;
                9) NOTIFY_METHODS="${NOTIFY_METHODS},webhook" ;;
                *) print_fail "Ignoring unrecognised choice '${CHOICE}'" ;;
            esac
        done
        NOTIFY_METHODS="${NOTIFY_METHODS#,}"

        # --- Per-channel details, asked only for the channels chosen ---
        if echo ",${NOTIFY_METHODS}," | grep -q ",email,"; then
            echo ""
            echo -e "  ${C_BOLD}Email${C_NC}"
            # SMTP was added to the updater and the panel in 1.2.0 but never to the
            # installer, which still assumed email meant Mailgun. A fresh install
            # was therefore forced through Mailgun prompts it could not skip, even
            # for someone who only wanted to use their own mail server.
            echo -e "  ${C_DIM}1) SMTP server — any mail server, relay or app password${C_NC}"
            echo -e "  ${C_DIM}2) Mailgun API${C_NC}"
            DEFAULT_TRANSPORT="1"
            [ "${PREV_TRANSPORT}" = "mailgun" ] && DEFAULT_TRANSPORT="2"
            [ -z "${PREV_TRANSPORT}" ] && [ -n "${PREV_KEY}" ] && DEFAULT_TRANSPORT="2"
            ask I "  Send via [${DEFAULT_TRANSPORT}]: "
            case "${I:-${DEFAULT_TRANSPORT}}" in
                2) EMAIL_TRANSPORT="mailgun" ;;
                *) EMAIL_TRANSPORT="smtp" ;;
            esac

            if [ "${EMAIL_TRANSPORT}" = "mailgun" ]; then
                ask_required MAILGUN_API_KEY "API key" "${PREV_KEY}"
                ask_required MAILGUN_DOMAIN "Domain (e.g. mg.example.com)" "${PREV_DOMAIN}"
                if [ "${MAILGUN_REGION}" = "US" ]; then
                    ask I "  Region — 1 for EU, 2 for US [Enter for 2]: "
                else
                    ask I "  Region — 1 for EU, 2 for US [Enter for 1]: "
                fi
                case "${I}" in 1) MAILGUN_REGION="EU" ;; 2) MAILGUN_REGION="US" ;; esac
            else
                ask_required SMTP_HOST "SMTP host (e.g. smtp.example.com)" "${PREV_SMTP_HOST}"
                ask I "  Port [${PREV_SMTP_PORT:-587}]: "
                SMTP_PORT="${I:-${PREV_SMTP_PORT:-587}}"
                echo -e "  ${C_DIM}1) STARTTLS (587)   2) SSL/TLS (465)   3) none — local relay${C_NC}"
                case "${SMTP_SECURITY}" in ssl) SEC_DEFAULT=2 ;; none) SEC_DEFAULT=3 ;; *) SEC_DEFAULT=1 ;; esac
                ask I "  Encryption [Enter for ${SEC_DEFAULT}]: "
                case "${I:-${SEC_DEFAULT}}" in
                    2) SMTP_SECURITY="ssl" ;;
                    3) SMTP_SECURITY="none" ;;
                    *) SMTP_SECURITY="starttls" ;;
                esac
                if [ -n "${PREV_SMTP_USER}" ]; then
                    ask I "  Username [Enter keeps ${PREV_SMTP_USER}]: "
                else
                    ask I "  Username [Enter for none — unauthenticated relay]: "
                fi
                SMTP_USER="${I:-${PREV_SMTP_USER}}"
                if [ -n "${SMTP_USER}" ]; then
                    if [ -n "${PREV_SMTP_PASSWORD}" ]; then
                        ask_secret I "  Password [Enter to keep the existing one]: "
                    else
                        ask_secret I "  Password (not echoed): "
                    fi
                    SMTP_PASSWORD="${I:-${PREV_SMTP_PASSWORD}}"
                fi
            fi

            ask_required SENDER_EMAIL "From address" "${PREV_SENDER}"
            ask_required RECIPIENT_EMAIL "To address" "${PREV_RECIPIENT}"
            if [ "${EMAIL_TRANSPORT}" = "mailgun" ]; then
                print_ok "Email via Mailgun (${MAILGUN_REGION} → ${RECIPIENT_EMAIL})"
            else
                print_ok "Email via SMTP (${SMTP_HOST}:${SMTP_PORT} → ${RECIPIENT_EMAIL})"
            fi
        fi

        if echo ",${NOTIFY_METHODS}," | grep -q ",discord,"; then
            echo ""
            echo -e "  ${C_BOLD}Discord${C_NC}"
            echo -e "    ${C_CYAN}1)${C_NC} Channel webhook  ${C_DIM}(Server Settings → Integrations → Webhooks)${C_NC}"
            echo -e "    ${C_CYAN}2)${C_NC} Direct message   ${C_DIM}(bot token + your user ID)${C_NC}"
            ask I "  Select 1 or 2 [1]: "
            if [ "${I}" = "2" ]; then
                echo -e "  ${C_DIM}The bot must share a server with you for Discord to allow the DM.${C_NC}"
                echo -e "  ${C_DIM}It is never run as a process — the token is only used to POST.${C_NC}"
                ask_secret I "  Bot token (not echoed): "
                DISCORD_BOT_TOKEN="${I:-${PREV_BOT_TOKEN}}"
                ask I "  Your Discord user ID (numeric): "
                DISCORD_USER_ID="${I:-${PREV_USER_ID}}"
                ask I "  Fallback webhook URL (optional): "
                DISCORD_WEBHOOK_URL="${I:-${PREV_DISCORD}}"
                if [ -n "${DISCORD_BOT_TOKEN}" ] && [ -n "${DISCORD_USER_ID}" ]; then
                    print_ok "Discord DM configured"
                else
                    print_fail "Both a bot token and a user ID are needed — dropping Discord."
                    NOTIFY_METHODS=$(echo "${NOTIFY_METHODS}" | sed 's/discord//; s/,,/,/g; s/^,//; s/,$//')
                fi
            else
                ask I "  Webhook URL: "
                DISCORD_WEBHOOK_URL="${I:-${PREV_DISCORD}}"
                if [ -n "${DISCORD_WEBHOOK_URL}" ]; then
                    print_ok "Discord configured"
                else
                    print_fail "No URL given — dropping Discord."
                    NOTIFY_METHODS=$(echo "${NOTIFY_METHODS}" | sed 's/discord//; s/,,/,/g; s/^,//; s/,$//')
                fi
            fi
        fi

        if echo ",${NOTIFY_METHODS}," | grep -q ",slack,"; then
            echo ""
            echo -e "  ${C_BOLD}Slack${C_NC}"
            ask I "  Webhook URL: "
            SLACK_WEBHOOK_URL="${I:-${PREV_SLACK}}"
            if [ -n "${SLACK_WEBHOOK_URL}" ]; then
                print_ok "Slack configured"
            else
                print_fail "No URL given — dropping Slack."
                NOTIFY_METHODS=$(echo "${NOTIFY_METHODS}" | sed 's/slack//; s/,,/,/g; s/^,//; s/,$//')
            fi
        fi

        if echo ",${NOTIFY_METHODS}," | grep -q ",teams,"; then
            echo ""
            echo -e "  ${C_BOLD}Microsoft Teams${C_NC}"
            echo -e "  ${C_DIM}Works with a Power Automate \"when a Teams webhook request is${C_NC}"
            echo -e "  ${C_DIM}received\" trigger, or a legacy Office 365 connector.${C_NC}"
            ask I "  Webhook URL: "
            TEAMS_WEBHOOK_URL="${I:-${PREV_TEAMS}}"
            if [ -n "${TEAMS_WEBHOOK_URL}" ]; then
                print_ok "Teams configured"
            else
                print_fail "No URL given — dropping Teams."
                NOTIFY_METHODS=$(echo "${NOTIFY_METHODS}" | sed 's/teams//; s/,,/,/g; s/^,//; s/,$//')
            fi
        fi

        if echo ",${NOTIFY_METHODS}," | grep -q ",ntfy,"; then
            echo ""
            echo -e "  ${C_BOLD}ntfy${C_NC}"
            echo -e "  ${C_DIM}The topic is part of the URL, e.g. https://ntfy.sh/my-topic${C_NC}"
            ask I "  Topic URL: "
            NTFY_URL="${I:-${PREV_NTFY_URL}}"
            if [ -n "${NTFY_URL}" ]; then
                ask_secret I "  Access token [Enter for none]: "
                NTFY_TOKEN="${I:-${PREV_NTFY_TOKEN}}"
                print_ok "ntfy configured"
            else
                print_fail "No URL given — dropping ntfy."
                NOTIFY_METHODS=$(echo "${NOTIFY_METHODS}" | sed 's/ntfy//; s/,,/,/g; s/^,//; s/,$//')
            fi
        fi

        if echo ",${NOTIFY_METHODS}," | grep -q ",gotify,"; then
            echo ""
            echo -e "  ${C_BOLD}Gotify${C_NC}"
            ask I "  Server URL (e.g. https://gotify.example.com): "
            GOTIFY_URL="${I:-${PREV_GOTIFY_URL}}"
            ask_secret I "  Application token: "
            GOTIFY_TOKEN="${I:-${PREV_GOTIFY_TOKEN}}"
            if [ -n "${GOTIFY_URL}" ] && [ -n "${GOTIFY_TOKEN}" ]; then
                print_ok "Gotify configured"
            else
                print_fail "Both a URL and a token are needed — dropping Gotify."
                NOTIFY_METHODS=$(echo "${NOTIFY_METHODS}" | sed 's/gotify//; s/,,/,/g; s/^,//; s/,$//')
            fi
        fi

        if echo ",${NOTIFY_METHODS}," | grep -q ",telegram,"; then
            echo ""
            echo -e "  ${C_BOLD}Telegram${C_NC}"
            echo -e "  ${C_DIM}Create a bot with @BotFather, message it, then read your chat ID${C_NC}"
            echo -e "  ${C_DIM}from https://api.telegram.org/bot<token>/getUpdates${C_NC}"
            ask_secret I "  Bot token (not echoed): "
            TELEGRAM_BOT_TOKEN="${I:-${PREV_TG_TOKEN}}"
            ask I "  Chat ID: "
            TELEGRAM_CHAT_ID="${I:-${PREV_TG_CHAT}}"
            if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
                print_ok "Telegram configured"
            else
                print_fail "Both a token and a chat ID are needed — dropping Telegram."
                NOTIFY_METHODS=$(echo "${NOTIFY_METHODS}" | sed 's/telegram//; s/,,/,/g; s/^,//; s/,$//')
            fi
        fi

        if echo ",${NOTIFY_METHODS}," | grep -q ",webhook,"; then
            echo ""
            echo -e "  ${C_BOLD}Generic webhook${C_NC}"
            echo -e "  ${C_DIM}Receives a JSON POST — Home Assistant, n8n, your own endpoint.${C_NC}"
            echo -e "  ${C_DIM}ntfy and Gotify have their own options above; they need their own${C_NC}"
            echo -e "  ${C_DIM}request shapes, not this one.${C_NC}"
            ask I "  URL: "
            GENERIC_WEBHOOK_URL="${I:-${PREV_GENERIC}}"
            if [ -n "${GENERIC_WEBHOOK_URL}" ]; then
                print_ok "Generic webhook configured"
            else
                print_fail "No URL given — dropping the generic webhook."
                NOTIFY_METHODS=$(echo "${NOTIFY_METHODS}" | sed 's/webhook//; s/,,/,/g; s/^,//; s/,$//')
            fi
        fi

        if [ -z "${NOTIFY_METHODS}" ]; then
            print_ok "Notifications: none ${C_DIM}(updates will run silently)${C_NC}"
        fi
    fi

    # --- Notify only on failure? ---
    if [ -n "${NOTIFY_METHODS}" ]; then
        echo ""
        DEFAULT_FAIL_ONLY="${PREV_FAIL_ONLY:-false}"
        echo -e "  ${C_BOLD}Only notify when something fails?${C_NC}"
        echo -e "  ${C_DIM}A weekly \"nothing happened\" message trains you to ignore the channel.${C_NC}"
        if [ "${DEFAULT_FAIL_ONLY}" = "true" ]; then
            ask I "  1 = only on failure, 2 = every run [Enter for 1]: "
        else
            ask I "  1 = only on failure, 2 = every run [Enter for 2]: "
        fi
        case "${I}" in
            1) NOTIFY_ON_FAILURE_ONLY="true" ;;
            2) NOTIFY_ON_FAILURE_ONLY="false" ;;
            *) NOTIFY_ON_FAILURE_ONLY="${DEFAULT_FAIL_ONLY}" ;;
        esac
        print_ok "Notify on failure only: ${NOTIFY_ON_FAILURE_ONLY}"
    else
        NOTIFY_ON_FAILURE_ONLY="${PREV_FAIL_ONLY:-false}"
    fi

    # --- Advanced Settings ---
else
    echo ""
    if [ -n "${NOTIFY_METHODS}" ]; then
        print_ok "Notifications: ${NOTIFY_METHODS}"
    else
        print_ok "Notifications: none — updates run quietly"
        print_skip "Add a channel any time from the panel, or in ${CONFIG_FILE}"
    fi
fi

echo ""
step "Advanced settings"
if asking; then
    echo ""
    echo -e "  ${C_DIM}Every question here has a working default — press Enter to take it.${C_NC}"
    echo -e "  ${C_DIM}All of it can be changed later in the web panel or the config file.${C_NC}"
    echo ""

    # --- Exclude IDs ---
    echo -e "  ${C_BOLD}Guests to leave alone${C_NC}"
    echo -e "  ${C_DIM}VM and container IDs the updater should skip entirely — a database${C_NC}"
    echo -e "  ${C_DIM}that must not restart, an appliance you patch by hand. Comma-separated,${C_NC}"
    echo -e "  ${C_DIM}e.g. 100,201,305.${C_NC}"
    EXCLUDE_IDS=""
    if [ -n "${PREV_EXCLUDE}" ]; then
        ask INPUT_EXCLUDE "  Exclude VM/CT IDs [Enter keeps ${PREV_EXCLUDE}, 'none' clears]: "
    else
        ask INPUT_EXCLUDE "  Exclude VM/CT IDs [Enter for none]: "
    fi
    # `:-` treats an empty answer as "unset", so pressing Enter to clear the list
    # silently reinstated the previous one and there was no way to empty it from
    # the installer at all. `-` distinguishes "not answered" from "answered with
    # nothing", and the sentinel gives an explicit way to say none.
    if [ -z "${INPUT_EXCLUDE+set}" ]; then
        EXCLUDE_IDS="${PREV_EXCLUDE}"
    elif [ "${INPUT_EXCLUDE}" = "none" ] || [ "${INPUT_EXCLUDE}" = "-" ]; then
        EXCLUDE_IDS=""
    else
        EXCLUDE_IDS="${INPUT_EXCLUDE:-${PREV_EXCLUDE}}"
    fi
    if [ -n "${EXCLUDE_IDS}" ]; then
        print_ok "Excluding: ${EXCLUDE_IDS}"
    else
        print_ok "No exclusions"
    fi

    # --- Windows Update Timeout ---
    echo ""
    echo -e "  ${C_BOLD}Windows Update timeout${C_NC}"
    echo -e "  ${C_DIM}How long a Windows VM gets to finish before it is reported as timed${C_NC}"
    echo -e "  ${C_DIM}out. Cumulative updates on a machine that has been off for a while${C_NC}"
    echo -e "  ${C_DIM}routinely take longer than you would guess.${C_NC}"
    WINDOWS_UPDATE_TIMEOUT=""
    DEFAULT_WIN_TIMEOUT="${PREV_WIN_TIMEOUT:-1200}"
    ask INPUT_WIN_TIMEOUT "  Seconds [Enter for ${DEFAULT_WIN_TIMEOUT}]: "
    WINDOWS_UPDATE_TIMEOUT="${INPUT_WIN_TIMEOUT:-${DEFAULT_WIN_TIMEOUT}}"
    print_ok "Windows timeout: ${WINDOWS_UPDATE_TIMEOUT}s"

    # --- Start Stopped Windows VMs ---
    echo ""
    echo -e "  ${C_BOLD}Start stopped Windows VMs for updates?${C_NC}"
    echo -e "  ${C_DIM}(Windows Update can take 30+ minutes — not recommended for short maintenance windows)${C_NC}"
    DEFAULT_START_WIN="${PREV_START_WIN:-false}"
    if [ "${DEFAULT_START_WIN}" = "true" ]; then
        echo -e "    ${C_CYAN}1)${C_NC} Yes  ${C_DIM}${MARK_CURRENT}${C_NC}"
        echo -e "    ${C_CYAN}2)${C_NC} No"
    else
        echo -e "    ${C_CYAN}1)${C_NC} Yes"
        echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}${MARK_CURRENT}${C_NC}"
    fi
    ask INPUT_START_WIN "  Select 1 or 2 [Enter to keep the marked one]: "
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
        echo -e "    ${C_CYAN}1)${C_NC} Yes  ${C_DIM}${MARK_CURRENT}${C_NC}"
        echo -e "    ${C_CYAN}2)${C_NC} No"
    else
        echo -e "    ${C_CYAN}1)${C_NC} Yes"
        echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}${MARK_CURRENT}${C_NC}"
    fi
    ask INPUT_START_LXC "  Select 1 or 2 [Enter to keep the marked one]: "
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
        echo -e "    ${C_CYAN}1)${C_NC} Yes  ${C_DIM}${MARK_CURRENT}${C_NC}"
        echo -e "    ${C_CYAN}2)${C_NC} No"
    else
        echo -e "    ${C_CYAN}1)${C_NC} Yes"
        echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}${MARK_CURRENT}${C_NC}"
    fi
    ask INPUT_START_LINUX_VMS "  Select 1 or 2 [Enter to keep the marked one]: "
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
    ask INPUT_LINUX_TIMEOUT "  Linux update timeout in seconds [Enter for ${DEFAULT_LINUX_TIMEOUT}]: "
    LINUX_UPDATE_TIMEOUT="${INPUT_LINUX_TIMEOUT:-${DEFAULT_LINUX_TIMEOUT}}"
    print_ok "Linux timeout: ${LINUX_UPDATE_TIMEOUT}s"

    # --- APT Lock Timeout ---
    echo ""
    DEFAULT_APT_LOCK="${PREV_APT_LOCK:-600}"
    echo -e "  ${C_DIM}How long apt waits for the dpkg lock inside a guest. Distros with"
    echo -e "  unattended-upgrades enabled (Ubuntu by default) fail with exit code"
    echo -e "  100 if this is 0 and the two happen to overlap.${C_NC}"
    ask INPUT_APT_LOCK "  APT lock wait in seconds [Enter for ${DEFAULT_APT_LOCK}]: "
    APT_LOCK_TIMEOUT="${INPUT_APT_LOCK:-${DEFAULT_APT_LOCK}}"
    print_ok "APT lock wait: ${APT_LOCK_TIMEOUT}s"

    # --- Pre-update Snapshots ---
    echo ""
    echo -e "  ${C_BOLD}Take a snapshot of each guest before updating it?${C_NC}"
    echo -e "  ${C_DIM}(Needs a snapshot-capable storage backend: ZFS, LVM-thin, qcow2.${C_NC}"
    echo -e "  ${C_DIM} Uses disk space, but gives you a one-command rollback.)${C_NC}"
    DEFAULT_SNAPSHOT="${PREV_SNAPSHOT:-false}"
    if [ "${DEFAULT_SNAPSHOT}" = "true" ]; then
        echo -e "    ${C_CYAN}1)${C_NC} Yes  ${C_DIM}${MARK_CURRENT}${C_NC}"
        echo -e "    ${C_CYAN}2)${C_NC} No"
    else
        echo -e "    ${C_CYAN}1)${C_NC} Yes"
        echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}${MARK_CURRENT}${C_NC}"
    fi
    ask INPUT_SNAPSHOT "  Select 1 or 2 [Enter to keep the marked one]: "
    case "${INPUT_SNAPSHOT}" in
        1) SNAPSHOT_BEFORE_UPDATE="true" ;;
        2) SNAPSHOT_BEFORE_UPDATE="false" ;;
        *) SNAPSHOT_BEFORE_UPDATE="${DEFAULT_SNAPSHOT}" ;;
    esac
    print_ok "Pre-update snapshots: ${SNAPSHOT_BEFORE_UPDATE}"

    DEFAULT_SNAPSHOT_KEEP="${PREV_SNAPSHOT_KEEP:-3}"
    if [ "${SNAPSHOT_BEFORE_UPDATE}" = "true" ]; then
        ask INPUT_SNAPSHOT_KEEP "  Snapshots to keep per guest [Enter for ${DEFAULT_SNAPSHOT_KEEP}]: "
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
        echo -e "    ${C_CYAN}1)${C_NC} Yes  ${C_DIM}${MARK_CURRENT}${C_NC}"
        echo -e "    ${C_CYAN}2)${C_NC} No"
    else
        echo -e "    ${C_CYAN}1)${C_NC} Yes"
        echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}${MARK_CURRENT}${C_NC}"
    fi
    ask INPUT_WEBUI "  Select 1 or 2 [Enter to keep the marked one]: "
    case "${INPUT_WEBUI}" in
        1) ENABLE_WEB_UI="true" ;;
        2) ENABLE_WEB_UI="false" ;;
        *) ENABLE_WEB_UI="${DEFAULT_WEBUI}" ;;
    esac

    WEB_UI_PORT="${PREV_WEBUI_PORT:-8007}"
    if [ "${ENABLE_WEB_UI}" = "true" ]; then
        ask INPUT_WEBUI_PORT "  Port for the control panel [Enter for ${WEB_UI_PORT}]: "
        WEB_UI_PORT="${INPUT_WEBUI_PORT:-${WEB_UI_PORT}}"
        print_ok "Web control panel: enabled on port ${WEB_UI_PORT}"
    else
        print_ok "Web control panel: disabled"
    fi

    # --- Log retention ---
    echo ""
    DEFAULT_KEEP_LOGS="${PREV_KEEP_LOGS:-true}"
    echo -e "  ${C_BOLD}Keep update logs on disk?${C_NC}"
    echo -e "  ${C_DIM}\"No\" still lets you watch a run live, then deletes the log after.${C_NC}"
    if [ "${DEFAULT_KEEP_LOGS}" = "true" ]; then
        ask INPUT_KEEP_LOGS "  1 = keep, 2 = discard [Enter for 1]: "
    else
        ask INPUT_KEEP_LOGS "  1 = keep, 2 = discard [Enter for 2]: "
    fi
    case "${INPUT_KEEP_LOGS}" in
        1) KEEP_LOGS="true" ;;
        2) KEEP_LOGS="false" ;;
        *) KEEP_LOGS="${DEFAULT_KEEP_LOGS}" ;;
    esac

    DEFAULT_LOG_RETENTION="${PREV_LOG_RETENTION:-90}"
    if [ "${KEEP_LOGS}" = "true" ]; then
        ask I "  Delete logs older than N days (0 = never) [${DEFAULT_LOG_RETENTION}]: "
        LOG_RETENTION_DAYS="${I:-${DEFAULT_LOG_RETENTION}}"
        print_ok "Logs kept in ${LOG_DIR}/ for ${LOG_RETENTION_DAYS} day(s)"
    else
        LOG_RETENTION_DAYS="${DEFAULT_LOG_RETENTION}"
        print_ok "Logs discarded after each run"
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
else
    echo ""
    print_ok "Exclusions: ${EXCLUDE_IDS:-none}"
    print_ok "Stopped guests: LXC=${START_STOPPED_LXC}, Linux VMs=${START_STOPPED_LINUX_VMS}, Windows=${START_STOPPED_WINDOWS}"
    print_ok "Timeouts: Windows=${WINDOWS_UPDATE_TIMEOUT}s, Linux=${LINUX_UPDATE_TIMEOUT}s, apt lock=${APT_LOCK_TIMEOUT}s"
    print_ok "Pre-update snapshots: ${SNAPSHOT_BEFORE_UPDATE}"
    if [ "${ENABLE_WEB_UI}" = "true" ]; then
        print_ok "Web control panel: enabled on port ${WEB_UI_PORT}"
    else
        print_skip "Web control panel: not installed"
    fi
    if [ "${KEEP_LOGS}" = "true" ]; then
        print_ok "Logs kept in ${LOG_DIR}/ for ${LOG_RETENTION_DAYS} day(s)"
    else
        print_ok "Logs streamed live, then deleted"
    fi
fi

echo ""
step "Schedule and reboot timing"
if asking; then
    echo ""

    # --- Cron schedules ---
    #
    # More than one is allowed, and each says for itself whether it may reboot the
    # host. The setup this exists for: install updates every week without an
    # outage, and let one run a month be the one that takes the kernel.
    DEFAULT_CRON="${PREV_CRON:-0 23 * * 5}"
    UPDATE_SCHEDULES=""
    SCHED_COUNT=0

    echo -e "  ${C_DIM}Updates run from cron. You can have more than one schedule, and each${C_NC}"
    echo -e "  ${C_DIM}one decides for itself whether it is allowed to reboot the host — so${C_NC}"
    echo -e "  ${C_DIM}updates can land weekly while the reboot only happens monthly.${C_NC}"

    # Offer to keep what is already configured.
    #
    # Without this, pressing Enter through a re-install rebuilt the list from
    # scratch as a single always-reboots schedule, quietly throwing away a
    # weekly/monthly split — and the panel's unattended self-update runs this same
    # script, so it would have happened without anyone at the keyboard.
    KEEP_SCHEDULES=false
    if [ -n "${PREV_SCHEDULES}" ]; then
        echo ""
        echo -e "  ${C_BOLD}Currently configured:${C_NC}"
        parse_schedules "${PREV_SCHEDULES}" | while IFS="$(printf '	')" read -r c r l; do
            case "${r}" in
                no)   echo -e "    ${C_CYAN}•${C_NC} ${c}  ${C_DIM}${l:+${l} — }update, never reboots${C_NC}" ;;
                only) echo -e "    ${C_CYAN}•${C_NC} ${c}  ${C_DIM}${l:+${l} — }reboot window, no updates${C_NC}" ;;
                *)    echo -e "    ${C_CYAN}•${C_NC} ${c}  ${C_DIM}${l:+${l} — }update, may reboot${C_NC}" ;;
            esac
        done
        echo -e "    ${C_CYAN}1)${C_NC} Keep these"
        echo -e "    ${C_CYAN}2)${C_NC} Replace them"
        ask INPUT_SCHED_KEEP "  Select 1 or 2 [Enter for 1]: "
        if [ "${INPUT_SCHED_KEEP}" != "2" ]; then
            UPDATE_SCHEDULES="${PREV_SCHEDULES}"
            KEEP_SCHEDULES=true
            print_ok "Schedules unchanged"
        fi
    fi

    while [ "${KEEP_SCHEDULES}" = false ] && [ "${SCHED_COUNT}" -lt 5 ]; do
        SCHED_COUNT=$((SCHED_COUNT + 1))
        echo ""
        echo -e "  ${C_BOLD}Schedule ${SCHED_COUNT}${C_NC}"
        echo -e "    ${C_CYAN}1)${C_NC} Friday at 23:00  ${C_DIM}(0 23 * * 5)${C_NC}"
        echo -e "    ${C_CYAN}2)${C_NC} Friday at 22:00  ${C_DIM}(0 22 * * 5)${C_NC}"
        echo -e "    ${C_CYAN}3)${C_NC} Friday at 20:00  ${C_DIM}(0 20 * * 5)${C_NC}"
        echo -e "    ${C_CYAN}4)${C_NC} Sunday at 03:00  ${C_DIM}(0 3 * * 0)${C_NC}"
        # Monthly by day-of-month, never "first Sunday". cron ORs day-of-month with
        # day-of-week when both are restricted, so the obvious "0 3 1-7 * 0" fires
        # on the 1st-7th *and* on every Sunday — weekly, not monthly.
        echo -e "    ${C_CYAN}5)${C_NC} 1st of the month at 03:00  ${C_DIM}(0 3 1 * *)${C_NC}"
        echo -e "    ${C_CYAN}6)${C_NC} Custom cron expression"

        SCHED_LABEL=""
        if [ "${SCHED_COUNT}" -eq 1 ]; then
            ask INPUT_SCHED_CHOICE "  Select 1-6 [Enter for ${DEFAULT_CRON}]: "
        else
            ask INPUT_SCHED_CHOICE "  Select 1-6: "
        fi
        case "${INPUT_SCHED_CHOICE:-0}" in
            1) SCHED_CRON="0 23 * * 5"; SCHED_LABEL="Friday 23:00" ;;
            2) SCHED_CRON="0 22 * * 5"; SCHED_LABEL="Friday 22:00" ;;
            3) SCHED_CRON="0 20 * * 5"; SCHED_LABEL="Friday 20:00" ;;
            4) SCHED_CRON="0 3 * * 0";  SCHED_LABEL="Sunday 03:00" ;;
            5) SCHED_CRON="0 3 1 * *";  SCHED_LABEL="Monthly, 1st at 03:00" ;;
            6)
                ask CUSTOM_CRON "  Enter 5-field cron expression (e.g. 0 10 * * 5): "
                SCHED_CRON="${CUSTOM_CRON:-${DEFAULT_CRON}}"
                SCHED_LABEL="Custom"
                ;;
            *) SCHED_CRON="${DEFAULT_CRON}"; SCHED_LABEL="Updates" ;;
        esac

        # Reject a malformed expression here rather than letting crontab refuse the
        # whole file at the end, which used to abort the install after everything
        # else had already been written.
        if ! echo "${SCHED_CRON}" | grep -qE '^[0-9*,/@ -]{1,100}$'        || [ "$(echo "${SCHED_CRON}" | wc -w)" -ne 5 ]; then
            print_fail "Not a 5-field cron expression: '${SCHED_CRON}'"
            SCHED_CRON="${DEFAULT_CRON}"
            SCHED_LABEL="Updates"
            print_skip "Using ${SCHED_CRON}."
        fi

        echo ""
        echo -e "  ${C_DIM}What should this schedule do?${C_NC}"
        echo -e "    ${C_CYAN}1)${C_NC} Update, and reboot if it installs a new kernel"
        echo -e "    ${C_CYAN}2)${C_NC} Update, never reboot  ${C_DIM}— leave the reboot to another schedule${C_NC}"
        echo -e "    ${C_CYAN}3)${C_NC} Reboot only  ${C_DIM}— install nothing; reboot if one is already owed${C_NC}"
        ask INPUT_SCHED_REBOOT "  Select 1-3 [Enter for 1]: "
        case "${INPUT_SCHED_REBOOT}" in
            2) SCHED_REBOOT="no" ;;
            3) SCHED_REBOOT="only"; SCHED_LABEL="Reboot window" ;;
            *) SCHED_REBOOT="yes" ;;
        esac

        # ';' and '|' are the separators, so they cannot appear inside a label.
        SCHED_LABEL=$(echo "${SCHED_LABEL}" | tr -d ';|')
        UPDATE_SCHEDULES="${UPDATE_SCHEDULES}${UPDATE_SCHEDULES:+;}${SCHED_CRON}|${SCHED_REBOOT}|${SCHED_LABEL}"
        case "${SCHED_REBOOT}" in
            yes)  print_ok "Schedule ${SCHED_COUNT}: ${SCHED_CRON} ${C_DIM}(update, may reboot)${C_NC}" ;;
            no)   print_ok "Schedule ${SCHED_COUNT}: ${SCHED_CRON} ${C_DIM}(update, never reboots)${C_NC}" ;;
            only) print_ok "Schedule ${SCHED_COUNT}: ${SCHED_CRON} ${C_DIM}(reboot window — no updates)${C_NC}" ;;
        esac

        [ "${SCHED_COUNT}" -ge 5 ] && break
        echo ""
        echo -e "  ${C_DIM}Add another schedule? A second one is how you get weekly updates${C_NC}"
        echo -e "  ${C_DIM}with a monthly reboot.${C_NC}"
        echo -e "    ${C_CYAN}1)${C_NC} Yes"
        echo -e "    ${C_CYAN}2)${C_NC} No  ${C_DIM}(done)${C_NC}"
        ask INPUT_SCHED_MORE "  Select 1 or 2 [Enter for 2]: "
        [ "${INPUT_SCHED_MORE}" = "1" ] || break
    done

    # Kept in step with the first schedule so a config written here still reads
    # correctly to anything that only knows about the single-schedule key.
    UPDATE_SCHEDULE_CRON=$(parse_schedules "${UPDATE_SCHEDULES}" | head -1 | cut -f1)

    if [ "${SCHED_COUNT}" -gt 1 ] \
       && ! echo "${UPDATE_SCHEDULES}" | grep -qE '\|(yes|only)\|'; then
        print_fail "None of these schedules may reboot."
        print_fail "A kernel update will install and then wait indefinitely."
    fi

    # --- Reboot Time ---
    echo ""
    echo -e "  ${C_BOLD}Reboot time after a kernel update${C_NC}"
    echo -e "  ${C_DIM}A new kernel only takes effect after a reboot. If one is installed,${C_NC}"
    echo -e "  ${C_DIM}the host is scheduled to reboot at this time; otherwise nothing${C_NC}"
    echo -e "  ${C_DIM}happens. 24-hour HH:MM.${C_NC}"
    DEFAULT_REBOOT_TIME="${PREV_REBOOT_TIME:-00:00}"
    # Checked here because update-everything.sh treats anything that is not HH:MM
    # as FATAL and exits before touching a single guest. Typing the obvious "9:00"
    # used to earn a green tick and "Deployment successful", and then every
    # scheduled run aborted for good, into a cron log nobody reads. A single-digit
    # hour is the common slip, so it is padded rather than rejected.
    REBOOT_ATTEMPTS=0
    while :; do
        REBOOT_ATTEMPTS=$((REBOOT_ATTEMPTS + 1))
        ask INPUT_REBOOT_TIME "  Reboot at [Enter for ${DEFAULT_REBOOT_TIME}]: "
        REBOOT_TIME="${INPUT_REBOOT_TIME:-${DEFAULT_REBOOT_TIME}}"
        [[ "${REBOOT_TIME}" =~ ^[0-9]:[0-5][0-9]$ ]] && REBOOT_TIME="0${REBOOT_TIME}"
        [[ "${REBOOT_TIME}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
        print_fail "Not a 24-hour HH:MM time: '"'"'${REBOOT_TIME}'"'"'  (e.g. 00:00, 03:30, 23:15)"
        if [ "${HAVE_TTY}" != true ] || [ "${REBOOT_ATTEMPTS}" -ge 5 ]; then
            REBOOT_TIME="${DEFAULT_REBOOT_TIME}"
            print_skip "Using ${REBOOT_TIME}."
            break
        fi
    done
    print_ok "Scheduled reboot time: ${REBOOT_TIME}"

    # 3. Write credentials to a secure config file
    echo ""
else
    echo ""
    parse_schedules "${UPDATE_SCHEDULES}" | while IFS="$(printf '	')" read -r c r l; do
        case "${r}" in
            no)   print_ok "Schedule: ${c} ${C_DIM}${l:+${l} — }update, never reboots${C_NC}" ;;
            only) print_ok "Schedule: ${c} ${C_DIM}${l:+${l} — }reboot window, no updates${C_NC}" ;;
            *)    print_ok "Schedule: ${c} ${C_DIM}${l:+${l} — }update, may reboot${C_NC}" ;;
        esac
    done
    print_ok "Reboot time if a kernel is installed: ${REBOOT_TIME}"
fi

echo ""
step "Saving configuration"
print_action "Writing ${C_DIM}${CONFIG_FILE}${C_NC}"
# Create the file with restrictive permissions *before* writing credentials into
# it. Writing first and chmod'ing afterwards left the Mailgun key, Discord bot
# token and webhook URLs world-readable for the duration.
install -m 600 -o root -g root /dev/null "${CONFIG_FILE}"
cat > "${CONFIG_FILE}" <<CONF
# Proxmox Auto-Update — Configuration
# Generated by installer on $(date '+%d/%m/%Y %H:%M:%S')

# Notification channels: comma-separated list of email, discord, slack, teams,
# ntfy, gotify, telegram, webhook.
# Empty means no notifications — updates still run, they just run quietly.
NOTIFY_METHODS=$(sq "${NOTIFY_METHODS}")

# Stay silent on clean runs, so the channel only fires when something needs you
NOTIFY_ON_FAILURE_ONLY=$(sq "${NOTIFY_ON_FAILURE_ONLY}")

# How email leaves the box: "mailgun" or "smtp". Blank auto-detects from
# whichever set of credentials below is filled in.
EMAIL_TRANSPORT=$(sq "${EMAIL_TRANSPORT}")

# Mailgun API credentials (only used when EMAIL_TRANSPORT resolves to mailgun)
MAILGUN_API_KEY=$(sq "${MAILGUN_API_KEY}")
MAILGUN_DOMAIN=$(sq "${MAILGUN_DOMAIN}")
MAILGUN_REGION=$(sq "${MAILGUN_REGION}")

# SMTP relay (only used when EMAIL_TRANSPORT resolves to smtp). SMTP_SECURITY
# is starttls, ssl or none. Leave SMTP_USER blank for an unauthenticated relay.
SMTP_HOST=$(sq "${SMTP_HOST}")
SMTP_PORT=$(sq "${SMTP_PORT}")
SMTP_USER=$(sq "${SMTP_USER}")
SMTP_PASSWORD=$(sq "${SMTP_PASSWORD}")
SMTP_SECURITY=$(sq "${SMTP_SECURITY}")

# Email addresses
SENDER_EMAIL=$(sq "${SENDER_EMAIL}")
RECIPIENT_EMAIL=$(sq "${RECIPIENT_EMAIL}")

# Webhook URLs. These are credentials in their own right — anyone holding one
# can post to your channel — so this file is chmod 600.
DISCORD_WEBHOOK_URL=$(sq "${DISCORD_WEBHOOK_URL}")
SLACK_WEBHOOK_URL=$(sq "${SLACK_WEBHOOK_URL}")
TEAMS_WEBHOOK_URL=$(sq "${TEAMS_WEBHOOK_URL}")
GENERIC_WEBHOOK_URL=$(sq "${GENERIC_WEBHOOK_URL}")

# ntfy: the topic is part of the URL. The token is only needed on a protected
# topic; ntfy.sh public topics take none.
NTFY_URL=$(sq "${NTFY_URL}")
NTFY_TOKEN=$(sq "${NTFY_TOKEN}")
NTFY_PRIORITY=$(sq "${NTFY_PRIORITY:-default}")

# Gotify: server URL plus an application token from Apps → Create Application
GOTIFY_URL=$(sq "${GOTIFY_URL}")
GOTIFY_TOKEN=$(sq "${GOTIFY_TOKEN}")

# Telegram: a @BotFather token, and the chat ID to send to
TELEGRAM_BOT_TOKEN=$(sq "${TELEGRAM_BOT_TOKEN}")
TELEGRAM_CHAT_ID=$(sq "${TELEGRAM_CHAT_ID}")

# Discord direct message instead of a channel webhook. Set both and the report
# is DM'd to that user; the webhook above stays as a fallback. The bot is never
# run as a process — the token is only an Authorization header on two REST
# calls made at report time.
DISCORD_BOT_TOKEN=$(sq "${DISCORD_BOT_TOKEN}")
DISCORD_USER_ID=$(sq "${DISCORD_USER_ID}")

# Ask before starting an update ("true" or "false"). Deleting logs and
# uninstalling always confirm regardless.
CONFIRM_UPDATES=$(sq "${CONFIRM_UPDATES}")

# Log retention. KEEP_LOGS=false still streams a run live, then deletes it.
# LOG_RETENTION_DAYS=0 keeps logs forever.
KEEP_LOGS=$(sq "${KEEP_LOGS}")
LOG_RETENTION_DAYS=$(sq "${LOG_RETENTION_DAYS}")

# Comma-separated VM/CT IDs to exclude from updates (e.g., "100,201,305")
EXCLUDE_IDS=$(sq "${EXCLUDE_IDS}")

# Windows Update timeout in seconds (default: 1200 = 20 minutes)
WINDOWS_UPDATE_TIMEOUT=$(sq "${WINDOWS_UPDATE_TIMEOUT}")

# How long a Linux guest gets to finish its upgrade (default: 1800 = 30 minutes)
LINUX_UPDATE_TIMEOUT=$(sq "${LINUX_UPDATE_TIMEOUT}")

# How long apt waits for the dpkg lock inside a guest, in seconds.
# Prevents spurious "exit code 100" failures when unattended-upgrades is
# running at the same time (default: 600 = 10 minutes)
APT_LOCK_TIMEOUT=$(sq "${APT_LOCK_TIMEOUT}")

# Take a snapshot of each guest before updating it? ("true" or "false")
# Requires snapshot-capable storage (ZFS, LVM-thin, qcow2).
SNAPSHOT_BEFORE_UPDATE=$(sq "${SNAPSHOT_BEFORE_UPDATE}")

# How many auto-generated snapshots to keep per guest before pruning the oldest
SNAPSHOT_KEEP=$(sq "${SNAPSHOT_KEEP}")

# Report what would be updated without changing anything ("true" or "false").
# Leave this false for the scheduled run — use 'update-everything.sh --dry-run'
# when you want a one-off preview.
DRY_RUN=$(sq "${PREV_DRY_RUN:-false}")

# Where run logs are written.
LOG_DIR=$(sq "${PREV_LOG_DIR:-/var/log/proxmox-autoupdate}")

# Web control panel (toolbar button in the Proxmox UI)
ENABLE_WEB_UI=$(sq "${ENABLE_WEB_UI}")
WEB_UI_PORT=$(sq "${WEB_UI_PORT}")

# Start stopped Windows VMs to update them? ("true" or "false")
START_STOPPED_WINDOWS=$(sq "${START_STOPPED_WINDOWS}")

# Start stopped LXC Containers to update them? ("true" or "false")
START_STOPPED_LXC=$(sq "${START_STOPPED_LXC}")

# Start stopped Linux VMs to update them? ("true" or "false")
START_STOPPED_LINUX_VMS=$(sq "${START_STOPPED_LINUX_VMS}")

# Cron schedules. One per entry, ';'-separated, each of them
#   <5-field cron>|<yes|no, may this schedule reboot>|<label>
# so updates can land weekly while the host is only taken down monthly:
#   UPDATE_SCHEDULES='0 23 * * 5|no|Weekly;0 3 1 * *|yes|Monthly reboot'
# A schedule marked "no" runs update-everything.sh --no-reboot.
UPDATE_SCHEDULES=$(sq "${UPDATE_SCHEDULES}")

# The first schedule's expression, kept in step with the list above. Only read
# by older versions and as the fallback when UPDATE_SCHEDULES is empty.
UPDATE_SCHEDULE_CRON=$(sq "${UPDATE_SCHEDULE_CRON}")

# Scheduled reboot time if kernel is updated (default: "00:00")
REBOOT_TIME=$(sq "${REBOOT_TIME}")
CONF

chmod 600 "${CONFIG_FILE}"
chown root:root "${CONFIG_FILE}"
print_ok "Config saved ${C_DIM}(chmod 600, root-only)${C_NC}"

# 5b. Web control panel
# Fetch a support file either from the checkout we were run from, or from GitHub.
# Downloads go to a temp file first so a failed fetch can't leave a truncated
# executable in place of a working one.
fetch_asset() {
    local rel="$1" dest="$2"
    if [ "${LOCAL_SOURCE_OK}" = true ] && [ -f "${rel}" ]; then
        cp -f "${rel}" "${dest}"
        return 0
    fi
    local tmp
    tmp=$(mktemp) || return 1
    if curl -fsSL --retry 3 --retry-delay 2 -m 120 "${GITHUB_RAW_BASE}/${rel}" -o "${tmp}" \
       && [ -s "${tmp}" ]; then
        mv -f "${tmp}" "${dest}"
        return 0
    fi
    rm -f "${tmp}"
    print_fail "Could not download ${rel} from ${GITHUB_RAW_BASE}"
    return 1
}

# Does a downloaded file actually look like the thing we asked for?
#
# curl without --fail exits 0 on a 404, 403, 502 or a captive-portal
# interstitial and writes the response body to the destination, so the installer
# happily made an HTML error page executable, put it in root's crontab, and
# reported success. Every scheduled run then died on line 1 with a syntax error
# into a log nobody reads. --fail closes most of that; these checks close the
# rest, including a proxy that returns 200 with the wrong content.
verify_script() {
    local path="$1" needle="$2" what="$3"
    if [ ! -s "${path}" ]; then
        print_fail "${what} is empty"
        return 1
    fi
    if ! head -1 "${path}" | grep -q '^#!'; then
        print_fail "${what} is not a script (no #! line) — a proxy or portal probably replaced it"
        print_fail "  ${C_DIM}head -3 ${path}${C_NC}"
        return 1
    fi
    if ! grep -q "${needle}" "${path}"; then
        print_fail "${what} does not contain '${needle}' — wrong or truncated file"
        return 1
    fi
    if ! bash -n "${path}" 2>/dev/null; then
        print_fail "${what} is not valid shell — the download was corrupted"
        return 1
    fi
    return 0
}

# 4. Fetch the update script
step "Installing the update script"
STAGED_MAIN="$(mktemp)"
if [ "${LOCAL_SOURCE_OK}" = true ] && [ -f "update-everything.sh" ]; then
    cp -f update-everything.sh "${STAGED_MAIN}"
    MAIN_SOURCE="local file"
elif spin_start "Downloading from GitHub (${PAU_RESOLVED_REF})" \
     && curl -fsSL --retry 3 --retry-delay 2 -m 120 "${GITHUB_RAW_URL}" -o "${STAGED_MAIN}" \
     && spin_stop; then
    MAIN_SOURCE="GitHub (${PAU_RESOLVED_REF})"
    print_ok "Downloaded from GitHub ${C_DIM}(${PAU_RESOLVED_REF})${C_NC}"
else
    spin_stop
    rm -f "${STAGED_MAIN}"
    print_fail "Could not download update-everything.sh from ${GITHUB_RAW_URL}"
    print_fail "Check network access to raw.githubusercontent.com and try again."
    exit 1
fi

if ! verify_script "${STAGED_MAIN}" '^PAU_VERSION=' "The downloaded update script"; then
    rm -f "${STAGED_MAIN}"
    print_fail "Refusing to install it. Nothing has been changed."
    exit 1
fi

# Only now replace the live script, and do it atomically so a crash here cannot
# leave a half-written updater in root's crontab.
install -m 700 -o root -g root "${STAGED_MAIN}" "${TARGET_PATH}.new"
mv -f "${TARGET_PATH}.new" "${TARGET_PATH}"
rm -f "${STAGED_MAIN}"
print_ok "Installed from ${MAIN_SOURCE} ${C_DIM}(verified)${C_NC}"

# 4a. Changelog, so the panel can show it even without network access
mkdir -p /usr/local/share/proxmox-autoupdate
fetch_asset "CHANGELOG.md" "/usr/local/share/proxmox-autoupdate/CHANGELOG.md" || true

# 4b. Uninstaller, so removal never depends on having the repo to hand
if fetch_asset "uninstall.sh" "/usr/local/bin/pve-autoupdate-uninstall"; then
    chmod +x /usr/local/bin/pve-autoupdate-uninstall
    print_ok "Uninstaller: ${C_DIM}pve-autoupdate-uninstall${C_NC}"
fi

# 5. Create log directory
step "Preparing the log directory"
mkdir -p "${LOG_DIR}"
print_ok "Log directory: ${C_DIM}${LOG_DIR}/${C_NC}"


WEBUI_SKIP_ALL=false

# Announced either way, so the step count stays honest. A run that silently
# skips a numbered step looks like it lost one.
step "Web control panel"
if [ "${ENABLE_WEB_UI}" != "true" ]; then
    print_skip "Not installing it — updates run from cron regardless"
fi

if [ "${ENABLE_WEB_UI}" = "true" ]; then

    if ! command -v python3 >/dev/null 2>&1; then
        print_fail "python3 not found — required by the control panel."
        print_fail "Install it with 'apt-get install -y python3', then re-run this installer."
        exit 1
    fi

    # Stage every panel file before installing any of them.
    #
    # These used to be fetched straight over their live destinations, and a
    # single failure set ENABLE_WEB_UI=false — which fell through to the
    # *teardown* branch below, un-patching pvemanagerlib.js and deleting the
    # unit, apt hook, binary and patcher, while printing "Web control panel
    # removed". So one transient GitHub blip during an unattended self-update
    # uninstalled the very panel that had requested the update, leaving the
    # config on disk still saying ENABLE_WEB_UI="true".
    UI_STAGE="$(mktemp -d)"
    UI_FETCH_OK=true
    fetch_asset "webui/pve-autoupdate-ui"            "${UI_STAGE}/ui"      || UI_FETCH_OK=false
    fetch_asset "webui/patch-webui.sh"               "${UI_STAGE}/patch"   || UI_FETCH_OK=false
    fetch_asset "webui/pve-autoupdate-ui.service"    "${UI_STAGE}/service" || UI_FETCH_OK=false
    fetch_asset "webui/99-proxmox-autoupdate-webui"  "${UI_STAGE}/hook"    || UI_FETCH_OK=false

    if [ "${UI_FETCH_OK}" = true ]; then
        verify_script "${UI_STAGE}/patch" 'BEGIN proxmox-autoupdate button' "The panel patcher" \
            || UI_FETCH_OK=false
        if [ -s "${UI_STAGE}/ui" ] && head -1 "${UI_STAGE}/ui" | grep -q '^#!'; then
            python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" \
                "${UI_STAGE}/ui" >/dev/null 2>&1 || {
                print_fail "The downloaded control panel is not valid Python"
                UI_FETCH_OK=false
            }
        else
            print_fail "The downloaded control panel is not a script"
            UI_FETCH_OK=false
        fi
    fi

    if [ "${UI_FETCH_OK}" = true ]; then
        install -m 755 -o root -g root "${UI_STAGE}/ui"      "${UI_BIN}"
        install -m 755 -o root -g root "${UI_STAGE}/patch"   "${UI_PATCHER}"
        install -m 644 -o root -g root "${UI_STAGE}/service" "${UI_SERVICE}"
        install -m 644 -o root -g root "${UI_STAGE}/hook"    "${UI_APT_HOOK}"
    else
        print_fail "Web control panel files could not be installed."
        print_fail "The scheduled updates themselves are unaffected."
        if [ -x "${UI_BIN}" ]; then
            # Something is already installed and working. Leave it exactly as it
            # is rather than tearing it down over a failed download.
            print_action "Keeping the existing panel installation unchanged."
            WEBUI_SKIP_ALL=true
        else
            ENABLE_WEB_UI="false"
        fi
    fi
    rm -rf "${UI_STAGE}"
fi

if [ "${WEBUI_SKIP_ALL}" = true ]; then
    : # A download failed but a working panel is already installed. Leave it be.
elif [ "${ENABLE_WEB_UI}" = "true" ]; then
    # Port settings go in a drop-in, not into the unit itself.
    #
    # The unit is refetched on every install and self-update, so editing it in
    # place threw away any operator customisation — most importantly
    # Environment=PAU_UI_ADDR=127.0.0.1, which is how you stop the panel
    # listening on every interface. A drop-in survives the unit being replaced.
    mkdir -p "${UI_SERVICE}.d"
    cat > "${UI_SERVICE}.d/10-port.conf" <<DROPIN
# Managed by the proxmox-autoupdate installer. Safe to edit; it is not
# overwritten unless you change the port during a re-install.
[Service]
Environment=PAU_UI_PORT=${WEB_UI_PORT}
DROPIN
    chmod 644 "${UI_SERVICE}.d/10-port.conf"

    # Is the port actually free? Nothing checked, and because the unit is
    # Type=simple, `systemctl restart` returns 0 as soon as the process forks —
    # before it tries to bind. So a collision printed "Service running on port
    # 8007" while the unit crash-looped every 5 seconds. Proxmox Backup Server
    # owns 8007, and co-installing it on the PVE host is a documented setup.
    PORT_OWNER=""
    if command -v ss >/dev/null 2>&1; then
        PORT_OWNER=$(ss -lntpH "( sport = :${WEB_UI_PORT} )" 2>/dev/null | head -1 || true)
    fi
    if [ -n "${PORT_OWNER}" ] && ! systemctl is-active --quiet pve-autoupdate-ui.service 2>/dev/null; then
        print_fail "Port ${WEB_UI_PORT} is already in use by something else:"
        echo -e "      ${C_DIM}${PORT_OWNER}${C_NC}"
        if [ "${WEB_UI_PORT}" = "8007" ]; then
            print_fail "Port 8007 belongs to Proxmox Backup Server. Choose another port."
        fi
        # WEBUI_SKIP_ALL, *not* ENABLE_WEB_UI="false".
        #
        # The panel files were installed a moment ago, at the top of this
        # section. Flipping ENABLE_WEB_UI here dropped straight through to the
        # teardown branch below, whose guard — "does the unit file exist?" — was
        # satisfied by the unit this run had just written. So a port clash on a
        # fresh install un-patched the Proxmox UI, deleted the binary, the unit,
        # its drop-in directory and the apt hook, and signed off with a green
        # "✓ Web control panel removed" for a panel the operator had just asked
        # for. Meanwhile the config file, written earlier, still said
        # ENABLE_WEB_UI="true".
        #
        # This is the same failure the download path was fixed for; the fix just
        # never reached this branch. Leave everything installed and stopped, so
        # changing the port and starting the unit is all that is needed.
        WEBUI_SKIP_ALL=true
        echo ""
        echo -e "  ${C_BOLD}The panel is installed but not started.${C_NC}"
        echo -e "  ${C_DIM}Nothing has been removed. Pick a free port and start it:${C_NC}"
        echo -e "    ${C_CYAN}sed -i 's/^WEB_UI_PORT=.*/WEB_UI_PORT='\\''8009'\\''/' ${CONFIG_FILE}${C_NC}"
        echo -e "    ${C_CYAN}systemctl start pve-autoupdate-ui.service${C_NC}"
        echo -e "  ${C_DIM}Or re-run this installer and choose a different port.${C_NC}"
        echo ""
    fi
fi

if [ "${WEBUI_SKIP_ALL}" = true ]; then
    : # unchanged
elif [ "${ENABLE_WEB_UI}" = "true" ]; then
    systemctl daemon-reload
    systemctl enable pve-autoupdate-ui.service >/dev/null 2>&1 || true
    systemctl restart pve-autoupdate-ui.service >/dev/null 2>&1 || true

    # Ask the port, not systemd.
    #
    # The unit is Type=simple, so `systemctl is-active` says "active" the moment
    # the process forks — before it has read a certificate or bound anything. A
    # panel that starts, throws, and is restarted five seconds later by
    # Restart=on-failure looks perfectly healthy in that window, which is how an
    # install could report success while the port never answered. The only
    # honest test is a request.
    UI_UP=false
    UI_CODE="000"
    for _ATTEMPT in 1 2 3 4 5 6 7 8 9 10; do
        # Any HTTP status counts as up. 401 in particular is a *success* here:
        # the server answered, curl simply has no Proxmox session cookie.
        # "000" is curl's code for "never got a response at all", and the
        # `|| echo 000` matters — without it a missing curl produces an empty
        # string, which is not "000", which would have been read as success.
        UI_CODE=$(curl -s -k -m 5 -o /dev/null -w '%{http_code}' \
                  "https://127.0.0.1:${WEB_UI_PORT}/" 2>/dev/null) || UI_CODE=""
        # Match a real status explicitly rather than testing "not 000".
        # `curl ... || echo 000` appended to curl's own "000" and produced
        # "000000", which is not "000", so a dead port reported as answering —
        # exactly the false success this check exists to remove.
        case "${UI_CODE}" in
            [1-9][0-9][0-9]) UI_UP=true; break ;;
            *)               UI_CODE="000" ;;
        esac
        sleep 1
    done

    if [ "${UI_UP}" = true ]; then
        print_ok "Panel is answering on ${C_BOLD}https://$(hostname -f 2>/dev/null || hostname):${WEB_UI_PORT}/${C_NC} ${C_DIM}(HTTP ${UI_CODE})${C_NC}"
    else
        print_fail "The panel is not answering on port ${WEB_UI_PORT}."
        # Print the reason here rather than telling the user to go and find it.
        # "check journalctl" is a step most people do not take, so the actual
        # error — a busy port, a missing certificate, a Python traceback — went
        # unread and the install looked like it had simply not worked.
        echo ""
        # Every one of these is best-effort. Under `set -euo pipefail` a
        # missing journalctl made the *diagnostic* abort the installer with
        # exit 127 — turning "the panel did not start" into "the install
        # failed", which is both wrong and much harder to recover from.
        if command -v systemctl >/dev/null 2>&1; then
            echo -e "  ${C_DIM}systemctl status pve-autoupdate-ui:${C_NC}"
            { systemctl --no-pager --lines=0 status pve-autoupdate-ui.service 2>&1                 | sed 's/^/      /' | head -8; } || true
        fi
        if command -v journalctl >/dev/null 2>&1; then
            echo -e "  ${C_DIM}Last lines from the service log:${C_NC}"
            { journalctl -u pve-autoupdate-ui.service -n 15 --no-pager 2>&1                 | sed 's/^/      /' | tail -15; } || true
        fi
        echo ""
        print_fail "Updates from cron are unaffected — only the panel is down."
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
        if "${UI_PATCHER}" apply            && grep -qF 'BEGIN proxmox-autoupdate button' "${PVE_JS}"; then
            # Verified by reading the file back, not by trusting the exit code.
            print_ok "Toolbar button added to ${C_DIM}${PVE_JS}${C_NC}"
            print_ok "Apt hook installed ${C_DIM}(re-applies it after pve-manager upgrades)${C_NC}"
            echo ""
            echo -e "  ${C_BOLD}The button will not appear until you reload the Proxmox UI.${C_NC}"
            echo -e "  ${C_DIM}Your browser has the old pvemanagerlib.js cached, and an ordinary${C_NC}"
            echo -e "  ${C_DIM}refresh will not replace it. Use ${C_NC}${C_CYAN}Ctrl+Shift+R${C_NC}${C_DIM} (${C_NC}${C_CYAN}Cmd+Shift+R${C_NC}${C_DIM} on a Mac),${C_NC}"
            echo -e "  ${C_DIM}or open the Proxmox UI in a private window to check.${C_NC}"
            echo ""
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
        # Take the button out of pvemanagerlib.js *before* deleting the tool
        # that knows how to do it, and only delete that tool if it succeeded.
        # Otherwise a failed un-patch left the button wired into the Proxmox UI
        # permanently, pointing at a service that no longer exists.
        UNPATCH_OK=true
        if [ -x "${UI_PATCHER}" ]; then
            "${UI_PATCHER}" remove --quiet >/dev/null 2>&1 || UNPATCH_OK=false
        fi
        systemctl disable --now pve-autoupdate-ui.service >/dev/null 2>&1 || true
        rm -f "${UI_SERVICE}" "${UI_APT_HOOK}" "${UI_BIN}"
        rm -rf "${UI_SERVICE}.d"
        if [ "${UNPATCH_OK}" = true ]; then
            rm -f "${UI_PATCHER}"
            systemctl daemon-reload
            print_ok "Web control panel removed"
        else
            systemctl daemon-reload
            print_fail "Could not remove the toolbar button from the Proxmox UI."
            print_fail "Keeping ${UI_PATCHER} so you can retry:"
            print_fail "  ${UI_PATCHER} remove"
        fi
    fi
fi

# 6. Idempotent Cron Configuration
step "Configuring the schedule"
CRON_MARKER="# proxmox-autoupdate"
# One crontab line per schedule. The ones that must not reboot carry
# --no-reboot; the comment above each is what makes `crontab -l` readable.
build_cron_lines() {
    parse_schedules "${UPDATE_SCHEDULES}" | while IFS="$(printf '	')" read -r c r l; do
        [ -n "${l}" ] && echo "${CRON_MARKER}: ${l}$([ "${r}" = "no" ] && echo " (no reboot)")"
        case "${r}" in
            no)   echo "${c} ${TARGET_PATH} --no-reboot >> ${LOG_DIR}/cron.log 2>&1" ;;
            only) echo "${c} ${TARGET_PATH} --reboot-window >> ${LOG_DIR}/cron.log 2>&1" ;;
            *)    echo "${c} ${TARGET_PATH} >> ${LOG_DIR}/cron.log 2>&1" ;;
        esac
    done
}

CRON_TMP=$(mktemp)
CRON_ERR=$(mktemp)
crontab -l 2>/dev/null | grep -v "${TARGET_PATH}" | grep -v "^${CRON_MARKER}" > "${CRON_TMP}" || true
echo "${CRON_MARKER}" >> "${CRON_TMP}"
build_cron_lines >> "${CRON_TMP}"
if ! crontab "${CRON_TMP}" 2>"${CRON_ERR}"; then
    print_fail "Invalid cron schedule! crontab rejected it:"
    sed 's/^/    /' "${CRON_ERR}"
    rm -f "${CRON_TMP}" "${CRON_ERR}"
    exit 1
fi
rm -f "${CRON_TMP}" "${CRON_ERR}"

# A crontab entry is useless without something to run it. Nothing checked, so an
# install on a node with no cron daemon reported success and then never ran.
if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 \
   || systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet cronie 2>/dev/null; then
    print_ok "Cron daemon is running"
else
    print_fail "No cron daemon is running — the schedule will never fire."
    print_fail "Fix it with:  systemctl enable --now cron"
fi

# Rotate our own logs.
#
# The retention pruner in update-everything.sh is `find -name '*.log' -mtime +N`,
# which can never match cron.log: the name matches, but the file is appended to
# on every run so its mtime is always current. Without this it grows forever.
cat > /etc/logrotate.d/proxmox-autoupdate <<LOGROTATE
"${LOG_DIR}"/cron.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LOGROTATE
chmod 644 /etc/logrotate.d/proxmox-autoupdate
print_ok "Log rotation configured ${C_DIM}(/etc/logrotate.d/proxmox-autoupdate)${C_NC}"

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
# Only the channels actually set up. This block used to print a Mailgun region
# and two blank email lines to everyone, including the majority who skip
# notifications entirely, which read as something half-configured.
echo -e "  ${C_CYAN}Notify:${C_NC}     ${NOTIFY_METHODS:-none}"
if echo ",${NOTIFY_METHODS}," | grep -q ",email,"; then
    if [ "${EMAIL_TRANSPORT}" = "mailgun" ]; then
        echo -e "  ${C_CYAN}Email:${C_NC}      Mailgun ${MAILGUN_REGION}, ${SENDER_EMAIL} → ${RECIPIENT_EMAIL}"
    else
        echo -e "  ${C_CYAN}Email:${C_NC}      ${SMTP_HOST}:${SMTP_PORT} (${SMTP_SECURITY}), ${SENDER_EMAIL} → ${RECIPIENT_EMAIL}"
    fi
fi
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
parse_schedules "${UPDATE_SCHEDULES}" | while IFS="$(printf '	')" read -r c r l; do
    case "${r}" in
        no)   echo -e "  ${C_CYAN}Schedule:${C_NC}   ${c}  ${C_DIM}${l:+${l} — }update, never reboots${C_NC}" ;;
        only) echo -e "  ${C_CYAN}Schedule:${C_NC}   ${c}  ${C_DIM}${l:+${l} — }reboot window, no updates${C_NC}" ;;
        *)    echo -e "  ${C_CYAN}Schedule:${C_NC}   ${c}  ${C_DIM}${l:+${l} — }update, may reboot${C_NC}" ;;
    esac
done
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
# If a notification channel is configured, either run mode also exercises it end
# to end.
#
# Only offered when there is a real terminal to answer. This guard used to test
# UNATTENDED alone, but the prompt also reads EOF whenever there is no
# controlling terminal — `ssh host 'curl … | bash'` without -t, Ansible,
# cloud-init, cron — and the "Enter for 1" default then silently started a
# sweep of every guest, took the update lockfile, and blocked for a long time,
# with none of the prompts even printed.
if [ "${UNATTENDED}" = true ] || [ "${HAVE_TTY}" != true ]; then
    echo ""
    if [ "${UNATTENDED}" = true ]; then
        print_ok "Install complete ${C_DIM}(no test run — unattended)${C_NC}"
    else
        print_ok "Install complete ${C_DIM}(no test run — no terminal to prompt on)${C_NC}"
        echo ""
        echo -e "  Check the installation with:  ${C_BOLD}${TARGET_PATH} --doctor${C_NC}"
        echo -e "  Preview a run with:           ${C_BOLD}${TARGET_PATH} --dry-run${C_NC}"
    fi
    echo ""
    exit 0
fi

step "Test run"
echo ""
echo -e "  ${C_BOLD}Run now to verify the setup?${C_NC}"
echo -e "    ${C_CYAN}1)${C_NC} Dry run   ${C_DIM}— check everything and email the report,${C_NC}"
echo -e "                  ${C_DIM}but install nothing and never reboot${C_NC}"
echo -e "    ${C_CYAN}2)${C_NC} Full run  ${C_DIM}— update the host and every guest now,${C_NC}"
echo -e "                  ${C_DIM}then email the report${C_NC}"
echo -e "    ${C_CYAN}3)${C_NC} Skip      ${C_DIM}— wait for the scheduled run (${UPDATE_SCHEDULE_CRON})${C_NC}"
echo ""
ask RUN_CHOICE "  Select 1-3 [Enter for 1]: "

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
    ask CONFIRM_FULL "  Type 'yes' to confirm: "
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
            report_delivery_hint
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
            report_delivery_hint
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