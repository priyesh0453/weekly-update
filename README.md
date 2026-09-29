# weekly-update

Keeps macOS and the apps in your Dock current, once a week, without surprising you.

## The 30-second pitch

Once a week, a small shell tool wakes up on your Mac. It refreshes Homebrew's index, compares the apps in your Dock that Homebrew knows with it, quietly upgrades the closed apps you said it may manage when they need nothing from you, and lists pending macOS updates.

If something needs you (a running app, a password, a restart), it waits until you are at the Mac and opens one Terminal window that asks first. Every question defaults to No. The tool itself never deletes anything, and every pass leaves a plain-text record you can read.

It is one bash script of about 2,400 lines, with a shared library of about 2,100 lines, plus an installer, an uninstaller and a static checker, all for the stock macOS bash 3.2 (the bash that ships with macOS and the one launchd runs) and nothing beyond what ships with macOS plus Homebrew.

## A reference design, not a product

Treat this repository as a worked example of how to automate something risky on a machine someone is using, then change it for your use case. The parts most worth adapting, and what to swap each one for, are listed in `docs/ADAPT.md`, together with a prompt you can paste into a coding assistant if you do not write code.

The design rule: whatever you adapt, keep the unattended path narrower than the interactive one. `docs/ARCHITECTURE.md` explains the stages, the nine invariants and the records.

## Who this is for

- **People who want their Mac kept current.** You do not need to read the code: run the quickstart, answer the questions in the window when it appears, and read the one-line notifications. If you are unsure, run `./bin/weekly-update check` first; it only reports.
- **People who automate their own machines.** The interesting parts are the safety rules and the tests: how a scheduled job decides it is safe to act, how it defers when the Mac is half awake, and how those rules are pinned by tests that never change the real system.
- **Anyone porting the idea.** Windows and Linux have the same problem. The design carries over; the commands do not (see Cross-platform notes).

## What it never does

- It never deletes an app, a file or a setting itself. Homebrew replaces the links a cask defines on each upgrade, and an assisted upgrade runs the app's own uninstall steps; `docs/LIMITATIONS.md` has the details, and invariant I1 in `docs/ARCHITECTURE.md` lists the Homebrew settings behind this rule.
- The unattended pass never quits a running app, never calls `sudo` itself, and never installs a macOS update. A running app waits for you.
- Before it installs any macOS update, the interactive pass asks you, and the question says that installing accepts Apple's license terms for those updates (the tool passes `--agree-to-license` to `softwareupdate`). No, an empty answer or no terminal installs and downloads nothing and asks for no password.
- A restart needs its own typed yes; it never restarts the Mac without one. That question defaults to No, and No means download only.
- It never acts on an app you have not confirmed. Apps it finds automatically are only reported until you confirm them with the `setup` mode (see Quickstart).
- The unattended pass never decides on stale data: a slot that cannot refresh the index defers, and a later slot that day retries. An interactive run says so, records a failure and continues on the cached index.
- Loading the schedule never starts a pass (`RunAtLoad` is false), and the schedule loads only in a logged-in desktop session.
- It never sends anything anywhere itself. The network traffic is what Homebrew and `softwareupdate` do, plus the apps' own updaters when you let the interactive pass open apps.

## Quickstart

You need macOS, [Homebrew](https://brew.sh) and `jq` (recent macOS versions ship `/usr/bin/jq`; on an older one, `brew install jq`). The first three commands after `cd` only read; `install.sh --dry-run` prints its plan and writes nothing.

<!-- quickstart:begin -->
```sh
git clone https://github.com/priyesh0453/weekly-update.git
cd weekly-update
./bin/weekly-update --version
./bin/weekly-update check
./bin/weekly-update auto --dry-run
./install.sh --dry-run
./install.sh
~/.local/share/weekly-update/app/bin/weekly-update status
```
<!-- quickstart:end -->

What you should see:

- `--version` prints `weekly-update 0.1.0`.
- `check` lists your Dock apps with their state and says the schedule is not loaded yet.
- `auto --dry-run` prints what a slot would do and ends with "Dry run finished; nothing was changed and nothing was written".
- `install.sh --dry-run` shows where install would put its files.
- `install.sh` copies the tool to `~/.local/share/weekly-update/app/`, loads the schedule (loading never starts a pass) and prints the commands to try next.
- `status` shows "No history yet" and that the LaunchAgent on disk matches the config.

`docs/sample-output.txt` shows what these six commands printed in one run against the test doubles; I captured it once, outside the tests, so it can lag behind the code. No `git`? Download the repository as a ZIP from its GitHub page, unzip it, open Terminal in that folder and start from the third line. Install puts nothing on your `PATH`.

Then, once, tell it which apps it may manage: `~/.local/share/weekly-update/app/bin/weekly-update setup` lists the apps it found, asks you to confirm each proposed match (default No), offers to register confirmed apps with Homebrew, and shows the macOS automatic-update settings. Or write the config by hand (see Config reference); until an app is confirmed, it is only reported.

## How it works

A LaunchAgent runs `weekly-update auto` once an hour in a window you choose (default Sunday 14:00 to 21:00). Slots the Mac sleeps through run as one slot at its next wake, whatever the day or hour. Most slots do nothing: once a pass has finished on or after the slot day, later slots stand down until the next slot day.

1. **Stand down or go.** A slot stands down when a pass finished or a window was opened on or after the slot day (the most recent day that has a slot, today included). If the last slot or pass today that did not stand down deferred a window because nobody was at the Mac, this slot skips the upgrade work and only retries the window.
2. **Preflight.** The same preflight guards every mode that changes things: the tools it needs, Homebrew, the battery (on battery power below 20 percent, nothing is replaced), one run lock, and keep-awake.
3. **Index.** `brew update` with a deadline. A failure or a hang defers the slot; a later slot that day retries, and when none is left the notification says so.
4. **Inventory.** Each Dock app is matched to a Homebrew cask: from your config (confirmed), or proposed from casks Homebrew already manages or a matching cask name (report-only). A failed query is a failure, never counted as matching the index.
5. **Apps.** Confirmed apps that are managed, outdated and closed, whose bundle and link folders this account can write, and whose cask has no step that needs a person (group `silent`) are upgraded.
6. **macOS.** The pending updates are listed, never installed, in the unattended pass. A listing this tool cannot read is a failure, never "current".
7. **Decision.** Nothing needs you: a "Done" notification. Something does: a "Waiting for you" notification when nobody is at the Mac (a later slot that day retries the window), or one Terminal window when someone is.
8. **The window.** It explains why it opened and asks "Run the weekly update now?" (default No, times out after four hours). Yes runs the interactive pass, which asks again before it quits an app itself, installs macOS updates, or restarts.

Every pass writes a run log and ends with exactly one outcome row in `history.tsv`, written after the decision, so the record says what really happened; `check`, `status`, `plist` and the dry runs write nothing. The records live in `~/Library/Logs/weekly-update/`, and `docs/ARCHITECTURE.md` has the full flow, the nine invariants, the record formats, the test seam, and what the static tripwire `bin/weekly-update-verify` does and does not prove.

### Modes

<!-- usage:begin -->
```text
weekly-update 0.1.0: keeps macOS and the apps in your Dock current, once a week.

Usage: weekly-update [MODE] [--dry-run]

Modes (run is the default):
  run        Interactive pass: Dock apps, then macOS. Asks before anything that needs you; every question defaults to No.
  auto       One unattended slot, the one the schedule runs. Upgrades only confirmed apps that are closed; never quits an app, never calls sudo itself, never installs macOS updates.
  scheduled  The window a slot opens when something needs you. Asks first (default No, times out), then runs the interactive pass.
  setup      One-time interactive setup: confirm proposed casks into the config, adopt confirmed apps into Homebrew, show the macOS automatic-update settings.
  check      Report only: Dock inventory, the macOS listing and the agent state. Changes nothing and writes nothing.
  status     History, pending restarts, schedule, heartbeat and whether the installed agent matches the config. Writes nothing.
  verify     Run the static regression tripwire over these files. A tripwire, not a proof.
  plist      Print the LaunchAgent that this config renders to. Writes nothing.
  help       Print this text, or help MODE for one mode.

Flags:
  --dry-run  With run or auto: print what the pass would do. No lock, no index refresh, no history row, no notification, no change.
  --version  Print the version.
  --help     Print this text; -h is the same. --help MODE describes one mode.

Exit status: 0 done or stood down, 1 partial, stopped or issues found, 2 usage, invalid config or an unusable setup, 4 needs a terminal,
129, 130 or 143 a pass stopped by a hangup, an interrupt or a terminate signal.
A dry run exits 0 even when its report lists failures; read its last lines.
Config: ~/.config/weekly-update/config (optional; see config/weekly-update.conf.example)
Logs:   ~/Library/Logs/weekly-update/
```
<!-- usage:end -->

## Config reference

The config file, `~/.config/weekly-update/config`, is optional; without it every value is a built-in default. `config/weekly-update.conf.example` is a commented copy to start from, and `docs/CONFIG.md` has the format rules and every key with its type, range, default and meaning.

The reader is strict: a typo, an unknown key or a bad value stops every mode except `help`, `--help` and `--version`, naming the file and line (exit status 2). No key lets the unattended pass quit an app, call `sudo` or install macOS updates, or makes the schedule start at load or stay alive.

A schedule on Saturday morning and one app it may manage:

```ini
[updater]
weekday = 6
first_hour = 10
last_hour = 13

[app org.mozilla.firefox]
cask = firefox
```

After an edit, `./bin/weekly-update plist` or `check` names an invalid file with its line number. After a change to `[updater]`, run `./install.sh` again; `~/.local/share/weekly-update/app/bin/weekly-update status` tells you when the installed LaunchAgent no longer matches the config.

## Cross-platform notes

This tool is macOS only: it drives Homebrew casks, `softwareupdate`, the Dock and launchd. The design ports; the commands do not. `docs/ADAPT.md` lists the usual Windows and Linux equivalents for each piece, and what a port does about keep-awake; I have not tested any of them, so treat them as starting points, not verified instructions.

## Known limitations

- **No test runs against a real system.** Every Homebrew, `softwareupdate` and `pmset` answer the tests use is a hand-written fixture. Make your first run a supervised one: `check`, then `auto --dry-run`, then a `run` you watch.
- **macOS versions.** It needs `jq`, `plutil` with its `raw` output format (macOS 12 or later) and a `lockf` that locks an open file descriptor. I have run the test suite only on a recent macOS release on Apple silicon, and only the static tripwire checks the Intel (`/usr/local`) Homebrew branch.
- **An app opened during an unattended upgrade.** The pass checks that an app is closed right before it hands it to Homebrew, but Homebrew downloads first and then replaces the bundle. An app you open in those seconds can be replaced while it runs.
- **A file where a Homebrew link goes.** A file that is not a link, where a cask puts a command-line link, a shell completion or a man page, makes Homebrew's upgrade fail, its restore of the old version fail on the same file, and the undo of that restore can remove the app (from Homebrew's source; I have not reproduced it). So this tool never adopts or upgrades such an app, in any mode, and names the file.
- **Homebrew's `brew.env` files.** A `HOMEBREW_*` line there overrides the settings this tool exports, including the cask options it clears. The tool does not read those files; check them if links go missing.
- **Background items.** If macOS lists this LaunchAgent under Allow in the Background and it is switched off there, no slot runs and nothing tells you, because the heartbeat notification comes from a slot. `status` lists the latest history rows.

`docs/LIMITATIONS.md` has the full list, including the interactive-upgrade behaviours, keep-awake timing, unusual home folder paths, install stopping part-way, and how install and the uninstaller decide what is this tool's.

## Extend this

- Port it to Windows (Task Scheduler with "run as soon as possible after a missed start", per-app `winget upgrade --id`) or Linux (a systemd timer with `Persistent=true` driving apt, dnf or flatpak). Keep the consent-in-a-window rule, the liveness rule (refresh the index or defer) and the never-delete tripwire.
- Reuse the nudge ledger anywhere you poke something you cannot verify: record each attempt with the state it saw, and stop after N attempts that changed nothing.
- Extend the inventory beyond the Dock to `/Applications` and `~/Applications`, and report Mac App Store apps read-only.
- A menu-bar plugin that reads `history.tsv` and shows the last pass, what is pending and the next slot.
- A shared override file for bundle ids whose cask cannot be found automatically.

## FAQ

**Why not `brew upgrade --greedy` on a timer?** It quits running apps without asking, it cannot tell "nothing to do" from "the query failed", and it knows nothing about macOS updates, batteries or whether you are at the Mac. Each of those is decided here before anything is replaced.

**Why did it skip my app?** The window and the summary say why:

- it was running;
- its bundle is not writable by your account (its own updater keeps it current);
- it is only proposed (found automatically): confirm it with `setup` or a `cask = TOKEN` line;
- Homebrew's record already matches the index;
- a file sits where Homebrew puts one of its links (`in-the-way(APP)` among the failures in `history.tsv`): move the file aside and rerun.

**Why did a slot defer?** Usually the Mac woke briefly without a network, so Homebrew could not refresh its index, or it was on battery below the floor, or nobody was at the Mac when a window was needed. The notification says which; later slots of the same day retry, and when none is left the notification says so.

**Does it need administrator rights?** Only for macOS updates, after you answer yes to the macOS question in an interactive pass; Homebrew may ask for the password in an interactive upgrade of an app with an installer package, a background helper or a link folder this account cannot write. The unattended pass never calls `sudo` itself. Never run the tool, `install.sh` or the uninstaller with `sudo`: they refuse to run as root, because root-owned files would stop later runs.

**Is the static check a proof that it is safe?** No. `./bin/weekly-update verify` is a regression tripwire, and I treat it as one: the tests break every deny rule and many structure checks on purpose and show that each of those fires; they cannot show that no other risky edit exists.

**How was it built?** I drafted much of the code with AI assistance. The design, the safety rules, the review and the test runs are mine. Most rules under What it never does are checked by scenario tests that run the real scripts against test doubles, never a live Homebrew or `softwareupdate`; two are pinned only by the static tripwire and its probes: that the tool itself deletes nothing, and that it sends nothing anywhere itself.

## Uninstall

```sh
./uninstall.sh
```

or, if you deleted the download, `~/.local/share/weekly-update/app/bin/weekly-update-uninstall`. Add `--dry-run` to see the plan first; `--help` lists both options.

It unloads the schedule, moves the installed copy and its LaunchAgent into `~/.local/share/weekly-update/removed-DATE/`, and checks that they are gone ("Removed and verified", exit 0). Anything it cannot unload or move is listed, with exit status 1; when it cannot tell whose an agent is, it stops before anything is unloaded or moved (`docs/LIMITATIONS.md` explains how it and install decide what is this tool's).

Kept, because nothing is deleted by the uninstaller: the log folder `~/Library/Logs/weekly-update`, your config in `~/.config/weekly-update`, and the dated `replaced-*` and `removed-*` folders under `~/.local/share/weekly-update`. Delete those three folders, and any link you made to the runtime on your `PATH`, yourself.

The same steps by hand, if you prefer: `launchctl bootout gui/$(id -u)/LABEL` (the label is the file name, without `.plist`, of the `~/Library/LaunchAgents/*.weekly-update.plist` whose program is `~/.local/share/weekly-update/app/bin/weekly-update`), then move that plist and `~/.local/share/weekly-update` wherever you like.

## License

MIT. See `LICENSE`.
