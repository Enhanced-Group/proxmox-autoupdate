# Changelog

The newest release is written out in full, with everything before it summarised
under [Previous releases](#previous-releases). Nothing is removed — the web
panel only ever renders the first entry, so keeping the history here costs
nothing and is worth having.

Only released versions appear. Work in progress belongs in the git history and
in pull requests, not here: a changelog people rely on to decide whether to
update should describe what they would actually get.

The heading format is parsed by the panel: `## <version> — <YYYY-MM-DD>`, then
`### Added` / `### Fixed` / `### Changed` sections of bullet points.

## 4.6.1 — 2026-08-12

### Fixed

- **CI compared config defaults as text, so two spellings of the same number
  failed.** `DISCORD_MAX_UPLOAD` is written as `$((8 * 1024 * 1024))` in the
  script, which is clearer than `8388608`, and stored as the number in the
  panel. The check compared the strings and reported a mismatch between two
  identical values. It now evaluates arithmetic before comparing, restricted to
  digits and operators so nothing in a config default can be executed.

## 4.6.0 — 2026-08-12

### Fixed

- **Discord rate limits were not handled at all.** Discord allows roughly five
  requests per two seconds per webhook and answers 429 with a `retry_after`
  saying exactly how long to wait. None of the three call sites read it: a 429
  was reported as a generic HTTP failure and the message was simply lost.
  Sending a multi-part log made that likely rather than theoretical, since
  every part is another request. All Discord traffic now goes through one
  helper that honours `retry_after`, retries up to four times, clamps the wait
  to 30s so a long limit cannot stall a run, and falls back to 2s when the
  value is missing or malformed.
- **Attachments were uploaded even when the message had failed.** A webhook
  returning 401 was followed by several megabytes of log going the same way,
  producing more failures and no report. Attachments now only follow a message
  that landed.
- The panel's notification form serialised checkboxes as `"on"`, which is not a
  value the script or the validators accept — it would have silently rejected
  the new attachment toggle. Checkboxes now read and write `true`/`false`.

### Added

- **The HTML report can be attached to Discord**, alongside the plain log
  (`DISCORD_ATTACH_REPORT`, on by default). It is the same report the email
  channel sends, with the per-guest package lists formatted — Discord offers it
  as a download rather than rendering it inline. Unlike the log it is never
  split when oversized, because half an HTML document renders as whatever the
  browser can salvage and silently drops the rest; it is skipped with a reason
  instead.
- `DISCORD_MAX_UPLOAD` is configurable. Discord's ceiling depends on the
  server's boost tier and the free-tier figure has changed more than once, so
  it is no longer a constant you have to edit the script to change. A 413 from
  Discord is now reported as "too large" with the setting to adjust, rather
  than a bare HTTP code.

## 4.5.6 — 2026-08-12

### Fixed

- **Two "reload now" prompts after a self-update.** The panel offered a reload,
  and so did the toolbar patch running in the Proxmox page — two dialogs for
  one event, on the normal path where the panel is opened from the toolbar
  button. The panel now stays quiet when it is embedded, since reloading the
  parent page reloads the frame with it; opened standalone in its own tab there
  is no toolbar, so it still offers the reload itself.

## 4.5.5 — 2026-08-12

### Fixed

- **"Check for updates" answered from a five-minute-old cache.** The resolved
  release reference is cached for 300 seconds to keep background status polls
  off the GitHub API, but the button shared that cache — so pressing it minutes
  after a new version was published still reported "up to date", and pressing
  it again changed nothing. An explicit check now bypasses the cache and
  refreshes it; background polls still use it.

## 4.5.4 — 2026-08-12

### Fixed

- **Update checks could sit on an old version indefinitely.** The panel and the
  installer asked GitHub for `/releases/latest`, which only knows about
  *published Release objects*, and fell back to git tags only when that
  returned nothing at all. So a maintainer who tags and pushes without also
  publishing a Release leaves every installation reporting "up to date" against
  a version that is not the newest — which is exactly what happened here
  between v4.4.0 and v4.5.3: six tags, no Releases, and every panel reporting
  4.4.0 as current.

  Both now take whichever is *newer* of the published Release and the highest
  git tag, comparing by version rather than by the order GitHub returns things.
  A missing Release, a deleted tag, or an odd ordering can no longer make an
  update check resolve backwards or stall.

## 4.5.3 — 2026-08-12

### Changed

- **Added a "Before You Install" section to the README.** On a stock Proxmox
  this installs and runs without preparation, but four things decide whether it
  does what you expect, and two of them catch almost everybody: the enterprise
  repository returning 401 without a subscription, so the host can never update
  while Debian's own repositories keep working; and VMs needing the QEMU guest
  agent installed *inside* the guest, without which they are skipped silently
  and permanently. The other two are what happens to stopped guests, and that
  snapshots are off by default and need snapshot-capable storage.

  It also states plainly what the tool will not do: containers inside guests,
  anything on another node, and the exact conditions under which it reboots.

## 4.5.2 — 2026-08-12

### Fixed

- **The CI check that `--doctor` is read-only failed on a read-only run.** It
  compared `find -newermt '-1 minute'` before and after, but that is relative
  to *now* — and `--doctor` takes about ninety seconds on a runner because it
  refreshes the package index, so the two samples covered different sliding
  windows and files aged out of the first one whether or not anything was
  written. It now compares actual paths, mtimes and sizes, and prints a diff of
  what changed when it does fail. Verified both ways: the old form reports a
  false failure after a three-second no-op, the new one does not, and it still
  catches a real modification.

## 4.5.1 — 2026-08-12

### Fixed

- **CI failed at random.** `ci/invariants.sh` runs under `set -o pipefail` and
  tested for things with `producer | grep -q`. `grep -q` exits on its first
  match, the producer takes SIGPIPE, and the pipeline reports failure — so a
  *successful* match was reported as a failed check. It is timing-dependent, so
  it passed for weeks and then began failing once the notifier block grew past
  a few hundred lines, claiming `notify_email()` had left that block when it
  had not. Four checks were affected, including two added the same day.
  Replaced with herestrings, which have no pipe to break: measured 20/20 false
  failures before, 0/20 after.

## 4.5.0 — 2026-08-12

### Added

- **openSUSE/SLES and Arch guests are updated.** `zypper` and `pacman` joined
  `apt`, `dnf`, `yum` and `apk`; those two previously fell through to
  "unsupported package manager" and were silently counted as skipped. zypper's
  exit codes 100 and 101 are treated as success, because they mean "updates
  applied" and "applied, reboot advised" rather than failure — reading them as
  errors would have marked every successful openSUSE update as failed.
- **Docker and Podman hosts are reported.** A guest running containers gets a
  note in the console and the report saying how many are running and that this
  tool does not update them. It deliberately does not pull or restart anything:
  that needs compose files and restart ordering, and it can take a stack down
  in ways `apt` never will. Without the note, "already up to date" was true of
  the guest's packages and silent about the images actually running the
  services — a green tick that implied more than it meant.
- `--doctor` and the unsupported-guest message now name every package manager
  that was looked for, instead of an out-of-date list.

### Fixed

- The `unsupported` result gave no reason. It now says what it searched for.
- `ci/invariants.sh` checks that every package manager the README advertises
  has a branch in the guest script, and that container runtimes are still
  reported. Alpine was advertised for a long time while its branch was
  unreachable; this stops that recurring.

## 4.4.2 — 2026-08-12

### Fixed

- **A dry run reported guests as "updated".** The dry-run branch incremented the
  same counter as a real install, so a run that changed nothing finished with
  "LXC: 8 updated" — the one number someone reads to find out what happened.
  Dry runs now count separately and the summary says "8 with updates pending",
  in the console, in notifications, and in the run history the panel shows.
  Found on the first real dry run against a live host.

## 4.4.1 — 2026-08-12

### Fixed

- **The self-check said nothing about containers, and nothing at all when no VM
  was running.** Its Guests section only emitted a line per *running VM*, so on
  a host whose VMs are all stopped it produced no output — and because the
  panel drops empty sections, the Guests heading vanished entirely. "Nothing to
  check" and "the check did not run" looked identical.

  It now reports running and stopped counts for both containers and VMs, always
  says something, and warns when stopped guests will be skipped because
  `START_STOPPED_LXC` or `START_STOPPED_LINUX_VMS` is false. Found by running
  `--doctor` on a real host with 15 containers and 5 stopped VMs, where it
  reported on none of them.

## 4.4.0 — 2026-08-12

### Fixed

- **Most of the installer's output was invisible.** Every explanatory line used
  the ANSI *faint* attribute (`[2m`), which xterm.js — what the Proxmox web
  shell is built on — renders at very low contrast on a dark background. In the
  terminal most people install from, roughly a third of the installer simply
  did not appear. It now uses bright black, a real colour that stays legible on
  both dark and light themes.

- **Colour is only emitted to a terminal.** Piping the installer to a file or
  running it from Ansible produced a wall of raw escape sequences. `NO_COLOR`
  is honoured.

### Added

- **Progress in the installer.** It downloads several files, may install
  packages, patches the Proxmox UI and restarts a service, and did all of it in
  silence — on a slow link it was indistinguishable from a hang. Steps are now
  numbered, long operations run behind a spinner, and a failed step prints the
  last few lines of what actually went wrong instead of only lacking a tick.
  Without a terminal the spinner degrades to a plain line.

## 4.3.1 — 2026-08-11

### Changed

- **Switching tabs with unsaved changes no longer discards them silently.**
  Nothing was posted and returning re-read the saved values, so an edit could
  vanish without a word. Navigation is now blocked while a section has unsaved
  changes, and you are taken to the save button with the warning banner
  flashing.

  Every banner also carries a **Discard them** link, because being unable to
  leave a form you have changed your mind about would be worse than losing the
  edit. Re-selecting the tab you are already on is not treated as navigation.

- The save button that briefly lived in the header is gone. Each section keeps
  its save next to the form it applies to, which is where you look for it.

## 4.3.0 — 2026-08-11

### Added

- **A sticky header.** The title, status, schedule and tabs stay put while the
  page scrolls, so navigation is reachable from anywhere on a long page.

## 4.2.2 — 2026-08-11

### Fixed

- **The Settings tab opened empty.** Clicking it showed the container and
  fetched the data but never unhid the sub-section inside it, so the content
  sat behind `hidden` until a sub-tab click revealed it — which is why clicking
  away and back appeared to fix it. Introduced in 4.1.0 with the tab
  consolidation.

## 4.2.1 — 2026-08-11

### Fixed

- **The Update Everything button did not match its toolbar.** It forced
  `scale: 'medium'` and `minWidth: 170` while every other button beside it —
  Documentation, Create VM, Create CT — is `small` and sized to its text, so it
  sat noticeably taller and wider than its neighbours, and its label was bolded
  when theirs are not. It now copies the toolbar's own button geometry, exactly
  as the per-guest button already did, and expresses the accent through colour
  alone.

- **The panel followed the operating system's light/dark preference, not
  Proxmox's.** Those are frequently not the same — a dark Proxmox on a light
  desktop opened this panel in light mode inside a dark window, which is most
  of why it looked like a foreign object. The toolbar patch now measures the
  theme Proxmox is actually rendering and passes it in the panel URL, and the
  panel applies it in `<head>` so it never paints in the wrong theme first.
  Opened directly rather than through the button, it still falls back to the
  system preference.

  The theme is measured from the rendered page rather than read from a cookie
  or a class name, so it keeps working when Proxmox renames or restructures its
  themes — which it has done before. Only `dark` and `light` are accepted from
  the URL.

- **Saving the Configuration tab failed with "invalid value".** The three
  timeouts added in 4.2.0 are not present in a config file written by an
  earlier version, so the panel served them as empty strings — and since a form
  posts every field it renders, and an empty integer failed validation, the
  whole form became unsaveable. Settings absent from the config file now show
  their real default instead of an empty box, and an empty value is accepted as
  "use the default", which is what the script already does with `${KEY:-...}`.

  The same trap applied to any setting added in future, so `ci/invariants.sh`
  now checks that every setting either accepts an empty value or has a default,
  and that those defaults match the script's.

- **The email transport could be shown wrong.** The script infers it when unset
  — a Mailgun key means Mailgun — so an existing Mailgun installation would
  have seen "SMTP server" selected while runs still went through Mailgun. The
  panel mirrors the inference.

- **Scrollbars used the browser default**, which on a dark panel reads as a
  pale hole punched through it. They now derive from the theme tokens, so they
  follow light and dark and pick up a custom accent on hover. Log output keeps
  its own darker scrollbar, because it stays a console view in both themes —
  the page scrollbar there would have been a light bar on black.

## 4.2.0 — 2026-08-11

### Added

- **Email over any SMTP server.** Email was tied to Mailgun, which is a poor
  default for a free tool — most people already have a relay, a mail server, or
  an app password. `EMAIL_TRANSPORT=smtp` with `SMTP_HOST`, `SMTP_PORT`,
  `SMTP_SECURITY` (STARTTLS, SSL/TLS or none for a local relay) and optional
  credentials. Mailgun still works and existing installations are unchanged:
  with the transport unset, having a Mailgun key still means Mailgun.
- **Microsoft Teams as its own channel.** It was previously folded into Slack
  and sent Slack's own message format, which Teams does not render — so the
  "Slack/Teams" label was simply wrong. Teams now receives a MessageCard with
  the run summary as fields, understood by both a Power Automate webhook
  trigger and a legacy Office 365 connector.
- **ntfy**, properly. The generic webhook was documented as working with it,
  but ntfy takes the topic in the URL path and the message as the request body
  with metadata in headers — posting the generic JSON object published the raw
  JSON as the message text. Failures are sent at high priority automatically.
- **Gotify** and **Telegram**. Gotify's token is sent in a header rather than
  the query string, so it stays out of the server's access log.
- **Links to the repository, all releases and the full changelog** on the
  Maintenance tab.

### Changed

- The changelog keeps its full history again, with everything before the
  current release summarised and linked. The panel renders only the newest
  entry regardless — it enforces that when parsing — so keeping the record
  costs nothing. Only released versions appear; work in progress belongs in the
  git history.
- Webhook URLs and extra headers are passed to curl through its config file
  rather than argv, so credentials embedded in a URL stay out of the process
  list. This already applied to some channels and now applies to all of them.
- ntfy and Gotify accept plain `http://`, because they are usually a machine on
  your own network with a token sent separately. The hosted-service webhooks
  still require `https://`, where the URL is the only credential.

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

---

## Previous releases

Summarised so the record is visible here, with full detail in the
[git history](https://github.com/Enhanced-Group/proxmox-autoupdate/commits/main)
and on the [releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

- **[v3.5.1](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.5.1)** — test-notification button fixed.
- **[v3.5.0](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.5.0)** — credentials passed to curl on stdin, never in the process list.
- **[v3.4.5](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.4.5)** — Discord 401 identifies which credential was pasted.
- **[v3.4.4](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.4.4)** — update check no longer served a stale version by the CDN.
- **[v3.4.3](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.4.3)** — self-update no longer triggers a guest dry run; correct status labelling.
- **[v3.4.2](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.4.2)** — Discord DM diagnostic, unsaved-change tracking.
- **[v3.4.1](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.4.1)** — button geometry, Discord DM diagnostics, self-update messaging.
- **[v3.4.0](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.4.0)** — changelog in the UI, Discord DMs and log attachments, optional update confirmations.
- **[v3.3.0](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.3.0)** — orange Update Everything beside Documentation; per-guest button between Start and Shutdown.
- **[v3.2.2](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.2.2)** — Auto-Update button sits with the Start/Reboot action group.
- **[v3.2.1](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.2.1)** — working self-update, Mailgun diagnostics, buttons in the content toolbar.
- **[v3.2](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.2)** — Proxmox-styled dialogs, single toolbar button per panel, animated run feedback.
- **[v3.1](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.1)** — optional webhook notifications (Discord/Slack/generic), toolbar buttons on node and guest panels, shell-persistent runs, log retention controls, run history, and in-UI update check and uninstall.
- **[v3.0](https://github.com/Enhanced-Group/proxmox-autoupdate/releases/tag/v3.0)** — guest-update reliability fixes, dry run, targeted --only runs, optional pre-update snapshots, and an optional web control panel with a per-guest Auto-Update tab.
