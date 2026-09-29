#!/bin/bash
# run-all.sh: runs every tests/test-*.sh with the stock /bin/bash and reports
# each file's exit status. Exit 0 only when every file passed.
set -u
case $0 in
  */*) here=$(CDPATH='' cd -P -- "${0%/*}" && pwd -P) ;;
  *) here=$(pwd -P) ;;
esac
failed=""
count=0
for test_file in "$here"/test-*.sh; do
  [ -f "$test_file" ] || continue
  count=$((count + 1))
  printf '\n######## %s\n' "${test_file##*/}"
  /bin/bash "$test_file"
  status=$?
  printf '######## %s exit %s\n' "${test_file##*/}" "$status"
  [ "$status" -eq 0 ] || failed="$failed ${test_file##*/}"
done
printf '\n%s test files ran.\n' "$count"
if [ "$count" -eq 0 ]; then
  printf 'RESULT: FAIL (no test files found)\n'
  exit 1
fi
if [ -n "$failed" ]; then
  printf 'RESULT: FAIL:%s\n' "$failed"
  exit 1
fi
printf 'RESULT: PASS\n'
exit 0
