#!/usr/bin/env sh
# Kjører generics-probene mot en gitt fpc og rapporterer hva som kompilerer.
#
#   tools/probes/run.sh                      # fpc fra PATH
#   tools/probes/run.sh /sti/til/fpc         # en bestemt kompilator
#
# Hver probe er en grense som ble truffet under fase 1. Kompilerer den, er
# grensen borte.

FPC=${1:-fpc}
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)

# FPC leter etter fpc.cfg i ~/.fpc.cfg og /etc/fpc.cfg på Unix, ikke ved siden
# av binaeren. En fpcupdeluxe-installasjon legger den ved binaeren, så den må
# pekes ut eksplisitt.
FPCDIR=$(dirname "$FPC")
if [ -f "$FPCDIR/fpc.cfg" ]; then
  PPC_CONFIG_PATH="$FPCDIR"
  export PPC_CONFIG_PATH
fi

echo "kompilator: $("$FPC" -iV 2>/dev/null) $("$FPC" -iTO 2>/dev/null) $("$FPC" -iTP 2>/dev/null)"
echo

OK=0
FAIL=0
for f in "$DIR"/p*.pas "$DIR"/p*.lpr; do
  [ -e "$f" ] || continue
  name=$(basename "$f")
  log="$OUT/$name.log"
  if "$FPC" -Sh -vew -Fu"$DIR" -FU"$OUT" -FE"$OUT" "$f" > "$log" 2>&1; then
    echo "  KOMPILERER   $name"
    OK=$((OK+1))
  else
    reason=$(grep -E "Error|Fatal" "$log" | head -1 | sed 's/^.*(\([0-9,]*\)) //')
    echo "  FEILER       $name"
    echo "               $reason"
    FAIL=$((FAIL+1))
  fi
done

echo
echo "$OK kompilerer, $FAIL feiler"
rm -rf "$OUT"
