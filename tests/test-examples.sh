#!/bin/bash
# test-examples.sh: the example config is safe to copy and true to the code.
# As shipped it loads with no refused line and changes nothing, every range
# it states is the schema's, each worked example validates on its own and
# does what its comment says, and a wrong value is refused with its line.
# shellcheck source-path=SCRIPTDIR
set -u
set -o pipefail
# shellcheck source=harness.sh
. "${0%/*}/harness.sh"

EXAMPLE=$REPO/config/weekly-update.conf.example

config_path() { printf '%s' "$HOME_DIR/.config/weekly-update/config"; }

copy_example() { cp "$EXAMPLE" "$(config_path)"; }

block_ids() { LC_ALL=C sed -n 's/^# \[app \(.*\)\]$/\1/p' "$EXAMPLE"; }

# write_dock replaces the whole Dock, so the fixture's four tiles come first.
dock_with() {
  write_dock Firefox:org.mozilla.firefox Zed:dev.zed.Zed "Visual Studio Code:com.microsoft.VSCode" Safari:com.apple.Safari "$@"
}

# uncomment_block ID: the "# [app ID]" header and the "# key = value" lines
# under it lose their "# ", up to the first line that is neither.
uncomment_block() {
  local file
  file=$(config_path)
  LC_ALL=C awk -v header="# [app $1]" '
    $0 == header { on = 1 }
    on && /^# (\[app |[a-z_]+ = )/ { print substr($0, 3); next }
    { on = 0; print }' "$file" > "$file.next" && mv "$file.next" "$file"
  testing_check "example $1: its block was uncommented" 1 "$(LC_ALL=C grep -c -x -F "[app $1]" "$file")"
}

# set_live KEY VALUE: rewrites the one live "KEY = ..." line.
set_live() {
  local file
  file=$(config_path)
  LC_ALL=C sed "s/^$1 = .*/$1 = $2/" "$file" > "$file.next" && mv "$file.next" "$file"
  testing_check "$1 = $2 was written" 1 "$(LC_ALL=C grep -c -x -F "$1 = $2" "$file")"
}

check_loads() {
  run_wu check
  check_status "$1: check exits 0" 0
  check_out_has "$1: the file was read, not the defaults" 'Config: loaded'
  check_out_lacks "$1: no line is refused" 'config:[0-9]+:'
}

notes_fixture() {
  new_sandbox
  basic_fixture
  make_app "Example Notes" com.example.notes 2.0
  cask_info example-notes 2.1 "Example Notes.app" 2.0
  dock_with "Example Notes:com.example.notes"
  set_outdated example-notes
  printf '%s\n' "$S/Applications/Example Notes.app" > "$STATE/scenario/brew/upgrade-example-notes.app"
  printf '2.1\n' > "$STATE/scenario/brew/upgrade-example-notes.version"
  copy_example
  uncomment_block com.example.notes
}

printf '== the example as shipped loads and changes nothing\n'
new_sandbox
basic_fixture
copy_example
testing_check "as shipped: no [app] block is live" 0 "$(LC_ALL=C grep -c '^\[app ' "$(config_path)")"
testing_check "as shipped: [updater] is the only live section" "[updater]" "$(LC_ALL=C grep '^\[' "$(config_path)" | tr '\n' ' ' | sed 's/ $//')"
check_loads "as shipped"
run_wu plist
check_status "as shipped: plist exits 0" 0
cp "$OUT" "$S/plist-from-example.txt"
mv "$(config_path)" "$S/config.moved-by-test"
run_wu plist
check_status "no config: plist exits 0" 0
testing_check "as shipped: the schedule and the label are the defaults (plist unchanged)" yes "$( cmp -s "$OUT" "$S/plist-from-example.txt" && printf yes || printf no )"
for key in weekday first_hour last_hour minute battery_floor quit_wait entry_wait nudge_give_up index_timeout query_timeout list_timeout slow_warn final_prompt_timeout heartbeat_days; do
  expected=$(LC_ALL=C sed -n "s/^  [A-Z_]*=\$(updater_value $key \([0-9][0-9]*\))\$/\1/p" "$RUNTIME")
  testing_check "the runtime states a default for $key" yes "$( [ -n "$expected" ] && printf yes || printf no )"
  testing_check "as shipped: the live $key is the runtime default" "$expected" "$(LC_ALL=C sed -n "s/^$key = //p" "$EXAMPLE")"
done

printf '== every range the example states is the schema'"'"'s\n'
ranged=0
while read -r kind key minimum maximum; do
  [ -n "$key" ] || continue
  ranged=$((ranged + 1))
  testing_check "the example states $kind $key as $minimum to $maximum in the paragraph that names the key" yes \
    "$(LC_ALL=C awk -v key="$key" -v range="$minimum to $maximum" 'BEGIN { RS = "" } index($0, key) && $0 ~ ("(^|[^0-9])" range "([^0-9]|$)") { found = 1 } END { print (found ? "yes" : "no") }' "$EXAMPLE")"
done <<EOF
$(LC_ALL=C sed -E -n 's/^  conf_schema_key (updater|app) ([a-z_]+) int:([0-9]+):([0-9]+)$/\1 \2 \3 \4/p' "$RUNTIME")
EOF
testing_check "the schema's ranged keys were read (at least 15)" yes "$( [ "$ranged" -ge 15 ] && printf yes || printf no )"

printf '== each worked example validates on its own and does what its comment says\n'
ids=$(block_ids)
testing_check "the example has its worked examples (at least 10 blocks)" yes "$( [ "$(printf '%s\n' "$ids" | LC_ALL=C grep -c .)" -ge 10 ] && printf yes || printf no )"
for id in $ids; do
  new_sandbox
  basic_fixture
  case $id in
    com.google.Chrome)
      make_app Chrome com.google.Chrome 129.0
      dock_with Chrome:com.google.Chrome
      ;;
    us.zoom.xos)
      make_app Zoom us.zoom.xos 6.0.0
      dock_with Zoom:us.zoom.xos
      ;;
    com.example.browser)
      make_app "Example Browser" com.example.browser.helper 1.2.3
      cask_info example-browser 1.2.3 "Example Browser.app" 1.2.3
      dock_with "Example Browser:com.example.browser.helper"
      ;;
    com.example.suite)
      make_app "Example Suite" com.example.suite 3.0
      cask_info example-suite 3.0 "Example Suite.app" 3.0
      dock_with "Example Suite:com.example.suite"
      ;;
    com.example.editor)
      make_app "Example Editor" com.example.editor 1.0.0
      cask_info example-editor 1.1.0 "Example Editor.app" 1.0.0
      dock_with "Example Editor:com.example.editor"
      ;;
    com.example.tool)
      make_app "Example Tool" com.example.tool 129.1.2.3
      cask_info example-tool 1.2.3 "Example Tool.app" 1.2.3
      dock_with "Example Tool:com.example.tool"
      ;;
    com.example.notes)
      make_app "Example Notes" com.example.notes 2.0
      cask_info example-notes 2.1 "Example Notes.app" 2.0
      dock_with "Example Notes:com.example.notes"
      ;;
  esac
  copy_example
  uncomment_block "$id"
  check_loads "example $id"
  case $id in
    org.mozilla.firefox)
      check_out_has "example $id: the cask line confirms Firefox" 'Firefox +130\.0 +130\.0 +same +silent +confirmed'
      ;;
    com.microsoft.VSCode)
      check_out_has "example $id: the cask line confirms Visual Studio Code" 'Visual Studio Code +1\.93\.0 +1\.93\.0 +same +silent +confirmed'
      ;;
    dev.zed.Zed)
      check_out_has "example $id: the cask line confirms Zed" 'Zed +0\.150\.0 +0\.150\.0 +same +silent +confirmed'
      ;;
    com.google.Chrome)
      check_out_has "example $id: the vendor row is shown as vendor" 'Chrome +129\.0 +- +no index +vendor'
      check_out_lacks "example $id: a vendor app is not listed under No cask found" 'No cask found for: .*Chrome'
      ;;
    us.zoom.xos)
      check_out_has "example $id: the vendor row is shown as vendor" 'Zoom +6\.0\.0 +- +no index +vendor'
      check_out_lacks "example $id: a vendor app is not listed under No cask found" 'No cask found for: .*Zoom'
      ;;
    com.example.browser)
      check_out_has "example $id: the tile is matched through also_matches and confirmed" 'Example Browser +1\.2\.3 +1\.2\.3 +same +silent +confirmed'
      ;;
    com.example.suite)
      check_out_has "example $id: the cask line confirms the app" 'Example Suite +3\.0 +3\.0 +same +silent +confirmed'
      ;;
    com.example.editor)
      check_out_has "example $id: the app is behind its index" 'Example Editor +1\.0\.0 +1\.1\.0 +older +silent +confirmed'
      INTERACTIVE=1
      run_wu run --dry-run
      INTERACTIVE=0
      check_status "example $id: an interactive dry run exits 0" 0
      check_out_has "example $id: the warning is printed with the app's name" "Example Editor: Opening it restores every window from last time"
      check_out_has "example $id: the warning comes before the question to open the app" 'Would ask, then open: Example Editor'
      ;;
    com.example.tool)
      check_out_has "example $id: one leading part is dropped and the versions compare as same" 'Example Tool +129\.1\.2\.3 +1\.2\.3 +same +silent +confirmed'
      set_live version_drop_leading 0
      run_wu check
      check_out_has "example $id: with 0 the app reads as newer than the index" 'Example Tool +129\.1\.2\.3 +1\.2\.3 +newer'
      set_live version_drop_leading 2
      run_wu check
      check_out_has "example $id: a drop that leaves the shapes apart reads as unordered" 'Example Tool +129\.1\.2\.3 +1\.2\.3 +unordered'
      ;;
    com.example.notes)
      check_out_has "example $id: the manual app is still compared with the index" 'Example Notes +2\.0 +2\.1 +older +manual +confirmed'
      ;;
  esac
done

printf '== group = manual keeps Homebrew from upgrading the app; without it the same app is upgraded\n'
notes_fixture
run_wu auto
check_status "manual: auto exits 0" 0
check_calls_lacks "manual: Homebrew never upgrades the app" '^brew upgrade'
check_out_has "manual: the app is still reported as older" 'Example Notes +2\.0 +2\.1 +older +manual +confirmed'
check_i8 "manual"
notes_fixture
LC_ALL=C sed '/^group = manual$/d' "$(config_path)" > "$(config_path).next" && mv "$(config_path).next" "$(config_path)"
testing_check "control: the group line was removed" 0 "$(LC_ALL=C grep -c -x -F 'group = manual' "$(config_path)")"
run_wu auto
check_calls_has "control: without the group line auto upgrades the app" '^brew upgrade --cask example-notes'
check_i8 "control"

printf '== a wrong value is refused with its line, and nothing runs\n'
while IFS='|' read -r block key wrong pattern; do
  [ -n "$key" ] || continue
  new_sandbox
  basic_fixture
  copy_example
  [ -z "$block" ] || uncomment_block "$block"
  set_live "$key" "$wrong"
  run_wu check
  check_status "wrong value: $key = $wrong exits 2" 2
  check_out_has "wrong value: $key = $wrong is named with its line" "config:[0-9]+: $pattern"
  check_calls_lacks "wrong value: $key = $wrong runs nothing" '^(brew|softwareupdate|pmset)'
done <<'EOF'
|weekday|7|weekday in \[updater\] must be a whole number from 0 to 6, got "7"
|last_hour|14|last_hour must be later than first_hour
|minute|60|minute in \[updater\] must be a whole number from 0 to 59, got "60"
|battery_floor|10|battery_floor in \[updater\] must be a whole number from 20 to 100, got "10"
|entry_wait|59|entry_wait in \[updater\] must be a whole number from 60 to 86400, got "59"
|slow_warn|0|slow_warn in \[updater\] must be a whole number from 60 to 86400, got "0"
|heartbeat_days|1|heartbeat_days in \[updater\] must be a whole number from 2 to 60, got "1"
com.example.notes|group|silent|group in \[app com\.example\.notes\] must be one of vendor, manual, got "silent"
com.example.tool|version_drop_leading|4|version_drop_leading in \[app com\.example\.tool\] must be a whole number from 0 to 3, got "4"
com.example.tool|cask|Example-Tool|cask in \[app com\.example\.tool\] does not have the expected form, got "Example-Tool"
com.example.browser|also_matches|com.example.browser.helper _bad|also_matches in \[app com\.example\.browser\] has an item without the expected form: "_bad"
EOF

testing_verdict
