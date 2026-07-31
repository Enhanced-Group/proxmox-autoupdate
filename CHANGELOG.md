# Changelog

Only the current release is kept here — this is what the web panel shows when
it offers you an update, so it should describe the version you are about to
install and nothing else. Earlier releases are in the git history and on the
[releases page](https://github.com/Enhanced-Group/proxmox-autoupdate/releases).

The heading format is parsed by the panel: `## <version> — <YYYY-MM-DD>`, then
`### Added` / `### Fixed` / `### Changed` sections of bullet points.

## 3.4.1 — 2026-07-31

### Fixed
- The Update Everything button overflowed into the Documentation button. It is now larger, sized by ExtJS rather than CSS, and no longer clips.
- Discord direct messages reported a bare "400" with no cause. The actual message, error code and offending field are now shown.
- An empty embed footer or description caused a 400 that looked like a configuration problem.
- A bot token pasted with its "Bot " prefix is now accepted rather than producing "Bot Bot …".
- Field-level Discord errors never appeared, because the extraction called `join()` on a path containing array indices.

### Changed
- The status indicator is now the button's icon — a coloured dot, green, red or pulsing amber — instead of a badge on the right.
- The button says when it is updating **itself**, which is distinct from updating the guests, and prompts you to reload your Proxmox tabs once it finishes.
- The changelog now carries only the current release.
