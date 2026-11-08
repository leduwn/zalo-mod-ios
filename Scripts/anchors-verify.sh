#!/bin/bash
# ZLMod — verify every anchor in Scripts/anchors.txt against IPA analysis dumps.
# Required dump files in $ZLMOD_IPA_DUMP:
#   objc_methname.txt  (selectors, one per line)
#   objc_classname.txt (classes, one per line)
#   zalo.strings       (strings -a -n 4 output of the host binary)
set -euo pipefail

DIR="${ZLMOD_IPA_DUMP:?set ZLMOD_IPA_DUMP to the dump directory}"
ANCHORS="$(dirname "$0")/anchors.txt"

PASS=0; FAIL=0
while IFS=$'\t' read -r kind anchor; do
  case "$kind" in
    sel)  FILE="$DIR/objc_methname.txt" ;;
    cls)  FILE="$DIR/objc_classname.txt" ;;
    key|url) FILE="$DIR/zalo.strings" ;;
    \#*|"") continue ;;
    *) echo "unknown kind: $kind"; continue ;;
  esac
  if grep -qF -- "$anchor" "$FILE"; then
    PASS=$((PASS+1))
  else
    echo "MISSING [$kind] $anchor"
    FAIL=$((FAIL+1))
  fi
done < <(grep -v '^#' "$ANCHORS" | grep -v '^$')

echo "anchors: $PASS verified, $FAIL missing"
[ "$FAIL" -eq 0 ]
