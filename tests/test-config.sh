#!/bin/bash
# test-config.sh: the config reader, the command line and the test seam's
# refusals. An invalid config must stop every mode but help and version,
# naming the file and line, before any Homebrew or macOS call.
# shellcheck source-path=SCRIPTDIR
set -u
set -o pipefail
# shellcheck source=harness.sh
. "${0%/*}/harness.sh"

printf '== invalid config stops every mode with file and line\n'
new_sandbox
basic_fixture
write_config '[updater]' 'battery_floor = 10'
run_wu auto
check_status "a floor below 20 exits 2" 2
check_out_has "the error names the line" 'config:2: battery_floor in \[updater\] must be a whole number from 20 to 100, got "10"'
testing_check "auto records the stop" stopped "$(last_outcome)"
check_file_has "the stop row names the line" "$(history_file)" 'config invalid at .*config:2'
check_file_has "auto notifies the stop" "$STATE/notifications.log" '^Stopped: the config file is invalid'
check_calls_lacks "nothing runs on an invalid config" '^(brew|softwareupdate|pmset)'
check_i8 "invalid config"
write_config '[updater]' 'first_hour = 15' 'last_hour = 15'
run_wu plist
check_status "a single slot a day exits 2" 2
check_out_has "the single slot is explained" 'last_hour must be later than first_hour'
write_config '[app com.example.thing]' 'open_as = com.example.other'
run_wu check
check_status "an app with neither cask nor group exits 2" 2
check_out_has "the empty app row is explained" 'needs cask = TOKEN or group = vendor or manual'
write_config '[app bad_name]' 'cask = x'
run_wu check
check_status "a bad bundle name exits 2" 2
write_config '[updater]' 'dependson = x'
run_wu run --dry-run
check_status "a typo exits 2 even in a dry run" 2
testing_check "a dry run writes no history even when stopped" 1 "$(history_rows)"
write_config '[app org.mozilla.firefox]' 'cask = Firefox'
run_wu check
check_status "an upper-case cask token exits 2" 2
write_config '[updater]' "label_prefix = $(printf '%200s' '' | tr ' ' a)"
run_wu plist
check_status "a label_prefix of 200 characters is accepted" 0
write_config '[updater]' "label_prefix = $(printf '%201s' '' | tr ' ' a)"
run_wu plist
check_status "a label_prefix of 201 characters exits 2" 2
check_out_has "the long label_prefix is named with its line" 'config:2: label_prefix'
for value in .bad -bad a_b; do
  write_config '[updater]' "label_prefix = $value"
  run_wu plist
  check_status "label_prefix $value exits 2" 2
  check_out_has "label_prefix $value is named with its line" 'config:2: label_prefix'
done
write_config '[updater]' 'admin_hint ='
run_wu plist
check_status "a blank admin_hint exits 2" 2
check_out_has "the blank admin_hint is named with its line" 'config:2: admin_hint'
printf '\357\273\277[updater]\n' > "$HOME_DIR/.config/weekly-update/config"
run_wu plist
check_status "a config with a byte-order mark exits 2" 2
check_out_has "the byte-order mark is named" 'byte-order mark or is UTF-16'

printf '== an invalid config stops every mode except help and version\n'
new_sandbox
basic_fixture
write_config '[updater]' 'weekdy = 0'
INTERACTIVE=1
for mode in run scheduled setup status verify plist check auto-dry-run run-dry-run; do
  case $mode in
    auto-dry-run) run_wu auto --dry-run ;;
    run-dry-run) run_wu run --dry-run ;;
    *) run_wu "$mode" ;;
  esac
  check_status "invalid config: $mode exits 2" 2
  check_out_has "invalid config: $mode names the file and line" 'config:2: unknown key weekdy in \[updater\]'
done
INTERACTIVE=0
check_calls_lacks "invalid config: nothing ran in any mode" '^(brew|softwareupdate|pmset|launchctl|open|osascript|sudo|caffeinate)'
run_wu --help
check_status "invalid config: --help exits 0" 0
run_wu help auto
check_status "invalid config: help auto exits 0" 0
run_wu --version
check_status "invalid config: --version exits 0" 0

printf '== values are literal; defaults apply without a file\n'
new_sandbox
basic_fixture
write_config '[updater]' 'admin_hint = Ask the owner of this Mac # see the notes | option two' '[app org.mozilla.firefox]' 'cask = firefox'
: > "$STATE/scenario/id/not-admin"
INTERACTIVE=1
: > "$S/answers"
run_wu run
check_out_has "a # and a | inside a value are kept" 'Ask the owner of this Mac # see the notes \| option two'
new_sandbox
basic_fixture
: > "$STATE/scenario/id/not-admin"
INTERACTIVE=1
: > "$S/answers"
run_wu run
check_out_has "the default admin hint says what is skipped and why" 'This account is not an administrator, and installing macOS updates needs one\. macOS installs are skipped this run\.'
new_sandbox
basic_fixture
mv "$HOME_DIR/.config/weekly-update/config" "$S/config.moved-by-test"
run_wu plist
check_status "no config file renders the defaults" 0
check_out_has "defaults: Sunday" '<integer>0</integer>'
testing_check "defaults: eight slots" 8 "$(grep -c '<key>Weekday</key>' "$OUT")"
mkdir -p "$STATE/scenario/id"
printf 'john_smith\n' > "$STATE/scenario/id/login"
run_wu plist
check_out_has "a login name with other characters maps them to - in the default label" '<string>local\.john-smith\.weekly-update</string>'
rm -f "$STATE/scenario/id/login"
: > "$STATE/scenario/id/login"
run_wu plist
check_out_has "no login name gives the default label local.user" '<string>local\.user\.weekly-update</string>'
rm -f "$STATE/scenario/id/login"

printf '== the command line\n'
new_sandbox
run_wu --version
check_status "--version exits 0" 0
testing_check "--version matches VERSION" "weekly-update $(cat "$REPO/VERSION")" "$(cat "$OUT")"
run_wu --help
check_status "--help exits 0" 0
run_wu help auto
check_status "help auto exits 0" 0
check_out_has "help auto describes the retry" 'retried by a later slot'
run_wu help nosuchmode
check_status "help for an unknown mode exits 2" 2
run_wu frobnicate
check_status "an unknown mode exits 2" 2
run_wu check --dry-run
check_status "--dry-run with check exits 2" 2
run_wu run extra
check_status "an extra argument exits 2" 2
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
printf '%s\n' "$S/Applications/Zed.app" > "$STATE/scenario/brew/upgrade-zed.app"
printf '0.151.0\n' > "$STATE/scenario/brew/upgrade-zed.version"
INTERACTIVE=1
answers yes yes yes
run_wu --help auto
check_status "--help auto exits 0" 0
check_out_has "--help auto describes the auto mode" '^weekly-update auto$'
run_wu -h run
check_status "-h run exits 0" 0
check_out_has "-h run describes the run mode" '^weekly-update run$'
run_wu --help plist
check_status "--help plist exits 0" 0
check_out_lacks "--help plist prints no LaunchAgent" '<plist'
run_wu --version auto
check_status "--version auto is a usage error" 2
run_wu --version plist
check_status "--version plist is a usage error" 2
check_calls_lacks "help and version with a mode word run nothing" '^(brew|osascript|open|softwareupdate|sudo|pmset|caffeinate|launchctl)'
testing_check "help and version with a mode word write no history" 0 "$(history_rows)"
testing_check "help and version with a mode word create no log folder" no "$( [ -e "$HOME_DIR/Library/Logs/weekly-update" ] && printf yes || printf no )"
INTERACTIVE=0
basic_fixture
INTERACTIVE=0
run_wu run
check_status "run without a terminal exits 4" 4
testing_check "run without a terminal writes no history" 0 "$(history_rows)"
run_wu setup
check_status "setup without a terminal exits 4" 4
run_wu scheduled
check_status "scheduled without a terminal exits 4" 4
testing_check "run, setup and scheduled without a terminal create no log folder" no "$( [ -e "$HOME_DIR/Library/Logs/weekly-update" ] && printf yes || printf no )"

printf '== the changing modes refuse to run as root; the read-only ones still work\n'
new_sandbox
basic_fixture
: > "$STATE/scenario/id/root"
run_wu auto
check_status "auto as root exits 2" 2
check_out_has "auto as root says why" 'must run as the person who uses this Mac, not as root'
testing_check "auto as root creates no log folder" no "$( [ -e "$HOME_DIR/Library/Logs/weekly-update" ] && printf yes || printf no )"
check_calls_lacks "auto as root runs nothing that changes things" '^(brew (update|upgrade|install)|osascript|open|softwareupdate|sudo|launchctl)'
INTERACTIVE=1
run_wu run
check_status "run as root exits 2, before it asks for a terminal" 2
INTERACTIVE=0
run_wu check
check_status "control: check as root still exits 0" 0

printf '== as root with an invalid config, the changing modes refuse before they write anything\n'
for mode in auto run setup scheduled; do
  new_sandbox
  basic_fixture
  write_config '[updater]' 'weekdy = 0'
  : > "$STATE/scenario/id/root"
  INTERACTIVE=1
  run_wu "$mode"
  INTERACTIVE=0
  check_status "root, invalid config: $mode exits 2" 2
  check_out_has "root, invalid config: $mode names the root refusal" 'must run as the person who uses this Mac, not as root'
  check_out_lacks "root, invalid config: $mode stops before reading the config" 'the config file is invalid'
  testing_check "root, invalid config: $mode creates no log folder" no "$( [ -e "$HOME_DIR/Library/Logs/weekly-update" ] && printf yes || printf no )"
  check_calls_lacks "root, invalid config: $mode sends no notification" '^osascript'
  check_i8 "root, invalid config: $mode"
done
new_sandbox
basic_fixture
write_config '[updater]' 'weekdy = 0'
run_wu auto
check_status "control: not root, invalid config: auto exits 2" 2
check_out_has "control: not root, invalid config: auto names the config error" 'the config file is invalid'
check_i8 "control: not root, invalid config"

printf '== status on a home folder with no log folder yet, under another language\n'
new_sandbox
basic_fixture
OUT=$S/out-status-de.txt
seam_env LC_ALL=de_DE.UTF-8 /bin/bash "$RUNTIME" status > "$OUT" 2>&1
RC=$?
check_status "fresh status exits 0" 0
check_out_has "fresh status says there is no log folder yet" 'Log folder: none yet'
check_out_has "the next slot is named in English whatever the language" 'Next unattended pass: (Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday) [0-9]{4}-'
check_out_lacks "no weekday in the person's language" 'Sonntag|Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag'
check_out_has "the hint names install.sh where it is, not beside this copy" 'Run install\.sh from the folder you downloaded to load it'
testing_check "status still creates no log folder" no "$( [ -e "$HOME_DIR/Library/Logs/weekly-update" ] && printf yes || printf no )"

printf '== a link to the runtime still finds the files beside the real one\n'
new_sandbox
basic_fixture
mkdir -p "$S/linkbin" "$S/otherbin"
ln -s "$REPO/bin/weekly-update" "$S/linkbin/weekly-update"
ln -s ../linkbin/weekly-update "$S/otherbin/wu"
RUNTIME=$S/linkbin/weekly-update
run_wu --version
check_status "through an absolute link: --version exits 0" 0
testing_check "through an absolute link: the version" "weekly-update $(cat "$REPO/VERSION")" "$(cat "$OUT")"
RUNTIME=$S/otherbin/wu
run_wu check
check_status "through a relative link to a link: check exits 0" 0
check_out_has "through a relative link to a link: the Dock was read" 'Zed +0\.150\.0'
RUNTIME=$REPO/bin/weekly-update

printf '== a runtime path with a single quote gives a hint that can be pasted\n'
new_sandbox
quoted_copy="$S/Jo's code"
mkdir -p "$quoted_copy/bin"
cp -R "$REPO/lib" "$REPO/templates" "$quoted_copy/"
cp "$REPO/bin/weekly-update" "$quoted_copy/bin/weekly-update"
RUNTIME=$quoted_copy/bin/weekly-update
run_wu --bogus
check_status "quoted path: an unknown flag exits 2" 2
hint=$(LC_ALL=C sed -n 's/^Run \(.*\) --help for the modes and flags\.$/\1/p' "$OUT")
OUT=$S/out-pasted-hint.txt
seam_env /bin/bash -c "$hint --version" > "$OUT" 2>&1
RC=$?
check_status "quoted path: the hint runs as printed" 0
check_out_has "quoted path: the hint ran the runtime" '^weekly-update [0-9]'
RUNTIME=$REPO/bin/weekly-update

printf '== HOME must be an absolute path in every script\n'
new_sandbox
basic_fixture
for script in "bin/weekly-update plist" "install.sh --dry-run" "bin/weekly-update-uninstall --dry-run" "bin/weekly-update-verify --help"; do
  OUT=$S/out-relative-home-$RANDOM.txt
  (cd "$S" && env -i HOME=home PATH=/usr/bin:/bin WU_TEST=1 WU_TEST_ROOT="$S" WU_TEST_SHIMS="$S/shims" WU_TEST_STATE="$STATE" \
    /bin/bash "$REPO/${script%% *}" "${script#* }") > "$OUT" 2>&1
  RC=$?
  name=${script%% *}
  name=${name##*/}
  check_status "relative HOME: $name exits 2" 2
  check_out_has "relative HOME: $name refuses in its own name" "^${name//./\\.}: HOME must be an absolute path"
done
testing_check "relative HOME: nothing was written under the relative home" no "$( [ -e "$S/home/.local" ] && printf yes || printf no )"
OUT=$S/out-no-home.txt
env -i PATH=/usr/bin:/bin WU_TEST=1 WU_TEST_ROOT="$S" WU_TEST_SHIMS="$S/shims" WU_TEST_STATE="$STATE" /bin/bash "$REPO/bin/weekly-update" --version > "$OUT" 2>&1
RC=$?
check_status "no HOME: --version exits 2" 2
check_out_has "no HOME: says why" '^weekly-update: HOME must be an absolute path'

printf '== an exported CDPATH never sends a relative call to another folder\n'
new_sandbox
basic_fixture
mkdir -p "$S/cdpath/bin" "$S/cdpath/lib"
for script in bin/weekly-update bin/weekly-update-verify bin/weekly-update-uninstall; do
  OUT=$S/out-cdpath-$RANDOM.txt
  seam_env CDPATH="$S/cdpath" /bin/bash -c "cd \"\$1\" && /bin/bash \"\$2\" --help" cdpath "$REPO" "$script" > "$OUT" 2>&1
  RC=$?
  check_status "CDPATH set: $script --help exits 0" 0
done

printf '== a name without a slash, run from the folder that holds the script\n'
new_sandbox
basic_fixture
for script in weekly-update weekly-update-verify weekly-update-uninstall; do
  OUT=$S/out-noslash-$RANDOM.txt
  seam_env /bin/bash -c "cd \"\$1/bin\" && /bin/bash \"\$2\" --help" noslash "$REPO" "$script" > "$OUT" 2>&1
  RC=$?
  check_status "no slash: $script --help exits 0" 0
done
OUT=$S/out-noslash-check.txt
seam_env /bin/bash -c "cd \"\$1/bin\" && /bin/bash weekly-update check" noslash "$REPO" > "$OUT" 2>&1
RC=$?
check_status "no slash: weekly-update check exits 0" 0
check_out_has "no slash: check found lib/ and read the Dock" 'Zed +0\.150\.0'

printf '== the test seam refuses anything outside a sandbox\n'
new_sandbox
basic_fixture
OUT=$S/out-seam.txt
env -i HOME="$S/../" PATH=/usr/bin:/bin WU_TEST=1 WU_TEST_ROOT="$S" WU_TEST_SHIMS="$S/shims" WU_TEST_STATE="$STATE" /bin/bash "$REPO/bin/weekly-update" check > "$OUT" 2>&1
RC=$?
check_status "HOME outside the sandbox: exit 2" 2
check_out_has "HOME outside the sandbox: says so" 'outside a sandbox'
mv "$S/.weekly-update-test-root" "$S/marker.moved-by-test"
run_wu check
check_status "no sandbox marker: exit 2" 2
run_script "$REPO/install.sh" --dry-run
check_status "no sandbox marker: install.sh exits 2" 2
check_out_has "no sandbox marker: install.sh refuses in its own name" 'install\.sh: test seams requested outside a sandbox'
run_script "$REPO/bin/weekly-update-uninstall" --dry-run
check_status "no sandbox marker: the uninstaller exits 2" 2
check_out_has "no sandbox marker: the uninstaller refuses in its own name" 'weekly-update-uninstall: test seams requested outside a sandbox'
check_calls_lacks "no sandbox marker: nothing ran" '.'
mv "$S/marker.moved-by-test" "$S/.weekly-update-test-root"
for script in install.sh bin/weekly-update-uninstall; do
  OUT=$S/out-seam-home-$RANDOM.txt
  env -i HOME="$S/../" PATH=/usr/bin:/bin WU_TEST=1 WU_TEST_ROOT="$S" WU_TEST_SHIMS="$S/shims" WU_TEST_STATE="$STATE" /bin/bash "$REPO/$script" --dry-run > "$OUT" 2>&1
  RC=$?
  check_status "HOME outside the sandbox: $script exits 2" 2
  check_out_has "HOME outside the sandbox: $script refuses in its own name" "${script##*/}: test seams requested outside a sandbox"
done
check_calls_lacks "HOME outside the sandbox: nothing ran" '.'
mv "$S/shims/pmset" "$S/pmset.moved-by-test"
run_wu check
check_status "a missing shim: exit 2" 2
check_out_has "a missing shim is named" 'pmset resolves to /usr/bin/pmset, not to the shim directory'
check_calls_lacks "a refused seam runs nothing" '.'
run_script "$REPO/install.sh" --dry-run
check_status "install.sh refuses a missing shim too" 2
run_script "$REPO/bin/weekly-update-uninstall" --dry-run
check_status "the uninstaller refuses a missing shim too" 2
mv "$S/pmset.moved-by-test" "$S/shims/pmset"
OUT=$S/out-seam2.txt
env -i HOME="$HOME_DIR" PATH=/usr/bin:/bin WU_TEST=2 WU_TEST_ROOT="$S" WU_TEST_SHIMS="$S/shims" /bin/bash "$REPO/bin/weekly-update" check > "$OUT" 2>&1
RC=$?
check_status "WU_TEST other than 1: exit 2" 2
OUT=$S/out-seam3.txt
env -i HOME="$HOME_DIR" PATH=/usr/bin:/bin "$S/shims/brew" --version > "$OUT" 2>&1
RC=$?
check_status "a shim outside the harness refuses to run" 97

testing_verdict
