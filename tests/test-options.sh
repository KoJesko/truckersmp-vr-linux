#!/usr/bin/env bash
# Check the two edits truckvr makes to real user data: TruckersMP's consoleOpts
# and the three bytes inside setupapi.dll. Both must round-trip exactly — a
# toggle that quietly loses a renderer flag, or a patch that cannot be undone,
# is worse than not having the tool.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TRUCKVR="${TRUCKVR:-$HERE/../truckvr}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Pull the engine out of the script so the tests can call it directly.
eval "$(sed -n '/^read -r -d .. PY_ENGINE/,/^PYEOF$/p' "$TRUCKVR")"
py() { python3 -c "$PY_ENGINE" "$@"; }

pass=0 fail=0
check() {   # check <label> <expected> <actual>
  if [[ "$3" == "$2" ]]; then
    printf '  \033[32mok\033[0m   %-44s %s\n' "$1" "$2"; pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m %-44s\n        expected: %s\n        got:      %s\n' "$1" "$2" "$3"
    fail=$((fail+1))
  fi
}

mkopts() {   # mkopts <json-array-of-flags>
  cat > "$WORK/launcher-options.json" <<EOF
{"games":{"ets2":{"game":"ets2","path":"Z:\\\\game.exe","consoleOpts":$1},"ats":{"game":"ats","path":"C:\\\\other.exe","consoleOpts":["-keepme"]}},"installPath":"/somewhere","theme":"dark","lang":"en_GB"}
EOF
}
opts() { py tmp-get "$WORK/launcher-options.json" "${1:-ets2}"; }
setvr() { py tmp-set "$WORK/launcher-options.json" ets2 "$1" -experimental_vr -openxr >/dev/null; }

echo
echo "Enabling and disabling VR"
mkopts '[]'
setvr 1; check "on adds the VR flags"            "-experimental_vr -openxr" "$(opts)"
setvr 0; check "off removes them"                ""                          "$(opts)"

echo
echo "Unrelated flags survive, and the other game is untouched"
mkopts '["-nointro","-force_mods"]'
setvr 1; check "user flags kept, VR in front"    "-experimental_vr -openxr -nointro -force_mods" "$(opts)"
check     "sibling game untouched"               "-keepme" "$(opts ats)"
setvr 0; check "off leaves user flags alone"     "-nointro -force_mods" "$(opts)"

echo
echo "A -rdevice gl renderer choice is set aside for VR and handed back after"
mkopts '["-rdevice","gl","-nointro"]'
setvr 1; check "gl stripped (VR needs DX11)"     "-experimental_vr -openxr -nointro" "$(opts)"
setvr 0; check "gl restored on the way out"      "-nointro -rdevice gl" "$(opts)"

echo
echo "A non-gl renderer choice is left alone"
mkopts '["-rdevice","dx11","-nointro"]'
setvr 1; check "dx11 kept as-is"                 "-experimental_vr -openxr -rdevice dx11 -nointro" "$(opts)"
setvr 0; check "and still there afterwards"      "-rdevice dx11 -nointro" "$(opts)"

echo
echo "A flag's value is never mistaken for a flag"
# SCS options take their argument as a separate token that does not begin with
# a dash (`-rdevice gl`), so pairing is what keeps `gl` attached to `-rdevice`
# while the real `-openxr` flag beside it is removed. A value that itself began
# with a dash would be indistinguishable from a flag — that is inherent to the
# format, not something this tool can second-guess.
mkopts '["-rdevice","gl","-openxr","-nointro"]'
setvr 0
check "only the real flag is removed"            "-rdevice gl -nointro" "$(opts)"

echo
echo "Enabling twice does not duplicate anything"
mkopts '["-nointro"]'
setvr 1; setvr 1
check "idempotent"                               "-experimental_vr -openxr -nointro" "$(opts)"

echo
echo "File mode is preserved (mkstemp defaults to 0600)"
mkopts '["-nointro"]'
chmod 644 "$WORK/launcher-options.json"
setvr 1
check "still 0644 after a toggle"                "644" "$(stat -c '%a' "$WORK/launcher-options.json")"

echo
echo "Unrelated top-level keys survive a round trip"
mkopts '["-nointro"]'
before="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["installPath"], d["theme"], d["lang"])' "$WORK/launcher-options.json")"
setvr 1; setvr 0
after="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["installPath"], d["theme"], d["lang"])' "$WORK/launcher-options.json")"
check "installPath/theme/lang intact"            "$before" "$after"

echo
echo "The setupapi patch round-trips byte for byte"
SRC=""
for c in "$HOME"/.local/share/Steam/compatibilitytools.d/*/files/lib/wine/x86_64-windows/setupapi.dll \
         "$HOME"/.local/share/Steam/steamapps/common/*/files/lib/wine/x86_64-windows/setupapi.dll \
         /usr/share/steam/compatibilitytools.d/*/files/lib/wine/x86_64-windows/setupapi.dll; do
  [[ -f "$c" ]] || continue
  [[ "$(py dll-state "$c")" == UNPATCHED ]] && { SRC="$c"; break; }
done
if [[ -z "$SRC" ]]; then
  printf '  \033[33mskip\033[0m no unpatched setupapi.dll available to test against\n'
else
  cp "$SRC" "$WORK/setupapi.dll"
  orig="$(md5sum < "$WORK/setupapi.dll")"
  check "starts out as a verified stub"           "UNPATCHED" "$(py dll-state "$WORK/setupapi.dll")"
  py dll-patch "$WORK/setupapi.dll" >/dev/null
  check "patches"                                 "PATCHED"   "$(py dll-state "$WORK/setupapi.dll")"
  py dll-unpatch "$WORK/setupapi.dll" >/dev/null
  check "unpatches"                               "UNPATCHED" "$(py dll-state "$WORK/setupapi.dll")"
  check "identical to the original"               "$orig"     "$(md5sum < "$WORK/setupapi.dll")"

  # A Proton update deletes the backup that lived inside the dist while leaving
  # the patched DLL behind, so undo has to work without one.
  cp "$SRC" "$WORK/nobackup.dll"
  py dll-patch "$WORK/nobackup.dll" >/dev/null
  rm -f "$WORK/nobackup.dll.truckvr-orig"
  out="$(py dll-unpatch "$WORK/nobackup.dll")"
  check "undo works with no backup file"          "UNPATCHED" "$(py dll-state "$WORK/nobackup.dll")"
  check "and matches the original exactly"        "$orig"     "$(md5sum < "$WORK/nobackup.dll")"

  # Refuse to touch a build that implements the function for real.
  cp "$SRC" "$WORK/impl.dll"
  python3 - "$WORK/impl.dll" "$(py dll-offset "$WORK/impl.dll")" <<'PYX'
import sys
# Blank the two `lea` instructions so the code no longer names the module and
# function — which is exactly what a genuine implementation that happens to
# start with `sub rsp,0x28` looks like. The prologue is untouched, so a
# prologue-only check would still call this a stub and clobber it.
d = bytearray(open(sys.argv[1], 'rb').read())
off = int(sys.argv[2])
d[off+4:off+18] = b'\x90' * 14
open(sys.argv[1], 'wb').write(d)
PYX
  check "a real implementation is not a stub"     "IMPLEMENTED" "$(py dll-state "$WORK/impl.dll")"
  out="$(py dll-patch "$WORK/impl.dll" 2>&1)"
  case "$out" in *"leaving it alone"*) r=refused ;; *) r="$out" ;; esac
  check "and patching refuses to touch it"        "refused" "$r"
fi

echo
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
