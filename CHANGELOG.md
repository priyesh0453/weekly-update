# Changelog

All notable changes to this project are listed here. The format is based on Keep a Changelog, and versions follow Semantic Versioning.

## [Unreleased]

- Planned: a Homebrew tap, so `brew install` becomes the third way to get it.

## [0.1.0]

First public version, not yet tagged; I add the date when I cut the tag. It is a reference design. The README lists what it does and what it never does; docs/LIMITATIONS.md lists its known limitations and describes how install and uninstall decide what belongs to this tool; docs/CONFIG.md lists every config key; docs/ARCHITECTURE.md gives the invariants and the tests that pin them. This entry does not restate them.

### Added

- `bin/weekly-update` with the modes run, auto, scheduled, setup, check, status, verify, plist and help, plus `--dry-run` for run and auto and `--version`.
- One optional config file, `~/.config/weekly-update/config`, read by a strict reader: an unknown key or a bad value stops every mode except `help`, `--help` and `--version` with its line number.
- Automatic cask mapping for Dock apps (casks Homebrew already manages, and matching cask names), report-only until confirmed with `setup` or in the config.
- `install.sh`, which renders the LaunchAgent from `templates/launchagent.plist.template`, and `bin/weekly-update-uninstall` (also `uninstall.sh`), which moves the tool copy and its LaunchAgent aside into a dated folder and verifies.
- `bin/weekly-update-verify`, a static regression tripwire, and `tests/`, with test doubles for 12 of the system tools the scripts drive, scenario tests, and a probe for every deny rule of the tripwire and for many of its structure checks.
- A heartbeat warning when no pass has finished for `heartbeat_days`, and a warning when an app this tool saw goes missing.
- `AGENTS.md` and `skills/weekly-update/SKILL.md` for coding agents, and `docs/ADAPT.md` for porting the design to another platform.
