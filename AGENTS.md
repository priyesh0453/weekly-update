# Instructions for AI coding agents

This repository is `weekly-update`: a bash 3.2 tool that keeps a Mac's Dock apps and macOS current once a week, published as a reference design people adapt. These instructions apply to any AI coding agent working in it.

Read first: `README.md`, `docs/ARCHITECTURE.md`, `docs/CONFIG.md` (every config key with its range and default), and the skill at `skills/weekly-update/SKILL.md`, which explains how to run the tool safely and how to change its config. `docs/LIMITATIONS.md` lists what I have not tested and how install and the uninstaller decide what is this tool's.

## Safe to run

These only read, or run against test doubles in a temporary folder:

- `./bin/weekly-update --help`, `--version`, `help MODE`
- `./bin/weekly-update check` and `./bin/weekly-update status` (report only; write nothing)
- `./bin/weekly-update plist` (prints the LaunchAgent the config renders to)
- `./bin/weekly-update run --dry-run` and `./bin/weekly-update auto --dry-run` (no lock, no refresh, no history, no change)
- `./install.sh --dry-run`, `./uninstall.sh --dry-run` and `./bin/weekly-update-uninstall --dry-run`
- `./bin/weekly-update-verify` (the static tripwire)
- `/bin/bash tests/run-all.sh` (the test suite; 12 of the system tools the scripts drive are replaced by test doubles, and a few read-only calls, such as `ps` and `pgrep`, read the real process table; it takes about 15 to 20 minutes under the sandbox I use for the tests, and longer on a busy Mac)
- `shellcheck -x -s bash` on `bin/*`, `install.sh`, `uninstall.sh`, `tests/*.sh` and `tests/shims/*` (on the pinned `lib/*.sh` it prints info-level notes only), and `/bin/bash -n` on any script

## Never run without the person asking in this conversation

- `./install.sh`, `./uninstall.sh`, `bin/weekly-update-uninstall` (only their `--dry-run` forms, listed above, are safe)
- `./bin/weekly-update` with no mode, or with `run`, `auto`, `scheduled` or `setup`: these upgrade apps, ask to quit apps, or install macOS updates
- `brew upgrade`, `brew install`, `brew uninstall`, `brew cleanup`, `softwareupdate --install`, `sudo`, `launchctl bootstrap`, `launchctl bootout`, `defaults write`

Show the person the command instead and let them run it.

## Rules for changes

- Never add a config key that makes the unattended pass quit an app, call `sudo`, install macOS updates, or start at load.
- Keep the invariants in `docs/ARCHITECTURE.md`. If a change moves a risky command, move its check in `bin/weekly-update-verify` and add a probe in `tests/test-gate.sh`.
- Do not edit anything in `lib/`. It is vendored and pinned by `lib/MANIFEST.sha256`; `tests/test-manifest.sh` fails when a file in `lib/` does not match that manifest or is not listed in it. Work around it in `bin/`.
- Stock macOS bash 3.2 only: no associative arrays, no `mapfile`, no `${var,,}`. Every executable script starts with `#!/bin/bash`.
- ASCII only. Comments explain why, never what.
- Every behaviour change comes with a scenario in `tests/`, and `/bin/bash tests/run-all.sh` must exit 0. Report the commands you ran and their exit status (a dry run of the runtime exits 0 even when its report lists failures, so also report its last lines; the install and uninstall dry runs exit 1 for the ownership stops, such as an agent whose owner is unknown (and, for install, another program's agent at its own label), and 2 when run as root or, for install, on a config it cannot render; they neither take the run lock nor make a folder, so only the real run reports a pass in progress or a tool folder it cannot write to, and it then unloads, moves and installs nothing and exits 1, though a first install may leave the empty folders and the empty run.lock file it made; without the install manifest (a tool folder removed by hand), the uninstaller's dry run also exits 0 when the config cannot be rendered but it found an agent of this tool, which the real run removes before it exits 1; with the manifest in place the config is not rendered); never claim a test passed that you did not run.
