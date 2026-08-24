#!/usr/bin/env bash
# ==============================================================================
# Proxmox Master Auto-Update — with Fancy Output, Stopped Guest Support
# & Windows VM Updates via QEMU Guest Agent
# ==============================================================================

# Read by the web panel's "check for updates" and shown in its footer. Keep the
# literal assignment on one line — it is grepped, not sourced.
PAU_VERSION="1.9.0"

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
DOCTOR="false"
ALLOW_REBOOT="true"
REBOOT_WINDOW="false"
RAW_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run)
            CLI_DRY_RUN="true"
            ;;
        --doctor)
            DOCTOR="true"
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
        --reboot-window)
            REBOOT_WINDOW="true"
            ;;
        --no-reboot)
            # Apply everything, but never book the reboot.
            #
            # This is what lets one machine have more than one schedule: a
            # weekly run that installs updates and leaves the new kernel
            # waiting, and a monthly run — same script, without this flag —
            # that is allowed to take the host down for it.
            ALLOW_REBOOT="false"
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

  --reboot-window   Reboot the host if — and only if — a reboot is already
                    owed: a newer kernel is installed than the one running.
                    Updates nothing. This is the other half of --no-reboot:
                    schedule the updates as often as you like, and schedule the
                    outage separately, on its own terms. Does nothing at all,
                    quietly, when no reboot is owed.

  --no-reboot       Install everything as normal, but never schedule a reboot,
                    however much the kernel changed. Pair a frequent run
                    carrying this flag with an occasional one that does not, and
                    updates land weekly while the host only goes down monthly.
                    The report says a reboot is being held rather than that none
                    is needed.

  --doctor          Check this installation and report what would stop it
                    working, without changing anything. Run this first if a
                    scheduled run appears to do nothing. Exits non-zero if any
                    check fails.

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

# Timestamps and the reboot schedule follow the host's own timezone.
#
# This used to force TZ=Europe/London for the whole process, which is fine for a
# UK box and wrong everywhere else: REBOOT_TIME was resolved as a London
# wall-clock time, so a US-Eastern user asking for 03:00 got a reboot at 22:00
# local. Set PAU_TZ in the config to pin a specific zone for reporting.
if [ -n "${PAU_TZ:-}" ]; then
    export TZ="${PAU_TZ}"
fi

# Ensure full PATH for cron execution (pct, qm, pveversion live in sbin dirs)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# --- EARLY FAILURE NOTIFICATION ---
# The full notification layer lives near the end of this script and only runs
# once the sweep has finished. Every fatal path before that point — a missing
# config, a held lock, a missing dependency — used to exit with a line on stdout
# and nothing else, and cron's output is redirected to a log file by the
# installer, so nothing was mailed either. A weekly job could therefore fail
# silently for months.
#
# This is a deliberately minimal sender: no HTML, no attachments, no jq. It
# parses the config rather than sourcing it, so it cannot be broken by (or
# execute) whatever is in there.
CONFIG_FILE="${PAU_CONFIG_FILE:-/etc/proxmox-autoupdate.conf}"

cfg_read() {
    [ -r "${CONFIG_FILE}" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "${CONFIG_FILE}" 2>/dev/null \
        | tail -1 \
        | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
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

# Escape a string for embedding in a JSON string literal.
#
# The slurp (:a N $!ba) has to come first. sed applies commands in order within
# a cycle, so escaping before the slurp only ever escapes the first line — every
# subsequent line is appended after those substitutions have already run.
json_escape() {
    printf '%s' "$1" \
        | tr -d '\r' \
        | sed -e ':a' -e 'N' -e '$!ba' \
              -e 's/\\/\\\\/g' \
              -e 's/"/\\"/g' \
              -e 's/\t/\\t/g' \
              -e 's/\n/\\n/g'
}

notify_fatal() {
    local msg="$1"
    local methods host_label
    methods=$(cfg_read NOTIFY_METHODS)
    if [ -z "${methods}" ] || [ "${methods}" = "none" ]; then
        return 0
    fi
    command -v curl >/dev/null 2>&1 || return 0

    host_label=$(hostname -s 2>/dev/null || echo "proxmox")
    local text="[proxmox-autoupdate] ${host_label}: ${msg}"
    local esc
    esc=$(json_escape "${text}")

    case ",${methods}," in
        *,discord,*)
            local dw
            dw=$(cfg_read DISCORD_WEBHOOK_URL)
            [ -n "${dw}" ] && curl -fsS -m 15 -H 'Content-Type: application/json' \
                -d "{\"content\":\"${esc}\"}" "${dw}" >/dev/null 2>&1 || true
            ;;
    esac
    case ",${methods}," in
        *,slack,*)
            local sw
            sw=$(cfg_read SLACK_WEBHOOK_URL)
            [ -n "${sw}" ] && curl -fsS -m 15 -H 'Content-Type: application/json' \
                -d "{\"text\":\"${esc}\"}" "${sw}" >/dev/null 2>&1 || true
            ;;
    esac
    case ",${methods}," in
        *,webhook,*)
            local gw
            gw=$(cfg_read GENERIC_WEBHOOK_URL)
            [ -n "${gw}" ] && curl -fsS -m 15 -H 'Content-Type: application/json' \
                -d "{\"status\":\"fatal\",\"host\":\"$(json_escape "${host_label}")\",\"message\":\"${esc}\"}" \
                "${gw}" >/dev/null 2>&1 || true
            ;;
    esac
    case ",${methods}," in
        *,email,*)
            local key domain region sender recipient api
            key=$(cfg_read MAILGUN_API_KEY);   domain=$(cfg_read MAILGUN_DOMAIN)
            sender=$(cfg_read SENDER_EMAIL);   recipient=$(cfg_read RECIPIENT_EMAIL)
            region=$(cfg_read MAILGUN_REGION); region="${region:-EU}"
            api="https://api.eu.mailgun.net/v3"
            [ "${region}" = "US" ] && api="https://api.mailgun.net/v3"
            if [ -n "${key}" ] && [ -n "${domain}" ] && [ -n "${recipient}" ]; then
                curl -fsS -m 20 --user "api:${key}" \
                    "${api}/${domain}/messages" \
                    -F from="${sender:-proxmox@${domain}}" \
                    -F to="${recipient}" \
                    -F subject="[proxmox-autoupdate] ${host_label}: run did not start" \
                    -F text="${text}" >/dev/null 2>&1 || true
            fi
            ;;
    esac
    return 0
}

# --- SELF-DIAGNOSTIC ---
# Everything the update path silently depends on, checked in one place and
# reported in plain language. This exists because the failure modes that matter
# most are the quiet ones: a host whose repositories are broken, a node where
# pmxcfs is down, an install on a machine that is not a Proxmox host at all. All
# of those used to end in "all clear" and an empty report.
#
# Read-only. Changes nothing, sends nothing, starts nothing.
DOC_FAIL=0
DOC_WARN=0
_d_ok()   { echo "  [ ok ] $1"; }
_d_warn() { echo "  [warn] $1"; DOC_WARN=$((DOC_WARN + 1)); }
_d_fail() { echo "  [FAIL] $1"; DOC_FAIL=$((DOC_FAIL + 1)); }
_d_head() { echo ""; echo "── $1"; }

# Where run history and the pending-reboot marker live, so a report can say
# "this guest has failed 3 runs" instead of treating every run as the first.
#
# Defined up here rather than with the rest of the config because --doctor reads
# it and returns long before that block is reached; under `set -u` a later
# definition is not a subtle bug, it is an immediate abort.
STATE_DIR="/var/lib/proxmox-autoupdate"
STATE_FILE="${STATE_DIR}/state.json"
REBOOT_PENDING_FILE="${STATE_DIR}/reboot-pending"

# The newest kernel image on disk, by version.
#
# `ls -t` orders by mtime, which is not version order: reinstalling or pinning
# an older kernel — routine after a NIC or GPU driver problem, and what a /boot
# restore does — made that older image look like the newest, so the running
# kernel never matched and the host rebooted after every single run, forever.
# linux-version (from linux-base) knows how to order kernel versions; sort -V is
# the fallback.
latest_installed_kernel() {
    local list newest=""
    list=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' || true)
    [ -n "${list}" ] || return 0
    if command -v linux-version >/dev/null 2>&1; then
        newest=$(echo "${list}" | linux-version sort --reverse 2>/dev/null | head -1)
    fi
    [ -n "${newest}" ] || newest=$(echo "${list}" | sort -V | tail -1)
    echo "${newest}"
}

# --- Reboot window -----------------------------------------------------------
#
# Takes a reboot that is already owed, and does nothing else. Pairs with
# --no-reboot: the update schedules install kernels without ever taking the host
# down, and this decides when the host actually goes down for them.
#
# "Owed" is deliberately the same test the update path uses — a newer kernel is
# installed than the one booted — so this never reboots a host that has nothing
# to gain from it. The marker file only carries the reason across for the
# report; it is not what makes the decision, so clearing it by hand or losing
# /var/lib cannot strand a host on an old kernel.
run_reboot_window() {
    local running latest reason=""
    running=$(uname -r)
    latest=$(latest_installed_kernel)

    if [ -z "${latest}" ] || [ "${running}" = "${latest}" ]; then
        rm -f "${REBOOT_PENDING_FILE}" 2>/dev/null || true
        echo "Reboot window: nothing owed — running the newest installed kernel (${running})."
        return 0
    fi

    if [ -r "${REBOOT_PENDING_FILE}" ]; then
        reason=$(head -c 500 "${REBOOT_PENDING_FILE}" 2>/dev/null | tr -d '"""+BS+"r"+BS+"""n')
    fi
    [ -n "${reason}" ] || reason="Kernel ${latest} is installed; the host is running ${running}"

    if [ "${DRY_RUN}" = "true" ]; then
        echo "Reboot window (dry run): would reboot now. ${reason}"
        return 0
    fi

    echo "Reboot window: rebooting. ${reason}"
    # notify_fatal is the one-line "send this sentence to every configured
    # channel" helper; the name is about how little it does, not severity. A
    # host going down unattended is worth a message.
    notify_fatal "Rebooting into ${latest} — ${reason}" || true
    rm -f "${REBOOT_PENDING_FILE}" 2>/dev/null || true
    # A minute's grace so anyone watching, and any guest still shutting down,
    # has a moment. `shutdown -r now` from cron has no such courtesy.
    shutdown -r +1 "Scheduled reboot window: ${reason}" 2>/dev/null || {
        echo "shutdown(8) refused the reboot — is this a container rather than the host?" >&2
        return 1
    }
    return 0
}

run_doctor() {
    echo ""
    echo "proxmox-autoupdate — self-check (version ${PAU_VERSION})"
    echo "Nothing is changed by this command."

    _d_head "Host"
    if [ "$(id -u)" -eq 0 ]; then
        _d_ok "running as root"
    else
        _d_fail "not running as root — the real run needs root for pct, qm and apt"
    fi

    if command -v pveversion >/dev/null 2>&1 && [ -d /etc/pve ]; then
        _d_ok "Proxmox VE detected: $(pveversion 2>/dev/null | head -1)"
    else
        _d_fail "this is not a Proxmox VE host (pveversion and /etc/pve required)"
        _d_fail "  → run this on the PVE host itself, not in a VM or container"
    fi

    local t
    for t in pct qm pvesh; do
        command -v "${t}" >/dev/null 2>&1 && _d_ok "${t} found" || _d_fail "${t} not found on PATH"
    done

    _d_head "Cluster filesystem"
    if pct list >/dev/null 2>&1; then
        _d_ok "pct list works ($(pct list 2>/dev/null | awk 'NR>1' | wc -l) container(s))"
    else
        _d_fail "pct list failed — containers cannot be enumerated"
        _d_fail "  → check: systemctl status pve-cluster"
    fi
    if qm list >/dev/null 2>&1; then
        _d_ok "qm list works ($(qm list 2>/dev/null | awk 'NR>1' | wc -l) VM(s))"
    else
        _d_fail "qm list failed — VMs cannot be enumerated"
        _d_fail "  → check: systemctl status pve-cluster"
    fi

    _d_head "Dependencies"
    local pkg
    for t in jq python3 curl flock; do
        case "${t}" in
            flock) pkg="util-linux" ;;
            *)     pkg="${t}" ;;
        esac
        command -v "${t}" >/dev/null 2>&1 && _d_ok "${t}" \
            || _d_fail "${t} missing (required) — apt-get install -y ${pkg}"
    done
    command -v systemd-run >/dev/null 2>&1 && _d_ok "systemd-run (needed by --detach)" \
        || _d_warn "systemd-run missing — --detach will not work"
    command -v fuser >/dev/null 2>&1 && _d_ok "fuser (used by the panel's run-in-progress guard)" \
        || _d_warn "fuser missing — apt-get install -y psmisc"
    command -v linux-version >/dev/null 2>&1 && _d_ok "linux-version (accurate kernel comparison)" \
        || _d_warn "linux-version missing — apt-get install -y linux-base"

    _d_head "This installation"
    local installed="/usr/local/bin/update-everything.sh"
    if [ -f "${installed}" ]; then
        if head -1 "${installed}" | grep -q '^#!'; then
            if bash -n "${installed}" 2>/dev/null; then
                if grep -q '^PAU_VERSION=' "${installed}"; then
                    _d_ok "${installed} looks like a valid copy of this script"
                else
                    _d_fail "${installed} parses but has no PAU_VERSION — it is not this script"
                fi
            else
                _d_fail "${installed} is not valid shell — the download was corrupted"
                _d_fail "  → reinstall; a proxy or captive portal may have replaced it with an error page"
            fi
        else
            _d_fail "${installed} does not start with #! — it is not a script at all"
            _d_fail "  → head -3 ${installed}   (probably an HTML error page)"
        fi
    else
        _d_warn "${installed} not present (running from a checkout?)"
    fi

    _d_head "Configuration"
    if [ -f "${CONFIG_FILE}" ]; then
        _d_ok "${CONFIG_FILE} exists"
        if bash -n "${CONFIG_FILE}" 2>/dev/null; then
            _d_ok "config parses as shell"
        else
            _d_fail "config is not valid shell — the run will abort on it"
        fi
        local mode
        mode=$(stat -c '%a' "${CONFIG_FILE}" 2>/dev/null || echo "?")
        if [ "${mode}" = "600" ]; then
            _d_ok "config permissions are 600"
        else
            _d_warn "config is mode ${mode}; it holds credentials — chmod 600 ${CONFIG_FILE}"
        fi
        local m
        m=$(cfg_read NOTIFY_METHODS)
        if [ -z "${m}" ] || [ "${m}" = "none" ]; then
            _d_warn "no notification channel configured — failures will be silent"
        else
            _d_ok "notification methods: ${m}"
        fi
        if [ "$(cfg_read DRY_RUN)" = "true" ]; then
            _d_warn "DRY_RUN=true — scheduled runs report but never install anything"
        fi
    else
        _d_fail "${CONFIG_FILE} not found — run the installer"
    fi

    _d_head "Host package sources"
    if [ "$(id -u)" -eq 0 ]; then
        local apterr rc=0
        apterr=$(apt-get update -qy 2>&1 >/dev/null) || rc=$?
        if [ "${rc}" -eq 0 ]; then
            _d_ok "apt-get update succeeds"
            local n
            n=$(LC_ALL=C apt list --upgradable 2>/dev/null | grep -c '/' || true)
            _d_ok "${n} host package(s) currently upgradable"
        else
            _d_fail "apt-get update exited ${rc} — the host cannot be updated"
            echo "${apterr}" | tail -n 3 | sed 's/^/         /'
        fi
    else
        _d_warn "skipping apt check (needs root)"
    fi
    if grep -rqs 'enterprise\.proxmox\.com' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        if [ -s /etc/subscription ]; then
            _d_ok "enterprise repository enabled and a subscription is present"
        else
            _d_fail "enterprise repository enabled but no subscription — apt will fail every run"
            _d_fail "  → switch to pve-no-subscription, or disable the enterprise repository"
        fi
    fi

    _d_head "Scheduling"
    if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 \
       || systemctl is-active --quiet cron 2>/dev/null; then
        _d_ok "a cron daemon is running"
    else
        _d_fail "no cron daemon is running — nothing will ever trigger a scheduled run"
        _d_fail "  → systemctl enable --now cron"
    fi
    CRON_LINES=$(crontab -l 2>/dev/null | grep 'update-everything.sh' || true)
    if [ -n "${CRON_LINES}" ]; then
        CRON_N=$(echo "${CRON_LINES}" | wc -l | tr -d ' ')
        _d_ok "${CRON_N} crontab entr$([ "${CRON_N}" = "1" ] && echo y || echo ies):"
        echo "${CRON_LINES}" | while IFS= read -r _line; do
            _d_ok "  ${_line}"
        done
        # The whole point of splitting schedules is that one of them can reboot.
        # If none may, a kernel update installs and then waits forever, and the
        # only symptom is a host quietly running an old kernel.
        if ! echo "${CRON_LINES}" | grep -qv -- '--no-reboot'; then
            _d_warn "every schedule runs with --no-reboot, so a new kernel will never be booted"
            _d_warn "  → give one schedule permission to reboot, in the panel or the installer"
        fi
    else
        _d_warn "no crontab entry for update-everything.sh"
    fi

    # A reboot one schedule installed a kernel for and was not allowed to take.
    # Worth surfacing: from the outside the machine just looks like it is
    # running an old kernel for no reason.
    if [ -r "${STATE_DIR}/reboot-pending" ]; then
        _d_warn "a reboot is pending: $(head -c 200 "${STATE_DIR}/reboot-pending" 2>/dev/null | tr -d '\r\n')"
        _d_warn "  → the next schedule that allows a reboot will take it, or reboot by hand"
    fi

    # The crontab is what actually runs; the config is what the panel edits.
    # They are written together, so a difference means one of them was
    # hand-edited and the other was not.
    CFG_SCHEDULES=$(cfg_read UPDATE_SCHEDULES)
    if [ -n "${CFG_SCHEDULES}" ]; then
        CFG_N=$(UPDATE_SCHEDULE_CRON="" parse_schedules "${CFG_SCHEDULES}" | wc -l | tr -d ' ')
        if [ -n "${CRON_LINES}" ] && [ "${CFG_N}" != "${CRON_N:-0}" ]; then
            _d_warn "the config lists ${CFG_N} schedule(s) but the crontab has ${CRON_N:-0}"
            _d_warn "  → re-save the schedule in the panel to put them back in step"
        fi
    fi

    _d_head "Runtime state"
    if [ -e "${LOCKFILE}" ]; then
        if command -v fuser >/dev/null 2>&1 && fuser "${LOCKFILE}" >/dev/null 2>&1; then
            _d_warn "a run is in progress right now (lock held)"
        else
            _d_ok "lockfile present but not held (normal between runs)"
        fi
    else
        _d_ok "no lockfile"
    fi
    local logdir
    logdir=$(cfg_read LOG_DIR); logdir="${logdir:-/var/log/proxmox-autoupdate}"
    if [ -d "${logdir}" ] && [ -w "${logdir}" ]; then
        _d_ok "log directory writable: ${logdir}"
    else
        _d_warn "log directory missing or not writable: ${logdir}"
    fi
    local avail_root avail_boot
    avail_root=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "${avail_root}" ] && { [ "${avail_root}" -lt 1024 ] \
        && _d_warn "only ${avail_root} MB free on / — an upgrade may fail" \
        || _d_ok "${avail_root} MB free on /"; }
    if mountpoint -q /boot 2>/dev/null; then
        avail_boot=$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')
        [ -n "${avail_boot}" ] && { [ "${avail_boot}" -lt 100 ] \
            && _d_fail "only ${avail_boot} MB free on /boot — a kernel upgrade will fail" \
            || _d_ok "${avail_boot} MB free on /boot"; }
    fi
    _d_ok "timezone: $(date +%Z) (reboot times are interpreted in this zone)"

    _d_head "Web panel"
    local uiport
    uiport=$(cfg_read WEB_UI_PORT); uiport="${uiport:-8007}"
    if [ "$(cfg_read ENABLE_WEB_UI)" = "true" ]; then
        # Ask the port, not systemd. Type=simple reports "active" as soon as the
        # process forks, so a panel that starts and immediately dies looks
        # healthy for the five seconds before Restart=on-failure notices.
        local http=""
        if command -v curl >/dev/null 2>&1; then
            http=$(curl -s -k -m 5 -o /dev/null -w '%{http_code}'                    "https://127.0.0.1:${uiport}/" 2>/dev/null || echo 000)
        fi
        if [ -n "${http}" ] && [ "${http}" != "000" ]; then
            _d_ok "panel is answering on port ${uiport} (HTTP ${http})"
        elif systemctl is-active --quiet pve-autoupdate-ui.service 2>/dev/null; then
            _d_fail "the panel service is running but port ${uiport} does not answer"
            _d_fail "  → journalctl -u pve-autoupdate-ui -n 50"
        else
            _d_fail "panel is enabled in the config but the service is not running"
            _d_fail "  → systemctl status pve-autoupdate-ui"
            _d_fail "  → journalctl -u pve-autoupdate-ui -n 50"
            if command -v ss >/dev/null 2>&1 && ss -lntH 2>/dev/null | grep -q ":${uiport} "; then
                _d_fail "  → port ${uiport} is already in use by something else"
                _d_fail "     (Proxmox Backup Server uses 8007 — pick another port)"
            fi
        fi

        # Is the toolbar button actually in the file the browser loads? This is
        # the other half of "I installed it and nothing appeared": the service
        # can be perfectly healthy while pvemanagerlib.js was never patched, or
        # was replaced by a pve-manager upgrade and the apt hook did not re-run.
        local pvejs="/usr/share/pve-manager/js/pvemanagerlib.js"
        if [ ! -f "${pvejs}" ]; then
            _d_warn "${pvejs} not found — no toolbar button on this node"
        elif grep -qF 'BEGIN proxmox-autoupdate button' "${pvejs}" 2>/dev/null; then
            _d_ok "toolbar button is present in pvemanagerlib.js"
            _d_ok "  if you cannot see it, hard-refresh the Proxmox UI (Ctrl+Shift+R)"
        else
            _d_fail "the toolbar button is NOT in pvemanagerlib.js"
            _d_fail "  → /usr/local/bin/pve-autoupdate-patch-webui apply"
        fi
        if [ ! -f /etc/apt/apt.conf.d/99-proxmox-autoupdate-webui ]; then
            _d_warn "the apt hook is missing — the button will vanish on the next"
            _d_warn "  pve-manager upgrade and not come back. Re-run install.sh."
        fi
    else
        _d_ok "web panel not enabled"
    fi

    _d_head "Guests"
    # Report on containers as well as VMs, and always say something.
    #
    # This previously only emitted a line per *running* VM, so on a host whose
    # VMs were all stopped the section produced nothing at all — and the panel,
    # which drops empty sections, showed no Guests heading whatsoever. "Nothing
    # to check" and "the check did not run" looked identical. Containers were
    # not mentioned at all, which on a typical host is most of the fleet.
    local ct_run=0 ct_stop=0 ct_tmpl=0
    if pct list >/dev/null 2>&1; then
        local cid cstate
        while read -r cid cstate _; do
            [ -z "${cid}" ] && continue
            case "${cstate}" in
                running) ct_run=$((ct_run + 1)) ;;
                *)       ct_stop=$((ct_stop + 1)) ;;
            esac
            [ "$(config_field pct "${cid}" template)" = "1" ] && ct_tmpl=$((ct_tmpl + 1))
        done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $2}')
        _d_ok "containers: ${ct_run} running, ${ct_stop} stopped${ct_tmpl:+, ${ct_tmpl} template(s) skipped}"
        if [ "${ct_stop}" -gt 0 ] && [ "$(cfg_read START_STOPPED_LXC)" = "false" ]; then
            _d_warn "  ${ct_stop} stopped container(s) will be skipped (START_STOPPED_LXC=false)"
        fi

        # Can each running container actually reach anything?
        #
        # A guest that cannot resolve or connect takes the full apt timeout on
        # every run and then reports whatever apt's exit code happened to be.
        # Finding out why means bisecting DNS against connectivity by hand, so
        # this does that split here and names the cause.
        #
        # Every probe is time-boxed. A diagnostic that hangs is worse than no
        # diagnostic.
        local cid cname
        while read -r cid cname; do
            [ -z "${cid}" ] && continue
            [ "$(config_field pct "${cid}" template)" = "1" ] && continue
            [ "$(pct status "${cid}" 2>/dev/null | awk '{print $2}')" = "running" ] || continue

            if pct exec "${cid}" -- timeout 5 getent hosts deb.debian.org >/dev/null 2>&1 \
               || pct exec "${cid}" -- timeout 5 getent hosts archive.ubuntu.com >/dev/null 2>&1; then
                continue                    # resolves; nothing to report
            fi

            _d_warn "LXC ${cid} (${cname}): cannot resolve its package mirrors — updates will time out"

            # Name the cause rather than leaving it as "network broken". This
            # exact shape — a default-deny INPUT chain with no rules in it —
            # is what ufw leaves behind when it fails to start inside an
            # unprivileged container, and it silently firewalls the guest off
            # from the world while looking perfectly configured.
            local ipt
            ipt=$(pct exec "${cid}" -- timeout 5 iptables -S INPUT 2>/dev/null || true)
            if echo "${ipt}" | grep -q '^-P INPUT DROP' \
               && ! echo "${ipt}" | grep -qi 'ESTABLISHED'; then
                _d_warn "  its INPUT chain is default-DROP with no rules, so replies never come back"
                if pct exec "${cid}" -- timeout 5 sh -c 'command -v ufw' >/dev/null 2>&1; then
                    _d_warn "  ufw is installed; it cannot load its rules in an unprivileged container"
                    _d_warn "  → pct exec ${cid} -- systemctl disable --now ufw && pct exec ${cid} -- iptables -P INPUT ACCEPT"
                    _d_warn "  → filter with the Proxmox firewall instead, which runs outside the container"
                else
                    _d_warn "  → pct exec ${cid} -- iptables -P INPUT ACCEPT   (then make it persistent)"
                fi
            else
                _d_warn "  check its gateway, DNS servers and any firewall inside it"
            fi
        done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $3}')
    fi

    local vm_run=0 vm_stop=0 vm_agent_ok=0 vm_agent_bad=0
    if qm list >/dev/null 2>&1; then
        local vid vstate vname
        while read -r vid vname vstate _; do
            [ -z "${vid}" ] && continue
            if [ "${vstate}" = "running" ]; then
                vm_run=$((vm_run + 1))
                if qm agent "${vid}" ping >/dev/null 2>&1; then
                    vm_agent_ok=$((vm_agent_ok + 1))
                else
                    vm_agent_bad=$((vm_agent_bad + 1))
                    _d_warn "VM ${vid} (${vname}): running but the guest agent is not responding — it cannot be updated"
                fi
            else
                vm_stop=$((vm_stop + 1))
            fi
        done < <(qm list 2>/dev/null | awk 'NR>1 {print $1, $2, $3}')
        _d_ok "VMs: ${vm_run} running, ${vm_stop} stopped"
        if [ "${vm_run}" -gt 0 ]; then
            if [ "${vm_agent_bad}" -eq 0 ]; then
                _d_ok "  all ${vm_agent_ok} running VM(s) have a responding guest agent"
            fi
        else
            _d_ok "  no running VMs, so no guest agents to check"
        fi
        if [ "${vm_stop}" -gt 0 ] && [ "$(cfg_read START_STOPPED_LINUX_VMS)" = "false" ]; then
            _d_warn "  ${vm_stop} stopped VM(s) will be skipped (START_STOPPED_LINUX_VMS=false)"
        fi
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────"
    if [ "${DOC_FAIL}" -gt 0 ]; then
        echo "  ${DOC_FAIL} problem(s) will stop this working, ${DOC_WARN} warning(s)."
        echo "  Fix the [FAIL] lines above, then run --doctor again."
    elif [ "${DOC_WARN}" -gt 0 ]; then
        echo "  No blocking problems. ${DOC_WARN} warning(s) worth a look."
    else
        echo "  Everything checks out."
    fi
    echo "────────────────────────────────────────────────────────────"
    echo ""
    [ "${DOC_FAIL}" -gt 0 ] && return 1
    return 0
}

if [ "${DOCTOR}" = "true" ]; then
    LOCKFILE="/var/run/proxmox-autoupdate.lock"
    run_doctor
    exit $?
fi

# The reboot window updates nothing, so it runs before the preflight, the
# lockfile and the whole update machinery. It does need root — shutdown(8) does
# — and it must not fire while a real update run is still going, or it would
# take the host down mid-dpkg.
if [ "${REBOOT_WINDOW}" = "true" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "[!] FATAL: --reboot-window must run as root." >&2
        exit 1
    fi
    DRY_RUN="${CLI_DRY_RUN:-false}"
    if [ -e "${LOCKFILE:-/var/run/proxmox-autoupdate.lock}" ]        && command -v fuser >/dev/null 2>&1        && fuser "${LOCKFILE:-/var/run/proxmox-autoupdate.lock}" >/dev/null 2>&1; then
        echo "Reboot window: an update run is in progress — not rebooting."
        exit 0
    fi
    run_reboot_window
    exit $?
fi

# --- PREFLIGHT ---
# These checks come before the lockfile, because the lockfile itself needs root
# and a working flock. Getting them wrong produced a spectacularly misleading
# error: a non-root run failed to open the lockfile, then ran flock on an
# unopened descriptor, and reported "Another instance is already running."
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] FATAL: this must run as root (it drives pct, qm and apt)."
    echo "    Try:  sudo $0 $*"
    exit 1
fi

if ! command -v flock >/dev/null 2>&1; then
    echo "[!] FATAL: flock is required but not installed."
    echo "    Install it with:  apt-get install -y util-linux"
    exit 1
fi

# Refuse to run anywhere that is not a Proxmox VE node. Without this the guest
# loops simply found nothing, and the run reported a clean sweep of zero guests
# — the exact symptom of installing on plain Debian, on a Proxmox Backup Server,
# or inside a container on the host rather than on the host itself.
if [ "${PAU_SKIP_PVE_CHECK:-false}" != "true" ]; then
    if ! command -v pveversion >/dev/null 2>&1 || [ ! -d /etc/pve ]; then
        echo "[!] FATAL: this does not look like a Proxmox VE host."
        echo "    pveversion and /etc/pve are both required."
        echo "    Run this on the PVE host itself — not inside a VM or container."
        echo "    Set PAU_SKIP_PVE_CHECK=true to override."
        exit 1
    fi
    for PVE_TOOL in pct qm pvesh; do
        if ! command -v "${PVE_TOOL}" >/dev/null 2>&1; then
            echo "[!] FATAL: ${PVE_TOOL} not found on PATH."
            echo "    This is part of a normal Proxmox VE install; something is wrong."
            exit 1
        fi
    done
fi

# --- LOCKFILE (prevent concurrent runs) ---
LOCKFILE="/var/run/proxmox-autoupdate.lock"
if ! exec 200>"${LOCKFILE}"; then
    echo "[!] FATAL: could not open the lockfile ${LOCKFILE}"
    exit 1
fi
if ! flock -n 200; then
    echo "[!] Another instance of proxmox-autoupdate is already running. Exiting."
    echo "    Watch it:  journalctl -fu pve-autoupdate-run"
    echo "    If nothing is actually running, a previous run was killed; the lock"
    echo "    clears on its own once that process is gone."
    notify_fatal "A scheduled run was skipped: another instance still holds the lock on $(hostname -s 2>/dev/null || echo host)."
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
    # Bright black, not the faint attribute (\033[2m). xterm.js — which the
    # Proxmox web shell is built on — renders faint text at very low contrast on
    # a dark background, so every hint and detail line was close to invisible in
    # the terminal most of this output is actually read from.
    C_DIM='\033[90m'
    C_NC='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_DIM='' C_NC=''
fi

# Spinner / heartbeat state
_SPIN_PID=""
_HEARTBEAT_PID=""
_SPIN_MSG=""
_SPIN_START=""

# How often to report that a long operation is still going, in seconds. Set to
# 0 to turn the heartbeat off.
HEARTBEAT_SECS="${HEARTBEAT_SECS:-30}"

# Seconds as "3m 05s" / "1h 02m".
fmt_duration() {
    local s="${1:-0}"
    if [ "${s}" -lt 60 ]; then
        printf '%ds' "${s}"
    elif [ "${s}" -lt 3600 ]; then
        printf '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
    else
        printf '%dh %02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
    fi
}

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

    # Say what is being worked on, in the log, before anything else.
    #
    # The spinner writes to /dev/tty, so it is invisible to anything reading the
    # log — which is every run from the web panel and every run from cron. A
    # guest upgrade can legitimately take half an hour (LINUX_UPDATE_TIMEOUT
    # defaults to 1800s), and for all of that time the log said nothing at all.
    # A run that is working normally on a slow mirror was indistinguishable from
    # one that had hung.
    _SPIN_MSG="${msg}"
    _SPIN_START=$(date +%s)
    if [ "${_TTY_OK}" != true ]; then
        printf "  %s %s\n" "▶" "$(printf '%s' "${msg}" | sed 's/\x1b\[[0-9;]*m//g')"
    fi

    # Heartbeat. Prints elapsed time periodically so a long silent stretch is
    # visibly still alive, and so it is obvious afterwards *where* the time
    # went. Runs regardless of whether there is a terminal.
    (
        trap 'exit 0' TERM
        trap '' HUP
        local waited=0
        while true; do
            sleep "${HEARTBEAT_SECS}"
            waited=$(( waited + HEARTBEAT_SECS ))
            printf "      %s still working — %s elapsed\n" "…" "$(fmt_duration ${waited})" \
                2>/dev/null || exit 0
        done
    ) &
    _HEARTBEAT_PID=$!
    disown "$_HEARTBEAT_PID" 2>/dev/null

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
    if [ -n "${_HEARTBEAT_PID}" ]; then
        kill "${_HEARTBEAT_PID}" 2>/dev/null
        wait "${_HEARTBEAT_PID}" 2>/dev/null || true
        _HEARTBEAT_PID=""
    fi
    if [ -n "${_SPIN_PID}" ]; then
        kill "${_SPIN_PID}" 2>/dev/null
        wait "${_SPIN_PID}" 2>/dev/null || true
        _SPIN_PID=""
        [ "${_TTY_OK}" = true ] && { printf "\r\033[K" >&9 2>/dev/null || true; }
    fi
    # Report how long it actually took whenever it was long enough to have been
    # worth wondering about.
    if [ -n "${_SPIN_START}" ]; then
        local took=$(( $(date +%s) - _SPIN_START ))
        if [ "${took}" -ge "${HEARTBEAT_SECS}" ] && [ "${_TTY_OK}" != true ]; then
            printf "      %s took %s\n" "·" "$(fmt_duration ${took})"
        fi
        _SPIN_START=""
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

# CONFIG_FILE is set near the top, before the preflight checks, so that the
# early failure notifier can read it.

if [ ! -f "${CONFIG_FILE}" ]; then
    echo -e "${C_RED}[!] FATAL: Configuration file not found: ${CONFIG_FILE}${C_NC}"
    echo "    Run the installer to create it: curl -sSL https://raw.githubusercontent.com/Enhanced-Group/proxmox-autoupdate/main/install.sh | bash"
    exit 1
fi

# Refuse to source a config that bash cannot parse, rather than letting the
# error surface as an unbound-variable abort partway through the assignment
# block. Anything the panel or installer wrote is single-quoted, but a
# hand-edited file can still contain anything.
if ! bash -n "${CONFIG_FILE}" 2>/dev/null; then
    echo -e "${C_RED}[!] FATAL: ${CONFIG_FILE} is not valid shell and cannot be read.${C_NC}"
    bash -n "${CONFIG_FILE}" 2>&1 | head -n 3 | sed 's/^/    /'
    notify_fatal "The configuration file is not valid shell and could not be read. The scheduled run did not start."
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

# How email is sent: "mailgun" or "smtp".
#
# Left empty this infers the old behaviour — a Mailgun key means Mailgun —
# so existing installations are unaffected. SMTP exists because tying the only
# email path to one commercial provider is a poor default for a free tool: most
# people already have a relay, a mail server, or an app password.
EMAIL_TRANSPORT="${EMAIL_TRANSPORT:-}"
if [ -z "${EMAIL_TRANSPORT}" ]; then
    if [ -n "${MAILGUN_API_KEY}" ]; then EMAIL_TRANSPORT="mailgun"; else EMAIL_TRANSPORT="smtp"; fi
fi

SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
# starttls (default, port 587) | ssl (port 465) | none (unencrypted, local relay)
SMTP_SECURITY="${SMTP_SECURITY:-starttls}"

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
GENERIC_WEBHOOK_URL="${GENERIC_WEBHOOK_URL:-}"

# Microsoft Teams. A separate channel from Slack rather than a shared one: the
# Slack payload is Slack's own mrkdwn and Teams does not render it, so the old
# "Slack/Teams" label was simply wrong.
TEAMS_WEBHOOK_URL="${TEAMS_WEBHOOK_URL:-}"

# ntfy. The topic is part of the URL, e.g. https://ntfy.sh/my-topic.
NTFY_URL="${NTFY_URL:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
NTFY_PRIORITY="${NTFY_PRIORITY:-default}"

# Gotify. URL is the server root; the token is an application token.
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"

# Telegram bot.
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Discord direct message. With both of these set the report is DM'd to that user
# instead of posted to a channel; the webhook, if also configured, is kept as a
# fallback. The bot must share a server with the recipient for Discord to allow
# the DM at all.
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
DISCORD_USER_ID="${DISCORD_USER_ID:-}"

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
            # Two ways to send mail. EMAIL_TRANSPORT picks one; when it is
            # unset, having a Mailgun key implies mailgun and anything else
            # implies smtp, so existing installs keep working untouched.
            case "${EMAIL_TRANSPORT}" in
                smtp)
                    if [ -n "${SMTP_HOST}" ] && [ -n "${SENDER_EMAIL}" ] && [ -n "${RECIPIENT_EMAIL}" ]; then
                        NOTIFY_ACTIVE="${NOTIFY_ACTIVE} email"
                    else
                        NOTIFY_DISABLED="${NOTIFY_DISABLED} email(SMTP needs SMTP_HOST, SENDER_EMAIL and RECIPIENT_EMAIL)"
                    fi
                    ;;
                *)
                    if [ -n "${MAILGUN_API_KEY}" ] && [ -n "${MAILGUN_DOMAIN}" ] \
                       && [ -n "${SENDER_EMAIL}" ] && [ -n "${RECIPIENT_EMAIL}" ]; then
                        NOTIFY_ACTIVE="${NOTIFY_ACTIVE} email"
                    else
                        NOTIFY_DISABLED="${NOTIFY_DISABLED} email(incomplete Mailgun settings)"
                    fi
                    ;;
            esac
            ;;
        teams)
            if [ -n "${TEAMS_WEBHOOK_URL}" ]; then
                NOTIFY_ACTIVE="${NOTIFY_ACTIVE} teams"
            else
                NOTIFY_DISABLED="${NOTIFY_DISABLED} teams(no URL)"
            fi
            ;;
        ntfy)
            if [ -n "${NTFY_URL}" ]; then
                NOTIFY_ACTIVE="${NOTIFY_ACTIVE} ntfy"
            else
                NOTIFY_DISABLED="${NOTIFY_DISABLED} ntfy(no URL)"
            fi
            ;;
        gotify)
            if [ -n "${GOTIFY_URL}" ] && [ -n "${GOTIFY_TOKEN}" ]; then
                NOTIFY_ACTIVE="${NOTIFY_ACTIVE} gotify"
            else
                NOTIFY_DISABLED="${NOTIFY_DISABLED} gotify(needs URL and token)"
            fi
            ;;
        telegram)
            if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -n "${TELEGRAM_CHAT_ID}" ]; then
                NOTIFY_ACTIVE="${NOTIFY_ACTIVE} telegram"
            else
                NOTIFY_DISABLED="${NOTIFY_DISABLED} telegram(needs bot token and chat ID)"
            fi
            ;;
        discord)
            if [ -n "${DISCORD_WEBHOOK_URL}" ] \
               || { [ -n "${DISCORD_BOT_TOKEN}" ] && [ -n "${DISCORD_USER_ID}" ]; }; then
                NOTIFY_ACTIVE="${NOTIFY_ACTIVE} discord"
            elif [ -n "${DISCORD_BOT_TOKEN}" ]; then
                NOTIFY_DISABLED="${NOTIFY_DISABLED} discord(bot token set but no user ID)"
            elif [ -n "${DISCORD_USER_ID}" ]; then
                NOTIFY_DISABLED="${NOTIFY_DISABLED} discord(user ID set but no bot token)"
            else
                NOTIFY_DISABLED="${NOTIFY_DISABLED} discord(no webhook URL or bot DM)"
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
WINDOWS_UPDATE_TIMEOUT="${WINDOWS_UPDATE_TIMEOUT:-3600}"
START_STOPPED_WINDOWS="${START_STOPPED_WINDOWS:-false}"

# How long a Windows guest that this script started gets to shut itself down
# again, in seconds.
#
# Windows runs its servicing stack on shutdown ("Working on updates — do not
# turn off your computer"), which routinely takes far longer than an ACPI
# request normally would. This budget is never escalated to a forced stop: if
# the guest is still going when it expires, it is left running and reported.
WINDOWS_SHUTDOWN_TIMEOUT="${WINDOWS_SHUTDOWN_TIMEOUT:-900}"

# How long a Linux guest that this script started gets to shut down before it
# is forcibly stopped.
LINUX_SHUTDOWN_TIMEOUT="${LINUX_SHUTDOWN_TIMEOUT:-180}"
START_STOPPED_LXC="${START_STOPPED_LXC:-true}"
START_STOPPED_LINUX_VMS="${START_STOPPED_LINUX_VMS:-true}"
REBOOT_TIME="${REBOOT_TIME:-00:00}"

# How long a Linux guest (VM or LXC) gets to finish its upgrade, in seconds.
# A real dist-upgrade over a slow mirror routinely exceeds five minutes.
LINUX_UPDATE_TIMEOUT="${LINUX_UPDATE_TIMEOUT:-1800}"

# How long the guest-agent poll loop tolerates exec-status errors before it
# concludes the agent is gone. A guest that upgrades its own qemu-guest-agent
# restarts it mid-run, which drops the exec-pid table for a while.
AGENT_ERROR_GRACE="${AGENT_ERROR_GRACE:-120}"

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
# SNAPSHOT_KEEP and LOG_RETENTION_DAYS may legitimately be 0 ("keep none" /
# "keep forever"). The timeouts may not: `timeout 0` means *no limit*, while the
# guest-agent poll loop clamps to a single poll and declares an instant timeout
# — so the same 0 means opposite things on the two guest paths, and a host
# reboot would be suppressed forever by the resulting mid-update count.
for _NUM_VAR in WINDOWS_UPDATE_TIMEOUT LINUX_UPDATE_TIMEOUT APT_LOCK_TIMEOUT \
                WINDOWS_SHUTDOWN_TIMEOUT LINUX_SHUTDOWN_TIMEOUT; do
    if ! [[ "${!_NUM_VAR}" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${C_RED}[!] FATAL: ${_NUM_VAR} must be a positive integer (got '${!_NUM_VAR}')${C_NC}"
        notify_fatal "Configuration error: ${_NUM_VAR} must be a positive integer (got '${!_NUM_VAR}'). The scheduled run did not start."
        exit 1
    fi
done
for _NUM_VAR in SNAPSHOT_KEEP LOG_RETENTION_DAYS; do
    if ! [[ "${!_NUM_VAR}" =~ ^[0-9]+$ ]]; then
        echo -e "${C_RED}[!] FATAL: ${_NUM_VAR} must be a non-negative integer (got '${!_NUM_VAR}')${C_NC}"
        notify_fatal "Configuration error: ${_NUM_VAR} must be a non-negative integer (got '${!_NUM_VAR}'). The scheduled run did not start."
        exit 1
    fi
done


# REBOOT_TIME is used both to compute a delay and as a fallback argument to
# shutdown(8). A malformed value made `date -d` fail, which silently disabled
# the post-kernel-update reboot while the report still claimed one was booked.
if ! [[ "${REBOOT_TIME}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo -e "${C_RED}[!] FATAL: REBOOT_TIME must be HH:MM in 24-hour form (got '${REBOOT_TIME}')${C_NC}"
    notify_fatal "Configuration error: REBOOT_TIME must be HH:MM (got '${REBOOT_TIME}'). The scheduled run did not start."
    exit 1
fi

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
        notify_fatal "Missing dependency '${TOOL}' and it could not be installed automatically — probably because apt itself is failing. The scheduled run did not start."
        exit 1
    fi
done

# Summary counters
LXC_UPDATED=0
# A dry run finds pending packages; it does not update anything. Counting both
# in one variable made a dry run report "8 updated" when nothing was touched.
LXC_PENDING=0
LXC_CURRENT=0
LXC_STARTED=0
LXC_ERRORS=0
LXC_SKIPPED=0
LXC_EXCLUDED=0

VM_UPDATED=0
VM_PENDING=0
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
# Is a Proxmox `ostype` value one of the Windows ones?
#
# Proxmox uses: wxp w2k w2k3 w2k8 wvista win7 win8 win10 win11 for Windows, and
# l24 l26 solaris other for everything else. Matching on the substring "win"
# therefore missed wxp/w2k/w2k3/w2k8/wvista entirely, which meant those guests
# were treated as Linux and gated on START_STOPPED_LINUX_VMS (default true)
# rather than START_STOPPED_WINDOWS (default false) — so a config that
# explicitly refused to boot stopped Windows guests booted them anyway. Anchor
# on a leading "w", the same test the web UI patch already uses.
is_windows_ostype() {
    echo "${1:-}" | grep -qiE '^w'
}

# Classify a running guest. `ostype` from the VM config is authoritative when it
# is set to a Windows value: it is what the administrator declared, it is
# available without talking to the guest, and it cannot be spoofed by the guest.
# The agent probe is only used to refine "not declared Windows".
#
# Returns: windows | linux | unknown
#
# "unknown" matters. This used to fall back to "linux" whenever the probe failed
# or returned nothing, which sent Windows guests down the Linux path, where the
# exec of /bin/bash fails and the guest is reported as a generic agent error —
# and, more importantly, is never actually patched.
detect_vm_os() {
    local vmid="$1"
    local ostype=""
    ostype=$(config_field qm "${vmid}" ostype)
    if is_windows_ostype "${ostype}"; then
        echo "windows"
        return
    fi

    local os_info=""
    os_info=$(pvesh get "/nodes/${NODE_NAME}/qemu/${vmid}/agent/get-osinfo" \
        --output-format json 2>/dev/null) || true

    if [ -n "$os_info" ]; then
        # Match the machine-readable id field rather than grepping the whole
        # blob: "pretty-name":"Microsoft Azure Linux 3.0" is not Windows, but a
        # blob-wide search for "microsoft" said it was.
        local os_id=""
        os_id=$(echo "${os_info}" | jq -r '.id // empty' 2>/dev/null || true)
        if [ -n "${os_id}" ]; then
            case "${os_id}" in
                mswindows|windows) echo "windows"; return ;;
                *)                 echo "linux";   return ;;
            esac
        fi
        # No usable id — fall back to the old substring test on the name fields.
        if echo "$os_info" | grep -qi "mswindows"; then
            echo "windows"
            return
        fi
        echo "linux"
        return
    fi

    # The probe gave us nothing at all. Say so rather than guessing Linux.
    if [ -n "${ostype}" ] && [ "${ostype}" != "other" ]; then
        echo "linux"
        return
    fi
    echo "unknown"
}

# Return a VM that this script started back to its stopped state.
#
# The distinction that matters here is Windows. A Windows guest may be running
# its servicing stack — installing or rolling back updates — during shutdown,
# and cutting power at that point is the one action in this whole script that
# can leave a guest unbootable. So Windows gets a much longer budget and is
# *never* escalated to `qm stop`; if it will not stop in time it is left running
# and counted as mid-update, which also suppresses the host reboot.
#
# Linux guests keep the previous behaviour: ask, wait, then force.
restore_stopped_vm() {
    local vmid="$1" name="$2" ostype="${3:-linux}"

    if [ "${DRY_RUN}" = "true" ]; then
        print_skip "VM ${vmid} (${name}) — would be stopped again ${C_DIM}[dry run]${C_NC}"
        return 0
    fi

    print_stop "Stopping VM ${vmid} (${name}) ${C_DIM}[restoring state]${C_NC}..."
    qm shutdown "${vmid}" >/dev/null 2>&1 || true

    local budget="${LINUX_SHUTDOWN_TIMEOUT}"
    [ "${ostype}" = "windows" ] && budget="${WINDOWS_SHUTDOWN_TIMEOUT}"

    if wait_for_status "vm" "${vmid}" "stopped" "${budget}"; then
        return 0
    fi

    if [ "${ostype}" = "windows" ]; then
        print_warn "VM ${vmid} (${name}) — still shutting down after ${budget}s; left running to finish safely"
        GUESTS_MID_UPDATE=$((GUESTS_MID_UPDATE + 1))
        return 1
    fi

    print_warn "VM ${vmid} (${name}) — ACPI shutdown timeout, forcing stop..."
    qm stop "${vmid}" >/dev/null 2>&1 || true
    return 1
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
# Everything is read from stdin by /bin/sh, so each command gets </dev/null to
# stop apt from swallowing the rest of this script off the shared stdin.
#
# This body must stay POSIX: it is executed with /bin/sh, which is dash on
# Debian and BusyBox ash on Alpine. It was previously piped into /bin/bash,
# which Alpine does not ship at all — so every Alpine guest failed its exec,
# reported "update did not report a result", and accumulated a permanent
# failure streak, while the apk branch below was unreachable. Nothing here
# needs bash. `sh -n` over the generated output is enforced in CI.
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
# A fixed fallback path is a hazard in a container: any local user can
# pre-create it, and this runs as root. $$ makes it unpredictable, and the
# umask keeps it private if mktemp is genuinely missing.
WORK_LOG=\$(mktemp 2>/dev/null || { umask 077; echo "/tmp/.pau_log.\$\$"; })

emit_log() { tail -n 20 "\${WORK_LOG}" 2>/dev/null | sed 's/^/__LOG__ /' || true; }

# Package name -> "old -> new" from \`apt list --upgradable\` output.
#
# LC_ALL=C because the caller parses the literal English string
# "upgradable from:" out of this; under any other locale apt translates it and
# the old-version column is silently lost.
#
# Sets LIST_RC so the caller can tell "nothing to upgrade" from "apt failed" —
# both of which produce empty output.
LIST_RC=0
list_upgradable() {
    _lu_out=\$(LC_ALL=C apt list --upgradable 2>/dev/null)
    LIST_RC=\$?
    echo "\${_lu_out}" | grep '/' || true
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

# Report a container runtime if one is present.
#
# This runs *before* the package managers, not after. Every branch below ends
# in `exit 0` — that is how the sentinel protocol works — so anything placed
# after them is unreachable on every successful path, which is exactly what
# happened: a Docker host with nothing to upgrade reported "already up to date"
# and never mentioned its containers at all.
#
# The tool updates the guest's own packages and nothing inside its containers,
# so on a Docker or Podman host "already up to date" is true of apt and silent
# about the images actually running the services. Reporting it stops a green
# tick implying something it does not mean. It deliberately does not pull or
# restart anything: that needs compose files and restart ordering, and can take
# a stack down in ways apt never will.
#
# Each probe is time-boxed. \`docker ps\` talks to a daemon that may be wedged
# or starting, and this must never be the reason a guest update hangs.
for RUNTIME in docker podman; do
    command -v "\${RUNTIME}" >/dev/null 2>&1 || continue
    RUNNING=\$(timeout 10 "\${RUNTIME}" ps -q 2>/dev/null | grep -c . || echo 0)
    [ "\${RUNNING}" -gt 0 ] && echo "__CONTAINERS__ \${RUNTIME} \${RUNNING}"
done

if command -v apt-get >/dev/null 2>&1; then
    # The guest may have only just booted, so DNS and routing can lag behind the
    # guest agent coming up. Retry rather than reporting a hard failure.
    UPDATE_RC=1
    ATTEMPT=1
    _T_START=\$(date +%s 2>/dev/null || echo 0)
    while [ \${ATTEMPT} -le 5 ]; do
        # Capture the status directly from apt-get. Assigning \$? on the line
        # after the closing \`fi\` read the exit status of the *if compound*
        # instead, and an \`if\` whose condition is false with no \`else\` exits 0
        # — so UPDATE_RC was always 0, the FAIL branch below was unreachable,
        # and a guest that could not reach its mirrors at all reported success
        # with zero packages.
        apt-get \${APT_OPTS} update -qy </dev/null >"\${WORK_LOG}" 2>&1
        UPDATE_RC=\$?
        [ \${UPDATE_RC} -eq 0 ] && break
        ATTEMPT=\$((ATTEMPT + 1))
        [ \${ATTEMPT} -le 5 ] && sleep 5
    done
    # Report how long the refresh took, and how many attempts it needed.
    #
    # Output only comes back when the exec finishes, so this cannot be shown
    # live — but it is the difference between "that guest took twelve minutes"
    # and "eleven and a half of those minutes were apt-get update", which is
    # the part that identifies a slow mirror or a contended host.
    _T_END=\$(date +%s 2>/dev/null || echo 0)
    if [ "\${_T_START}" -gt 0 ] && [ "\${_T_END}" -ge "\${_T_START}" ]; then
        echo "__TIMING__ refresh \$(( _T_END - _T_START )) \${ATTEMPT}"
    fi

    if [ \${UPDATE_RC} -ne 0 ]; then
        echo "__RESULT__ FAIL"
        echo "__DETAIL__ apt-get update failed after 5 attempts (exit \${UPDATE_RC})"
        emit_log
        exit 0
    fi

    BEFORE=\$(list_upgradable)

    # An empty list means "nothing to upgrade" only if apt actually succeeded.
    if [ \${LIST_RC} -ne 0 ]; then
        echo "__RESULT__ FAIL"
        echo "__DETAIL__ apt list --upgradable failed (exit \${LIST_RC}) — package state unknown"
        emit_log
        exit 0
    fi

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

elif command -v zypper >/dev/null 2>&1; then
    # openSUSE / SLES. --non-interactive is essential: zypper otherwise stops to
    # ask about licences and vendor changes and would sit there until the
    # guest-agent timeout killed it.
    zypper --non-interactive refresh -q </dev/null >/dev/null 2>&1 || true
    # Start at the table's separator rather than a fixed line number: zypper
    # prints a variable number of "Loading repository data..." lines first, so
    # skipping a fixed count found nothing on some hosts and everything on
    # others.
    zypper --non-interactive list-updates 2>/dev/null \\
        | awk -F'|' '/^-+\\+/ {t=1; next}
                     t && NF>=5 {gsub(/^[ \\t]+|[ \\t]+\$/,"",\$3); if (\$3 != "") print "__PKG__ " \$3}' || true
    if [ "\${DRY_RUN}" = "true" ]; then
        echo "__RESULT__ OK"
    else
        zypper --non-interactive update -y -l </dev/null >"\${WORK_LOG}" 2>&1
        ZRC=\$?
        # 0 = done, 100 = updates applied, 101 = applied and a reboot is advised.
        # Anything else is a real failure.
        if [ \${ZRC} -eq 0 ] || [ \${ZRC} -eq 100 ] || [ \${ZRC} -eq 101 ]; then
            echo "__RESULT__ OK"
        else
            echo "__RESULT__ FAIL"
            echo "__DETAIL__ zypper update failed (exit \${ZRC})"
            emit_log
        fi
    fi

elif command -v pacman >/dev/null 2>&1; then
    # Arch. Refresh and upgrade are one operation here; a partial upgrade is
    # explicitly unsupported upstream, so -Sy on its own is never done.
    pacman -Sy --noconfirm </dev/null >/dev/null 2>&1 || true
    pacman -Qu 2>/dev/null | awk '{print "__PKG__ " \$1}' || true
    if [ "\${DRY_RUN}" = "true" ]; then
        echo "__RESULT__ OK"
    elif pacman -Su --noconfirm </dev/null >"\${WORK_LOG}" 2>&1; then
        echo "__RESULT__ OK"
    else
        echo "__RESULT__ FAIL"
        echo "__DETAIL__ pacman -Su failed"
        emit_log
    fi

else
    echo "__RESULT__ UNSUPPORTED"
    echo "__DETAIL__ no supported package manager found (looked for apt-get, dnf, yum, apk, zypper, pacman)"
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
    GX_SIGNAL=""
    GX_OUT=""
    GX_ERR=""

    # Budget against the wall clock, not against a poll count.
    #
    # This used to be max_polls = timeout / poll_interval, which charged only
    # the sleeps and never the pvesh round-trip. With a 1800s setting and a
    # ~0.5-1.5s API call per poll the real budget was closer to 2000-2300s, so
    # the configured timeout did not mean what it said — and it meant something
    # different again on the LXC path, which uses a real timeout(1).
    local deadline=$(( $(date +%s) + timeout ))
    local consecutive_failures=0
    local first_failure_at=0
    local parse_failures=0

    while [ "$(date +%s)" -lt "${deadline}" ]; do
        local exec_status=""
        if ! exec_status=$(pvesh get "/nodes/${NODE_NAME}/qemu/${vmid}/agent/exec-status" \
                --pid "${exec_pid}" --output-format json 2>/dev/null); then
            # A hiccup on the API or the agent socket is not a failed update.
            #
            # Three consecutive misses was about fifteen seconds, which is far
            # too little: a Linux guest upgrading its own qemu-guest-agent
            # restarts the agent mid-run and drops the exec-pid table, and any
            # brief pvedaemon stall looks identical. Giving up here marks the
            # guest mid-update, which also cancels the host's kernel reboot for
            # the night. Tolerate it for a couple of minutes, and confirm with a
            # ping before declaring the agent gone.
            consecutive_failures=$((consecutive_failures + 1))
            [ "${first_failure_at}" -eq 0 ] && first_failure_at=$(date +%s)
            if [ $(( $(date +%s) - first_failure_at )) -ge "${AGENT_ERROR_GRACE}" ]; then
                if ! qm agent "${vmid}" ping >/dev/null 2>&1; then
                    GX_STATE="apierror"
                    return
                fi
                # Agent is alive; the exec record is what we lost. Keep waiting.
                first_failure_at=$(date +%s)
            fi
            sleep "${poll_interval}"
            continue
        fi
        consecutive_failures=0
        first_failure_at=0

        # A reply that isn't JSON will never become JSON on a later poll — it
        # means --output-format json isn't being honoured. Fail fast and say so,
        # rather than silently burning the whole timeout and reporting a bogus
        # "timed out" for an update that actually ran.
        # An empty reply is a parse failure too. jq exits 0 on empty input and
        # prints nothing, so `exited` came back empty, the case below matched
        # nothing, and the loop burned the entire timeout before reporting a
        # bogus "timed out" — exactly what the comment above says it avoids.
        local exited=""
        if [ -z "${exec_status}" ] || \
           ! exited=$(echo "${exec_status}" | jq -re '.exited' 2>/dev/null); then
            parse_failures=$((parse_failures + 1))
            if [ ${parse_failures} -ge 2 ]; then
                GX_STATE="badjson"
                GX_OUT="${exec_status}"
                return
            fi
            sleep "${poll_interval}"
            continue
        fi

        case "${exited}" in
            1|true)
                GX_EXITCODE=$(echo "${exec_status}" | jq -r '.exitcode // empty' 2>/dev/null || true)
                # A process killed by a signal reports `signal`, not `exitcode`.
                # Defaulting to 0 hid that entirely, so an OOM-killed upgrade
                # looked like a clean exit.
                GX_SIGNAL=$(echo "${exec_status}" | jq -r '.signal // empty' 2>/dev/null || true)
                if [ -z "${GX_EXITCODE}" ]; then
                    if [ -n "${GX_SIGNAL}" ]; then
                        GX_EXITCODE="signal:${GX_SIGNAL}"
                    else
                        GX_EXITCODE="0"
                    fi
                fi
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

        sleep "${poll_interval}"
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
    # A dry run records what is pending, not what was installed, so the panel's
    # history does not show counts for work that never happened.
    local rec_lxc="${LXC_UPDATED}" rec_vm="${VM_UPDATED}"
    if [ "${DRY_RUN}" = "true" ]; then
        rec_lxc="${LXC_PENDING}"
        rec_vm="${VM_PENDING}"
    fi
    counts=$(printf '{"lxc_updated":%d,"lxc_errors":%d,"vm_updated":%d,"vm_errors":%d,"host_packages":%d,"mid_update":%d}' \
        "${rec_lxc}" "${LXC_ERRORS}" "${rec_vm}" "${VM_ERRORS}" \
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

# >>> PAU-NOTIFIER-BEGIN
# Everything between these markers is lifted verbatim by the web panel's "Send
# test notification", so that a test exercises the real notifier rather than a
# copy of it. Keep the whole notifier inside them: a helper left outside is not
# a compile error, it is a function that is simply missing at run time.
#
# ci/invariants.sh enforces that every function the panel requires is in here.

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
    if [ "${DRY_RUN}" = "true" ]; then
        printf 'LXC:  %s with updates pending, %s current, %s errors\n' "${LXC_PENDING}" "${LXC_CURRENT}" "${LXC_ERRORS}"
        printf 'VMs:  %s with updates pending, %s current, %s errors\n' "${VM_PENDING}" "${VM_CURRENT}" "${VM_ERRORS}"
    else
        printf 'LXC:  %s updated, %s current, %s errors\n' "${LXC_UPDATED}" "${LXC_CURRENT}" "${LXC_ERRORS}"
        printf 'VMs:  %s updated, %s current, %s errors\n' "${VM_UPDATED}" "${VM_CURRENT}" "${VM_ERRORS}"
    fi
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


# ---- Keeping credentials out of the process list ----
# A process's full command line is readable from /proc by any local user, so an
# argument is not a safe place for a secret. Webhook URLs are credentials in
# their own right — anyone holding one can post to that channel — as are the
# Mailgun key and the Discord bot token.
#
# curl reads options from a config file, and `--config -` reads that from
# stdin, which never appears in `ps`. Each caller emits its URL and any auth
# header this way instead of passing them as arguments.

# Escape a value for a curl config double-quoted string.
cfg_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Usage: curl_cfg <url> [extra directive ...]
curl_cfg() {
    printf 'url = "%s"\n' "$(cfg_escape "$1")"
    shift
    local directive
    for directive in "$@"; do
        printf '%s\n' "${directive}"
    done
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
    # Discord validates these strictly and answers a bare 400 when they are
    # wrong: the description caps at 4096, the title at 256, and an embed
    # footer with empty text is rejected outright rather than ignored.
    text = body[:3900] or "(no output)"
    if len(body) > 3900:
        text += "\n… truncated, see the attached log for the rest"
    colour = 9807270 if dry else (15158332 if failed else 3066993)
    embed = {
        "title": (subject[:256] or "Proxmox Auto-Update"),
        "description": "```\n" + text + "\n```",
        "color": colour,
    }
    # Join only the parts that exist, so an unset host or timestamp cannot
    # leave a lone separator as the footer text.
    footer = " · ".join(p for p in (os.environ.get("PAU_HOST", "").strip(),
                                    os.environ.get("PAU_TIMESTAMP", "").strip()) if p)
    if footer:
        embed["footer"] = {"text": footer[:2048]}
    payload = {"embeds": [embed]}
elif fmt == "slack":
    text = body[:3500]
    if len(body) > 3500:
        text += "\n… truncated, see the log for the rest"
    payload = {"text": "*" + subject + "*\n```" + text + "```"}
elif fmt == "teams":
    # Teams does not render Slack mrkdwn, which is what it was previously being
    # sent. A MessageCard is understood both by the legacy Office 365 connector
    # webhooks and by the "when a Teams webhook request is received" trigger in
    # Power Automate, which is what new webhooks create.
    text = body[:6000]
    if len(body) > 6000:
        text += "\n… truncated, see the log for the rest"
    colour = "7A5FBF" if dry else ("D93025" if failed else "2E9E4F")
    facts = [
        {"name": "Host", "value": os.environ.get("PAU_HOST", "") or "unknown"},
        {"name": "Proxmox", "value": os.environ.get("PAU_PVE", "") or "unknown"},
        {"name": "Containers", "value": "%s updated, %s errors"
            % (os.environ.get("PAU_LXC_UPDATED", "0"), os.environ.get("PAU_LXC_ERRORS", "0"))},
        {"name": "VMs", "value": "%s updated, %s errors"
            % (os.environ.get("PAU_VM_UPDATED", "0"), os.environ.get("PAU_VM_ERRORS", "0"))},
        {"name": "Host packages", "value": os.environ.get("PAU_HOST_PKGS", "0")},
    ]
    if os.environ.get("PAU_REBOOT") == "true":
        facts.append({"name": "Reboot", "value": "scheduled"})
    if os.environ.get("PAU_OFFENDERS", "").strip():
        facts.append({"name": "Failing repeatedly", "value": os.environ["PAU_OFFENDERS"]})
    payload = {
        "@type": "MessageCard",
        "@context": "https://schema.org/extensions",
        "summary": subject[:250] or "Proxmox Auto-Update",
        "themeColor": colour,
        "title": subject[:250] or "Proxmox Auto-Update",
        "sections": [{
            "facts": facts,
            # Teams collapses runs of whitespace, so the report is sent as a
            # preformatted block rather than as loose text.
            "text": "<pre>" + (text or "(no output)")
                    .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;") + "</pre>",
        }],
    }
elif fmt == "gotify":
    text = body[:4000]
    if len(body) > 4000:
        text += "\n… truncated, see the log for the rest"
    payload = {
        "title": subject[:250] or "Proxmox Auto-Update",
        "message": text or "(no output)",
        # Gotify priorities: 0-3 quiet, 4-7 normal, 8+ pops up.
        "priority": 8 if failed else 4,
        "extras": {"client::display": {"contentType": "text/plain"}},
    }
elif fmt == "telegram":
    # Telegram caps a message at 4096 characters including the markup.
    text = body[:3600]
    if len(body) > 3600:
        text += "\n… truncated, see the log for the rest"
    payload = {
        "chat_id": os.environ.get("PAU_TELEGRAM_CHAT", ""),
        "text": "*" + subject.replace("*", "") + "*\n```\n" + (text or "(no output)") + "\n```",
        "parse_mode": "Markdown",
        "disable_web_page_preview": True,
    }
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
               PAU_LXC_ERRORS PAU_VM_UPDATED PAU_VM_ERRORS PAU_HOST_PKGS \
               PAU_TELEGRAM_CHAT
        PAU_TELEGRAM_CHAT="${TELEGRAM_CHAT_ID:-}"
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
    local label="$1" url="$2" payload="$3" extra_header="${4:-}" hide_url="${5:-}"
    local code
    # The URL goes in via --config, not argv, so credentials embedded in it stay
    # out of the process list. Same for any extra header.
    code=$( { curl_cfg "${url}"
              [ -n "${extra_header}" ] && printf 'header = "%s"\n' "$(cfg_escape "${extra_header}")"
              true; } \
        | curl -s --config - --max-time 30 \
        -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -X POST --data-binary "${payload}" 2>/dev/null) || code="000"
    if [ "${code}" -ge 200 ] 2>/dev/null && [ "${code}" -lt 300 ] 2>/dev/null; then
        print_ok "${label} notified"
    elif [ "${code}" = "000" ]; then
        print_fail "${label} unreachable (network error or timeout)"
        [ "${hide_url}" = "hide-url" ] || print_fail "  ${url}"
    else
        print_fail "${label} returned HTTP ${code}"
    fi
}

# Send the report over SMTP.
#
# Credentials arrive as environment variables rather than on the command line,
# so they never appear in /proc/<pid>/cmdline. The HTML report and the plain
# text are both attached, so a client that refuses HTML still shows something
# readable.
SMTP_HELPER='
import os, smtplib, ssl, sys
from email.message import EmailMessage

subject, html_path = sys.argv[1], sys.argv[2]
text_body = sys.stdin.read()

msg = EmailMessage()
msg["Subject"] = subject
msg["From"] = os.environ["PAU_SMTP_FROM"]
msg["To"] = os.environ["PAU_SMTP_TO"]
msg.set_content(text_body or "(no output)")
if html_path and os.path.isfile(html_path):
    try:
        with open(html_path, encoding="utf-8", errors="replace") as fh:
            msg.add_alternative(fh.read(), subtype="html")
    except OSError:
        pass

host = os.environ["PAU_SMTP_HOST"]
port = int(os.environ.get("PAU_SMTP_PORT") or 587)
user = os.environ.get("PAU_SMTP_USER") or ""
password = os.environ.get("PAU_SMTP_PASSWORD") or ""
security = (os.environ.get("PAU_SMTP_SECURITY") or "starttls").lower()

try:
    if security == "ssl":
        server = smtplib.SMTP_SSL(host, port, timeout=45,
                                  context=ssl.create_default_context())
    else:
        server = smtplib.SMTP(host, port, timeout=45)
    with server:
        server.ehlo()
        if security == "starttls":
            server.starttls(context=ssl.create_default_context())
            server.ehlo()
        if user:
            server.login(user, password)
        server.send_message(msg)
except Exception as exc:
    sys.stderr.write("%s: %s\n" % (type(exc).__name__, exc))
    sys.exit(1)
'

notify_email_smtp() {
    local subject="$1" body="$2" html_file="$3"
    local err
    err=$(
        export PAU_SMTP_HOST="${SMTP_HOST}" PAU_SMTP_PORT="${SMTP_PORT}" \
               PAU_SMTP_USER="${SMTP_USER}" PAU_SMTP_PASSWORD="${SMTP_PASSWORD}" \
               PAU_SMTP_SECURITY="${SMTP_SECURITY}" \
               PAU_SMTP_FROM="${SENDER_EMAIL}" PAU_SMTP_TO="${RECIPIENT_EMAIL}"
        printf '%s' "${body}" | python3 -c "${SMTP_HELPER}" "${subject}" "${html_file}" 2>&1 >/dev/null
    ) && {
        print_ok "Email sent to ${C_BOLD}${RECIPIENT_EMAIL}${C_NC} ${C_DIM}(SMTP ${SMTP_HOST}:${SMTP_PORT})${C_NC}"
        return 0
    }
    print_fail "SMTP send failed: ${err}"
    return 1
}

notify_email() {
    if [ "${EMAIL_TRANSPORT}" = "smtp" ]; then
        notify_email_smtp "$@"
        return
    fi
    notify_email_mailgun "$@"
}

notify_email_mailgun() {
    local subject="$1" html_file="$3"
    NOTIFY_RESPONSE_FILE="/tmp/notify_response_$$.txt"
    local code
    # API key goes in via stdin, not --user, so it stays out of `ps`.
    code=$(curl_cfg "${MAILGUN_API_URL}" "user = \"api:$(cfg_escape "${MAILGUN_API_KEY}")\"" \
        | curl -s --config - --max-time 60 \
            -o "${NOTIFY_RESPONSE_FILE}" -w "%{http_code}" \
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

# Discord truncates hard: 2000 characters of content, 4096 in an embed. A real
# run's log is far bigger than that, so the summary goes in the embed and the
# files are attached.
#
# The upload ceiling depends on the server's boost tier and Discord has changed
# the free-tier figure more than once, so this is configurable rather than a
# constant someone has to edit the script to change. The default leaves room
# for multipart overhead under the smallest tier. Anything larger is split
# across several messages rather than silently dropped.
DISCORD_MAX_UPLOAD="${DISCORD_MAX_UPLOAD:-$((8 * 1024 * 1024))}"

# Attach the HTML report as well as the plain log ("true" or "false").
#
# Discord will not render it inline — it arrives as a file you download and
# open — but it is the same report the email channel sends, with the per-guest
# package lists formatted, which the plain text summary cannot show.
DISCORD_ATTACH_REPORT="${DISCORD_ATTACH_REPORT:-true}"

# Discord can be reached two ways:
#   webhook  — post straight to a channel URL, no auth header
#   bot DM   — open a DM channel with the bot token, then post to that channel
#
# The bot never runs as a process. There is no gateway/websocket connection and
# nothing stays logged in: the token is only ever an Authorization header on two
# ordinary HTTPS POSTs, made when a report is sent and not otherwise. Nothing
# here keeps the bot online or listening.
#
# A bot token plus a user ID takes precedence, because someone who has
# configured a DM has asked for a DM. Both paths end up posting the same
# multipart body, so only the URL and the auth header differ.
#
# Sets DISCORD_TARGET_URL and DISCORD_TARGET_AUTH; returns 1 if neither is
# usable. The DM channel is resolved once per run and reused.
DISCORD_TARGET_URL=""
DISCORD_TARGET_AUTH=""
DISCORD_TARGET_READY=""

discord_resolve_target() {
    [ -n "${DISCORD_TARGET_READY}" ] && return "${DISCORD_TARGET_READY}"

    if [ -n "${DISCORD_BOT_TOKEN}" ] && [ -n "${DISCORD_USER_ID}" ]; then
        # Tokens are commonly pasted straight out of the developer portal with
        # the "Bot " prefix already attached, which would produce "Bot Bot ...".
        local token="${DISCORD_BOT_TOKEN#Bot }"
        token="${token# }"

        if ! echo "${DISCORD_USER_ID}" | grep -qE '^[0-9]{15,25}$'; then
            print_fail "Discord: DISCORD_USER_ID must be a numeric user ID, not a username"
            echo "     ${C_DIM}Enable Developer Mode in Discord, right-click yourself, Copy User ID.${C_NC}"
            DISCORD_TARGET_READY=1
            return 1
        fi

        local resp channel
        resp=$(curl_cfg "https://discord.com/api/v10/users/@me/channels" \
                "header = \"Authorization: Bot $(cfg_escape "${token}")\"" \
            | curl -s --config - --max-time 30 -X POST \
                -H "Content-Type: application/json" \
                -d "{\"recipient_id\":\"${DISCORD_USER_ID}\"}" 2>/dev/null) || resp=""
        channel=$(printf '%s' "${resp}" | jq -r '.id // empty' 2>/dev/null || true)
        DISCORD_BOT_TOKEN="${token}"

        if [ -n "${channel}" ]; then
            DISCORD_TARGET_URL="https://discord.com/api/v10/channels/${channel}/messages"
            DISCORD_TARGET_AUTH="Authorization: Bot ${DISCORD_BOT_TOKEN}"
            DISCORD_TARGET_READY=0
            return 0
        fi

        # Report exactly what Discord said. "400" on its own is not something
        # anyone can act on; the message and code identify the problem.
        local why code_num details
        why=$(printf '%s' "${resp}" | jq -r '.message // empty' 2>/dev/null || true)
        code_num=$(printf '%s' "${resp}" | jq -r '.code // empty' 2>/dev/null || true)
        details=$(printf '%s' "${resp}" \
            | jq -r '[(.errors // {}) | paths(scalars) as $p | "\($p|map(tostring)|join(".")): \(getpath($p))"] | join("; ")' \
              2>/dev/null || true)

        print_fail "Discord DM unavailable${why:+ — ${why}}${code_num:+ (code ${code_num})}"
        [ -n "${details}" ] && echo "     ${C_DIM}${details}${C_NC}"
        case "${code_num}" in
            50007) echo "     ${C_DIM}That user does not accept DMs from this bot. The bot must share a${C_NC}"
                   echo "     ${C_DIM}server with you, and your privacy settings must allow server DMs.${C_NC}" ;;
            0|"")  [ -z "${why}" ] && echo "     ${C_DIM}No response from Discord — check network access.${C_NC}" ;;
            *)     echo "     ${C_DIM}Check the bot token is a *bot* token, and the user ID is your own.${C_NC}" ;;
        esac
        [ -n "${resp}" ] && echo "     ${C_DIM}Raw: $(printf '%s' "${resp}" | head -c 240)${C_NC}"

        # Fall back to the webhook rather than losing the report entirely.
        if [ -n "${DISCORD_WEBHOOK_URL}" ]; then
            print_warn "Falling back to the Discord webhook"
            DISCORD_TARGET_URL="${DISCORD_WEBHOOK_URL}"
            DISCORD_TARGET_AUTH=""
            DISCORD_TARGET_READY=0
            return 0
        fi
        DISCORD_TARGET_READY=1
        return 1
    fi

    if [ -n "${DISCORD_WEBHOOK_URL}" ]; then
        DISCORD_TARGET_URL="${DISCORD_WEBHOOK_URL}"
        DISCORD_TARGET_AUTH=""
        DISCORD_TARGET_READY=0
        return 0
    fi
    DISCORD_TARGET_READY=1
    return 1
}

# Emits the curl config for the resolved target: the URL always, plus the bot
# Authorization header when talking to the API. Read by curl from stdin so
# neither the webhook URL nor the token is ever an argument.
discord_cfg() {
    if [ -n "${DISCORD_TARGET_AUTH}" ]; then
        curl_cfg "${DISCORD_TARGET_URL}" \
            "header = \"$(cfg_escape "${DISCORD_TARGET_AUTH}")\""
    else
        curl_cfg "${DISCORD_TARGET_URL}"
    fi
}

# Perform a Discord request, honouring rate limits.
#
# Discord allows roughly five requests per two seconds per webhook and answers
# 429 with a `retry_after` telling you exactly how long to wait. None of that
# was handled: a 429 was reported as a generic HTTP failure and the message was
# simply lost. Sending a multi-part log made it likely rather than theoretical,
# because every part is another request.
#
# Sets DISCORD_HTTP and leaves the response body in DISCORD_BODY.
DISCORD_HTTP=""
DISCORD_BODY=""
discord_request() {
    local attempt=0 max_attempts=4 wait
    DISCORD_BODY=$(mktemp)
    while :; do
        attempt=$((attempt + 1))
        DISCORD_HTTP=$(discord_cfg | curl -s --config - --max-time 180 \
            -o "${DISCORD_BODY}" -w "%{http_code}" "$@" 2>/dev/null) || DISCORD_HTTP="000"

        [ "${DISCORD_HTTP}" = "429" ] || break
        [ "${attempt}" -ge "${max_attempts}" ] && break

        # retry_after is seconds, fractional, in the JSON body. Clamp it: a long
        # rate limit should not stall the whole run, and a malformed value must
        # not turn into an unbounded sleep.
        wait=$(jq -r '.retry_after // empty' "${DISCORD_BODY}" 2>/dev/null || true)
        case "${wait}" in
            ''|*[!0-9.]*) wait="2" ;;
        esac
        awk -v w="${wait}" 'BEGIN { exit !(w > 30) }' && wait="30"
        print_warn "Discord rate limited — waiting ${wait}s (attempt ${attempt}/${max_attempts})"
        sleep "${wait}"
    done
    return 0
}

# Attach the HTML report.
#
# Unlike the log this is never split: half an HTML document is not a document,
# and a browser shown one renders whatever it can and silently drops the rest —
# worse than not sending it. Over the limit it is skipped with a reason.
discord_attach_report() {
    [ "${DISCORD_ATTACH_REPORT}" = "true" ] || return 0
    [ -s "${HTML_FILE}" ] || return 0

    local size
    size=$(wc -c < "${HTML_FILE}" 2>/dev/null || echo 0)
    if [ "${size}" -gt "${DISCORD_MAX_UPLOAD}" ]; then
        print_warn "Discord: HTML report is ${size} bytes, over the ${DISCORD_MAX_UPLOAD} limit — not attached"
        print_warn "  The summary above still covers it; raise DISCORD_MAX_UPLOAD if your server allows it."
        return 0
    fi

    local named
    named="$(dirname "${HTML_FILE}")/proxmox-update-report-$(date +%Y%m%d-%H%M%S).html"
    cp -f "${HTML_FILE}" "${named}" 2>/dev/null || return 0

    discord_request \
        -F "payload_json={\"content\":\"Full report\"}" \
        -F "files[0]=@${named};type=text/html"
    case "${DISCORD_HTTP}" in
        200|204) print_ok "Discord report attached" ;;
        413)     print_warn "Discord rejected the report as too large (${size} bytes)" ;;
        *)       print_warn "Discord report upload returned HTTP ${DISCORD_HTTP}" ;;
    esac
    rm -f "${DISCORD_BODY}" "${named}"
}

discord_attach_log() {
    [ "${KEEP_LOGS}" = "true" ] || return 0
    [ -s "${LOG_FILE}" ] || return 0

    # The log is still being written by the tee, so snapshot it, and strip the
    # ANSI escapes so the attachment reads cleanly in Discord's viewer.
    local workdir
    workdir=$(mktemp -d) || return 0
    local flat="${workdir}/$(basename "${LOG_FILE}" .log).log"
    sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\r$//' "${LOG_FILE}" > "${flat}" 2>/dev/null || {
        rm -rf "${workdir}"; return 0
    }

    local size
    size=$(wc -c < "${flat}" 2>/dev/null || echo 0)

    if [ "${size}" -le "${DISCORD_MAX_UPLOAD}" ]; then
        discord_request \
            -F "payload_json={\"content\":\"Full log\"}" \
            -F "files[0]=@${flat};type=text/plain"
        case "${DISCORD_HTTP}" in
            200|204) print_ok "Discord log attached" ;;
            413)     print_warn "Discord rejected the log as too large (${size} bytes)."
                     print_warn "  Lower DISCORD_MAX_UPLOAD so it is split into smaller parts." ;;
            *)       print_warn "Discord log upload returned HTTP ${DISCORD_HTTP}" ;;
        esac
        rm -f "${DISCORD_BODY}"
        rm -rf "${workdir}"
        return 0
    fi

    # Too big for one message: split on line boundaries so each part is readable
    # on its own, then send them in order.
    local base="${workdir}/part"
    split -C "${DISCORD_MAX_UPLOAD}" -d -a 3 "${flat}" "${base}." 2>/dev/null || {
        print_warn "Could not split the log for Discord (${size} bytes) — skipping attachment"
        rm -rf "${workdir}"
        return 0
    }

    local parts total index=0
    parts=$(find "${workdir}" -name 'part.*' | sort)
    total=$(echo "${parts}" | grep -c . || echo 0)
    local failed=0
    local part
    while IFS= read -r part; do
        [ -z "${part}" ] && continue
        index=$((index + 1))
        local named="${workdir}/$(basename "${LOG_FILE}" .log).part${index}of${total}.log"
        mv "${part}" "${named}"
        discord_request \
            -F "payload_json={\"content\":\"Full log — part ${index} of ${total}\"}" \
            -F "files[0]=@${named};type=text/plain"
        case "${DISCORD_HTTP}" in
            200|204) ;;
            *) failed=$((failed + 1))
               print_warn "  part ${index}/${total} returned HTTP ${DISCORD_HTTP}" ;;
        esac
        rm -f "${DISCORD_BODY}"
        # Pace the remaining parts. discord_request backs off when Discord says
        # 429; this keeps us under the limit rather than relying on hitting it.
        [ "${index}" -lt "${total}" ] && sleep 1
    done <<< "${parts}"

    if [ "${failed}" -eq 0 ]; then
        print_ok "Discord log attached in ${total} part(s)"
    else
        print_warn "Discord log: ${failed} of ${total} part(s) failed to upload"
    fi
    rm -rf "${workdir}"
}

notify_discord() {
    if ! discord_resolve_target; then
        print_fail "Discord: no usable webhook or bot DM target"
        return 0
    fi

    local label="Discord"
    [ -n "${DISCORD_TARGET_AUTH}" ] && label="Discord DM"

    # Never POST an unusable body: Discord answers an empty or malformed payload
    # with a 400 that looks identical to a configuration problem.
    local payload
    payload=$(build_payload discord "$1" "$2")
    if [ -z "${payload}" ] || ! printf '%s' "${payload}" | jq -e . >/dev/null 2>&1; then
        print_fail "${label}: could not build the message payload (is python3 working?)"
        return 0
    fi

    discord_request \
        -H "Content-Type: application/json" \
        -X POST --data-binary "${payload}"
    local body_file="${DISCORD_BODY}" code="${DISCORD_HTTP}"

    if [ "${code}" -ge 200 ] 2>/dev/null && [ "${code}" -lt 300 ] 2>/dev/null; then
        print_ok "${label} notified"
    elif [ "${code}" = "000" ]; then
        print_fail "${label} unreachable (network error or timeout)"
    else
        local why details
        why=$(jq -r '.message // empty' "${body_file}" 2>/dev/null || true)
        details=$(jq -r '[(.errors // {}) | paths(scalars) as $p | "\($p|map(tostring)|join(".")): \(getpath($p))"] | join("; ")' \
            "${body_file}" 2>/dev/null || true)
        print_fail "${label} returned HTTP ${code}${why:+ — ${why}}"
        [ -n "${details}" ] && echo "     ${C_DIM}${details}${C_NC}"
        [ -z "${why}" ] && [ -s "${body_file}" ] && \
            echo "     ${C_DIM}Raw: $(head -c 240 "${body_file}")${C_NC}"
    fi
    rm -f "${body_file}"

    # Only attach when the message itself landed. Uploading a 5 MB log to a
    # webhook that just returned 401 achieves nothing except three more
    # failures in the console.
    if [ "${code}" -ge 200 ] 2>/dev/null && [ "${code}" -lt 300 ] 2>/dev/null; then
        discord_attach_report
        discord_attach_log "${DISCORD_TARGET_URL}"
    fi
}

notify_slack() {
    post_webhook "Slack" "${SLACK_WEBHOOK_URL}" "$(build_payload slack "$1" "$2")"
}

notify_teams() {
    post_webhook "Teams" "${TEAMS_WEBHOOK_URL}" "$(build_payload teams "$1" "$2")"
}

notify_gotify() {
    # Token goes in a header rather than the query string so it stays out of the
    # server's access log.
    local url="${GOTIFY_URL%/}/message"
    post_webhook "Gotify" "${url}" "$(build_payload gotify "$1" "$2")" \
        "X-Gotify-Key: ${GOTIFY_TOKEN}"
}

notify_telegram() {
    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    # The bot token is in the URL by Telegram's design, so keep it out of the
    # console: post_webhook prints the URL on failure.
    post_webhook "Telegram" "${url}" "$(build_payload telegram "$1" "$2")" "" "hide-url"
}

notify_ntfy() {
    # ntfy is not JSON-shaped like the others: the topic is the URL path and the
    # body is the message text, with metadata in headers. Posting the generic
    # JSON object to it — which is what the old "generic webhook works with
    # ntfy" claim amounted to — published the raw JSON as the message body.
    local subject="$1" body="$2"
    local prio="${NTFY_PRIORITY}"
    [ "${ERRORS_OCCURRED}" = true ] && prio="high"
    local tags="white_check_mark"
    [ "${ERRORS_OCCURRED}" = true ] && tags="rotating_light"
    [ "${DRY_RUN}" = "true" ] && tags="mag"

    local code
    code=$( { [ -n "${NTFY_TOKEN}" ] && printf 'header = "Authorization: Bearer %s"\n' "$(cfg_escape "${NTFY_TOKEN}")"; true; } \
        | curl -s --config - --max-time 30 -o /dev/null -w "%{http_code}" \
            -H "Title: $(printf '%s' "${subject}" | tr -d '\r\n')" \
            -H "Priority: ${prio}" \
            -H "Tags: ${tags}" \
            --data-binary @- "${NTFY_URL}" <<NTFYBODY 2>/dev/null || true
$(printf '%s' "${body}" | head -c 4000)
NTFYBODY
    )
    if [ "${code}" = "200" ]; then
        print_ok "ntfy notified"
    else
        print_fail "ntfy returned HTTP ${code}"
        ERRORS_OCCURRED=true
    fi
}

# Generic: structured JSON, so ntfy/Gotify/Home Assistant/n8n and anything else
# can pick out whichever fields it needs.
notify_webhook() {
    post_webhook "Webhook" "${GENERIC_WEBHOOK_URL}" "$(build_payload generic "$1" "$2")"
}

notify_all() {
    local subject="$1" body="$2" html_file="$3"
    # The spinner helpers live outside this block. Guard the calls so the block
    # stays sourceable on its own, which is how the panel's test-notification
    # button runs it.
    command -v start_spinner >/dev/null 2>&1 && start_spinner "Sending notifications (${NOTIFY_ACTIVE})..."
    command -v stop_spinner  >/dev/null 2>&1 && stop_spinner
    local channel
    for channel in ${NOTIFY_ACTIVE}; do
        case "${channel}" in
            email)    notify_email    "${subject}" "${body}" "${html_file}" ;;
            discord)  notify_discord  "${subject}" "${body}" ;;
            slack)    notify_slack    "${subject}" "${body}" ;;
            teams)    notify_teams    "${subject}" "${body}" ;;
            ntfy)     notify_ntfy     "${subject}" "${body}" ;;
            gotify)   notify_gotify   "${subject}" "${body}" ;;
            telegram) notify_telegram "${subject}" "${body}" ;;
            webhook)  notify_webhook  "${subject}" "${body}" ;;
        esac
    done
}
# <<< PAU-NOTIFIER-END

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
    if [ -n "${GU_CONTAINERS}" ]; then
        html="${html}<div class='detail'>$(container_note "${GU_CONTAINERS}" | html_escape)</div>"
    fi
    echo "${html}"
}

# "docker 14" -> a sentence saying those 14 are not this tool's business.
container_note() {
    local runtime count
    runtime=$(echo "${1}" | awk '{print $1}')
    count=$(echo "${1}" | awk '{print $2}')
    [ -z "${count}" ] && return 0
    printf '%s %s container(s) are running here and are not updated by this tool — their images are managed separately.' \
        "${count}" "${runtime}"
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
    # "docker 14" / "podman 3" — a runtime present in the guest and how many
    # containers it is running. Reported, never touched.
    GU_CONTAINERS=$(echo "${raw}" | sed -n 's/^__CONTAINERS__ //p' | head -1 || true)
    # "refresh 723 1" — seconds spent refreshing the package list, and how many
    # attempts it needed.
    GU_TIMING=$(echo "${raw}" | sed -n 's/^__TIMING__ //p' | head -1 || true)

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
            --command "/bin/sh" \
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
# Stop, not SilentlyContinue. With SilentlyContinue a non-terminating COM
# failure does not throw, so the catch below never ran: $SearchResult could be
# $null, `$null.Updates.Count -eq 0` evaluates to False in PowerShell, and
# execution fell through to report "UPDATED:" with an empty count — a
# successful update of a guest that installed nothing.
$ErrorActionPreference = "Stop"
# Redirected stdout is otherwise encoded with the console OEM code page, which
# mangles non-ASCII update titles by the time they reach the report.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }
try {
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    $SearchResult = $Searcher.Search("IsInstalled=0 and Type='"'"'Software'"'"'")
    if ($null -eq $SearchResult -or $null -eq $SearchResult.Updates) {
        Write-Output "ERROR:Windows Update search returned no result object"
        exit 0
    }
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
    if ($DownloadResult.ResultCode -ne 2) {
        Write-Output "ERROR:Download returned result code $($DownloadResult.ResultCode) (HRESULT $($DownloadResult.HResult))"
        exit 0
    }
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
    # Last, so it cannot disturb the "first line is UPDATED:<count>" contract.
    if ($InstallResult.RebootRequired) {
        Write-Output "__REBOOT_PENDING__"
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
    # printf, not echo: echo appends a newline that becomes part of the
    # base64 payload PowerShell decodes.
    encoded_cmd=$(printf '%s' "${ps_script}" | iconv -t UTF-16LE 2>/dev/null | base64 -w 0 2>/dev/null) || {
        echo "ENCODE_FAILED"
        return
    }

    # Execute via guest agent
    local exec_result=""
    exec_result=$(pvesh create "/nodes/${NODE_NAME}/qemu/${vmid}/agent/exec" \
        --command "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded_cmd}" \
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

# Enumerate first and check the exit status, rather than iterating over the
# output of an unchecked command substitution.
#
# `set -e` is deliberately off, so a failing `pct list` used to produce an empty
# word list, the loop body simply never ran, every counter stayed at zero, and
# the run finished by printing "Update sequence complete — all clear". That is
# what happens whenever pmxcfs is unhappy — pve-cluster failed to start after a
# full disk, /etc/pve not mounted, a quorum-less node — and the host apt phase
# still works, so the whole run looks normal while nothing was even looked at.
CT_LIST=""
CT_LIST_OK=true
if ! CT_LIST=$(pct list 2>&1); then
    print_fail "Could not list containers: $(echo "${CT_LIST}" | tail -n 1)"
    print_fail "Is pve-cluster running?  systemctl status pve-cluster"
    ERRORS_OCCURRED=true
    CT_LIST_OK=false
    LXC_HTML="<tr><td colspan='3'>Container list unavailable — <code>pct list</code> failed. No containers were examined.</td></tr>"
    CT_LIST=""
fi

for CTID in $(echo "${CT_LIST}" | awk 'NR>1 {print $1}'); do
    is_targeted "${CTID}" || continue
    CT_NAME=$(config_field pct "${CTID}" hostname)
    [ -z "${CT_NAME}" ] && CT_NAME="LXC-${CTID}"

    # Templates are not updatable objects. They appear in `pct list` as stopped,
    # so with START_STOPPED_LXC=true (the default) every run tried to `pct start`
    # them, Proxmox refused, and each one became a permanent error and a
    # permanent "repeat offender" — turning every report red on any host that
    # keeps a template, which is most of them.
    if [ "$(config_field pct "${CTID}" template)" = "1" ]; then
        print_skip "LXC ${CTID} (${CT_NAME}) — template"
        continue
    fi

    CT_STATUS=$(pct status "${CTID}" | awk '{print $2}')
    CT_WAS_STOPPED=false
    GU_CONTAINERS=""
    GU_TIMING=""

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
        # A dry run reports; it does not change the state of the machine.
        # Booting every stopped guest, waiting a minute each, then stopping them
        # again is emphatically a change — and --help promises the opposite.
        if [ "${DRY_RUN}" = "true" ]; then
            print_skip "LXC ${CTID} (${CT_NAME}) — stopped; would be started and checked ${C_DIM}[dry run]${C_NC}"
            LXC_SKIPPED=$((LXC_SKIPPED + 1))
            LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})</td><td><span class='status-badge badge-dim'>Skipped</span></td><td>Stopped container. A real run would start it, update it and stop it again.</td></tr>"
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
    CT_OUTPUT=$(build_guest_update_script | timeout -k 60 "${LINUX_UPDATE_TIMEOUT}" pct exec "${CTID}" -- /bin/sh 2>&1) || CT_RC=$?
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
            LXC_HTML="${LXC_HTML}<tr><td>${CT_LABEL}</td><td><span class='status-badge badge-warning'>Unsupported</span></td><td>${GU_DETAIL:-No supported package manager found.}</td></tr>"
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
                LXC_PENDING=$((LXC_PENDING + 1))
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

    # Where the time went, when there was enough of it to wonder about.
    if [ -n "${GU_TIMING:-}" ]; then
        _tsecs=$(echo "${GU_TIMING}" | awk '{print $2}')
        _tries=$(echo "${GU_TIMING}" | awk '{print $3}')
        if [ -n "${_tsecs}" ] && [ "${_tsecs}" -ge "${HEARTBEAT_SECS}" ] 2>/dev/null; then
            print_warn "  package list refresh took $(fmt_duration "${_tsecs}")$([ "${_tries:-1}" -gt 1 ] 2>/dev/null && echo " over ${_tries} attempts")"
        fi
    fi

    # Say when a guest is running containers this tool does not manage.
    if [ -n "${GU_CONTAINERS:-}" ]; then
        print_warn "  $(container_note "${GU_CONTAINERS}")"
    fi

    # Restore stopped state if needed
    if [ "${CT_WAS_STOPPED}" = true ] && [ "${DRY_RUN}" != "true" ]; then
        print_stop "Stopping LXC ${CTID} (${CT_NAME}) ${C_DIM}[restoring state]${C_NC}..."
        # `pct shutdown` blocks for its own timeout and then exits non-zero, so
        # `|| pct stop` fired an immediate force-stop and the wait below was
        # dead weight. Ask first, wait properly, and only then force.
        pct shutdown "${CTID}" >/dev/null 2>&1 || true
        if ! wait_for_status "ct" "${CTID}" "stopped" "${LINUX_SHUTDOWN_TIMEOUT}"; then
            print_warn "LXC ${CTID} — shutdown timeout, forcing stop..."
            pct stop "${CTID}" >/dev/null 2>&1 || true
        fi
    fi
done

# ==============================================================================
# 2. UPDATE VIRTUAL MACHINES
# ==============================================================================
section_header "Virtual Machines"
VM_HTML=""

# Same reasoning as the container list above: a failed `qm list` must be an
# error, not an empty sweep reported as success.
VM_LIST=""
VM_LIST_OK=true
if ! VM_LIST=$(qm list 2>&1); then
    print_fail "Could not list VMs: $(echo "${VM_LIST}" | tail -n 1)"
    print_fail "Is pve-cluster running?  systemctl status pve-cluster"
    ERRORS_OCCURRED=true
    VM_LIST_OK=false
    VM_HTML="<tr><td colspan='3'>VM list unavailable — <code>qm list</code> failed. No VMs were examined.</td></tr>"
    VM_LIST=""
fi

for VMID in $(echo "${VM_LIST}" | awk 'NR>1 {print $1}'); do
    is_targeted "${VMID}" || continue
    VM_NAME=$(config_field qm "${VMID}" name)
    [ -z "${VM_NAME}" ] && VM_NAME="VM-${VMID}"

    # As above: a template is not something to boot and patch.
    if [ "$(config_field qm "${VMID}" template)" = "1" ]; then
        print_skip "VM ${VMID} (${VM_NAME}) — template"
        continue
    fi

    VM_STATUS=$(qm status "${VMID}" | awk '{print $2}')
    VM_WAS_STOPPED=false
    GU_CONTAINERS=""
    GU_TIMING=""
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
        if is_windows_ostype "${VM_OSTYPE_CONFIG}"; then
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

        # See the container loop: a dry run must not boot the machine.
        if [ "${DRY_RUN}" = "true" ]; then
            print_skip "VM ${VMID} (${VM_NAME}) — stopped; would be started and checked ${C_DIM}[dry run]${C_NC}"
            VM_SKIPPED=$((VM_SKIPPED + 1))
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})</td><td><span class='status-badge badge-dim'>Skipped</span></td><td>Stopped VM. A real run would start it, update it and stop it again.</td></tr>"
            continue
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
                    # Shut it back down.
                    #
                    # Never force-stop a Windows guest here. The most likely
                    # reason a Windows VM we just started has no guest agent is
                    # that it is sitting at "Configuring Windows updates" from a
                    # previous cycle — which is precisely when pulling the power
                    # corrupts it. Ask politely, and if it will not go, leave it
                    # running and say so.
                    restore_stopped_vm "${VMID}" "${VM_NAME}" "${VM_OS_TYPE}"
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

    # An OS we could not identify must not be guessed at. Running the Linux
    # payload against a Windows guest silently leaves it unpatched, and running
    # it against anything else is a shot in the dark.
    if [ "${VM_OS_TYPE}" = "unknown" ]; then
        print_fail "VM ${VMID} (${VM_NAME}) — could not determine the guest OS"
        VM_ERRORS=$((VM_ERRORS + 1))
        ERRORS_OCCURRED=true
        record_guest_failure "${VMID}" "${VM_NAME}" "could not determine guest OS"
        VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})</td><td><span class='status-badge badge-error'>Unknown OS</span></td><td>The guest agent returned no OS information and <code>ostype</code> is not set in the VM config. Set <code>ostype</code> so the correct update method is used.</td></tr>"
        [ "${VM_WAS_STOPPED}" = true ] && restore_stopped_vm "${VMID}" "${VM_NAME}" "linux"
        continue
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
        # Strip carriage returns once, here, rather than in each branch below.
        # PowerShell terminates every line with CRLF, and command substitution
        # removes the trailing newline but never the CR. That left WIN_OUTPUT as
        # "NO_UPDATES\r", so the exact-equality test against "NO_UPDATES" was
        # false for every healthy Windows guest and each one was reported as an
        # unrecognised-output error on every run. It also left stray CRs inside
        # the extracted counts and update titles, which corrupted the console
        # output and the HTML report.
        WIN_OUTPUT=$(update_windows_vm "${VMID}" "${WINDOWS_UPDATE_TIMEOUT}" | tr -d '\r')
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
            # A timeout leaves the guest in an unknown state, so it has to count
            # as a failure. It previously set no error flag at all, which meant
            # the run was recorded as "ok", a failure-only notification stayed
            # silent, and — because the id never reached FAILED_THIS_RUN — any
            # existing failure streak for this guest was reset to zero.
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
            record_guest_failure "${VMID}" "${VM_NAME}" "Windows Update timed out after ${WINDOWS_UPDATE_TIMEOUT}s"
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
            VM_PENDING=$((VM_PENDING + 1))
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-warning'>Pending</span></td><td><strong>${WIN_COUNT} update(s) would be installed:</strong><ul class='pkg-list'>$(html_list "${WIN_NAMES}")</ul></td></tr>"
        elif echo "${WIN_OUTPUT}" | grep -q "^UPDATED:"; then
            WIN_COUNT=$(echo "${WIN_OUTPUT}" | head -1 | sed 's/^UPDATED://')
            WIN_NAMES=$(echo "${WIN_OUTPUT}" | tail -n +2 | grep -v '^__REBOOT_PENDING__$' || true)
            WIN_REBOOT_PENDING=false
            echo "${WIN_OUTPUT}" | grep -q '^__REBOOT_PENDING__$' && WIN_REBOOT_PENDING=true
            print_ok "VM ${VMID} (${VM_NAME}) — ${C_BOLD}${WIN_COUNT} Windows updates installed${C_NC}${local_suffix}"
            VM_WIN_UPDATED=$((VM_WIN_UPDATED + 1))
            VM_UPDATED=$((VM_UPDATED + 1))
            WIN_LEFT_RUNNING=""
            if [ "${WIN_REBOOT_PENDING}" = true ]; then
                WIN_LEFT_RUNNING=" Windows reports a reboot is required to finish installing."
            fi
            if [ "${VM_WAS_STOPPED}" = true ]; then
                # This is the dangerous case, and it used to be the unguarded
                # one. Updates have just been written and a servicing reboot is
                # pending, so the guest is about to spend a long time in
                # "Working on updates — do not turn off your computer". The
                # restore-state block below would ask it to shut down and then
                # force-stop it a few minutes later, cutting power in the middle
                # of that. Leave it running instead and let it settle; the next
                # scheduled run will find it idle and stop it then.
                print_warn "VM ${VMID} (${VM_NAME}) — left running to finish installing (was stopped)"
                VM_WAS_STOPPED=false
                GUESTS_MID_UPDATE=$((GUESTS_MID_UPDATE + 1))
                WIN_LEFT_RUNNING="${WIN_LEFT_RUNNING} It was started by this run and has been left running to complete servicing safely; it will be returned to its stopped state once it settles."
            fi
            VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-success'>Updated</span></td><td><strong>${WIN_COUNT} update(s) installed:</strong><ul class='pkg-list'>$(html_list "${WIN_NAMES}")</ul>${WIN_LEFT_RUNNING}</td></tr>"
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
                VM_HTML="${VM_HTML}<tr><td>${VM_LABEL}</td><td><span class='status-badge badge-warning'>Unsupported</span></td><td>${GU_DETAIL:-No supported package manager found.}</td></tr>"
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
                    VM_PENDING=$((VM_PENDING + 1))
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

    if [ -n "${GU_TIMING:-}" ]; then
        _tsecs=$(echo "${GU_TIMING}" | awk '{print $2}')
        if [ -n "${_tsecs}" ] && [ "${_tsecs}" -ge "${HEARTBEAT_SECS}" ] 2>/dev/null; then
            print_warn "  package list refresh took $(fmt_duration "${_tsecs}")"
        fi
    fi
    if [ -n "${GU_CONTAINERS:-}" ]; then
        print_warn "  $(container_note "${GU_CONTAINERS}")"
    fi

    # Restore stopped state if needed
    if [ "${VM_WAS_STOPPED}" = true ]; then
        restore_stopped_vm "${VMID}" "${VM_NAME}" "${VM_OS_TYPE}"
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
HOST_APT_ERR=$(apt-get "${HOST_APT_OPTS[@]}" update -qy 2>&1 >/dev/null) || HOST_UPDATE_RC=$?
HOST_UPGRADABLE=$(LC_ALL=C apt list --upgradable 2>/dev/null | grep '/' || true)
stop_spinner

# A refresh that failed means the package list cannot be trusted, so nothing
# below may claim the host is up to date.
#
# This used to be a print_warn and nothing else: ERRORS_OCCURRED was never set,
# so with an empty or stale index the host was badged "No Updates", the report
# said "Host node is fully up to date", the run was recorded as ok, and a
# failure-only notification stayed silent. On the single most common Proxmox
# homelab misconfiguration — the enterprise repo enabled without a subscription
# — every pve-* package went unpatched for months behind a green tick.
HOST_REPO_WARNING=""
if [ "${HOST_UPDATE_RC}" -ne 0 ]; then
    print_fail "Host apt-get update exited ${HOST_UPDATE_RC} — the package list is stale"
    ERRORS_OCCURRED=true
    HOST_REPO_WARNING="apt-get update exited ${HOST_UPDATE_RC}, so the package list could not be refreshed and updates may have been missed."

    if grep -rqs 'enterprise\.proxmox\.com' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
       && [ ! -s /etc/subscription ]; then
        print_fail "The Proxmox enterprise repository is enabled but there is no subscription."
        print_fail "Switch to the no-subscription repository, or disable the enterprise one."
        HOST_REPO_WARNING="${HOST_REPO_WARNING} The Proxmox <em>enterprise</em> repository is enabled without a subscription, which makes this fail on every run. Switch to <code>pve-no-subscription</code> or disable the enterprise repository."
    fi

    if [ -n "${HOST_APT_ERR}" ]; then
        echo "${HOST_APT_ERR}" | tail -n 5 | sed 's/^/      /'
    fi
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
elif [ "${HOST_UPDATE_RC}" -ne 0 ]; then
    # Empty list *and* a failed refresh. "Up to date" would be a guess, and the
    # wrong one on any host whose repositories are misconfigured.
    print_fail "Host package list could not be refreshed — update status unknown"
    HOST_STATUS_BADGE="<span class='status-badge badge-error'>Repo Error</span>"
    HOST_SUMMARY_TEXT="<strong>Could not determine host update status.</strong> ${HOST_REPO_WARNING}"
else
    print_ok "Host is already fully up to date"
    HOST_STATUS_BADGE="<span class='status-badge badge-no-updates'>No Updates</span>"
    HOST_SUMMARY_TEXT="Host node is fully up to date."
fi

# Carry the repository warning into the report even when packages *were* found
# and installed — a partial refresh still means something may have been missed.
if [ -n "${HOST_REPO_WARNING}" ] && [ "${HOST_STATUS_BADGE}" != "<span class='status-badge badge-error'>Repo Error</span>" ]; then
    HOST_SUMMARY_TEXT="${HOST_SUMMARY_TEXT}<p class='warn-note'>${HOST_REPO_WARNING}</p>"
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

# Pick the highest kernel *version*, not the most recently written file.
#
# `ls -t` orders by mtime, which is not version order. Reinstalling or pinning
# an older kernel — routine after a NIC or GPU driver problem, and what a /boot
# restore does — made that older image the "latest", so the running kernel never
# matched it and the host was rebooted at REBOOT_TIME after every single run,
# forever, each time reporting a kernel change that had not happened.
#
# linux-version (from linux-base) knows how to order kernel versions properly;
# sort -V is the fallback.
LATEST_KERNEL=$(latest_installed_kernel)

# Did this run actually install a kernel? A version difference that predates the
# run is a pre-existing skew (a pinned kernel, a stock Debian image pulled in as
# a dependency), and rebooting for it every week is not an update, it is an
# unexplained weekly outage.
KERNEL_UPGRADED_THIS_RUN=false
if [ -n "${HOST_UPDATES:-}" ] && \
   echo "${HOST_UPDATES}" | grep -qE '(proxmox-kernel|pve-kernel|linux-image)'; then
    KERNEL_UPGRADED_THIS_RUN=true
fi

if [ -n "${ONLY_IDS}" ]; then
    # Never reboot the host because of a targeted guest run.
    REBOOT_REASON="Reboot not considered — targeted run (--only ${ONLY_IDS})"
elif [ "${KERNEL_UPGRADED_THIS_RUN}" = true ] && [ -n "${LATEST_KERNEL}" ] \
     && [ "${RUNNING_KERNEL}" != "${LATEST_KERNEL}" ]; then
    REBOOT_NEEDED=true
    REBOOT_REASON="Kernel updated: ${RUNNING_KERNEL} &rarr; ${LATEST_KERNEL}"
    print_warn "Kernel change detected: ${C_BOLD}${RUNNING_KERNEL} → ${LATEST_KERNEL}${C_NC}"
elif [ -n "${LATEST_KERNEL}" ] && [ "${RUNNING_KERNEL}" != "${LATEST_KERNEL}" ]; then
    # Newer kernel present but not installed by this run. Report it; do not
    # reboot for it, or every scheduled run reboots the host again.
    print_warn "Running an older kernel than the newest installed (${RUNNING_KERNEL} vs ${LATEST_KERNEL})"
    print_warn "No kernel was installed by this run, so no reboot has been scheduled."
    REBOOT_REASON="Not rebooting: ${LATEST_KERNEL} is installed but was not updated by this run (running ${RUNNING_KERNEL})"
fi

if [ -z "${ONLY_IDS}" ] && [ -f /var/run/reboot-required ]; then
    REBOOT_NEEDED=true
    [ -z "${REBOOT_REASON}" ] && REBOOT_REASON="System flagged reboot-required"
fi

# A reboot held by one schedule has to be taken by the next one that is allowed
# to take it.
#
# Without this the whole point of --no-reboot collapses. The reboot decision
# above only fires when *this* run installed a kernel, so the weekly no-reboot
# run would install it, hold the reboot, and the monthly run would then find
# nothing to install, conclude no reboot was needed, and the host would sit on
# the old kernel forever. The hold is recorded on disk instead, and cleared as
# soon as the machine is seen running the newest kernel — whether it got there
# through this tool or someone rebooting it by hand.
REBOOT_PENDING_FILE="${STATE_DIR}/reboot-pending"

if [ -n "${LATEST_KERNEL}" ] && [ "${RUNNING_KERNEL}" = "${LATEST_KERNEL}" ]; then
    rm -f "${REBOOT_PENDING_FILE}" 2>/dev/null || true
elif [ "${REBOOT_NEEDED}" != true ] && [ -z "${ONLY_IDS}" ] \
     && [ -r "${REBOOT_PENDING_FILE}" ]; then
    HELD_REASON=$(head -c 500 "${REBOOT_PENDING_FILE}" 2>/dev/null | tr -d '\r\n')
    REBOOT_NEEDED=true
    REBOOT_REASON="${HELD_REASON:-A previous run installed a kernel and was not allowed to reboot}"
fi

REBOOT_HELD=false
if [ "${ALLOW_REBOOT}" != "true" ] && [ "${REBOOT_NEEDED}" = true ]; then
    # Deliberately distinct from "no reboot needed". A run started with
    # --no-reboot has installed a kernel the host is not running, and saying
    # nothing about it would leave the machine looking up to date while it waits
    # for whichever schedule is allowed to take it down.
    REBOOT_NEEDED=false
    REBOOT_HELD=true
    # Record the plain reason, before it is dressed up for the report. Writing
    # the decorated string re-wrapped itself on every held run, so by the third
    # week the report read "Reboot HELD — Reboot HELD — Reboot HELD — ...".
    if [ "${DRY_RUN}" != "true" ]; then
        mkdir -p "${STATE_DIR}" 2>/dev/null || true
        printf '%s\n' "${REBOOT_REASON:-A reboot is required}"             > "${REBOOT_PENDING_FILE}" 2>/dev/null || true
    fi
    REBOOT_REASON="Reboot HELD — ${REBOOT_REASON:-a reboot is required}. This schedule runs with --no-reboot; the next schedule that allows a reboot will take it."
    print_warn "Reboot held: this schedule does not reboot. The host is running ${RUNNING_KERNEL} with ${LATEST_KERNEL:-a newer kernel} installed."
elif [ "${ALLOW_REBOOT}" != "true" ]; then
    if [ -n "${REBOOT_REASON}" ]; then
        REBOOT_REASON="${REBOOT_REASON} (this schedule runs with --no-reboot in any case)"
    else
        REBOOT_REASON="No reboot needed — and this schedule would not have rebooted in any case"
    fi
fi

if [ "${HOST_UPDATE_FAILED}" = true ]; then
    REBOOT_NEEDED=false
    REBOOT_HELD=false
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
elif [ "${REBOOT_HELD}" = true ]; then
    REBOOT_STATUS_HTML="<span class='status-badge badge-warning'>Reboot Pending</span><br><em>${REBOOT_REASON}</em>"
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

    <!-- This said "delivered via Mailgun ${MAILGUN_REGION} API" for every
         report, on every channel. One file is built and then handed to all of
         them — SMTP, Discord, Slack, Teams, ntfy, Gotify, Telegram, webhook —
         so it cannot name its own transport, and MAILGUN_REGION defaults to EU
         even on a host with no Mailgun credentials at all. What the report can
         honestly say is which machine produced it, and when. -->
    <div class='footer'>
      Proxmox Auto-Update ${PAU_VERSION} on <strong>${HOST_NAME}</strong> — ${TIMESTAMP}
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
    rm -f "${REBOOT_PENDING_FILE}" 2>/dev/null || true
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

if [ "${DRY_RUN}" = "true" ]; then
    echo -e "  ${C_CYAN}LXC:${C_NC}  ${C_YELLOW}${LXC_PENDING} with updates pending${C_NC}, ${LXC_CURRENT} current, ${LXC_ERRORS} errors, ${LXC_EXCLUDED} excluded"
    echo -e "  ${C_CYAN}VMs:${C_NC}  ${C_YELLOW}${VM_PENDING} with updates pending${C_NC}, ${VM_CURRENT} current, ${VM_ERRORS} errors"
else
    echo -e "  ${C_CYAN}LXC:${C_NC}  ${C_GREEN}${LXC_UPDATED} updated${C_NC}, ${LXC_CURRENT} current, ${LXC_STARTED} started+stopped, ${LXC_ERRORS} errors, ${LXC_EXCLUDED} excluded"
    echo -e "  ${C_CYAN}VMs:${C_NC}  ${C_GREEN}${VM_UPDATED} updated${C_NC} (${VM_WIN_UPDATED} Windows), ${VM_CURRENT} current, ${VM_STARTED} started+stopped, ${VM_ERRORS} errors, ${VM_WIN_TIMEOUT} timeouts"
fi
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
elif [ "${GUESTS_MID_UPDATE}" -gt 0 ]; then
    echo -e "  ${C_YELLOW}${C_BOLD}Update sequence complete — ${GUESTS_MID_UPDATE} guest(s) left mid-update${C_NC}${DRY_SUFFIX}"
else
    echo -e "  ${C_GREEN}${C_BOLD}Update sequence complete — all clear ✓${C_NC}${DRY_SUFFIX}"
fi
echo -e "${C_BOLD}${C_CYAN}══════════════════════════════════════════════════════════════${C_NC}"
echo ""

# Exit with a status that reflects the run.
#
# The script previously ended on an echo, so it always exited 0 no matter what
# had failed. `systemctl status pve-autoupdate-run` reported SUCCESS on a failed
# run — which the --detach help text explicitly tells people to check — and any
# cron or monitoring wrapper using `|| alert` could never fire.
#
#   0  everything succeeded
#   1  at least one error occurred
#   2  no hard error, but guests were left mid-update (host reboot suppressed)
if [ "${ERRORS_OCCURRED}" = true ]; then
    exit 1
fi
if [ "${GUESTS_MID_UPDATE}" -gt 0 ]; then
    exit 2
fi
exit 0