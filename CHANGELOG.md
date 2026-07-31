# Changelog

Only the current release is kept here — this is what the web panel shows when
it offers you an update, so it should describe the version you are about to
install and nothing else. Earlier releases are in the git history and on the
[releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

The heading format is parsed by the panel: `## <version> — <YYYY-MM-DD>`, then
`### Added` / `### Fixed` / `### Changed` sections of bullet points.

## 3.5.1 — 2026-07-31

### Fixed
- **Send test notification** failed with HTTP 400 while real notifications sent normally. The test copies the notifier out of the update script, and two helpers added in 3.5.0 fell outside the copied range — so the credentials never reached `curl`. The section is now delimited by explicit markers and checked for completeness before use.
- The test button reported a bare "HTTP 400" instead of the reason. The endpoint returned a 400 status for a failed test, which made the browser treat it as a transport error and discard the explanation in the body.
