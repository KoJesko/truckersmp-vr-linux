#!/usr/bin/env bash
# Round-trip the MessageBoxA NULL-caption patch against a real Proton user32.dll.
#
# This is the one part of truckvr that rewrites machine code, and it finds its
# site by scanning for a reference to the literal "Star Citizen" rather than by
# trusting a fixed offset. So the things worth proving are:
#
#   * the scan recognises the same site before and after the patch,
#   * un-patching with no backup file reproduces the original byte for byte
#     (a Proton update deletes the backup but leaves the patched DLL behind),
#   * a build that has no such hack is left completely alone.
#
# Everything runs on copies in a temp directory; no installed file is touched.
set -uo pipefail

TRUCKVR="${TRUCKVR:-$(dirname "$0")/../truckvr}"
PY="$(sed -n '/^read -r -d .. PY_ENGINE/,/^PYEOF$/p' "$TRUCKVR" | sed '1d;$d')"
eng() { python3 -c "$PY" "$@"; }

pass=0 fail=0
ok()  { printf '  \033[32mok\033[0m   %-46s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %-46s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
is()  { if [[ "$2" == "$3" ]]; then ok "$1" "$2"; else bad "$1" "got '$2', wanted '$3'"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
md5() { md5sum "$1" | cut -d' ' -f1; }

# ---------------------------------------------------------------- find inputs
# A DLL that carries the hack (in either state — this machine may already be
# patched) and, ideally, one that does not, for the negative case.
WITH="" WITHOUT=""
while read -r f; do
  [[ -f "$f" ]] || continue
  case "$(eng msg-state "$f" 2>/dev/null)" in
    UNPATCHED|PATCHED) [[ -z "$WITH"    ]] && WITH="$f" ;;
    NOTPRESENT)        [[ -z "$WITHOUT" ]] && WITHOUT="$f" ;;
  esac
  [[ -n "$WITH" && -n "$WITHOUT" ]] && break
done < <(
  for root in "${STEAM_ROOT:-$HOME/.local/share/Steam}"/compatibilitytools.d \
              "${STEAM_ROOT:-$HOME/.local/share/Steam}"/steamapps/common \
              /usr/share/steam/compatibilitytools.d; do
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth 6 -name user32.dll -path '*x86_64-windows*' 2>/dev/null
  done
)

echo
if [[ -z "$WITH" ]]; then
  echo "No Proton on this machine carries the Star Citizen caption hack —"
  echo "nothing to round-trip. (Only GE-Proton builds have it.)"
  echo "  skipped"
  exit 0
fi
echo "Using $(sed "s|$HOME|~|" <<<"$WITH")"

# --------------------------------------------------------------- round trip
cp "$WITH" "$TMP/user32.dll"
DLL="$TMP/user32.dll"

# Normalise to the unpatched state so the test works on a machine that has
# already run `truckvr patch`.
[[ "$(eng msg-state "$DLL")" == PATCHED ]] && eng msg-unpatch "$DLL" >/dev/null
cp "$DLL" "$TMP/pristine.dll"
PRISTINE="$(md5 "$TMP/pristine.dll")"

echo
echo "Detection"
is "clean build reads as UNPATCHED" "$(eng msg-state "$DLL")" "UNPATCHED"

echo
echo "Patching"
out="$(eng msg-patch "$DLL")"
case "$out" in patched\ at\ *) ok "applies and reports the offset" "$out" ;;
               *)              bad "applies and reports the offset" "$out" ;; esac
is "now reads as PATCHED" "$(eng msg-state "$DLL")" "PATCHED"
is "patching again is a no-op" "$(eng msg-patch "$DLL")" "already patched"

# The jump must land exactly on the `jne` target — the normal dialog path.
python3 - "$DLL" "$TMP/pristine.dll" <<'PYEOF' && ok "jump lands on the normal path" || bad "jump lands on the normal path"
import sys, struct
new = open(sys.argv[1], 'rb').read()
old = open(sys.argv[2], 'rb').read()
off = next(i for i in range(len(old)) if old[i:i+3] == b'\x48\x8d\x15' and new[i] == 0xEB)
rel8 = struct.unpack_from('<b', old, off + 16)[0]      # the original `jne rel8`
disp = struct.unpack_from('<b', new, off + 1)[0]       # our `jmp disp8`
sys.exit(0 if (off + 2 + disp) == (off + 17 + rel8) else 1)
PYEOF

echo
echo "Un-patching"
rm -f "$DLL.truckvr-orig"                               # force reconstruction
out="$(eng msg-unpatch "$DLL")"
case "$out" in restored*) ok "rebuilds without a backup file" "$out" ;;
               *)         bad "rebuilds without a backup file" "$out" ;; esac
is "byte-identical to the original" "$(md5 "$DLL")" "$PRISTINE"
is "reads as UNPATCHED again" "$(eng msg-state "$DLL")" "UNPATCHED"

eng msg-patch "$DLL" >/dev/null                         # now with the backup kept
out="$(eng msg-unpatch "$DLL")"
case "$out" in restored\ from\ *) ok "restores from the backup file" "$out" ;;
                *)                bad "restores from the backup file" "$out" ;; esac
is "also byte-identical" "$(md5 "$DLL")" "$PRISTINE"
[[ -e "$DLL.truckvr-orig" ]] && bad "removes the backup afterwards" "still there" \
                             || ok "removes the backup afterwards"

# ------------------------------------------------------------ negative case
echo
echo "A build without the hack"
if [[ -n "$WITHOUT" ]]; then
  cp "$WITHOUT" "$TMP/other.dll"
  before="$(md5 "$TMP/other.dll")"
  is "reads as NOTPRESENT" "$(eng msg-state "$TMP/other.dll")" "NOTPRESENT"
  is "patching declines" "$(eng msg-patch "$TMP/other.dll")" \
     "no Star Citizen caption hack in this build — nothing to do"
  is "and leaves the file alone" "$(md5 "$TMP/other.dll")" "$before"
else
  echo "  (no hack-free Proton installed to compare against — skipped)"
fi

echo
if (( fail )); then
  printf '  \033[31m%d passed, %d failed\033[0m\n\n' "$pass" "$fail"; exit 1
fi
printf '  \033[32m%d passed, 0 failed\033[0m\n\n' "$pass"
