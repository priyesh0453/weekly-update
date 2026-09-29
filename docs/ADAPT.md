# Adapting weekly-update

`weekly-update` is one answer to a general question: how do you let a scheduled job change things on a machine someone is using, without it ever surprising them? This page is about reusing that answer, whether you change this tool or port it to another system.

## The five questions any port has to answer

1. **What gets updated, and who owns each item?** Here: Dock apps, each mapped to a Homebrew cask and a group (system, vendor, silent, assisted, manual). In a port: a package list, an app folder, containers, anything with a version you can read before and after.
2. **When may it run, and when must it stand down?** Here: hourly slots on one weekday, a stand-down once a pass has finished, a deferral when the index cannot be refreshed or the battery is low.
3. **What may it do with nobody watching?** Here: only upgrades of confirmed, closed, writable apps. Nothing that needs a password, a quit or a restart. Keep this list short in any port; everything else waits for a person.
4. **How does it ask?** Here: one window, a question that defaults to No and times out, then a second yes for anything that interrupts work. A question with no terminal is a no.
5. **How does it prove itself?** Here: a record of every pass written after the decision, test doubles for 12 of the system tools it drives (a few read-only tools such as `jq` and `plutil` run for real on sandbox files, and a few reads of the process table, such as `ps` and `pgrep` checks on processes the runtime or a test started, run for real), scenario tests, and a static tripwire with a probe for every deny rule and for many of its structure checks.

If a port answers all five, it is the same design in another language.

## Changing this tool

The parts most worth adapting:

| part | where | adapt it to |
|---|---|---|
| what gets updated | `load_dock_inventory` in `bin/weekly-update` | a different app list (all of `/Applications`, a file you keep), another package manager |
| when it runs | `[updater]` in the config, `templates/launchagent.plist.template` | other days and hours; systemd timers or Task Scheduler on other systems (see Cross-platform equivalents, below) |
| what it may do unattended | `mode_auto` and `upgrade_cask` | less, never more: the unattended pass is deliberately narrow |
| how it asks | `lib/prompt.sh`; every question the runtime asks defaults to No | the same rules in any language |
| how it proves itself | `tests/` (test doubles for 12 of the system tools it drives) and `bin/weekly-update-verify` | your own scenarios; the pattern ports to any shell tool |

Whatever you adapt, keep the unattended path narrower than the interactive one.

- **Different apps.** Edit `load_dock_inventory` to read another list, for example every bundle in `/Applications`. Keep the mapping rules: an automatically found match is only reported until a person confirms it in the config.
- **A different schedule.** Change `[updater]` in the config and run `./install.sh` again. Keep at least two slots, so a day has more than one chance to find someone at the machine.
- **Another package manager on macOS.** Replace every `brew` call in `bin/weekly-update` (the `brew-verb` allow rule in `rules/runtime.rules` lists each verb it uses), update that rule and the `brew-path` rule, and give the new tool its own test double in `tests/shims/`, named in `SHIMMED_TOOLS` in `bin/weekly-update`, `install.sh` and `bin/weekly-update-uninstall`.
- **Anything you change:** add or update the scenario that shows it, run `tests/run-all.sh`, and run `bin/weekly-update-verify`. If you move a risky command, move its tripwire check with it and add a probe in `tests/test-gate.sh` that proves the check still fires.
- **Do not edit `lib/`.** It is shared, vendored byte for byte, and pinned by `lib/MANIFEST.sha256`; `tests/test-manifest.sh` fails when a file in `lib/` does not match that manifest or is not listed in it. Work around it in `bin/` instead.

## Porting to another system

Start from the stages in `docs/ARCHITECTURE.md` and swap the commands; the table under Cross-platform equivalents, below, lists the usual ones for Windows and Linux. In order:

1. Write the test doubles first: one small script per system tool, recording every call to a log and answering from files. Then the rest can be built and tested without touching a real machine.
2. Build the unattended pass with the narrowest possible list of actions, and the record written after the decision.
3. Add the interactive pass behind a question that defaults to No.
4. Add the scheduler definition as a template, rendered at install, with the "run at load" and "keep alive" switches written as literals, never as config.
5. Add an uninstaller that moves things aside and verifies, rather than deleting.
6. Add a static check for the few lines that matter most, and a probe for each rule.

## Cross-platform equivalents

This tool is macOS only: it drives Homebrew casks, `softwareupdate`, the Dock and launchd. The design ports; the commands below are the usual equivalents. I have not tested any of them, so treat them as starting points, not verified instructions.

| piece | macOS (this repo) | Windows (untested) | Linux (untested) |
|---|---|---|---|
| schedule | LaunchAgent with several `StartCalendarInterval` slots | `schtasks /Create /TN weekly-update /TR "powershell -NoProfile -File C:\tools\weekly-update.ps1 auto" /SC WEEKLY /D SUN /ST 14:00 /RI 60 /DU 08:00` | a systemd user timer with `OnCalendar=Sun *-*-* 14..21:00:00` and `Persistent=true`, enabled with `systemctl --user enable --now weekly-update.timer` |
| list app updates | `brew outdated --cask --json=v2` | `winget upgrade` | `apt list --upgradable`, `dnf check-update`, `flatpak remote-ls --updates` |
| upgrade one app | `brew upgrade --cask TOKEN` | `winget upgrade --id Mozilla.Firefox --exact --silent` | `flatpak update --noninteractive org.mozilla.firefox`; system packages in the interactive pass only, with `sudo apt-get install --only-upgrade PACKAGE` |
| system updates | `softwareupdate --list` (the window installs) | leave to Windows Update; open its page with `start ms-settings:windowsupdate` | leave to the distribution's updater, or list only |
| someone at the machine | `pmset -g assertions` (UserIsActive) | the idle time from the `GetLastInputInfo` API | `loginctl show-session "$XDG_SESSION_ID" -p IdleHint` |
| battery | `pmset -g batt` | `(Get-CimInstance Win32_Battery).EstimatedChargeRemaining` | `cat /sys/class/power_supply/BAT0/capacity` |
| run lock | `lockf -s -t 0` (the library falls back to `flock -n -E 75`) | an exclusive `[System.IO.File]::Open(...)` with `FileShare.None` | `flock -n -E 75 9` |
| keep awake | `caffeinate -i -w PID` | `SetThreadExecutionState(ES_CONTINUOUS \| ES_SYSTEM_REQUIRED)` from the tool's own process (for example through PowerShell `Add-Type`), cleared with `ES_CONTINUOUS` when the pass ends | `systemd-inhibit --what=idle:sleep --why=weekly-update COMMAND` |
| notify | `osascript -e 'display notification ...'` | a toast through the `BurntToast` PowerShell module | `notify-send "weekly-update" "..."` |
| open a window | `open -a Terminal FILE` | `start powershell -NoExit -File FILE` | `x-terminal-emulator -e FILE` |

The library in `lib/` is plain bash 3.2 and should run on Linux; only its keep-awake helper is macOS-specific. When `caffeinate` is missing, that helper returns a failure status without printing anything, and the runtime reports it and carries on. A port leaves `lib/` unchanged, like any other change (see Changing this tool, above). It keeps the machine awake its own way, as in the table, so that it ends with the run. Where the platform can bind that to the runtime's process, the port starts it from `bin/` in place of the `lifecycle_keep_awake` call and stops it next to the `lifecycle_release_awake` call before the closing prompt, because that release stops only a child of the runtime named `caffeinate`. Where it cannot, the scheduler wraps the whole run instead (`systemd-inhibit ... COMMAND` on Linux), and keep-awake then lasts until the run ends.

## A prompt for any AI assistant

If you do not write code, you can still adapt this. Download the repository, open it in any AI coding assistant that can read files and run commands, and paste this:

```text
This folder is weekly-update, a reference design for a weekly updater on macOS.
Read README.md, docs/ARCHITECTURE.md and skills/weekly-update/SKILL.md first.

I want to adapt it so that: <describe what you want, in plain words>.
My computer is: <macOS, Windows or Linux, and anything special about it>.

Rules for you:
- Keep every safety rule in "What it never does" in README.md. Nothing may be
  deleted, and anything that interrupts me must ask first, defaulting to No.
- The unattended part may only do less than today, never more.
- Do not run install.sh, uninstall.sh or bin/weekly-update-uninstall
  without --dry-run, or ./bin/weekly-update with no mode or with the run,
  auto, scheduled or setup mode, on my computer. Show me the command and
  let me run it.
- You may run the read-only commands: ./bin/weekly-update check,
  ./bin/weekly-update status, ./bin/weekly-update auto --dry-run,
  ./install.sh --dry-run, ./uninstall.sh --dry-run,
  ./bin/weekly-update-uninstall --dry-run and ./bin/weekly-update-verify.
  You may also run tests/run-all.sh, which leaves throwaway test folders
  in the temp folder.
- Do not change anything in lib/.
- For every change, add or update a test in tests/ and run tests/run-all.sh.
- When you finish, list what you changed, which tests you ran, and their
  results, and tell me what you could not test.
```

Read what it proposes before you let it change anything, and run the dry runs yourself before installing.
