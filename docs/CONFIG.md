# Config reference

The config file is `~/.config/weekly-update/config`. It is optional: without it, every value below is its default. `config/weekly-update.conf.example` is a commented copy you can start from: `mkdir -p ~/.config/weekly-update`, then copy it there as `config`.

## Format

- A line whose first non-blank character is `#` is a comment.
- `[updater]` opens the settings section, at most once. `[app BUNDLE_ID]` opens one section per app, named by its bundle id (ASCII letters, digits, dots and hyphens, starting with a letter or digit); the same id twice is an error. Find a bundle id with `osascript -e 'id of app "Firefox"'`.
- `key = value`. The value is the rest of the line after the first `=`, trimmed; quotes are kept, and `#`, `|` and `=` inside a value are part of it.
- The reader is strict. A typo, an unknown key, a bad value, a second `[updater]` section, an `[app]` section with neither `cask` nor `group`, or a `last_hour` that is not later than `first_hour` stops every mode except `help`, `--help` and `--version`, with the file name and line number and exit status 2. Nothing runs on a half-read config.
- There is no key that lets the unattended pass quit an app, call `sudo` or install macOS updates, or that makes the schedule start at load or stay alive. An unknown key is rejected like any other.

## `[updater]`

| key | type and range | default | meaning |
|---|---|---|---|
| `label_prefix` | text of ASCII letters, digits, dots and hyphens, starting with a letter or digit, at most 200 characters | `local.<login name>`, with any other byte of the login name turned into `-` (`local.user` when no login name can be read) | the LaunchAgent label is `<label_prefix>.weekly-update` |
| `weekday` | integer, 0 to 6 | 0 (Sunday) | the day the slots run |
| `first_hour` | integer, 0 to 23 | 14 | the first slot of the day; one slot per hour from here to `last_hour` |
| `last_hour` | integer, 0 to 23, later than `first_hour` | 21 | the last slot of the day, so a day has at least two slots |
| `minute` | integer, 0 to 59 | 0 | the minute of each slot |
| `battery_floor` | integer, 20 to 100 | 20 | on battery power below this percentage, nothing is replaced |
| `quit_wait` | integer, 10 to 600 (seconds) | 120 | how long an app gets to quit its own way in an interactive pass |
| `entry_wait` | integer, 60 to 86400 (seconds) | 14400 | how long the window a slot opens waits for your answer |
| `nudge_give_up` | integer, 1 to 10 | 2 | attempts that left the version unchanged before opening an app is retired for that app |
| `index_timeout` | integer, 5 to 3600 (seconds) | 300 | the deadline for the index refresh (`brew update`); past it, the slot defers |
| `query_timeout` | integer, 5 to 3600 (seconds) | 120 | the deadline for each Homebrew query |
| `list_timeout` | integer, 5 to 3600 (seconds) | 300 | the deadline for the macOS update listing |
| `slow_warn` | integer, 60 to 86400 (seconds) | 1800 | a warning every this many seconds during an upgrade or adoption, which have no deadline because stopping one part-way is the unsafe way to fail |
| `final_prompt_timeout` | integer, 10 to 3600 (seconds) | 600 | how long the "Press Return to close" prompt waits after a window pass |
| `heartbeat_days` | integer, 2 to 60 | 8 | warn when no pass has finished for this many days |
| `admin_hint` | text, not blank | This account is not an administrator, and installing macOS updates needs one. macOS installs are skipped this run. | what the tool tells you when this account is not an administrator; say how rights are granted on your Mac |

## `[app BUNDLE_ID]`

Every app section needs `cask` or `group`. A `cask` line confirms the app: the tool may upgrade it, and the unattended pass may do so when the app is closed, its bundle and link folders are writable by your account, and its cask has no step that needs a person (group `silent`). Without a `group` line, the tool derives the group (`system`, `silent` or `assisted`, or `manual` when the cask's app name is not the bundle's or the cask entry could not be read) from the app and its cask. Apps found automatically are only reported until a section confirms them, by hand or through `weekly-update setup`.

| key | type and range | default | meaning |
|---|---|---|---|
| `cask` | a cask token: lowercase letters, digits, `@`, `.`, `_`, `+` and `-`, starting with a letter or digit | none | the Homebrew cask that manages the app; this confirms it |
| `group` | `vendor` or `manual` | none (derived) | `vendor`: its maker updates it in the background; `manual`: you update it from inside the app; either way the tool never upgrades it and only warns when it is behind |
| `also_matches` | bundle ids separated by spaces | none | other bundle ids a Dock tile may carry for this app |
| `open_as` | a bundle id | the section's bundle id | the bundle id to open and quit, when it differs from the Dock tile |
| `open_warning` | text | none | printed before the tool opens this app so its own updater fetches |
| `version_drop_leading` | integer, 0 to 3 | 0 | drop this many leading version parts before comparing, for apps whose bundle version carries a prefix the index does not; any other shape compares as unordered |

## A worked example

Every key in use, with values you can change and check. I rendered it with `./bin/weekly-update plist` before publishing it.

```ini
[updater]
weekday = 6
first_hour = 10
last_hour = 13
minute = 30
battery_floor = 30
heartbeat_days = 10
admin_hint = Ask an administrator of this Mac to run the macOS update.

[app org.mozilla.firefox]
cask = firefox

[app com.example.Editor]
cask = example-editor
also_matches = com.example.Editor-beta
open_as = com.example.EditorLauncher
open_warning = The editor fetches its own update a few seconds after it opens; leave it open until it says so.
version_drop_leading = 1

[app com.google.Chrome]
group = vendor

[app us.zoom.xos]
group = manual
```

What it says: four slots on Saturday, at 10:30, 11:30, 12:30 and 13:30; nothing is replaced on battery below 30 percent; a warning after 10 days without a finished pass; one app confirmed by its cask; a second app confirmed by a cask (the token is a placeholder), whose Dock tile may also carry the `-beta` id, which is opened and quit through a launcher id, with a note printed before it is opened and one leading version part dropped before its version is compared; and two apps left to their own updaters.

## Checking a config

`./bin/weekly-update plist` renders the LaunchAgent the config produces and writes nothing; `./bin/weekly-update check` reads the config and reports. An invalid file is named with its line number, and the mode exits 2. Both errors below come from one file with `first_hour = 21`, `last_hour = 21` and an `[app]` section that only sets `also_matches`:

```text
~/.config/weekly-update/config:3: last_hour must be later than first_hour, so there are at least two slots a day
~/.config/weekly-update/config:5: [app com.example.X] needs cask = TOKEN or group = vendor or manual
weekly-update: the config file is invalid, so nothing runs: ~/.config/weekly-update/config:3: last_hour must be later than first_hour, so there are at least two slots a day
```

After a change to `[updater]`, run `./install.sh` again so the loaded schedule matches the file; `./bin/weekly-update status` says when it does not.
