#!/bin/bash
# test-gate.sh: the static tripwire (bin/weekly-update-verify) and its probes.
# Each probe copies a shipped file, breaks one thing, and must make the gate
# print a FAIL line that the unbroken file does not print. A probe only counts
# after a passing baseline, so a gate that never fires cannot pass here. Every
# deny rule in rules/ must have a probe that bites; the last check enforces it.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # probe lines are literal source text, so a $ in them must not expand
set -u
set -o pipefail
# shellcheck source=harness.sh
. "${0%/*}/harness.sh"

# mutate SOURCE FUNCTION ACTION FIXED [LINE]: copy SOURCE, and in FUNCTION (or
# the whole file for -) delete, replace, or add LINE after or before the first
# line that contains FIXED. Prints the mutant's path.
mutate() {
  local source=$1 mutant
  mutant=$S/mutant-$RANDOM$RANDOM-${source##*/}
  if MUTATE_FUNCTION=$2 MUTATE_ACTION=$3 MUTATE_FIXED=$4 MUTATE_LINE=${5:-} LC_ALL=C awk '
    BEGIN { fn = ENVIRON["MUTATE_FUNCTION"]; action = ENVIRON["MUTATE_ACTION"]; fixed = ENVIRON["MUTATE_FIXED"]; repl = ENVIRON["MUTATE_LINE"]; inside = (fn == "-") }
    fn != "-" && index($0, fn "() {") == 1 { inside = 1 }
    !done && inside && index($0, fixed) {
      done = 1
      if (action == "delete") next
      if (action == "replace") { print repl; next }
      if (action == "after") { print; print repl; next }
      if (action == "before") { print repl; print; next }
    }
    fn != "-" && inside && $0 == "}" { inside = 0 }
    { print }
    END { if (!done) exit 3 }' "$source" > "$mutant"; then
    :
  else
    printf 'mutate: "%s" not found in %s of %s\n' "$4" "$2" "$source" >&2
  fi
  printf '%s' "$mutant"
}

RULE_PROBES=" "

# A biting probe whose pattern is "DENY id " covers that deny rule of KIND.
note_rule() {
  case $2 in
    'DENY '*' ') RULE_PROBES="$RULE_PROBES$1:${2#DENY }" ;;
  esac
}

probe_runtime() {
  local label=$1 pattern=$2 mutant output
  shift 2
  mutant=$(mutate "$REPO/bin/weekly-update" "$@")
  output=$(/bin/bash "$VERIFY" --runtime "$mutant" 2>&1)
  testing_expect_fail "$label" "$output" "$pattern" && note_rule runtime "$pattern"
}

# probe_file KIND SOURCE LABEL PATTERN FUNCTION ACTION FIXED [LINE], where KIND
# names the rules file: install, uninstall or verify.
probe_file() {
  local kind=$1 source=$2 label=$3 pattern=$4 option output
  shift 4
  option=--$kind
  [ "$kind" != verify ] || option=--verifier
  output=$(/bin/bash "$VERIFY" "$option" "$(mutate "$source" "$@")" 2>&1)
  testing_expect_fail "$label" "$output" "$pattern" && note_rule "$kind" "$pattern"
}

printf '== the gate passes on the shipped tree\n'
new_sandbox
basic_fixture
run_script "$VERIFY"
check_status "full gate on the repository exits 0" 0
check_out_has "full gate ran the denylist" '^PASS V2 denylist \(weekly-update, runtime\.rules\)'
check_out_has "full gate ran the I8 sudo check" '^PASS V3 every sudo is inside consent_restart or phase_macos'
check_out_has "full gate checked the rendering" '^PASS V4 I9 rendering of the current config: RunAtLoad is false'
check_out_has "full gate checked lib" '^PASS V5 lib/ matches lib/MANIFEST\.sha256'
check_out_has "full gate checked the tripwire's own redirects" '^PASS V2 no overwriting redirect in weekly-update-verify$'
check_out_lacks "full gate has no FAIL" '^FAIL'
run_wu verify
check_status "weekly-update verify runs the tripwire and exits 0" 0
check_out_has "weekly-update verify prints the tripwire's result" '^RESULT: PASS'

printf '== the tripwire exit statuses\n'
/bin/bash "$VERIFY" --runtime "$(mutate "$REPO/bin/weekly-update" upgrade_cask after 'upgrade_cask() {' '  /bin/rm -rf "$HOME/x"')" >/dev/null 2>&1
testing_check "a failed check exits 1" 1 "$?"
/bin/bash "$VERIFY" --runtime >/dev/null 2>&1
testing_check "an option without its file exits 2" 2 "$?"
/bin/bash "$VERIFY" --bogus >/dev/null 2>&1
testing_check "an unknown option exits 2" 2 "$?"

printf '== runtime probes: the denylist\n'
baseline=$(/bin/bash "$VERIFY" --runtime "$REPO/bin/weekly-update" 2>&1)
testing_baseline "runtime" "$?" "$baseline"
probe_runtime "absolute-path rm" 'DENY delete-or-move ' upgrade_cask after 'upgrade_cask() {' '  /bin/rm -rf "$HOME/x"'
probe_runtime "rm behind if" 'DENY delete-or-move ' upgrade_cask after 'upgrade_cask() {' '  if rm -f "$HOME/x"; then :; fi'
probe_runtime "rm behind command" 'DENY delete-or-move ' upgrade_cask after 'upgrade_cask() {' '  command rm "$HOME/x"'
probe_runtime "mv in a pipeline" 'DENY delete-or-move ' upgrade_cask after 'upgrade_cask() {' '  true && mv "$HOME/a" "$HOME/b"'
probe_runtime "an interpreter" 'DENY interpreter ' upgrade_cask after 'upgrade_cask() {' '  python3 -c "print(1)"'
probe_runtime "eval" 'DENY eval ' upgrade_cask after 'upgrade_cask() {' '  eval "true"'
probe_runtime "\${BREW}" 'DENY brew-variable ' upgrade_cask after 'upgrade_cask() {' '  "${BREW}" upgrade --cask x'
probe_runtime "a clobbering redirect" 'DENY clobber ' upgrade_cask after 'upgrade_cask() {' '  printf x >| "$HOME/x"'
probe_runtime "shell tracing" 'DENY trace ' upgrade_cask after 'upgrade_cask() {' '  set -x'
probe_runtime "defaults write" 'DENY defaults-write ' upgrade_cask after 'upgrade_cask() {' '  defaults write com.example.x key -bool true'
probe_runtime "plutil editing a file" 'DENY plutil-edit ' upgrade_cask after 'upgrade_cask() {' '  plutil -replace key -string y "$HOME/x.plist"'
probe_runtime "find -delete" 'DENY find-delete ' upgrade_cask after 'upgrade_cask() {' '  find "$HOME/x" -name y -delete'
probe_runtime "sed -i with a suffix" 'DENY in-place ' upgrade_cask after 'upgrade_cask() {' '  sed -i.bak s/a/b/ "$HOME/x"'
probe_runtime "--greedy" 'DENY dangerous-flag ' upgrade_cask after 'upgrade_cask() {' '  brew outdated --cask --greedy'
probe_runtime "launchctl bootout in the runtime" 'DENY launchctl-change ' mode_status after 'mode_status() {' '  launchctl bootout "gui/501/x"'
probe_runtime "tee without -a" 'DENY tee ' upgrade_cask after 'upgrade_cask() {' '  printf x | tee "$HOME/x"'
probe_runtime "a brew verb outside the allowlist" 'DENY brew-verb ' upgrade_cask after 'upgrade_cask() {' '  brew cleanup'
probe_runtime "a literal Homebrew prefix" 'DENY brew-path ' upgrade_cask after 'upgrade_cask() {' '  ls /opt/homebrew/Caskroom'
probe_runtime "softwareupdate -a" 'DENY softwareupdate-all ' phase_macos after 'phase_macos() {' '  sudo softwareupdate -i -a'
probe_runtime "another osascript form" 'DENY osascript ' reopen_app after 'reopen_app() {' '  osascript -e "tell application \"Finder\" to empty the trash"'
probe_runtime "another open form" 'DENY open ' reopen_app after 'reopen_app() {' '  open -a Safari'
probe_runtime "pmset changing a setting" 'DENY pmset-change ' upgrade_cask after 'upgrade_cask() {' '  pmset -a sleep 0'
probe_runtime "caffeinate outside the library" 'DENY caffeinate ' upgrade_cask after 'upgrade_cask() {' '  caffeinate -i true'
probe_runtime "an overwriting redirect" '^FAIL V2 [^ ]*weekly-update has a redirect' record_nudge after 'record_nudge() {' '  printf x > "$NUDGE_LEDGER"'

printf '== runtime probes: structure\n'
probe_runtime "the global --no-binaries export restored" '^FAIL V3 HOMEBREW_CASK_OPTS must be unset' - replace 'unset HOMEBREW_CASK_OPTS' 'export HOMEBREW_CASK_OPTS="--no-binaries"'
probe_runtime "cask options set later in the file" '^FAIL V3 HOMEBREW_CASK_OPTS must be unset' - after 'SEP=$' 'export HOMEBREW_CASK_OPTS="--no-binaries"'
probe_runtime "cask options no longer cleared" '^FAIL V3 HOMEBREW_CASK_OPTS must be unset' - delete 'unset HOMEBREW_CASK_OPTS'
probe_runtime "--no-binaries dropped from the adoption" '^FAIL V3 adopt: without command-line links' adopt_cask replace 'brew install --cask --adopt --no-binaries' '  if run_never_killed "Homebrew adoption of $name" brew install --cask --adopt "$token"; then'
probe_runtime "cleanup export deleted" '^FAIL V3 export HOMEBREW_NO_INSTALL_CLEANUP' - delete 'export HOMEBREW_NO_INSTALL_CLEANUP=1'
probe_runtime "autoremove export deleted" '^FAIL V3 export HOMEBREW_NO_AUTOREMOVE' - delete 'export HOMEBREW_NO_AUTOREMOVE=1'
probe_runtime "install-upgrade export deleted" '^FAIL V3 export HOMEBREW_NO_INSTALL_UPGRADE' - delete 'export HOMEBREW_NO_INSTALL_UPGRADE=1'
probe_runtime "adoptable test dropped from adopt_cask" '^FAIL V3 adopt: only casks with no roll-back-capable step' adopt_cask replace 'if [ "${app_confirmed[$i]}" != yes ]' '  if [ "${app_confirmed[$i]}" != yes ] || [ "${app_writable[$i]}" != yes ] || [ "${app_in_apps[$i]}" != yes ]; then'
probe_runtime "adoptable test dropped from setup" '^FAIL V3 setup: adoption is offered only after the adoptable check' mode_setup replace 'app_adoptable[$i]}" != yes' '            elif false; then'
probe_runtime "the adoption allowlist widened" '^FAIL V3 ADOPT_SAFE_KEYS must be assigned once' - replace 'ADOPT_SAFE_KEYS="app' 'ADOPT_SAFE_KEYS="app uninstall zap binary command_wrapper pkg postflight"'
probe_runtime "the adoption allowlist widened later in the file" '^FAIL V3 ADOPT_SAFE_KEYS must be assigned once' - after 'SEP=$' 'ADOPT_SAFE_KEYS="$ADOPT_SAFE_KEYS pkg"'
probe_runtime "the silent allowlist widened" '^FAIL V3 SILENT_SAFE_KEYS must be assigned once' - replace 'SILENT_SAFE_KEYS="app' 'SILENT_SAFE_KEYS="app uninstall zap binary command_wrapper bash_completion zsh_completion fish_completion pkg"'
probe_runtime "the link check dropped from upgrade_cask" '^FAIL V3 upgrade_cask: a file in the way of a command-line link stops the upgrade' upgrade_cask replace 'if upgrade_blocked_by_link "$i"; then' '  if false; then'
probe_runtime "a blocked app offered for upgrade" '^FAIL V3 an outdated app with a file in the way is never offered' phase_dock_apps replace 'if upgrade_blocked_by_link "$i"; then' '        if false; then'
probe_runtime "a file in the way no longer blocks adoption" '^FAIL V3 a file in the way of a command-line link blocks adoption' load_dock_inventory replace 'if link_block=$(link_in_the_way "$link_paths"); then' '        if false; then'
probe_runtime "a file in the way left in the silent group" '^FAIL V3 a file in the way of a command-line link keeps the app out of the silent group' load_dock_inventory delete '          silent_safe=no'
probe_runtime "only a missing path counted as free" '^FAIL V3 anything but a link at a link path is in the way' link_in_the_way replace 'if [ -e "$entry" ] && [ ! -L "$entry" ]; then' '    if [ -f "$entry" ] && [ ! -L "$entry" ]; then'
probe_runtime "an unplaceable link path counted as free" '^FAIL V3 a link path that cannot be placed counts as in the way' link_in_the_way replace "'?'*) printf" "      '?'*) continue ;;"
probe_runtime "a file in the way reported as a skip" '^FAIL V3 a file in the way is a failure' upgrade_blocked_by_link replace 'report_failure' '  report_skipped "$(link_block_text "${app_name[$i]}" "$blocker")"'
probe_runtime "a real artifact kind left out of the allowlist check" '^FAIL V3 the artifact kinds must leave out only' - after 'SEP=$' "CASK_QUERY_JQ=\${CASK_QUERY_JQ//'keys[]'/'keys[] | select(. != \"pkg\")'}"
probe_runtime "the target field read as an artifact kind" '^FAIL V3 the artifact kinds must leave out only' - replace "CASK_QUERY_JQ='" "$(LC_ALL=C grep "^CASK_QUERY_JQ='" "$REPO/bin/weekly-update" | LC_ALL=C sed 's/ | select(. != "target")//')"
output=$(/bin/bash "$VERIFY" --runtime "$(mutate "$REPO/bin/weekly-update" load_dock_inventory replace '*) group=assisted ;;' '              *) group=silent ;;')" 2>&1)
testing_expect_fail "any uninstall stanza made silent" "$output" '^FAIL V3 any other uninstall stanza is assisted'
testing_expect_fail "a second silent assignment" "$output" '^FAIL V3 the silent group is assigned in one place: count=2'
probe_runtime "the pkg rule dropped" '^FAIL V3 a cask with a pkg or an artifact off the silent allowlist is assisted' load_dock_inventory replace 'elif [ "${pkg_count:-0}" != 0 ]' '          elif false; then'
probe_runtime "the app-name rule dropped" '^FAIL V3 a cask whose app name differs from the bundle is manual' load_dock_inventory replace 'if [ "$cask_app" != "${path##*/}" ]; then' '          if false; then'
probe_runtime "an upgrade that a closed window can stop" '^FAIL V3 replacing an app starts with HUP, INT and TERM ignored' run_never_killed replace "( trap '' HUP INT TERM; exec" '  "$@" >>"$RUN_SINK" 2>&1 8<&- 9>&- &'
probe_runtime "TERM no longer ignored by a replacement" '^FAIL V3 replacing an app starts with HUP, INT and TERM ignored' run_never_killed replace "( trap '' HUP INT TERM; exec" "  ( trap '' HUP INT; exec \"\$@\" ) >>\"\$RUN_SINK\" 2>&1 8<&- 9>&- &"
probe_runtime "stale records reported after a failed outdated query" '^FAIL V3 stale-record warnings only after a successful outdated query' phase_dock_apps replace '[ "$query_ok" = 0 ] || report_stale_records' '  report_stale_records "$outdated"'
probe_runtime "check calling records stale without asking brew outdated" '^FAIL V3 check warns of a stale record only' mode_check replace 'if query_outdated; then' '  if true; then'
probe_runtime "an unreadable Dock treated as empty" '^FAIL V3 unreadable Dock preferences are a failure' load_dock_inventory replace '"query(dock)"' '    count=0'
probe_runtime "an unreadable macOS listing reported as a warning" '^FAIL V3 an unreadable macOS listing is a failure' phase_macos replace '"query(softwareupdate)"' '    report_warning "The update listing could not be read"'
probe_runtime "only the main executable counted as running" '^FAIL V3 any process started from inside the bundle counts' app_is_running replace 'pgrep -q -f' '  pgrep -q -f "^$(ere_escape "$1")/Contents/MacOS/"'
probe_runtime "an unwritable history file ignored" '^FAIL V3 a history file that cannot be written stops the pass' preflight replace '! -w "$HISTORY_FILE"' '  if false; then'
probe_runtime "a pgrep error read as not running" '^FAIL V3 an app whose running state is unknown counts as running' app_is_running replace '[ "$status" -ne 1 ]' '  [ "$status" -eq 0 ]'
probe_runtime "a second quit site" '^FAIL V3 app quit once, inside quit_app_gracefully: count=2' reopen_app after 'reopen_app() {' '  osascript -e "tell application id \"$bundle\" to quit" >>"$RUN_SINK" 2>&1'
probe_runtime "--restart removed from consent_restart" '^FAIL V3 --restart once, inside consent_restart' consent_restart replace '--restart --agree-to-license' '    if ! sudo softwareupdate --install "$label" --agree-to-license; then'
probe_runtime "the macOS install question removed" '^FAIL V3 phase_macos: the install question comes before the first sudo' phase_macos replace 'recommended macOS update(s) listed above?' '  if false; then'
probe_runtime "I8 auto switched to live" '^FAIL V3 I8 the unattended pass (never installs|lists)' mode_auto replace 'phase_macos dry' '  phase_macos live'
probe_runtime "I8 live-only return deleted" '^FAIL V3 I8 phase_macos returns before any sudo' phase_macos delete '[ "$live" = live ] || return 0'
probe_runtime "I8 sudo added to the app phase" '^FAIL V3 sudo outside consent_restart and phase_macos' phase_dock_apps after 'phase_dock_apps() {' '  sudo true'
probe_runtime "PATH with the Homebrew bin first" '^FAIL V3 PATH must be assigned' - replace 'export PATH="/usr/bin:/bin:/usr/sbin:/sbin${BREW_BIN:+:$BREW_BIN}"' 'export PATH="${BREW_BIN:+$BREW_BIN:}/usr/bin:/bin:/usr/sbin:/sbin"'
probe_runtime "BREW_BIN from the environment" '^FAIL V3 BREW_BIN may only be assigned' - replace '  BREW_BIN=""' '  BREW_BIN=${WEEKLY_BREW:-}'
probe_runtime "dry-run guard removed from upgrade_cask" '^FAIL V3 upgrade_cask: the dry-run guard precedes the upgrade' upgrade_cask replace 'if [ "$DRY_RUN" = 1 ]; then' '  if false; then'
probe_runtime "dry-run guard removed from open_window" '^FAIL V3 window: the dry-run guard precedes the window' open_window replace 'if [ "$DRY_RUN" = 1 ]; then' '  if false; then'
probe_runtime "auto guard removed from upgrade_cask" '^FAIL V3 upgrade_cask: the unattended pass returns before any quit' upgrade_cask replace 'if [ "$MODE" = auto ]; then' '    if false; then'
probe_runtime "auto guard removed from the quit" '^FAIL V3 quit: refused in the unattended pass' quit_app_gracefully replace 'if [ "$MODE" = auto ]; then' '  if false; then'
probe_runtime "Homebrew's own quit left on in auto" '^FAIL V3 I1 Homebrew' mode_auto delete 'export HOMEBREW_NO_UPGRADE_QUIT_CASKS=1'
probe_runtime "setup without the preflight" '^FAIL V3 setup uses the shared preflight' mode_setup delete '  preflight'
probe_runtime "preflight without the lock" '^FAIL V3 I7 the shared preflight takes the run lock' preflight delete 'take_lock_or_stand_down'
probe_runtime "every lock status treated as busy" '^FAIL V3 I7 only lock status 75 means busy' take_lock_or_stand_down replace '-eq 75' '  [ "$status" -ne 0 ] || return 0'
probe_runtime "a row written before the decision" '^FAIL V3 mode_auto writes a history row' mode_auto after '  phase_dock_apps' '  report_history completed "before the decision"'
probe_runtime "deferrals made terminal" '^FAIL V3 TERMINAL_OUTCOMES' - replace 'TERMINAL_OUTCOMES="completed partial escalated declined started"' 'TERMINAL_OUTCOMES="completed partial escalated declined started escalation deferred"'
probe_runtime "I6 window without the presence check" '^FAIL V3 I6 no window opens unless someone is at the Mac' auto_finish replace 'if ! user_is_at_the_mac; then' '  if false; then'
probe_runtime "lock kept through the closing prompt" '^FAIL V3 the lock is released before the closing prompt' mode_scheduled delete '  lifecycle_release_lock'
probe_runtime "keep-awake kept through the closing prompt" '^FAIL V3 keep-awake stops before the closing prompt' mode_scheduled delete '  lifecycle_release_awake'
probe_runtime "outdated status ignored" '^FAIL V3 the outdated query checks its exit status' query_outdated replace 'status=$?' '  status=0'
probe_runtime "I3 restart request not recorded first" '^FAIL V3 I3 the restart request is on record' consent_restart delete 'report_history restart-requested'
probe_runtime "a consent that defaults to yes" '^FAIL V3 a consent question defaults to yes' phase_nudge replace 'own updaters fetch?" no' '  if ! prompt_consent "Open these $count app(s) now so their own updaters fetch?" yes; then'
probe_runtime "a nudge not recorded before the open" '^FAIL V3 every attempt is recorded before the app is opened' phase_nudge delete 'record_nudge "${app_name[$i]}" "${app_version[$i]}" attempt'
probe_runtime "the escalation run in a subshell" '^FAIL V3 compute_escalation must never run in a command substitution' mode_auto after '  compute_escalation' '  reasons=$(compute_escalation)'
probe_runtime "a WU_TEST read outside the seam" '^FAIL V3 WU_TEST is read outside apply_test_seams' mode_auto after 'mode_auto() {' '  [ -z "${WU_TEST:-}" ] || :'
probe_runtime "an env shebang" '^FAIL V1 [^ ]*weekly-update must start with #!/bin/bash' - replace '#!/bin/bash' '#!/usr/bin/env bash'
probe_runtime "a syntax error" '^FAIL V1 syntax' upgrade_cask after 'upgrade_cask() {' '  if then'
probe_runtime "an indented function definition" '^FAIL V3 function layout' mode_auto after 'mode_auto() {' '  helper() { :; }'

printf '== template and plist probes (I9)\n'
baseline=$(/bin/bash "$VERIFY" --template "$REPO/templates/launchagent.plist.template" 2>&1)
testing_baseline "template" "$?" "$baseline"
output=$(/bin/bash "$VERIFY" --template "$(mutate "$REPO/templates/launchagent.plist.template" - replace '<false/>' '	<true/>')" 2>&1)
testing_expect_fail "template RunAtLoad true" "$output" '^FAIL V4 I9 the template must write <key>RunAtLoad</key>'
output=$(/bin/bash "$VERIFY" --template "$(mutate "$REPO/templates/launchagent.plist.template" - replace '<string>Aqua</string>' '	<string>Background</string>')" 2>&1)
testing_expect_fail "template session type changed" "$output" '^FAIL V4 I9 the template must write LimitLoadToSessionType Aqua'
output=$(/bin/bash "$VERIFY" --template "$(mutate "$REPO/templates/launchagent.plist.template" - before '</dict>' '	<key>KeepAlive</key><true/>')" 2>&1)
testing_expect_fail "template KeepAlive added" "$output" '^FAIL V4 I9 the template must not name KeepAlive'

run_wu plist
cp "$OUT" "$S/rendered.plist"
baseline=$(seam_env /bin/bash "$VERIFY" --plist "$S/rendered.plist" 2>&1)
testing_baseline "rendered plist" "$?" "$baseline"
output=$(seam_env /bin/bash "$VERIFY" --plist "$(mutate "$S/rendered.plist" - replace '<false/>' '	<true/>')" 2>&1)
testing_expect_fail "rendered RunAtLoad true" "$output" '^FAIL V4 I9 .*RunAtLoad must be present and false'
output=$(seam_env /bin/bash "$VERIFY" --plist "$(mutate "$S/rendered.plist" - before '	<key>RunAtLoad</key>' '	<key>KeepAlive</key><true/>')" 2>&1)
testing_expect_fail "rendered KeepAlive added" "$output" '^FAIL V4 I9 .*KeepAlive implies RunAtLoad'
output=$(seam_env /bin/bash "$VERIFY" --plist "$(mutate "$S/rendered.plist" - replace '<string>Aqua</string>' '	<string>Background</string>')" 2>&1)
testing_expect_fail "rendered session type changed" "$output" '^FAIL V4 I9 .*LimitLoadToSessionType must be Aqua'
output=$(seam_env /bin/bash "$VERIFY" --plist "$(mutate "$S/rendered.plist" - replace '<string>auto</string>' '		<string>run</string>')" 2>&1)
testing_expect_fail "rendered program changed" "$output" '^FAIL V4 .*ProgramArguments must be exactly'
output=$(seam_env /bin/bash "$VERIFY" --plist "$(mutate "$S/rendered.plist" - before '	<key>RunAtLoad</key>' '	<key>EnvironmentVariables</key><dict><key>PATH</key><string>/tmp</string></dict>')" 2>&1)
testing_expect_fail "rendered environment injected" "$output" '^FAIL V4 .*EnvironmentVariables must be absent'
write_config '[updater]' 'first_hour = 14' 'last_hour = 15'
run_wu plist
awk '/^\t\t<dict>$/ { n++; if (n == 2) { skip = 1; next } } skip && /^\t\t<\/dict>$/ { skip = 0; next } !skip { print }' "$OUT" > "$S/one-slot.plist"
output=$(seam_env /bin/bash "$VERIFY" --plist "$S/one-slot.plist" 2>&1)
testing_expect_fail "rendered calendar with fewer than two slots" "$output" '^FAIL V4 .*the calendar needs at least two slots|^FAIL V4 .*does not lint'

printf '== install.sh probes\n'
baseline=$(/bin/bash "$VERIFY" --install "$REPO/install.sh" 2>&1)
testing_baseline "install.sh" "$?" "$baseline"
probe_file install "$REPO/install.sh" "install.sh deleting" 'DENY delete ' - after 'mv "$STAGE" "$APP"' 'rm -rf "$ASIDE"'
probe_file install "$REPO/install.sh" "install.sh escalating" 'DENY run-elsewhere ' - after 'mv "$STAGE" "$APP"' 'sudo launchctl bootstrap system "$PLIST"'
probe_file install "$REPO/install.sh" "install.sh running eval" 'DENY eval ' - after 'mv "$STAGE" "$APP"' 'eval "$LABEL"'
probe_file install "$REPO/install.sh" "install.sh clobbering" 'DENY clobber ' - after 'mv "$STAGE" "$APP"' 'printf x >| "$PLIST"'
probe_file install "$REPO/install.sh" "install.sh copying something else" 'DENY copy ' - after 'mv "$STAGE" "$APP"' 'cp "$HOME/Documents/x" "$APP/"'
probe_file install "$REPO/install.sh" "install.sh moving something else" 'DENY move ' - after 'mv "$STAGE" "$APP"' 'mv "$HOME/Documents" "$ASIDE/"'
probe_file install "$REPO/install.sh" "install.sh changing other permissions" 'DENY chmod ' - after 'mv "$STAGE" "$APP"' 'chmod 777 "$APP"'
probe_file install "$REPO/install.sh" "install.sh unloading another agent" 'DENY launchctl-change ' - after 'mv "$STAGE" "$APP"' 'launchctl bootout "gui/$USER_ID/com.example.other"'

printf '== uninstaller probes\n'
baseline=$(/bin/bash "$VERIFY" --uninstall "$REPO/bin/weekly-update-uninstall" 2>&1)
testing_baseline "uninstaller" "$?" "$baseline"
probe_file uninstall "$REPO/bin/weekly-update-uninstall" "uninstaller deleting the logs" 'DENY delete ' - before 'if ! mkdir -p "$TOOL_HOME" || ! fresh_folder "$DEST_BASE"; then' 'rm -rf "$LOG_DIR"'
probe_file uninstall "$REPO/bin/weekly-update-uninstall" "uninstaller running Homebrew" 'DENY run-elsewhere ' - before 'if ! mkdir -p "$TOOL_HOME" || ! fresh_folder "$DEST_BASE"; then' 'brew cleanup'
probe_file uninstall "$REPO/bin/weekly-update-uninstall" "uninstaller running eval" 'DENY eval ' - before 'if ! mkdir -p "$TOOL_HOME" || ! fresh_folder "$DEST_BASE"; then' 'eval "$LABEL"'
probe_file uninstall "$REPO/bin/weekly-update-uninstall" "uninstaller clobbering" 'DENY clobber ' - before 'if ! mkdir -p "$TOOL_HOME" || ! fresh_folder "$DEST_BASE"; then' 'printf x >| "$PLIST"'
probe_file uninstall "$REPO/bin/weekly-update-uninstall" "uninstaller unloading another agent" 'DENY launchctl-change ' - before 'if ! mkdir -p "$TOOL_HOME" || ! fresh_folder "$DEST_BASE"; then' 'launchctl bootout "gui/$USER_ID/com.other.agent"'
probe_file uninstall "$REPO/bin/weekly-update-uninstall" "uninstaller moving the logs" 'DENY move ' - before 'if ! mkdir -p "$TOOL_HOME" || ! fresh_folder "$DEST_BASE"; then' 'mv "$LOG_DIR" "$DEST/"'

printf '== verify probes: the tripwire itself only reads\n'
baseline=$(/bin/bash "$VERIFY" --verifier "$VERIFY" 2>&1)
testing_baseline "verify" "$?" "$baseline"
probe_file verify "$VERIFY" "verify deleting" 'DENY write-or-delete ' full_check after 'full_check() {' '  rm -f "$HOME/x"'
probe_file verify "$VERIFY" "verify running launchctl" 'DENY run-elsewhere ' full_check after 'full_check() {' '  launchctl print system'
probe_file verify "$VERIFY" "verify running eval" 'DENY eval ' full_check after 'full_check() {' '  eval "true"'
probe_file verify "$VERIFY" "verify clobbering" 'DENY clobber ' full_check after 'full_check() {' '  printf x >| "$HOME/x"'
probe_file verify "$VERIFY" "verify editing in place" 'DENY in-place ' full_check after 'full_check() {' '  sed -i.bak s/a/b/ "$HOME/x"'
probe_file verify "$VERIFY" "verify appending to a file" '^FAIL V2 .*has a redirect' full_check after 'full_check() {' '  printf x >> "$HOME/x"'

printf '== installed-copy probes: the launcher byte compare and the manifest\n'
new_sandbox
basic_fixture
install_into_sandbox
app=$HOME_DIR/.local/share/weekly-update/app
run_script "$app/bin/weekly-update-verify"
testing_baseline "installed copy" "$RC" "$(cat "$OUT")"
printf 'touch "$HOME/also-this"\n' >> "$app/bin/weekly-update-scheduled"
run_script "$app/bin/weekly-update-verify"
testing_expect_fail "launcher with an extra line" "$(cat "$OUT")" '^FAIL V2 the window launcher must be exactly'
testing_expect_fail "launcher change seen by the manifest" "$(cat "$OUT")" '^FAIL V5 changed or missing since install: .*weekly-update-scheduled'
printf '# edited\n' >> "$app/bin/weekly-update"
run_script "$app/bin/weekly-update-verify"
testing_expect_fail "runtime edited after install" "$(cat "$OUT")" '^FAIL V5 changed or missing since install: .*/bin/weekly-update$'

printf '== every deny rule in rules/ has a probe that bites\n'
missing=""
for kind in runtime install uninstall verify; do
  while read -r id; do
    case $RULE_PROBES in
      *" $kind:$id "*) ;;
      *) missing="$missing $kind:$id" ;;
    esac
  done <<EOF
$(LC_ALL=C awk '$1 == "deny" { print $2 }' "$REPO/rules/$kind.rules")
EOF
done
testing_check "deny rules without a biting probe" "" "$missing"

testing_verdict
