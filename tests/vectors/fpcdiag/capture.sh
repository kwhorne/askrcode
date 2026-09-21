#!/usr/bin/env sh
# Regenerates the compiler-diagnostic vectors next to this script.
#
#   tests/vectors/fpcdiag/capture.sh
#
# Three fixtures compiled by three toolchains: 3.2.2 on aarch64, 3.2.2 on
# x86_64, and 3.3.1 trunk. The premise test asserts that the positioned
# lines come out identical from all three — so these files have to be
# produced the same way every time, not by hand.
#
# Each container writes its own file through the mount rather than through a
# shell redirect on the host. A host-side redirect works, but Docker
# Desktop's mount cache does not always invalidate afterwards: the file
# reads 567 bytes on the host and 0 inside the next container, and the test
# then fails for a reason that has nothing to do with the parser. Measured,
# not guessed.
#
# The banner lines differ per compiler (version, target, config paths) and
# that is fine — the parser ignores everything that is not a diagnostic, and
# the test asserts exactly that.

set -e

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/../../.." && pwd)
REL=tests/vectors/fpcdiag
TMP=.build/diagtmp

cd "$ROOT"
mkdir -p "$TMP"

# -vewnh: errors, warnings, notes and hints. The hint level is needed for
# the "a build that succeeds while saying things" fixture.
FLAGS="-Sh -vewnh -FU/work/$TMP -FE/work/$TMP"

for f in errors syntax warnings; do
  docker run --rm -v "$ROOT":/work -w /work askr-fpc:bookworm \
    sh -c "fpc $FLAGS $REL/$f.pas > $REL/$f.fpc322-aarch64.txt 2>&1 || true"

  docker run --rm --platform linux/amd64 -v "$ROOT":/work -w /work \
    askr-fpc:bookworm-amd64 \
    sh -c "fpc $FLAGS $REL/$f.pas > $REL/$f.fpc322-amd64.txt 2>&1 || true"

  if [ -n "$ASKR_FPC" ] && [ -x "$ASKR_FPC" ]; then
    PPC_CONFIG_PATH=$(dirname "$ASKR_FPC") "$ASKR_FPC" -WM11.0 -Sh -vewnh \
      -FU"$TMP" -FE"$TMP" "$REL/$f.pas" > "$REL/$f.fpc331-darwin.txt" 2>&1 || true
  else
    echo "  ASKR_FPC is not set — leaving $f.fpc331-darwin.txt as it is"
  fi
done

echo
wc -c "$DIR"/*.txt
