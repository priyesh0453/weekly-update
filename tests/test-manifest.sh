#!/bin/bash
# test-manifest.sh: lib/ is vendored byte for byte from the shared library.
# This test fails when any file in lib/ differs from lib/MANIFEST.sha256, or
# when lib/ holds a file the manifest does not list, so drift is a failing
# test and not a silent fork.
# shellcheck source-path=SCRIPTDIR
set -u
set -o pipefail
case $0 in
  */*) here=$(CDPATH='' cd -P -- "${0%/*}" && pwd -P) ;;
  *) here=$(pwd -P) ;;
esac
repo=${here%/*}
unset _UTIL_SH_LOADED _GATE_SH_LOADED _TESTING_SH_LOADED
# shellcheck source=../lib/testing.sh
. "$repo/lib/testing.sh"
testing_init || exit 1

check_manifest() {
  (cd "$1" && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1)
}

unlisted_files() {
  local dir=$1 name
  for name in "$dir"/*; do
    name=${name##*/}
    [ "$name" = MANIFEST.sha256 ] && continue
    LC_ALL=C awk -v n="$name" '$2 == n { found = 1 } END { exit !found }' "$dir/MANIFEST.sha256" || printf '%s ' "$name"
  done
}

check_manifest "$repo/lib"
testing_check "lib/ matches lib/MANIFEST.sha256" 0 "$?"
testing_check "lib/ has no file the manifest does not list" "" "$(unlisted_files "$repo/lib")"
testing_check "the manifest lists nine modules" 9 "$(wc -l < "$repo/lib/MANIFEST.sha256" | tr -d ' ')"

copy=$TESTING_TMPDIR/lib-copy
mkdir -p "$copy"
cp "$repo"/lib/* "$copy/"
check_manifest "$copy"
testing_check "control: an exact copy verifies" 0 "$?"
printf '\n' >> "$copy/util.sh"
check_manifest "$copy"
testing_check "a one-byte change is caught" 1 "$?"
cp "$repo/lib/util.sh" "$copy/util.sh"
: > "$copy/extra.sh"
testing_check "an unlisted file is caught" "extra.sh " "$(unlisted_files "$copy")"

testing_verdict
