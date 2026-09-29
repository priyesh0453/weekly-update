#!/bin/bash
# test-auto.sh: scenarios for the unattended pass, S1-S6, S18 (auto leg) and
# S19. Every auto leg ends with the I8 check on calls.log, so a sudo or a
# macOS install that slipped into a slot fails the scenario that ran it.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # the decoy shim, the sed program and one grep needle are literal source text, so a $ in them must not expand
set -u
set -o pipefail
# shellcheck source=harness.sh
. "${0%/*}/harness.sh"

printf '== S1 auto, nothing outdated\n'
new_sandbox
basic_fixture
run_wu auto
check_status "S1 exit 0" 0
testing_check "S1 history row" completed "$(last_outcome)"
check_file_has "S1 Done notification" "$STATE/notifications.log" '^Done: 0 app\(s\) upgraded\. Nothing needs you\.$'
check_calls_has "S1 the index is refreshed" '^brew update$'
check_out_has "S1 matches the index" 'Every confirmed app matches the index'
testing_check "S1 one row for the pass" 1 "$(history_rows)"
check_out_lacks "S1 the banner promises no more than the README" 'never deletes'
check_out_lacks "S1 the summary names no next pass before its own row exists" 'Next unattended pass'
check_i8 "S1"
check_brew_env "S1"
run_wu auto
check_status "S1 a second slot the same day exits 0" 0
testing_check "S1 a second slot stands down" "slot skipped" "$(last_outcome)"
testing_check "S1 the stand-down adds one row" 2 "$(history_rows)"
check_i8 "S1 second slot"

printf '== a config that confirms no app never claims every confirmed app matches\n'
new_sandbox
basic_fixture
write_config '# no app is confirmed yet'
run_wu auto
check_out_has "no confirmed app: says none is checked" 'No app is confirmed yet, so none is checked for upgrades'
check_out_lacks "no confirmed app: no matches claim" 'Every confirmed app matches the index'
check_i8 "no confirmed app"

printf '== S2 a deferred window is retried by a later slot the same day\n'
new_sandbox
basic_fixture
make_app Zed dev.zed.Zed 0.150.0
cask_info zed 0.151.0 Zed.app 0.151.0
write_config '[updater]' "weekday = $(today_weekday)" 'first_hour = 0' 'last_hour = 23' 'minute = 59' \
  '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed' '[app com.microsoft.VSCode]' 'cask = visual-studio-code'
install_into_sandbox
check_status "S2 install into the sandbox" 0
reset_calls
set_active 0
run_wu auto
check_status "S2 slot 1 exits 0" 0
testing_check "S2 slot 1 defers the window" "escalation deferred" "$(last_outcome)"
check_file_has "S2 slot 1 promises a later slot today" "$STATE/notifications.log" 'A later slot today opens a window if you are at the Mac'
check_calls_lacks "S2 slot 1 opens no window" '^window '
check_i8 "S2 slot 1"
reset_calls
set_active 1
run_wu auto
check_status "S2 slot 2 exits 0" 0
testing_check "S2 slot 2 escalates" escalated "$(last_outcome)"
check_calls_has "S2 slot 2 opens the window launcher" "^window $HOME_DIR/.local/share/weekly-update/app/bin/weekly-update-scheduled\$"
check_calls_lacks "S2 slot 2 does not redo the upgrade work" '^brew (update|outdated)'
check_file_has "S2 slot 2 carries the reason" "$(history_file)" 'escalated.*reasons=apps-to-open'
check_i8 "S2 slot 2"
reset_calls
run_wu auto
check_status "S2 slot 3 exits 0" 0
testing_check "S2 slot 3 stands down" "slot skipped" "$(last_outcome)"
check_calls_lacks "S2 slot 3 does nothing" '^(brew|open|window)'
check_i8 "S2 slot 3"
run_wu status
check_status "S2 status after the day's pass exits 0" 0
check_out_has "S2 status names the next pass" 'Next unattended pass: [A-Za-z]+ [0-9]{4}-'
check_out_lacks "S2 status never names a slot today once a pass finished" "Next unattended pass: [A-Za-z]+ $(date '+%Y-%m-%d') "

printf '== S2 two-slot config: no later slot is promised\n'
new_sandbox
basic_fixture
cask_info zed 0.151.0 Zed.app 0.151.0
write_config '[updater]' "weekday = $(other_weekday)" 'first_hour = 14' 'last_hour = 15' \
  '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed'
install_into_sandbox
check_status "S2b install into the sandbox" 0
reset_calls
run_wu auto
check_status "S2b exits 0" 0
check_calls_has "S2b a slot on another day still runs the full pass" '^brew update$'
testing_check "S2b defers" "escalation deferred" "$(last_outcome)"
check_file_has "S2b says no slot is left today" "$STATE/notifications.log" 'No slot is left today'
check_file_lacks "S2b makes no false promise" "$STATE/notifications.log" 'A later slot today'
check_i8 "S2b"
suggested=$(sed -n 's/.*open Terminal and run: \(.*\)$/\1/p' "$STATE/notifications.log" | tail -n 1)
tilde='~'
testing_check "S2b the notification names the installed runtime, not a bare name" "$tilde/.local/share/weekly-update/app/bin/weekly-update" "$suggested"
testing_check "S2b that path is an executable file" yes "$( [ -f "$HOME_DIR/${suggested#\~/}" ] && [ -x "$HOME_DIR/${suggested#\~/}" ] && printf yes || printf no )"

printf '== S2e a slot the Mac slept through runs at a wake the next day and stands down once the slot day finished\n'
for row in "$(date -v-1d '+%Y-%m-%d') 20:00:00|completed|stands down" "$(date -v-1d '+%Y-%m-%d') 20:00:00|declined|stands down" "$(date -v-8d '+%Y-%m-%d') 20:00:00|completed|runs"; do
  stamp=${row%%|*}
  rest=${row#*|}
  outcome=${rest%%|*}
  expect=${rest#*|}
  new_sandbox
  basic_fixture
  cask_info zed 0.151.0 Zed.app 0.151.0
  write_config '[updater]' "weekday = $(date -v-1d '+%w')" 'first_hour = 14' 'last_hour = 15' \
    '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed'
  install_into_sandbox
  check_status "S2e install into the sandbox" 0
  mkdir -p "${HOME_DIR}/Library/Logs/weekly-update"
  printf '%s\tauto\t%s\texit=0\n' "$stamp" "$outcome" >> "$(history_file)"
  reset_calls
  set_active 1
  run_wu auto
  check_status "S2e after a $outcome row dated $stamp: exit 0" 0
  if [ "$expect" = "stands down" ]; then
    testing_check "S2e after a $outcome row on the slot day: the wake slot stands down" "slot skipped" "$(last_outcome)"
    check_calls_lacks "S2e after a $outcome row on the slot day: no update and no window" '^(brew update|window )'
  else
    check_calls_has "S2e after a $outcome row a week before the slot day: the wake slot runs the full pass" '^brew update$'
  fi
  check_i8 "S2e $outcome $expect"
done

printf '== S2 a retried window keeps the failure status of the slot that deferred it\n'
new_sandbox
basic_fixture
write_config '[updater]' "weekday = $(today_weekday)" 'first_hour = 0' 'last_hour = 23' 'minute = 59' \
  '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed' '[app com.microsoft.VSCode]' 'cask = visual-studio-code'
printf '1\n' > "$STATE/scenario/brew/info-zed.status"
install_into_sandbox
check_status "S2c install into the sandbox" 0
reset_calls
set_active 0
run_wu auto
check_status "S2c slot 1 with a failed query exits 1" 1
testing_check "S2c slot 1 defers the window" "escalation deferred" "$(last_outcome)"
check_i8 "S2c slot 1"
reset_calls
set_active 1
run_wu auto
check_status "S2c the retried window still exits 1" 1
testing_check "S2c slot 2 escalates" escalated "$(last_outcome)"
check_file_has "S2c the escalated row still names the failure" "$(history_file)" 'escalated.exit=1 .*reasons=[^ ]*failed-steps'
check_calls_lacks "S2c slot 2 does not redo the queries" '^brew (update|outdated|info)'
check_i8 "S2c slot 2"

printf '== S2 the slots come from the LaunchAgent launchd loaded, not from a config edited since\n'
new_sandbox
basic_fixture
cask_info zed 0.151.0 Zed.app 0.151.0
write_config '[updater]' "weekday = $(other_weekday)" 'first_hour = 14' 'last_hour = 15' \
  '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed' '[app com.microsoft.VSCode]' 'cask = visual-studio-code'
install_into_sandbox
check_status "S2d install into the sandbox" 0
write_config '[updater]' "weekday = $(today_weekday)" 'first_hour = 0' 'last_hour = 23' 'minute = 59' \
  '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed' '[app com.microsoft.VSCode]' 'cask = visual-studio-code'
reset_calls
set_active 0
run_wu auto
check_status "S2d exits 0" 0
testing_check "S2d defers the window" "escalation deferred" "$(last_outcome)"
check_file_has "S2d says no slot is left today, as the loaded LaunchAgent has none" "$STATE/notifications.log" 'No slot is left today'
check_file_lacks "S2d promises no slot that only the edited config has" "$STATE/notifications.log" 'A later slot today'
check_i8 "S2d"

printf '== a window that cannot open becomes partial and a notification\n'
new_sandbox
basic_fixture
cask_info zed 0.151.0 Zed.app 0.151.0
set_active 1
run_wu auto
check_status "no launcher: exit 1" 1
testing_check "no launcher: recorded as partial" partial "$(last_outcome)"
check_file_has "no launcher: the notification says what to run" "$STATE/notifications.log" '^Needs you: apps-to-open\. Open Terminal and run: '
check_calls_lacks "no launcher: no window" '^window '
check_i8 "no launcher"

printf '== S3 battery deferral is not terminal\n'
new_sandbox
basic_fixture
set_battery 15
run_wu auto
check_status "S3 exit 0 on battery" 0
testing_check "S3 battery deferred" "battery deferred" "$(last_outcome)"
check_calls_lacks "S3 nothing is refreshed or upgraded on battery" '^brew (update|upgrade)'
check_i8 "S3 battery leg"
set_ac
reset_calls
run_wu auto
check_status "S3 later slot exit 0" 0
testing_check "S3 a later slot runs the full pass" completed "$(last_outcome)"
check_calls_has "S3 later slot refreshes the index" '^brew update$'
check_i8 "S3 AC leg"

printf '== S3b a battery deferral promises a later slot only when one is left today\n'
new_sandbox
basic_fixture
write_config '[updater]' "weekday = $(today_weekday)" 'first_hour = 0' 'last_hour = 23' 'minute = 59'
install_into_sandbox
check_status "S3b install into the sandbox (slots left today)" 0
set_battery 15
reset_calls
run_wu auto
check_status "S3b exit 0 on battery with slots left" 0
check_file_has "S3b promises a later slot" "$STATE/notifications.log" 'Deferred: on battery below .* A later slot retries'
check_file_lacks "S3b with slots left says nothing about the last slot" "$STATE/notifications.log" 'No slot is left today'
check_file_has "S3b with slots left, the history row says a later slot retries" "$(history_file)" 'a later slot retries'
check_i8 "S3b slots left"
new_sandbox
basic_fixture
write_config '[updater]' "weekday = $(other_weekday)" 'first_hour = 14' 'last_hour = 15'
install_into_sandbox
check_status "S3b install into the sandbox (no slot left today)" 0
set_battery 15
reset_calls
run_wu auto
check_status "S3b exit 0 on battery with no slot left" 0
testing_check "S3b battery deferred" "battery deferred" "$(last_outcome)"
check_file_has "S3b says no slot is left today" "$STATE/notifications.log" 'Deferred: on battery below .* No slot is left today; next pass '
check_file_lacks "S3b makes no false promise" "$STATE/notifications.log" 'A later slot retries'
check_file_has "S3b the history row says so too" "$(history_file)" 'no slot is left today'
check_i8 "S3b no slot left"

printf '== S4 a slot that cannot refresh the index defers (I5)\n'
new_sandbox
basic_fixture
printf '1\n' > "$STATE/scenario/brew/update.status"
run_wu auto
check_status "S4 exit 0" 0
testing_check "S4 slot deferred" "slot deferred" "$(last_outcome)"
check_file_lacks "S4 no summary row" "$(history_file)" '	(completed|partial)	'
check_calls_lacks "S4 no inventory after a failed refresh" '^brew (info|outdated)'
check_i8 "S4 failed refresh"
printf '0\n' > "$STATE/scenario/brew/update.status"
run_wu auto
testing_check "S4 the next slot runs" completed "$(last_outcome)"
check_i8 "S4 next slot"
printf '== S4 an index deferral on the last slot of the day says no slot is left\n'
new_sandbox
basic_fixture
write_config '[updater]' "weekday = $(other_weekday)" 'first_hour = 14' 'last_hour = 15' \
  '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed' '[app com.microsoft.VSCode]' 'cask = visual-studio-code'
install_into_sandbox
check_status "S4 last slot: install into the sandbox" 0
reset_calls
printf '1\n' > "$STATE/scenario/brew/update.status"
run_wu auto
check_status "S4 last slot: exit 0" 0
testing_check "S4 last slot: deferred" "slot deferred" "$(last_outcome)"
check_file_has "S4 last slot: the notification says no slot is left today" "$STATE/notifications.log" '^Deferred: the Homebrew index could not be refreshed and no slot is left today'
check_file_lacks "S4 last slot: no later slot is promised" "$STATE/notifications.log" 'A later slot retries'
check_i8 "S4 last slot"
printf '== S4 a hung refresh is stopped at index_timeout\n'
new_sandbox
basic_fixture
write_config '[updater]' 'index_timeout = 5' '[app org.mozilla.firefox]' 'cask = firefox'
printf '30\n' > "$STATE/scenario/brew/update.sleep"
started=$SECONDS
run_wu auto
elapsed=$((SECONDS - started))
check_status "S4 hang exit 0" 0
testing_check "S4 hang deferred" "slot deferred" "$(last_outcome)"
if [ "$elapsed" -lt 20 ]; then testing_check "S4 hang stopped near its deadline" yes yes; else testing_check "S4 hang stopped near its deadline" "under 20s" "${elapsed}s"; fi
check_i8 "S4 hang"
printf '== S4 a week with no finished pass is notified once a day, even when every slot defers\n'
new_sandbox
basic_fixture
mkdir -p "$HOME_DIR/Library/Logs/weekly-update"
printf '%s\tauto\tcompleted\texit=0 version=0.1.0\n' "$(date -v-9d '+%Y-%m-%d %H:%M:%S')" > "$(history_file)"
printf '1\n' > "$STATE/scenario/brew/update.status"
run_wu auto
check_status "S4 heartbeat: exit 0" 0
testing_check "S4 heartbeat: the slot defers" "slot deferred" "$(last_outcome)"
check_file_has "S4 heartbeat: the silent week is notified" "$STATE/notifications.log" '^No weekly pass has finished for 9 days\. See why with: '
check_file_has "S4 heartbeat: the deferral names the index, not a guess" "$STATE/notifications.log" '^Deferred: the Homebrew index could not be refreshed'
check_i8 "S4 heartbeat slot 1"
reset_calls
run_wu auto
check_status "S4 heartbeat: a later slot exits 0" 0
check_file_lacks "S4 heartbeat: a later slot the same day does not repeat it" "$STATE/notifications.log" 'No weekly pass has finished'
check_i8 "S4 heartbeat slot 2"

printf '== S5 a running app is never quit by the unattended pass\n'
new_sandbox
basic_fixture
set_outdated firefox zed
cask_info firefox 131.0 Firefox.app 130.0
cask_info zed 0.151.0 Zed.app 0.150.0
printf '%s\n' "$S/Applications/Zed.app" > "$STATE/scenario/brew/upgrade-zed.app"
printf '0.151.0\n' > "$STATE/scenario/brew/upgrade-zed.version"
set_running org.mozilla.firefox
set_active 0
run_wu auto
check_status "S5 exit 0" 0
check_calls_lacks "S5 no quit" 'to quit'
check_calls_lacks "S5 no upgrade of the running app" '^brew upgrade --cask firefox'
check_calls_has "S5 the closed app is upgraded with Homebrew's quit off" '^brew upgrade --cask zed NO_UPGRADE_QUIT_CASKS=1$'
check_calls_lacks "S5 every unattended upgrade has Homebrew's quit off" '^brew upgrade .*NO_UPGRADE_QUIT_CASKS=(unset|0)'
check_file_has "S5 the running app is recorded as skipped" "$(history_file)" 'running-skipped=\[Firefox\]'
check_file_has "S5 a running app is an escalation reason" "$(history_file)" 'reasons=[^ ]*running-apps'
testing_check "S5 the Zed bundle moved" 0.151.0 "$(plutil -extract CFBundleShortVersionString raw -o - "$S/Applications/Zed.app/Contents/Info.plist")"
check_i8 "S5"
check_brew_env "S5"
printf '== S5 no config can turn the unattended quit on\n'
new_sandbox
basic_fixture
write_config '[updater]' 'running_apps_in_auto = quit'
run_wu auto
check_status "S5 a quit opt-in is refused with exit 2" 2
check_out_has "S5 the refusal names the file and line" 'config:2: unknown key running_apps_in_auto in \[updater\]'
check_calls_lacks "S5 nothing ran on the invalid config" '^(brew|softwareupdate|osascript -e "tell)'
check_i8 "S5 refused config"
printf '== S5 an app whose running state cannot be read counts as running\n'
new_sandbox
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
printf '%s\n' "$S/Applications/Zed.app" > "$STATE/scenario/brew/upgrade-zed.app"
printf '0.151.0\n' > "$STATE/scenario/brew/upgrade-zed.version"
printf '3\n' > "$STATE/scenario/pgrep.status"
run_wu auto
check_status "S5 pgrep error: exit 0" 0
check_calls_has "S5 pgrep error: the state was asked for" '^pgrep -q -f .*Zed'
check_calls_lacks "S5 pgrep error: no unattended upgrade" '^brew upgrade'
check_file_has "S5 pgrep error: recorded as running" "$(history_file)" 'running-skipped=\[Zed\]'
testing_check "S5 pgrep error: the bundle is untouched" 0.150.0 "$(plutil -extract CFBundleShortVersionString raw -o - "$S/Applications/Zed.app/Contents/Info.plist")"
check_i8 "S5 pgrep error"

printf '== S6 a failed query is a failure, never a match\n'
new_sandbox
basic_fixture
printf '1\n' > "$STATE/scenario/brew/info-zed.status"
run_wu auto
check_status "S6 info failure exits 1" 1
check_file_has "S6 info failure is tagged" "$(history_file)" 'failures=[^ ]*query\(zed\)'
check_out_lacks "S6 info failure: no matches claim" 'matches the index'
check_file_lacks "S6 info failure: no Nothing needs you" "$STATE/notifications.log" 'Nothing needs you'
check_i8 "S6 info"
new_sandbox
basic_fixture
printf '1\n' > "$STATE/scenario/brew/outdated.status"
run_wu auto
check_status "S6 outdated failure exits 1" 1
check_file_has "S6 outdated failure is tagged" "$(history_file)" 'failures=[^ ]*query\(outdated\)'
check_out_lacks "S6 outdated failure: no matches claim" 'matches the index'
check_file_lacks "S6 outdated failure: no Nothing needs you" "$STATE/notifications.log" 'Nothing needs you'
check_i8 "S6 outdated"
new_sandbox
basic_fixture
printf '#!/bin/bash\nexit 5\n' > "$S/shims/jq"
chmod 755 "$S/shims/jq"
run_wu auto
check_status "S6 broken jq exits 1" 1
check_file_has "S6 broken jq is tagged" "$(history_file)" 'failures=[^ ]*query\('
check_out_lacks "S6 broken jq: no matches claim" 'matches the index'
check_file_lacks "S6 broken jq: no Nothing needs you" "$STATE/notifications.log" 'Nothing needs you'
check_i8 "S6 jq"
printf '== S6 hung read-only calls are stopped at their deadlines and count as failures\n'
new_sandbox
basic_fixture
write_config '[updater]' 'query_timeout = 5' 'list_timeout = 5' '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed'
printf '30\n' > "$STATE/scenario/brew/info-zed.sleep"
printf '30\n' > "$STATE/scenario/brew/outdated.sleep"
printf '30\n' > "$STATE/scenario/softwareupdate/list.sleep"
started=$SECONDS
run_wu auto
elapsed=$((SECONDS - started))
check_status "S6 hangs exit 1" 1
check_file_has "S6 the hung cask query is tagged" "$(history_file)" 'failures=[^ ]*query\(zed\)'
check_file_has "S6 the hung outdated query is tagged" "$(history_file)" 'failures=[^ ]*query\(outdated\)'
check_file_has "S6 the hung macOS listing is tagged" "$(history_file)" 'failures=[^ ]*query\(softwareupdate\)'
check_out_lacks "S6 hangs: no matches claim" 'matches the index'
if [ "$elapsed" -lt 60 ]; then testing_check "S6 three 30-second hangs stopped near their 5-second deadlines" yes yes; else testing_check "S6 three 30-second hangs stopped near their 5-second deadlines" "under 60s" "${elapsed}s"; fi
check_i8 "S6 hangs"
printf '== S6 an interrupt during a Homebrew query ends the pass without waiting for the query\n'
if interrupts_arrive; then
  new_sandbox
  basic_fixture
  printf '40\n' > "$STATE/scenario/brew/info-zed.sleep"
  OUT=$S/out-query-interrupt.txt
  set -m
  seam_env /bin/bash "$RUNTIME" auto > "$OUT" 2>&1 &
  pass_group=$!
  set +m
  waited=0
  until LC_ALL=C grep -q '^brew info --cask zed' "$STATE/calls.log" 2>/dev/null || [ "$waited" -ge 300 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  check_calls_has "S6 query interrupt: the query had started" '^brew info --cask zed'
  signalled=$SECONDS
  kill -INT -- "-$pass_group" 2>/dev/null
  wait "$pass_group" 2>/dev/null
  waited=0
  until [ "$(last_outcome)" = interrupted ] || [ "$waited" -ge 300 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  elapsed=$((SECONDS - signalled))
  testing_check "S6 query interrupt: recorded as interrupted" interrupted "$(last_outcome)"
  check_file_has "S6 query interrupt: the row records exit 130 for INT" "$(history_file)" 'interrupted[[:space:]]exit=130 .*signal=INT'
  if [ "$elapsed" -lt 15 ]; then testing_check "S6 query interrupt: the pass ended within 15 seconds of the signal" yes yes; else testing_check "S6 query interrupt: the pass ended within 15 seconds of the signal" "under 15s" "${elapsed}s"; fi
  check_i8 "S6 query interrupt"
else
  printf 'SKIP  S6 query interrupt: SIGINT was ignored when this test started, so no interrupt can be sent\n'
fi

printf '== S6 a TERM during any read-only query ends the pass without waiting for the query\n'
testing_check "S6 no deadline call inside a command substitution skips the signal trap" 0 "$(LC_ALL=C grep -c '\$(lifecycle_run_with_deadline' "$REPO/bin/weekly-update")"
for site in 'brew/installed.sleep|^brew info --cask --installed' 'brew/outdated.sleep|^brew outdated --cask' 'softwareupdate/list.sleep|^softwareupdate --list'; do
  knob=${site%%|*}
  call=${site#*|}
  new_sandbox
  basic_fixture
  printf '40\n' > "$STATE/scenario/$knob"
  OUT=$S/out-query-term.txt
  set -m
  seam_env /bin/bash "$RUNTIME" auto > "$OUT" 2>&1 &
  pass_group=$!
  set +m
  waited=0
  until LC_ALL=C grep -q -e "$call" "$STATE/calls.log" 2>/dev/null || [ "$waited" -ge 300 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  check_calls_has "S6 TERM during $knob: the query had started" "$call"
  signalled=$SECONDS
  kill -TERM -- "-$pass_group" 2>/dev/null
  wait "$pass_group" 2>/dev/null
  waited=0
  until [ "$(last_outcome)" = interrupted ] || [ "$waited" -ge 300 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  elapsed=$((SECONDS - signalled))
  testing_check "S6 TERM during $knob: recorded as interrupted" interrupted "$(last_outcome)"
  check_file_has "S6 TERM during $knob: the row records exit 143 for TERM" "$(history_file)" 'interrupted[[:space:]]exit=143 .*signal=TERM'
  if [ "$elapsed" -lt 15 ]; then testing_check "S6 TERM during $knob: the pass ended within 15 seconds of the signal" yes yes; else testing_check "S6 TERM during $knob: the pass ended within 15 seconds of the signal" "under 15s" "${elapsed}s"; fi
  check_i8 "S6 TERM during $knob"
done

printf '== S6 unreadable Dock preferences are a failure, never an empty Dock\n'
dock_file() { printf '%s' "$HOME_DIR/Library/Preferences/com.apple.dock.plist"; }
new_sandbox
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
printf 'not a property list\n' > "$(dock_file)"
run_wu auto --dry-run
check_status "S6 corrupt Dock: auto --dry-run still exits 0" 0
check_out_has "S6 corrupt Dock: auto --dry-run lists the failure" 'Finished with issues: query\(dock\)'
run_wu run --dry-run
check_status "S6 corrupt Dock: run --dry-run still exits 0" 0
check_out_has "S6 corrupt Dock: run --dry-run lists the failure" 'Finished with issues: query\(dock\)'
run_wu auto
check_status "S6 corrupt Dock exits 1" 1
check_file_has "S6 corrupt Dock is tagged" "$(history_file)" 'failures=[^ ]*query\(dock\)'
check_out_lacks "S6 corrupt Dock: no matches claim" 'matches the index'
check_file_lacks "S6 corrupt Dock: no Nothing needs you" "$STATE/notifications.log" 'Nothing needs you'
check_i8 "S6 corrupt Dock"
new_sandbox
basic_fixture
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>tilesize</key>\n\t<integer>48</integer>\n</dict>\n</plist>\n' > "$(dock_file)"
run_wu auto
check_status "S6 Dock without its app list exits 1" 1
check_file_has "S6 Dock without its app list is tagged" "$(history_file)" 'failures=[^ ]*query\(dock\)'
check_file_lacks "S6 Dock without its app list: no Nothing needs you" "$STATE/notifications.log" 'Nothing needs you'
check_i8 "S6 Dock without its app list"
new_sandbox
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
mv "$(dock_file)" "$S/dock.moved-by-test"
run_wu auto
check_status "S6 no Dock preferences file exits 1" 1
check_out_has "S6 no Dock preferences file is named" 'The Dock preferences at .*/com\.apple\.dock\.plist are missing or could not be read, so no app was checked'
check_file_has "S6 no Dock preferences file is tagged" "$(history_file)" 'failures=[^ ]*query\(dock\)'
check_out_lacks "S6 no Dock preferences file: no matches claim" 'matches the index'
check_file_lacks "S6 no Dock preferences file: no Nothing needs you" "$STATE/notifications.log" 'Nothing needs you'
check_i8 "S6 no Dock preferences file"
new_sandbox
basic_fixture
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>persistent-apps</key>\n\t<array/>\n</dict>\n</plist>\n' > "$(dock_file)"
run_wu auto
check_status "S6 control: a Dock with no apps exits 0" 0
testing_check "S6 control: a Dock with no apps completes" completed "$(last_outcome)"
check_i8 "S6 empty Dock"

printf '== S6 a macOS listing this tool cannot read is a failure, never current\n'
new_sandbox
basic_fixture
set_listing 'Software Update Tool' '' 'Finding available software' 'Software Update found the following new or updated software:' \
  '   Label: Example Update-1.0' '        Example Update (1.0), 10240K [recommended]'
run_wu auto
check_status "S6 unreadable listing exits 1" 1
check_file_has "S6 unreadable listing is tagged" "$(history_file)" 'failures=[^ ]*query\(softwareupdate\)'
check_file_lacks "S6 unreadable listing: no Nothing needs you" "$STATE/notifications.log" 'Nothing needs you'
check_out_lacks "S6 unreadable listing: never called current" 'macOS is current'
check_i8 "S6 unreadable listing"

printf '== S6 a missing jq stops the preflight\n'
testing_source_function "$REPO/bin/weekly-update" missing_tools
mkdir -p "$S/only-plutil"
ln -s /usr/bin/plutil "$S/only-plutil/plutil"
testing_check "S6 missing_tools names jq" "jq" "$(PATH=$S/only-plutil missing_tools jq plutil)"
testing_check "S6 missing_tools is quiet when all exist" "" "$(missing_tools plutil)"

printf '== a history file that cannot be written stops the slot before it acts\n'
new_sandbox
basic_fixture
mkdir -p "$HOME_DIR/Library/Logs/weekly-update"
: > "$(history_file)"
chmod 444 "$(history_file)"
run_wu auto
check_status "unwritable history: exit 1" 1
check_out_has "unwritable history: named, with what to do" 'cannot write .*history\.tsv, so later slots could not tell that a pass finished'
check_calls_lacks "unwritable history: no index refresh and no upgrade" '^brew (update|upgrade|install)'
check_i8 "unwritable history"
chmod 644 "$(history_file)"
reset_calls
run_wu auto
check_status "control: once writable, the slot runs and exits 0" 0
check_calls_has "control: once writable, the index is refreshed" '^brew update$'
testing_check "control: once writable, the pass row is written" completed "$(last_outcome)"
check_i8 "control: once writable"
for kind in folder devnull missing; do
  new_sandbox
  basic_fixture
  mkdir -p "$HOME_DIR/Library/Logs/weekly-update"
  label="history as a $kind"
  case $kind in
    folder) mkdir "$(history_file)" ;;
    devnull) ln -s /dev/null "$(history_file)" ;;
    missing)
      label="no history in a log folder this account cannot write, with a run.lock it can"
      : > "$HOME_DIR/Library/Logs/weekly-update/run.lock"
      chmod 555 "$HOME_DIR/Library/Logs/weekly-update"
      ;;
  esac
  run_wu auto
  chmod 755 "$HOME_DIR/Library/Logs/weekly-update"
  check_status "$label: exit 1" 1
  check_out_has "$label: named, with what to do" 'cannot write .*history\.tsv, so later slots could not tell'
  check_calls_lacks "$label: no index refresh and no upgrade" '^brew (update|upgrade|install)'
  check_file_has "$label: the stop is notified" "$STATE/notifications.log" '^Stopped: cannot write'
  check_i8 "$label"
done

printf '== S18 auto --dry-run changes and writes nothing\n'
new_sandbox
basic_fixture
set_outdated zed
cask_info zed 0.151.0 Zed.app 0.150.0
set_listing 'Software Update Tool' '' 'Software Update found the following new or updated software:' '* Label: Example Update-1.0' '	Title: Example Update, Version: 1.0, Size: 10KiB, Recommended: YES, '
set_active 1
run_wu auto --dry-run
check_status "S18 auto dry run exits 0" 0
check_calls_lacks "S18 no mutation" '^(brew (update|upgrade|install)|sudo|open|window|launchctl bootstrap)|to quit'
check_file_lacks "S18 no notification" "$STATE/notifications.log" '.'
testing_check "S18 no history row" 0 "$(history_rows)"
testing_check "S18 no log folder" no "$( [ -e "$HOME_DIR/Library/Logs/weekly-update" ] && printf yes || printf no )"
check_out_has "S18 says what it would do" 'Would upgrade Zed'
check_out_has "S18 reports the presence it read" 'UserIsActive 1'
check_i8 "S18 auto leg"

printf '== S19 the system directories come before the Homebrew bin\n'
new_sandbox
basic_fixture
for decoy in plutil grep; do
  printf '#!/bin/bash\n: >> "$WU_TEST_STATE/decoy-ran"\nexec /usr/bin/%s "$@"\n' "$decoy" > "$S/brewbin/$decoy"
  chmod 755 "$S/brewbin/$decoy"
done
run_wu auto --dry-run
check_status "S19 dry run exits 0" 0
testing_check "S19 no decoy ran" no "$( [ -e "$STATE/decoy-ran" ] && printf yes || printf no )"
check_i8 "S19 dry run"
mkdir -p "$S/mutant/bin"
cp -R "$REPO/lib" "$REPO/templates" "$S/mutant/"
sed 's#^  export PATH="\$WU_TEST_SHIMS:/usr/bin:/bin:/usr/sbin:/sbin\${WU_TEST_BREW_BIN:+:\$WU_TEST_BREW_BIN}"$#  export PATH="$WU_TEST_SHIMS${WU_TEST_BREW_BIN:+:$WU_TEST_BREW_BIN}:/usr/bin:/bin:/usr/sbin:/sbin"#' \
  "$REPO/bin/weekly-update" > "$S/mutant/bin/weekly-update"
testing_check "S19 the mutant differs from the runtime" 1 "$(cmp -s "$REPO/bin/weekly-update" "$S/mutant/bin/weekly-update"; printf '%s' "$?")"
RUNTIME=$S/mutant/bin/weekly-update
run_wu auto --dry-run
testing_check "S19 with the Homebrew bin first, the decoy runs" yes "$( [ -e "$STATE/decoy-ran" ] && printf yes || printf no )"
check_i8 "S19 mutant"

testing_verdict
