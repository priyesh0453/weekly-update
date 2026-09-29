# harness.sh: sourced by the scenario tests. It builds a throwaway sandbox (a
# temp HOME, fake apps, a Dock, and the test doubles in tests/shims) and runs
# the real scripts against it through their test seam. Nothing here touches
# the real Homebrew, softwareupdate, launchd, Dock or apps. Sandboxes are left
# in the temp folder for the OS to clean, so a failure can be inspected.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2034 # REPO, RC and the sandbox paths are read by the test files

case ${BASH_SOURCE[0]} in
  */*) TESTS_DIR=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P) ;;
  *) TESTS_DIR=$(pwd -P) ;;
esac
REPO=${TESTS_DIR%/*}
RUNTIME=$REPO/bin/weekly-update
VERIFY=$REPO/bin/weekly-update-verify
unset _UTIL_SH_LOADED _GATE_SH_LOADED _TESTING_SH_LOADED
# shellcheck source=../lib/testing.sh
. "$REPO/lib/testing.sh"
testing_init || exit 1

S=""
HOME_DIR=""
STATE=""
RC=0
OUT=""
INTERACTIVE=0
TTY_FILE=""

new_sandbox() {
  S=$(mktemp -d "${TMPDIR:-/tmp}/wu-test.XXXXXX") || { printf 'harness: mktemp failed\n' >&2; exit 1; }
  S=$(cd "$S" && pwd -P)
  : > "$S/.weekly-update-test-root"
  HOME_DIR=$S/home
  STATE=$S/state
  mkdir -p "$HOME_DIR/Library/Preferences" "$HOME_DIR/Library/LaunchAgents" "$HOME_DIR/.config/weekly-update" \
    "$STATE/scenario/brew" "$STATE/scenario/softwareupdate" "$STATE/scenario/sudo" "$STATE/scenario/osascript" \
    "$STATE/scenario/pmset" "$STATE/scenario/open" "$STATE/scenario/defaults" "$STATE/scenario/id" \
    "$STATE/running" "$STATE/launchd" "$STATE/brew-cache/api" "$STATE/caskroom" \
    "$S/Applications" "$S/shims" "$S/brewbin" "$S/tmp"
  cp "$TESTS_DIR"/shims/* "$S/shims/"
  chmod 755 "$S"/shims/*
  : > "$STATE/calls.log"
  : > "$STATE/brew-env.log"
  : > "$STATE/notifications.log"
  : > "$S/answers"
  RUNTIME=$REPO/bin/weekly-update
  INTERACTIVE=0
  TTY_FILE=""
}

# make_app NAME BUNDLE_ID VERSION: an app bundle with an Info.plist.
make_app() {
  local dir="$S/Applications/$1.app"
  mkdir -p "$dir/Contents/MacOS"
  cat > "$dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$2</string>
	<key>CFBundleShortVersionString</key>
	<string>$3</string>
</dict>
</plist>
EOF
}

url_path() {
  printf 'file://%s/' "$(printf '%s' "$1" | sed 's/ /%20/g')"
}

# write_dock NAME:BUNDLE_ID ...: the Dock lists these apps from the sandbox.
write_dock() {
  local entry name bundle
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n\t<key>persistent-apps</key>\n\t<array>\n'
    for entry in "$@"; do
      name=${entry%%:*}
      bundle=${entry#*:}
      printf '\t\t<dict>\n\t\t\t<key>tile-data</key>\n\t\t\t<dict>\n'
      printf '\t\t\t\t<key>bundle-identifier</key>\n\t\t\t\t<string>%s</string>\n' "$bundle"
      printf '\t\t\t\t<key>file-data</key>\n\t\t\t\t<dict>\n\t\t\t\t\t<key>_CFURLString</key>\n'
      printf '\t\t\t\t\t<string>%s</string>\n\t\t\t\t</dict>\n\t\t\t</dict>\n' "$(url_path "$S/Applications/$name.app")"
      printf '\t\t\t<key>tile-type</key>\n\t\t\t<string>file-tile</string>\n\t\t</dict>\n'
    done
    printf '\t</array>\n</dict>\n</plist>\n'
  } > "$HOME_DIR/Library/Preferences/com.apple.dock.plist"
}

# cask_info TOKEN INDEX_VERSION APP_FILE INSTALLED [UNINSTALL_JSON]
# [EXTRA_ARTIFACTS]: what brew info answers for the cask; an empty INSTALLED
# means Homebrew does not manage it.
cask_info() {
  local installed=null uninstall=${5:-'[{"quit":"x"}]'} extra=${6:-}
  [ -z "$4" ] || installed="\"$4\""
  printf '{"casks":[{"token":"%s","version":"%s","installed":%s,"auto_updates":true,"artifacts":[{"uninstall":%s},{"app":["%s"]}%s,{"zap":[{"trash":["~/Library/Caches/x"]}]}]}]}\n' \
    "$1" "$2" "$installed" "$uninstall" "$3" "${extra:+,$extra}" > "$STATE/scenario/brew/info-$1.json"
}

# set_outdated TOKEN...: brew outdated names these casks.
set_outdated() {
  local token list=""
  for token in "$@"; do
    list="${list:+$list,}{\"name\":\"$token\",\"installed_versions\":[\"1\"],\"current_version\":\"2\"}"
  done
  printf '{"formulae":[],"casks":[%s]}\n' "$list" > "$STATE/scenario/brew/outdated.json"
}

set_installed_casks() {
  printf '%s\n' "$1" > "$STATE/scenario/brew/installed.json"
}

write_config() {
  printf '%s\n' "$@" > "$HOME_DIR/.config/weekly-update/config"
}

set_active() { printf '%s\n' "$1" > "$STATE/scenario/pmset/active"; }
set_battery() { printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t%s%%; discharging; 2:00 remaining present: true\n" "$1" > "$STATE/scenario/pmset/batt"; }
set_ac() { printf "Now drawing from 'AC Power'\n" > "$STATE/scenario/pmset/batt"; }
set_running() { : > "$STATE/running/$1"; }
set_listing() { printf '%s\n' "$@" > "$STATE/scenario/softwareupdate/list.txt"; }
answers() { printf '%s\n' "$@" > "$S/answers"; }

# The baseline most scenarios start from: three example apps, all confirmed in
# the config and managed by Homebrew, all matching their index, plus Safari,
# which macOS updates; macOS current, on AC power, nobody at the Mac.
basic_fixture() {
  make_app Firefox org.mozilla.firefox 130.0
  make_app Zed dev.zed.Zed 0.150.0
  make_app "Visual Studio Code" com.microsoft.VSCode 1.93.0
  make_app Safari com.apple.Safari 18.0
  write_dock Firefox:org.mozilla.firefox Zed:dev.zed.Zed "Visual Studio Code:com.microsoft.VSCode" Safari:com.apple.Safari
  cask_info firefox 130.0 Firefox.app 130.0
  cask_info zed 0.150.0 Zed.app 0.150.0
  cask_info visual-studio-code 1.93.0 "Visual Studio Code.app" 1.93.0
  write_config '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed' '[app com.microsoft.VSCode]' 'cask = visual-studio-code'
  set_ac
  set_active 0
}

seam_env() {
  env -i HOME="$HOME_DIR" USER=tester LOGNAME=tester TMPDIR="$S/tmp/" LANG="${SEAM_LANG:-C}" PATH=/usr/bin:/bin \
    WU_TEST=1 WU_TEST_ROOT="$S" WU_TEST_SHIMS="$S/shims" WU_TEST_STATE="$STATE" WU_TEST_BREW_BIN="$S/brewbin" \
    WU_TEST_TTY="${TTY_FILE:-$S/answers}" WU_TEST_INTERACTIVE="$INTERACTIVE" WU_TEST_APPLICATIONS="$S/Applications" WU_TEST_FAST=1 \
    "$@"
}

# run_wu ARGS...: runs the runtime; output in $OUT (a file), status in $RC.
run_wu() {
  OUT=$S/out-$RANDOM.txt
  seam_env /bin/bash "$RUNTIME" "$@" > "$OUT" 2>&1
  RC=$?
}

# run_wu_within SECONDS ARGS...: run_wu with a deadline, for a scenario whose
# regression would loop instead of failing. A run still going at the deadline
# gets KILL on the process group it was started in, and RC is 124; groups the
# runtime created under its own deadline wrapper are not reached by that kill.
run_wu_within() {
  local limit=$1 ticks=0 group
  shift
  OUT=$S/out-$RANDOM.txt
  set -m
  seam_env /bin/bash "$RUNTIME" "$@" > "$OUT" 2>&1 &
  group=$!
  set +m
  while kill -0 "$group" 2>/dev/null && [ "$ticks" -lt $((limit * 5)) ]; do
    sleep 0.2
    ticks=$((ticks + 1))
  done
  if kill -0 "$group" 2>/dev/null; then
    kill -KILL -- "-$group" 2>/dev/null
    wait "$group" 2>/dev/null
    RC=124
    printf 'harness: still running after %s seconds, so it was killed\n' "$limit" >> "$OUT"
    return 0
  fi
  wait "$group"
  RC=$?
}

run_script() {
  OUT=$S/out-$RANDOM.txt
  seam_env /bin/bash "$@" > "$OUT" 2>&1
  RC=$?
}

history_file() { printf '%s' "$HOME_DIR/Library/Logs/weekly-update/history.tsv"; }
last_outcome() { awk -F'\t' 'END { print $3 }' "$(history_file)" 2>/dev/null; }
last_detail() { awk -F'\t' 'END { print $4 }' "$(history_file)" 2>/dev/null; }
history_rows() { if [ -f "$(history_file)" ]; then wc -l < "$(history_file)" | tr -d ' '; else printf '0'; fi; }

# check_status LABEL EXPECTED: the last run's exit status.
check_status() {
  testing_check "$1" "$2" "$RC" || { printf '      output tail:\n'; tail -n 15 "$OUT" | sed 's/^/        /'; }
}

check_file_has() {
  if LC_ALL=C grep -q -E -e "$3" "$2" 2>/dev/null; then testing_check "$1" found found; else testing_check "$1" found "missing /$3/ in ${2##*/}"; fi
}

check_file_lacks() {
  local hit
  hit=$(LC_ALL=C grep -m 1 -E -e "$3" "$2" 2>/dev/null)
  testing_check "$1" "" "$hit"
}

check_calls_has() { check_file_has "$1" "$STATE/calls.log" "$2"; }
check_calls_lacks() { check_file_lacks "$1" "$STATE/calls.log" "$2"; }
check_out_has() { check_file_has "$1" "$OUT" "$2"; }
check_out_lacks() { check_file_lacks "$1" "$OUT" "$2"; }

# Invariant I8: after an unattended leg, no sudo ran, softwareupdate only
# listed, and no test double logged an unexpected call.
check_i8() {
  check_calls_lacks "$1: I8 no sudo in the unattended pass" '^sudo'
  check_calls_lacks "$1: I8 softwareupdate only lists" '^softwareupdate (-[^-]|--[^l])'
  check_calls_lacks "$1: no unexpected command" '^UNEXPECTED'
}

reset_calls() {
  : > "$STATE/calls.log"
  : > "$STATE/brew-env.log"
  : > "$STATE/notifications.log"
}

# Every Homebrew call since the last reset ran with cleanup, autoremove,
# upgrade-on-install (brew install upgrading something already installed),
# hints and auto-update off, and with no cask options from the caller's
# environment (the brew double writes brew-env.log).
check_brew_env() {
  local bad
  bad=$(LC_ALL=C grep -v -x -E -e '.* \| cleanup=1 autoremove=1 install-upgrade=1 env-hints=1 auto-update=1 cask-opts=unset' "$STATE/brew-env.log" 2>/dev/null | head -n 1)
  testing_check "$1: every Homebrew call ran with the update-only settings" "" "$bad"
  testing_check "$1: Homebrew was called" yes "$( [ -s "$STATE/brew-env.log" ] && printf yes || printf no )"
}

# install_into_sandbox: runs install.sh through the seam, so later runs use the
# installed copy under the sandbox HOME, window launcher included.
install_into_sandbox() {
  run_script "$REPO/install.sh"
  RUNTIME=$HOME_DIR/.local/share/weekly-update/app/bin/weekly-update
}

# A signal ignored when a shell starts stays ignored in everything it runs, and
# a test started in the background by a shell without job control starts with
# SIGINT ignored, so a scenario that sends an interrupt checks first that one
# can arrive.
interrupts_arrive() {
  local probe ticks=0
  set -m
  sleep 30 &
  probe=$!
  set +m
  kill -INT "$probe" 2>/dev/null
  while kill -0 "$probe" 2>/dev/null && [ "$ticks" -lt 10 ]; do
    sleep 0.2
    ticks=$((ticks + 1))
  done
  if kill -0 "$probe" 2>/dev/null; then
    kill -TERM "$probe" 2>/dev/null
    wait "$probe" 2>/dev/null
    return 1
  fi
  wait "$probe" 2>/dev/null
  return 0
}

today_weekday() { date '+%w'; }
other_weekday() { printf '%s' $(( ($(date '+%w') + 3) % 7 )); }
