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

## 1.11.0 — 2026-08-12

### Added

- **`WEB_UI_PUBLIC_URL` — the panel's address, for people behind a proxy or
  tunnel.** The toolbar button built its link as
  `https://<the host in your address bar>:8007`. If you reach Proxmox through
  Cloudflare Tunnel, nginx, Traefik or Tailscale, that hostname forwards the
  Proxmox port and nothing else, so the button pointed at a port the browser
  can never open and timed out — with the status dot stuck neutral forever.

  Set the panel's real public address in the config (the installer asks for it
  after the port), re-run `pve-autoupdate-patch-webui apply`, and the button
  uses it. README documents the Cloudflare Tunnel case specifically.

  The value is interpolated into a JavaScript string inside
  `pvemanagerlib.js`, so it is validated as a plain `http(s)` origin at both
  ends — a quote or newline in it would be script injection into the Proxmox
  UI, not a formatting slip.

### Fixed

- **The "cannot reach the panel" dialog blamed the certificate every time.** It
  was titled *One-time certificate step* and stated the node's self-signed
  certificate needed approving. The probe behind it cannot know that: a
  `no-cors` fetch rejects identically for a rejected certificate, a refused
  connection, a timeout and a DNS failure. Someone behind a tunnel was told to
  accept a certificate, clicked through, and got `ERR_CONNECTION_TIMED_OUT` on
  a port unreachable from their browser. It now names both causes, says which
  is likely from the port you are on, and gives the exact config line.

- **The status dot could not tell "nothing has run yet" from "cannot reach the
  panel".** Both left it neutral with a generic tooltip, so a browser that
  could never reach the panel looked identical to a healthy idle install. An
  unreachable panel now shows a hollow amber dot after two consecutive failed
  polls, with a tooltip saying so; a fresh install with no runs says exactly
  that, and that the dot turns green after the first clean run.

## 1.10.1 — 2026-08-12

### Fixed

- **"I installed it and the button never appeared" — found, and it was not the
  patcher.** The web-panel question defaulted to **No** on a fresh install, in
  every release up to and including 1.10.0. Combined with prompts that printed
  nothing under `curl … | bash` (fixed in 1.8.1), the sequence was: you saw a
  menu, saw no question, pressed Enter to move past it, and silently declined
  the panel. Nothing was patched into `pvemanagerlib.js`, no service was
  installed, so no port ever listened — and the installer still finished with
  **Deployment successful ✓**. Both reported symptoms, one cause.

  Reproduced by running the shipped installer with every answer left blank:
  `ENABLE_WEB_UI="false"`, zero occurrences of the button block in
  `pvemanagerlib.js`, and a green success banner.

  A fresh install now defaults to **Yes**. A re-install still carries the
  previous answer forward, so anyone who deliberately declined stays declined.
  1.10.0's Typical install already set it; this fixes Custom too.

## 1.10.0 — 2026-08-12

### Added

- **Typical or Custom, asked first.** The installer opened with fifteen
  questions, which is a good way to lose someone at question four. It now asks
  one:

  ```
  1) Typical  — recommended defaults, nothing to answer
  2) Custom   — choose everything yourself
  ```

  Typical prints the full profile it is about to apply before applying it — it
  is not a black box — and then asks nothing else until the optional dry run at
  the end:

  | | |
  | --- | --- |
  | Schedule | Fridays 23:00, reboot at 02:00 only if a kernel was installed |
  | Guests | Stopped containers and Linux VMs started, updated, put back; Windows left alone |
  | Web panel | Installed on port 8007, toolbar button added |
  | Notifications | **Off** |
  | Snapshots | Off |
  | Logs | Kept for 90 days |
  | Exclusions | None |

  **Notifications stay off deliberately.** There is no safe guess at somebody's
  mail server, and a channel configured wrongly is worse than none: it reports
  nothing and looks configured. Add one afterwards from the panel.

- **Re-installing offers to keep what is there.** On a host that already has a
  config the first question becomes a three-way choice, defaulting to *Keep my
  current settings*. "Typical" on a machine somebody has already set up would
  mean silently discarding their settings, so it is never the default there.
  The panel's unattended self-update takes the keep path automatically.

### Fixed

- **Keep mode was relying on `source` to bind its variables.** Skipping the
  prompts left `NOTIFY_METHODS` and the rest defined only as a side effect of
  sourcing the old config — so a config missing any key (anything written by an
  older version) aborted with `unbound variable`, *after* the heredoc had
  already truncated the config file to zero bytes. Keep mode now sets every
  value explicitly, with the same fallbacks the prompts would have offered, and
  synthesises a schedule list from `UPDATE_SCHEDULE_CRON` when upgrading a
  pre-1.9.0 config. Caught by running the three modes back to back rather than
  one at a time.

- Every value the config file needs is now seeded before the prompts rather than
  inside them. Skipping the prompts previously left those variables unset, and
  under `set -u` that is not a missing default — it is an abort partway through
  writing the config, on the install path most people would take. CI checks that
  all 45 keys are set without asking, and that the three prompt sections stay
  behind the mode gate.

## 1.9.0 — 2026-08-12

### Added

- **Multiple schedules, each with its own reboot policy.** Updates are safe to
  apply weekly; the reboot a new kernel needs is the part that costs an outage.
  A schedule now says which of three things it is for:

  | Mode | Cron line | What it does |
  | --- | --- | --- |
  | Update · reboot if needed | *(no flag)* | The old behaviour. |
  | Update · never reboot | `--no-reboot` | Installs everything, including the kernel; leaves the host on the old one. |
  | Reboot window · no updates | `--reboot-window` | Installs nothing. Reboots only if a reboot is already owed. |

  Set it up in the installer or on the panel's **Schedule** tab, where each row
  has its own mode. Up to ten schedules.

- **A held reboot is handed over, not lost.** This is what makes the split work
  at all. The reboot decision only ever fires when *this* run installed a
  kernel — so a weekly no-reboot run would install one, and the monthly run
  would find nothing to install, conclude nothing was needed, and leave the host
  on the old kernel forever. A held reboot is now recorded in
  `/var/lib/proxmox-autoupdate/reboot-pending` and taken by the next run that is
  allowed to take it. The record clears as soon as the host is seen running the
  newest installed kernel, however it got there.

  Reports say **Reboot Pending** rather than *No Reboot Needed*, so a host is
  never quietly out of date.

- `--reboot-window` and `--no-reboot` on the command line, and a
  `--doctor` warning when *no* schedule may reboot — a configuration where a
  kernel installs and then waits indefinitely.

### Fixed

- **The installer reported a panel that was not running as a success.** The unit
  is `Type=simple`, so `systemctl is-active` says "active" the moment the
  process forks — before it has read a certificate or bound a port. A panel that
  started, threw and was restarted five seconds later looked perfectly healthy.
  The installer now makes an actual HTTPS request to the port, and on failure
  prints `systemctl status` and the last lines of the service log inline instead
  of suggesting you go and find them.

- **The toolbar button could silently never appear.** It was anchored solely to
  the *Documentation* button; any layout where that is renamed, moved out of a
  toolbar or loses its `onlineHelp` property left the injected code polling for
  two minutes and then giving up without a word — indistinguishable from a
  failed install. It now tries several anchors, logs to the browser console when
  none match, and falls back to a floating button so the panel is always
  reachable.

- **The installer never checked that the patch landed.** It trusted the
  patcher's exit code; it now reads `pvemanagerlib.js` back and confirms the
  block is there.

- **"I installed it and nothing happened" is usually browser cache.** The
  installer now says so explicitly, with the hard-refresh shortcut, rather than
  as a dim aside at the end.

- `--doctor` diagnoses all of the above: whether the port answers (not just
  whether systemd is happy), whether the button is present in
  `pvemanagerlib.js`, and whether the apt hook that survives a `pve-manager`
  upgrade is installed.

- The installer's own failure diagnostics could abort the install. Under
  `set -euo pipefail`, a missing `journalctl` made the diagnostic exit 127 and
  took the installer down with it — turning "the panel did not start" into "the
  install failed".

- A re-install no longer flattens a multi-schedule setup. It lists what is
  configured and offers to keep it, which matters most for the panel's own
  unattended self-update, where nobody is at the keyboard.

### Changed

- The reboot-time prompt and the schedule prompts explain what they are for, and
  the installer warns when the schedules it just wrote can never reboot.
- `README.md` documents the schedule modes, the handoff, and the cron
  day-of-month/day-of-week trap that makes "first Sunday of the month" fire
  weekly.

## 1.8.1 — 2026-08-12

Six defects that every automated check passed. They pass `bash -n`, they pass
shellcheck, and a scripted install completes cleanly with all of them present —
they are only wrong for a human sitting at a terminal, or for a value nobody
thought to type. Found by reading the installer as a transcript rather than as
a program.

### Fixed

- **None of the installer's questions were printed.** `read -p` shows its prompt
  only when *stdin* is a terminal, and the documented install is
  `curl -fsSL … | bash`, where stdin is the script being piped in. All 43
  questions printed nothing: the terminal sat at a blank line, cursor waiting,
  for a question it had never shown. Whole sections — Advanced settings most
  visibly — looked empty. Every prompt is now written out explicitly.

  The same bug made the uninstaller's `Proceed? (y/N):` invisible.

- **A password containing `$` stopped every scheduled run, silently.** Answers
  were interpolated raw into the config file, which is `source`d as root on
  every run. A `$` in a password aborted the run with `unbound variable` before
  the fatal-notification code was reached, so nothing was sent and updates
  simply stopped. A backtick or `$( )` in a pasted token **executed as root**
  every week. A `"` made the file unparseable. None of it was visible — the
  file on disk showed the right password. Values are now single-quoted with
  embedded quotes escaped, which is what the panel has always done and what
  the update script's own comment already claimed the installer did.

- **A port clash deleted the panel it had just installed.** If something else
  held the chosen port — Proxmox Backup Server on 8007 is the documented case —
  the installer flipped an internal flag that dropped it into the *teardown*
  branch, whose guard is "does the unit file exist?" — satisfied by the unit
  written seconds earlier. It un-patched the Proxmox UI, deleted the binary,
  the unit, its drop-in directory and the apt hook, and finished with a green
  "✓ Web control panel removed" for a panel the operator had just asked for,
  while the config file still said `ENABLE_WEB_UI="true"`. Nothing is removed
  now; the panel is left installed and stopped, with the two commands needed to
  put it on a free port.

- **`9:00` at the reboot prompt bricked the schedule.** The installer accepted
  any text, printed a green tick and "Deployment successful". The update script
  treats anything that is not 24-hour `HH:MM` as fatal and exits before touching
  a single guest — so every run from then on did nothing, into a cron log nobody
  reads. A single-digit hour is now padded; anything else is re-asked.

- **Re-installing downgraded an SSL/465 mail setup to STARTTLS.**
  `SMTP_SECURITY` was the one setting with no carry-over: it was reset to
  `starttls` on every run and written straight back out. That includes the
  panel's own unattended self-update, so mail could stop working after an
  upgrade nobody thought of as a mail change.

- **Every report claimed Mailgun delivered it.** The footer read "delivered via
  Mailgun EU API" whatever sent it — SMTP, Discord, Slack, Teams, ntfy, Gotify,
  Telegram, webhook — and on hosts with no Mailgun credentials at all, because
  the region defaults to EU. One report is built and handed to every channel, so
  it cannot name its own transport; it now names the host and the time instead.

### Changed

- Prompt copy throughout. `(current)` labelled the built-in defaults on a fresh
  install, where nothing is current; `[default: false]` and `[current: true]`
  asked the reader to decode a boolean to answer a 1-or-2 question;
  `Username []` offered an empty default and the password prompt offered to keep
  one that did not exist. Exclusions, the Windows timeout and the reboot time
  had no heading or explanation at all.

- Discord's bot token is no longer echoed to the terminal. Telegram's already
  was not.

- CI checks that no prompt uses `read -p`, and that every config value goes
  through the quoting helper. Both were invisible to every existing check.

## 1.8.0 — 2026-08-12

### Changed

- **Renumbered to the 1.x line.** Releases up to this point were numbered 2.x
  to 4.x, which overstated how long the tool had been in the open. Everything
  in this changelog has been restated on the 1.x line — what shipped as 4.7.0
  is 1.7.0 here — and the old tags are left in place on GitHub as a record.

  The tag lookup ignores the retired 2.x–4.x tags, because they sort above
  every 1.x release and "newest tag wins" would otherwise install the retired
  code on every fresh machine. An installation still reporting a 2.x–4.x
  version is treated as behind any 1.x release, so existing machines are
  offered the update instead of being stranded on "up to date" forever.

### Added

- **The installer asks about every notification channel.** It offered email,
  Discord, Slack and a generic webhook; the tool has supported Microsoft
  Teams, ntfy, Gotify and Telegram since 1.2.0, and the only way to reach them
  was to hand-edit the config or use the panel. All eight are now on the menu
  with their own prompts. Teams is listed separately from Slack because it
  cannot read Slack's payload format.

### Fixed

- **The installer asked for SMTP settings and then threw them away.** The
  prompts were added in 1.7.0 but the generated config file never contained
  `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_SECURITY` or
  `EMAIL_TRANSPORT` — so a fresh install that chose SMTP email silently sent
  nothing at all. The same omission covered every newer channel:
  `TEAMS_WEBHOOK_URL`, `NTFY_URL`, `NTFY_TOKEN`, `GOTIFY_URL`, `GOTIFY_TOKEN`,
  `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`.

- **Still no reload prompt after updating from a shell.** The prompt was tied
  to the self-update systemd unit, which only runs when the update is started
  from the panel. Running `install.sh` over SSH — how most upgrades actually
  happen — replaced the panel and the injected Proxmox JavaScript underneath
  every open tab without a word. Both now watch the installed version itself
  and offer the reload whenever it changes, whatever caused the change.

- **The generic webhook was described as the way to reach ntfy and Gotify.**
  Posting this tool's JSON payload to an ntfy topic publishes the raw JSON as
  the message body. Both have their own entries now, with the request shape
  each one actually expects.

- The deployment summary printed a Mailgun region and two empty email lines to
  everyone, including the majority who skip notifications entirely. It now
  lists the channels that were actually configured.

## 1.7.0 — 2026-08-12

### Fixed

- **Only the installer got the readable-colour fix in 1.4.0.** The uninstaller,
  the update script and the web-UI patcher were all still using the ANSI faint
  attribute, which xterm.js — the Proxmox web shell — renders at very low
  contrast. So every hint and detail line in the tool people actually run
  weekly, and in the uninstaller's "will keep" list, stayed close to invisible.
  All four now use bright black, and the uninstaller only emits colour to a
  real terminal.
- **The installer counted to six out of nine.** `STEP_TOTAL` said 9 while six
  `step()` calls existed, and the interactive sections used a different heading
  style entirely — so it showed `[1/9]`, then three unnumbered sections, then
  `[2/9]`, and never reached the total. One scheme now covers all ten phases,
  the web-panel step announces itself even when skipped so the count stays
  honest, and CI checks the declared total against the number of calls.
- **The uninstaller listed files under "Will keep" that `--purge` deletes.**
  With `--purge` it printed "nothing — --purge was given" and then named the
  config file and log directory underneath, which is the opposite of what was
  about to happen. Those now appear in the removal list, where they belong.
- The removal list also names the uninstaller itself and the run-history
  directory, both of which it removes and neither of which it mentioned.

### Added

- **The installer says which version it is installing**, before it installs it.
  It never mentioned one, so there was no way to tell what you were getting.
- **`--doctor` checks whether each running container can reach its package
  mirrors**, and names the cause when it cannot. It separates a DNS failure
  from a connectivity failure, and recognises the specific case where a
  default-deny INPUT chain with no rules is silently firewalling a container off
  from the world — which is what ufw leaves behind when it fails to start inside
  an unprivileged container, while still reporting itself as active. Every probe
  is time-boxed; a diagnostic that hangs is worse than none.

## 1.6.3 — 2026-08-12

### Fixed

- **Container detection never ran.** The Docker/Podman check added in 1.5.0 was
  placed after the package-manager branches — every one of which ends in
  `exit 0`, because that is how the sentinel protocol signals completion. It was
  unreachable on every successful path, so a Docker host with nothing to upgrade
  reported "already up to date" and said nothing about its containers, which is
  precisely the case the check existed for. Moved ahead of the package managers,
  and each probe is time-boxed so a wedged or starting daemon can never be the
  reason a guest update hangs.

### Added

- **Guests report how long refreshing the package list took**, and how many
  attempts it needed, whenever that exceeds the heartbeat interval. Output only
  returns when the exec finishes so it cannot be shown live, but it is the
  difference between "that guest took twelve minutes" and "eleven and a half of
  those minutes were `apt-get update`" — which is what identifies a slow mirror
  or a contended host rather than a problem with this tool.

## 1.6.2 — 2026-08-12

### Fixed

- **No reload prompt after a self-update.** 1.5.6 removed the duplicate prompt
  by silencing the panel's and leaving it to the toolbar patch. That was the
  wrong way round: the toolbar polls every 25 seconds when idle, and the panel
  service is restarting for part of that window, so its status request fails and
  it frequently never observes the update at all — leaving no prompt from
  either. The panel polls every two seconds and is the thing performing the
  update, so it is the reliable detector and now always prompts. The toolbar
  stands down while the panel is open, and still prompts other Proxmox tabs,
  which are the ones left running stale injected code.

## 1.6.1 — 2026-08-12

### Fixed

- **CI compared config defaults as text, so two spellings of the same number
  failed.** `DISCORD_MAX_UPLOAD` is written as `$((8 * 1024 * 1024))` in the
  script, which is clearer than `8388608`, and stored as the number in the
  panel. The check compared the strings and reported a mismatch between two
  identical values. It now evaluates arithmetic before comparing, restricted to
  digits and operators so nothing in a config default can be executed.

## 1.6.0 — 2026-08-12

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

## 1.5.6 — 2026-08-12

### Fixed

- **Two "reload now" prompts after a self-update.** The panel offered a reload,
  and so did the toolbar patch running in the Proxmox page — two dialogs for
  one event, on the normal path where the panel is opened from the toolbar
  button. The panel now stays quiet when it is embedded, since reloading the
  parent page reloads the frame with it; opened standalone in its own tab there
  is no toolbar, so it still offers the reload itself.

## 1.5.5 — 2026-08-12

### Fixed

- **"Check for updates" answered from a five-minute-old cache.** The resolved
  release reference is cached for 300 seconds to keep background status polls
  off the GitHub API, but the button shared that cache — so pressing it minutes
  after a new version was published still reported "up to date", and pressing
  it again changed nothing. An explicit check now bypasses the cache and
  refreshes it; background polls still use it.

## 1.5.4 — 2026-08-12

### Fixed

- **Update checks could sit on an old version indefinitely.** The panel and the
  installer asked GitHub for `/releases/latest`, which only knows about
  *published Release objects*, and fell back to git tags only when that
  returned nothing at all. So a maintainer who tags and pushes without also
  publishing a Release leaves every installation reporting "up to date" against
  a version that is not the newest — which is exactly what happened here
  between v1.4.0 and v1.5.3: six tags, no Releases, and every panel reporting
  1.4.0 as current.

  Both now take whichever is *newer* of the published Release and the highest
  git tag, comparing by version rather than by the order GitHub returns things.
  A missing Release, a deleted tag, or an odd ordering can no longer make an
  update check resolve backwards or stall.

## 1.5.3 — 2026-08-12

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

## 1.5.2 — 2026-08-12

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

## 1.5.1 — 2026-08-12

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

## 1.5.0 — 2026-08-12

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

## 1.4.2 — 2026-08-12

### Fixed

- **A dry run reported guests as "updated".** The dry-run branch incremented the
  same counter as a real install, so a run that changed nothing finished with
  "LXC: 8 updated" — the one number someone reads to find out what happened.
  Dry runs now count separately and the summary says "8 with updates pending",
  in the console, in notifications, and in the run history the panel shows.
  Found on the first real dry run against a live host.

## 1.4.1 — 2026-08-12

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

## 1.4.0 — 2026-08-12

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

## 1.3.1 — 2026-08-11

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

## 1.3.0 — 2026-08-11

### Added

- **A sticky header.** The title, status, schedule and tabs stay put while the
  page scrolls, so navigation is reachable from anywhere on a long page.

## 1.2.2 — 2026-08-11

### Fixed

- **The Settings tab opened empty.** Clicking it showed the container and
  fetched the data but never unhid the sub-section inside it, so the content
  sat behind `hidden` until a sub-tab click revealed it — which is why clicking
  away and back appeared to fix it. Introduced in 1.1.0 with the tab
  consolidation.

## 1.2.1 — 2026-08-11

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
  timeouts added in 1.2.0 are not present in a config file written by an
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

## 1.2.0 — 2026-08-11

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

## 1.1.1 — 2026-08-11

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

## 1.1.0 — 2026-08-11

An interface release, on top of the correctness work in 1.0.0. The panel now
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
  `LINUX_SHUTDOWN_TIMEOUT` and `AGENT_ERROR_GRACE` were added in 1.0.0 and were
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

- **Exit code 2 was reported as a failure.** 1.0.0 introduced it to mean "the
  run finished, but guests were left mid-update, so the host reboot was held
  back" — usually a Windows guest still installing. The panel showed that as
  "last run failed (2)", turning a successful and deliberately cautious run
  into an apparent error.
- **A lost connection looked identical to an idle panel.** The page silently
  stopped updating. It now says it is reconnecting — which matters most during
  a host upgrade, when the Proxmox API restarts and someone is watching.
- Panel copy that stopped being true in 1.0.0: the Run tab promised "Both email
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

These predate the 1.x line and keep the tag names they were released under, so
the links still work. Their numbers sort above 1.x and mean nothing next to it —
v3.5.1 is older than 1.0.0, not newer.

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
