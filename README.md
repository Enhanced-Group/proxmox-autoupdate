# Proxmox VE Automated Infrastructure Updater

A fully automated maintenance solution for Proxmox VE hosts with fancy terminal output, Windows VM support, and stopped guest updates.

This tool performs weekly updates across your entire Proxmox stack — including the host node, all LXC containers (running **and** stopped), Linux VMs, and Windows VMs — then delivers a detailed HTML report via Mailgun and conditionally reboots when a kernel update is detected.

---

## Features

- **Complete Infrastructure Coverage:** Updates the Proxmox VE host, LXC containers, Linux VMs, and Windows VMs.
- **Stopped Guest Updates:** Automatically starts stopped containers and VMs, applies updates, and restores them to their original state.
- **Windows VM Support:** Detects Windows VMs via QEMU Guest Agent and runs Windows Update using native PowerShell COM objects (no extra modules needed).
- **Multi-Distro Container Support:** Detects and updates `apt` (Debian/Ubuntu), `yum` (RHEL/CentOS), and `apk` (Alpine) based containers.
- **Fancy Terminal Output:** Braille dot spinners, ANSI color-coded results, Unicode box-drawing banners, and a summary table.
- **Interactive Configuration:** Prompts for Mailgun credentials, region, exclusion list, and Windows timeout during install. Stored securely in `/etc/proxmox-autoupdate.conf` (`chmod 600`).
- **EU & US Mailgun Regions:** Quick 1/2 selection during install — supports both `api.eu.mailgun.net` and `api.mailgun.net`.
- **UK Localization:** Timestamps formatted as `DD/MM/YYYY HH:MM:SS` in `Europe/London` timezone.
- **Proxmox Version Tracking:** Highlights exact PVE version deltas (e.g., `8.2.2 → 8.2.7`).
- **Smart Conditional Reboot:** Only reboots when a kernel update is detected. Never reboots after a failed upgrade.
- **Error Reporting:** Failures are flagged in the email subject and report body with red badges.
- **Exclusion List:** Skip specific VM/CT IDs via config (`EXCLUDE_IDS="100,201"`).
- **Concurrency Safe:** Lockfile prevents overlapping runs.
- **Full Logging:** Output logged to `/var/log/proxmox-autoupdate/` with 90-day auto-pruning.
- **Idempotent Deployment:** Re-running the installer safely updates everything while preserving config.

---

## Requirements

- **Proxmox VE 7.x or 8.x** host
- **Root access** — both the installer and update script must run as `root`
- **curl** — for downloading the script and sending emails
- **QEMU Guest Agent** — must be installed inside VMs you want to auto-update:
  - **Linux VMs:** Install `qemu-guest-agent` package
  - **Windows VMs:** Install the [QEMU Guest Agent for Windows](https://pve.proxmox.com/wiki/Qemu-guest-agent) (included in VirtIO drivers)
- **Mailgun account** — with a configured sending domain (EU or US region)
- **jq** *(optional but recommended)* — for reliable JSON parsing of guest agent responses

> **⚠ Important:** VMs without the QEMU Guest Agent will be reported as "Agent Offline" and skipped. For Windows VMs, ensure the VirtIO guest tools are installed.

---

## One-Command Quick Install / Update

Run this on your Proxmox host **as `root`**:

```bash
curl -sSL https://raw.githubusercontent.com/Enhanced-Group/proxmox-autoupdate/main/install.sh | bash
```

The installer will prompt for:
1. Mailgun API key, domain, and region (EU/US)
2. Sender and recipient email addresses
3. Exclusion list (VM/CT IDs to skip)
4. Windows Update timeout
5. Whether to start stopped Windows VMs for updates

All settings are saved to `/etc/proxmox-autoupdate.conf` and preserved on re-install.

---

## What Happens During an Update

```
╔═══════════════════════════════════════════════════════════╗
║  Proxmox Auto-Update                                     ║
║  Host: pve01.local │ 27/07/2026 23:00:01                 ║
╚═══════════════════════════════════════════════════════════╝

── LXC Containers ──────────────────────────────────────────
  ✓ LXC 100 (pihole) — 3 packages updated
  ✓ LXC 101 (nginx) — already up to date
  ▶ Starting LXC 102 (postgres) [was stopped]...
  ✓ LXC 102 (postgres) — 7 packages updated
  ■ Stopping LXC 102 (postgres) [restoring state]...

── Virtual Machines ────────────────────────────────────────
  ✓ VM 200 (ubuntu-srv) — 12 packages updated
  ✓ VM 201 (win-server) — 4 Windows updates installed
  ⊘ VM 202 (win-desktop) — stopped Windows VM, skipped

── Proxmox Host (pve01) ────────────────────────────────────
  ✓ 5 host packages updated
  ⚠ Kernel updated: 6.8.4 → 6.8.8 — reboot scheduled

── Summary ─────────────────────────────────────────────────
  LXC:  3 updated, 1 started+stopped, 0 errors
  VMs:  2 updated (1 Windows), 1 skipped, 0 errors
  Host: 5 packages
```

### Step-by-step:

1. **LXC Containers** — starts any stopped containers, runs updates via `pct exec`, then stops them again
2. **Linux VMs** — starts stopped VMs, waits for guest agent, updates via `pvesh`, restores state
3. **Windows VMs** — detects via `ostype` config and guest agent, runs Windows Update via PowerShell
4. **Proxmox Host** — updates the host with `apt-get dist-upgrade`
5. **HTML Report** — sends a summary email via Mailgun
6. **Conditional Reboot** — schedules midnight reboot only if a new kernel was installed

---

## Windows VM Support

### How It Works

Windows VMs are detected automatically via their `ostype` in the Proxmox config and confirmed via the QEMU Guest Agent's `get-osinfo` endpoint.

Updates are triggered using native PowerShell COM objects (`Microsoft.Update.Session`) — **no PowerShell modules need to be pre-installed** on the Windows guest.

### Timing Considerations

Windows Update is fundamentally slower than `apt-get`:

| Scenario | Typical Duration |
|----------|-----------------|
| Windows VM already running, few updates | 5-15 minutes |
| Windows VM already running, cumulative updates | 15-60 minutes |
| Stopped Windows VM (boot + update + shutdown) | 10-90+ minutes |

The default timeout is **20 minutes** (1200 seconds), configurable via `WINDOWS_UPDATE_TIMEOUT` in the config file.

### Stopped Windows VMs

By default, **stopped Windows VMs are skipped** (`START_STOPPED_WINDOWS=false`). This is because:
- Windows boot + update + shutdown can easily exceed 30 minutes
- Windows Update sometimes requires mid-process reboots
- A timed-out update leaves the VM running to avoid corruption

To enable: set `START_STOPPED_WINDOWS=true` in the config or re-run the installer.

### Timeout Behavior

If a Windows Update exceeds the timeout:
- The VM is **left running** (never force-stopped mid-update)
- The report shows a ⚠ "Timeout" badge
- The update will continue to completion in the background

---

## Configuration

All settings are stored in `/etc/proxmox-autoupdate.conf`:

```bash
# Mailgun credentials
MAILGUN_API_KEY="your-key"
MAILGUN_DOMAIN="mg.example.com"
MAILGUN_REGION="EU"              # EU or US

# Email
SENDER_EMAIL="noreply@example.com"
RECIPIENT_EMAIL="admin@example.com"

# Exclusions (comma-separated VM/CT IDs)
EXCLUDE_IDS="300,301"

# Windows settings
WINDOWS_UPDATE_TIMEOUT="1200"    # seconds (default: 20 min)
START_STOPPED_WINDOWS="false"    # start stopped Windows VMs?

# Timing settings
UPDATE_SCHEDULE_CRON="0 23 * * 5" # Fridays at 23:00 (cron 5-field format)
REBOOT_TIME="00:00"              # HH:MM format for post-update reboot (if kernel updated)
```

---

## Schedule & Reboot Timing

Both the update trigger time and the reboot time are fully customizable during installation or via `/etc/proxmox-autoupdate.conf`:

- **Cron Schedule (`UPDATE_SCHEDULE_CRON`):** Choose from preset Friday times (23:00, 22:00, 20:00, 10:00) or specify any custom 5-field cron expression.
- **Reboot Time (`REBOOT_TIME`):** Specify when the host should reboot if a kernel update was installed (e.g. `00:00`, `01:00`, `02:00`).

To reconfigure at any time, re-run `install.sh` or edit `/etc/proxmox-autoupdate.conf` directly and update crontab (`crontab -e`).

---

## Logs

All output is logged to:

```
/var/log/proxmox-autoupdate/update_YYYYMMDD_HHMMSS.log
```

Logs older than 90 days are automatically pruned on each run.

---

## Uninstall

```bash
# Remove the update script
rm -f /usr/local/bin/update-everything.sh

# Remove the configuration
rm -f /etc/proxmox-autoupdate.conf

# Remove the cron job
crontab -l | grep -v 'update-everything.sh' | grep -v 'proxmox-autoupdate' | crontab -

# (Optional) Remove logs
rm -rf /var/log/proxmox-autoupdate/

# Cancel any pending reboot
shutdown -c 2>/dev/null || true
```

---

## License

MIT
