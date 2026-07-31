# Changelog

Only the current release is kept here — this is what the web panel shows when
it offers you an update, so it should describe the version you are about to
install and nothing else. Earlier releases are in the git history and on the
[releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

The heading format is parsed by the panel: `## <version> — <YYYY-MM-DD>`, then
`### Added` / `### Fixed` / `### Changed` sections of bullet points.

## 3.4.5 — 2026-07-31

### Changed
- When Discord rejects a bot token, the diagnostic now works out which credential was actually pasted — Application ID, Public Key or Client Secret — instead of only saying the token is invalid. If the value is the right shape, it says the token has been revoked or reset instead.
