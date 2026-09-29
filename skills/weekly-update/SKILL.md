---
name: weekly-update
description: Inspect, explain and adapt the weekly-update macOS updater safely. Use when someone asks what weekly-update would do on their Mac, why a weekly pass skipped, deferred or opened a window, how to read its history, how to change its schedule or app list, or how to port it to another system. Covers the read-only modes (check, status, plist, dry runs), the verify tripwire, the test suite, and the rules for editing its config.
license: MIT
compatibility: The tool runs on macOS with the stock /bin/bash 3.2 and Homebrew. The read-only modes need a shell in the repository folder or the installed copy; the test suite runs from the repository folder and replaces 12 of the system tools the scripts drive with test doubles.
metadata:
  version: "0.1.0"
  repository: https://github.com/priyesh0453/weekly-update
---

# weekly-update

`weekly-update` keeps the apps in a Mac's Dock and macOS itself current, once a week. A LaunchAgent runs `weekly-update auto` in hourly slots; the unattended pass only upgrades closed apps the person confirmed, and when something needs them and someone is at the Mac, it opens one Terminal window, which asks first. It never deletes anything itself.

This skill is for helping a person understand, check and adapt it. The person runs anything that changes their Mac; you run only the read-only commands below.

## Run only these

From the repository folder. The `bin/` commands also work from the installed copy at `~/.local/share/weekly-update/app/`; `install.sh` and `tests/` exist only in the repository folder.

| command | what it shows | writes |
|---|---|---|
| `./bin/weekly-update --help` or `help MODE` | the modes and flags | nothing |
| `./bin/weekly-update check` | the Dock inventory (installed version, index version, state, group, whether the cask is confirmed or proposed), the macOS listing, the schedule | nothing |
| `./bin/weekly-update status` | the last history rows, restart requests, the next unattended pass, whether the installed LaunchAgent matches the config, folder sizes | nothing |
| `./bin/weekly-update auto --dry-run` | what the next unattended slot would do, including whether it would open a window | nothing |
| `./bin/weekly-update run --dry-run` | what an interactive pass would upgrade, open or install | nothing |
| `./bin/weekly-update plist` | the LaunchAgent the config renders to | nothing |
| `./install.sh --dry-run` (repository folder only) | where install would put files and which label it would load | nothing |
| `./uninstall.sh --dry-run`, or `bin/weekly-update-uninstall --dry-run` in the installed copy | what the uninstaller would unload and move | nothing |
| `./bin/weekly-update-verify` | the static regression tripwire; PASS or FAIL per check | nothing |
| `/bin/bash tests/run-all.sh` (repository folder only; takes about 15 to 20 minutes, longer on a busy Mac) | the scenario tests, run against test doubles in a temp folder | temp files only |

Exit status: 0 done or stood down, 1 partial, stopped or issues found, 2 usage, invalid config or an unusable setup, 4 needs a terminal, 129, 130 or 143 a pass stopped by a hangup, an interrupt or a terminate signal. A dry run of the runtime (`run --dry-run`, `auto --dry-run`) exits 0 even when its report lists failures, so report what its last lines say, not only its exit status. The install and uninstall dry runs exit 1 for the ownership stops, such as an agent whose owner is unknown (and, for install, another program's agent at its own label), and 2 when run as root; install's also exits 2 for a config it cannot render. These two dry runs neither take the run lock nor make a folder, so only the real run reports a pass in progress or a tool folder it cannot write to; that run then unloads, moves and installs nothing and exits 1, though a first install may leave the empty folders and the empty run.lock file it made. Without the install manifest (a tool folder removed by hand), the uninstaller's dry run also exits 0 when the config cannot be rendered but it found an agent of this tool, which the real run removes before it exits 1; with the manifest in place the config is not rendered.

## Never do these for the person

- Do not run `./install.sh` or `./uninstall.sh` without `--dry-run`, or `weekly-update` with no mode or with `run`, `auto`, `scheduled` or `setup`. They upgrade apps, ask to quit apps, install macOS updates or load the schedule. Give the person the exact command and let them run it.
- Do not run `bin/weekly-update-uninstall` without `--dry-run`, or `brew upgrade`, `brew install`, `brew uninstall`, `brew cleanup`, `softwareupdate --install`, `sudo`, `launchctl bootstrap`, `launchctl bootout` or `defaults write`.
- Do not answer the window's questions on the person's behalf, and do not pipe `yes` into the tool.
- Do not edit files in `lib/`; they are pinned by `lib/MANIFEST.sha256`.

## Reading what happened

Records are in `~/Library/Logs/weekly-update/`:

- `history.tsv`: rows of `time, mode, outcome, detail`. A `completed`, `partial`, `escalated`, `declined` or `started` row from `run`, `auto` or `scheduled` dated on or after the slot day (the most recent day that has a slot, today included) ends that slot day for the unattended slots; any other row does not. `slot skipped` is written by a slot that stood down because the slot day was already done, or found another run holding the lock; only the second is retried. The detail of a `completed`, `partial`, `escalated` or `escalation deferred` row from `run`, `auto` or `scheduled` lists the reasons (`macOS`, `apps-needing-a-password`, `apps-to-open`, `running-apps`, `failed-steps`), how many apps were upgraded, and what was skipped.
- `run-*.log`: one tagged line per event, with the raw output of the commands it ran (Homebrew, the `softwareupdate` listing) untagged between them; `FAIL` lines name what failed and `VERDICT` is the last tagged line.
- `nudge-ledger.tsv`: every attempt to open an app so its own updater fetches; an app that stays at one version through the configured number of attempts is no longer opened.

To explain "why did it skip my app", run `check` and read the app's row: `proposed` means not confirmed yet, `assisted` means it needs a person, `Writable no` means macOS would refuse Homebrew, a warning that names a file in the way of a link means Homebrew would fail the upgrade (the person moves the file aside; `in-the-way(APP)` in the history's failures when an upgrade was due), and a running app is always left alone by the unattended pass.

## Changing the config

The config is `~/.config/weekly-update/config`, optional, in sections of `key = value`; `config/weekly-update.conf.example` documents every key, and `docs/CONFIG.md` lists each key's type, range and default with a worked example.

- To manage an app: add `[app BUNDLE_ID]` and `cask = TOKEN`. The person can get the bundle id with `osascript -e 'id of app "Name"'`, or confirm proposed casks interactively with `./bin/weekly-update setup` (the person runs it; it asks questions).
- To leave an app alone: `group = vendor` (its maker updates it) or `group = manual`.
- To change the schedule: `weekday`, `first_hour`, `last_hour`, `minute` under `[updater]`, then the person reruns `./install.sh`.
- After any edit, run `./bin/weekly-update plist` or `check`: an invalid file is rejected with its line number and exit status 2, and nothing runs until it is fixed.

## Adapting or porting

Read `docs/ARCHITECTURE.md` (stages, invariants I1 to I9, records), `docs/LIMITATIONS.md` (what I have not tested, and how install and the uninstaller decide what is this tool's) and `docs/ADAPT.md` (the five questions a port must answer, the Windows and Linux equivalents, and a prompt a person can reuse). For every change: keep the unattended pass narrower than the interactive one, add a scenario in `tests/`, run `/bin/bash tests/run-all.sh`, and report the commands you ran with their exit status.
