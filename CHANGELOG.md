# Changelog

Only the current release is kept here — this is what the web panel shows when
it offers you an update, so it should describe the version you are about to
install and nothing else. Earlier releases are in the git history and on the
[releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

The heading format is parsed by the panel: `## <version> — <YYYY-MM-DD>`, then
`### Added` / `### Fixed` / `### Changed` sections of bullet points.

## 3.4.3 — 2026-07-31

### Fixed
- Updating the tool silently started a dry run of every guest. The installer's end-of-run prompt defaults to "dry run" on Enter, and unattended it reads end-of-input — so a self-update triggered it. That run also took the update lock, which is why the status said "scheduled run in progress" during an update.
- The status now says **updating Auto-Update** while the tool updates itself, rather than reporting it as a guest update.
- Elements marked hidden could stay on screen: `.hidden` was less specific than the rules it had to override, so the reload notice showed while idle and the "live" tag never went away.

### Changed
- The reload notice is calmer and only appears while an update is actually running. When it finishes you are simply offered a reload, rather than warned.
