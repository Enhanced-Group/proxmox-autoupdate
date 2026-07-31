# Proxmox VE Automated Infrastructure Updater

A fully automated maintenance solution for Proxmox VE hosts with fancy terminal output, Windows VM support, and stopped guest updates.

This tool performs weekly updates across your entire Proxmox stack — including the host node, all LXC containers (running **and** stopped), Linux VMs, and Windows VMs — then delivers a detailed HTML report via Mailgun and conditionally reboots when a kernel update is detected.

---

## Features

- **Complete Infrastructure Coverage:** Updates the Proxmox VE host, LXC containers, Linux VMs, and Windows VMs.
- **Stopped Guest Updates:** Automatically starts stopped containers and VMs, applies updates, and restores them to their original state.
- **Windows VM Support:** Detects Windows VMs via QEMU Guest Agent and runs Windows Update using native PowerShell COM objects (no extra modules needed).
- **Multi-Distro Container Support:** Detects and updates `apt` (Debian/Ubuntu), `dnf`/`yum` (RHEL/Fedora/CentOS), and `apk` (Alpine) based containers.
- **Honest Result Reporting:** Guests report status through explicit markers rather than exit codes, so a benign non-zero `apt` exit is no longer reported as a failure — and a real failure is never reported as success. Packages that were genuinely upgraded are distinguished from those held back.
- **Dry Run Mode:** `update-everything.sh --dry-run` reports exactly what would be upgraded, installs nothing, and still emails the report.
- **Pre-Update Snapshots:** Optionally snapshot each guest before updating, with automatic pruning of old auto-snapshots.
- **Web Control Panel:** Optional **Auto-Update** button in the Proxmox toolbar (left of *Documentation*) — run updates, manage exclusions, edit the schedule and config, and read past reports without touching a shell. Authorised by your existing Proxmox login.
- **Per-Guest Updates:** Each VM and container gets its own **Auto-Update** tab below *Permissions* — patch a single guest without running the whole sweep, or exclude it from the schedule with one click. Also available as `--only <id>` on the CLI.
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
- **jq** — **required**. Every guest-agent reply is parsed as JSON; the installer installs it automatically if missing.

> **⚠ Important:** VMs without the QEMU Guest Agent will be reported as "Agent Offline" and skipped. For Windows VMs, ensure the VirtIO guest tools are installed.

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
| **Dry run** *(default)* | Checks the host and every guest, emails the full report, installs nothing, never reboots |
| **Full run** | Updates everything now, then emails the report (asks for typed confirmation first) |
| **Skip** | Waits for the scheduled run |

Both run modes send the report email, so either one verifies your Mailgun setup end to end.

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
WINDOWS_UPDATE_TIMEOUT="1200"    # seconds (default: 20 min)
START_STOPPED_WINDOWS="false"    # start stopped Windows VMs?

# Linux guest settings
LINUX_UPDATE_TIMEOUT="1800"      # seconds a Linux guest gets to finish (default: 30 min)
APT_LOCK_TIMEOUT="600"           # seconds apt waits for the dpkg lock inside a guest
START_STOPPED_LXC="true"
START_STOPPED_LINUX_VMS="true"

# Snapshots
SNAPSHOT_BEFORE_UPDATE="false"   # snapshot each guest before updating it
SNAPSHOT_KEEP="3"                # auto-snapshots to keep per guest

# Dry run — leave false for scheduled runs, use --dry-run for one-offs
DRY_RUN="false"

# Timing settings
UPDATE_SCHEDULE_CRON="0 23 * * 5" # Fridays at 23:00 (cron 5-field format)
REBOOT_TIME="00:00"              # HH:MM format for post-update reboot (if kernel updated)
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

## Schedule & Reboot Timing

Both the update trigger time and the reboot time are fully customizable during installation or via `/etc/proxmox-autoupdate.conf`:

- **Cron Schedule (`UPDATE_SCHEDULE_CRON`):** Choose from preset Friday times (23:00, 22:00, 20:00, 10:00) or specify any custom 5-field cron expression.
- **Reboot Time (`REBOOT_TIME`):** Specify when the host should reboot if a kernel update was installed (e.g. `00:00`, `01:00`, `02:00`).

To reconfigure at any time, re-run `install.sh` or edit `/etc/proxmox-autoupdate.conf` directly and update crontab (`crontab -e`).

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
| Discord | `DISCORD_WEBHOOK_URL` | Colour-coded embed — green/red/grey for ok/error/dry-run |
| Slack / Teams | `SLACK_WEBHOOK_URL` | Teams works via an incoming-webhook connector |
| Generic | `GENERIC_WEBHOOK_URL` | JSON POST — ntfy, Gotify, Home Assistant, n8n, anything |

```bash
NOTIFY_METHODS="discord,webhook"     # comma-separated; empty = silent
NOTIFY_ON_FAILURE_ONLY="true"        # stay quiet on clean runs
```

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

Buttons live in the **content toolbar**, next to the controls they belong with:

```
Node selected:      [ ⟳ Update Everything ● ]  Reboot   Shutdown   Shell   Bulk Actions   Help
LXC / Linux VM:     [ ⟳ Update Now ]           Start    Shutdown   Console   More   Help
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
| **Maintenance** | Version and update check, recent run history, uninstall |

### Per-guest updates

A per-guest run:

- touches **only** that guest — the Proxmox host is not updated
- **never** schedules a reboot
- sends **no** report email (you're watching the output live)

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
removal is an exact delete between two markers. The per-guest tab is added by
overriding `PVE.qemu.Config` / `PVE.lxc.Config` after their own `initComponent`
has run, so it doesn't depend on how those panels are built internally; if a
future Proxmox release reshapes them, the override is wrapped in `try/catch` and
costs you the tab rather than the guest view.

A `pve-manager` upgrade replaces that file and removes the button. An apt hook at
`/etc/apt/apt.conf.d/99-proxmox-autoupdate-webui` re-applies it automatically
afterwards. To check or fix it by hand:

```bash
pve-autoupdate-patch-webui status
pve-autoupdate-patch-webui apply
pve-autoupdate-patch-webui remove
```

### Update checking and uninstalling from the UI

The **Maintenance** tab has a *Check for updates* button. It only **reads** the
published version and tells you — it never installs anything by itself. Applying
is a separate action behind a typed `UPDATE` confirmation. That split is
deliberate: automatic self-update would mean a compromised or simply mistaken
upstream could roll itself onto your node without anyone deciding to.

Uninstalling from the UI takes **two independent steps**: a plain-language
confirmation listing exactly what will be removed, then typing `UNINSTALL`.
Both self-update and uninstall run detached under systemd, because each one
restarts or deletes the very service handling the request.

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
