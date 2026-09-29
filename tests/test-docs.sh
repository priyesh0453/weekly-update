#!/bin/bash
# test-docs.sh: the documents match the code. The README usage block is the
# --help output, the quickstart runs, versions agree, the skill is well
# formed, and every text file is ASCII.
# shellcheck source-path=SCRIPTDIR
set -u
set -o pipefail
# shellcheck source=harness.sh
. "${0%/*}/harness.sh"

between() {
  LC_ALL=C awk -v begin="<!-- $2:begin -->" -v end="<!-- $2:end -->" '
    $0 == begin { on = 1; next }
    $0 == end { on = 0 }
    on && /^```/ { fence = !fence; next }
    on && fence { print }' "$1"
}

printf '== the README usage block is the --help output\n'
new_sandbox
run_wu --help
testing_check "README usage block equals weekly-update --help" "$(cat "$OUT")" "$(between "$REPO/README.md" usage)"
for mode in run auto scheduled setup check status verify plist help; do
  check_file_has "the README names mode $mode" "$REPO/README.md" "^  $mode "
done

printf '== the quickstart runs as written, on a home folder with no config\n'
new_sandbox
basic_fixture
mv "$HOME_DIR/.config/weekly-update/config" "$S/config.moved-by-test"
quickstart=$(between "$REPO/README.md" quickstart)
testing_check "the quickstart starts with the clone" "git clone https://github.com/priyesh0453/weekly-update.git" "$(printf '%s\n' "$quickstart" | head -n 1)"
testing_check "the quickstart then enters the folder" "cd weekly-update" "$(printf '%s\n' "$quickstart" | sed -n 2p)"
steps=0
while IFS= read -r line; do
  case $line in
    'git clone '*|'cd weekly-update') continue ;;
  esac
  steps=$((steps + 1))
  OUT=$S/quickstart-$steps.txt
  seam_env /bin/bash -c "cd \"\$1\" && $line" quickstart "$REPO" > "$OUT" 2>&1
  RC=$?
  check_status "quickstart: $line" 0
done <<EOF
$quickstart
EOF
testing_check "the quickstart ran six commands" 6 "$steps"
check_calls_lacks "the quickstart ran nothing unexpected" '^UNEXPECTED'
check_calls_lacks "the quickstart upgraded nothing" '^brew (upgrade|install)|^sudo'
check_i8 "the quickstart"

printf '== the README describes the questions the code asks\n'
macos_question=$(LC_ALL=C awk '/^phase_macos\(\) \{/ { on = 1 } on && /prompt_consent/ { print; exit }' "$REPO/bin/weekly-update")
if printf '%s\n' "$macos_question" | LC_ALL=C grep -F -e "accepts Apple's license terms for them" >/dev/null; then asks=yes; else asks=no; fi
testing_check "phase_macos asks a question that names the license terms" yes "$asks"
check_file_has "the README says the macOS step asks before it installs" "$REPO/README.md" "Before it installs any macOS update, the interactive pass asks you, and the question says that installing accepts Apple's license terms"
check_file_has "the README says the window pass asks again before a macOS install" "$REPO/README.md" 'asks again before it quits an app itself, installs macOS updates, or restarts'
check_file_lacks "the README makes no blanket stale-data promise" "$REPO/README.md" '^- It never decides on stale data'
for doc in README.md AGENTS.md skills/weekly-update/SKILL.md; do
  check_file_lacks "$doc makes no do-less promise" "$REPO/$doc" 'may only make the tool do less'
done

printf '== versions and headers agree\n'
version=$(cat "$REPO/VERSION")
testing_check "VERSION is 0.1.0" 0.1.0 "$version"
testing_check "the runtime reports VERSION" "WU_VERSION=$version" "$(grep -x 'WU_VERSION=.*' "$REPO/bin/weekly-update")"
check_file_has "CHANGELOG has the version" "$REPO/CHANGELOG.md" "^## \\[$version\\]"
check_file_has "CHANGELOG has Unreleased" "$REPO/CHANGELOG.md" '^## \[Unreleased\]'
check_file_has "LICENSE is MIT with the copyright line" "$REPO/LICENSE" '^Copyright \(c\) 2026 Priyesh Mishra$'
check_file_has "the skill states its version" "$REPO/skills/weekly-update/SKILL.md" "^  version: \"$version\"$"
for script in bin/weekly-update bin/weekly-update-verify bin/weekly-update-uninstall install.sh uninstall.sh tests/run-all.sh tests/test-*.sh tests/shims/*; do
  for file in "$REPO"/$script; do
    testing_check "shebang of ${file#"$REPO"/}" '#!/bin/bash' "$(head -n 1 "$file")"
  done
done

printf '== the skill is well formed\n'
skill=$REPO/skills/weekly-update/SKILL.md
frontmatter=$(LC_ALL=C awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on { print }' "$skill")
testing_check "the skill name matches its folder" "name: weekly-update" "$(printf '%s\n' "$frontmatter" | grep '^name:')"
testing_check "the skill has only spec keys at the top level" "compatibility description license metadata name" \
  "$(printf '%s\n' "$frontmatter" | LC_ALL=C grep -E -o '^[a-z-]+:' | tr -d ':' | sort | tr '\n' ' ' | sed 's/ $//')"
description=$(printf '%s\n' "$frontmatter" | sed -n 's/^description: //p')
if [ "${#description}" -le 1024 ] && [ -n "$description" ]; then testing_check "the description fits the spec" ok ok; else testing_check "the description fits the spec" "1 to 1024 characters" "${#description}"; fi

printf '== the README has its sections in order\n'
testing_check "README section order" \
  "The 30-second pitch|A reference design, not a product|Who this is for|What it never does|Quickstart|How it works|Config reference|Cross-platform notes|Known limitations|Extend this|FAQ|Uninstall|License" \
  "$(LC_ALL=C sed -n 's/^## //p' "$REPO/README.md" | tr '\n' '|' | sed 's/|$//')"
for key in label_prefix weekday first_hour last_hour minute battery_floor quit_wait entry_wait nudge_give_up index_timeout query_timeout list_timeout slow_warn final_prompt_timeout heartbeat_days admin_hint cask group also_matches open_as open_warning version_drop_leading; do
  check_file_has "docs/CONFIG.md documents config key $key" "$REPO/docs/CONFIG.md" "\`$key"
  check_file_has "the example config documents $key" "$REPO/config/weekly-update.conf.example" "$key"
  check_file_has "the runtime declares $key" "$REPO/bin/weekly-update" "conf_schema_key (updater|app) $key "
done

printf '== every text file is ASCII and has no leftover markers\n'
testing_check "no non-ASCII byte in a text file" "" "$(LC_ALL=C grep -r -l '[^[:print:][:space:]]' "$REPO" --exclude-dir=.git 2>/dev/null)"
testing_check "no leftover work markers in the tree" "" "$(LC_ALL=C grep -r -l -E "TO""DO|FIX""ME|XX""X:" "$REPO" --exclude-dir=.git 2>/dev/null)"

testing_verdict
