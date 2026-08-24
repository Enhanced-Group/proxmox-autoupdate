# Proxmox VE Automated Infrastructure Updater

A fully automated maintenance solution for Proxmox VE hosts with fancy terminal output, Windows VM support, and stopped guest updates.

This tool performs weekly updates across your entire Proxmox stack — including the host node, all LXC containers (running **and** stopped), Linux VMs, and Windows VMs — then delivers a detailed HTML report via Mailgun and conditionally reboots when a kernel update is detected.

---

## Features

- **Complete Infrastructure Coverage:** Updates the Proxmox VE host, LXC containers, Linux VMs, and Windows VMs.
- **Stopped Guest Updates:** Automatically starts stopped containers and VMs, applies updates, and restores them to their original state.
- **Windows VM Support:** Detects Windows VMs via QEMU Guest Agent and runs Windows Update using native PowerShell COM objects (no extra modules needed).
- **Multi-Distro Container Support:** Detects and updates `apt` (Debian/Ubuntu), `dnf`/`yum` (RHEL/Fedora/CentOS) and `apk` (Alpine), `zypper` (openSUSE/SLES) and `pacman` (Arch) based containers. The in-guest script is POSIX `sh`, so it runs on Alpine's BusyBox shell as well as Debian's dash. Guests using `zypper` or `pacman` are reported as unsupported rather than silently skipped.
- **Honest Result Reporting:** Guests report status through explicit markers rather than exit codes, so a benign non-zero `apt` exit is no longer reported as a failure — and a real failure is never reported as success. Packages that were genuinely upgraded are distinguished from those held back.
- **Dry Run Mode:** `update-everything.sh --dry-run` reports exactly what would be upgraded and changes nothing at all — no packages, no snapshots, no reboot, and no starting or stopping of guests. Stopped guests are listed as skipped.
- **Self-Diagnostic:** `update-everything.sh --doctor` checks everything a run depends on — Proxmox detected, cluster filesystem answering, dependencies present, repositories working, cron running, guest agents responding, disk space — and exits non-zero with a numbered list of what to fix. Read-only.
- **Pre-Update Snapshots:** Optionally snapshot each guest before updating, with automatic pruning of old auto-snapshots.
- **Web Control Panel:** Optional **Update Everything** button in the Proxmox toolbar (left of *Documentation*) — run updates, manage exclusions, edit the schedule and config, and read past reports without touching a shell. Authorised by your existing Proxmox login.
- **Flexible Notifications:** Email over **any SMTP server** or Mailgun, Discord (channel *or* direct message, with the log attached as a file), Slack, **Microsoft Teams**, **ntfy**, **Gotify**, **Telegram**, and any JSON webhook — in any combination, or none at all.
- **Per-Guest Updates:** Each VM and container gets an **Update Now** button in its toolbar — patch a single guest without running the whole sweep, or exclude it from the schedule with one click. Also available as `--only <id>` on the CLI.
- **Fancy Terminal Output:** Braille dot spinners, ANSI color-coded results, Unicode box-drawing banners, and a summary table.
- **Interactive Configuration:** Prompts for notification channels, exclusion list, timeouts, schedule, reboot time and the web panel during install. Stored in `/etc/proxmox-autoupdate.conf` (`chmod 600`, created with those permissions before anything is written to it).
- **EU & US Mailgun Regions:** Quick 1/2 selection during install — supports both `api.eu.mailgun.net` and `api.mailgun.net`.
- **Local Time:** Timestamps and the scheduled reboot follow the host's own timezone. Set `PAU_TZ` in the config to pin a specific one.
- **Proxmox Version Tracking:** Highlights exact PVE version deltas (e.g., `8.2.2 → 8.2.7`).
- **Multiple Schedules, Per-Schedule Reboot Control:** Run updates as often as you like and reboot as rarely as you need. A weekly schedule marked "never reboots" installs the new kernel and records that a reboot is owed; a monthly one that may reboot takes it. Up to ten schedules, editable in the panel or the installer.
- **Smart Conditional Reboot:** Reboots only when *this run* installed a newer kernel than the one booted, or when the system flags `/var/run/reboot-required`. Kernels are compared by version, not by file timestamp, so a pinned or reinstalled older kernel cannot cause a reboot every run. Never reboots after a failed upgrade, a targeted run, or while a guest is mid-update.
- **Error Reporting:** Failures are flagged in the email subject and report body with red badges.
- **Exclusion List:** Skip specific VM/CT IDs via config (`EXCLUDE_IDS="100,201"`).
- **Concurrency Safe:** A `flock` lockfile prevents overlapping runs, and the web panel refuses to start one while a scheduled run is going.
- **Honest Exit Codes:** `0` clean, `1` errors occurred, `2` guests left mid-update — so cron wrappers and `systemctl status` reflect reality.
- **Customisable Appearance:** Recolour the panel's accent, success, warning and error colours from the Configuration tab, with presets and a live preview. Text contrast is adjusted automatically.
- **Full Logging:** Output logged to `LOG_DIR` (default `/var/log/proxmox-autoupdate/`), pruned after `LOG_RETENTION_DAYS` (default 90; `0` keeps forever). `cron.log` is rotated by logrotate.
- **Idempotent Deployment:** Re-running the installer safely updates everything while preserving config.

---

## Requirements

- **Proxmox VE host** — 7.x, 8.x and 9.x are all supported. There is no version gate; the installer refuses to run anywhere `pveversion` and `/etc/pve` are not both present, so it will not install on plain Debian, on a Proxmox Backup Server, or inside a container.
- **Root access** — the installer, the update script and the uninstaller all check for it and refuse otherwise.
- **QEMU Guest Agent** — must be installed inside VMs you want to auto-update:
  - **Linux VMs:** Install `qemu-guest-agent` package
  - **Windows VMs:** Install the [QEMU Guest Agent for Windows](https://pve.proxmox.com/wiki/Qemu-guest-agent) (included in VirtIO drivers)

Required packages — the installer adds the first two automatically if missing, and `update-everything.sh --doctor` reports on all of them:

| Package | Why |
|---|---|
| `jq` | Every guest-agent reply is parsed as JSON |
| `python3` | Report payloads and the run-history state file; also the web panel |
| `curl` | Downloads and notification delivery |
| `util-linux` (`flock`) | The lockfile that prevents overlapping runs |
| `cron` (running) | Nothing triggers the schedule without it |
| `psmisc` | Optional. Used by the panel's run-in-progress indicator |
| `linux-base` | Optional. Accurate kernel version comparison |
| `systemd` (`systemd-run`) | Optional. Needed by `--detach` |

**Notifications are entirely optional.** With no channel configured the tool still updates on schedule — it just does so quietly. Email works with any SMTP server; Mailgun is supported but no longer required.

> **⚠ Important:** VMs without the QEMU Guest Agent will be reported as "Agent Offline" and skipped. For Windows VMs, ensure the VirtIO guest tools are installed.

---

## Before You Install

**On a stock Proxmox install this works out of the box.** Everything it needs is
either already there or installed for you, and the installer refuses to run
anywhere that isn't a Proxmox VE host. You do not need to prepare anything.

There are, however, four things worth knowing first — two of which catch almost
everybody.

### 1. The enterprise repository, if you have no subscription

A fresh Proxmox enables `pve-enterprise`, which returns **HTTP 401** without a
subscription. `apt-get update` then fails on every run and **the host can never
be updated** — while Debian's own repositories keep working, so it is easy to
miss.

This is the single most common reason a homelab install appears to do nothing.
Check with:

```bash
update-everything.sh --doctor
```

It detects this case specifically and names it. To fix, either buy a
subscription (it funds Proxmox) or switch to the no-subscription repository —
Proxmox documents both.

### 2. VMs need the guest agent; containers do not

Containers are updated through `pct exec` and need nothing installed.

**VMs are different.** There is no way into a VM without the QEMU guest agent,
so a VM without it is reported as *Agent Offline* and skipped — permanently, and
quietly, unless you look. Two steps, both required:

1. Enable the agent in Proxmox: **VM → Options → QEMU Guest Agent → Enabled**
2. Install it **inside** the guest:
   - Debian/Ubuntu: `apt install qemu-guest-agent`
   - RHEL/Alma/Rocky: `dnf install qemu-guest-agent`
   - Windows: the VirtIO driver ISO, which includes `qemu-ga`

`--doctor` lists every running VM whose agent is not answering.

### 3. Decide what should happen to stopped guests

By default, **stopped containers are started, updated and stopped again**;
stopped VMs are left alone. That is often not what people expect, in either
direction. The defaults:

| Setting | Default | Effect |
|---|---|---|
| `START_STOPPED_LXC` | `true` | Stopped containers are booted, updated, then returned to stopped |
| `START_STOPPED_LINUX_VMS` | `true` | Same for Linux VMs |
| `START_STOPPED_WINDOWS` | `false` | Stopped Windows VMs are skipped |

If you have containers that are stopped deliberately — a spare, a broken
experiment, something half-built — set `START_STOPPED_LXC=false` before the
first scheduled run.

### 4. Snapshots are off by default

`SNAPSHOT_BEFORE_UPDATE=false`. Turning it on requires storage that supports
snapshots (ZFS, LVM-thin, or qcow2 on directory storage); on plain LVM or raw
disks the snapshot fails and the guest is updated anyway.

### Then, before you trust it

Run the two read-only checks in order. Neither changes anything:

```bash
update-everything.sh --doctor
```

```bash
update-everything.sh --dry-run
```

A dry run reports exactly what a real run would install, and starts nothing,
installs nothing and reboots nothing. If both look right, the scheduled run will
do what you expect.

### What it will not do for you

- **Containers inside your guests.** Docker and Podman hosts are detected and
  reported, but their images are never pulled or restarted — that needs compose
  files and restart ordering, and it can take a stack down in ways `apt` cannot.
- **Anything on another node.** Each install manages its own host.
- **Reboot unexpectedly.** A reboot is scheduled only when this run installed a
  new kernel, or when the system itself has flagged `/var/run/reboot-required`.
  It is always suppressed during a `--dry-run`, during a `--only` run, when the
  host upgrade failed, and when any guest was left mid-update — taking the host
  down then would kill `dpkg` part way through inside it. The time is
  `REBOOT_TIME`, in the host's own timezone.

---

## One-Command Quick Install / Update

Run this on your Proxmox host **as `root`**:

```bash
curl -sSL https://raw.githubusercontent.com/Enhanced-Group/proxmox-autoupdate/main/install.sh | bash
```

> **Don't want the web UI?** The installer asks, and the answer defaults to
> **no** — say no and you get the updater and nothing else: no extra service, no
> open port, no change to any Proxmox file.
>
> If you'd rather run the older release that predates the web UI entirely, it's
> preserved on the **`no-web-ui`** branch (tag `v2.3-no-web-ui`):
>
> ```bash
> curl -sSL https://raw.githubusercontent.com/Enhanced-Group/proxmox-autoupdate/no-web-ui/install.sh | bash
> ```
>
> Note that branch does **not** include the guest-update reliability fixes in
> v3.0 — it still reports a failed job when `apt` exits non-zero for a benign
> reason. Prefer `main` with the UI declined.

The installer will prompt for:
1. Mailgun API key, domain, and region (EU/US)
2. Sender and recipient email addresses
3. Exclusion list (VM/CT IDs to skip)
4. Windows Update timeout, Linux update timeout, and apt lock wait
5. Whether to start stopped Windows VMs, Linux VMs, and LXC containers
6. Whether to snapshot guests before updating (and how many to keep)
7. Cron schedule and reboot time

All settings are saved to `/etc/proxmox-autoupdate.conf` and preserved on re-install.

At the end, it offers to run immediately:

| Choice | What it does |
|--------|--------------|
| **Dry run** *(default)* | Checks the host and every running guest, reports in full, installs nothing, never reboots, and never starts or stops a guest |
| **Full run** | Updates everything now, then emails the report (asks for typed confirmation first) |
| **Skip** | Waits for the scheduled run |

If a notification channel is configured, both run modes deliver the report through it, so either one verifies the channel end to end. With no channel configured the run is simply quiet — the full output is on screen and in the log directory.

---

## Dry Run

Preview what would be updated without changing anything:

```bash
/usr/local/bin/update-everything.sh --dry-run
```

No packages are installed, no snapshots are taken, and no reboot is scheduled — but the full HTML report is still emailed, marked `[DRY RUN]` in the subject.

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
WINDOWS_UPDATE_TIMEOUT="3600"    # seconds a Windows guest gets to install (default: 60 min)
WINDOWS_SHUTDOWN_TIMEOUT="900"   # seconds to wait for a Windows guest to shut down.
                                 # Never escalated to a forced stop: a guest still
                                 # servicing updates is left running instead.
START_STOPPED_WINDOWS="false"    # start stopped Windows VMs?

# Linux guest settings
LINUX_UPDATE_TIMEOUT="1800"      # seconds a Linux guest gets to finish (default: 30 min)
APT_LOCK_TIMEOUT="600"           # seconds apt waits for the dpkg lock inside a guest
START_STOPPED_LXC="true"
START_STOPPED_LINUX_VMS="true"
LINUX_SHUTDOWN_TIMEOUT="180"     # seconds before a started Linux guest is forced off
AGENT_ERROR_GRACE="120"          # seconds of guest-agent errors tolerated mid-update

# Snapshots
SNAPSHOT_BEFORE_UPDATE="false"   # snapshot each guest before updating it
SNAPSHOT_KEEP="3"                # auto-snapshots to keep per guest

# Dry run — leave false for scheduled runs, use --dry-run for one-offs
DRY_RUN="false"

# Logs
LOG_DIR="/var/log/proxmox-autoupdate"   # where run logs are written
KEEP_LOGS="true"                 # false still streams a run live, then deletes it
LOG_RETENTION_DAYS="90"          # 0 keeps them forever

# Timezone used for timestamps and REBOOT_TIME. Empty means the host's own.
PAU_TZ=""

# Ask before starting an update. Deletions and uninstall always confirm.
# Read by the web panel only — the update script never looks at it.
CONFIRM_UPDATES="true"

# Notifications — all optional; empty NOTIFY_METHODS means updates run quietly
NOTIFY_METHODS=""                # email, discord, slack, webhook (comma-separated)
NOTIFY_ON_FAILURE_ONLY="false"

# Schedules. Read by the installer and the web panel, which write them into
# root's crontab. A run never consults this list — its own cron line already
# carries --no-reboot or not.
#   <5-field cron>|<yes|no, may it reboot>|<label>, ';'-separated
UPDATE_SCHEDULES='0 23 * * 5|no|Weekly updates;0 3 1 * *|yes|Monthly reboot'
UPDATE_SCHEDULE_CRON="0 23 * * 5" # first schedule; kept for older versions
REBOOT_TIME="00:00"              # HH:MM, for whichever schedule may reboot
```

### Why `APT_LOCK_TIMEOUT` matters

Ubuntu enables `unattended-upgrades` by default. If it happens to be holding the
dpkg lock when this script runs, `apt-get` exits with code **100** immediately —
which older versions of this script reported as a failed update even though
nothing was actually wrong. `APT_LOCK_TIMEOUT` makes apt wait for the lock
instead of giving up.

---

## How Guest Results Are Determined

Guests do **not** signal success through their exit status, because `apt-get`
legitimately exits non-zero for reasons that aren't update failures: lock
contention, `needrestart` prompts, or services that can't restart inside an
unprivileged container.

Instead the in-guest script emits explicit markers, and the host classifies the
run from those:

| Result | Meaning |
|--------|---------|
| **Updated** | Packages were verifiably upgraded (confirmed by re-checking what is still upgradable afterwards) |
| **No Updates** | Nothing was pending |
| **Held back** | Listed as upgradable before *and* after the run — shown separately, not counted as updated |
| **Error** | The guest reported a real failure; the report includes the exit code and the last 20 lines of apt output |
| **Timeout** | The upgrade was still running when the budget expired. The guest is **left running** so `dpkg` can finish, and the host reboot is suppressed |
| **Agent Lost** | The guest agent stopped answering mid-upgrade. Guest left running; state unknown |

A guest that produces no result marker at all is reported as an **error**, never
as "up to date" — a run that was killed part way through must not be mistaken
for a clean one.

---

## Schedules and reboot timing

You can have more than one schedule, and each one decides for itself whether it
is allowed to reboot the host.

That combination is the point. Updates are safe to apply weekly; the reboot a
new kernel needs is the part that costs you an outage. So:

Each schedule is one of three things:

| Mode | Config value | Cron line gets | What it does |
| --- | --- | --- | --- |
| Update · reboot if needed | `yes` | *(no flag)* | Installs updates, and reboots if this run installed a kernel. |
| Update · never reboot | `no` | `--no-reboot` | Installs everything, kernel included, and leaves the host on the old one. |
| Reboot window · no updates | `only` | `--reboot-window` | Installs nothing. Reboots **only** if a reboot is already owed. |

A worked example — updates weekly, outage monthly:

| Schedule | Mode | What happens |
| --- | --- | --- |
| `0 23 * * 5` — Friday 23:00 | `no` | Installs everything, including the new kernel. The host keeps running the old one. |
| `0 3 1 * *` — 1st of the month, 03:00 | `only` | Touches no packages. Boots into the kernel that has been waiting; does nothing at all if none is. |

Use `only` when the outage should have its own slot and nothing else. Use `yes`
on the monthly run instead if you would rather it also install whatever has
appeared since Friday.

Set it up during install, or on the panel's **Schedule** tab, where each row has
its own mode. Up to ten schedules.

### How a held reboot is handed over

A schedule that may not reboot still installs the kernel. It records that a
reboot is owed, in `/var/lib/proxmox-autoupdate/reboot-pending`, and says so in
its report — *Reboot Pending*, not *No Reboot Needed*, so a host is never
quietly out of date.

The next run that **is** allowed to reboot picks that up and books the reboot,
even though it installed nothing itself. The record is cleared as soon as the
host is seen running the newest installed kernel, whether it got there through
this tool or because you rebooted it yourself.

`update-everything.sh --doctor` reports a pending reboot, and warns if *no*
schedule may reboot — a configuration where a new kernel would install and then
wait indefinitely.

### In the config file

```bash
# One entry per schedule, ';'-separated:  <5-field cron>|<mode>|<label>
# mode: yes = update and reboot | no = update, never reboot
#       only = reboot window, installs nothing
UPDATE_SCHEDULES='0 23 * * 5|no|Weekly updates;0 3 1 * *|only|Reboot window'

# When the reboot happens, for whichever schedule is allowed to take it.
REBOOT_TIME="00:00"
```

Each schedule becomes one line in root's crontab; the ones marked `no` are run
with `--no-reboot`:

```
# proxmox-autoupdate
# proxmox-autoupdate: Weekly updates (no reboot)
0 23 * * 5 /usr/local/bin/update-everything.sh --no-reboot >> /var/log/proxmox-autoupdate/cron.log 2>&1
# proxmox-autoupdate: Reboot window (reboot window)
0 3 1 * * /usr/local/bin/update-everything.sh --reboot-window >> /var/log/proxmox-autoupdate/cron.log 2>&1
```

`UPDATE_SCHEDULE_CRON` is still written, holding the first schedule's
expression, so a config from an earlier version keeps working — a single
schedule that is allowed to reboot, which is what it always meant.

### One warning about monthly cron expressions

cron **ORs** day-of-month with day-of-week when both are restricted. The obvious
way to write "first Sunday of the month" — `0 3 1-7 * 0` — actually fires on the
1st to the 7th *and* on every Sunday, which is weekly. Use a day of the month
(`0 3 1 * *`) and leave day-of-week as `*`.

To reconfigure at any time, re-run `install.sh`, use the panel, or edit
`/etc/proxmox-autoupdate.conf` and re-save the schedule from the panel so the
crontab is rewritten to match. `--doctor` warns when the two have drifted.

---

## Snapshots

With `SNAPSHOT_BEFORE_UPDATE="true"`, each guest is snapshotted immediately
before its upgrade, named `autoupdate_YYYYMMDD_HHMMSS`.

- Only snapshots carrying the `autoupdate` prefix are ever pruned — your manual
  snapshots are never touched.
- The oldest are removed to keep at most `SNAPSHOT_KEEP` per guest.
- If a snapshot **fails**, that guest is skipped rather than updated without a
  rollback point, and the run is flagged as an error.
- Requires snapshot-capable storage (ZFS, LVM-thin, or qcow2). It will fail on
  raw LVM or directory storage using raw images.

Roll back with:

```bash
qm rollback <vmid> autoupdate_20260731_230014     # VMs
pct rollback <ctid> autoupdate_20260731_230014    # containers
```

---

## Notifications

**Entirely optional.** With no channel configured the updates still run on
schedule — they just run quietly. You can skip setup at install time and add a
channel later from the panel or the config file; nothing about updating depends
on it.

| Channel | Config key | Notes |
|---|---|---|
| Email | `MAILGUN_*` | The full HTML report |
| Discord — channel | `DISCORD_WEBHOOK_URL` | Colour-coded embed, green/red/grey for ok/error/dry-run |
| Discord — DM | `DISCORD_BOT_TOKEN` + `DISCORD_USER_ID` | Same report, sent to you directly |
| Slack / Teams | `SLACK_WEBHOOK_URL` | Teams works via an incoming-webhook connector |
| Generic | `GENERIC_WEBHOOK_URL` | JSON POST — ntfy, Gotify, Home Assistant, n8n, anything |

```bash
NOTIFY_METHODS="discord,webhook"     # comma-separated; empty = silent
NOTIFY_ON_FAILURE_ONLY="true"        # stay quiet on clean runs
```

### Discord

The **full run log is attached as a `.log` file**, not pasted into the message —
Discord truncates content at 2000 characters and an embed at 4096, which a real
run comfortably exceeds. Logs above the per-file upload limit are split across
several messages so nothing is lost.

To DM the report to yourself instead of posting to a channel, set a bot token
and your user ID:

```bash
DISCORD_BOT_TOKEN="..."              # bot token, not a webhook URL
DISCORD_USER_ID=""                   # Developer Mode → right-click yourself → Copy User ID
```

With both set, the report is DM'd; a `DISCORD_WEBHOOK_URL` is kept as a fallback
if the DM can't be opened. **The bot is never run as a process** — there is no
gateway connection and nothing stays logged in. The token is only used as an
`Authorization` header on two ordinary POSTs at report time:

```
POST /api/v10/users/@me/channels      → open the DM channel
POST /api/v10/channels/{id}/messages  → send the report and attach the log
```

Discord only permits the DM if the bot shares a server with you. If it doesn't,
the panel says so rather than failing silently.

The generic webhook payload:

```json
{
  "title": "[Proxmox] ✓ Update Report - pve01 (31/07/2026 23:00:14)",
  "message": "Completed successfully\n\nHost: pve01\n...",
  "status": "success", "dry_run": false, "host": "pve01",
  "pve_version": "9.2.5", "reboot_scheduled": false,
  "repeat_offenders": "OGL-Server (101) x3",
  "counts": {"lxc_updated": 3, "lxc_errors": 0, "vm_updated": 2,
             "vm_errors": 0, "host_packages": 5}
}
```

**Webhook URLs are credentials** — anyone holding one can post to your channel.
They live in `/etc/proxmox-autoupdate.conf` (`chmod 600`) and are masked in the UI.

There's a **Send test notification** button in the panel. It runs the real
notifier, so if the test arrives, real reports will too.

A failing notification never fails a run — the updates already happened, and not
being able to talk about them is the lesser problem.

---

## Running from the Proxmox Shell

Closing the browser tab kills the shell session, which used to kill the update
with it — leaving `dpkg` half-configured. Two fixes: the script now ignores
`SIGHUP`, and `--detach` hands the run to systemd so it isn't yours to kill:

```bash
update-everything.sh --detach
journalctl -fu pve-autoupdate-run    # watch it
```

Runs started from the web panel already survive this.

---

## Web Control Panel

Optional. Adds an **Auto-Update** button to the Proxmox toolbar, immediately to
the left of *Documentation*:

```
[ Auto-Update ] [ Documentation ] [ Create VM ] [ Create CT ]
```

Two buttons are added:

```
Top toolbar:        [ ⟳ Update Everything ● ]  Documentation   Create VM   Create CT
LXC / Linux VM:     [ ⟳ Update Now ]           Start   Shutdown   Console   More   Help
Windows VM:         (no button — scheduled runs only)
```

The node button carries a **status dot**: green if the last run was clean, red if
it reported errors, amber while one is running. Hovering shows when it last ran
and any guests that keep failing — so problems are visible without opening
anything.

Clicking opens a panel with seven tabs:

| Tab | What it does |
|-----|--------------|
| **Run** | Dry run, or "Update everything now" (requires typing `UPDATE`), with live streaming output |
| **Exclusions** | Tick-list of every VM and container — choose which ones the scheduled run skips |
| **Schedule** | Change the cron expression and reboot time — writes both the config and the crontab |
| **Notifications** | Enable channels, paste webhook URLs, send a test notification |
| **Configuration** | Timeouts, snapshots, start-stopped behaviour |
| **Logs & Reports** | Keep-or-discard, retention period, where they live, how much space, purge, and browse past runs |
| **Maintenance** | Version check and update, changelog, confirmation preference, run history, uninstall |

### Per-guest updates

A per-guest run:

- touches **only** that guest — the Proxmox host is not updated
- **never** schedules a reboot
- sends **no** report when started from the panel (you're watching the output live). From the shell, add `--no-email` for the same behaviour

The same thing from the shell:

```bash
update-everything.sh --only 101              # update guest 101 only
update-everything.sh --only 100,102 --no-email
update-everything.sh --only 101 --dry-run    # check without installing
```

### How it's put together

The panel is a **standalone service**, not a modification of Proxmox's backend:

```
Toolbar button  ──►  https://<host>:8007/  (pve-autoupdate-ui.service)
(appended to                                      │
 pvemanagerlib.js)                                ▼
                                    /usr/local/bin/update-everything.sh
```

Only the injected JavaScript touches a Proxmox-owned file, and it's **appended**
to the end of `pvemanagerlib.js` between markers rather than spliced into
Proxmox's own definitions — appending cannot break the code above it, and
removal is an exact delete between two markers. The buttons are placed by a
short `Ext.ComponentQuery` sweep once the UI has rendered, so it doesn't depend
on how those panels are built internally; if a future Proxmox release reshapes
them, you lose the button rather than the page.

The file is never rewritten in place. Each edit is staged to a temporary file in
the same directory and swapped in with an atomic rename, so an interrupted
write — power loss, out of memory, a full disk — cannot leave a truncated
`pvemanagerlib.js` behind. A pristine copy is kept at
`/var/lib/proxmox-autoupdate/pvemanagerlib.js.orig`; restore it with
`pve-autoupdate-patch-webui restore`.

A `pve-manager` upgrade replaces that file and removes the button. An apt hook at
`/etc/apt/apt.conf.d/99-proxmox-autoupdate-webui` re-applies it automatically
afterwards. To check or fix it by hand:

```bash
pve-autoupdate-patch-webui status
pve-autoupdate-patch-webui apply
pve-autoupdate-patch-webui remove
```

### Updating and uninstalling from the UI

*Check for updates* only **reads** the published version — it never installs
anything by itself. That split is deliberate: automatic self-update would mean a
compromised or simply mistaken upstream could roll itself onto your node without
anyone deciding to.

If an update is available, the **changelog for that version** is shown next to
the button, so you can see what changes before committing to it.
[CHANGELOG.md](CHANGELOG.md) carries the current release only; earlier ones are
in the git history and on the
[releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

While installing, the button is disabled and reports which stage it's at. It
stays disabled until the **new version number is confirmed running** — not
merely until the installer exits — because the panel restarts part way through
and briefly still reports the old version.

Uninstalling takes **two independent steps**: a plain-language confirmation
listing exactly what will be removed, then typing `UNINSTALL`. Both self-update
and uninstall run detached under systemd, because each one restarts or deletes
the very service handling the request.

### Confirmations

Update actions ask before starting by default. If that's only friction for you,
turn it off in **Maintenance → Confirmations**:

```bash
CONFIRM_UPDATES="false"
```

That covers **Update Everything**, **Update Now** and **Install update**.
Deleting logs and uninstalling always confirm regardless — those cannot be
undone from the panel. The backend still requires its confirmation token either
way; the setting only decides whether a human is asked for it.

### Security

**Treat access to this port as equivalent to root shell access, and firewall it
accordingly.**

- Every request must carry a valid `PVEAuthCookie`, verified against the local
  Proxmox API on each call — there is no separate password.
- Only `root@pam` is permitted (`ALLOWED_USERS` in the service).
- Mutating requests additionally require a CSRF token bound to the session.
- Full updates require an explicit typed confirmation.
- Config writes are whitelisted per key and validated; unknown keys are rejected.
- Log reads are confined to the log directory; path traversal is rejected.
- Guest IDs are validated as numeric and checked against the real guest list
  before being passed to the update script.
- The status dot needs a credentialed cross-origin read, so the panel returns
  CORS headers **only** when the Origin's hostname matches this node's — never a
  wildcard, which credentialed CORS forbids anyway, and never a reflected
  arbitrary origin, which would let any site read your run status using your
  cookie.

The service runs as root and is deliberately **not** systemd-sandboxed: those
protections are inherited by child processes, and `ProtectSystem` would break the
`apt-get dist-upgrade` this service exists to launch.

### Certificates

The panel runs on its own port, and browsers scope certificate exceptions **per
port**. Trusting `:8006` does not trust `:8007`. What that means depends on which
certificate your node uses — the installer detects this and tells you which case
you're in.

**If your node has a CA-signed certificate (ACME/Let's Encrypt, or your own):**
nothing to do. The service reuses `pveproxy`'s certificate, so the panel is
trusted immediately. Renewals are picked up automatically — the service watches
the certificate file and reloads it in place, so an ACME renewal doesn't leave it
serving an expired cert until someone restarts it.

**If your node still uses the Proxmox self-signed certificate,** pick one:

| | Approach | Effort | Scope |
|---|---|---|---|
| **a** | Click through the warning once at `https://host:8007/` | 10 seconds | That one browser, that one machine |
| **b** | Set up ACME: **Datacenter → ACME**, then **Node → Certificates → Order Certificate** | One-time, ~5 min | Every browser, forever — *also removes the warning on the Proxmox UI itself* |
| **c** | Install `/etc/pve/pve-root-ca.pem` into your computer's trust store | One-time | Every browser on that machine — also fixes `:8006` |

**(b) is the real fix.** It's Proxmox's own built-in feature, it eliminates the
problem for good rather than papering over it, and it removes the certificate
warning you're already clicking through on the main UI.

There is no way to approve a certificate on the user's behalf from the server —
that's a deliberate browser security boundary, and anything that could bypass it
would be a vulnerability. What the UI does instead is **detect the situation
precisely** rather than failing silently: before embedding the panel it probes
the unauthenticated `/healthz` endpoint, and if the certificate isn't trusted it
explains the situation and offers a one-click way to approve it, instead of
showing a blank window.

After installing, **hard-refresh the Proxmox UI (Ctrl+Shift+R)** — the old
`pvemanagerlib.js` is cached by the browser.

---

## Troubleshooting

### It ran and said everything was fine, but nothing was updated

Run the self-check first. It covers every cause below and tells you which one you have:

```bash
update-everything.sh --doctor
```

It changes nothing and exits non-zero if anything is actually broken. The usual culprits:

| Symptom | Cause | Fix |
|---|---|---|
| Reports 0 containers and 0 VMs | Installed somewhere that isn't a Proxmox host — plain Debian, a Proxmox Backup Server, or inside a container on the host | Install on the PVE host itself. The installer now refuses outright. |
| Reports 0 containers and 0 VMs on a real PVE host | `pve-cluster` is down, so `pct list` and `qm list` fail | `systemctl status pve-cluster` |
| Host badged "Repo Error" | The Proxmox enterprise repository is enabled without a subscription, so `apt-get update` fails on every run | Switch to `pve-no-subscription`, or disable the enterprise repository |
| A container reports "already up to date" but is months behind | It cannot reach its mirrors — no gateway, wrong DNS, or an end-of-life release | `pct exec <id> -- apt-get update` |
| Nothing ever runs at all | No cron daemon | `systemctl enable --now cron` |
| No notifications, ever | No channel configured, or `NOTIFY_ON_FAILURE_ONLY` is set and the runs are clean | Check the Notifications tab, or `--doctor` |
| `cron.log` shows a syntax error on line 1 | The install downloaded an error page instead of the script — a captive portal, a filtering proxy, or a DNS blocklist hit on `raw.githubusercontent.com` | Reinstall. The installer now verifies what it downloaded before installing it. |

### The install finished but the Auto-Update button is not there

Run the self-check first — it answers this exact question:

```bash
update-everything.sh --doctor
```

It reports, separately, whether the panel is answering on its port and whether
the button is present in `pvemanagerlib.js`. Those are two different failures
with two different fixes.

**If the button is present in the file:** it is your browser. Proxmox serves
`pvemanagerlib.js` with aggressive caching and an ordinary reload will not
replace it. Hard-refresh with `Ctrl+Shift+R` (`Cmd+Shift+R` on a Mac), or open
the Proxmox UI in a private window to confirm. This is by far the most common
cause, and a normal browser restart does not always clear it.

**If the button is not in the file:**

```bash
/usr/local/bin/pve-autoupdate-patch-webui apply
```

**If the button is in the file and you have hard-refreshed and it is still not
there:** the injected code could not find the toolbar to attach to. Open the
browser's developer console (F12) and look for a `proxmox-autoupdate:` warning —
it says so explicitly. In that case a floating **Update Everything** button
appears in the bottom-right corner instead, and the panel is always reachable
directly at `https://<node>:8007/`. Please
[open an issue](https://github.com/Enhanced-Group/proxmox-autoupdate/issues)
with your Proxmox version.

### The panel's port is not listening after installing

```bash
update-everything.sh --doctor          # says whether the port answers
systemctl status pve-autoupdate-ui
journalctl -u pve-autoupdate-ui -n 50  # the actual error
```

The three things that account for almost all of it:

- **The port is taken.** 8007 is Proxmox Backup Server's. If PBS is on the same
  node, pick another port — re-run the installer, or edit `WEB_UI_PORT` in
  `/etc/proxmox-autoupdate.conf` and `systemctl restart pve-autoupdate-ui`.
- **No certificate.** The panel reuses the node's own Proxmox certificate from
  `/etc/pve/local/`. If `/etc/pve` is not mounted — pmxcfs not started, or the
  node is not part of a working cluster filesystem — it exits saying so.
- **A firewall.** The service can be listening while the Proxmox firewall drops
  the connection. `curl -k https://127.0.0.1:8007/` from the node itself
  distinguishes the two: if that answers and your browser does not, it is the
  firewall.

Note that `systemctl is-active` is not a reliable check here on its own — the
unit is `Type=simple`, so systemd reports "active" as soon as the process forks,
before it has bound anything. Ask the port, as `--doctor` does.

### The Proxmox web UI is blank after an update

An interrupted write to `pvemanagerlib.js` by an older version of this tool could leave that file truncated, and because it is a single script the whole interface stops loading. Restore it:

```bash
pve-autoupdate-patch-webui restore
```

If that fails, reinstall the file from Proxmox itself:

```bash
apt-get install --reinstall pve-manager
```

Current versions stage every edit to a temporary file and swap it in with an atomic rename, so this can no longer happen.

### The web panel isn't reachable

```bash
systemctl status pve-autoupdate-ui
journalctl -u pve-autoupdate-ui -n 50
```

The most common cause is a port collision: **Proxmox Backup Server also uses 8007**. If you run both on one machine, re-run the installer and choose a different port.

The panel serves TLS using the node's own certificate, so if you trust `:8006` in your browser you will trust this port too. On the default self-signed certificate you get the usual warning once per port.

### A Windows VM reports "Timeout" every run

Windows cumulative updates routinely take longer than the default hour. Raise it:

```bash
WINDOWS_UPDATE_TIMEOUT="7200"
```

A guest left mid-update is reported as such, and the host reboot is suppressed until it settles. Windows guests are never force-stopped by this tool — a guest that is still installing or rolling back updates is left running instead.

### A guest fails every run and appears under "Failing repeatedly"

Check what it actually reported, then reproduce it by hand:

```bash
update-everything.sh --only <id> --dry-run
```

Templates are skipped automatically. Guests using `zypper` or `pacman` are reported as unsupported rather than silently passed over.

### Checking a run afterwards

Exit codes are meaningful, so a wrapper can act on them:

| Code | Meaning |
|---|---|
| `0` | Everything succeeded |
| `1` | At least one error occurred |
| `2` | No hard error, but guests were left mid-update |

```bash
update-everything.sh || echo "run failed with $?"
journalctl -u pve-autoupdate-run     # when started with --detach
```

---

## Logs

All output is logged to:

```
/var/log/proxmox-autoupdate/update_YYYYMMDD_HHMMSS.log
```

Logs older than 90 days are automatically pruned on each run.

---

## Uninstall

From the web panel: **Maintenance → Uninstall** (two confirmation steps).

From the shell:

```bash
pve-autoupdate-uninstall            # installed alongside the updater
```

Or fetch it:

```bash
curl -sSL https://raw.githubusercontent.com/Enhanced-Group/proxmox-autoupdate/main/uninstall.sh | bash
```

Or, from a checkout:

```bash
./uninstall.sh              # keeps config and logs
./uninstall.sh --purge      # removes them too
./uninstall.sh --yes        # no confirmation prompt
```

It removes the update script, the cron entry, the web control panel and its
service, the apt hook, and the Proxmox UI patch — restoring `pvemanagerlib.js`
byte for byte.

By default it **keeps** `/etc/proxmox-autoupdate.conf` (it holds your Mailgun
API key) and `/var/log/proxmox-autoupdate/` (your update history). Pass
`--purge` to delete both. Re-running `install.sh` afterwards reuses the kept
config.

Two safety behaviours worth knowing:

- It **refuses to run while an update is in progress**, rather than deleting the
  script out from under a running job.
- If the patcher binary is missing or broken, it un-patches `pvemanagerlib.js`
  inline instead, and refuses to write the result if that would damage the file.

Guest snapshots named `autoupdate_*` are deliberately left alone. Remove them
yourself if you want them gone:

```bash
qm delsnapshot <vmid> autoupdate_20260731_230014
pct delsnapshot <ctid> autoupdate_20260731_230014
```

---

## License

MIT
