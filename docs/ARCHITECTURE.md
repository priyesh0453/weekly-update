# Architecture

This is the reference design behind `weekly-update`: the stages a pass goes through, the rules that never bend, the records it leaves, and the points where it decides. Function names refer to `bin/weekly-update` unless another file is named.

## Files

| file | role |
|---|---|
| `bin/weekly-update` | the runtime: every mode, one file |
| `bin/weekly-update-verify` | the static regression tripwire (reads, never writes). With no option it checks the tree it lives in; `--runtime`, `--plist`, `--template`, `--install`, `--uninstall` and `--verifier` each check one file, which is how `tests/test-gate.sh` runs it on a broken copy (`--help` lists them) |
| `bin/weekly-update-uninstall` | unload, move aside, verify |
| `install.sh`, `uninstall.sh` | install from a download; `uninstall.sh` runs the uninstaller |
| `templates/launchagent.plist.template` | the LaunchAgent, with `__HOME__`, `__LABEL__` and `__CALENDAR__` tokens |
| `rules/*.rules` | the denylists the tripwire applies to the runtime, `install.sh`, the uninstaller and itself |
| `lib/*.sh` | the shared library (config reader, reporting, lock, prompts, gate helpers), vendored byte for byte and pinned by `lib/MANIFEST.sha256`. It also carries `classify.sh`, which this tool does not use |
| `tests/` | the harness, test doubles and scenario tests |
| `docs/` | `CONFIG.md` (every config key with its type, range and default), `LIMITATIONS.md` (known limitations, and how install and the uninstaller decide what is this tool's), `ADAPT.md` (changing and porting the design, with the Windows and Linux equivalents), and `sample-output.txt`, what the README Quickstart commands printed in one run in the test mode; I captured it once, outside the tests, and no test regenerates it |

## The unattended flow

```text
launchd slot (hourly on one weekday, first_hour to last_hour; slots slept through run as one at the next wake)
  |
  v
weekly-update auto
  |
  +-- a pass finished since the slot day? - yes --> row "slot skipped", exit 0
  |
  +-- preflight: tools, Homebrew, battery, run lock, keep-awake
  |     +-- battery below the floor -----------> row "battery deferred", notify, exit 0
  |     +-- lock held (status 75) ------------> row "slot skipped", exit 0
  |     '-- lock broken (any other status) ---> row "stopped", notify, exit 1
  |
  +-- today's last row deferred a window (Stages, retry)? -- yes --> DECISION with its reasons
  |
  +-- brew update, with a deadline
  |     '-- fails or hangs -------------------> row "slot deferred", notify, exit 0
  |
  +-- inventory: each Dock tile to a cask (confirmed, proposed, or none)
  +-- apps: upgrade what is confirmed, managed, outdated, silent, closed and writable
  +-- macOS: list pending updates, install nothing
  |
  v
DECISION (auto_finish; the only place the pass row is written)
  +-- no reasons ------------------------------> row "completed", notify "Done", exit 0
  +-- reasons, nobody at the Mac --------------> row "escalation deferred", notify, exit 0 or 1
  '-- reasons, someone at the Mac -------------> open the window, row "escalated", exit 0 or 1
                                                   |
                                                   v
                              weekly-update scheduled, in a Terminal window
                                +-- "Run the weekly update now?" (default No, times out)
                                +-- no, timeout, closed window --> row "declined", exit 0
                                '-- yes --> preflight, row "started", interactive pass,
                                            stop keep-awake (or leave it to end with the run), release lock, closing prompt,
                                            row "completed" or "partial"
```

Reasons that need a person: `macOS` (updates are pending), `apps-needing-a-password` (a confirmed, outdated app in the `assisted` group whose bundle this account can write), `apps-to-open` (a closed app is behind and its own updater should fetch), `running-apps` (a confirmed app was running, so it was skipped), `failed-steps` (anything failed, including a query).

Exit status 0 or 1 on the decision rows follows whether anything failed in the pass, so launchd's "last exit code" means something.

## Stages

| stage | function | what it decides | on failure |
|---|---|---|---|
| stand-down | `pass_finished_since_slot_day` | a terminal row from `run`, `auto` or `scheduled` dated on or after the slot day (the most recent day with a slot, today included) ends that slot day | none: it only reads `history.tsv` and the slots from `slot_list` |
| retry | `last_pass_row_today` | today's last row from `run`, `auto` or `scheduled`, other than `slot skipped`, `skipped` and `restart-requested`, is `escalation deferred`, so only the presence check and the window are retried | falls through to a full pass |
| preflight | `preflight` | tools present, Homebrew found, battery above the floor, lock taken, keep-awake running | stop with a record, or stand down |
| index | `refresh_index` | the index is fresh enough to decide on | the slot defers (I5) |
| inventory | `load_dock_inventory` | which cask each app maps to, its group and its state | a failed query is a failure and the app is left alone; Dock preferences that are missing or cannot be read are a failure, never an empty Dock |
| apps | `phase_dock_apps`, `upgrade_cask` | what may be upgraded now | recorded as a reason |
| macOS | `phase_macos dry` | what is pending | a failed listing, or one this tool cannot read, is recorded as a failure |
| decision | `auto_finish` | notify, defer, or open a window | a window that cannot open becomes `partial` and a notification |

Groups, per app: `system` (macOS updates it), `vendor` (its maker does, from your config), `silent` (Homebrew may upgrade it unattended), `assisted` (only an interactive pass upgrades it, for example one with an installer package, a background helper, a bundle or link folder this account cannot write, or a file in the way of a link), `manual` (you update it inside the app). An app is `silent` only when its cask's artifacts are all on an allowlist, its uninstall steps are only quit or signal, the cask's app name equals the bundle's, the bundle and its folder are writable, and every folder Homebrew links into for it is writable (else Homebrew would ask for the administrator password).

## Invariants

Each invariant has a place in the code and a tripwire check. The tripwire checks text; the tests check behaviour. The test column names the scenarios that check each invariant's behaviour, and says where a part of it is pinned only by the tripwire and its probes.

| id | invariant | where | tripwire (verify) | test |
|---|---|---|---|---|
| I1 | update-only environment: `noclobber`, and Homebrew cleanup, autoremove, upgrade-on-install (`HOMEBREW_NO_INSTALL_UPGRADE`: `brew install` never upgrades something already installed) and hints off, no auto-update, and `HOMEBREW_CASK_OPTS` cleared so a shell's cask options never reach Homebrew; only an adoption passes `--no-binaries`, because a failed adoption is rolled back and removes the app; the unattended pass also turns off Homebrew's own quit of running apps | the head of the file; `adopt_cask`; `mode_auto` | the head exports and the unset, no other `HOMEBREW_CASK_OPTS` assignment, `--no-binaries` in the adoption call, the `HOMEBREW_NO_UPGRADE_QUIT_CASKS` export in `mode_auto` | S1, S5, the binary-link scenario and the adoption-refusal scenario check the settings every Homebrew call ran under; S5 checks Homebrew's own quit; the binary-link scenario checks a command-line link survives an unattended upgrade; `noclobber`: the tripwire check only |
| I2 | a normalized denylist: no deleting, moving or copying verbs, no `eval`, no `${BREW}`, no in-place edits, no other `osascript` or `open` forms, no overwriting redirect | the whole runtime | `rules/runtime.rules` and the redirect check | the probes in `tests/test-gate.sh` |
| I3 | a restart needs its own yes: default No, the request is on record before the install, No means download only | `consent_restart` | single site, order and default checks | S10 |
| I4 | an unwritable bundle is never quit or handed to Homebrew | `upgrade_cask`, `load_dock_inventory`, `adopt_cask` | order checks | S7 |
| I5 | a slot that cannot refresh the index defers without a pass row | `mode_auto` | order check | S4 |
| I6 | no window opens unless someone is at the Mac | `auto_finish` | order check | S2 |
| I7 | one run lock in every mode that changes things; only status 75 means busy | `preflight`, `take_lock_or_stand_down`, `lifecycle_take_lock` in `lib/lifecycle.sh` | lock checks | S9, S14 |
| I8 | the unattended pass never calls `sudo` itself and never installs or downloads macOS updates; the interactive pass asks before the first `sudo` | `mode_auto` calls `phase_macos dry`; every `sudo` is in `phase_macos` or `consent_restart`, after the live-only return and, in `phase_macos`, after the install question | sudo-site count and order checks | the call-log check after each unattended run in the scenarios; the macOS-question scenario; S10 is the positive control |
| I9 | the LaunchAgent has `RunAtLoad` false, `LimitLoadToSessionType` Aqua, and no `KeepAlive`; none of them is a config key | `templates/launchagent.plist.template`, `render_plist` | template and rendering checks | S17 |

Also pinned: `PATH` is set once, with the system directories before the Homebrew bin, and the Homebrew bin comes only from its two standard prefixes (tripwire checks and their probes; S19 shows the order matters, using the test seam's PATH line, which keeps the same order); the two artifact allowlists and the uninstall rule that decide the `silent` group and adoption (tripwire checks, probes, and the inventory scenarios); an app replacement starts with HUP, INT and TERM ignored, so a closed window or a TERM to the window's group ends the pass but not the replacement (tripwire check, probes, and the HUP and TERM scenarios); an app whose running state cannot be read counts as running, and so does any process started from inside its bundle (tripwire checks, probes, and a scenario); an app is neither adopted nor upgraded, in any mode, while a file that is not a link sits at a path where its cask links a command, a shell completion or a man page, or where one of that path's folders should be, because Homebrew would fail that upgrade, fail again restoring the old version, and remove the app undoing that (`link_in_the_way`, checked in `load_dock_inventory`, `phase_dock_apps` and again in `upgrade_cask` right before Homebrew is called; tripwire checks, probes, and the in-the-way scenarios, whose Homebrew double removes the app the way Homebrew would; the folder case, and the rule that a link folder this account cannot write keeps an app out of `silent` (`link_folder_needs_admin`), are pinned by scenarios only); the resolved `target` field recent Homebrew prints beside each artifact is never read as an artifact kind (tripwire check, probes, and a scenario); every executable script starts with `#!/bin/bash`; every question defaults to No; and the functions that run a changing command (upgrade, adopt, quit, reopen, restart, window, notification, ledger write) start with the dry-run guard.

## Records

All in `~/Library/Logs/weekly-update/`, append-only.

| file | one line is | written by |
|---|---|---|
| `run-YYYYmmdd-HHMMSS-MODE.log` | `YYYY-MM-DD HH:MM:SS  TAG     message`, TAG one of PHASE, OK, WARN, SKIP, INFO, FAIL, ASK, NOTIFY, FAILED, ABORT, VERDICT; between those lines, untagged, the raw output of the commands it runs (`brew update`, each upgrade and adoption, the `softwareupdate` listing, `open`, and the `osascript` quit request) | `lib/report.sh`, and the runtime for the raw output |
| `history.tsv` | `time<TAB>mode<TAB>outcome<TAB>detail` | `report_verdict` and `report_history` in `lib/report.sh` |
| `nudge-ledger.tsv` | `time<TAB>app<TAB>version<TAB>attempt` or `did-not-start` | `record_nudge` |
| `apps.tsv` | `time<TAB>seen, upgraded, upgrade-failed or adopted<TAB>app<TAB>version or change` | `apps_ledger_add` |
| `launchd.log` | whatever launchd captured from a slot | launchd |

Terminal outcomes (after such a row from `run`, `auto` or `scheduled`, later slots stand down until the next slot day, including a slot the Mac slept through that runs at a wake on a later day): `completed`, `partial`, `escalated`, `declined`, `started`. Everything else, including `escalation deferred`, `battery deferred`, `slot deferred`, `stopped` and `interrupted`, lets a later slot try again.

The detail of a `completed`, `partial`, `escalated` or `escalation deferred` row from `run`, `auto` or `scheduled` carries `exit`, `version`, `reasons`, `upgraded`, `failures`, the skipped and pending lists, and the number of proposed apps. The nudge ledger counts attempts in a row that left an app at the same version; a `did-not-start` row cancels the attempt before it, and the count is a string comparison, so `1.1` and `1.10` differ.

## Decision points

- **May this app be upgraded unattended?** Confirmed in the config, managed by Homebrew, listed by `brew outdated`, group `silent`, closed (no process running from inside the bundle), bundle and folder writable, no leftover copy in the Caskroom, and no file that is not a link at any path where its cask links a command, a completion or a man page. The last two also hold for an interactive upgrade, and the link check also holds for adoption.
- **Does this pass need a person?** Any reason listed above.
- **Can a window open now?** `pmset -g assertions` reports `UserIsActive 1`.
- **Is this slot day done?** A terminal row from `run`, `auto` or `scheduled` in `history.tsv` dated on or after the slot day, the most recent day that has a slot, today included.
- **Is the installed schedule current?** The LaunchAgent on disk equals what the current config renders to (`status` and `check`, and `verify` in an installed copy). `status` and `check` use only the exit status of `launchctl print`; `verify` does not call it. The uninstaller and install read one line of its text, `program =`, to decide whether a loaded schedule is this tool's, for these labels only: the label of any other `*.weekly-update.plist` whose LaunchAgent runs this tool and carries its own file name as its Label, a weekly-update label (both); the Label key, when it is a weekly-update label, of a file that runs this tool's runtime path under another home folder (install only; the uninstaller stops on such a file without asking); install's own label, unless its install manifest names that label; and, without a manifest, the label the config names (both). For the label the install manifest names, and for an older label it names after `label_prefix` changed, both unload whatever is loaded there and move its LaunchAgent aside without reading that line; the one exception is install's read of a lookalike file's Label key, which can be the manifest's label. Apple documents that output as not an interface, so a line it cannot read leaves the owner unknown: both stop with exit status 1 and name the schedule, and `launchctl bootout gui/$(id -u)/LABEL` removes it by hand.

## Install layout

`install.sh` copies `bin/`, `lib/`, `rules/`, `templates/`, `config/` (the example), `VERSION` and `LICENSE` to `~/.local/share/weekly-update/app/`, writes the window launcher `bin/weekly-update-scheduled` (two lines: a shebang and one `exec` of the runtime in scheduled mode, because `open` cannot pass a mode to a script), renders the LaunchAgent to `~/Library/LaunchAgents/LABEL.plist`, records the LaunchAgent and the four scripts in `bin/` with their sha256 in `install-manifest.tsv` (which `verify` checks as V5; `lib/` is checked against `lib/MANIFEST.sha256`, and the other copied files are not hashed), and loads the schedule. A previous copy or LaunchAgent is moved to `replaced-DATE/`. The uninstaller first makes `removed-DATE/`, then unloads, moves the tool copy and this tool's LaunchAgents there and verifies; if it cannot make that folder it stops with exit status 1 before unloading anything. Either folder gets a `-2`, `-3` suffix when one of that name exists, so a move always lands in an empty folder of its own. With the manifest or without, it looks at every other `*.weekly-update.plist` for one whose Label is its file name and a weekly-update label, and whose program is this tool's runtime, and with no manifest and no tool folder it also asks about the loaded schedule the config names. Install looks for such agents under other labels too: it replaces one whose loaded schedule, if any, runs this tool, stops with exit status 1 when a schedule other than another program's is loaded under a lookalike's Label key (when that is a weekly-update label), or when the schedule loaded under this tool's agent names no program it can read or a lookalike, and otherwise names and leaves alone what it cannot place. It judges each file and each loaded schedule by the program it names, with the same helper copied into install.sh (the runtime path under this home folder, with a trailing slash, doubled slashes or through a symlink; a test keeps the two copies identical), and the uninstaller makes every decision before it unloads or moves anything: a file that runs another program or names no program it can read stays in place, a schedule loaded under a label that runs another program stays loaded (except at the label the install manifest names, which is unloaded whatever it runs), and a file it cannot read, a lookalike, an agent of this tool whose Label is not its file name or not a weekly-update label, or a loaded schedule whose program it cannot tell stops it with exit status 1, as does a LaunchAgent that cannot be rendered when it finds no agent of this tool. Install stops the same way at its own label unless its own manifest names that label. Both act only on a weekly-update label (ASCII letters, digits, dots and hyphens, not starting with a dot, ending in `.weekly-update`), so a hand-edited manifest cannot make them unload an agent outside that suffix. Install, uninstall and every mode that changes things refuse to run as root (exit status 2): under `sudo`, `HOME` stays the person's, and root-owned files there would stop every later run at the lock.

## The test seam

The runtime, the installer and the uninstaller each have a function, `apply_test_seams`, that reads the `WU_TEST*` variables; in the runtime, the tripwire checks that no other line does. The seam is honoured only when `WU_TEST=1`, `HOME` is inside a folder carrying the harness's marker file, and every tool the tests replace resolves to the test doubles; otherwise the script exits 2 before doing anything. With the seam on, `PATH` keeps the same order with the doubles in front. The doubles themselves refuse to run outside the harness.

The scenario tests run the real scripts against a throwaway home folder, fake apps and a fake Dock, with test doubles for `brew`, `softwareupdate`, `osascript`, `defaults`, `pmset`, `launchctl`, `open`, `sudo`, `caffeinate`, `sw_vers`, `id` and `pgrep` that record every call. Other tools (`jq`, `plutil`, `lockf`, `stat`, `du`) run for real, on sandbox files only. A few reads go past the sandbox, such as `ps`, `kill -0` and `pgrep` checks on processes the runtime or a test started itself (the `pgrep` double hands the library's keep-awake question, which children of the runtime are named `caffeinate`, to the real `pgrep`), and `uname -s` in `install.sh`. After each unattended run in the scenarios, the tests check the call log: no `sudo`, and no `softwareupdate` except `--list`. The Homebrew double also records the settings each call ran under, and several scenarios check that every Homebrew call had cleanup, autoremove, upgrade-on-install (`brew install` upgrading something already installed), hints and auto-update off and no cask options, even when the caller's environment sets `--no-binaries`. `tests/test-docs.sh` runs every README Quickstart line after the clone and the `cd` in such a sandbox, with no config file, and fails if any of them fails; the clone line itself is not tested. The same test fails when the README's Modes block and `weekly-update --help` differ, and when a config key the runtime declares is missing from `docs/CONFIG.md` or `config/weekly-update.conf.example`.

`tests/run-all.sh` runs every test file with the stock `/bin/bash`; it takes about 15 to 20 minutes under the sandbox I use for the tests, which slows process start-up, and longer on a busy Mac. `bin/weekly-update-verify` is a static regression tripwire: a denylist over the scripts plus checks that each risky command sits in one function, behind its guards, in the right order. `tests/test-gate.sh` breaks every deny rule in `rules/` and many of the structure checks on purpose, shows that the tripwire fires for each one it breaks, and fails if a deny rule has no such probe. Some structure checks have no probe. The tripwire catches the edits it was written for; it is not a proof that the scripts are safe.
