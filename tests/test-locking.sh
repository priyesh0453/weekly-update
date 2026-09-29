#!/bin/bash
# test-locking.sh: lock, battery and closing-prompt scenarios, S9 and S14 (I7)
# and S15, plus the caffeinate double, the keep-awake release, and install and
# uninstall stopping at a pass in progress.
# shellcheck source-path=SCRIPTDIR
set -u
set -o pipefail
# shellcheck source=harness.sh
. "${0%/*}/harness.sh"

log_dir() { printf '%s' "$HOME_DIR/Library/Logs/weekly-update"; }

hold_lock() {
  mkdir -p "$(log_dir)"
  lockf -s -t 0 "$(log_dir)/run.lock" sleep 60 &
  HOLDER=$!
  local waited=0
  while [ ! -e "$(log_dir)/run.lock" ] && [ "$waited" -lt 20 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
}

release_holder() {
  kill "$HOLDER" 2>/dev/null
  wait "$HOLDER" 2>/dev/null
}

adoptable_fixture() {
  basic_fixture
  cask_info firefox 130.0 Firefox.app ""
}

printf '== S9 a held lock is a stand-down, a broken lock is a stop (I7)\n'
new_sandbox
basic_fixture
hold_lock
run_wu auto
release_holder
check_status "S9 held lock exits 0" 0
testing_check "S9 held lock stands down" "slot skipped" "$(last_outcome)"
check_file_has "S9 held lock says why" "$(history_file)" 'another run holds the lock'
check_calls_lacks "S9 held lock does no work" '^brew (update|upgrade)'
check_i8 "S9 held lock"
new_sandbox
basic_fixture
mkdir -p "$(log_dir)"
chmod 555 "$(log_dir)"
run_wu auto
check_status "S9 unopenable lock exits 1" 1
check_out_has "S9 unopenable lock stops, naming the lock" 'STOPPED +cannot open the run lock'
check_file_has "S9 unopenable lock notifies" "$STATE/notifications.log" '^Stopped: cannot open the run lock'
check_calls_lacks "S9 unopenable lock does no work" '^brew (update|upgrade)'
check_i8 "S9 unopenable lock"
chmod 755 "$(log_dir)"

printf '== S14 setup takes the lock and respects the battery floor\n'
new_sandbox
adoptable_fixture
INTERACTIVE=1
answers yes no
hold_lock
run_wu setup
release_holder
check_status "S14 setup with a pass running exits 0" 0
testing_check "S14 setup stands down" skipped "$(last_outcome)"
check_calls_lacks "S14 setup adopts nothing while a pass runs" 'install --cask --adopt'
set_battery 15
reset_calls
answers yes no
run_wu setup
check_status "S14 setup on low battery exits 0" 0
check_out_has "S14 adoption skipped on low battery" 'Adoption skipped this run \(battery\)'
check_calls_lacks "S14 no adoption on low battery" 'install --cask --adopt'
set_ac
reset_calls
answers yes no
run_wu setup
check_status "S14 control: setup on AC exits 0" 0
check_calls_has "S14 control: setup adopts on AC after a yes" '^brew install --cask --adopt --no-binaries firefox$'
check_calls_lacks "S14 setup never loads the schedule itself" '^launchctl (bootstrap|enable)'

printf '== S15 the closing prompt holds neither the lock nor keep-awake\n'
new_sandbox
basic_fixture
write_config '[updater]' 'final_prompt_timeout = 10' '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed'
INTERACTIVE=1
mkfifo "$S/tty"
exec 7<>"$S/tty"
TTY_FILE=$S/tty
OUT=$S/out-s15.txt
seam_env /bin/bash "$RUNTIME" scheduled > "$OUT" 2>&1 &
window=$!
printf 'yes\n' >&7
waited=0
until LC_ALL=C grep -q 'Press Return to close' "$OUT" 2>/dev/null || [ "$waited" -ge 150 ]; do
  sleep 0.2
  waited=$((waited + 1))
done
check_out_has "S15 the pass reached the closing prompt" 'Press Return to close'
check_out_has "S15 the closing line claims no more than the release can confirm" 'Lock released, and keep-awake stops now or at the latest when this run ends'
lockf -s -t 0 "$(log_dir)/run.lock" true
testing_check "S15 the lock is free at the closing prompt" 0 "$?"
awake_pid=$(tail -n 1 "$STATE/caffeinate.pids" 2>/dev/null)
testing_check "S15 keep-awake had started" yes "$( [ -n "$awake_pid" ] && printf yes || printf no )"
testing_check "S15 keep-awake is gone at the closing prompt" gone "$(kill -0 "$awake_pid" 2>/dev/null && printf running || printf gone)"
wait "$window"
RC=$?
exec 7>&-
check_status "S15 the window exits 0" 0
testing_check "S15 the pass row is the normal outcome" completed "$(last_outcome)"
check_file_has "S15 the row says the prompt timed out" "$(history_file)" 'closed=timeout$'
check_file_lacks "S15 no interrupted row" "$(history_file)" 'interrupted'

printf '== the caffeinate double runs once under a relative state folder instead of re-running itself forever\n'
new_sandbox
OUT=$S/out-relative-state.txt
# macOS never hands out a process number above 99999, so the double's wait ends at once.
(cd "$S" && exec env -i PATH=/usr/bin:/bin WU_TEST=1 WU_TEST_STATE=state "$S/shims/caffeinate" -i -w 999999) > "$OUT" 2>&1 &
double=$!
waited=0
while kill -0 "$double" 2>/dev/null && [ "$waited" -lt 50 ]; do
  sleep 0.2
  waited=$((waited + 1))
done
if kill -0 "$double" 2>/dev/null; then kill -KILL "$double" 2>/dev/null; fi
wait "$double"
RC=$?
check_status "a relative state folder: the double exits 0 within 10 seconds" 0
testing_check "a relative state folder: the double logged its call once" 1 "$(LC_ALL=C grep -c -x -e 'caffeinate -i -w 999999' "$STATE/calls.log")"
testing_check "a relative state folder: the double ran through its caffeinate link" yes "$( [ -L "$STATE/named/caffeinate" ] && printf yes || printf no )"

printf '== keep-awake release signals only its own caffeinate child, never a reused process number\n'
new_sandbox
mkdir -p "$S/named"
ln -s /bin/sleep "$S/named/caffeinate"
cat > "$S/awake-driver.sh" <<'DRIVER'
set -u
set -o pipefail
. "$1/lib/lifecycle.sh" || exit 3
/bin/sleep 30 &
other=$!
LIFECYCLE_AWAKE_PID=$other
lifecycle_release_awake
if kill -0 "$other" 2>/dev/null; then printf 'foreign=spared\n'; else printf 'foreign=signalled\n'; fi
printf 'cleared=[%s]\n' "$LIFECYCLE_AWAKE_PID"
kill "$other" 2>/dev/null
wait "$other" 2>/dev/null
"$2/named/caffeinate" 30 &
own=$!
tries=0
until pgrep -P "$$" -x caffeinate 2>/dev/null | grep -x -e "$own" >/dev/null || [ "$tries" -ge 50 ]; do
  sleep 0.1
  tries=$((tries + 1))
done
LIFECYCLE_AWAKE_PID=$own
lifecycle_release_awake
if kill -0 "$own" 2>/dev/null; then printf 'own=running\n'; kill "$own" 2>/dev/null; else printf 'own=stopped\n'; fi
wait "$own" 2>/dev/null
exit 0
DRIVER
OUT=$S/out-awake.txt
env -i HOME="$HOME_DIR" PATH=/usr/bin:/bin /bin/bash "$S/awake-driver.sh" "$REPO" "$S" > "$OUT" 2>&1
RC=$?
check_status "keep-awake release: the driver exits 0" 0
check_out_has "keep-awake release: a saved number that now names another child is not signalled" '^foreign=spared$'
check_out_has "keep-awake release: the saved number is cleared" '^cleared=\[\]$'
check_out_has "keep-awake release control: its own caffeinate child is stopped" '^own=stopped$'

printf '== install and uninstall stop at a pass in progress, which their dry runs do not see\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "pass in progress: the first install exits 0" 0
hold_lock
reset_calls
run_script "$REPO/install.sh" --dry-run
check_status "pass in progress: the install dry run exits 0" 0
run_script "$REPO/install.sh"
check_status "pass in progress: install exits 1" 1
check_out_has "pass in progress: install says why" 'A weekly-update pass is running right now'
run_script "$REPO/uninstall.sh" --dry-run
check_status "pass in progress: the uninstall dry run exits 0" 0
run_script "$REPO/uninstall.sh"
check_status "pass in progress: uninstall exits 1" 1
check_out_has "pass in progress: uninstall says why" 'A weekly-update pass is running right now'
check_calls_lacks "pass in progress: nothing is unloaded" '^launchctl bootout'
testing_check "pass in progress: the LaunchAgent stays" yes "$( [ -f "$HOME_DIR/Library/LaunchAgents/local.tester.weekly-update.plist" ] && printf yes || printf no )"
release_holder

testing_verdict
