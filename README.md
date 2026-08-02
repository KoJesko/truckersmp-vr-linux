# truckvr

Get **Euro Truck Simulator 2** and **American Truck Simulator** running in VR on
Linux, streaming to a standalone headset with [WiVRn](https://github.com/WiVRn/WiVRn),
with or without [TruckersMP](https://truckersmp.com/).

One script, both games, no SteamVR.

```
$ truckvr doctor

Headset / OpenXR
  ✔ OpenXR runtime: WiVRn
  ✔ WiVRn installed

Euro Truck Simulator 2  (appid 227300)
  ✔ installed: ~/.local/share/Steam/steamapps/common/Euro Truck Simulator 2
  ✔ mode: VR   (TruckersMP flags: -experimental_vr -openxr)
  ✔ Steam launch options: pressure-vessel import is set
  ✔ Proton: GE-Proton11-3 (GE-Proton11-3 >= GE-Proton11-3)
      resolved via: Steam CompatToolMapping[227300] -> Proton-stl | 227300.conf USEPROTON -> GE-Proton11-3
  ✔ setupapi stub: patched
  ✔ MessageBoxA NULL caption: patched
```

## Why this is not a two-line fix

VR in these games needs five independent things to be right. Each one fails
differently, and fixing one only reveals the next — which is what makes this
frustrating to debug by hand.

| # | What | How it fails |
|---|------|--------------|
| 1 | **An OpenXR runtime** must be selected in `~/.config/openxr/1/active_runtime.json` | Game reports no headset. If SteamVR has ever run it replaces this file, and deletes it again on exit — so a working setup silently stops working |
| 2 | **`PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES=1`** in the Steam launch options | Steam's container cannot see WiVRn, so the game finds no runtime even though the host has one |
| 3 | **A Proton with the wineopenxr session fix** (Valve PR #9915, 2026-07-07) | The nasty one: the game renders stereo *on your monitor* while the headset sits on the WiVRn lobby forever. It looks like a WiVRn problem. It isn't |
| 4 | **A patched `setupapi.dll`** — only if you use TruckersMP | Game dies at the TruckersMP login screen |
| 5 | **A patched `user32.dll`** — only if you use TruckersMP, only on GE-Proton | Game hard-crashes a couple of seconds into startup, and the crash log blames `ucrtbase!strcmp` as if the game were at fault |

Hurdle 3 is worth expanding on. Prism3D destroys and recreates its `XrSession`
during startup. Older `wineopenxr` kept the dead handle in its session list, so
the game never called `xrBeginSession` and spun in `xrPollEvent` — over 200,000
times in one traced run. Fixed in GE-Proton11-3 and in Proton Experimental
builds from 2026-07-07 onward.

Hurdle 4 is not a Proton bug you can escape by changing builds.
`SetupDiGetDeviceInterfaceAlias` is a bare `@ stub` in `setupapi.spec` in **Wine
master itself**, so every Proton has it. Calling a Wine stub raises
`EXCEPTION_WINE_STUB` and takes the process down. TruckersMP's `core_*mp.dll`
calls it right after the audio and dinput threads spawn. `truckvr` patches the
stub thunk to `xor eax,eax; ret` — returning FALSE, i.e. "no alias found",
which is a perfectly ordinary answer that callers handle.

Hurdle 5 is the opposite: it is **not** in upstream Wine, only in GE-Proton.
Those builds carry a Star Citizen workaround inside `user32.MessageBoxExA` that
suppresses one dialog by string-matching its caption:

```asm
lea  rdx, "Star Citizen"
mov  rcx, r8          ; lpCaption, straight from the caller — never NULL-checked
call strcmp
```

`MessageBoxA(hwnd, text, NULL, type)` is legal on Windows; a NULL caption just
titles the box "Error". TruckersMP's `core_*mp.dll` uses exactly that to report
a startup error — so instead of the dialog you get `C0000005 ACCESS_VIOLATION`
and a crash log pointing at `ucrtbase!strcmp`, which reads like a game bug and
sends you chasing mods, drivers and verify-files. `truckvr` replaces the `lea`
with a two-byte jump to the normal dialog path, so the message actually appears.

The site is found by scanning for the reference to the literal `"Star Citizen"`,
not by a hardcoded offset, so it keeps working across Proton releases and
reports `NOTPRESENT` — a pass, not a failure — on the builds that never had it.

## Requirements

- Linux, bash 4+, python3 (standard library only — no pip packages)
- Steam, with ETS2 and/or ATS installed
- WiVRn: `flatpak install flathub io.github.wivrn.wivrn`, or your distro's package
- A standalone headset running the WiVRn client (Quest, Pico, …)
- Game version 1.55 or newer. **The old `oculus` / VR beta branch is obsolete** —
  VR is in the main branch now, and `-openvr` mode is broken on 1.50+

## Install

```sh
git clone https://github.com/YOUR_USERNAME/truckersmp-vr-linux.git
cd truckersmp-vr-linux
install -Dm755 truckvr ~/.local/bin/truckvr
```

Then, with Steam closed:

```sh
truckvr install
```

That is the whole setup. Start WiVRn, connect the headset, launch the game from
Steam. `F11` toggles VR in game, `F12` recenters.

> The headset shows the WiVRn lobby ("start an application on the server") for
> roughly the first 35 seconds while the game boots, scans profiles and lets
> TruckersMP inject. This looks broken and is not.

## Usage

```
truckvr [options] <command> [ets2|ats|both]

  doctor        diagnose every part of the stack and say what is wrong (default)
  install       do whatever is needed to make VR work, then diagnose
  on            enable VR for the next launch
  off           back to flat (monitor) mode
  patch         (re)apply the setupapi stub patch TruckersMP needs
  runtime       point OpenXR at WiVRn (fixes "no headset" after SteamVR ran)
  protons       list installed Protons and whether each one can do VR
  revert        undo everything this script changed

  --game G      ets2 | ats | both              (default: both)
  --proton NAME use this Proton instead of the detected one
  --all-protons patch every installed Proton, not just the active one
  --include-32  also patch 32-bit setupapi.dll (not needed for these games)
  --dry-run     say what would change, change nothing
  --yes         do not ask for confirmation
  --no-color    plain output
```

`truckvr protons` is the quickest way to answer "can this build do VR":

```
   VR  GE-Proton11-3                               GE-Proton11-3 >= GE-Proton11-3
   VR  Proton - Experimental                       experimental-11.0-20260713 built 20260713 (>= 20260707)
   --- Proton 11.0                                 Proton 11.0 is Proton 11.x — the fix is not backported
   --- proton-cachyos-11.0-20260703-slr-x86_64_v3  proton-cachyos-11.0-20260703-slr-x86_64_v3 built 20260703 (< 20260707)
```

## What it actually changes

Everything is reversible, and `--dry-run` shows you the plan first.

| File | Change | Backup |
|------|--------|--------|
| `$XDG_CONFIG_HOME/openxr/1/active_runtime.json` | rewritten to point at WiVRn | — (regenerated by `truckvr runtime`) |
| `<prefix>/…/TruckersMP/launcher-options.json` | adds/removes `-experimental_vr -openxr` in `consoleOpts` | `$XDG_DATA_HOME/truckvr/backups/` |
| `userdata/*/config/localconfig.vdf` | sets the game's `LaunchOptions` | `$XDG_DATA_HOME/truckvr/backups/` |
| `<proton>/files/lib/wine/x86_64-windows/setupapi.dll` | 3 bytes at one function entry | `setupapi.dll.truckvr-orig` beside it |
| `<proton>/files/lib/wine/x86_64-windows/user32.dll` | 2 bytes inside `MessageBoxExA` | `user32.dll.truckvr-orig` beside it |

Both DLL patches apply to the Proton dist *and* to each game's prefix, because
Proton gives every prefix its own copy and that copy is the one the game loads.

Neither patch will touch anything that is not byte-for-byte the code it expects,
and both write through symlinks atomically (prefix DLLs are sometimes symlinks
into a shared Proton dist). Both are also exactly reconstructable without the
backup file — they overwrite only constant opcode bytes — which matters because
a Proton update deletes the backup while leaving the patched DLL in place.

`truckvr revert` restores the DLLs from their backups and clears the VR flags.

## Notes and gotchas

**Do not run SteamVR.** It takes over `active_runtime.json` and deletes it on
exit. If VR stops working after you have opened SteamVR, run `truckvr runtime`.

**TruckersMP builds its own command line.** With SteamTinkerLaunch's
`ONLY_CUSTOMCMD=1`, flags in Steam's launch options are discarded. They have to
be in TruckersMP's `consoleOpts` as well — `truckvr` writes both, so it works
with or without TruckersMP.

**VR needs DX11.** A leftover `-rdevice gl` silently disables it. `truckvr on`
strips that flag and tells you it did.

**After a Proton update or a switch, re-run `truckvr patch`.** Updating Proton
restores the pristine (unpatched) DLL, and switching to a different Proton means
a dist that was never patched in the first place.

**TruckersMP in VR** does not render menus or player nameplates in the headset.
That is a known TruckersMP limitation, not a problem with this setup.

## Testing

```sh
./tests/run-all.sh            # everything
./tests/test-capability.sh    # the "does this Proton have the fix" rule
./tests/test-resolution.sh    # Proton/library/game discovery, on a synthetic Steam install
./tests/test-msgbox.sh        # the user32 patch, round-tripped against a real DLL
```

`test-resolution.sh` builds a throwaway Steam installation in `/tmp`, so it is
safe to run anywhere and does not touch your real setup. `test-msgbox.sh` copies
an installed `user32.dll` to a temp directory and patches the copy — it skips
itself with a note if no GE-Proton is installed to test against.

## Credits

- [WiVRn](https://github.com/WiVRn/WiVRn) — the OpenXR runtime doing the streaming
- Valve, for [Proton PR #9915](https://github.com/ValveSoftware/Proton/pull/9915)
- [GloriousEggroll](https://github.com/GloriousEggroll/proton-ge-custom) — GE-Proton
- [SteamTinkerLaunch](https://github.com/sonic2kk/steamtinkerlaunch) — optional, supported

Related: [WiVRn issue #979](https://github.com/WiVRn/WiVRn/issues/979) is the
same `xrPollEvent` symptom described in hurdle 3.

## License

MIT — see [LICENSE](LICENSE).
