# Changelog

Only the current release is kept here — this is what the web panel shows when
it offers you an update, so it should describe the version you are about to
install and nothing else. Earlier releases are in the git history and on the
[releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

The heading format is parsed by the panel: `## <version> — <YYYY-MM-DD>`, then
`### Added` / `### Fixed` / `### Changed` sections of bullet points.

## 3.4.4 — 2026-07-31

### Fixed
- Check for updates could keep reporting the previous release for several minutes after one was published. `raw.githubusercontent.com` serves through a CDN that caches for a few minutes, and the check accepted whatever copy it was given. Requests now carry a unique query string and no-cache headers.
- The changelog was fetched the same way and could be equally stale.

### Changed
- "Up to date" now names the published version and the time of the check, so a genuine match can be told apart from a lookup that failed or returned something old.
