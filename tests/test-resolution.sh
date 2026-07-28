#!/usr/bin/env bash
# Build a throwaway Steam installation and check that truckvr works out which
# Proton runs a game in each layout it will meet in the wild:
#   - Proton mapped directly on the game (no SteamTinkerLaunch)
#   - the Steam Play global default, with no per-game override
#   - SteamTinkerLaunch in the middle, choosing the real Proton itself
#   - Proton living in a second library folder
#   - a Valve dist, which has no internal name and must be matched another way
set -uo pipefail

TRUCKVR="${TRUCKVR:-$(cd "$(dirname "$0")/.." && pwd)/truckvr}"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0 fail=0
check() {   # check <label> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then
    printf '  \033[32mok\033[0m   %-46s %s\n' "$1" "$2"; pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m %-46s expected %-28s got: %s\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

STEAM="$ROOT/Steam"
LIB2="$ROOT/SecondLibrary"

mkproton() {   # mkproton <dir> <internal-name|-> <version-line|->
  mkdir -p "$1/files/lib/wine/x86_64-windows"
  : > "$1/proton"
  [[ "$2" != - ]] && cat > "$1/compatibilitytool.vdf" <<EOF
"compatibilitytools"
{
  "compat_tools"
  {
    "$2" // Internal name of this tool
    {
      "install_path" "."
      "display_name" "$2"
      "from_oslist"  "windows"
      "to_oslist"    "linux"
    }
  }
}
EOF
  [[ "$3" != - ]] && printf '%s\n' "$3" > "$1/version"
  return 0
}

mkdir -p "$STEAM/steamapps/common" "$STEAM/config" "$STEAM/compatibilitytools.d" \
         "$LIB2/steamapps/common"

mkproton "$STEAM/compatibilitytools.d/GE-Proton11-3" GE-Proton11-3 "1784963766 GE-Proton11-3"
mkproton "$STEAM/compatibilitytools.d/GE-Proton11-1" GE-Proton11-1 "1780000000 GE-Proton11-1"
# A Valve dist: no compatibilitytool.vdf at all, identified via its manifest.
mkproton "$STEAM/steamapps/common/Proton - Experimental" - "1783957914 experimental-11.0-20260713"
# A Proton that lives in the *other* library folder.
mkproton "$LIB2/steamapps/common/GE-Proton12-1" GE-Proton12-1 "1790000000 GE-Proton12-1"
# A build whose version file is stale and names a completely different Proton.
mkproton "$STEAM/compatibilitytools.d/proton-cachyos-11.0-20260801-slr-x86_64_v3" \
         proton-cachyos-11.0-20260801-slr-x86_64_v3 "1731350438 proton-8.0-5d"

cat > "$STEAM/steamapps/libraryfolders.vdf" <<EOF
"libraryfolders"
{
	"0" { "path" "$STEAM" }
	"1" { "path" "$LIB2" }
}
EOF

cat > "$STEAM/steamapps/appmanifest_1493710.acf" <<'EOF'
"AppState" { "appid" "1493710" "name" "Proton Experimental" "installdir" "Proton - Experimental" }
EOF
cat > "$STEAM/steamapps/appmanifest_227300.acf" <<'EOF'
"AppState" { "appid" "227300" "name" "Euro Truck Simulator 2" "installdir" "Euro Truck Simulator 2" }
EOF
cat > "$LIB2/steamapps/appmanifest_270880.acf" <<'EOF'
"AppState" { "appid" "270880" "name" "American Truck Simulator" "installdir" "American Truck Simulator" }
EOF
mkdir -p "$STEAM/steamapps/common/Euro Truck Simulator 2" \
         "$LIB2/steamapps/common/American Truck Simulator" \
         "$LIB2/steamapps/compatdata/270880/pfx/drive_c/windows/system32"

write_config() {   # write_config <mapping-body>
  cat > "$STEAM/config/config.vdf" <<EOF
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"CompatToolMapping"
				{
$1
				}
			}
		}
	}
}
EOF
}

run() { TRUCKVR_STEAM_ROOT="$STEAM" HOME="$ROOT/fakehome" "$TRUCKVR" "$@" 2>&1; }
mkdir -p "$ROOT/fakehome"

echo
echo "Proton mapped directly on the game — no SteamTinkerLaunch anywhere"
write_config '					"227300" { "name" "GE-Proton11-3" "config" "" "priority" "250" }'
out="$(run doctor --game ets2)"
check "resolves the mapped Proton"      "Proton: GE-Proton11-3" "$out"
check "and calls it VR-capable"         "GE-Proton11-3 >= GE-Proton11-3" "$out"

echo
echo "A mapped Proton that predates the fix must be called out, not waved through"
write_config '					"227300" { "name" "GE-Proton11-1" "config" "" "priority" "250" }'
out="$(run doctor --game ets2)"
check "flags the old build"             "too old for VR" "$out"

echo
echo "No per-game override — fall back to the Steam Play global default"
write_config '					"0" { "name" "GE-Proton11-3" "config" "" "priority" "75" }'
out="$(run doctor --game ets2)"
check "uses the global default"         "Steam global Steam Play default" "$out"
check "and resolves it"                 "Proton: GE-Proton11-3" "$out"

echo
echo "SteamTinkerLaunch in the middle — Steam says Proton-stl, STL picks the real one"
write_config '					"227300" { "name" "Proton-stl" "config" "" "priority" "250" }'
mkdir -p "$ROOT/fakehome/.config/steamtinkerlaunch/gamecfgs/id"
printf 'USEPROTON="GE-Proton11-3"\nUSEGAMESCOPE="0"\n' \
  > "$ROOT/fakehome/.config/steamtinkerlaunch/gamecfgs/id/227300.conf"
out="$(XDG_CONFIG_HOME="$ROOT/fakehome/.config" run doctor --game ets2)"
check "follows the wrapper indirection" "USEPROTON -> GE-Proton11-3" "$out"
check "ends at the real Proton"         "Proton: GE-Proton11-3" "$out"

echo
echo "STL selecting a Proton that lives in the second library folder"
printf 'USEPROTON="GE-Proton12-1"\n' \
  > "$ROOT/fakehome/.config/steamtinkerlaunch/gamecfgs/id/227300.conf"
out="$(XDG_CONFIG_HOME="$ROOT/fakehome/.config" run doctor --game ets2)"
check "finds Proton in another library" "Proton: GE-Proton12-1" "$out"
check "and judges it correctly"         "GE-Proton12-1 >= GE-Proton11-3" "$out"

echo
echo "A Valve dist, which carries no internal name of its own"
write_config '					"227300" { "name" "Proton Experimental" "config" "" "priority" "250" }'
out="$(run doctor --game ets2)"
check "matched via its app manifest"    "Proton: Proton Experimental" "$out"
check "dated from its version file"     "20260713" "$out"

echo
echo "A stale version file must not override the directory name"
write_config '					"227300" { "name" "proton-cachyos-11.0-20260801-slr-x86_64_v3" "config" "" "priority" "250" }'
out="$(run doctor --game ets2)"
check "trusts the directory name"       "built 20260801" "$out"

echo
echo "A Proton that is mapped but not installed must be reported, not hidden"
write_config '					"227300" { "name" "GE-Proton99-9" "config" "" "priority" "250" }'
out="$(run doctor --game ets2)"
check "says it cannot find it"          "not installed anywhere" "$out"

echo
echo "The game in the second library is still found"
write_config '					"270880" { "name" "GE-Proton11-3" "config" "" "priority" "250" }'
out="$(run doctor --game ats)"
check "locates the install"             "American Truck Simulator" "$out"
check "and its Proton"                  "Proton: GE-Proton11-3" "$out"

echo
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
