# Changelog

Only the current release is kept here — this is what the web panel shows when
it offers you an update, so it should describe the version you are about to
install and nothing else. Earlier releases are in the git history and on the
[releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

The heading format is parsed by the panel: `## <version> — <YYYY-MM-DD>`, then
`### Added` / `### Fixed` / `### Changed` sections of bullet points.

## 4.0.0 — 2026-08-11

A correctness and safety release. Several long-standing bugs made a run report
success while doing nothing, and two could damage a working system. If you have
Windows VMs, or the web panel installed, this is worth taking.

### Fixed — data loss and availability

- **A Windows VM could be power-cut in the middle of installing updates.** After
  a successful install the guest was shut down and then forcibly stopped about
  four minutes later — inside the window where Windows is servicing updates on
  shutdown. Guests that this tool started are now left running until they settle,
  and a Windows guest is never forcibly stopped. Reaching this did not require
  `START_STOPPED_WINDOWS=true`: the Windows detection missed the `wxp`, `w2k`,
  `w2k3`, `w2k8` and `wvista` OS types, so those were treated as Linux and booted
  against an explicit setting not to.
- **The Proxmox web UI could be left blank by an interrupted patch.**
  `pvemanagerlib.js` was rewritten in place, so any interruption — power loss,
  out of memory, a full `/usr` — truncated a file the entire interface depends
  on. Edits are now staged beside the target and swapped in with an atomic
  rename. The apt hook also re-applied the patch after *every* dpkg transaction,
  rewriting 5 MB twice each time; it is now a single grep unless the button is
  genuinely missing. A new `pve-autoupdate-patch-webui restore` puts back the
  reference copy, which previously was written but never read — and was
  overwritten by the damaged file on the next run.

### Fixed — runs that reported success and did nothing

- **A container that could not reach its mirrors reported "already up to date"
  with zero packages.** The retry loop captured the exit status of the wrong
  thing, so the failure branch was unreachable.
- **A host whose `apt-get update` failed was badged "No Updates" and reported as
  fully up to date.** It is now an error, and the enterprise-repository-without-
  a-subscription case is detected and named explicitly.
- **A failing `pct list` or `qm list` produced an empty sweep reported as "all
  clear".** Both are now checked, so a node with `pve-cluster` down fails loudly.
- **The script always exited 0**, so `systemctl status` showed success on a
  failed run and cron wrappers could never fire. Now `0` clean, `1` errors,
  `2` guests left mid-update.
- **Fatal errors sent no notification at all** — a missing config, a stale lock
  or a missing dependency exited quietly into a log nobody reads.
- **There was no root check**, and its absence surfaced as the misleading
  "Another instance is already running".
- **Nothing checked this was a Proxmox host.** Installing on plain Debian, a
  Proxmox Backup Server, or inside a container succeeded and then swept nothing,
  forever.

### Fixed — wrong results

- **Templates were never skipped.** They appear as stopped guests, so every run
  tried to start them, failed, and marked them as permanently failing — turning
  every report red on any host that keeps one.
- **Alpine guests could never be updated.** The in-guest script was piped into
  `/bin/bash`, which Alpine does not ship, so the `apk` support was unreachable.
  It now runs under `/bin/sh`.
- **A fully-patched Windows VM was reported as an error on every run**, because
  PowerShell's CRLF line endings broke an exact string comparison.
- **A failed Windows Update search could report a successful update that
  installed nothing**, because `$ErrorActionPreference` was suppressing the very
  errors the surrounding `try`/`catch` existed to catch.
- **The host could reboot after every single run, forever.** The "latest kernel"
  was chosen by file timestamp rather than version, so a pinned or reinstalled
  older kernel never matched the running one. Kernels are now compared by
  version, and a reboot requires this run to have actually installed one.
- **A Windows Update timeout set no error flag**, so the run was recorded as
  clean and the guest's failure streak was reset.
- **`--dry-run` started and stopped guests.** It now changes nothing at all.
- **Held-back host packages were counted as both updated and held.**
- **`REBOOT_TIME` was interpreted in Europe/London regardless of where the host
  was**, so a 03:00 setting could reboot the machine in the early evening. It now
  follows the host's timezone; set `PAU_TZ` to pin one.

### Fixed — security

- **Config values were written into a file that bash sources as root, inside
  double quotes.** A webhook URL containing `$` aborted the whole run; a backtick
  executed as root. Values are now single-quoted and the validators reject shell
  metacharacters.
- **`GET /api/config` returned the Mailgun key, Discord bot token and every
  webhook URL in cleartext**, relying on the browser to draw asterisks. They are
  now redacted server-side.
- **The panel could be framed by any HTTPS site on the internet** and its actions
  clickjacked. `frame-ancestors` is now scoped to this host.
- **The installer downloaded the update script without `--fail`**, so a captive
  portal, filtering proxy or DNS blocklist could install an HTML error page as
  the updater and report success. Downloads are now verified before installation.
- **The installer trusted its working directory**, so running it from `/tmp` could
  install an attacker-planted file as root.
- **The self-update tracked `main`**, so any push to the repository went straight
  into a root cron job on every installation. It now tracks published releases.
- The concurrency guard silently did nothing when `psmisc` was absent, which it
  is by default. It now asks the kernel directly.
- The config file is created with mode 600 before credentials are written to it.

### Added

- **`update-everything.sh --doctor`** — a read-only self-check covering
  everything a run depends on: Proxmox detected, cluster filesystem answering,
  dependencies, repositories, cron, disk space, guest agents, the panel's port,
  and whether the installed script is even valid. Exits non-zero with a numbered
  list of what to fix. Run this first if a scheduled run appears to do nothing.
- **Customisable colours.** The panel's accent, success, warning and error
  colours can be changed from the Configuration tab, with four presets, a live
  preview and a reset. Text contrast on coloured buttons is calculated rather
  than assumed, so a pale accent stays readable.
- **Continuous integration.** shellcheck, `bash -n`, `py_compile`, `pyflakes`, a
  CLI smoke test, a full apply/remove/restore round-trip of the web-UI patcher,
  the in-guest payload parsed under both dash and BusyBox ash, and a set of
  cross-file invariants — including the one that would have caught the 3.5.0
  notifier regression.
- **Log rotation** for `cron.log`, which the retention pruner could never match.
- Release tags, so an installation can track reviewed releases rather than
  whatever was last pushed.

### Changed

- `WINDOWS_UPDATE_TIMEOUT` now defaults to 3600s, matching the documented
  15–60 minute expectation for cumulative updates.
- New settings: `WINDOWS_SHUTDOWN_TIMEOUT`, `LINUX_SHUTDOWN_TIMEOUT`,
  `AGENT_ERROR_GRACE`, `PAU_TZ`, and `LOG_DIR` is now honoured by the web panel
  as well as the updater.
- Guest-agent timeouts are measured against the wall clock rather than counted
  in polls, so the configured value means what it says.
- The systemd unit's port setting moved to a drop-in, so re-installs no longer
  discard operator customisation such as `PAU_UI_ADDR`.
- `uninstall.sh` now removes the uninstaller, the share directory, the systemd
  drop-in and the logrotate config, and keeps the patcher if un-patching failed.
- The README's requirements, feature list and web-panel description have been
  corrected to match the code, and a troubleshooting section added.
