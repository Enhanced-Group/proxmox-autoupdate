#!/usr/bin/env bash
# ==============================================================================
# Proxmox Master Auto-Update — with Fancy Output, Stopped Guest Support
# & Windows VM Updates via QEMU Guest Agent
# ==============================================================================

set -u

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

start_spinner() {
    local msg="$1"
    if [ "${INTERACTIVE}" = true ]; then
        (
            trap 'exit 0' TERM
            local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            local i=0
            while true; do
                printf "\r  \033[0;36m%s\033[0m %s" "${chars:$i:1}" "$msg" >/dev/tty 2>/dev/null
                i=$(( (i + 1) % ${#chars} ))
                sleep 0.08
            done
        ) &
        _SPIN_PID=$!
        disown "$_SPIN_PID" 2>/dev/null
    fi
}

stop_spinner() {
    if [ -n "${_SPIN_PID}" ]; then
        kill "${_SPIN_PID}" 2>/dev/null
        wait "${_SPIN_PID}" 2>/dev/null || true
        _SPIN_PID=""
        printf "\r\033[K" >/dev/tty 2>/dev/null || true
    fi
}

# Ensure spinner is killed on script exit
trap 'stop_spinner; rm -f "${HTML_FILE:-}" "${MAILGUN_RESPONSE_FILE:-}"' EXIT

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

# Validate required config values
for VAR_NAME in MAILGUN_API_KEY MAILGUN_DOMAIN MAILGUN_REGION RECIPIENT_EMAIL SENDER_EMAIL; do
    if [ -z "${!VAR_NAME:-}" ]; then
        echo -e "${C_RED}[!] FATAL: ${VAR_NAME} is not set in ${CONFIG_FILE}${C_NC}"
        exit 1
    fi
done

# Optional config values with defaults
EXCLUDE_IDS="${EXCLUDE_IDS:-}"
WINDOWS_UPDATE_TIMEOUT="${WINDOWS_UPDATE_TIMEOUT:-1200}"
START_STOPPED_WINDOWS="${START_STOPPED_WINDOWS:-false}"
REBOOT_TIME="${REBOOT_TIME:-00:00}"

# Resolve Mailgun API base URL from region
if [ "${MAILGUN_REGION}" = "EU" ]; then
    MAILGUN_API_URL="https://api.eu.mailgun.net/v3/${MAILGUN_DOMAIN}/messages"
else
    MAILGUN_API_URL="https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages"
fi

# ==============================================================================
# SYSTEM & LOG SETUP
# ==============================================================================

HOST_NAME=$(hostname -f 2>/dev/null || hostname)
NODE_NAME=$(hostname -s 2>/dev/null || hostname)
TIMESTAMP=$(date '+%d/%m/%Y %H:%M:%S')
HTML_FILE="/tmp/update_report_$$.html"

# Logging: persist all output to a log file
LOG_DIR="/var/log/proxmox-autoupdate"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/update_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Prune logs older than 90 days
find "${LOG_DIR}" -name "update_*.log" -mtime +90 -delete 2>/dev/null || true

# Check for jq
HAS_JQ=false
command -v jq >/dev/null 2>&1 && HAS_JQ=true

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

ERRORS_OCCURRED=false

# ==============================================================================
# HELPER: Check if an ID is in the exclusion list
# ==============================================================================
is_excluded() {
    local id="$1"
    if [ -n "${EXCLUDE_IDS}" ]; then
        echo ",${EXCLUDE_IDS}," | grep -q ",${id}," && return 0
    fi
    return 1
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
    os_info=$(pvesh get "/nodes/${NODE_NAME}/qemu/${vmid}/agent/get-osinfo" 2>/dev/null) || true

    if [ -n "$os_info" ]; then
        if echo "$os_info" | grep -qi "mswindows\|windows\|microsoft"; then
            echo "windows"
            return
        fi
    fi
    echo "linux"
}

# ==============================================================================
# HELPER: Run Linux updates inside a VM via guest agent
# ==============================================================================
update_linux_vm() {
    local vmid="$1"
    local vm_output=""
    local vm_error=""

    # Execute update command via pvesh
    local exec_result=""
    exec_result=$(pvesh create "/nodes/${NODE_NAME}/qemu/${vmid}/agent/exec" \
        --command "/bin/bash" \
        --'input-data' "$(cat <<'VMSCRIPT'
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qy >/dev/null 2>&1
    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep '/' || true)
    if [ -n "${UPGRADABLE}" ]; then
        echo "${UPGRADABLE}" | awk -F'/' '{
            pkg=$1;
            split($2, a, " ");
            new_ver=a[2];
            match($0, /\[from: [^\]]+\]/);
            old_ver=substr($0, RSTART+7, RLENGTH-8);
            print pkg " (" old_ver " -> " new_ver ")"
        }'
        apt-get dist-upgrade -qy >/dev/null 2>&1 && apt-get autoremove -qy >/dev/null 2>&1
    fi
elif command -v yum >/dev/null 2>&1; then
    yum -q check-update 2>/dev/null | awk 'NF==3 {print $1 " (" $2 ")"}' || true
    yum -y update -q >/dev/null 2>&1
elif command -v apk >/dev/null 2>&1; then
    apk update -q 2>/dev/null
    apk upgrade -q 2>&1
fi
VMSCRIPT
)" 2>&1) || { echo "EXEC_FAILED"; return; }

    # Extract PID
    local exec_pid=""
    if [ "${HAS_JQ}" = true ]; then
        exec_pid=$(echo "${exec_result}" | jq -r '.pid // empty' 2>/dev/null || true)
    else
        exec_pid=$(echo "${exec_result}" | grep -oP '"pid"\s*:\s*\K\d+' 2>/dev/null || true)
    fi

    if [ -z "${exec_pid}" ]; then
        echo "EXEC_FAILED"
        return
    fi

    # Poll for completion (5 min timeout)
    local wait_count=0
    while [ ${wait_count} -lt 60 ]; do
        local exec_status=""
        exec_status=$(pvesh get "/nodes/${NODE_NAME}/qemu/${vmid}/agent/exec-status" --pid "${exec_pid}" 2>&1) || break

        local exited=""
        if [ "${HAS_JQ}" = true ]; then
            exited=$(echo "${exec_status}" | jq -r '.exited // empty' 2>/dev/null || true)
        else
            exited=$(echo "${exec_status}" | grep -oP '"exited"\s*:\s*\K\d+' 2>/dev/null || true)
        fi

        if [ "${exited}" = "1" ]; then
            if [ "${HAS_JQ}" = true ]; then
                echo "${exec_status}" | jq -r '."out-data" // empty' 2>/dev/null || true
            else
                echo "${exec_status}" | grep -oP '"out-data"\s*:\s*"\K[^"]*' 2>/dev/null | sed 's/\\n/\n/g' || true
            fi
            return
        fi
        sleep 5
        wait_count=$((wait_count + 1))
    done
    echo "TIMEOUT"
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
    $Downloader = $Session.CreateUpdateDownloader()
    $Downloader.Updates = $SearchResult.Updates
    $DownloadResult = $Downloader.Download()
    $Installer = New-Object -ComObject Microsoft.Update.UpdateInstaller
    $Installer.Updates = $SearchResult.Updates
    $InstallResult = $Installer.Install()
    Write-Output "UPDATED:$Count"
    foreach ($name in $Names) {
        Write-Output $name
    }
} catch {
    Write-Output "ERROR:$($_.Exception.Message)"
}
'

    # Encode for PowerShell -EncodedCommand (UTF-16LE base64)
    local encoded_cmd=""
    encoded_cmd=$(echo "${ps_script}" | iconv -t UTF-16LE 2>/dev/null | base64 -w 0 2>/dev/null) || {
        echo "ENCODE_FAILED"
        return
    }

    # Execute via guest agent
    local exec_result=""
    exec_result=$(pvesh create "/nodes/${NODE_NAME}/qemu/${vmid}/agent/exec" \
        --command "powershell.exe -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${encoded_cmd}" 2>&1) || {
        echo "EXEC_FAILED"
        return
    }

    # Extract PID
    local exec_pid=""
    if [ "${HAS_JQ}" = true ]; then
        exec_pid=$(echo "${exec_result}" | jq -r '.pid // empty' 2>/dev/null || true)
    else
        exec_pid=$(echo "${exec_result}" | grep -oP '"pid"\s*:\s*\K\d+' 2>/dev/null || true)
    fi

    if [ -z "${exec_pid}" ]; then
        echo "EXEC_FAILED"
        return
    fi

    # Poll for completion with configurable timeout
    local poll_interval=10
    local max_polls=$(( timeout / poll_interval ))
    local wait_count=0

    while [ ${wait_count} -lt ${max_polls} ]; do
        local exec_status=""
        exec_status=$(pvesh get "/nodes/${NODE_NAME}/qemu/${vmid}/agent/exec-status" --pid "${exec_pid}" 2>&1) || break

        local exited=""
        if [ "${HAS_JQ}" = true ]; then
            exited=$(echo "${exec_status}" | jq -r '.exited // empty' 2>/dev/null || true)
        else
            exited=$(echo "${exec_status}" | grep -oP '"exited"\s*:\s*\K\d+' 2>/dev/null || true)
        fi

        if [ "${exited}" = "1" ]; then
            if [ "${HAS_JQ}" = true ]; then
                echo "${exec_status}" | jq -r '."out-data" // empty' 2>/dev/null || true
            else
                echo "${exec_status}" | grep -oP '"out-data"\s*:\s*"\K[^"]*' 2>/dev/null | sed 's/\\n/\n/g' || true
            fi
            return
        fi
        sleep ${poll_interval}
        wait_count=$((wait_count + 1))
    done
    echo "TIMEOUT"
}

# ==============================================================================
# DISPLAY BANNER
# ==============================================================================

print_banner

# Capture Proxmox VE Version BEFORE updates
PVE_VERSION_BEFORE=$(pveversion 2>/dev/null | awk '{print $1}' || dpkg-query -W -f='${Version}' pve-manager 2>/dev/null || echo "Unknown")
echo ""
echo -e "  PVE Version: ${C_BOLD}${PVE_VERSION_BEFORE}${C_NC}"

# ==============================================================================
# 1. UPDATE LXC CONTAINERS
# ==============================================================================
section_header "LXC Containers"
LXC_HTML=""

for CTID in $(pct list | awk 'NR>1 {print $1}'); do
    CT_NAME=$(pct config "${CTID}" | grep -E "^hostname:" | awk '{print $2}')
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
                LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})</td><td><span class='status-badge badge-error'>Start Failed</span></td><td>Container did not reach running state within 60 seconds.</td></tr>"
                continue
            fi
        else
            print_fail "LXC ${CTID} (${CT_NAME}) — pct start failed"
            LXC_ERRORS=$((LXC_ERRORS + 1))
            ERRORS_OCCURRED=true
            LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})</td><td><span class='status-badge badge-error'>Start Failed</span></td><td>Failed to start container.</td></tr>"
            continue
        fi
    fi

    # Container is now running — perform update
    start_spinner "Updating LXC ${CTID} (${CT_NAME})..."
    CT_OUTPUT=""
    CT_ERROR=""
    CT_OUTPUT=$(pct exec "${CTID}" -- bash -c "
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qy >/dev/null 2>&1
            UPGRADABLE=\$(apt list --upgradable 2>/dev/null | grep '/' || true)
            if [ -n \"\${UPGRADABLE}\" ]; then
                echo \"\${UPGRADABLE}\" | awk -F'/' '{
                    pkg=\$1;
                    split(\$2, a, \" \");
                    new_ver=a[2];
                    match(\$0, /\[from: [^\]]+\]/);
                    old_ver=substr(\$0, RSTART+7, RLENGTH-8);
                    print pkg \" (\" old_ver \" -> \" new_ver \")\"
                }'
                apt-get dist-upgrade -qy 2>&1 && apt-get autoremove -qy >/dev/null 2>&1
            fi
        elif command -v yum >/dev/null 2>&1; then
            yum -q check-update 2>/dev/null | awk 'NF==3 {print \$1 \" (\" \$2 \")\"}' || true
            yum -y update -q >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk update -q 2>/dev/null
            apk upgrade -q 2>&1
        else
            echo '__UNSUPPORTED_PKG_MANAGER__'
        fi
    " 2>&1) || CT_ERROR="Command failed with exit code $?"
    stop_spinner

    # Build suffix for display
    local_suffix=""
    [ "${CT_WAS_STOPPED}" = true ] && local_suffix=" ${C_DIM}[was stopped]${C_NC}"
    html_suffix=""
    [ "${CT_WAS_STOPPED}" = true ] && html_suffix=" <em style='color:#6c757d'>[was stopped]</em>"

    if [ -n "${CT_ERROR}" ]; then
        print_fail "LXC ${CTID} (${CT_NAME}) — ${CT_ERROR}${local_suffix}"
        LXC_ERRORS=$((LXC_ERRORS + 1))
        ERRORS_OCCURRED=true
        ESCAPED_ERROR=$(echo "${CT_ERROR}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})${html_suffix}</td><td><span class='status-badge badge-error'>Error</span></td><td>${ESCAPED_ERROR}</td></tr>"
    elif echo "${CT_OUTPUT}" | grep -q '__UNSUPPORTED_PKG_MANAGER__'; then
        print_warn "LXC ${CTID} (${CT_NAME}) — unsupported package manager${local_suffix}"
        LXC_SKIPPED=$((LXC_SKIPPED + 1))
        LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})${html_suffix}</td><td><span class='status-badge badge-warning'>Unsupported</span></td><td>No supported package manager found (apt/yum/apk).</td></tr>"
    else
        UPDATES=$(echo "${CT_OUTPUT}" | grep -E '^\S+\s+\(' || true)
        if [ -n "${UPDATES}" ]; then
            PKG_COUNT=$(echo "${UPDATES}" | wc -l)
            print_ok "LXC ${CTID} (${CT_NAME}) — ${C_BOLD}${PKG_COUNT} packages updated${C_NC}${local_suffix}"
            LXC_UPDATED=$((LXC_UPDATED + 1))
            ESCAPED_UPDATES=$(echo "${UPDATES}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
            PKG_LIST_HTML=$(echo "${ESCAPED_UPDATES}" | awk '{print "<li>" $0 "</li>"}')
            LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})${html_suffix}</td><td><span class='status-badge badge-success'>Updated</span></td><td><strong>${PKG_COUNT} package(s) updated:</strong><ul class='pkg-list'>${PKG_LIST_HTML}</ul></td></tr>"
        else
            print_ok "LXC ${CTID} (${CT_NAME}) — already up to date${local_suffix}"
            LXC_CURRENT=$((LXC_CURRENT + 1))
            LXC_HTML="${LXC_HTML}<tr><td><strong>${CTID}</strong> (${CT_NAME})${html_suffix}</td><td><span class='status-badge badge-no-updates'>No Updates</span></td><td>System fully up to date.</td></tr>"
        fi
    fi

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
    VM_NAME=$(qm config "${VMID}" | grep -E "^name:" | awk '{print $2}')
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
        VM_OSTYPE_CONFIG=$(qm config "${VMID}" | grep -E "^ostype:" | awk '{print $2}')
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
                VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})</td><td><span class='status-badge badge-error'>Start Failed</span></td><td>VM did not reach running state within 60 seconds.</td></tr>"
                continue
            fi
        else
            print_fail "VM ${VMID} (${VM_NAME}) — qm start failed"
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
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
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${os_icon}${html_suffix}</td><td><span class='status-badge badge-error'>Error</span></td><td>Failed to execute Windows Update via guest agent.</td></tr>"
        elif [ "${WIN_OUTPUT}" = "TIMEOUT" ]; then
            print_warn "VM ${VMID} (${VM_NAME}) — Windows Update timed out after ${WINDOWS_UPDATE_TIMEOUT}s${local_suffix}"
            VM_WIN_TIMEOUT=$((VM_WIN_TIMEOUT + 1))
            # Don't shut down a Windows VM mid-update! Leave it running.
            VM_WAS_STOPPED=false
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${os_icon}${html_suffix}</td><td><span class='status-badge badge-warning'>Timeout</span></td><td>Windows Update did not complete within ${WINDOWS_UPDATE_TIMEOUT}s. VM left running to finish.</td></tr>"
        elif [ "${WIN_OUTPUT}" = "NO_UPDATES" ]; then
            print_ok "VM ${VMID} (${VM_NAME}) — Windows already up to date${local_suffix}"
            VM_CURRENT=$((VM_CURRENT + 1))
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${os_icon}${html_suffix}</td><td><span class='status-badge badge-no-updates'>No Updates</span></td><td>Windows is fully up to date.</td></tr>"
        elif echo "${WIN_OUTPUT}" | grep -q "^ERROR:"; then
            ERROR_MSG=$(echo "${WIN_OUTPUT}" | head -1 | sed 's/^ERROR://')
            print_fail "VM ${VMID} (${VM_NAME}) — ${ERROR_MSG}${local_suffix}"
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
            ESCAPED_ERROR=$(echo "${ERROR_MSG}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${os_icon}${html_suffix}</td><td><span class='status-badge badge-error'>Error</span></td><td>${ESCAPED_ERROR}</td></tr>"
        elif echo "${WIN_OUTPUT}" | grep -q "^UPDATED:"; then
            WIN_COUNT=$(echo "${WIN_OUTPUT}" | head -1 | sed 's/^UPDATED://')
            WIN_NAMES=$(echo "${WIN_OUTPUT}" | tail -n +2)
            print_ok "VM ${VMID} (${VM_NAME}) — ${C_BOLD}${WIN_COUNT} Windows updates installed${C_NC}${local_suffix}"
            VM_WIN_UPDATED=$((VM_WIN_UPDATED + 1))
            VM_UPDATED=$((VM_UPDATED + 1))
            ESCAPED_NAMES=$(echo "${WIN_NAMES}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
            PKG_LIST_HTML=$(echo "${ESCAPED_NAMES}" | awk '{print "<li>" $0 "</li>"}')
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${os_icon}${html_suffix}</td><td><span class='status-badge badge-success'>Updated</span></td><td><strong>${WIN_COUNT} update(s) installed:</strong><ul class='pkg-list'>${PKG_LIST_HTML}</ul></td></tr>"
        else
            print_ok "VM ${VMID} (${VM_NAME}) — Windows checked${local_suffix}"
            VM_CURRENT=$((VM_CURRENT + 1))
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${os_icon}${html_suffix}</td><td><span class='status-badge badge-no-updates'>No Updates</span></td><td>Windows is fully up to date.</td></tr>"
        fi
    else
        # ---- LINUX VM UPDATE ----
        start_spinner "Updating VM ${VMID} (${VM_NAME})..."
        LINUX_OUTPUT=$(update_linux_vm "${VMID}")
        stop_spinner

        if [ "${LINUX_OUTPUT}" = "EXEC_FAILED" ]; then
            print_fail "VM ${VMID} (${VM_NAME}) — guest exec failed${local_suffix}"
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${html_suffix}</td><td><span class='status-badge badge-error'>Error</span></td><td>Failed to execute update command via guest agent.</td></tr>"
        elif [ "${LINUX_OUTPUT}" = "TIMEOUT" ]; then
            print_warn "VM ${VMID} (${VM_NAME}) — update timed out${local_suffix}"
            VM_ERRORS=$((VM_ERRORS + 1))
            ERRORS_OCCURRED=true
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${html_suffix}</td><td><span class='status-badge badge-warning'>Timeout</span></td><td>Update command timed out after 5 minutes.</td></tr>"
        elif [ -n "${LINUX_OUTPUT}" ]; then
            UPDATES=$(echo "${LINUX_OUTPUT}" | grep -E '^\S+\s+\(' || true)
            if [ -n "${UPDATES}" ]; then
                PKG_COUNT=$(echo "${UPDATES}" | wc -l)
                print_ok "VM ${VMID} (${VM_NAME}) — ${C_BOLD}${PKG_COUNT} packages updated${C_NC}${local_suffix}"
                VM_UPDATED=$((VM_UPDATED + 1))
                ESCAPED_UPDATES=$(echo "${UPDATES}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
                PKG_LIST_HTML=$(echo "${ESCAPED_UPDATES}" | awk '{print "<li>" $0 "</li>"}')
                VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${html_suffix}</td><td><span class='status-badge badge-success'>Updated</span></td><td><strong>${PKG_COUNT} package(s) updated:</strong><ul class='pkg-list'>${PKG_LIST_HTML}</ul></td></tr>"
            else
                print_ok "VM ${VMID} (${VM_NAME}) — already up to date${local_suffix}"
                VM_CURRENT=$((VM_CURRENT + 1))
                VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${html_suffix}</td><td><span class='status-badge badge-no-updates'>No Updates</span></td><td>System fully up to date.</td></tr>"
            fi
        else
            print_ok "VM ${VMID} (${VM_NAME}) — already up to date${local_suffix}"
            VM_CURRENT=$((VM_CURRENT + 1))
            VM_HTML="${VM_HTML}<tr><td><strong>${VMID}</strong> (${VM_NAME})${html_suffix}</td><td><span class='status-badge badge-no-updates'>No Updates</span></td><td>System fully up to date.</td></tr>"
        fi
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
section_header "Proxmox Host (${HOST_NAME})"
HOST_UPDATE_FAILED=false

start_spinner "Checking for host updates..."
apt-get update -qy >/dev/null 2>&1
HOST_UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep '/' || true)
stop_spinner

if [ -n "${HOST_UPGRADABLE}" ]; then
    HOST_UPDATES=$(echo "${HOST_UPGRADABLE}" | awk -F'/' '{
        pkg=$1;
        split($2, a, " ");
        new_ver=a[2];
        match($0, /\[from: [^\]]+\]/);
        old_ver=substr($0, RSTART+7, RLENGTH-8);
        print pkg " (" old_ver " -> " new_ver ")"
    }')

    HOST_PKG_COUNT=$(echo "${HOST_UPDATES}" | wc -l)

    start_spinner "Installing ${HOST_PKG_COUNT} host updates..."
    if DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -qy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" 2>&1; then
        apt-get autoremove -qy >/dev/null 2>&1
        apt-get autoclean -qy >/dev/null 2>&1
        stop_spinner

        print_ok "${C_BOLD}${HOST_PKG_COUNT} host packages updated${C_NC}"
        HOST_STATUS_BADGE="<span class='status-badge badge-success'>Updated</span>"
        ESCAPED_HOST_UPDATES=$(echo "${HOST_UPDATES}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        PKG_LIST_HTML=$(echo "${ESCAPED_HOST_UPDATES}" | awk '{print "<li>" $0 "</li>"}')
        HOST_SUMMARY_TEXT="<strong>${HOST_PKG_COUNT} host package(s) updated:</strong><ul class='pkg-list'>${PKG_LIST_HTML}</ul>"
    else
        stop_spinner
        HOST_UPDATE_FAILED=true
        ERRORS_OCCURRED=true
        HOST_STATUS_BADGE="<span class='status-badge badge-error'>Failed</span>"
        HOST_SUMMARY_TEXT="<strong>apt-get dist-upgrade failed!</strong> Check log: ${LOG_FILE}"
        print_fail "${C_RED}Host apt-get dist-upgrade FAILED — reboot will NOT be scheduled${C_NC}"
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

# --- Determine if a reboot is needed ---
REBOOT_NEEDED=false
REBOOT_REASON=""
RUNNING_KERNEL=$(uname -r)
LATEST_KERNEL=$(ls -t /boot/vmlinuz-* 2>/dev/null | head -1 | sed 's|/boot/vmlinuz-||' || true)

if [ -n "${LATEST_KERNEL}" ] && [ "${RUNNING_KERNEL}" != "${LATEST_KERNEL}" ]; then
    REBOOT_NEEDED=true
    REBOOT_REASON="Kernel updated: ${RUNNING_KERNEL} &rarr; ${LATEST_KERNEL}"
    print_warn "Kernel change detected: ${C_BOLD}${RUNNING_KERNEL} → ${LATEST_KERNEL}${C_NC}"
fi

if [ -f /var/run/reboot-required ]; then
    REBOOT_NEEDED=true
    [ -z "${REBOOT_REASON}" ] && REBOOT_REASON="System flagged reboot-required"
fi

if [ "${HOST_UPDATE_FAILED}" = true ]; then
    REBOOT_NEEDED=false
    REBOOT_REASON="Reboot SKIPPED — host update failed"
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
  .summary-box { background: #f8f9fa; border: 1px solid #dee2e6; padding: 15px; border-radius: 6px; margin: 15px 0; font-size: 13px; line-height: 1.8; }
  .footer { margin-top: 25px; font-size: 12px; color: #6c757d; text-align: center; border-top: 1px solid #eee; padding-top: 15px; }
</style>
</head>
<body>
  <div class='container'>
    <div class='header'>
      <h1>Proxmox VE Maintenance Report</h1>
    </div>

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
      Host: ${HOST_PKG_COUNT} packages
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

if [ "${ERRORS_OCCURRED}" = true ]; then
    EMAIL_SUBJECT="[Proxmox] ⚠ Update Report (ERRORS) - ${HOST_NAME} (${TIMESTAMP})"
else
    EMAIL_SUBJECT="[Proxmox] ✓ Update Report - ${HOST_NAME} (${TIMESTAMP})"
fi

start_spinner "Sending report via Mailgun ${MAILGUN_REGION}..."
MAILGUN_RESPONSE_FILE="/tmp/mailgun_response_$$.txt"
HTTP_CODE=$(curl -s -o "${MAILGUN_RESPONSE_FILE}" -w "%{http_code}" \
    --user "api:${MAILGUN_API_KEY}" \
    "${MAILGUN_API_URL}" \
    -F from="${SENDER_EMAIL}" \
    -F to="${RECIPIENT_EMAIL}" \
    -F subject="${EMAIL_SUBJECT}" \
    -F html="<${HTML_FILE}" 2>&1) || true
stop_spinner

if [ "${HTTP_CODE}" = "200" ]; then
    print_ok "Report dispatched to ${C_BOLD}${RECIPIENT_EMAIL}${C_NC}"
else
    print_fail "Mailgun API returned HTTP ${HTTP_CODE}"
    if [ -f "${MAILGUN_RESPONSE_FILE}" ]; then
        echo "     Response: $(cat "${MAILGUN_RESPONSE_FILE}")"
    fi
fi
rm -f "${MAILGUN_RESPONSE_FILE}"

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

if [ "${REBOOT_NEEDED}" = true ]; then
    echo -e "  ${C_YELLOW}⚠ Reboot scheduled at ${REBOOT_TIME}${C_NC}"
fi

echo ""
echo -e "${C_BOLD}${C_CYAN}══════════════════════════════════════════════════════════════${C_NC}"
if [ "${ERRORS_OCCURRED}" = true ]; then
    echo -e "  ${C_RED}${C_BOLD}Update sequence complete — with errors${C_NC}"
else
    echo -e "  ${C_GREEN}${C_BOLD}Update sequence complete — all clear ✓${C_NC}"
fi
echo -e "${C_BOLD}${C_CYAN}══════════════════════════════════════════════════════════════${C_NC}"
echo ""