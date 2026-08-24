# proxmox-autoupdate — working notes

Automated updater for Proxmox VE: the host, LXC containers, Linux VMs and
Windows VMs, plus an optional web control panel bolted into the Proxmox UI.
Public repo, free tool, so assume unattended installs on machines you cannot
see.

## Layout

| File | What it is |
| --- | --- |
| `update-everything.sh` | The updater. ~4k lines of bash. Runs from cron. Carries `PAU_VERSION`, the single source of truth for the version. |
| `install.sh` | Interactive installer. Also run unattended by the panel's self-update. Writes `/etc/proxmox-autoupdate.conf` and root's crontab. |
| `uninstall.sh` | Removes everything; `--purge` also removes logs and state. |
| `webui/pve-autoupdate-ui` | The panel. One file, stdlib-only Python 3, HTTPS, serves its own HTML/CSS/JS as string templates. |
| `webui/patch-webui.sh` | Appends the toolbar-button block to `pvemanagerlib.js`. Append-only, atomic, exactly reversible. |
| `webui/99-proxmox-autoupdate-webui` | apt hook: re-applies the button after a `pve-manager` upgrade. |
| `ci/invariants.sh` | Cross-file checks no linter can see. **Read this before changing anything** — each check is a bug that shipped. |

## Rules that matter

- **Never `read -p`.** Bash prints a `-p` prompt only when *stdin* is a
  terminal, and the documented install is `curl … | bash`, where stdin is the
  piped script. Use the `ask` / `ask_secret` helpers in `install.sh`. CI enforces
  this.
- **Never write a config value unquoted.** The config is `source`d as root every
  run. Use `sq()`; a `$` or a backtick in a pasted token otherwise breaks every
  run silently or executes as root. CI enforces this.
- **Never trust `systemctl is-active` for the panel.** `Type=simple` reports
  active as soon as the process forks. Ask the port.
- **`set -euo pipefail` is on in `install.sh`.** Guard every diagnostic with
  `|| true`; a missing `journalctl` once aborted the whole installer with 127.
- **Define before use.** `--doctor` runs early and returns; anything it touches
  must be defined above `run_doctor()`, or `set -u` aborts.
- **Line continuations get eaten** by naive Python string replacement — always
  `bash -n` after editing, and check the emitted line.
- Versions are on the **1.x line**. Tags `v2.x`–`v4.x` are retired and are
  filtered out of tag lookups in `install.sh` and the panel, because they sort
  above 1.x. If this ever legitimately reaches 2.0, those filters must go.

## Schedules

`UPDATE_SCHEDULES` is `;`-separated, each entry `<5-field cron>|<mode>|<label>`:

- `yes` — update, reboot if this run installed a kernel *(no flag)*
- `no` — update, never reboot → `--no-reboot`
- `only` — reboot window, installs nothing → `--reboot-window`

Parsed in three places that must agree: `parse_schedules()` in `install.sh` and
`update-everything.sh` (byte-identical, CI-checked) and `parse_schedules()` in
the panel. A held reboot is recorded in
`/var/lib/proxmox-autoupdate/reboot-pending` and taken by the next run allowed
to take it — without that, splitting the schedules silently never reboots.

cron ORs day-of-month with day-of-week when both are restricted, so
`0 3 1-7 * 0` fires weekly, not on the first Sunday. Use a day of the month.

## Testing without a Proxmox host

There is no Docker or WSL here. The approach that works, and has caught real
bugs every time:

1. `sed` the absolute paths in `install.sh` into a sandbox root.
2. Stub `pveversion`, `pvesh`, `pct`, `qm`, `systemctl`, `crontab`, `apt-get`,
   `id`, `install`, `ss` on `PATH`.
3. Patch the fd-3 setup to read answers from a file.
4. **Run it with stdin as a pipe** — `echo x | bash install.sh` — because that
   is the condition that broke the prompts.
5. Check the generated config parses (`bash -n`) *and* sources cleanly under
   `set -u`.

`python3` is not on `PATH` in Git Bash; a shim in the scratchpad makes
`ci/invariants.sh` run its Python checks.

## Release

Bump `PAU_VERSION` in `update-everything.sh` and `PAU_FALLBACK_REF` in
`install.sh`, add a `## <version> — <date>` changelog entry (CI checks they
match), run `ci/invariants.sh`, commit, push, tag `vX.Y.Z`, then create the
GitHub release via the API with `make_latest: true`.

Commits: no `Co-Authored-By` trailer.

## Install modes

`install.sh` asks Typical / Custom first (Keep / Typical / Custom when a config
already exists; the panel's `--unattended` self-update always takes Keep).

- `apply_typical_profile()` holds the Typical defaults. Notifications are off —
  never guess at somebody's mail server.
- `asking()` is true only in Custom mode. The Notifications, Advanced settings
  and Schedule prompt blocks are each wrapped in `if asking; then … else
  <print what was chosen> fi`.
- **Every config key must be set outside those gates**, either in
  `apply_typical_profile()` or in the seeded-from-`PREV_*` block above
  `step "Notifications"`. Skipping a prompt otherwise leaves the variable unset,
  and `set -u` aborts partway through writing the config. CI enforces this.

## Reaching the panel

The panel is a separate service on its own port (8007), because `pveproxy` has
no reverse-proxy or add-a-route mechanism — the only supported way to add
endpoints under 8006 is a `PVE::API2` Perl module, which upgrades break.

`WEB_UI_PUBLIC_URL` is the escape hatch for anyone behind a tunnel or reverse
proxy: the injected button uses it verbatim instead of building
`https://<location.hostname>:<port>`. It is read by `patch-webui.sh` (not the
updater — CI knows this) and **interpolated into a JavaScript string literal in
pvemanagerlib.js**, so it is validated as a bare `http(s)` origin in both the
patcher and the panel. Loosening either regex is a script-injection hole in the
Proxmox UI.

Anything that probes the panel from the browser (`probePanel`, `fetchStatus`)
cannot distinguish a rejected certificate from a refused connection, a timeout
or a DNS failure — a `no-cors` fetch rejects identically for all of them. Never
write a message that claims to know which.
