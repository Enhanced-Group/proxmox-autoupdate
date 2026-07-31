# Changelog

Read by the web panel's Maintenance tab, so the heading format matters:
`## <version> — <YYYY-MM-DD>`, then `### Added` / `### Fixed` / `### Changed`
sections of bullet points. Newest version first.

## 3.4.1 — 2026-07-31

### Fixed
- The Update Everything button overflowed into the Documentation button; it is now larger, sized correctly, and no longer clips.
- Discord DM failures reported a bare "400" with no cause. The actual Discord message, error code and offending field are now shown.
- An empty embed footer or description produced a 400 that looked like a configuration problem.
- A bot token pasted with its "Bot " prefix is now accepted.

### Changed
- The status indicator is the button's icon — a coloured dot — instead of a badge on the right.
- The button says when it is updating *itself*, and prompts you to reload your Proxmox tabs once done.

## 3.4.0 — 2026-07-31

### Added
- Changelog in the Maintenance tab — see what a new version changes before installing it.
- Optional confirmations for update actions. Deletions and uninstall always confirm.
- Discord notifications attach the full run log as a `.log` file, split across messages above 8 MB.

### Changed
- Check for updates and Install update now sit together; the install button stays disabled until the new version is confirmed running.

## 3.3.0 — 2026-07-31

### Changed
- "Update Everything" moved back to the top toolbar beside Documentation, in Proxmox orange.
- "Update Now" now sits between Start and Shutdown on every container and Linux VM.

### Fixed
- A button placed by an earlier version was never repositioned, because the sweep returned early when one already existed anywhere in the toolbar.

## 3.2.1 — 2026-07-31

### Fixed
- Self-update did nothing: `install.sh --unattended` aborted at its first prompt, because `read` returns non-zero at EOF and the script runs under `set -e`.
- Install update now re-enabled itself mid-install, allowing a second competing installer.
- Mailgun returned a bare 400: the test path never derived `MAILGUN_API_URL`, so an empty domain produced `.../v3//messages`.
- Enabling a notification channel without filling in its fields failed at the provider with no indication of what was missing.

## 3.2.0 — 2026-07-31

### Changed
- Browser `confirm()`/`prompt()` replaced with dialogs styled to match Proxmox.
- The panel animates while a run is in progress, so a long silent stretch no longer looks like a hang.

### Fixed
- Duplicate toolbar buttons: both the outer Config panel and the content panel inside it carry `pveSelNode`, so both were being decorated.

## 3.1.0 — 2026-07-31

### Added
- Notifications are optional and pluggable: Discord, Slack/Teams, generic JSON webhook, and Mailgun email, in any combination.
- Notify-on-failure-only, and a test-notification button that exercises the real notifier.
- Per-guest Auto-Update, `--only <ids>` and `--no-email` on the CLI.
- Log retention controls, run history with repeat-offender tracking, and an in-UI update check and uninstall.

### Fixed
- Closing the Proxmox shell tab killed a running update mid-`dpkg` and hung the terminal. Runs now ignore `SIGHUP`, and `--detach` hands them to systemd.

## 3.0.0 — 2026-07-31

### Fixed
- Linux guests were reported as failed when the update had actually succeeded. Three causes: `pvesh` output was parsed as JSON while defaulting to text, `apt` exiting non-zero for benign reasons was treated as failure, and `exitcode`/`err-data` were never read.
- `apt list --upgradable` was parsed for `[from: ` when it emits `[upgradable from: `, so every "old version" in a report was blank.

### Added
- Optional web control panel with an Auto-Update button in the Proxmox UI.
- `--dry-run`, optional pre-update snapshots, and an uninstaller.

## 2.3.0

### Added
- Windows VM support, stopped-guest updates, custom cron scheduling, HTML email reports.
