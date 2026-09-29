#!/bin/bash
# test-interactive.sh: scenarios for the interactive passes, S7, S8, S10-S13
# and S18 (run leg), plus the window's entry question, the macOS install
# question, the measured sudo forecast, the refusals inside an upgrade, and an
# upgrade that outlives a closed window.
# shellcheck source-path=SCRIPTDIR
set -u
set -o pipefail
# shellcheck source=harness.sh
. "${0%/*}/harness.sh"

restart_listing() {
  set_listing 'Software Update Tool' '' 'Finding available software' 'Software Update found the following new or updated software:' \
    '* Label: macOS Example 15.2-24C101' \
    '	Title: macOS Example 15.2, Version: 15.2, Size: 3000000KiB, Recommended: YES, Action: restart, '
}

printf '== S7 an unwritable bundle is never quit or upgraded (I4)\n'
new_sandbox
basic_fixture
set_outdated firefox
cask_info firefox 131.0 Firefox.app 130.0
set_running org.mozilla.firefox
chmod 555 "$S/Applications/Firefox.app"
INTERACTIVE=1
answers yes yes
run_wu run
check_status "S7 exit 0" 0
check_out_has "S7 the inventory demotes it from silent" 'Firefox +130\.0 +131\.0 +older +assisted'
check_out_has "S7 SKIP line names the reason" 'Firefox is not writable by this account'
check_calls_lacks "S7 no quit" 'to quit'
check_calls_lacks "S7 no upgrade" '^brew upgrade'
check_file_has "S7 recorded as left to its own updater" "$(history_file)" 'unwritable=\[Firefox\]'
chmod 755 "$S/Applications/Firefox.app"

printf '== S8 an upgrade that leaves the version unchanged is not counted\n'
new_sandbox
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
printf 'unchanged\n' > "$STATE/scenario/brew/upgrade-zed"
INTERACTIVE=1
answers yes
run_wu run
check_status "S8 exit 0" 0
check_calls_has "S8 the upgrade ran" '^brew upgrade --cask zed'
check_out_has "S8 unchanged WARN" 'Zed unchanged at 0\.150\.0'
check_file_has "S8 not counted as upgraded" "$(history_file)" 'upgraded=0 '

printf '== the interactive upgrade quits a running app only with a yes, then reopens it\n'
new_sandbox
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
printf '%s\n' "$S/Applications/Zed.app" > "$STATE/scenario/brew/upgrade-zed.app"
printf '0.151.0\n' > "$STATE/scenario/brew/upgrade-zed.version"
set_running dev.zed.Zed
INTERACTIVE=1
answers yes no
run_wu run
check_calls_lacks "a no leaves the running app alone" 'to quit|^brew upgrade'
check_file_has "a no is recorded as skipped" "$(history_file)" 'running-skipped=\[Zed\]'
reset_calls
answers yes yes
run_wu run
check_status "a yes: exit 0" 0
check_calls_has "a yes asks the app to quit its own way" 'tell application id "dev.zed.Zed" to quit'
check_calls_has "a yes upgrades it" '^brew upgrade --cask zed NO_UPGRADE_QUIT_CASKS=unset$'
check_calls_has "a yes reopens it" '^open -b dev.zed.Zed$'
check_out_has "the new version is read back from the bundle" 'Zed upgraded 0\.150\.0 to 0\.151\.0'

printf '== the window asks first and a no changes nothing\n'
new_sandbox
basic_fixture
INTERACTIVE=1
answers no
run_wu scheduled
check_status "window no: exit 0" 0
check_out_has "the window says the pass asks again before it quits an app itself" 'asks again before it quits an app itself'
testing_check "window no: declined" declined "$(last_outcome)"
check_calls_lacks "window no: nothing ran" '^(brew|softwareupdate|sudo|caffeinate)'
: > "$S/answers"
run_wu scheduled
testing_check "window without an answer: declined" declined "$(last_outcome)"
check_file_has "window without an answer: says why" "$(history_file)" 'answer=no-answer'

# window_group ANSWER: starts a window pass in its own process group, reading
# its answers from a FIFO on file descriptor 7; the group is in WINDOW_GROUP.
window_group() {
  INTERACTIVE=1
  mkfifo "$S/tty"
  exec 7<>"$S/tty"
  TTY_FILE=$S/tty
  OUT=$S/out-window-closed.txt
  set -m
  seam_env /bin/bash "$RUNTIME" scheduled > "$OUT" 2>&1 &
  WINDOW_GROUP=$!
  set +m
  [ -z "$1" ] || printf '%s\n' "$1" >&7
}

# wait_for_output PATTERN: waits up to 60 seconds for PATTERN in $OUT.
wait_for_output() {
  local waited=0
  until LC_ALL=C grep -q -E -e "$1" "$OUT" 2>/dev/null || [ "$waited" -ge 300 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
}

# wait_for_row_after PREVIOUS: waits up to 60 seconds for a last row other
# than PREVIOUS. The job leader is the seam_env subshell, which the signal
# ends at once, so the pass's own row is what shows it has finished.
wait_for_row_after() {
  local waited=0
  until [ "$(last_outcome)" != "$1" ] || [ "$waited" -ge 300 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
}

printf '== closing the window at its question declines and changes nothing\n'
new_sandbox
basic_fixture
window_group ""
wait_for_output 'Run the weekly update now'
check_out_has "window closed at the question: the question was asked" 'Run the weekly update now'
kill -HUP -- "-$WINDOW_GROUP" 2>/dev/null
wait "$WINDOW_GROUP" 2>/dev/null
wait_for_row_after ""
exec 7>&-
TTY_FILE=""
INTERACTIVE=0
testing_check "window closed at the question: declined" declined "$(last_outcome)"
check_file_has "window closed at the question: exit 0, and says why" "$(history_file)" 'declined[[:space:]]exit=0 .*window closed before an answer'
check_calls_lacks "window closed at the question: nothing ran" '^(brew|softwareupdate|sudo)'

printf '== closing the window at its closing prompt keeps the pass row\n'
new_sandbox
basic_fixture
write_config '[updater]' 'final_prompt_timeout = 60' '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed'
window_group yes
wait_for_output 'Press Return to close'
check_out_has "window closed at the closing prompt: the pass reached it" 'Press Return to close'
kill -HUP -- "-$WINDOW_GROUP" 2>/dev/null
wait "$WINDOW_GROUP" 2>/dev/null
wait_for_row_after started
exec 7>&-
TTY_FILE=""
INTERACTIVE=0
testing_check "window closed at the closing prompt: the pass row is the last row" completed "$(last_outcome)"
testing_check "window closed at the closing prompt: exit 0, closed by the window" yes "$(tail -n 1 "$(history_file)" | LC_ALL=C grep -E -e 'completed[[:space:]]exit=0 .*closed=window$' >/dev/null && printf yes || printf no)"
check_file_lacks "window closed at the closing prompt: no interrupted row" "$(history_file)" 'interrupted'

printf '== S10 the restart question: no means download only; yes records the request first (I3)\n'
new_sandbox
basic_fixture
restart_listing
INTERACTIVE=1
answers yes yes no
run_wu scheduled
check_status "S10 no-to-restart exit 0" 0
check_calls_has "S10 no-to-restart downloads" '^sudo softwareupdate --download macOS Example 15\.2-24C101 --agree-to-license$'
check_calls_lacks "S10 no-to-restart installs nothing" 'softwareupdate --install'
check_file_lacks "S10 no restart request on record" "$(history_file)" 'restart-requested'
check_file_has "S10 the window pass is on record" "$(history_file)" '	scheduled	started	'
testing_check "S10 the window pass ends completed" completed "$(last_outcome)"
reset_calls
answers yes yes yes
run_wu scheduled
check_calls_has "S10 yes-to-restart installs with --restart" '^sudo softwareupdate --install macOS Example 15\.2-24C101 --restart --agree-to-license$'
check_calls_has "S10 the request was on record before the install ran" '^softwareupdate --install .* restart-rows-before-call=1$'
check_file_has "S10 restart-requested row" "$(history_file)" '	restart-requested	macOS Example 15\.2-24C101$'
check_calls_has "S10 positive control: the I8 check can see a sudo install" '^sudo softwareupdate --install'

printf '== S11 a pre-release item stops every macOS install\n'
new_sandbox
basic_fixture
set_listing 'Software Update Tool' '' 'Software Update found the following new or updated software:' \
  '* Label: macOS Example 16.0 beta 2-25A5' \
  '	Title: macOS Example 16.0 beta 2, Version: 16.0, Size: 9000KiB, Recommended: YES, Action: restart, '
INTERACTIVE=1
answers yes yes
run_wu run
check_status "S11 exit 1 (partial)" 1
check_calls_lacks "S11 no install" 'softwareupdate --(install|download)'
check_calls_lacks "S11 no sudo" '^sudo'
check_file_has "S11 tagged" "$(history_file)" 'macos\(pre-release-listed\)'

printf '== S12 the listing parser: Recommended, major, pending, empty Version\n'
new_sandbox
basic_fixture
set_listing 'Software Update Tool' '' 'Finding available software' 'Software Update found the following new or updated software:' \
  '* Label: Command Line Tools for Xcode-16.0' \
  '	Title: Command Line Tools for Xcode, Version: 16.0, Size: 751793KiB, Recommended: YES, ' \
  '* Label: Example Tool-1.0' \
  '	Title: Example Tool, Version: 1.0, Size: 1024KiB, Recommended: NO, ' \
  '* Label: Mystery Update-' \
  '	Title: Mystery Update, Version: , Size: 2048KiB, Recommended: YES, Action: restart, '
printf '0\n' > "$STATE/scenario/sudo/n.status"
INTERACTIVE=1
answers yes no
run_wu run
check_status "S12 exit 0" 0
check_out_has "S12 the tools item is not major" 'Command Line Tools for Xcode +16\.0 +restart:0 minor'
check_calls_has "S12 the recommended item is installed" '^sudo softwareupdate --install Command Line Tools for Xcode-16\.0 --agree-to-license$'
check_calls_lacks "S12 a Recommended NO item is left alone" 'Example Tool'
check_out_has "S12 the empty Version keeps the restart column" 'Mystery Update +- +restart:1 minor'
check_calls_has "S12 the restart item was asked about and only downloaded" '^sudo softwareupdate --download Mystery Update- --agree-to-license$'
check_file_has "S12 pending keeps the restart item" "$(history_file)" 'macos-pending=\[Mystery Update\]'
check_file_lacks "S12 pending drops the installed item" "$(history_file)" 'macos-pending=\[[^]]*Command Line Tools'
check_out_has "S12 the password forecast is measured" 'sudo remembers the password'
new_sandbox
basic_fixture
set_listing 'Software Update Tool' '' 'Software Update found the following new or updated software:' \
  '* Label: macOS Example 16.1-25B1' \
  '	Title: macOS Example 16.1, Version: 16.1, Size: 9000KiB, Recommended: YES, Action: restart, '
INTERACTIVE=1
answers yes no
run_wu run
check_out_has "S12 a newer macOS major is labelled major" 'macOS Example 16\.1 +16\.1 +restart:1 major'
check_out_has "S12 without cached sudo the forecast says so" 'sudo does not remember the password'

printf '== a macOS item that shuts the Mac down gets its own question, like a restart\n'
new_sandbox
basic_fixture
set_listing 'Software Update Tool' '' 'Software Update found the following new or updated software:' \
  '* Label: Example Firmware-1.0' \
  '	Title: Example Firmware, Version: 1.0, Size: 2048KiB, Recommended: YES, Action: shut down, '
INTERACTIVE=1
answers yes no
run_wu run
check_status "shut down: exit 0" 0
check_out_has "shut down: listed as such" 'Example Firmware +1\.0 +restart:shut-down minor'
check_out_has "shut down: the person is told it shuts the Mac down" 'Apple lists "Example Firmware" as shutting the Mac down'
check_out_has "shut down: asked on its own" 'Install "Example Firmware" and restart now\?'
check_calls_lacks "shut down: never installed without its own yes" '^sudo softwareupdate --install Example Firmware-1\.0'
check_calls_has "shut down: a no downloads only" '^sudo softwareupdate --download Example Firmware-1\.0 --agree-to-license$'

printf '== S13 the nudge retires after attempts that do not move the version\n'
new_sandbox
basic_fixture
cask_info zed 0.151.0 Zed.app 0.151.0
mkdir -p "$HOME_DIR/Library/Logs/weekly-update"
ledger=$HOME_DIR/Library/Logs/weekly-update/nudge-ledger.tsv
printf '2000-01-02 10:00:00\tZed\t0.150.0\tattempt\n2000-01-09 10:00:00\tZed\t0.150.0\tattempt\n2000-01-16 10:00:00\tZed\t0.150.0\tattempt\n2000-01-16 10:00:05\tZed\t0.150.0\tdid-not-start\n' > "$ledger"
INTERACTIVE=1
answers yes
run_wu run
check_status "S13 exit 0" 0
check_out_has "S13 retired" 'Zed is not opened any more'
check_calls_lacks "S13 no open" '^open -b dev\.zed\.Zed'
printf '2000-01-02 10:00:00\tZed\t0.150.0\tattempt\n2000-01-09 10:00:00\tZed\t0.150.0\tattempt\n2000-01-09 10:00:05\tZed\t0.150.0\tdid-not-start\n' > "$ledger"
reset_calls
run_wu run
check_calls_has "S13 a did-not-start row does not count, so it is opened again" '^open -b dev\.zed\.Zed$'
testing_check "S13 the new attempt is in the ledger" 1 "$(awk -F'\t' '$1 ~ /^20/ && $4 == "attempt"' "$ledger" | awk 'END { print NR - 2 }')"
printf '2000-01-02 10:00:00\tZed\t0.150.0\tattempt\n' > "$ledger"
: > "$STATE/scenario/open/no-start-dev.zed.Zed"
mv "$STATE/running/dev.zed.Zed" "$STATE/running/.was-dev.zed.Zed" 2>/dev/null
reset_calls
run_wu run
check_out_has "S13 a launch that failed is reported" 'Zed did not start'
testing_check "S13 a launch that failed is marked" did-not-start "$(awk -F'\t' 'END { print $4 }' "$ledger")"

printf '== open_warning is printed before the tool opens the app so its updater fetches\n'
new_sandbox
basic_fixture
cask_info zed 0.151.0 Zed.app 0.151.0
write_config '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed' 'open_warning = Opening it restores every tab' \
  '[app com.microsoft.VSCode]' 'cask = visual-studio-code'
INTERACTIVE=1
answers yes
run_wu run
check_status "open_warning: exit 0" 0
check_out_has "open_warning: printed with the app's name" 'Zed: Opening it restores every tab'
check_calls_has "open_warning: the app was opened" '^open -b dev\.zed\.Zed$'

printf '== the macOS step asks before the administrator password; no, an empty line or no answer runs no sudo\n'
new_sandbox
basic_fixture
set_listing 'Software Update Tool' '' 'Software Update found the following new or updated software:' \
  '* Label: Command Line Tools for Xcode-16.0' \
  '	Title: Command Line Tools for Xcode, Version: 16.0, Size: 751793KiB, Recommended: YES, ' \
  '* Label: macOS Example 15.2-24C101' \
  '	Title: macOS Example 15.2, Version: 15.2, Size: 3000000KiB, Recommended: YES, Action: restart, '
INTERACTIVE=1
answers no
run_wu run
check_status "macOS no: exit 0" 0
check_out_has "the question names the password and the license terms" "Install the 2 recommended macOS update\\(s\\) listed above\\? This needs the administrator password and accepts Apple's license terms"
check_calls_lacks "macOS no: no sudo at all" '^sudo'
check_calls_lacks "macOS no: nothing installed or downloaded" 'softwareupdate --(install|download)'
check_file_has "macOS no: both items stay pending" "$(history_file)" 'macos-pending=\[Command Line Tools for Xcode; macOS Example 15\.2\]'
reset_calls
answers ''
run_wu run
check_calls_lacks "macOS empty line: no sudo" '^sudo'
reset_calls
: > "$S/answers"
run_wu run
check_calls_lacks "macOS without an answer: no sudo" '^sudo'
reset_calls
answers yes no
run_wu scheduled
check_status "window yes, macOS no: exit 0" 0
check_calls_lacks "window yes, macOS no: no sudo" '^sudo'
testing_check "window yes, macOS no: two questions were asked" 2 "$(cat "$HOME_DIR"/Library/Logs/weekly-update/run-*-scheduled.log | LC_ALL=C grep -c ' ASK ')"
reset_calls
answers yes yes
run_wu run
check_calls_has "macOS yes: sudo only after the question" '^sudo -v$'
check_calls_has "macOS yes: the no-restart item is installed" '^sudo softwareupdate --install Command Line Tools for Xcode-16\.0 --agree-to-license$'
check_calls_has "macOS yes, restart yes: the restart item installs with --restart" '^sudo softwareupdate --install macOS Example 15\.2-24C101 --restart --agree-to-license$'

printf '== an app that will not quit is left running and unchanged\n'
new_sandbox
basic_fixture
write_config '[updater]' 'quit_wait = 10' '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed'
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
set_running dev.zed.Zed
: > "$STATE/scenario/osascript/stuck-dev.zed.Zed"
INTERACTIVE=1
answers yes yes
run_wu run
check_status "stuck app: exit 0" 0
check_calls_has "stuck app: it was asked to quit" 'tell application id "dev.zed.Zed" to quit'
check_out_has "stuck app: the give-up is reported" 'Zed did not quit within 10 seconds; left running and unchanged'
check_calls_lacks "stuck app: no upgrade" '^brew upgrade'
check_file_has "stuck app: recorded as skipped because running" "$(history_file)" 'running-skipped=\[Zed\]'

printf '== a leftover copy in the Caskroom stops the upgrade before it starts\n'
new_sandbox
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
mkdir -p "$STATE/caskroom/zed/0.150.0/Zed.app"
INTERACTIVE=1
answers yes
run_wu run
check_status "leftover copy: exit 1, so the pass asks for a person" 1
check_out_has "leftover copy: named" 'Zed has a leftover copy where Homebrew expects a link'
check_file_has "leftover copy: recorded as a failure" "$(history_file)" 'failures=[^ ]*in-the-way\(Zed\)'
check_calls_lacks "leftover copy: no upgrade" '^brew upgrade'
mv "$STATE/caskroom/zed/0.150.0/Zed.app" "$STATE/caskroom/zed/0.150.0/Zed.app.moved-by-test"
ln -s "$S/Applications/Zed.app" "$STATE/caskroom/zed/0.150.0/Zed.app"
printf '%s\n' "$S/Applications/Zed.app" > "$STATE/scenario/brew/upgrade-zed.app"
printf '0.151.0\n' > "$STATE/scenario/brew/upgrade-zed.version"
reset_calls
run_wu run
check_calls_has "control: a link where Homebrew expects one does not block" '^brew upgrade --cask zed'

printf '== an app that cannot be read after a reported upgrade is a failure\n'
new_sandbox
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
printf 'vanish\n' > "$STATE/scenario/brew/upgrade-zed"
printf '%s\n' "$S/Applications/Zed.app" > "$STATE/scenario/brew/upgrade-zed.app"
INTERACTIVE=1
answers yes
run_wu run
check_status "unreadable after upgrade: exit 1" 1
check_out_has "unreadable after upgrade: said plainly" 'Zed is missing or unreadable at .* although Homebrew reported success'
check_file_has "unreadable after upgrade: tagged" "$(history_file)" 'failures=[^ ]*upgrade\(Zed\)'
check_file_has "unreadable after upgrade: not counted" "$(history_file)" 'upgraded=0 '

printf '== an app missing after a failed upgrade is named, not only called failed\n'
new_sandbox
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
printf 'fail-vanish\n' > "$STATE/scenario/brew/upgrade-zed"
printf '%s\n' "$S/Applications/Zed.app" > "$STATE/scenario/brew/upgrade-zed.app"
INTERACTIVE=1
answers yes
run_wu run
check_status "missing after a failed upgrade: exit 1" 1
check_out_has "missing after a failed upgrade: said plainly" 'Zed upgrade failed, and Zed is now missing or unreadable at .*Zed\.app'
check_file_has "missing after a failed upgrade: tagged" "$(history_file)" 'failures=[^ ]*upgrade\(Zed\)'
check_file_has "missing after a failed upgrade: the attempt is in the apps ledger" "$HOME_DIR/Library/Logs/weekly-update/apps.tsv" $'\t'upgrade-failed$'\t'Zed$'\t''0\.150\.0$'
INTERACTIVE=0
run_wu check
check_out_has "missing after a failed upgrade: a later check names the failed attempt" 'Zed is missing from disk; a run last saw it at .*, and this tool last changed it at .*\(upgrade-failed\)'

printf '== an interrupt during the index refresh shows its banner on the screen\n'
# The refresh output goes to the run log; the banner must not follow it there.
new_sandbox
basic_fixture
printf '30\n' > "$STATE/scenario/brew/update.sleep"
INTERACTIVE=1
answers yes
OUT=$S/out-index-term.txt
set -m
seam_env /bin/bash "$RUNTIME" run > "$OUT" 2>&1 &
pass_group=$!
set +m
waited=0
until LC_ALL=C grep -q '^brew update' "$STATE/calls.log" 2>/dev/null || [ "$waited" -ge 300 ]; do
  sleep 0.2
  waited=$((waited + 1))
done
check_calls_has "index interrupt: the refresh had started" '^brew update'
kill -TERM -- "-$pass_group" 2>/dev/null
wait "$pass_group" 2>/dev/null
waited=0
until [ "$(last_outcome)" = interrupted ] || [ "$waited" -ge 150 ]; do
  sleep 0.2
  waited=$((waited + 1))
done
testing_check "index interrupt: recorded as interrupted" interrupted "$(last_outcome)"
check_file_has "index interrupt: the row records exit 143 for TERM" "$(history_file)" 'interrupted[[:space:]]exit=143 .*signal=TERM'
check_out_has "index interrupt: the banner is on the screen" 'INTERRUPTED'
check_out_has "index interrupt: the hint is on the screen" 'Nothing was deleted\. Rerun whenever convenient\.'

# replacement_outlives SIGNAL: the signal reaches the whole window group while
# an app is being replaced; the pass ends, the replacement finishes.
replacement_outlives() {
  local signal=$1 pass_group waited code
  new_sandbox
  basic_fixture
  set_outdated zed
  cask_info zed 0.151.0 Zed.app 0.150.0
  printf '%s\n' "$S/Applications/Zed.app" > "$STATE/scenario/brew/upgrade-zed.app"
  printf '0.151.0\n' > "$STATE/scenario/brew/upgrade-zed.version"
  printf '8\n' > "$STATE/scenario/brew/upgrade-zed.sleep"
  INTERACTIVE=1
  answers yes
  OUT=$S/out-$signal.txt
  set -m
  seam_env /bin/bash "$RUNTIME" run > "$OUT" 2>&1 &
  pass_group=$!
  set +m
  waited=0
  until LC_ALL=C grep -q '^brew upgrade --cask zed' "$STATE/calls.log" 2>/dev/null || [ "$waited" -ge 300 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  check_calls_has "$signal: the upgrade had started" '^brew upgrade --cask zed'
  kill "-$signal" -- "-$pass_group" 2>/dev/null
  wait "$pass_group" 2>/dev/null
  waited=0
  until [ "$(last_outcome)" = interrupted ] || [ "$waited" -ge 150 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  testing_check "$signal: the pass recorded the interruption" interrupted "$(last_outcome)"
  case $signal in HUP) code=129 ;; INT) code=130 ;; *) code=143 ;; esac
  check_file_has "$signal: the row records exit $code" "$(history_file)" "interrupted[[:space:]]exit=$code .*signal=$signal"
  testing_check "$signal: the upgrade was still running when the pass ended" no "$( [ -e "$STATE/upgrade-finished-zed" ] && printf yes || printf no )"
  waited=0
  until [ -e "$STATE/upgrade-finished-zed" ] || [ "$waited" -ge 100 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  testing_check "$signal: the upgrade finished anyway" yes "$( [ -e "$STATE/upgrade-finished-zed" ] && printf yes || printf no )"
  testing_check "$signal: the bundle is whole at the new version" 0.151.0 "$(plutil -extract CFBundleShortVersionString raw -o - "$S/Applications/Zed.app/Contents/Info.plist")"
}

printf '== closing the window ends the pass but not an app replacement already running\n'
replacement_outlives HUP
printf '== a TERM to the window group ends the pass but not an app replacement already running\n'
replacement_outlives TERM
printf '== an interrupt to the window group ends the pass but not an app replacement already running\n'
if interrupts_arrive; then
  replacement_outlives INT
else
  printf 'SKIP  INT: SIGINT was ignored when this test started, so no interrupt can be sent\n'
fi

printf '== an interactive run that cannot refresh the index says so and carries on\n'
new_sandbox
basic_fixture
printf '1\n' > "$STATE/scenario/brew/update.status"
INTERACTIVE=1
: > "$S/answers"
run_wu run
INTERACTIVE=0
check_status "index failure, run: exit 1" 1
check_out_has "index failure, run: says the cached index is used" 'the pass uses the cached one'
check_file_has "index failure, run: recorded as a failure" "$(history_file)" 'failures=[^ ]*index'
check_out_has "index failure, run: the inventory still ran" 'Zed +0\.150\.0'

printf '== S18 run --dry-run changes and writes nothing\n'
new_sandbox
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
cask_info firefox 131.0 Firefox.app 131.0
restart_listing
run_wu run --dry-run
check_status "S18 run dry run exits 0 without a terminal" 0
check_calls_lacks "S18 run: no mutation" '^(brew (update|upgrade|install)|sudo|open|window|launchctl bootstrap)|to quit|osascript'
testing_check "S18 run: no history row" 0 "$(history_rows)"
check_out_has "S18 run: would upgrade" 'Would upgrade Zed'
check_out_has "S18 run: would open" 'Would ask, then open: Firefox'
check_out_has "S18 run: would install" 'Would install the 1 recommended item'

testing_verdict
