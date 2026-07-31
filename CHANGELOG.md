# Changelog

Only the current release is kept here — this is what the web panel shows when
it offers you an update, so it should describe the version you are about to
install and nothing else. Earlier releases are in the git history and on the
[releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

The heading format is parsed by the panel: `## <version> — <YYYY-MM-DD>`, then
`### Added` / `### Fixed` / `### Changed` sections of bullet points.

## 3.5.0 — 2026-07-31

### Changed
- Credentials are no longer passed to `curl` as arguments. A process's command line is readable from `/proc` by any local user, which made the Discord bot token, the webhook URLs and the Mailgun API key briefly visible in `ps`. They are now supplied on stdin instead.
- A 401 from Discord now identifies which credential was actually pasted — Application ID, Public Key or Client Secret — rather than only reporting the token as invalid.
