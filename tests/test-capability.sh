#!/usr/bin/env bash
# Exercise the "does this Proton have the VR fix" rule against build names that
# are not installed here. This is the part of truckvr most likely to be wrong in
# a way nobody notices — a false "yes" costs the user an evening of the headset
# sitting on the WiVRn lobby while the game happily renders stereo to a monitor.
set -uo pipefail

TRUCKVR="${TRUCKVR:-$(dirname "$0")/../truckvr}"
pass=0 fail=0

check() {   # check <expected> <name...>
  local want="$1"; shift
  local got reason
  IFS=$'\t' read -r got reason < <(python3 -c "$(sed -n '/^read -r -d .. PY_ENGINE/,/^PYEOF$/p' "$TRUCKVR" | sed '1d;$d')" verdict "$@")
  if [[ "$got" == "$want" ]]; then
    printf '  \033[32mok\033[0m   %-42s -> %-7s %s\n' "$1" "$got" "$reason"
    pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m %-42s -> %-7s (expected %s) %s\n' "$1" "$got" "$want" "$reason"
    fail=$((fail+1))
  fi
}

echo
echo "GE-Proton — the fix landed in 11-3"
check no      GE-Proton11-1
check no      GE-Proton11-2
check yes     GE-Proton11-3
check yes     GE-Proton11-4
check yes     GE-Proton11-10        # lexically "11-10" < "11-3"; must compare numerically
check yes     GE-Proton12-1
check yes     GE-Proton20-1         # a glob like ge-proton1[1-9]-* would miss this
check no      GE-Proton10-9
check no      GE-Proton9-27

echo
echo "Date-stamped builds — the fix landed 2026-07-07"
check no      experimental-11.0-20260706
check yes     experimental-11.0-20260707
check yes     experimental-11.0-20260713
check no      proton-cachyos-11.0-20260703-slr-x86_64_v3
check yes     proton-cachyos-11.0-20260801-slr-x86_64_v3
check yes     proton-tkg-11.0-20261102
check no      proton-cachyos-10.0-20260207-slr-x86_64_v4

echo
echo "Valve stable — the fix is not backported to 11.x or older"
check no      proton-11.0-1
check no      proton-10.0-4
check no      "Proton 11.0"
check no      "Proton 10.0"
check no      proton-8.0-5d
check yes     proton-12.0-1
check yes     "Proton 12.0"

echo
echo "Multiple aliases — the first name that gives a definite answer wins"
# A Valve dist: the directory name says nothing, the version file settles it.
check yes     "Proton - Experimental" "experimental-11.0-20260713"
# A cachyos build whose version file is stale and names a totally different
# Proton (this really happens — see proton-cachyos-11.0-20260521 on the author's
# box, whose version file reads "proton-8.0-5d"). The directory name is checked
# first precisely so the stale file cannot override it.
check yes     "proton-cachyos-11.0-20260801-slr-x86_64_v3" "proton-8.0-5d"
check no      "proton-cachyos-11.0-20260521-slr-x86_64_v3" "proton-8.0-5d"

echo
echo "Unrecognised builds are reported as unknown, never guessed"
check unknown my-custom-wine
check unknown Proton-stl
check unknown ""

echo
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
