# Changelog

Only the current release is kept here — this is what the web panel shows when
it offers you an update, so it should describe the version you are about to
install and nothing else. Earlier releases are in the git history and on the
[releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

The heading format is parsed by the panel: `## <version> — <YYYY-MM-DD>`, then
`### Added` / `### Fixed` / `### Changed` sections of bullet points.

## 4.1.1 — 2026-08-11

### Fixed

- **A run in progress produced no output at all.** The progress spinner writes
  to `/dev/tty`, so it was invisible to anything reading the log — which is
  every run started from the web panel and every run from cron. A guest upgrade
  may legitimately take up to `LINUX_UPDATE_TIMEOUT` (30 minutes by default),
  and for all of that time the log said nothing, so a run working normally
  through a slow mirror looked identical to one that had hung.

  Each step now announces itself in the log, a heartbeat reports elapsed time
  every `HEARTBEAT_SECS` (30 by default, `0` disables), and anything that took
  longer than that reports how long it took when it finishes. This makes it
  obvious both that a run is alive and, afterwards, where the time went.

### Added

- **An elapsed timer for a run in progress**, in the live output header. It is
  driven from the run's own start time, so it survives a page reload rather
  than counting from when the tab was opened, and it ticks every second rather
  than only on the status poll. A run started outside the panel — by cron — is
  labelled as such instead of showing a misleading clock.

## 4.1.0 — 2026-08-11

An interface release, on top of the correctness work in 4.0.0. The panel now
answers "did the scheduled run work?" on the page you land on, instead of
making you go and find out.

### Added

- **A status summary on the Overview tab.** Last run and how long ago, outcome,
  what it actually updated, when the next run is due, and anything needing
  attention — including guests that have been failing repeatedly. All of this
  existed already; it was spread across two other tabs.
- **Self-check in the panel.** The `--doctor` checks now have a button on the
  Maintenance tab, rendered as a pass/warn/fail checklist. It is read-only, so
  it needs no confirmation. This is the first thing to reach for if a scheduled
  run appears to do nothing.
- **Log downloads.** Each log has a download link, and there is a "Download all
  as .tar.gz" for attaching to a bug report. The viewer strips ANSI and pages
  through the file, which is right for reading and wrong for keeping a copy.
- **The colours apply to the Proxmox UI buttons too.** Both the
  *Update Everything* toolbar button and the per-guest *Update Now* buttons
  follow the palette set in the panel, and pick it up without re-patching —
  the toolbar already polls the panel, so it costs no extra request.
- **An option to hide the "No valid subscription" dialog**, on the Maintenance
  tab, off by default. It re-hides automatically after a
  `proxmox-widget-toolkit` upgrade replaces the file, the same way the toolbar
  button survives a `pve-manager` upgrade. This changes one dialog and nothing
  else: it does not create or alter a subscription, does not change repository
  access, and does not touch `/etc/subscription`. If you run Proxmox
  commercially, buy a subscription.
- **Three settings that had no interface.** `WINDOWS_SHUTDOWN_TIMEOUT`,
  `LINUX_SHUTDOWN_TIMEOUT` and `AGENT_ERROR_GRACE` were added in 4.0.0 and were
  only reachable by editing the config file. `PAU_TZ` is now editable too.

### Changed

- **Seven tabs are now four.** Exclusions, Schedule, Notifications and
  Configuration are all "set this up once", so they moved into a single
  **Settings** tab with its own sub-navigation. Overview and Logs & Reports are
  what you actually use. Unsaved changes on a sub-tab still show on Settings.
- **Settings are no longer duplicated between tabs.** The Configuration form
  repeated the five Mailgun fields that Notifications owns, `EXCLUDE_IDS` which
  Exclusions owns as checkboxes, and `REBOOT_TIME` which Schedule owns. That was
  not only confusing: saving Configuration posts every field it shows, so
  ticking exclusions and then saving Configuration wrote back the stale value
  and **silently reverted them**. Each setting now lives in exactly one place.
- Configuration fields explain what they do. Several are timeouts whose
  consequences are not guessable from the name.
- Dates read as "3 days ago", with the exact timestamp on hover.
- The live output pane falls back to the most recent run instead of saying "No
  run started from this page yet" — which is what a scheduled run always left
  it saying, despite that being the run people most want to see.
- The tab strips are real tablists: roles, selection state and arrow-key
  navigation. They were styled buttons with none of that.
- Tables scroll inside their card rather than squeezing the name column to a
  few dozen pixels on a phone.

### Fixed

- **Exit code 2 was reported as a failure.** 4.0.0 introduced it to mean "the
  run finished, but guests were left mid-update, so the host reboot was held
  back" — usually a Windows guest still installing. The panel showed that as
  "last run failed (2)", turning a successful and deliberately cautious run
  into an apparent error.
- **A lost connection looked identical to an idle panel.** The page silently
  stopped updating. It now says it is reconnecting — which matters most during
  a host upgrade, when the Proxmox API restarts and someone is watching.
- Panel copy that stopped being true in 4.0.0: the Run tab promised "Both email
  the report to your configured recipient" when notifications are optional and
  email is one of four channels; the Exclusions tab pointed at an "Auto-Update
  tab" that does not exist; and the dry-run description still described the old
  behaviour of starting and stopping guests.
- The Maintenance tab now names the release it would install, not just the
  version number — updates track tags, so the tag is what decides what you get.
- The update check no longer requires a published GitHub Release. A plain tag is
  enough, and the highest version is chosen rather than whichever tag the API
  happens to return first — which could have resolved to an older tag and
  installed backwards.
