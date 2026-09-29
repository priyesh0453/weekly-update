#!/bin/bash
# test-install.sh: install and uninstall scenarios, S17 (I9). Install renders
# the LaunchAgent exactly, the installed copy passes the tripwire, and
# uninstall moves everything aside and verifies; the rest are the ownership
# rules for LaunchAgents with this tool's suffix that it did or did not write.
# shellcheck source-path=SCRIPTDIR
set -u
set -o pipefail
# shellcheck source=harness.sh
. "${0%/*}/harness.sh"

app_dir() { printf '%s' "$HOME_DIR/.local/share/weekly-update/app"; }
plist_path() { printf '%s' "$HOME_DIR/Library/LaunchAgents/$1.plist"; }
plist_key() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
# Every path under the sandbox home, then every file's checksum, so a run that
# writes, adds or removes anything there changes the snapshot.
home_snapshot() { (cd "$HOME_DIR" && find . | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }

printf '== install.sh and the uninstaller carry the same ownership helper\n'
helper_block() {
  awk '/^RUNTIME_SUFFIX=/ { on = 1 } on { print } on && /^program_owner\(\)/ { inside = 1 } inside && /^}$/ { exit }' "$1"
}
install_helper=$(helper_block "$REPO/install.sh")
uninstall_helper=$(helper_block "$REPO/bin/weekly-update-uninstall")
testing_check "the helper in install.sh defines both functions" 2 "$(printf '%s\n' "$install_helper" | LC_ALL=C grep -c -E '^(is_our_program|program_owner)\(\) \{$')"
testing_check "the two copies of the ownership helper are identical" same "$( [ "$install_helper" = "$uninstall_helper" ] && printf same || printf different )"
strip_block() { awk '/^while :; do$/ { on = 1 } on { print } on && /^export HOME$/ { exit }' "$1"; }
testing_check "install.sh and the uninstaller strip the trailing slash from HOME the same way" same "$( [ -n "$(strip_block "$REPO/install.sh")" ] && [ "$(strip_block "$REPO/install.sh")" = "$(strip_block "$REPO/bin/weekly-update-uninstall")" ] && printf same || printf different )"

printf '== S17 install --dry-run writes nothing\n'
new_sandbox
basic_fixture
before=$(home_snapshot)
run_script "$REPO/install.sh" --dry-run
check_status "S17 dry run exits 0" 0
testing_check "S17 dry run on a fresh home: the home is unchanged" "$before" "$(home_snapshot)"
testing_check "S17 dry run: no tool copy" no "$( [ -e "$(app_dir)" ] && printf yes || printf no )"
testing_check "S17 dry run: no LaunchAgent" 0 "$(find "$HOME_DIR/Library/LaunchAgents" -type f | wc -l | tr -d ' ')"
check_calls_lacks "S17 dry run: nothing loaded" '^launchctl (bootstrap|enable|bootout)'
run_script "$REPO/install.sh" --help
check_status "install --help exits 0" 0
check_out_has "install --help lists --dry-run" '^  --dry-run  '
check_out_has "install --help lists --help" '^  --help  '
run_script "$REPO/bin/weekly-update-uninstall" --help
check_status "uninstaller --help exits 0" 0
check_out_has "uninstaller --help lists --dry-run" '^  --dry-run  '
check_out_has "uninstaller --help lists --help" '^  --help  '

printf '== S17 install renders the LaunchAgent exactly (I9)\n'
run_script "$REPO/install.sh"
check_status "S17 install exits 0" 0
plist=$(plist_path local.tester.weekly-update)
testing_check "S17 the LaunchAgent exists" yes "$( [ -f "$plist" ] && printf yes || printf no )"
plutil -lint "$plist" >/dev/null 2>&1
testing_check "S17 the LaunchAgent lints" 0 "$?"
testing_check "S17 RunAtLoad is false" false "$(plist_key "$plist" RunAtLoad)"
testing_check "S17 LimitLoadToSessionType is Aqua" Aqua "$(plist_key "$plist" LimitLoadToSessionType)"
testing_check "S17 KeepAlive is absent" absent "$(plist_key "$plist" KeepAlive >/dev/null && printf present || printf absent)"
testing_check "S17 the label comes from the login name" local.tester.weekly-update "$(plist_key "$plist" Label)"
testing_check "S17 the program is the installed runtime" "$(app_dir)/bin/weekly-update" "$(plist_key "$plist" ProgramArguments.0)"
testing_check "S17 in auto mode" auto "$(plist_key "$plist" ProgramArguments.1)"
testing_check "S17 eight Sunday slots by default" 8 "$(plist_key "$plist" StartCalendarInterval)"
testing_check "S17 first slot 14:00" "0 14 0" "$(plist_key "$plist" StartCalendarInterval.0.Weekday) $(plist_key "$plist" StartCalendarInterval.0.Hour) $(plist_key "$plist" StartCalendarInterval.0.Minute)"
testing_check "S17 last slot 21:00" 21 "$(plist_key "$plist" StartCalendarInterval.7.Hour)"
testing_check "S17 logs under the log folder" "$HOME_DIR/Library/Logs/weekly-update/launchd.log" "$(plist_key "$plist" StandardErrorPath)"
testing_check "S17 the schedule is loaded" yes "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"
check_calls_has "S17 loaded with bootstrap" "^launchctl bootstrap gui/501 $plist\$"
testing_check "S17 the window launcher only execs the runtime" "$(printf '#!/bin/bash\nexec %q scheduled' "$(app_dir)/bin/weekly-update")" "$(cat "$(app_dir)/bin/weekly-update-scheduled")"
check_file_has "S17 the manifest records the label" "$(app_dir)/install-manifest.tsv" '^label	local\.tester\.weekly-update$'
check_calls_lacks "S17 install runs no update tool" '^(brew (update|upgrade|install)|softwareupdate|sudo|osascript)'

printf '== S17 the installed copy passes its own tripwire, and status agrees\n'
run_script "$(app_dir)/bin/weekly-update-verify"
check_status "S17 installed verify exits 0" 0
check_out_has "S17 verify compared the LaunchAgent on disk" 'PASS V4 the LaunchAgent on disk equals the rendering'
check_out_has "S17 verify byte-compared the launcher" 'PASS V2 the window launcher only execs the runtime'
RUNTIME=$(app_dir)/bin/weekly-update
before=$(home_snapshot)
run_wu status
check_status "S17 status exits 0" 0
testing_check "S17 status writes nothing" "$before" "$(home_snapshot)"
check_out_has "S17 status: loaded" 'The schedule is loaded'
check_out_has "S17 status: on disk matches the config" 'The LaunchAgent on disk matches this config'
run_wu plist
check_status "S17 plist exits 0" 0
testing_check "S17 plist writes nothing" "$before" "$(home_snapshot)"
run_wu check
check_status "S17 check exits 0" 0
testing_check "S17 check writes nothing" "$before" "$(home_snapshot)"
testing_check "S17 the installed copy carries the example config its help names" yes "$( [ -f "$(app_dir)/config/weekly-update.conf.example" ] && printf yes || printf no )"

printf '== S17 a config line cannot turn RunAtLoad on\n'
write_config '[updater]' 'run_at_load = true'
run_wu plist
check_status "S17 run_at_load exits 2" 2
check_out_has "S17 run_at_load is named with file and line" '/\.config/weekly-update/config:2: unknown key run_at_load in \[updater\]'
run_script "$REPO/install.sh"
check_status "S17 install refuses the invalid config with exit 2" 2
check_out_has "S17 install says the LaunchAgent could not be rendered" 'The LaunchAgent could not be rendered \(the lines above say why'
testing_check "S17 the installed LaunchAgent is untouched" false "$(plist_key "$plist" RunAtLoad)"

printf '== S17 reinstall with a new label moves the old files aside\n'
write_config '[updater]' 'label_prefix = com.example' 'first_hour = 9' 'last_hour = 10'
reset_calls
before=$(home_snapshot)
run_script "$REPO/install.sh" --dry-run
check_status "S17 reinstall dry run exits 0" 0
testing_check "S17 reinstall dry run: the home is unchanged" "$before" "$(home_snapshot)"
check_out_has "S17 reinstall dry run names the schedule it would unload" 'Would unload the loaded schedule local\.tester\.weekly-update first'
check_out_has "S17 reinstall dry run names the copy it would move aside" 'Would move the previous copy to .*/replaced-[0-9-]*/app'
check_out_has "S17 reinstall dry run names the LaunchAgent it would move aside" 'Would move the previous LaunchAgent .*/local\.tester\.weekly-update\.plist to '
check_calls_lacks "S17 reinstall dry run unloads nothing" '^launchctl (bootout|bootstrap|enable)'
testing_check "S17 reinstall dry run leaves the old LaunchAgent" yes "$( [ -f "$plist" ] && printf yes || printf no )"
testing_check "S17 reinstall dry run moves nothing aside" 0 "$(find "$HOME_DIR/.local/share/weekly-update" -maxdepth 1 -name 'replaced-*' | wc -l | tr -d ' ')"
run_script "$REPO/install.sh"
check_status "S17 reinstall exits 0" 0
new_plist=$(plist_path com.example.weekly-update)
testing_check "S17 the new LaunchAgent exists" com.example.weekly-update "$(plist_key "$new_plist" Label)"
testing_check "S17 the new calendar follows the config" 2 "$(plist_key "$new_plist" StartCalendarInterval)"
testing_check "S17 the old LaunchAgent left its place" no "$( [ -e "$plist" ] && printf yes || printf no )"
testing_check "S17 the old LaunchAgent was moved, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*replaced-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"
check_calls_has "S17 the old schedule was unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
testing_check "S17 the old schedule is no longer loaded" no "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"

printf '== S17 uninstall moves everything aside and verifies\n'
before=$(home_snapshot)
run_script "$REPO/uninstall.sh" --dry-run
check_status "S17 uninstall dry run exits 0" 0
testing_check "S17 uninstall dry run: the home is unchanged" "$before" "$(home_snapshot)"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "S17 uninstall exits 0" 0
check_out_has "S17 uninstall verified" 'Removed and verified: this tool.s schedule is not loaded, and this tool.s LaunchAgent and the tool copy are gone from their places\.'
testing_check "S17 the tool copy left its place" no "$( [ -e "$(app_dir)" ] && printf yes || printf no )"
testing_check "S17 the LaunchAgent left its place" no "$( [ -e "$new_plist" ] && printf yes || printf no )"
testing_check "S17 the schedule is unloaded" no "$( [ -f "$STATE/launchd/com.example.weekly-update" ] && printf yes || printf no )"
moved=$(find "$HOME_DIR/.local/share/weekly-update" -maxdepth 1 -name 'removed-*' | head -n 1)
testing_check "S17 the moved runtime is present" yes "$( [ -f "$moved/app/bin/weekly-update" ] && printf yes || printf no )"
testing_check "S17 the moved LaunchAgent is present" yes "$( [ -f "$moved/com.example.weekly-update.plist" ] && printf yes || printf no )"
testing_check "S17 the config is kept" yes "$( [ -f "$HOME_DIR/.config/weekly-update/config" ] && printf yes || printf no )"
testing_check "S17 the logs are kept" yes "$( [ -d "$HOME_DIR/Library/Logs/weekly-update" ] && printf yes || printf no )"
check_calls_lacks "S17 uninstall runs no update tool" '^(brew|softwareupdate|sudo|osascript|open)'
run_script "$REPO/uninstall.sh"
check_status "S17 a second uninstall exits 0" 0
check_out_has "S17 a second uninstall finds nothing" 'Nothing is installed'

printf '== uninstall after the tool folder was removed by hand still unloads and moves the LaunchAgent\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "install exits 0" 0
plist=$(plist_path local.tester.weekly-update)
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
reset_calls
run_script "$REPO/uninstall.sh" --dry-run
check_status "no tool folder: the dry run exits 0" 0
check_out_lacks "no tool folder: the dry run does not claim nothing is installed" 'Nothing is installed'
check_out_has "no tool folder: the dry run says the schedule is still here" 'No tool copy at .*, but a weekly-update schedule is still here'
check_out_has "no tool folder: the dry run names the schedule" 'Schedule: +local\.tester\.weekly-update$'
check_out_has "no tool folder: the dry run names the LaunchAgent" 'LaunchAgent: +.*/Library/LaunchAgents/local\.tester\.weekly-update\.plist$'
check_calls_lacks "no tool folder: the dry run unloads nothing" '^launchctl bootout'
testing_check "no tool folder: the dry run leaves the LaunchAgent" yes "$( [ -f "$plist" ] && printf yes || printf no )"
run_script "$REPO/uninstall.sh"
check_status "no tool folder: uninstall exits 0" 0
check_out_has "no tool folder: uninstall verified" 'Removed and verified'
check_calls_has "no tool folder: the schedule was unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
testing_check "no tool folder: the schedule is no longer loaded" no "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"
testing_check "no tool folder: the LaunchAgent left its place" no "$( [ -e "$plist" ] && printf yes || printf no )"
testing_check "no tool folder: the LaunchAgent was moved, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*removed-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"
testing_check "no tool folder: the folder the person moved is untouched" yes "$( [ -f "$HOME_DIR/tool-folder-moved-by-person/app/bin/weekly-update" ] && printf yes || printf no )"
run_script "$REPO/uninstall.sh"
check_status "no tool folder: a second uninstall exits 0" 0
check_out_has "no tool folder: a second uninstall finds nothing and says the schedule is not loaded" 'Nothing is installed: no tool copy at .* and none of this tool.s LaunchAgents in .*, and the schedule local\.tester\.weekly-update is not loaded'

printf '== uninstall unloads the schedule the config names when its LaunchAgent file is gone too\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
mv "$(plist_path local.tester.weekly-update)" "$HOME_DIR/plist-moved-by-person.plist"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "loaded without a file: uninstall exits 0" 0
check_out_lacks "loaded without a file: does not claim nothing is installed" 'Nothing is installed'
check_calls_has "loaded without a file: the schedule was unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
testing_check "loaded without a file: the schedule is no longer loaded" no "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"
check_out_has "loaded without a file: uninstall verified" 'Removed and verified'
testing_check "loaded without a file: the file the person moved is untouched" yes "$( [ -f "$HOME_DIR/plist-moved-by-person.plist" ] && printf yes || printf no )"

printf '== without a tool folder, a LaunchAgent that cannot be moved is named and the uninstall exits 1\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "install exits 0" 0
plist=$(plist_path local.tester.weekly-update)
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
chmod 555 "$HOME_DIR/Library/LaunchAgents"
run_script "$REPO/uninstall.sh"
chmod 755 "$HOME_DIR/Library/LaunchAgents"
check_status "a stuck LaunchAgent: uninstall exits 1" 1
check_out_has "a stuck LaunchAgent: the move failure is named" 'Could not move .*/Library/LaunchAgents/local\.tester\.weekly-update\.plist$'
check_out_has "a stuck LaunchAgent is listed as still present" 'NOT fully removed; still present: .*/Library/LaunchAgents/local\.tester\.weekly-update\.plist$'
check_out_lacks "a stuck LaunchAgent: no success is claimed" 'Removed and verified|Nothing is installed'
testing_check "a stuck LaunchAgent is still in place, not deleted" yes "$( [ -f "$plist" ] && printf yes || printf no )"
run_script "$REPO/uninstall.sh"
check_status "a stuck LaunchAgent: the rerun exits 0" 0
check_out_has "a stuck LaunchAgent: the rerun verified" 'Removed and verified'
testing_check "a stuck LaunchAgent: the rerun moved it" no "$( [ -e "$plist" ] && printf yes || printf no )"

printf '== without a manifest, a LaunchAgent whose label is not its own file name is left alone\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
odd=$HOME_DIR/Library/LaunchAgents/other.weekly-update.plist
mv "$(plist_path local.tester.weekly-update)" "$odd"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "a mismatched LaunchAgent: uninstall exits 1" 1
check_out_has "a mismatched LaunchAgent is named" 'other\.weekly-update\.plist does not carry its own file name as a weekly-update label'
check_calls_lacks "a mismatched LaunchAgent: nothing is unloaded" '^launchctl bootout'
testing_check "a mismatched LaunchAgent stays in place" yes "$( [ -f "$odd" ] && printf yes || printf no )"

printf '== an agent with the same suffix that runs another program is never unloaded or moved\n'
write_foreign_agent() {
  foreign=$HOME_DIR/Library/LaunchAgents/com.example.weekly-update.plist
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>Label</key>\n\t<string>com.example.weekly-update</string>\n\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>/usr/local/bin/my-own-weekly-backup</string>\n\t</array>\n</dict>\n</plist>\n' > "$foreign"
  printf '/usr/local/bin/my-own-weekly-backup\n' > "$STATE/launchd/com.example.weekly-update"
}
new_sandbox
basic_fixture
write_foreign_agent
reset_calls
run_script "$REPO/uninstall.sh"
check_status "a foreign agent, nothing installed: uninstall exits 0" 0
check_out_has "a foreign agent, nothing installed: named as not this tool's" 'com\.example\.weekly-update\.plist runs /usr/local/bin/my-own-weekly-backup, not this tool, so it was left alone'
check_out_has "a foreign agent, nothing installed: nothing is installed" 'Nothing is installed'
check_out_lacks "a foreign agent, nothing installed: claims no removal" 'Removed and verified'
check_calls_lacks "a foreign agent, nothing installed: nothing is unloaded" '^launchctl bootout'
testing_check "a foreign agent, nothing installed: its file stays in place" yes "$( [ -f "$foreign" ] && printf yes || printf no )"
testing_check "a foreign agent, nothing installed: it stays loaded" yes "$( [ -f "$STATE/launchd/com.example.weekly-update" ] && printf yes || printf no )"
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "a foreign agent beside a real one: install exits 0" 0
write_foreign_agent
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "a foreign agent beside a real one: uninstall exits 0" 0
check_out_has "a foreign agent beside a real one: verified" 'Removed and verified'
check_calls_has "a foreign agent beside a real one: this tool's schedule is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
check_calls_lacks "a foreign agent beside a real one: the other schedule is not unloaded" '^launchctl bootout gui/501/com\.example\.weekly-update$'
testing_check "a foreign agent beside a real one: its file stays in place" yes "$( [ -f "$foreign" ] && printf yes || printf no )"
testing_check "a foreign agent beside a real one: it stays loaded" yes "$( [ -f "$STATE/launchd/com.example.weekly-update" ] && printf yes || printf no )"
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "a loaded label that runs another program: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
mv "$(plist_path local.tester.weekly-update)" "$HOME_DIR/plist-moved-by-person.plist"
printf '/usr/local/bin/something-else\n' > "$STATE/launchd/local.tester.weekly-update"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "a loaded label that runs another program: uninstall exits 0" 0
check_out_has "a loaded label that runs another program: named and left alone" 'The schedule local\.tester\.weekly-update is loaded but runs /usr/local/bin/something-else, not this tool, so it was left alone'
check_calls_lacks "a loaded label that runs another program: nothing is unloaded" '^launchctl bootout'
testing_check "a loaded label that runs another program: it stays loaded" yes "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"

printf '== a loaded schedule whose program launchctl does not name stops the uninstall without acting\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "an unnamed program: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
mv "$(plist_path local.tester.weekly-update)" "$HOME_DIR/plist-moved-by-person.plist"
: > "$STATE/launchd/local.tester.weekly-update"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "an unnamed program: uninstall exits 1" 1
check_out_has "an unnamed program: named, and its owner called unknown" 'The schedule local\.tester\.weekly-update is loaded, but launchctl names no program for it that this tool can read, so it is not known whether it belongs to this tool'
check_out_lacks "an unnamed program: does not claim nothing is installed" 'Nothing is installed'
check_calls_lacks "an unnamed program: nothing is unloaded" '^launchctl bootout'
testing_check "an unnamed program: it stays loaded" yes "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"

printf '== an unreadable LaunchAgent with the suffix stops the uninstall without acting\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "unreadable: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
plist=$(plist_path local.tester.weekly-update)
chmod 000 "$plist"
reset_calls
run_script "$REPO/uninstall.sh"
chmod 644 "$plist"
check_status "unreadable: uninstall exits 1" 1
check_out_has "unreadable: names the file and says why" 'local\.tester\.weekly-update\.plist cannot be read, so it is not known whether it belongs to this tool'
check_out_lacks "unreadable: does not claim nothing is installed" 'Nothing is installed'
check_calls_lacks "unreadable: nothing is unloaded" '^launchctl bootout'

printf '== a home folder written with a trailing slash still finds this tool\x27s LaunchAgent\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "trailing slash: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
HOME_DIR_SAVED=$HOME_DIR
HOME_DIR="$HOME_DIR/"
reset_calls
run_script "$REPO/uninstall.sh"
HOME_DIR=$HOME_DIR_SAVED
check_status "trailing slash: uninstall exits 0" 0
check_out_has "trailing slash: verified" 'Removed and verified'
check_calls_has "trailing slash: this tool's schedule is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
check_out_lacks "trailing slash: this tool's LaunchAgent is not called another program's" 'not this tool'
testing_check "trailing slash: the LaunchAgent left its place" no "$( [ -e "$(plist_path local.tester.weekly-update)" ] && printf yes || printf no )"
testing_check "trailing slash: the LaunchAgent was moved, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*removed-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "trailing slash, loaded only: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
mv "$(plist_path local.tester.weekly-update)" "$HOME_DIR/plist-moved-by-person.plist"
HOME_DIR_SAVED=$HOME_DIR
HOME_DIR="$HOME_DIR/"
reset_calls
run_script "$REPO/uninstall.sh"
HOME_DIR=$HOME_DIR_SAVED
check_status "trailing slash, loaded only: uninstall exits 0" 0
check_out_lacks "trailing slash, loaded only: the loaded schedule is not called another program's" 'not this tool'
check_calls_has "trailing slash, loaded only: the loaded schedule is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'

printf '== an invalid config at uninstall time is named instead of silently skipped\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "invalid config: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
mv "$(plist_path local.tester.weekly-update)" "$HOME_DIR/plist-moved-by-person.plist"
write_config '[updater]' 'weekdy = 0'
reset_calls
run_script "$REPO/uninstall.sh"
check_status "invalid config: uninstall exits 1" 1
check_out_has "invalid config: says the label was not checked and why" 'The LaunchAgent could not be rendered, so a loaded schedule under the label the config names was not checked: .*unknown key weekdy'
check_out_lacks "invalid config: does not claim nothing is installed" 'Nothing is installed'
check_calls_lacks "invalid config: nothing is unloaded" '^launchctl bootout'

printf '== a file at this tool\x27s LaunchAgent path that runs another program stays in place\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "same path, other program: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
plist=$(plist_path local.tester.weekly-update)
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>Label</key>\n\t<string>local.tester.weekly-update</string>\n\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>/usr/local/bin/something-else</string>\n\t</array>\n</dict>\n</plist>\n' >| "$plist"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "same path, other program: uninstall exits 0" 0
check_calls_has "same path, other program: this tool's loaded schedule is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
check_out_has "same path, other program: the file is named and left alone" 'local\.tester\.weekly-update\.plist runs /usr/local/bin/something-else, not this tool, so it was left alone'
check_out_lacks "same path, other program: it is not moved" 'LaunchAgent moved'
testing_check "same path, other program: the file is still there" yes "$( [ -f "$plist" ] && printf yes || printf no )"
check_out_has "same path, other program: the summary names the file left in place" 'Left in place, for the reasons named above: .*local\.tester\.weekly-update\.plist'

printf '== with an install manifest, this tool\x27s LaunchAgent is moved whatever its program reads\n'
for variant in unreadable edited linked; do
  new_sandbox
  basic_fixture
  run_script "$REPO/install.sh"
  check_status "$variant: install exits 0" 0
  plist=$(plist_path local.tester.weekly-update)
  case $variant in
    unreadable) chmod 000 "$plist" ;;
    edited) printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>Label</key>\n\t<string>local.tester.weekly-update</string>\n\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>/usr/local/bin/my-wrapper</string>\n\t</array>\n</dict>\n</plist>\n' >| "$plist" ;;
    linked) ln -s "$HOME_DIR" "$S/home-link"; HOME_DIR_SAVED=$HOME_DIR; HOME_DIR=$S/home-link ;;
  esac
  reset_calls
  run_script "$REPO/uninstall.sh"
  [ "$variant" != linked ] || HOME_DIR=$HOME_DIR_SAVED
  check_status "$variant: uninstall exits 0" 0
  check_out_lacks "$variant: the LaunchAgent is not called another program's" 'not this tool'
  check_out_has "$variant: verified" 'Removed and verified'
  testing_check "$variant: the LaunchAgent left its place" no "$( [ -e "$plist" ] || [ -L "$plist" ] && printf yes || printf no )"
  testing_check "$variant: the LaunchAgent was moved, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*removed-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"
done

printf '== an install that cannot write its LaunchAgent stops before it places anything, and promises no load at login\n'
new_sandbox
basic_fixture
chmod 555 "$HOME_DIR/Library/LaunchAgents"
run_script "$REPO/install.sh"
chmod 755 "$HOME_DIR/Library/LaunchAgents"
check_status "no LaunchAgent written: install exits 1" 1
check_out_has "no LaunchAgent written: names the folder it cannot write" 'Cannot write .*/Library/LaunchAgents, where the LaunchAgent goes'
check_out_has "no LaunchAgent written: says nothing was installed" 'Not installed\.'
testing_check "no LaunchAgent written: no tool copy was placed" no "$( [ -e "$(app_dir)" ] && printf yes || printf no )"
check_out_lacks "no LaunchAgent written: no promise of a load at login" 'log in again'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "unwritable LaunchAgents on a reinstall: the first install exits 0" 0
chmod 555 "$HOME_DIR/Library/LaunchAgents"
reset_calls
run_script "$REPO/install.sh"
chmod 755 "$HOME_DIR/Library/LaunchAgents"
check_status "unwritable LaunchAgents on a reinstall: install exits 1" 1
check_calls_lacks "unwritable LaunchAgents on a reinstall: the working schedule is not unloaded" '^launchctl bootout'
testing_check "unwritable LaunchAgents on a reinstall: the schedule stays loaded" yes "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"
testing_check "unwritable LaunchAgents on a reinstall: nothing was moved aside" 0 "$(find "$HOME_DIR/.local/share/weekly-update" -maxdepth 1 -name 'replaced-*' | wc -l | tr -d ' ')"

printf '== install never unloads or moves another program\x27s agent at its label\n'
new_sandbox
basic_fixture
plist=$(plist_path local.tester.weekly-update)
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>Label</key>\n\t<string>local.tester.weekly-update</string>\n\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>/usr/local/bin/my-own-weekly-backup</string>\n\t</array>\n</dict>\n</plist>\n' >| "$plist"
printf '/usr/local/bin/my-own-weekly-backup\n' > "$STATE/launchd/local.tester.weekly-update"
reset_calls
run_script "$REPO/install.sh"
check_status "a foreign agent at the label: install exits 1" 1
check_out_has "a foreign agent at the label: named, nothing touched" 'local\.tester\.weekly-update\.plist runs /usr/local/bin/my-own-weekly-backup, not this tool, so install stopped before unloading or moving it'
check_calls_lacks "a foreign agent at the label: nothing is unloaded" '^launchctl bootout'
testing_check "a foreign agent at the label: its file is untouched" yes "$( [ -f "$plist" ] && LC_ALL=C grep -q my-own-weekly-backup "$plist" && printf yes || printf no )"
testing_check "a foreign agent at the label: no tool copy was placed" no "$( [ -e "$HOME_DIR/.local/share/weekly-update/app" ] && printf yes || printf no )"
run_script "$REPO/install.sh" --dry-run
check_status "a foreign agent at the label: the dry run exits 1 too" 1
new_sandbox
basic_fixture
printf '/usr/local/bin/something-else\n' > "$STATE/launchd/local.tester.weekly-update"
reset_calls
run_script "$REPO/install.sh"
check_status "a foreign schedule loaded at the label: install exits 1" 1
check_out_has "a foreign schedule loaded at the label: named" 'A schedule named local\.tester\.weekly-update is loaded and runs /usr/local/bin/something-else, not this tool, so install stopped before unloading it'
check_calls_lacks "a foreign schedule loaded at the label: nothing is unloaded" '^launchctl bootout'

printf '== with a home folder written with a trailing slash, install, status and the tripwire agree\n'
new_sandbox
basic_fixture
installed=$(app_dir)
HOME_DIR_SAVED=$HOME_DIR
HOME_DIR="$HOME_DIR/"
run_script "$REPO/install.sh"
check_status "trailing slash at install: install exits 0" 0
testing_check "trailing slash at install: no doubled slash in the launcher" 0 "$(LC_ALL=C grep -c '//' "$installed/bin/weekly-update-scheduled")"
run_script "$installed/bin/weekly-update-verify"
check_status "trailing slash at install: the installed tripwire passes under the same home folder" 0
check_out_has "trailing slash at install: the tripwire result is PASS" '^RESULT: PASS$'
run_script "$installed/bin/weekly-update" status
check_status "trailing slash at install: status exits 0" 0
check_out_has "trailing slash at install: status under the same home folder says the LaunchAgent matches" 'The LaunchAgent on disk matches this config'
check_out_lacks "trailing slash at install: status does not call it different" 'differs'
HOME_DIR=$HOME_DIR_SAVED

printf '== without a tool folder, a file at the label that names no ProgramArguments stays while this tool\x27s loaded schedule is unloaded\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "program-only file: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
plist=$(plist_path local.tester.weekly-update)
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>Label</key>\n\t<string>local.tester.weekly-update</string>\n\t<key>Program</key>\n\t<string>/usr/local/bin/person-own</string>\n</dict>\n</plist>\n' >| "$plist"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "program-only file: uninstall exits 0" 0
check_out_has "program-only file: named and left alone" 'local\.tester\.weekly-update\.plist names no ProgramArguments this tool can read, so it was left alone'
check_out_lacks "program-only file: it is not moved" 'LaunchAgent moved'
check_out_has "program-only file: the summary names it" 'Left in place, for the reasons named above: .*local\.tester\.weekly-update\.plist'
check_calls_has "program-only file: this tool's loaded schedule is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
testing_check "program-only file: the file is still at the label path" yes "$( [ -f "$plist" ] && LC_ALL=C grep -q person-own "$plist" && printf yes || printf no )"

printf '== without a tool folder, this tool\x27s LaunchAgent is moved, but a schedule at its label that runs another program stays loaded\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "foreign loaded job: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
plist=$(plist_path local.tester.weekly-update)
printf '/usr/local/bin/something-else\n' >| "$STATE/launchd/local.tester.weekly-update"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "foreign loaded job: uninstall exits 0" 0
check_out_has "foreign loaded job: named and left alone" 'The schedule local\.tester\.weekly-update is loaded but runs /usr/local/bin/something-else, not this tool, so it was left alone'
check_calls_lacks "foreign loaded job: it is not unloaded" '^launchctl bootout'
testing_check "foreign loaded job: it stays loaded" /usr/local/bin/something-else "$(cat "$STATE/launchd/local.tester.weekly-update" 2>/dev/null)"
testing_check "foreign loaded job: this tool's LaunchAgent left its place" no "$( [ -e "$plist" ] && printf yes || printf no )"
testing_check "foreign loaded job: this tool's LaunchAgent was moved, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*removed-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"
check_out_has "foreign loaded job: the summary names the schedule left loaded" 'Left loaded, because it runs another program: local\.tester\.weekly-update$'
check_out_has "foreign loaded job: verified" 'Removed and verified'

printf '== without a tool folder, a home folder reached through a symlink still finds this tool\x27s LaunchAgent\n'
for direction in link-at-uninstall link-at-install; do
  new_sandbox
  basic_fixture
  ln -s "$HOME_DIR" "$S/home-link"
  HOME_DIR_SAVED=$HOME_DIR
  [ "$direction" != link-at-install ] || HOME_DIR=$S/home-link
  run_script "$REPO/install.sh"
  HOME_DIR=$HOME_DIR_SAVED
  check_status "$direction: install exits 0" 0
  mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
  [ "$direction" != link-at-uninstall ] || HOME_DIR=$S/home-link
  reset_calls
  run_script "$REPO/uninstall.sh"
  HOME_DIR=$HOME_DIR_SAVED
  check_status "$direction: uninstall exits 0" 0
  check_out_lacks "$direction: this tool's agent is not called another program's" 'not this tool|not known whether|Nothing is installed'
  check_out_has "$direction: verified" 'Removed and verified'
  check_calls_has "$direction: the schedule is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
  testing_check "$direction: the LaunchAgent was moved, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*removed-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"
done

printf '== install recovers this tool\x27s LaunchAgent through a home folder reached by a symlink\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "linked reinstall: the first install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
ln -s "$HOME_DIR" "$S/home-link"
HOME_DIR_SAVED=$HOME_DIR
HOME_DIR=$S/home-link
reset_calls
run_script "$REPO/install.sh"
HOME_DIR=$HOME_DIR_SAVED
check_status "linked reinstall: exits 0" 0
check_out_lacks "linked reinstall: this tool's agent is not called another program's" 'not this tool|not known whether'
check_calls_has "linked reinstall: the previous schedule was unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
testing_check "linked reinstall: the previous LaunchAgent was moved aside" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*replaced-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"

printf '== this tool\x27s runtime path under another home folder stops uninstall and install without acting\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "renamed home: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
plist=$(plist_path local.tester.weekly-update)
plutil -replace ProgramArguments.0 -string "$S/old-home-name/.local/share/weekly-update/app/bin/weekly-update" "$plist"
printf '%s\n' "$S/old-home-name/.local/share/weekly-update/app/bin/weekly-update" >| "$STATE/launchd/local.tester.weekly-update"
reset_calls
run_script "$REPO/uninstall.sh" --dry-run
check_status "renamed home: the uninstall dry run exits 1 too" 1
run_script "$REPO/uninstall.sh"
check_status "renamed home: uninstall exits 1" 1
check_out_has "renamed home: the file is named as possibly this tool's" 'local\.tester\.weekly-update\.plist runs .*/old-home-name/\.local/share/weekly-update/app/bin/weekly-update, this tool.s runtime path under another home folder, so it is not known whether it belongs to this tool'
check_out_has "renamed home: the loaded schedule is named too" 'The schedule local\.tester\.weekly-update is loaded and runs .*/old-home-name/.*, this tool.s runtime path under another home folder'
check_out_lacks "renamed home: claims neither nothing installed nor a removal" 'Nothing is installed|Removed and verified'
check_calls_lacks "renamed home: nothing is unloaded" '^launchctl bootout'
testing_check "renamed home: the file stays" yes "$( [ -f "$plist" ] && printf yes || printf no )"
reset_calls
run_script "$REPO/install.sh"
check_status "renamed home: install stops too" 1
check_out_has "renamed home: install names it" 'runs .*/old-home-name/.*, this tool.s runtime path under another home folder, so it is not known whether it belongs to this tool, and install stopped before unloading or moving it'
check_calls_lacks "renamed home: install unloads nothing" '^launchctl bootout'

printf '== with its install manifest, a reinstall replaces this tool\x27s LaunchAgent whatever it runs now\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "edited program, reinstall: the first install exits 0" 0
plist=$(plist_path local.tester.weekly-update)
plutil -replace ProgramArguments.0 -string /usr/local/bin/my-wrapper "$plist"
printf '/usr/local/bin/my-wrapper\n' >| "$STATE/launchd/local.tester.weekly-update"
reset_calls
run_script "$REPO/install.sh"
check_status "edited program, reinstall: exits 0" 0
check_out_lacks "edited program, reinstall: not stopped as another program's" 'not this tool|install stopped'
check_calls_has "edited program, reinstall: the loaded schedule was unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
testing_check "edited program, reinstall: the edited LaunchAgent is kept under replaced-*" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*replaced-*' -name 'local.tester.weekly-update.plist' -exec grep -l my-wrapper {} + | wc -l | tr -d ' ')"

printf '== without a manifest, install stops when the schedule loaded at its label runs another program, even beside this tool\x27s file\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "this tool's file, foreign job: the first install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
printf '/usr/local/bin/something-else\n' >| "$STATE/launchd/local.tester.weekly-update"
reset_calls
run_script "$REPO/install.sh"
check_status "this tool's file, foreign job: install exits 1" 1
check_out_has "this tool's file, foreign job: named" 'A schedule named local\.tester\.weekly-update is loaded and runs /usr/local/bin/something-else, not this tool, so install stopped before unloading it'
check_calls_lacks "this tool's file, foreign job: nothing is unloaded" '^launchctl bootout'
testing_check "this tool's file, foreign job: the other job stays loaded" /usr/local/bin/something-else "$(cat "$STATE/launchd/local.tester.weekly-update" 2>/dev/null)"

printf '== install stops at an agent at its label that names no program it can read, or that cannot be read\n'
new_sandbox
basic_fixture
plist=$(plist_path local.tester.weekly-update)
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>Label</key>\n\t<string>local.tester.weekly-update</string>\n\t<key>Program</key>\n\t<string>/usr/local/bin/person-own</string>\n</dict>\n</plist>\n' >| "$plist"
reset_calls
run_script "$REPO/install.sh"
check_status "program-only agent at the label: install exits 1" 1
check_out_has "program-only agent at the label: its owner is called unknown" 'local\.tester\.weekly-update\.plist names no ProgramArguments install can read, so it is not known whether it belongs to this tool, and install stopped before unloading or moving it'
check_out_lacks "program-only agent at the label: not called another program's" 'not this tool'
chmod 000 "$plist"
run_script "$REPO/install.sh"
chmod 644 "$plist"
check_status "unreadable agent at the label: install exits 1" 1
check_out_has "unreadable agent at the label: named" 'local\.tester\.weekly-update\.plist cannot be read, so it is not known whether it belongs to this tool, and install stopped before touching it'
check_calls_lacks "an unreadable or unnamed agent at the label: nothing is unloaded" '^launchctl bootout'
testing_check "an unreadable or unnamed agent at the label: no tool copy was placed" no "$( [ -e "$HOME_DIR/.local/share/weekly-update/app" ] && printf yes || printf no )"

printf '== without a tool folder, a link to a missing file with the suffix stops the uninstall\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "dangling link: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
ln -s "$S/nowhere.plist" "$HOME_DIR/Library/LaunchAgents/mine.weekly-update.plist"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "dangling link: uninstall exits 1" 1
check_out_has "dangling link: named" 'mine\.weekly-update\.plist cannot be read, so it is not known whether it belongs to this tool'
check_calls_lacks "dangling link: nothing is unloaded" '^launchctl bootout'

printf '== with its install manifest, a link to a missing file at the label is moved like the LaunchAgent\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "manifest, dangling link: install exits 0" 0
plist=$(plist_path local.tester.weekly-update)
mv "$plist" "$S/plist-moved-by-person.plist"
ln -s "$S/nowhere.plist" "$plist"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "manifest, dangling link: uninstall exits 0" 0
testing_check "manifest, dangling link: the link left the label path" no "$( [ -L "$plist" ] && printf yes || printf no )"
testing_check "manifest, dangling link: the link was moved, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*removed-*' -name 'local.tester.weekly-update.plist' -type l | wc -l | tr -d ' ')"

printf '== without a tool folder, a loaded schedule alone that runs this tool\x27s runtime path under another home folder stops the uninstall\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "lookalike job only: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
mv "$(plist_path local.tester.weekly-update)" "$HOME_DIR/plist-moved-by-person.plist"
printf '%s\n' "$S/old-home/.local/share/weekly-update/app/bin/weekly-update" >| "$STATE/launchd/local.tester.weekly-update"
reset_calls
run_script "$REPO/uninstall.sh" --dry-run
check_status "lookalike job only: the dry run exits 1 too" 1
run_script "$REPO/uninstall.sh"
check_status "lookalike job only: uninstall exits 1" 1
check_out_has "lookalike job only: named" 'The schedule local\.tester\.weekly-update is loaded and runs .*/old-home/.*, this tool.s runtime path under another home folder'
check_out_lacks "lookalike job only: does not claim nothing is installed" 'Nothing is installed'
check_calls_lacks "lookalike job only: nothing is unloaded" '^launchctl bootout'

printf '== without a tool folder, a LaunchAgent alone that runs this tool\x27s runtime path under another home folder stops the uninstall\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "lookalike file only: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
plist=$(plist_path local.tester.weekly-update)
plutil -replace ProgramArguments.0 -string "$S/old-home/.local/share/weekly-update/app/bin/weekly-update" "$plist"
mv "$STATE/launchd/local.tester.weekly-update" "$S/unloaded-by-person"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "lookalike file only: uninstall exits 1" 1
check_out_has "lookalike file only: named" 'local\.tester\.weekly-update\.plist runs .*/old-home/.*, this tool.s runtime path under another home folder'
check_out_lacks "lookalike file only: does not claim nothing is installed" 'Nothing is installed'
testing_check "lookalike file only: the file stays" yes "$( [ -f "$plist" ] && printf yes || printf no )"

printf '== with no LaunchAgent file at its label, install stops at a loaded schedule whose owner it cannot tell\n'
for loaded in unnamed lookalike; do
  new_sandbox
  basic_fixture
  case $loaded in
    unnamed) : >| "$STATE/launchd/local.tester.weekly-update" ;;
    lookalike) printf '%s\n' "$S/old-home/.local/share/weekly-update/app/bin/weekly-update" >| "$STATE/launchd/local.tester.weekly-update" ;;
  esac
  reset_calls
  run_script "$REPO/install.sh"
  check_status "$loaded loaded job: install exits 1" 1
  case $loaded in
    unnamed) check_out_has "$loaded loaded job: named" 'A schedule named local\.tester\.weekly-update is loaded, but launchctl names no program for it that install can read, so it is not known whether it belongs to this tool' ;;
    lookalike) check_out_has "$loaded loaded job: named" 'A schedule named local\.tester\.weekly-update is loaded and runs .*/old-home/.*, this tool.s runtime path under another home folder, so it is not known whether it belongs to this tool' ;;
  esac
  check_calls_lacks "$loaded loaded job: nothing is unloaded" '^launchctl bootout'
  testing_check "$loaded loaded job: no tool copy was placed" no "$( [ -e "$HOME_DIR/.local/share/weekly-update/app" ] && printf yes || printf no )"
done

printf '== a tool folder that cannot be moved is listed, and the uninstall exits 1\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "stuck tool folder: install exits 0" 0
mv "$(app_dir)/bin/weekly-update" "$S/runtime-moved-by-person"
chmod 555 "$(app_dir)"
reset_calls
run_script "$REPO/uninstall.sh"
chmod 755 "$(app_dir)"
check_status "stuck tool folder: uninstall exits 1" 1
check_out_has "stuck tool folder: listed as still present" 'NOT fully removed; still present: .*/\.local/share/weekly-update/app$'
check_out_lacks "stuck tool folder: no success is claimed" 'Removed and verified'

printf '== with its install manifest, a reinstall moves a link to a missing file at the label aside\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "manifest, dangling link, reinstall: the first install exits 0" 0
plist=$(plist_path local.tester.weekly-update)
mv "$plist" "$S/plist-moved-by-person.plist"
ln -s "$S/nowhere.plist" "$plist"
run_script "$REPO/install.sh" --dry-run
check_status "manifest, dangling link, reinstall: the dry run exits 0" 0
check_out_has "manifest, dangling link, reinstall: the dry run names the link" 'Would move the previous LaunchAgent .*/local\.tester\.weekly-update\.plist'
reset_calls
run_script "$REPO/install.sh"
check_status "manifest, dangling link, reinstall: exits 0" 0
testing_check "manifest, dangling link, reinstall: a LaunchAgent file is at the label" file "$( [ -f "$plist" ] && [ ! -L "$plist" ] && printf file || printf other )"
testing_check "manifest, dangling link, reinstall: the link was moved aside, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*replaced-*' -name 'local.tester.weekly-update.plist' -type l | wc -l | tr -d ' ')"

printf '== a render failure that prints nothing still stops the uninstall when nothing else is found\n'
new_sandbox
basic_fixture
mkdir -p "$S/silent-copy"
cp -R "$REPO/bin" "$REPO/lib" "$S/silent-copy/"
printf '#!/bin/bash\nexit 3\n' >| "$S/silent-copy/bin/weekly-update"
reset_calls
run_script "$S/silent-copy/bin/weekly-update-uninstall"
check_status "silent render failure: uninstall exits 1" 1
check_out_has "silent render failure: says no reason was printed" 'The LaunchAgent could not be rendered, so a loaded schedule under the label the config names was not checked: no reason was printed'
check_out_lacks "silent render failure: does not claim nothing is installed" 'Nothing is installed'

printf '== install replaces another label\x27s LaunchAgent that runs this tool\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "old label: the first install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
write_config '[updater]' 'label_prefix = com.example'
run_script "$REPO/install.sh" --dry-run
check_status "old label: the dry run exits 0" 0
check_out_has "old label: the dry run names the old schedule" 'Would unload local\.tester\.weekly-update, another label.s schedule that runs this tool'
reset_calls
run_script "$REPO/install.sh"
check_status "old label: install under the new label exits 0" 0
check_calls_has "old label: the old schedule is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
testing_check "old label: the old schedule is no longer loaded" no "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"
testing_check "old label: the old LaunchAgent left its place" no "$( [ -e "$(plist_path local.tester.weekly-update)" ] && printf yes || printf no )"
testing_check "old label: the old LaunchAgent was moved aside, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*replaced-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"
testing_check "old label: the new schedule is loaded" yes "$( [ -f "$STATE/launchd/com.example.weekly-update" ] && printf yes || printf no )"

printf '== install leaves alone the agents under other labels that are not provably this tool\x27s\n'
new_sandbox
basic_fixture
write_foreign_agent
look=$HOME_DIR/Library/LaunchAgents/org.lookalike.weekly-update.plist
cp "$foreign" "$look"
plutil -replace Label -string org.lookalike.weekly-update "$look"
plutil -replace ProgramArguments.0 -string "$S/old-home/.local/share/weekly-update/app/bin/weekly-update" "$look"
locked=$HOME_DIR/Library/LaunchAgents/net.locked.weekly-update.plist
printf 'x\n' >| "$locked"
chmod 000 "$locked"
idle=$HOME_DIR/Library/LaunchAgents/org.idle.weekly-update.plist
cp "$foreign" "$idle"
plutil -replace Label -string org.idle.weekly-update "$idle"
idle_before=$(cat "$idle")
odd=$HOME_DIR/Library/LaunchAgents/odd.weekly-update.plist
cp "$foreign" "$odd"
programonly=$HOME_DIR/Library/LaunchAgents/org.program-only.weekly-update.plist
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>Label</key>\n\t<string>org.program-only.weekly-update</string>\n\t<key>Program</key>\n\t<string>/usr/local/bin/person-own</string>\n</dict>\n</plist>\n' >| "$programonly"
plutil -replace Label -string not-its-file-name.weekly-update "$odd"
plutil -replace ProgramArguments.0 -string "$(app_dir)/bin/weekly-update" "$odd"
foreign_before=$(cat "$foreign")
look_before=$(cat "$look")
reset_calls
run_script "$REPO/install.sh" --dry-run
check_status "other labels left alone: the dry run exits 0" 0
check_out_lacks "other labels left alone: the dry run plans no move of them" 'Would move .*(com\.example|org\.idle|org\.lookalike|net\.locked|odd)\.weekly-update'
run_script "$REPO/install.sh"
chmod 644 "$locked"
check_status "other labels left alone: install exits 0" 0
check_calls_lacks "other labels left alone: none of them is unloaded" '^launchctl bootout gui/501/(com\.example|org\.lookalike|net\.locked|not-its-file-name)'
testing_check "other labels left alone: another program's agent is untouched" same "$( [ "$(cat "$foreign")" = "$foreign_before" ] && printf same || printf changed )"
testing_check "other labels left alone: it stays loaded" yes "$( [ -f "$STATE/launchd/com.example.weekly-update" ] && printf yes || printf no )"
testing_check "other labels left alone: another program's agent that is not loaded is untouched too" same "$( [ -f "$idle" ] && [ "$(cat "$idle")" = "$idle_before" ] && printf same || printf changed )"
testing_check "other labels left alone: the lookalike is untouched" same "$( [ "$(cat "$look")" = "$look_before" ] && printf same || printf changed )"
testing_check "other labels left alone: the unreadable file is still there" yes "$( [ -f "$locked" ] && printf yes || printf no )"
testing_check "other labels left alone: the mislabelled file is still there" yes "$( [ -f "$odd" ] && printf yes || printf no )"
check_out_has "other labels left alone: the lookalike is named" 'org\.lookalike\.weekly-update\.plist runs .*/old-home/.*, this tool.s runtime path under another home folder, so it was left alone'
check_out_has "other labels left alone: the unreadable file is named" 'net\.locked\.weekly-update\.plist cannot be read'
check_out_has "other labels left alone: the mislabelled file is named" 'odd\.weekly-update\.plist runs this tool but does not carry its own file name'
check_out_has "other labels left alone: the file with no readable program is named" 'org\.program-only\.weekly-update\.plist names no ProgramArguments install can read, so it was left alone'
testing_check "other labels left alone: the file with no readable program is still there" yes "$( [ -f "$programonly" ] && printf yes || printf no )"

printf '== install stops at another label\x27s loaded schedule that runs this tool\x27s runtime path under another home folder\n'
for where in file loaded; do
  new_sandbox
  basic_fixture
  run_script "$REPO/install.sh"
  check_status "$where lookalike at old label: the first install exits 0" 0
  mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
  case $where in
    file) plutil -replace ProgramArguments.0 -string "$S/old-home/.local/share/weekly-update/app/bin/weekly-update" "$(plist_path local.tester.weekly-update)" ;;
  esac
  printf '%s\n' "$S/old-home/.local/share/weekly-update/app/bin/weekly-update" >| "$STATE/launchd/local.tester.weekly-update"
  write_config '[updater]' 'label_prefix = com.example'
  reset_calls
  run_script "$REPO/install.sh" --dry-run
  check_status "$where lookalike at old label: the dry run exits 1" 1
  run_script "$REPO/install.sh"
  check_status "$where lookalike at old label: install exits 1" 1
  check_out_has "$where lookalike at old label: named" 'local\.tester\.weekly-update.* this tool.s runtime path under another home folder.* so it is not known whether it belongs to this tool, and install stopped before unloading or moving anything'
  check_calls_lacks "$where lookalike at old label: nothing is unloaded" '^launchctl bootout'
  testing_check "$where lookalike at old label: its LaunchAgent stays" yes "$( [ -f "$(plist_path local.tester.weekly-update)" ] && printf yes || printf no )"
done

printf '== a rerun in the same second never moves anything onto an earlier run\x27s files\n'
future_stamps() {
  local now offset
  now=$(date +%s)
  for offset in $(seq 0 90); do
    date -r $((now + offset)) '+%Y%m%d-%H%M%S'
  done
}
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "same second: the first install exits 0" 0
tool_home=$HOME_DIR/.local/share/weekly-update
for stamp in $(future_stamps); do
  mkdir -p "$tool_home/replaced-$stamp" "$tool_home/removed-$stamp" "$tool_home/staging-$stamp"
  printf 'earlier run\n' >| "$tool_home/replaced-$stamp/earlier-run.txt"
  printf 'earlier run\n' >| "$tool_home/removed-$stamp/earlier-run.txt"
  printf 'earlier run\n' >| "$tool_home/staging-$stamp/earlier-run.txt"
done
run_script "$REPO/install.sh" --dry-run
check_out_has "same second: the plan names a fresh folder" 'Would move the previous copy to .*/replaced-[0-9]{8}-[0-9]{6}-2/app'
run_script "$REPO/install.sh"
check_status "same second: the reinstall exits 0" 0
testing_check "same second: the reinstall moved the old LaunchAgent into a fresh folder" 1 "$(find "$tool_home" -path '*/replaced-*-2/local.tester.weekly-update.plist' | wc -l | tr -d ' ')"
testing_check "same second: and the old copy" 1 "$(find "$tool_home" -path '*/replaced-*-2/app/bin/weekly-update' | wc -l | tr -d ' ')"
run_script "$REPO/uninstall.sh" --dry-run
check_out_has "same second: the uninstall plan names a fresh folder" 'Moved to: +.*/removed-[0-9]{8}-[0-9]{6}-2$'
run_script "$REPO/uninstall.sh"
check_status "same second: uninstall exits 0" 0
testing_check "same second: uninstall moved the LaunchAgent into a fresh folder" 1 "$(find "$tool_home" -path '*/removed-*-2/local.tester.weekly-update.plist' | wc -l | tr -d ' ')"
check_out_has "same second: uninstall reports the folder it used" 'Moved files: +.*/removed-[0-9]{8}-[0-9]{6}-2$'
crowded=0
for folder in "$tool_home"/replaced-* "$tool_home"/removed-* "$tool_home"/staging-*; do
  case $folder in *-2) continue ;; esac
  [ "$(find "$folder" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ] || crowded=$((crowded + 1))
done
testing_check "same second: every earlier run's folder still holds only its own file" 0 "$crowded"
kept=$(find "$tool_home" -mindepth 2 -maxdepth 2 -name earlier-run.txt \( -path '*/replaced-*' -o -path '*/removed-*' -o -path '*/staging-*' \) | wc -l | tr -d ' ')
testing_check "same second: every earlier run's folder is still in place" 273 "$kept"

printf '== install and uninstall change nothing when they cannot make a folder to move files into\n'
if [ "$(id -u)" != 0 ]; then
  new_sandbox
  basic_fixture
  run_script "$REPO/install.sh"
  check_status "unwritable tool folder: the first install exits 0" 0
  tool_home=$HOME_DIR/.local/share/weekly-update
  chmod 555 "$tool_home"
  reset_calls
  run_script "$REPO/install.sh"
  check_status "unwritable tool folder: the reinstall exits 1" 1
  check_out_has "unwritable tool folder: the reinstall says it could not make a staging folder" 'Could not create a staging folder under'
  check_calls_lacks "unwritable tool folder: the reinstall unloads nothing" '^launchctl bootout'
  reset_calls
  run_script "$REPO/uninstall.sh"
  chmod 755 "$tool_home"
  check_status "unwritable tool folder: uninstall exits 1" 1
  check_out_has "unwritable tool folder: uninstall says nothing was unloaded or moved" 'Cannot create a folder under .* to move the files into; nothing was unloaded or moved'
  check_calls_lacks "unwritable tool folder: uninstall unloads nothing" '^launchctl bootout'
  testing_check "unwritable tool folder: the LaunchAgent stays" yes "$( [ -f "$(plist_path local.tester.weekly-update)" ] && printf yes || printf no )"
  run_script "$REPO/uninstall.sh"
  check_status "unwritable tool folder: uninstall after the fix exits 0" 0
else
  printf 'SKIP  unwritable tool folder: running as root, where nothing is read-only\n'
fi

printf '== install moves aside another label\x27s LaunchAgent of this tool that is not loaded\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "unloaded old label: the first install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
mv "$STATE/launchd/local.tester.weekly-update" "$S/unloaded-by-person"
write_config '[updater]' 'label_prefix = com.example'
reset_calls
run_script "$REPO/install.sh" --dry-run
check_out_has "unloaded old label: the plan names its LaunchAgent" 'Would move .*/local\.tester\.weekly-update\.plist, another label.s LaunchAgent that runs this tool'
run_script "$REPO/install.sh"
check_status "unloaded old label: install exits 0" 0
check_calls_lacks "unloaded old label: nothing is unloaded under it" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
testing_check "unloaded old label: its LaunchAgent left its place" no "$( [ -e "$(plist_path local.tester.weekly-update)" ] && printf yes || printf no )"
testing_check "unloaded old label: it was moved aside, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*replaced-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"

printf '== a lookalike under another label: install stops unless another program is loaded there\n'
for loaded in current unnamed other; do
  new_sandbox
  basic_fixture
  run_script "$REPO/install.sh"
  check_status "lookalike with $loaded loaded: the first install exits 0" 0
  mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
  plist=$(plist_path local.tester.weekly-update)
  plutil -replace ProgramArguments.0 -string "$S/old-home/.local/share/weekly-update/app/bin/weekly-update" "$plist"
  case $loaded in
    current) printf '%s\n' "$(app_dir)/bin/weekly-update" >| "$STATE/launchd/local.tester.weekly-update" ;;
    unnamed) : >| "$STATE/launchd/local.tester.weekly-update" ;;
    other) printf '/usr/local/bin/something-else\n' >| "$STATE/launchd/local.tester.weekly-update" ;;
  esac
  write_config '[updater]' 'label_prefix = com.example'
  reset_calls
  run_script "$REPO/install.sh"
  case $loaded in
    other)
      check_status "lookalike with another program loaded: install exits 0" 0
      check_out_has "lookalike with another program loaded: named and left alone" 'local\.tester\.weekly-update\.plist runs .*/old-home/.*, so it was left alone'
      testing_check "lookalike with another program loaded: that program stays loaded" /usr/local/bin/something-else "$(cat "$STATE/launchd/local.tester.weekly-update" 2>/dev/null)"
      ;;
    *)
      check_status "lookalike with $loaded loaded: install exits 1" 1
      check_out_has "lookalike with $loaded loaded: named" 'local\.tester\.weekly-update\.plist runs .*/old-home/.*, and its schedule local\.tester\.weekly-update is loaded'
      ;;
  esac
  check_calls_lacks "lookalike with $loaded loaded: nothing is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
  testing_check "lookalike with $loaded loaded: the file stays" yes "$( [ -f "$plist" ] && printf yes || printf no )"
done

printf '== install stops at another label\x27s loaded schedule of this tool whose program it cannot confirm\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "unconfirmed old label: the first install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
: >| "$STATE/launchd/local.tester.weekly-update"
write_config '[updater]' 'label_prefix = com.example'
reset_calls
run_script "$REPO/install.sh" --dry-run
check_status "unconfirmed old label: the dry run exits 1" 1
run_script "$REPO/install.sh"
check_status "unconfirmed old label: install exits 1" 1
check_out_has "unconfirmed old label: named" 'The schedule local\.tester\.weekly-update is loaded, but launchctl names no program for it that install can read'
check_calls_lacks "unconfirmed old label: nothing is unloaded" '^launchctl bootout'
testing_check "unconfirmed old label: its LaunchAgent stays" yes "$( [ -f "$(plist_path local.tester.weekly-update)" ] && printf yes || printf no )"

printf '== install leaves this tool\x27s LaunchAgent under another label alone when another program is loaded there\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "foreign job at old label: the first install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
printf '/usr/local/bin/something-else\n' >| "$STATE/launchd/local.tester.weekly-update"
write_config '[updater]' 'label_prefix = com.example'
reset_calls
run_script "$REPO/install.sh"
check_status "foreign job at old label: install exits 0" 0
check_out_has "foreign job at old label: named" 'The schedule local\.tester\.weekly-update is loaded but runs /usr/local/bin/something-else, not this tool, so that schedule and this tool.s LaunchAgent at .*/local\.tester\.weekly-update\.plist were left alone'
check_calls_lacks "foreign job at old label: it is not unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
testing_check "foreign job at old label: the LaunchAgent stays" yes "$( [ -f "$(plist_path local.tester.weekly-update)" ] && printf yes || printf no )"
testing_check "foreign job at old label: nothing of it was moved aside" 0 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*replaced-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"

printf '== with its install manifest, the uninstaller also removes another label\x27s LaunchAgent that runs this tool\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "second label: install exits 0" 0
extra=$HOME_DIR/Library/LaunchAgents/com.example.weekly-update.plist
cp "$(plist_path local.tester.weekly-update)" "$extra"
plutil -replace Label -string com.example.weekly-update "$extra"
printf '%s\n' "$(app_dir)/bin/weekly-update" >| "$STATE/launchd/com.example.weekly-update"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "second label: uninstall exits 0" 0
check_out_has "second label: verified" 'Removed and verified'
check_calls_has "second label: the manifest's schedule is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
check_calls_has "second label: the other label's schedule is unloaded" '^launchctl bootout gui/501/com\.example\.weekly-update$'
testing_check "second label: its LaunchAgent left its place" no "$( [ -e "$extra" ] && printf yes || printf no )"
testing_check "second label: its LaunchAgent was moved, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*removed-*' -name 'com.example.weekly-update.plist' | wc -l | tr -d ' ')"

printf '== with its install manifest, an unreadable LaunchAgent with the suffix still stops the uninstall\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "manifest, unreadable other: install exits 0" 0
odd=$HOME_DIR/Library/LaunchAgents/other.weekly-update.plist
printf 'x\n' >| "$odd"
chmod 000 "$odd"
reset_calls
run_script "$REPO/uninstall.sh"
chmod 644 "$odd"
check_status "manifest, unreadable other: uninstall exits 1" 1
check_out_has "manifest, unreadable other: named" 'other\.weekly-update\.plist cannot be read, so it is not known whether it belongs to this tool'
check_calls_lacks "manifest, unreadable other: nothing is unloaded" '^launchctl bootout'

printf '== without a tool folder, a config that cannot be rendered keeps the run from claiming it verified everything\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "unrendered, agent found: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
write_config '[updater]' 'weekdy = 0'
reset_calls
run_script "$REPO/uninstall.sh" --dry-run
check_status "unrendered, agent found: the dry run exits 0" 0
check_out_has "unrendered, agent found: the dry run warns the same way" 'The LaunchAgent could not be rendered, so a loaded schedule under the label the config names was not checked'
check_calls_lacks "unrendered, agent found: the dry run unloads nothing" '^launchctl bootout'
reset_calls
run_script "$REPO/uninstall.sh"
check_status "unrendered, agent found: uninstall exits 1" 1
check_calls_has "unrendered, agent found: the agent it found is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
check_out_has "unrendered, agent found: says what was not checked" 'NOT fully verified: the LaunchAgent could not be rendered'
check_out_lacks "unrendered, agent found: no success is claimed" 'Removed and verified'

printf '== install reads the schedule at the manifest label when a lookalike file under another name carries that label\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "stray lookalike: the first install exits 0" 0
stray=$HOME_DIR/Library/LaunchAgents/org.stray.weekly-update.plist
cp "$(plist_path local.tester.weekly-update)" "$stray"
plutil -replace ProgramArguments.0 -string "$S/old-home/.local/share/weekly-update/app/bin/weekly-update" "$stray"
reset_calls
run_script "$REPO/install.sh" --dry-run
check_status "stray lookalike: the dry run exits 1" 1
run_script "$REPO/install.sh"
check_status "stray lookalike: install exits 1" 1
check_out_has "stray lookalike: install names the file and the loaded schedule" 'org\.stray\.weekly-update\.plist runs .*/old-home/.*, this tool.s runtime path under another home folder, and its schedule local\.tester\.weekly-update is loaded'
check_calls_lacks "stray lookalike: nothing is unloaded" '^launchctl bootout'

printf '== a lookalike file whose Label key is not a weekly-update label is left alone without asking launchd\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "foreign Label key: the first install exits 0" 0
stray=$HOME_DIR/Library/LaunchAgents/org.stray.weekly-update.plist
cp "$(plist_path local.tester.weekly-update)" "$stray"
plutil -replace ProgramArguments.0 -string "$S/old-home/.local/share/weekly-update/app/bin/weekly-update" "$stray"
plutil -replace Label -string com.foo.agent "$stray"
printf '%s\n' "$(app_dir)/bin/weekly-update" >| "$STATE/launchd/com.foo.agent"
reset_calls
run_script "$REPO/install.sh" --dry-run
check_status "foreign Label key: the dry run exits 0" 0
run_script "$REPO/install.sh"
check_status "foreign Label key: install exits 0" 0
check_out_has "foreign Label key: the file is named and left alone" 'org\.stray\.weekly-update\.plist runs .*/old-home/.*, this tool.s runtime path under another home folder, so it was left alone'
check_calls_lacks "foreign Label key: launchd is not asked about that label" '^launchctl print gui/501/com\.foo\.agent$'

printf '== a lookalike file whose Label key names another weekly-update label stops install while this tool runs there\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "third label: the first install exits 0" 0
write_foreign_agent
stray=$HOME_DIR/Library/LaunchAgents/org.stray.weekly-update.plist
cp "$(plist_path local.tester.weekly-update)" "$stray"
plutil -replace ProgramArguments.0 -string "$S/old-home/.local/share/weekly-update/app/bin/weekly-update" "$stray"
plutil -replace Label -string com.example.weekly-update "$stray"
printf '%s\n' "$(app_dir)/bin/weekly-update" >| "$STATE/launchd/com.example.weekly-update"
reset_calls
run_script "$REPO/install.sh" --dry-run
check_status "third label: the dry run exits 1" 1
run_script "$REPO/install.sh"
check_status "third label: install exits 1" 1
check_out_has "third label: install names the lookalike and the schedule at that label" 'org\.stray\.weekly-update\.plist runs .*/old-home/.*, and its schedule com\.example\.weekly-update is loaded'
check_calls_lacks "third label: nothing is unloaded" '^launchctl bootout'

printf '== with the install manifest in place, the uninstaller does not render the config\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "manifest, broken config: the install exits 0" 0
write_config '[updater]' 'weekdy = 0'
reset_calls
run_script "$REPO/uninstall.sh" --dry-run
check_status "manifest, broken config: the dry run exits 0" 0
check_out_lacks "manifest, broken config: the dry run has no render warning" 'could not be rendered'
run_script "$REPO/uninstall.sh"
check_status "manifest, broken config: uninstall exits 0" 0
check_out_has "manifest, broken config: removed and verified" 'Removed and verified'
check_out_lacks "manifest, broken config: no render warning" 'could not be rendered'

printf '== an agent of this tool whose Label is its file name but not a weekly-update label is not this tool\x27s\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "odd label: the first install exits 0" 0
odd=$HOME_DIR/Library/LaunchAgents/my_agent.weekly-update.plist
cp "$(plist_path local.tester.weekly-update)" "$odd"
plutil -replace Label -string my_agent.weekly-update "$odd"
printf '%s\n' "$(app_dir)/bin/weekly-update" >| "$STATE/launchd/my_agent.weekly-update"
reset_calls
run_script "$REPO/uninstall.sh" --dry-run
check_status "odd label: the uninstall dry run exits 1" 1
run_script "$REPO/uninstall.sh"
check_status "odd label: uninstall exits 1" 1
check_out_has "odd label: the uninstaller names it" 'my_agent\.weekly-update\.plist does not carry its own file name as a weekly-update label'
check_calls_lacks "odd label: the uninstaller unloads nothing" '^launchctl bootout'
check_calls_lacks "odd label: the uninstaller does not ask launchd about it" '^launchctl print gui/501/my_agent\.weekly-update$'
reset_calls
run_script "$REPO/install.sh"
check_status "odd label: a reinstall exits 0" 0
check_out_has "odd label: install names it and leaves it alone" 'my_agent\.weekly-update\.plist runs this tool but does not carry its own file name as a weekly-update label, so it was left alone'
check_calls_lacks "odd label: install does not unload it" '^launchctl bootout gui/501/my_agent\.weekly-update$'
testing_check "odd label: its file stays in place" yes "$( [ -f "$odd" ] && printf yes || printf no )"

printf '== the installed tripwire passes on an install through a home folder reached by a symlink\n'
new_sandbox
basic_fixture
ln -s "$HOME_DIR" "$S/home-link-verify"
HOME_DIR_SAVED=$HOME_DIR
HOME_DIR=$S/home-link-verify
run_script "$REPO/install.sh"
check_status "linked home: install exits 0" 0
run_script "$(app_dir)/bin/weekly-update-verify"
HOME_DIR=$HOME_DIR_SAVED
check_status "linked home: the installed verify exits 0" 0
check_out_has "linked home: V2 passes" 'PASS V2 the window launcher only execs the runtime'

printf '== the installed tripwire passes on a home folder with a non-ASCII letter, in a UTF-8 locale\n'
new_sandbox
basic_fixture
accented=$S/Zo$(printf '\303\253')
mv "$HOME_DIR" "$accented"
HOME_DIR_SAVED=$HOME_DIR
HOME_DIR=$accented
SEAM_LANG=en_US.UTF-8
OUT=$S/out-accented.txt
seam_env LC_ALL=en_US.UTF-8 /bin/bash "$REPO/install.sh" > "$OUT" 2>&1
RC=$?
check_status "accented home: install exits 0" 0
testing_check "accented home: install prints the four commands" 4 "$(LC_ALL=C grep -c -E '^  (Try it|Status|Tripwire|Remove it):' "$OUT")"
testing_check "accented home: the commands install prints are ASCII" "" "$(LC_ALL=C grep -E '^  (Try it|Status|Tripwire|Remove it):' "$OUT" | LC_ALL=C grep '[^ -~]')"
testing_check "accented home: the launcher is ASCII" "" "$(LC_ALL=C grep -l '[^[:print:][:space:]]' "$(app_dir)/bin/weekly-update-scheduled")"
run_script "$(app_dir)/bin/weekly-update-verify"
check_status "accented home: the installed verify exits 0" 0
check_out_has "accented home: V2 passes" 'PASS V2 the window launcher only execs the runtime'
SEAM_LANG=
mv "$accented" "$HOME_DIR_SAVED"
HOME_DIR=$HOME_DIR_SAVED

printf '== install unloads and moves aside the older label its manifest names, whatever it runs\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "older label, other program: the first install exits 0" 0
testing_check "the install manifest hashes the LaunchAgent and the four bin scripts, nothing else" "$(printf '%s\n' "$(plist_path local.tester.weekly-update)" "$(app_dir)/bin/weekly-update" "$(app_dir)/bin/weekly-update-verify" "$(app_dir)/bin/weekly-update-uninstall" "$(app_dir)/bin/weekly-update-scheduled")" "$(awk -F'\t' '$1 == "file" { print $2 }' "$(app_dir)/install-manifest.tsv")"
plutil -replace ProgramArguments.0 -string /usr/local/bin/my-wrapper "$(plist_path local.tester.weekly-update)"
printf '/usr/local/bin/my-wrapper\n' >| "$STATE/launchd/local.tester.weekly-update"
write_config '[updater]' 'label_prefix = com.example'
reset_calls
run_script "$REPO/install.sh"
check_status "older label, other program: the reinstall exits 0" 0
check_calls_has "older label, other program: the older label is unloaded" '^launchctl bootout gui/501/local\.tester\.weekly-update$'
testing_check "older label, other program: its LaunchAgent was moved aside" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*replaced-*' -name 'local.tester.weekly-update.plist' | wc -l | tr -d ' ')"

printf '== a tool folder with no install manifest stops the uninstall\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "no manifest: install exits 0" 0
mv "$(app_dir)/install-manifest.tsv" "$S/manifest-moved-by-person.tsv"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "no manifest: uninstall exits 1" 1
check_out_has "no manifest: named" 'exists but has no install manifest'
check_calls_lacks "no manifest: nothing is unloaded" '^launchctl bootout'

printf '== without a tool folder, a home folder written with doubled slashes still finds this tool\x27s LaunchAgent\n'
new_sandbox
basic_fixture
HOME_DIR_SAVED=$HOME_DIR
HOME_DIR="${HOME_DIR%/home}//home"
run_script "$REPO/install.sh"
HOME_DIR=$HOME_DIR_SAVED
check_status "doubled slashes: install exits 0" 0
mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
reset_calls
run_script "$REPO/uninstall.sh"
check_status "doubled slashes: uninstall exits 0" 0
check_out_lacks "doubled slashes: this tool's agent is not called another's" 'not this tool|not known whether'
check_out_has "doubled slashes: verified" 'Removed and verified'

printf '== a home folder path with a character XML would need escaped is refused\n'
for ch in '&' '<' '>' '"' "'"; do
  new_sandbox
  basic_fixture
  mv "$HOME_DIR" "$S/ho${ch}me"
  HOME_DIR_SAVED=$HOME_DIR
  HOME_DIR="$S/ho${ch}me"
  run_script "$REPO/install.sh" --dry-run
  check_status "XML-special home ($ch): the install dry run exits 2" 2
  run_script "$REPO/install.sh"
  check_status "XML-special home ($ch): install exits 2" 2
  check_out_has "XML-special home ($ch): install says why" 'XML would need escaped'
  run_script "$REPO/uninstall.sh"
  check_status "XML-special home ($ch), nothing installed: uninstall exits 1" 1
  check_out_has "XML-special home ($ch): the uninstaller says the LaunchAgent could not be rendered" 'could not be rendered'
  HOME_DIR=$HOME_DIR_SAVED
done

printf '== without a tool folder, a home folder written in another letter case stops the uninstall\n'
new_sandbox
basic_fixture
if [ -d "${HOME_DIR%/home}/HOME" ]; then
  run_script "$REPO/install.sh"
  check_status "letter case: install exits 0" 0
  mv "$HOME_DIR/.local/share/weekly-update" "$HOME_DIR/tool-folder-moved-by-person"
  HOME_DIR_SAVED=$HOME_DIR
  HOME_DIR="${HOME_DIR%/home}/HOME"
  reset_calls
  run_script "$REPO/uninstall.sh"
  HOME_DIR=$HOME_DIR_SAVED
  check_status "letter case: uninstall exits 1" 1
  check_out_has "letter case: named as possibly this tool's" 'another home folder, so it is not known whether it belongs to this tool'
  check_calls_lacks "letter case: nothing is unloaded" '^launchctl bootout'
  HOME_DIR="${HOME_DIR%/home}/HOME"
  run_script "$REPO/install.sh"
  HOME_DIR=$HOME_DIR_SAVED
  check_status "letter case: install at its own label stops too" 1
  check_out_has "letter case: install says why" 'this tool.s runtime path under another home folder, so it is not known whether it belongs to this tool'
else
  printf 'SKIP  letter case: this file system tells letter cases apart\n'
fi

printf '== uninstall refuses while a pass holds the lock\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
mkdir -p "$HOME_DIR/Library/Logs/weekly-update"
lockf -s -t 0 "$HOME_DIR/Library/Logs/weekly-update/run.lock" sleep 60 &
holder=$!
sleep 1
run_script "$(app_dir)/bin/weekly-update-uninstall"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
check_status "uninstall during a pass exits 1" 1
testing_check "uninstall during a pass moves nothing" yes "$( [ -f "$(app_dir)/bin/weekly-update" ] && printf yes || printf no )"

printf '== a hand-edited manifest never makes install or uninstall touch another agent\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "install exits 0" 0
: > "$STATE/launchd/com.example.other"
manifest=$(app_dir)/install-manifest.tsv
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "label" { $2 = "com.example.other" } { print }' "$manifest" > "$S/manifest.edited"
mv "$S/manifest.edited" "$manifest"
reset_calls
run_script "$(app_dir)/bin/weekly-update-uninstall" --dry-run
check_status "the uninstall dry run with a foreign label exits 1" 1
run_script "$(app_dir)/bin/weekly-update-uninstall"
check_status "uninstall with a foreign label exits 1" 1
check_out_has "uninstall names the foreign label" 'names "com\.example\.other", which is not a weekly-update label'
check_calls_lacks "uninstall unloads nothing" '^launchctl bootout'
testing_check "uninstall moves nothing" yes "$( [ -f "$(app_dir)/bin/weekly-update" ] && printf yes || printf no )"
reset_calls
run_script "$REPO/install.sh"
check_status "reinstall over a foreign label exits 0" 0
check_out_has "reinstall says it leaves the foreign label alone" 'not a weekly-update label, so it is not unloaded or moved'
check_calls_lacks "reinstall never unloads the other agent" '^launchctl bootout gui/501/com\.example\.other'
testing_check "the other agent is still loaded" yes "$( [ -f "$STATE/launchd/com.example.other" ] && printf yes || printf no )"

printf '== an install stopped by a signal says what to do, and a rerun recovers\n'
new_sandbox
basic_fixture
printf '3\n' > "$STATE/scenario/launchctl.sleep"
OUT=$S/out-interrupted.txt
set -m
seam_env /bin/bash "$REPO/install.sh" > "$OUT" 2>&1 &
install_group=$!
set +m
waited=0
until LC_ALL=C grep -q '^launchctl bootstrap' "$STATE/calls.log" 2>/dev/null || [ "$waited" -ge 300 ]; do
  sleep 0.2
  waited=$((waited + 1))
done
check_calls_has "interrupted install: stopped while loading the schedule" '^launchctl bootstrap'
kill -TERM -- "-$install_group" 2>/dev/null
wait "$install_group" 2>/dev/null
RC=$?
waited=0
until LC_ALL=C grep -q 'Rerun ./install.sh' "$OUT" 2>/dev/null || [ "$waited" -ge 100 ]; do
  sleep 0.2
  waited=$((waited + 1))
done
check_status "interrupted install exits 143" 143
check_out_has "interrupted install prints the banner" 'INTERRUPTED'
check_out_has "interrupted install says to rerun, and that nothing was deleted" 'Rerun \./install\.sh\. Nothing was deleted'
check_out_lacks "interrupted install: no claim about when a schedule loads" 'none is loaded until you rerun'
testing_check "interrupted install: no schedule is loaded" no "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"
mv "$STATE/scenario/launchctl.sleep" "$STATE/scenario/launchctl.sleep.done"
run_script "$REPO/install.sh"
check_status "the rerun after an interrupt exits 0" 0
testing_check "the rerun loads the schedule" yes "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"

printf '== a reinstall whose schedule does not load says the unloaded one is gone until a rerun\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "failed reload: the first install exits 0" 0
: > "$STATE/scenario/launchctl.bootstrap-fails"
run_script "$REPO/install.sh"
mv "$STATE/scenario/launchctl.bootstrap-fails" "$STATE/scenario/launchctl.bootstrap-fails.done"
check_status "failed reload: install exits 1" 1
check_out_has "failed reload: says what was unloaded and what a rerun loads" 'The previous schedule was unloaded and is not loaded now: local\.tester\.weekly-update\. Rerun \./install\.sh to load the schedule your config names\.'

printf '== an install whose schedule does not load says what is in place\n'
new_sandbox
basic_fixture
: > "$STATE/scenario/launchctl.bootstrap-fails"
run_script "$REPO/install.sh"
check_status "a failed load: install exits 1" 1
check_out_has "a failed load: says the copy is in place and nothing is loaded" 'Installed only in part: the new copy is at .*/\.local/share/weekly-update/app, but no schedule is loaded until you rerun \./install\.sh or log in again\. Rerun \./install\.sh\.'
check_out_has "a failed load on a first install: nothing was moved aside" 'Nothing was deleted, and nothing was moved aside\.'
check_out_lacks "a failed load: does not claim nothing was installed" 'Not installed'
testing_check "a failed load: no schedule is loaded" no "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"
mv "$STATE/scenario/launchctl.bootstrap-fails" "$STATE/scenario/launchctl.bootstrap-fails.done"
run_script "$REPO/install.sh"
check_status "a failed load: the rerun exits 0" 0
check_out_has "a failed load: the rerun moves the partial copy aside" 'Previous copy moved to .*/replaced-[0-9-]*/app'
testing_check "a failed load: the rerun loads the schedule" yes "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"

printf '== the commands install prints can be pasted when the home folder has a space\n'
new_sandbox
HOME_DIR="$S/home with space"
mkdir -p "$HOME_DIR/Library/Preferences" "$HOME_DIR/Library/LaunchAgents" "$HOME_DIR/.config/weekly-update"
basic_fixture
run_script "$REPO/install.sh"
check_status "a home with a space: install exits 0" 0
try_line=$(LC_ALL=C sed -n 's/^  Try it:     //p' "$OUT")
check_out_has "a home with a space: the Try it line escapes the space" '^  Try it: +.*home\\ with\\ space/'
OUT=$S/out-pasted.txt
seam_env /bin/bash -c "$try_line" > "$OUT" 2>&1
RC=$?
check_status "a home with a space: the printed check command runs as printed" 0
check_out_has "a home with a space: the printed command read the Dock" 'Zed +0\.150\.0'

printf '== uninstall names a config only when one exists\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "no config: install exits 0" 0
mv "$HOME_DIR/.config/weekly-update/config" "$S/config.moved-by-test"
run_script "$REPO/uninstall.sh"
check_status "no config: uninstall exits 0" 0
check_out_has "no config: says there is none" 'Config: +none at .*/\.config/weekly-update/config'
check_out_lacks "no config: does not claim a config was kept" 'Config kept'

printf '== install and uninstall refuse to run as root\n'
new_sandbox
basic_fixture
: > "$STATE/scenario/id/root"
run_script "$REPO/install.sh"
check_status "install as root exits 2" 2
check_out_has "install as root says why" 'not as root'
testing_check "install as root writes nothing" no "$( [ -e "$(app_dir)" ] || [ -e "$HOME_DIR/Library/Logs/weekly-update" ] && printf yes || printf no )"
check_calls_lacks "install as root loads nothing" '^launchctl (bootstrap|enable|bootout)'
run_script "$REPO/install.sh" --dry-run
check_status "the install dry run as root exits 2" 2
run_script "$REPO/bin/weekly-update-uninstall" --dry-run
check_status "the uninstall dry run as root exits 2" 2
run_script "$REPO/bin/weekly-update-uninstall"
check_status "uninstall as root exits 2" 2
check_out_has "uninstall as root says why" 'not as root'
mv "$STATE/scenario/id/root" "$STATE/scenario/id/root.done"
run_script "$REPO/install.sh"
check_status "control: install as the person exits 0" 0

printf '== install enables a label the person disabled before it loads the schedule\n'
new_sandbox
basic_fixture
: > "$STATE/launchd/.disabled-local.tester.weekly-update"
run_script "$REPO/install.sh"
check_status "a disabled label: install exits 0" 0
testing_check "a disabled label: the schedule is loaded" yes "$( [ -f "$STATE/launchd/local.tester.weekly-update" ] && printf yes || printf no )"
enable_line=$(LC_ALL=C grep -n '^launchctl enable ' "$STATE/calls.log" | head -n 1 | cut -d : -f 1)
bootstrap_line=$(LC_ALL=C grep -n '^launchctl bootstrap ' "$STATE/calls.log" | head -n 1 | cut -d : -f 1)
testing_check "a disabled label: enable comes before bootstrap" yes "$( [ -n "$enable_line" ] && [ -n "$bootstrap_line" ] && [ "$enable_line" -lt "$bootstrap_line" ] && printf yes || printf no )"

printf '== a link to a missing folder at the tool copy path is moved aside like a previous copy\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "a dangling tool copy link: the first install exits 0" 0
mv "$(app_dir)" "$S/app-moved-by-person"
ln -s "$S/missing-app" "$(app_dir)"
run_script "$REPO/install.sh" --dry-run
check_status "a dangling tool copy link: the dry run exits 0" 0
check_out_has "a dangling tool copy link: the dry run names the move" 'Would move the previous copy to .*/replaced-[0-9-]*/app'
run_script "$REPO/install.sh"
check_status "a dangling tool copy link: install exits 0" 0
testing_check "a dangling tool copy link: the link was moved aside, not deleted" 1 "$(find "$HOME_DIR/.local/share/weekly-update" -path '*replaced-*' -name app -type l | wc -l | tr -d ' ')"

printf '== a plutil without the raw output format is named\n'
new_sandbox
basic_fixture
cat > "$S/shims/plutil" <<'STANDIN'
#!/bin/bash
for argument in "$@"; do [ "$argument" != raw ] || exit 1; done
exec /usr/bin/plutil "$@"
STANDIN
chmod 755 "$S/shims/plutil"
run_script "$REPO/install.sh" --dry-run
check_status "no raw format: the install dry run exits 1" 1
check_out_has "no raw format: says the plutil may be the cause" 'raw output format that macOS 12 added'

printf '== uninstall claims kept logs only when the log folder was there\n'
new_sandbox
basic_fixture
run_script "$REPO/install.sh"
check_status "no log folder: install exits 0" 0
mv "$HOME_DIR/Library/Logs/weekly-update" "$S/logs-moved-by-person"
run_script "$REPO/uninstall.sh"
check_status "no log folder: uninstall exits 0" 0
check_out_lacks "no log folder: no logs are claimed as kept" 'Logs and history kept'
check_out_has "control: the uninstall still verified" 'Removed and verified'

testing_verdict
