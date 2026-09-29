#!/bin/bash
# test-inventory.sh: inventory scenarios, S16 (heartbeat and missing apps),
# S20 (automatic mapping is report-only until setup confirms it), vendor and
# manual rows, the read-only check mode, and the rules that decide which apps
# may be upgraded unattended or adopted.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # cask fixtures carry Homebrew's literal $APPDIR and $HOMEBREW_CELLAR placeholders
set -u
set -o pipefail
# shellcheck source=harness.sh
. "${0%/*}/harness.sh"

printf '== S16 a silent week and a missing app are reported\n'
new_sandbox
basic_fixture
mkdir -p "$HOME_DIR/Library/Logs/weekly-update"
nine_days_ago=$(date -v-9d '+%Y-%m-%d %H:%M:%S')
printf '%s\tauto\tcompleted\texit=0 version=0.1.0\n' "$nine_days_ago" > "$(history_file)"
printf '%s\tseen\tZed\t0.150.0\n' "$nine_days_ago" > "$HOME_DIR/Library/Logs/weekly-update/apps.tsv"
mv "$S/Applications/Zed.app" "$S/Zed.app.moved-by-test"
run_wu check
check_status "S16 check exits 0" 0
check_out_has "S16 heartbeat warning" 'No pass has finished for 9 days'
check_out_has "S16 missing app warning" "Zed is missing from disk since the run of $nine_days_ago; this tool has not touched it since"
check_out_has "S16 the table shows it missing" 'Zed +missing'
testing_check "S16 check wrote no run log" 0 "$(find "$HOME_DIR/Library/Logs/weekly-update" -name 'run-*.log' | wc -l | tr -d ' ')"
testing_check "S16 check wrote no history row" 1 "$(history_rows)"
testing_check "S16 check wrote no ledger row" 1 "$(wc -l < "$HOME_DIR/Library/Logs/weekly-update/apps.tsv" | tr -d ' ')"
check_calls_lacks "S16 check changes nothing" '^(brew (update|upgrade|install)|sudo|open|launchctl (bootstrap|bootout))|to quit|osascript'
printf '%s\tupgraded\tZed\t0.149.0 to 0.150.0\n' "$(date -v-8d '+%Y-%m-%d %H:%M:%S')" >> "$HOME_DIR/Library/Logs/weekly-update/apps.tsv"
run_wu check
check_out_has "S16 a later change by this tool is named" 'this tool last changed it at .*\(upgraded\)'
# Two hours of margin on each side keep a daylight saving change from moving
# either row across a whole day.
printf '%s\tauto\tcompleted\texit=0 version=0.1.0\n' "$(date -v-8d -v-2H '+%Y-%m-%d %H:%M:%S')" >| "$(history_file)"
run_wu check
check_out_has "S16 heartbeat_days whole days without a pass are reported" 'No pass has finished for 8 days'
printf '%s\tauto\tcompleted\texit=0 version=0.1.0\n' "$(date -v-7d -v-22H '+%Y-%m-%d %H:%M:%S')" >| "$(history_file)"
run_wu check
check_out_lacks "S16 one whole day fewer is not reported" 'No pass has finished'

printf '== S20 an automatically mapped app is report-only until confirmed\n'
new_sandbox
basic_fixture
make_app "Example Editor" com.example.editor 1.0
make_app "Another App" com.example.another 3.0
make_app "Plain Tool" com.example.plain 1.0
write_dock Firefox:org.mozilla.firefox "Example Editor:com.example.editor" "Another App:com.example.another" "Plain Tool:com.example.plain"
set_installed_casks '{"casks":[{"token":"example-editor","artifacts":[{"app":["Example Editor.app"]}]}]}'
cask_info example-editor 2.0 "Example Editor.app" 1.0
printf 'another-app\nfirefox\n' > "$STATE/brew-cache/api/cask_names.txt"
cask_info another-app 3.1 "Another App.app" ""
set_outdated example-editor
run_wu auto
check_status "S20 exit 0" 0
check_calls_lacks "S20 no upgrade of a proposed app" '^brew upgrade --cask (example-editor|another-app)'
check_calls_lacks "S20 no adoption of a proposed app" 'install --cask --adopt'
check_calls_lacks "S20 no quit or open of a proposed app" 'to quit|^open '
check_out_has "S20 the summary asks for confirmation" '2 app\(s\) have a proposed cask; run setup to confirm them'
check_out_has "S20 the table marks them proposed" 'Example Editor +1\.0 +2\.0 +older +silent +proposed'
check_out_has "S20 an app with no cask is named" 'No cask found for: Plain Tool'
check_out_lacks "S20 no blanket match claim" 'Every Homebrew-managed'
check_file_has "S20 history counts the proposals" "$(history_file)" 'proposed=2$'
check_i8 "S20 auto"
INTERACTIVE=1
answers yes no no
run_wu setup
check_status "S20 setup exits 0" 0
check_file_has "S20 setup appended the confirmed row" "$HOME_DIR/.config/weekly-update/config" '^\[app com\.example\.editor\]$'
check_file_has "S20 setup appended its cask" "$HOME_DIR/.config/weekly-update/config" '^cask = example-editor$'
check_file_lacks "S20 a declined proposal is not written" "$HOME_DIR/.config/weekly-update/config" 'another'
check_file_has "S20 the original rows are kept" "$HOME_DIR/.config/weekly-update/config" '^cask = firefox$'
run_wu plist
check_status "S20 the appended config is still valid" 0
mv "$(history_file)" "$HOME_DIR/Library/Logs/weekly-update/history-before.tsv"
reset_calls
printf '%s\n' "$S/Applications/Example Editor.app" > "$STATE/scenario/brew/upgrade-example-editor.app"
printf '2.0\n' > "$STATE/scenario/brew/upgrade-example-editor.version"
INTERACTIVE=0
run_wu auto
check_calls_has "S20 once confirmed, it is upgraded" '^brew upgrade --cask example-editor NO_UPGRADE_QUIT_CASKS=1$'
check_i8 "S20 confirmed auto"

printf '== two Dock tiles for one app give one config section\n'
new_sandbox
basic_fixture
make_app "Example Editor" com.example.editor 1.0
write_dock Firefox:org.mozilla.firefox "Example Editor:com.example.editor" "Example Editor:com.example.editor"
set_installed_casks '{"casks":[{"token":"example-editor","artifacts":[{"app":["Example Editor.app"]}]}]}'
cask_info example-editor 2.0 "Example Editor.app" 1.0
INTERACTIVE=1
# The second yes would confirm the second tile if setup asked twice; asked once,
# it answers the settings-pane question, whose open goes to the test double.
answers yes yes no
run_wu setup
check_status "two tiles: setup exits 0" 0
testing_check "two tiles: asked once" 1 "$(LC_ALL=C grep -c 'Confirm Example Editor as cask example-editor' "$OUT")"
testing_check "two tiles: one section appended" 1 "$(LC_ALL=C grep -c -x '\[app com\.example\.editor\]' "$HOME_DIR/.config/weekly-update/config")"
INTERACTIVE=0
run_wu plist
check_status "two tiles: the config stays valid" 0

printf '== vendor and manual rows make the tool do less\n'
new_sandbox
basic_fixture
set_outdated firefox
cask_info firefox 131.0 Firefox.app 130.0
write_config '[app org.mozilla.firefox]' 'cask = firefox' 'group = manual' '[app dev.zed.Zed]' 'group = vendor'
run_wu auto
check_calls_lacks "a manual app is not upgraded" '^brew upgrade'
check_out_has "the vendor row is shown as vendor" 'Zed +0\.150\.0 +- +no index +vendor'
check_i8 "vendor and manual"

printf '== also_matches, open_as and version_drop_leading\n'
new_sandbox
basic_fixture
make_app "Example Browser" com.example.browser.helper 129.1.2.3
write_dock "Example Browser:com.example.browser.helper"
cask_info example-browser 1.2.3 "Example Browser.app" 1.2.3
write_config '[app com.example.browser]' 'cask = example-browser' 'also_matches = com.example.browser.helper' \
  'open_as = com.example.browser' 'version_drop_leading = 1' 'open_warning = Opening it restores every tab'
run_wu check
check_out_has "the Dock tile is matched through also_matches and compared after the prefix" 'Example Browser +129\.1\.2\.3 +1\.2\.3 +same +silent +confirmed'
make_app "Example Browser" com.example.browser.helper 129.2.0
run_wu check
check_out_has "a version of another shape is unordered, not newer" 'Example Browser +129\.2\.0 +1\.2\.3 +unordered'

printf '== check calls a record stale only when brew outdated does not list the app\n'
new_sandbox
basic_fixture
cask_info firefox 131.0 Firefox.app 130.0
set_outdated firefox
run_wu check
check_status "check, outdated app: exit 0" 0
check_calls_has "check asks Homebrew which casks are outdated" '^brew outdated --cask --json=v2$'
check_out_lacks "check, outdated app: no stale-record claim" 'record already matches'
check_out_has "check, outdated app: says Homebrew has a newer version" 'Homebrew lists a newer version of: Firefox$'
check_calls_lacks "check, outdated app: changes nothing" '^(brew (update|upgrade|install)|sudo|open|launchctl (bootstrap|bootout))|to quit|osascript'
run_wu auto --dry-run
check_out_has "check and auto --dry-run agree on the same state" 'Would upgrade Firefox with Homebrew \(cask firefox\)'
check_i8 "check and auto --dry-run"
cask_info firefox 131.0 Firefox.app 131.0
set_outdated
run_wu check
check_status "check, stale record: exit 0" 0
check_out_has "control: a stale record is still reported" "Firefox is 130\\.0 against index 131\\.0, but Homebrew's record already matches the index"
cask_info firefox 131.0 Firefox.app 130.0
printf '1\n' > "$STATE/scenario/brew/outdated.status"
run_wu check
check_status "check, failed outdated query: exit 1" 1
check_out_has "check, failed outdated query: named" 'Check finished with issues: .*query\(outdated\)'
check_out_lacks "check, failed outdated query: no stale-record guess" 'record already matches'
printf '0\n' > "$STATE/scenario/brew/outdated.status"
set_outdated firefox
write_config '[app org.mozilla.firefox]' 'cask = firefox' 'group = manual'
run_wu auto
check_out_lacks "a manual app that brew outdated lists is never called stale" 'record already matches'
check_i8 "manual outdated"

six_apps() {
  make_app Firefox org.mozilla.firefox 130.0
  make_app Zed dev.zed.Zed 0.150.0
  make_app "Visual Studio Code" com.microsoft.VSCode 1.93.0
  make_app "Example Tool" com.example.tool 2.0
  make_app "Example Agent" com.example.agent 3.0
  make_app "Example Clean" com.example.clean 1.0
  write_dock Firefox:org.mozilla.firefox Zed:dev.zed.Zed "Visual Studio Code:com.microsoft.VSCode" \
    "Example Tool:com.example.tool" "Example Agent:com.example.agent" "Example Clean:com.example.clean"
  write_config '[app org.mozilla.firefox]' 'cask = firefox' '[app dev.zed.Zed]' 'cask = zed' \
    '[app com.microsoft.VSCode]' 'cask = visual-studio-code' '[app com.example.tool]' 'cask = example-tool' \
    '[app com.example.agent]' 'cask = example-agent' '[app com.example.clean]' 'cask = example-clean'
  set_ac
  set_active 0
}

printf '== an adoption Homebrew could roll back is refused, one blocking artifact at a time\n'
new_sandbox
six_apps
cask_info firefox 130.0 Firefox.app "" '[{"quit":"org.mozilla.firefox"}]' '{"pkg":["Firefox.pkg"]}'
cask_info zed 0.150.0 Zed.app "" '[{"quit":"dev.zed.Zed"}]' '{"postflight":null}'
cask_info visual-studio-code 1.93.0 "Visual Studio Code.app" "" '[{"quit":"com.microsoft.VSCode"}]' '{"preflight":null}'
cask_info example-tool 2.0 "Example Tool.app" "" '[{"quit":"com.example.tool"}]' '{"installer":[{"manual":"Example Installer.app"}]}'
cask_info example-agent 3.0 "Example Agent.app" "" '[{"quit":"com.example.agent"}]' '{"uninstall_postflight":null}'
cask_info example-clean 1.0 "Example Clean.app" "" '[{"quit":"com.example.clean"}]'
INTERACTIVE=1
answers yes no
run_wu setup
check_status "adoption refusals: setup exits 0" 0
check_out_has "a pkg blocks adoption and is named" 'Firefox not adopted: its cask has steps Homebrew could roll back \(pkg\)'
check_out_has "a postflight blocks adoption and is named" 'Zed not adopted: its cask has steps Homebrew could roll back \(postflight\)'
check_out_has "a preflight blocks adoption and is named" 'Visual Studio Code not adopted: its cask has steps Homebrew could roll back \(preflight\)'
check_out_has "an installer blocks adoption and is named" 'Example Tool not adopted: its cask has steps Homebrew could roll back \(installer\)'
check_out_has "an uninstall_postflight blocks adoption and is named" 'Example Agent not adopted: its cask has steps Homebrew could roll back \(uninstall_postflight\)'
check_calls_lacks "no blocked cask is adopted" 'install --cask --adopt( --no-binaries)? (firefox|zed|visual-studio-code|example-tool|example-agent)$'
check_calls_has "control: a cask with only safe artifacts is adopted after a yes, without its command-line links" '^brew install --cask --adopt --no-binaries example-clean$'
check_brew_env "adoption refusals"

printf '== an uninstall stanza that does more than quit or signal keeps an app out of the unattended pass\n'
new_sandbox
six_apps
cask_info firefox 131.0 Firefox.app 130.0 '[{"quit":"org.mozilla.firefox","delete":"/Library/Example/Firefox"}]'
cask_info zed 0.151.0 Zed.app 0.150.0 '[{"script":{"executable":"uninstall.sh"}}]'
cask_info visual-studio-code 1.94.0 "Visual Studio Code.app" 1.93.0 '[{"launchctl":"com.example.helper"}]'
cask_info example-tool 2.1 "Example Tool.app" 2.0 '[{"quit":"com.example.tool","pkgutil":"com.example.tool.pkg"}]'
cask_info example-agent 3.1 "Example Agent.app" 3.0 '[{"quit":"com.example.agent","signal":["TERM","com.example.agent"],"on_upgrade":"signal"}]'
cask_info example-clean 1.1 "Example Clean.app" 1.0 '[{"quit":"com.example.clean","signal":["TERM","com.example.clean"]}]'
set_outdated firefox zed visual-studio-code example-tool example-agent example-clean
printf '%s\n' "$S/Applications/Example Clean.app" > "$STATE/scenario/brew/upgrade-example-clean.app"
printf '1.1\n' > "$STATE/scenario/brew/upgrade-example-clean.version"
run_wu auto
check_status "uninstall stanzas: exit 0" 0
check_out_has "delete makes an app assisted" 'Firefox +130\.0 +131\.0 +older +assisted'
check_out_has "script makes an app assisted" 'Zed +0\.150\.0 +0\.151\.0 +older +assisted'
check_out_has "launchctl makes an app assisted" 'Visual Studio Code +1\.93\.0 +1\.94\.0 +older +assisted'
check_out_has "pkgutil makes an app assisted" 'Example Tool +2\.0 +2\.1 +older +assisted'
check_out_has "on_upgrade makes an app assisted" 'Example Agent +3\.0 +3\.1 +older +assisted'
check_out_has "quit and signal only stay silent" 'Example Clean +1\.0 +1\.1 +older +silent'
check_calls_lacks "no app with a wider uninstall stanza is upgraded unattended" '^brew upgrade --cask (firefox|zed|visual-studio-code|example-tool|example-agent) '
check_calls_has "control: quit and signal only is upgraded unattended" '^brew upgrade --cask example-clean NO_UPGRADE_QUIT_CASKS=1$'
check_file_has "the others wait for a person" "$(history_file)" 'assisted-pending=\[Firefox, Zed, Visual Studio Code, Example Tool, Example Agent\]'
check_out_has "a skipped assisted app is named by its group, whatever made it assisted" 'Firefox is in the assisted group, so only the interactive run upgrades it'
check_out_has "the legend says only an interactive pass upgrades an assisted app" 'assisted: only an interactive pass upgrades it'
check_i8 "uninstall stanzas"

# zed_link_fixture: Zed is outdated, managed and silent-capable, its cask has
# a binary linked as <prefix>/bin/zed, and the brew double knows that path.
zed_link_fixture() {
  new_sandbox
  basic_fixture
  printf '%s\n' "$S/prefix" > "$STATE/scenario/brew/prefix"
  mkdir -p "$S/prefix/bin"
  set_outdated zed
  cask_info zed 0.151.0 Zed.app 0.150.0 '[{"quit":"dev.zed.Zed"}]' '{"binary":["$APPDIR/Zed.app/Contents/MacOS/cli",{"target":"zed"}]}'
  : > "$S/Applications/Zed.app/Contents/MacOS/cli"
  printf '%s\n' "$S/prefix/bin/zed" > "$STATE/scenario/brew/upgrade-zed.link"
  printf '%s\n' "$S/Applications/Zed.app/Contents/MacOS/cli" > "$STATE/scenario/brew/upgrade-zed.link-target"
  printf '%s\n' "$S/Applications/Zed.app" > "$STATE/scenario/brew/upgrade-zed.app"
  printf '0.151.0\n' > "$STATE/scenario/brew/upgrade-zed.version"
}
zed_version() { plutil -extract CFBundleShortVersionString raw -o - "$S/Applications/Zed.app/Contents/Info.plist" 2>/dev/null || printf gone; }

printf '== an unattended upgrade keeps the command-line link of a cask with a binary\n'
zed_link_fixture
ln -s "$S/Applications/Zed.app/Contents/MacOS/cli" "$S/prefix/bin/zed"
OUT=$S/out-binary.txt
seam_env HOMEBREW_CASK_OPTS=--no-binaries /bin/bash "$RUNTIME" auto > "$OUT" 2>&1
RC=$?
check_status "binary link: exit 0" 0
check_out_has "binary link: a cask with a binary can be silent" 'Zed +0\.150\.0 +0\.151\.0 +older +silent'
check_calls_has "binary link: upgraded unattended" '^brew upgrade --cask zed NO_UPGRADE_QUIT_CASKS=1$'
check_file_lacks "binary link: no Homebrew call ran with --no-binaries, not even one from the caller's environment" "$STATE/brew-env.log" 'no-binaries'
testing_check "binary link: the command-line link is there after the upgrade" yes "$( [ -L "$S/prefix/bin/zed" ] && printf yes || printf no )"
testing_check "binary link: the app is at the new version" 0.151.0 "$(zed_version)"
check_brew_env "binary link"
check_i8 "binary link"

printf '== a file, not a link, where a command-line link goes: no upgrade and no adoption, in any mode\n'
# Homebrew fails that upgrade, fails its revert on the same file, and undoing
# the revert removes the app. The brew double does the same, so an upgrade
# that got through would show here as a missing app.
zed_link_fixture
printf 'a zed command copied here by hand\n' > "$S/prefix/bin/zed"
run_wu auto
check_status "in the way, auto: exit 1" 1
check_out_has "in the way, auto: the file is named" "Zed: $S/prefix/bin/zed is a file, not a link, where Homebrew puts a link for this app \\(a command, a shell completion or a man page\\)"
check_out_has "in the way, auto: not in the silent group" 'Zed +0\.150\.0 +0\.151\.0 +older +assisted'
check_calls_lacks "in the way, auto: no upgrade" '^brew upgrade'
testing_check "in the way, auto: the app is intact" 0.150.0 "$(zed_version)"
testing_check "in the way, auto: the file is untouched" "a zed command copied here by hand" "$(cat "$S/prefix/bin/zed")"
check_file_has "in the way, auto: recorded as a failure" "$(history_file)" 'failures=[^ ]*in-the-way\(Zed\)'
check_file_lacks "in the way, auto: never reported as nothing to do" "$STATE/notifications.log" 'Nothing needs you'
check_i8 "in the way, auto"
INTERACTIVE=1
answers yes yes yes
run_wu run
check_status "in the way, run: exit 1" 1
check_out_has "in the way, run: the file is named" "Zed: $S/prefix/bin/zed is a file, not a link"
check_out_lacks "in the way, run: never offered for upgrade" 'Upgrade these'
check_calls_lacks "in the way, run: no upgrade after yes answers" '^brew upgrade'
testing_check "in the way, run: the app is intact" 0.150.0 "$(zed_version)"
cask_info zed 0.151.0 Zed.app "" '[{"quit":"dev.zed.Zed"}]' '{"binary":["$APPDIR/Zed.app/Contents/MacOS/cli",{"target":"zed"}]}'
answers yes yes yes
run_wu setup
check_status "in the way, setup: exit 0" 0
check_out_has "in the way, setup: the refusal names the path" "Zed not adopted: $S/prefix/bin/zed is in the way of a link Homebrew makes for it"
check_calls_lacks "in the way, setup: no adoption" 'install --cask --adopt'
testing_check "in the way, setup: the app is intact" 0.150.0 "$(zed_version)"
INTERACTIVE=0
[ ! -e "$STATE/running/dev.zed.Zed" ] || mv "$STATE/running/dev.zed.Zed" "$STATE/running/.closed-by-test-dev.zed.Zed"
mv "$S/prefix/bin/zed" "$S/zed.moved-by-test"
ln -s "$S/Applications/Zed.app/Contents/MacOS/cli" "$S/prefix/bin/zed"
cask_info zed 0.151.0 Zed.app 0.150.0 '[{"quit":"dev.zed.Zed"}]' '{"binary":["$APPDIR/Zed.app/Contents/MacOS/cli",{"target":"zed"}]}'
mv "$(history_file)" "$HOME_DIR/Library/Logs/weekly-update/history-before.tsv"
reset_calls
run_wu auto
check_status "control, a link at that path: exit 0" 0
check_calls_has "control, a link at that path: upgraded" '^brew upgrade --cask zed NO_UPGRADE_QUIT_CASKS=1$'
testing_check "control, a link at that path: linked again" yes "$( [ -L "$S/prefix/bin/zed" ] && printf yes || printf no )"
testing_check "control, a link at that path: the app is at the new version" 0.151.0 "$(zed_version)"
check_i8 "control, a link at that path"

printf '== a file in the way of an app that matches its index: named, but no failure\n'
# A failure every week would open a window for an app with nothing to upgrade,
# so the failure waits until Homebrew lists the app as outdated.
zed_link_fixture
set_outdated
cask_info zed 0.150.0 Zed.app 0.150.0 '[{"quit":"dev.zed.Zed"}]' '{"binary":["$APPDIR/Zed.app/Contents/MacOS/cli",{"target":"zed"}]}'
printf 'a zed command copied here by hand\n' > "$S/prefix/bin/zed"
run_wu auto
check_status "in the way, current: exit 0" 0
check_out_has "in the way, current: the file is named" "Zed: $S/prefix/bin/zed is a file, not a link"
check_out_has "in the way, current: not in the silent group" 'Zed +0\.150\.0 +0\.150\.0 +same +assisted'
testing_check "in the way, current: the pass completes" completed "$(last_outcome)"
check_file_has "in the way, current: no failure recorded" "$(history_file)" 'failures=- '
check_file_has "in the way, current: nothing needs you" "$STATE/notifications.log" 'Nothing needs you'
check_calls_lacks "in the way, current: no upgrade" '^brew upgrade'
testing_check "in the way, current: the file is untouched" "a zed command copied here by hand" "$(cat "$S/prefix/bin/zed")"
check_i8 "in the way, current"

printf '== a file that appears after the inventory still stops the upgrade\n'
# The run blocks at its first question, the file appears, and only then does
# the answer arrive, so the inventory saw the path free and only the re-check
# in upgrade_cask can see the file.
zed_link_fixture
INTERACTIVE=1
mkfifo "$S/tty"
exec 7<>"$S/tty"
TTY_FILE=$S/tty
OUT=$S/out-late-file.txt
seam_env /bin/bash "$RUNTIME" run > "$OUT" 2>&1 &
pass=$!
waited=0
until LC_ALL=C grep -q 'Upgrade these' "$OUT" 2>/dev/null || [ "$waited" -ge 300 ]; do
  sleep 0.2
  waited=$((waited + 1))
done
check_out_has "late file: the inventory saw the path free" 'Zed +0\.150\.0 +0\.151\.0 +older +silent'
check_out_has "late file: the upgrade was offered" 'Upgrade these 1 app'
printf 'a zed command copied here by hand\n' > "$S/prefix/bin/zed"
printf 'yes\nno\nno\nno\n' >&7
wait "$pass"
RC=$?
exec 7>&-
TTY_FILE=""
INTERACTIVE=0
check_status "late file: exit 1" 1
check_calls_lacks "late file: no upgrade" '^brew upgrade'
testing_check "late file: the app is intact" 0.150.0 "$(zed_version)"
check_out_has "late file: the file is named" "Zed: $S/prefix/bin/zed is a file, not a link"
check_file_has "late file: recorded as a failure" "$(history_file)" 'failures=[^ ]*in-the-way\(Zed\)'

printf '== a file where a folder of a link path should be\n'
zed_link_fixture
mv "$S/prefix/bin" "$S/prefix/bin.moved-by-test"
printf 'a file named bin\n' > "$S/prefix/bin"
run_wu auto
check_status "file for a folder: exit 1" 1
check_out_has "file for a folder: the file is named" "Zed: $S/prefix/bin is a file, not a folder, where Homebrew needs a folder"
check_out_has "file for a folder: not in the silent group" 'Zed +0\.150\.0 +0\.151\.0 +older +assisted'
check_calls_lacks "file for a folder: no upgrade" '^brew upgrade'
testing_check "file for a folder: the app is intact" 0.150.0 "$(zed_version)"
check_file_has "file for a folder: recorded as a failure" "$(history_file)" 'failures=[^ ]*in-the-way\(Zed\)'
check_i8 "file for a folder"
INTERACTIVE=1
answers yes yes yes
cask_info zed 0.151.0 Zed.app "" '[{"quit":"dev.zed.Zed"}]' '{"binary":["$APPDIR/Zed.app/Contents/MacOS/cli",{"target":"zed"}]}'
run_wu setup
INTERACTIVE=0
check_out_has "file for a folder, setup: the refusal names the file" "Zed not adopted: $S/prefix/bin is in the way of a link Homebrew makes for it"
check_calls_lacks "file for a folder, setup: no adoption" 'install --cask --adopt'

printf '== a link folder this account cannot write keeps an app out of the unattended pass\n'
# Homebrew would link there with sudo, which has no terminal in a slot.
zed_link_fixture
ln -s "$S/Applications/Zed.app/Contents/MacOS/cli" "$S/prefix/bin/zed"
chmod 555 "$S/prefix/bin"
run_wu auto
chmod 755 "$S/prefix/bin"
check_status "read-only link folder: exit 0" 0
check_out_has "read-only link folder: the folder is named" "Zed: Homebrew would need the administrator password to link into $S/prefix/bin"
check_out_has "read-only link folder: assisted, not silent" 'Zed +0\.150\.0 +0\.151\.0 +older +assisted'
check_calls_lacks "read-only link folder: no unattended upgrade" '^brew upgrade'
check_file_has "read-only link folder: it waits for a person" "$(history_file)" 'assisted-pending=\[Zed\]'
testing_check "read-only link folder: the app is intact" 0.150.0 "$(zed_version)"
check_i8 "read-only link folder"
mv "$(history_file)" "$HOME_DIR/Library/Logs/weekly-update/history-before.tsv"
reset_calls
run_wu auto
check_status "control, a writable link folder: exit 0" 0
check_out_lacks "control, a writable link folder: no password line" 'administrator password to link'
check_calls_has "control, a writable link folder: upgraded unattended" '^brew upgrade --cask zed NO_UPGRADE_QUIT_CASKS=1$'
check_i8 "control, a writable link folder"

printf '== each kind of link is looked for where Homebrew puts it\n'
new_sandbox
basic_fixture
printf '%s\n' "$S/prefix" > "$STATE/scenario/brew/prefix"
while IFS='|' read -r kind args relative expected; do
  cask_info zed 0.150.0 Zed.app 0.150.0 '[{"quit":"dev.zed.Zed"}]' "{\"$kind\":$args}"
  mkdir -p "$S/prefix/${relative%/*}"
  : > "$S/prefix/$relative"
  run_wu check
  check_status "$kind: check exits 0" 0
  check_out_has "$kind: the file in the way is named" "$expected"
  check_out_has "$kind: not in the silent group" 'Zed +0\.150\.0 +0\.150\.0 +same +assisted'
  mv "$S/prefix/$relative" "$S/prefix/$relative.moved-by-test"
  run_wu check
  check_out_lacks "$kind: control, nothing named once the file is gone" 'Zed: .* is a file, not a link'
done <<'EOF'
binary|["$APPDIR/Zed.app/Contents/MacOS/cli"]|bin/cli|prefix/bin/cli is a file, not a link
command_wrapper|["zedw",{"executable":"/usr/bin/true"}]|bin/zedw|prefix/bin/zedw is a file, not a link
bash_completion|["$APPDIR/Zed.app/Contents/Resources/zed.bash"]|etc/bash_completion.d/zed|prefix/etc/bash_completion.d/zed is a file, not a link
zsh_completion|["$APPDIR/Zed.app/Contents/Resources/zed.zsh"]|share/zsh/site-functions/_zed|prefix/share/zsh/site-functions/_zed is a file, not a link
fish_completion|["$APPDIR/Zed.app/Contents/Resources/zed"]|share/fish/vendor_completions.d/zed.fish|prefix/share/fish/vendor_completions.d/zed.fish is a file, not a link
pwsh_completion|["$APPDIR/Zed.app/Contents/Resources/zed.ps1"]|share/pwsh/completions/_zed.ps1|prefix/share/pwsh/completions/_zed.ps1 is a file, not a link
manpage|["$APPDIR/Zed.app/Contents/Resources/zed.1"]|share/man/man1/zed.1|prefix/share/man/man1/zed.1 is a file, not a link
EOF
cask_info zed 0.150.0 Zed.app 0.150.0 '[{"quit":"dev.zed.Zed"}]' '{"binary":["cli",{"target":"$HOMEBREW_CELLAR/zed"}]}'
run_wu check
check_out_has "a link path it cannot place is treated as in the way" "Zed: Homebrew's entry names a link this tool cannot place"
check_out_has "a link path it cannot place: not in the silent group" 'Zed +0\.150\.0 +0\.150\.0 +same +assisted'
printf '== a file in the way of a PowerShell completion stops the interactive upgrade\n'
zed_link_fixture
cask_info zed 0.151.0 Zed.app 0.150.0 '[{"quit":"dev.zed.Zed"}]' '{"pwsh_completion":["$APPDIR/Zed.app/Contents/Resources/zed.ps1"]}'
mkdir -p "$S/prefix/share/pwsh/completions"
printf 'a completion copied here by hand\n' > "$S/prefix/share/pwsh/completions/_zed.ps1"
printf '%s\n' "$S/prefix/share/pwsh/completions/_zed.ps1" > "$STATE/scenario/brew/upgrade-zed.link"
INTERACTIVE=1
answers yes
run_wu run
INTERACTIVE=0
check_status "pwsh completion in the way, run: exit 1" 1
check_calls_lacks "pwsh completion in the way, run: no upgrade" '^brew upgrade'
check_file_has "pwsh completion in the way, run: recorded as a failure" "$(history_file)" 'failures=[^ ]*in-the-way\(Zed\)'
testing_check "pwsh completion in the way, run: the app is intact" 0.150.0 "$(zed_version)"

printf '== the answer shape of current Homebrew: a resolved target beside each moved or linked artifact\n'
# zed_info_with_targets LINK_TARGET: the Zed entry as recent Homebrew prints
# it. The target field is a path, not an artifact kind, and for a link it is
# the path Homebrew will link.
zed_info_with_targets() {
  printf '{"casks":[{"token":"zed","version":"0.151.0","installed":"0.150.0","auto_updates":true,"artifacts":[{"uninstall":[{"quit":"dev.zed.Zed"}]},{"app":["Zed.app"],"target":"%s"},{"binary":["$APPDIR/Zed.app/Contents/MacOS/cli",{"target":"zed"}],"target":"%s"},{"zap":[{"trash":["~/Library/Caches/x"]}]}]}]}\n' \
    "$S/Applications/Zed.app" "$1" > "$STATE/scenario/brew/info-zed.json"
}
zed_link_fixture
zed_info_with_targets "$S/prefix/bin/zed"
ln -s "$S/Applications/Zed.app/Contents/MacOS/cli" "$S/prefix/bin/zed"
run_wu auto
check_status "target field: exit 0" 0
check_out_has "target field: not read as an artifact kind, so the app can be silent" 'Zed +0\.150\.0 +0\.151\.0 +older +silent'
check_calls_has "target field: upgraded unattended" '^brew upgrade --cask zed NO_UPGRADE_QUIT_CASKS=1$'
testing_check "target field: linked again" yes "$( [ -L "$S/prefix/bin/zed" ] && printf yes || printf no )"
testing_check "target field: the app is at the new version" 0.151.0 "$(zed_version)"
check_i8 "target field"
zed_link_fixture
mkdir -p "$S/elsewhere"
printf 'a zed command copied here by hand\n' > "$S/elsewhere/zed"
ln -s "$S/Applications/Zed.app/Contents/MacOS/cli" "$S/prefix/bin/zed"
zed_info_with_targets "$S/elsewhere/zed"
run_wu auto
check_status "target field in the way: exit 1" 1
check_out_has "target field in the way: the resolved target is the path checked" "Zed: $S/elsewhere/zed is a file, not a link"
check_calls_lacks "target field in the way: no upgrade" '^brew upgrade'
testing_check "target field in the way: the app is intact" 0.150.0 "$(zed_version)"
check_i8 "target field in the way"
zed_link_fixture
zed_info_with_targets zed
run_wu_within 120 auto
check_status "a relative target: exit 1, and within 120 seconds" 1
check_out_has "a relative target is treated as in the way" "Zed: Homebrew's entry names a link this tool cannot place \\(zed\\)"
check_out_has "a relative target: not in the silent group" 'Zed +0\.150\.0 +0\.151\.0 +older +assisted'
check_calls_lacks "a relative target: no upgrade" '^brew upgrade'
check_i8 "a relative target"

printf '== a cask whose app name differs from the bundle is left to the person\n'
new_sandbox
basic_fixture
set_outdated firefox
cask_info firefox 131.0 "Firefox Developer Edition.app" 130.0
run_wu auto
check_status "app name differs: exit 0" 0
check_out_has "app name differs: grouped manual" 'Firefox +130\.0 +131\.0 +older +manual'
check_calls_lacks "app name differs: not upgraded" '^brew upgrade'
check_i8 "app name differs"

printf '== a long app name with a non-ASCII letter keeps the report valid UTF-8 under the C locale\n'
new_sandbox
basic_fixture
long_name="Example Application Nam$(printf '\303\234')e"
make_app "$long_name" com.example.long 1.0
write_dock Firefox:org.mozilla.firefox "$long_name:com.example.long"
run_wu check
check_status "long name: check exits 0" 0
testing_check "a long non-ASCII name keeps the report valid UTF-8" 0 "$(iconv -f UTF-8 -t UTF-8 "$OUT" >/dev/null 2>&1; printf '%s' "$?")"

testing_verdict
