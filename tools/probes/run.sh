#!/usr/bin/env sh
# Runs the generics probes against a given fpc and reports what compiles.
#
#   tools/probes/run.sh                      # fpc from PATH
#   tools/probes/run.sh /path/to/fpc         # a particular compiler
#
# Each probe is a limit that was hit during phase 1. If it compiles, the
# limit is gone.

FPC=${1:-fpc}
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)

# FPC looks for fpc.cfg in ~/.fpc.cfg and /etc/fpc.cfg on Unix, not next to
# the binary. An fpcupdeluxe installation puts it next to the binary, so it
# has to be pointed out explicitly.
FPCDIR=$(dirname "$FPC")
if [ -f "$FPCDIR/fpc.cfg" ]; then
  PPC_CONFIG_PATH="$FPCDIR"
  export PPC_CONFIG_PATH
fi

echo "compiler: $("$FPC" -iV 2>/dev/null) $("$FPC" -iTO 2>/dev/null) $("$FPC" -iTP 2>/dev/null)"
echo

OK=0
FAIL=0
for f in "$DIR"/p*.pas "$DIR"/p*.lpr; do
  [ -e "$f" ] || continue
  name=$(basename "$f")
  log="$OUT/$name.log"
  if "$FPC" -Sh -vew -Fu"$DIR" -FU"$OUT" -FE"$OUT" "$f" > "$log" 2>&1; then
    echo "  COMPILES   $name"
    OK=$((OK+1))
  else
    reason=$(grep -E "Error|Fatal" "$log" | head -1 | sed 's/^.*(\([0-9,]*\)) //')
    echo "  FAILS      $name"
    echo "             $reason"
    FAIL=$((FAIL+1))
  fi
done

echo
echo "$OK compile, $FAIL fail"
rm -rf "$OUT"
