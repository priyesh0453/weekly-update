#!/bin/bash
# install.sh: installs weekly-update for this account and loads its schedule.
# It writes only these: a copy of the tool under
# ~/.local/share/weekly-update/app, one LaunchAgent file in
# ~/Library/LaunchAgents, and the log folder ~/Library/Logs/weekly-update. A
# previous copy or LaunchAgent is moved aside into a dated folder, never
# deleted. --dry-run prints the plan and writes nothing. Run ./uninstall.sh to
# undo.
# shellcheck source-path=SCRIPTDIR
set -u
set -o pipefail
set -o noclobber
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
case ${HOME:-} in
  /*) ;;
  *)
    printf '%s: HOME must be an absolute path\n' "${0##*/}" >&2
    exit 2
    ;;
esac

SHIMMED_TOOLS="softwareupdate osascript defaults pmset launchctl open sudo caffeinate sw_vers id pgrep brew"

# Nothing outside this function reads WU_TEST*. The sandbox rules are the
# runtime's.
apply_test_seams() {
  local tool found home_real root_real
  [ -n "${WU_TEST:-}" ] || return 0
  if [ "$WU_TEST" != 1 ] || [ -z "${WU_TEST_ROOT:-}" ] || [ ! -f "$WU_TEST_ROOT/.weekly-update-test-root" ]; then
    printf 'install.sh: test seams requested outside a sandbox\n' >&2
    exit 2
  fi
  home_real=$(cd "$HOME" 2>/dev/null && pwd -P)
  root_real=$(cd "$WU_TEST_ROOT" 2>/dev/null && pwd -P)
  case $home_real/ in
    "$root_real"/?*) ;;
    *)
      printf 'install.sh: test seams requested outside a sandbox (HOME is not under the test root)\n' >&2
      exit 2
      ;;
  esac
  if [ -z "${WU_TEST_SHIMS:-}" ] || [ ! -d "$WU_TEST_SHIMS" ]; then
    printf 'install.sh: test seams need WU_TEST_SHIMS\n' >&2
    exit 2
  fi
  export PATH="$WU_TEST_SHIMS:/usr/bin:/bin:/usr/sbin:/sbin"
  for tool in $SHIMMED_TOOLS; do
    found=$(command -v "$tool" 2>/dev/null)
    if [ "$found" != "$WU_TEST_SHIMS/$tool" ]; then
      printf 'install.sh: test seams refused: %s resolves to %s, not to the shim directory\n' "$tool" "${found:-nothing}" >&2
      exit 2
    fi
  done
  return 0
}

apply_test_seams

case $0 in
  */*) SRC=$(CDPATH='' cd -P -- "${0%/*}" 2>/dev/null && pwd -P) ;;
  *) SRC=$(pwd -P) ;;
esac
unset _UTIL_SH_LOADED _TERM_SH_LOADED _REPORT_SH_LOADED _LIFECYCLE_SH_LOADED
REPORT_RUN_LOG=""
REPORT_HISTORY_FILE=""
REPORT_MODE=install
LIFECYCLE_INTERRUPT_HINT="Rerun ./install.sh. Nothing was deleted: anything moved aside is under ~/.local/share/weekly-update."
LIFECYCLE_ABORT_HOOK=""
# shellcheck source=lib/util.sh
. "$SRC/lib/util.sh" || exit 2
# shellcheck source=lib/report.sh
. "$SRC/lib/report.sh" || exit 2
# shellcheck source=lib/term.sh
. "$SRC/lib/term.sh" || exit 2
# shellcheck source=lib/lifecycle.sh
. "$SRC/lib/lifecycle.sh" || exit 2

# A trailing slash would put "//" into the paths install writes, and the
# tripwire compares the window launcher byte for byte.
while :; do
  case $HOME in
    ?*/) HOME=${HOME%/} ;;
    *) break ;;
  esac
done
export HOME
TOOL_HOME=$HOME/.local/share/weekly-update
APP=$TOOL_HOME/app
RUNTIME_SUFFIX=/.local/share/weekly-update/app/bin/weekly-update
HOME_FLAT=$(printf '%s' "$HOME" | sed 's#//*#/#g')
HOME_REAL=$(CDPATH='' cd -P -- "$HOME" 2>/dev/null && pwd -P)
# A program is this tool's runtime when its home part is this home folder,
# with doubled slashes or through a symlink: a LaunchAgent written while HOME
# was spelled that way records the runtime under that spelling.
is_our_program() {
  local program prefix
  program=$(printf '%s' "$1" | sed 's#//*#/#g')
  case $program in
    *"$RUNTIME_SUFFIX") prefix=${program%"$RUNTIME_SUFFIX"} ;;
    *) return 1 ;;
  esac
  [ -n "$prefix" ] || prefix=/
  case $prefix in
    /*) ;;
    *) return 1 ;;
  esac
  [ "$prefix" = "$HOME_FLAT" ] && return 0
  [ -n "$HOME_REAL" ] && [ "$(CDPATH='' cd -P -- "$prefix" 2>/dev/null && pwd -P)" = "$HOME_REAL" ]
}
# The owner is ours, unread, lookalike or other. A lookalike is this tool's
# runtime path under a home folder that cannot be matched to this one, such as
# a renamed one, so it may still be this tool's.
program_owner() {
  if is_our_program "$1"; then
    printf 'ours'
  elif [ -z "$1" ]; then
    printf 'unread'
  else
    case $(printf '%s' "$1" | sed 's#//*#/#g') in
      *"$RUNTIME_SUFFIX") printf 'lookalike' ;;
      *) printf 'other' ;;
    esac
  fi
}
LOG_DIR=$HOME/Library/Logs/weekly-update
LAUNCH_AGENTS=$HOME/Library/LaunchAgents
STAMP=$(date '+%Y%m%d-%H%M%S')
ASIDE=""
# A folder of its own for this run, made with mkdir so it cannot already hold
# an earlier run's files, even one that started in the same second.
fresh_folder() {
  local base=$1 n=1
  FRESH=$base
  until mkdir -- "$FRESH" 2>/dev/null; do
    [ -e "$FRESH" ] || [ -L "$FRESH" ] || return 1
    n=$((n + 1))
    FRESH=$base-$n
  done
}
# The plan must create nothing, so this only predicts the name fresh_folder
# would pick now.
free_name() {
  local base=$1 n=1
  FRESH=$base
  while [ -e "$FRESH" ] || [ -L "$FRESH" ]; do
    n=$((n + 1))
    FRESH=$base-$n
  done
}
ensure_aside() {
  [ -z "$ASIDE" ] || return 0
  fresh_folder "$TOOL_HOME/replaced-$STAMP" || fail_install "Could not create a folder under $TOOL_HOME for the previous files"
  ASIDE=$FRESH
}
DRY_RUN=0
UNLOADED=""
PLACED=""

for argument in "$@"; do
  case $argument in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf 'Usage: ./install.sh [--dry-run] [--help]\n'
      printf 'Copies weekly-update to ~/.local/share/weekly-update/app, renders its LaunchAgent from\n'
      printf 'templates/launchagent.plist.template and loads it.\n'
      printf '  --dry-run  print the plan, including what a reinstall unloads and moves aside; write nothing\n'
      printf '  --help     print this text (-h is the same)\n'
      exit 0
      ;;
    *)
      printf 'install.sh: unknown argument %s (see --help)\n' "$argument" >&2
      exit 2
      ;;
  esac
done

# Under sudo, HOME stays the person's, so the copy, the log folder and the run
# lock would become root's, and every slot and every later install would stop.
if [ "$(id -u)" = 0 ]; then
  printf 'install.sh: run it as the person who uses this Mac, not as root. Run it again without sudo.\n' >&2
  exit 2
fi

fail_install() {
  report_failure "$1"
  if [ -n "$PLACED" ] && plutil -lint "$PLIST" >/dev/null 2>&1; then
    printf '\n  Installed only in part: the new copy is at %s, but no schedule is loaded until you rerun ./install.sh or log in again. Rerun ./install.sh.\n' "$APP"
  elif [ -n "$PLACED" ]; then
    printf '\n  Installed only in part: the new copy is at %s, but no schedule is loaded until you rerun ./install.sh. Rerun ./install.sh.\n' "$APP"
  else
    printf '\n  Not installed.\n'
  fi
  if [ -d "$ASIDE" ]; then
    printf '  Nothing was deleted; anything moved aside is in %s\n' "$ASIDE"
  else
    printf '  Nothing was deleted, and nothing was moved aside.\n'
  fi
  if [ -n "$UNLOADED" ]; then
    printf '  The previous schedule was unloaded and is not loaded now:%s. Rerun ./install.sh to load the schedule your config names.\n' "$UNLOADED"
  fi
  printf '\n'
  exit 1
}

plist_value() {
  printf '%s\n' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null
}

# %q under the C locale writes $'\ooo' escapes, so the launcher stays ASCII
# whatever locale install runs in.
render_shim() {
  local LC_ALL=C
  printf '#!/bin/bash\nexec %q scheduled\n' "$1/bin/weekly-update"
}

# Only labels with this suffix are acted on, so a hand-edited manifest cannot
# make install unload an agent outside it.
label_is_ours() {
  case $1 in
    .*|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-]*) return 1 ;;
    ?*.weekly-update) return 0 ;;
  esac
  return 1
}

term_banner "WEEKLY UPDATE  .  install" "copies the tool, renders the LaunchAgent, loads the schedule"

for required in bin/weekly-update bin/weekly-update-verify bin/weekly-update-uninstall lib/MANIFEST.sha256 \
  templates/launchagent.plist.template rules/runtime.rules VERSION; do
  [ -e "$SRC/$required" ] || { report_failure "$SRC/$required is missing; download the whole folder again"; exit 1; }
done
if [ "$(uname -s)" != Darwin ]; then
  report_failure "This tool drives macOS Software Update, Homebrew casks and launchd; it runs on macOS only"
  exit 1
fi
# Without these every scheduled slot would stop at its preflight, so install
# refuses now instead. The runtime looks in the same two Homebrew prefixes, but
# puts only one on its PATH, the first that has brew, so jq is looked for there.
if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
  report_failure "Homebrew was not found in either standard prefix. Get it from brew.sh, then rerun ./install.sh"
  exit 1
fi
if [ -x /opt/homebrew/bin/brew ]; then
  RUNTIME_BREW_BIN=/opt/homebrew/bin
elif [ -x /usr/local/bin/brew ]; then
  RUNTIME_BREW_BIN=/usr/local/bin
else
  RUNTIME_BREW_BIN=""
fi
if ! command -v jq >/dev/null 2>&1 && { [ -z "$RUNTIME_BREW_BIN" ] || [ ! -x "$RUNTIME_BREW_BIN/jq" ]; }; then
  report_failure "jq was not found in the system folders${RUNTIME_BREW_BIN:+ or in $RUNTIME_BREW_BIN}, where the tool looks for it; recent macOS versions ship /usr/bin/jq, and on an older one install it with that Homebrew first"
  exit 1
fi
if ! (cd "$SRC/lib" && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1); then
  report_failure "lib/ does not match lib/MANIFEST.sha256; download the folder again"
  exit 1
fi
report_success "Source folder complete, lib/ matches its manifest"

if ! RENDERED=$(/bin/bash "$SRC/bin/weekly-update" plist); then
  report_failure "The LaunchAgent could not be rendered (the lines above say why, and name the config line when the config is the cause); nothing was installed"
  exit 2
fi
if ! printf '%s\n' "$RENDERED" | plutil -lint - >/dev/null 2>&1; then
  report_failure "The rendered LaunchAgent does not lint; nothing was installed"
  exit 1
fi
if [ "$(plist_value "$RENDERED" RunAtLoad)" != false ] || [ "$(plist_value "$RENDERED" LimitLoadToSessionType)" != Aqua ] || plist_value "$RENDERED" KeepAlive >/dev/null; then
  report_failure "The rendered LaunchAgent could not be confirmed to have RunAtLoad false, LimitLoadToSessionType Aqua and no KeepAlive: the template was changed, or this plutil lacks the raw output format that macOS 12 added"
  exit 1
fi
LABEL=$(plist_value "$RENDERED" Label)
if ! label_is_ours "$LABEL"; then
  report_failure "The rendered label \"$LABEL\" does not end in .weekly-update; the template was changed"
  exit 1
fi
PLIST=$LAUNCH_AGENTS/$LABEL.plist
USER_ID=$(id -u)
report_success "LaunchAgent rendered and linted: $LABEL, $(plist_value "$RENDERED" StartCalendarInterval) slot(s) a week, RunAtLoad false, Aqua sessions only"

report_detail "Tool copy:   $APP"
report_detail "LaunchAgent: $PLIST"
report_detail "Logs:        $LOG_DIR"
report_detail "Config:      $HOME/.config/weekly-update/config (optional, never written by install)"

MANIFEST_LABEL=""
if [ -f "$APP/install-manifest.tsv" ]; then
  MANIFEST_LABEL=$(LC_ALL=C awk -F'\t' '$1 == "label" { print $2; exit }' "$APP/install-manifest.tsv")
fi
OLD_LABEL=$MANIFEST_LABEL
if [ -n "$OLD_LABEL" ] && ! label_is_ours "$OLD_LABEL"; then
  report_warning "The previous install manifest names \"$OLD_LABEL\", which is not a weekly-update label, so it is not unloaded or moved"
  OLD_LABEL=""
fi
[ "$OLD_LABEL" != "$LABEL" ] || OLD_LABEL=""

# The label suffix is a common name, so an agent already at this label, on
# disk or loaded, is unloaded or moved only when it runs this tool, or when
# this tool's own install manifest names the label: a reinstall then replaces
# the LaunchAgent this tool wrote there, whatever it runs now.
if [ "$MANIFEST_LABEL" != "$LABEL" ]; then
  if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
    if [ ! -r "$PLIST" ] || ! plutil -lint "$PLIST" >/dev/null 2>&1; then
      report_failure "$PLIST cannot be read, so it is not known whether it belongs to this tool, and install stopped before touching it. Check that file, or set another label_prefix in the config"
      exit 1
    fi
    existing_program=$(plutil -extract ProgramArguments.0 raw -o - "$PLIST" 2>/dev/null)
    case $(program_owner "$existing_program") in
      ours) ;;
      unread)
        report_failure "$PLIST names no ProgramArguments install can read, so it is not known whether it belongs to this tool, and install stopped before unloading or moving it. Check that file, or set another label_prefix in the config"
        exit 1
        ;;
      lookalike)
        report_failure "$PLIST runs $existing_program, this tool's runtime path under another home folder, so it is not known whether it belongs to this tool, and install stopped before unloading or moving it. If it is this tool's, move it aside yourself; otherwise set another label_prefix in the config"
        exit 1
        ;;
      *)
        report_failure "$PLIST runs $existing_program, not this tool, so install stopped before unloading or moving it. Set another label_prefix in the config, or move that agent yourself"
        exit 1
        ;;
    esac
  fi
  if existing_info=$(launchctl print "gui/$USER_ID/$LABEL" 2>/dev/null); then
    existing_program=$(printf '%s\n' "$existing_info" | sed -n 's/^[[:space:]]*program = //p' | head -n 1)
    case $(program_owner "$existing_program") in
      ours) ;;
      unread)
        report_failure "A schedule named $LABEL is loaded, but launchctl names no program for it that install can read, so it is not known whether it belongs to this tool, and install stopped before unloading it. Set another label_prefix in the config, or unload that schedule yourself"
        exit 1
        ;;
      lookalike)
        report_failure "A schedule named $LABEL is loaded and runs $existing_program, this tool's runtime path under another home folder, so it is not known whether it belongs to this tool, and install stopped before unloading it. If it is this tool's, unload it yourself; otherwise set another label_prefix in the config"
        exit 1
        ;;
      *)
        report_failure "A schedule named $LABEL is loaded and runs $existing_program, not this tool, so install stopped before unloading it. Set another label_prefix in the config, or unload that schedule yourself"
        exit 1
        ;;
    esac
  fi
fi

# Another label's LaunchAgent that runs this tool, such as the one left behind
# when the tool folder was removed by hand and label_prefix then changed,
# would keep its schedule loaded beside the new one, so it is replaced too.
EXTRA_LABELS=""
EXTRA_BOOT=""
for found_plist in "$LAUNCH_AGENTS"/*.weekly-update.plist; do
  [ -e "$found_plist" ] || [ -L "$found_plist" ] || continue
  [ "$found_plist" != "$PLIST" ] || continue
  [ -z "$OLD_LABEL" ] || [ "$found_plist" != "$LAUNCH_AGENTS/$OLD_LABEL.plist" ] || continue
  if [ ! -r "$found_plist" ] || ! plutil -lint "$found_plist" >/dev/null 2>&1; then
    report_warning "$found_plist cannot be read, so it is not known whether it belongs to this tool; it was left alone"
    continue
  fi
  found_program=$(plutil -extract ProgramArguments.0 raw -o - "$found_plist" 2>/dev/null)
  found_label=$(plutil -extract Label raw -o - "$found_plist" 2>/dev/null)
  case $(program_owner "$found_program") in
    ours) ;;
    lookalike)
      # Loaded, it may be this tool's own schedule under an older spelling of
      # HOME, which would keep running beside the new one.
      if label_is_ours "$found_label" && found_info=$(launchctl print "gui/$USER_ID/$found_label" 2>/dev/null) \
        && [ "$(program_owner "$(printf '%s\n' "$found_info" | sed -n 's/^[[:space:]]*program = //p' | head -n 1)")" != other ]; then
        report_failure "$found_plist runs $found_program, this tool's runtime path under another home folder, and its schedule $found_label is loaded, so it is not known whether it belongs to this tool, and install stopped before unloading or moving anything. Unload and move it yourself if it is this tool's"
        exit 1
      fi
      report_warning "$found_plist runs $found_program, this tool's runtime path under another home folder, so it was left alone; unload and move it by hand if it is this tool's"
      continue
      ;;
    unread)
      report_warning "$found_plist names no ProgramArguments install can read, so it was left alone"
      continue
      ;;
    *) continue ;;
  esac
  found_name=${found_plist##*/}
  if [ "$found_label" != "${found_name%.plist}" ] || ! label_is_ours "$found_label"; then
    report_warning "$found_plist runs this tool but does not carry its own file name as a weekly-update label, so it was left alone"
    continue
  fi
  # A LaunchAgent is moved only when nothing stays loaded under its label that
  # a later uninstall would need that file to find.
  if found_info=$(launchctl print "gui/$USER_ID/$found_label" 2>/dev/null); then
    found_program=$(printf '%s\n' "$found_info" | sed -n 's/^[[:space:]]*program = //p' | head -n 1)
    case $(program_owner "$found_program") in
      ours) EXTRA_BOOT="$EXTRA_BOOT $found_label" ;;
      unread)
        report_failure "The schedule $found_label is loaded, but launchctl names no program for it that install can read, so it is not known whether it belongs to this tool, and install stopped before unloading or moving anything. Unload it yourself if it is this tool's"
        exit 1
        ;;
      lookalike)
        report_failure "The schedule $found_label is loaded and runs $found_program, this tool's runtime path under another home folder, so it is not known whether it belongs to this tool, and install stopped before unloading or moving anything. Unload it yourself if it is this tool's"
        exit 1
        ;;
      *)
        report_warning "The schedule $found_label is loaded but runs $found_program, not this tool, so that schedule and this tool's LaunchAgent at $found_plist were left alone"
        continue
        ;;
    esac
  fi
  EXTRA_LABELS="$EXTRA_LABELS $found_label"
done

if [ "$DRY_RUN" = 1 ]; then
  free_name "$TOOL_HOME/replaced-$STAMP"
  ASIDE=$FRESH
  for label in "$LABEL" "$OLD_LABEL"; do
    [ -n "$label" ] || continue
    if launchctl print "gui/$USER_ID/$label" >/dev/null 2>&1; then
      report_detail "Would unload the loaded schedule $label first"
    fi
  done
  if [ -e "$APP" ] || [ -L "$APP" ]; then report_detail "Would move the previous copy to $ASIDE/app"; fi
  for old_plist in "$PLIST" "${OLD_LABEL:+$LAUNCH_AGENTS/$OLD_LABEL.plist}"; do
    [ -n "$old_plist" ] || continue
    [ -e "$old_plist" ] || [ -L "$old_plist" ] || continue
    report_detail "Would move the previous LaunchAgent $old_plist to $ASIDE/"
  done
  # Every label passed label_is_ours, so it holds no blank or pattern character.
  for label in $EXTRA_BOOT; do
    report_detail "Would unload $label, another label's schedule that runs this tool"
  done
  for label in $EXTRA_LABELS; do
    report_detail "Would move $LAUNCH_AGENTS/$label.plist, another label's LaunchAgent that runs this tool, to $ASIDE/"
  done
  printf '\n  Dry run: nothing was written and nothing was loaded.\n\n'
  exit 0
fi

# Install records no verdict, so only the signal traps stay: the exit trap
# would turn a finished install into a failure. An interrupt from here on
# prints the hint above.
lifecycle_install_traps
trap - EXIT
mkdir -p "$LOG_DIR" "$TOOL_HOME" "$LAUNCH_AGENTS" || fail_install "Could not create the folders above"
[ -w "$LAUNCH_AGENTS" ] || fail_install "Cannot write $LAUNCH_AGENTS, where the LaunchAgent goes"
lifecycle_take_lock "$LOG_DIR/run.lock"
if [ "$?" -eq 75 ]; then
  report_failure "A weekly-update pass is running right now; rerun ./install.sh when it finishes"
  exit 1
fi

fresh_folder "$TOOL_HOME/staging-$STAMP" || fail_install "Could not create a staging folder under $TOOL_HOME"
STAGE=$FRESH
for part in bin lib rules templates config VERSION LICENSE; do
  if [ -e "$SRC/$part" ]; then
    cp -R "$SRC/$part" "$STAGE/" || fail_install "Could not copy $part into $STAGE"
  fi
done
render_shim "$APP" >> "$STAGE/bin/weekly-update-scheduled" || fail_install "Could not write the window launcher"
chmod 755 "$STAGE/bin/weekly-update" "$STAGE/bin/weekly-update-verify" "$STAGE/bin/weekly-update-uninstall" "$STAGE/bin/weekly-update-scheduled" || fail_install "Could not mark the scripts executable"

for label in "$LABEL" "$OLD_LABEL"; do
  [ -n "$label" ] || continue
  if launchctl print "gui/$USER_ID/$label" >/dev/null 2>&1; then
    launchctl bootout "gui/$USER_ID/$label" >/dev/null 2>&1 || fail_install "Could not unload the running schedule $label"
    UNLOADED="$UNLOADED $label"
    report_detail "Unloaded the previous schedule $label"
  fi
done
for label in $EXTRA_BOOT; do
  launchctl bootout "gui/$USER_ID/$label" >/dev/null 2>&1 || fail_install "Could not unload the schedule $label"
  UNLOADED="$UNLOADED $label"
  report_detail "Unloaded $label, another label's schedule that runs this tool"
done
if [ -e "$APP" ] || [ -L "$APP" ]; then
  ensure_aside
  mv "$APP" "$ASIDE/app" || fail_install "Could not move the previous copy aside"
  report_detail "Previous copy moved to $ASIDE/app"
fi
for old_plist in "$PLIST" "${OLD_LABEL:+$LAUNCH_AGENTS/$OLD_LABEL.plist}"; do
  [ -n "$old_plist" ] || continue
  [ -e "$old_plist" ] || [ -L "$old_plist" ] || continue
  ensure_aside
  mv "$old_plist" "$ASIDE/" || fail_install "Could not move $old_plist aside"
  report_detail "Previous LaunchAgent moved to $ASIDE/"
done
for label in $EXTRA_LABELS; do
  old_plist=$LAUNCH_AGENTS/$label.plist
  ensure_aside
  mv "$old_plist" "$ASIDE/" || fail_install "Could not move $old_plist aside"
  report_detail "The LaunchAgent of $label, which ran this tool, moved to $ASIDE/"
done
mv "$STAGE" "$APP" || fail_install "Could not move the new copy into place"
PLACED=1
printf '%s\n' "$RENDERED" > "$PLIST" || fail_install "Could not write $PLIST"
plutil -lint "$PLIST" >/dev/null 2>&1 || fail_install "$PLIST does not lint"
report_success "Installed the tool copy and the LaunchAgent"

{
  printf 'label\t%s\n' "$LABEL"
  printf 'version\t%s\n' "$(cat "$APP/VERSION")"
  printf 'installed\t%s\n' "$STAMP"
  for file in "$PLIST" "$APP/bin/weekly-update" "$APP/bin/weekly-update-verify" "$APP/bin/weekly-update-uninstall" "$APP/bin/weekly-update-scheduled"; do
    printf 'file\t%s\t%s\n' "$file" "$(shasum -a 256 "$file" | cut -d ' ' -f 1)"
  done
} >> "$APP/install-manifest.tsv" || fail_install "Could not write the install manifest"

launchctl enable "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || report_warning "launchctl enable reported an error; weekly-update status shows whether the schedule is loaded"
if ! launchctl bootstrap "gui/$USER_ID" "$PLIST" >/dev/null 2>&1; then
  fail_install "launchctl could not load $PLIST"
fi
if launchctl print "gui/$USER_ID/$LABEL" >/dev/null 2>&1; then
  report_success "Schedule loaded: $LABEL. Loading it never starts a pass; the first one runs at the next slot"
else
  fail_install "The schedule does not show as loaded after bootstrap"
fi

printf '\n  Installed weekly-update %s.\n' "$(cat "$APP/VERSION")"
(
  LC_ALL=C
  printf '  Try it:     %q check\n' "$APP/bin/weekly-update"
  printf '  Status:     %q status\n' "$APP/bin/weekly-update"
  printf '  Tripwire:   %q verify\n' "$APP/bin/weekly-update"
  printf '  Remove it:  %q\n\n' "$APP/bin/weekly-update-uninstall"
)
exit 0
