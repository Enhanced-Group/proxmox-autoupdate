# Changelog

Only the current release is kept here — this is what the web panel shows when
it offers you an update, so it should describe the version you are about to
install and nothing else. Earlier releases are in the git history and on the
[releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

The heading format is parsed by the panel: `## <version> — <YYYY-MM-DD>`, then
`### Added` / `### Fixed` / `### Changed` sections of bullet points.

## 3.4.2 — 2026-07-31

### Added
- **Diagnose Discord DM** button. It walks the DM flow one call at a time and reports which step fails and why — bad token, the bot's own ID, no shared server, or a rejected recipient — instead of a bare "400".
- Unsaved-change tracking on every settings tab: a dot on the tab, a highlighted Save button, a banner, and a warning if you close the page with edits pending.

### Fixed
- The test notification aborted before sending on configs written by an older installer, because it sourced them under `set -u` without defaulting the newer keys.
- A bot token pasted with its `Bot ` prefix is now accepted by the diagnostic as well as the notifier.
