#!/bin/bash
# uninstall.sh: runs bin/weekly-update-uninstall from this folder. It unloads
# the schedule and moves the installed copy aside; nothing is deleted.
set -u
case $0 in
  */*) here=${0%/*} ;;
  *) here=. ;;
esac
exec /bin/bash "$here/bin/weekly-update-uninstall" "$@"
