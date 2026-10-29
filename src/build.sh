#!/bin/bash
# Rebuilds ../Claude-Summary-Tuner.ps1 (the single-file download) from the sources in this folder.
#   bash src/build.sh          rebuild in place
#   bash src/build.sh --check  build to a temp file and fail if it differs from the committed script
set -e; cd "$(dirname "$0")"
OUT=../Claude-Summary-Tuner.ps1
if [ "$1" = "--check" ]; then OUT=$(mktemp); fi
{
  cat main-head.ps1
  printf '\n# ------------------------------------------------------------------ embedded files\n'
  printf "# The hook. MIT (c) 2026 Flamerix AI (https://flamerix.ai), Windows gate + slow mode added.\n"
  printf "\$HookJs = @'\n"; cat hook.js; printf "'@\n"
  printf "\$CollectorPs = @'\n"; cat collector.ps1; printf "'@\n"
  cat body1.ps1 body2.ps1 body3.ps1 body4.ps1 body5.ps1
} > $OUT
# CRLF line endings for Windows; ASCII only (no BOM needed)
sed -i 's/\r$//; s/$/\r/' $OUT
if LC_ALL=C grep -nP '[^\x00-\x7F]' $OUT; then echo "NON-ASCII FOUND"; exit 1; fi
if grep -n "^'@" hook.js collector.ps1; then echo "here-string terminator inside payload"; exit 1; fi
wc -l $OUT
if [ "$1" = "--check" ]; then
  if cmp -s "$OUT" ../Claude-Summary-Tuner.ps1; then echo "OK: Claude-Summary-Tuner.ps1 matches src/"; rm -f "$OUT"
  else echo "MISMATCH: run bash src/build.sh and commit the result"; rm -f "$OUT"; exit 1; fi
fi
