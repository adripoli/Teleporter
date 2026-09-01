# Teleport

Set a real iPhone's location from your Mac. Drag a pin on a map, or type `48.8583,2.2945`
in a terminal — either way the phone believes it, and so does every app on it.

Two front ends, one engine:

| | |
|---|---|
| **Teleport.app** | A map. Drag the pin, hit Set Location, the phone is there. |
| **simplyteleporter** | A prompt. Type a coordinate, press return. |

```
  simply TELEPORTER
  latitude,longitude — and the phone is there

 ◆ pymobiledevice3 · /Users/you/.local/bin/pymobiledevice3
 ◆ Adrian's iPhone · iPhone 15 Pro · iOS 26.1
   type a coordinate like 48.8583,2.2945 — or help

 ● teleport ▸ 48.8583,2.2945

 ╭─ ARRIVED ──────────────────────────────────────────────────────╮
 │  latitude   48.858300° N                                       │
 │  longitude  2.294500° E                                        │
 │  device     Adrian's iPhone · iPhone 15 Pro                    │
 │  holding — the phone stays here until you clear or quit        │
 ╰────────────────────────────────────────────────────────────────╯
```

No jailbreak, no root, no Xcode project open, no developer account. It drives Apple's own
device services through [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3).

---

## Requirements

- **macOS 26** or later, Apple Silicon or Intel
- **An iPhone on USB**, unlocked, trusted, with Developer Mode on
  (Settings › Privacy & Security › Developer Mode — the phone restarts once)
- **pymobiledevice3**:
  ```sh
  pipx install pymobiledevice3
  ```
  (`brew install pipx` first if you need it. Teleport looks in `~/.local/bin`,
  `/usr/local/bin`, and `/opt/homebrew/bin`.)

## Install

### Terminal

```sh
curl -fsSL https://raw.githubusercontent.com/adripoli/Teleporter/main/install.sh | bash
```

Installs the `simplyteleporter` CLI, verifies its checksum, and clears the quarantine flag
so it runs straight away. Add `-s -- --app` to install the map app too:

```sh
curl -fsSL https://raw.githubusercontent.com/adripoli/Teleporter/main/install.sh | bash -s -- --app
```

<details>
<summary>Options</summary>

```
--app              also install Teleport.app into /Applications
--version=v1.0.0   install a specific release (default: latest)
--bin-dir=DIR      where to put simplyteleporter (default: /usr/local/bin,
                   falling back to ~/.local/bin when that isn't writable)
```
</details>

### Disk image

Grab `Teleport-<version>.dmg` from the [latest release](https://github.com/adripoli/Teleporter/releases/latest)
and drag Teleport to Applications.

Because these builds are ad-hoc signed rather than notarized, Gatekeeper will refuse the
first launch. Either **right-click the app › Open** and confirm once, or clear the flag:

```sh
xattr -dr com.apple.quarantine /Applications/Teleport.app
```

The terminal installer above does this for you.

### From source

```sh
git clone https://github.com/adripoli/Teleporter.git
cd Teleporter
./build.sh
```

Leaves `Teleport.app` and `simplyteleporter` in the working directory. Add `--universal`
for a fat binary; that is what releases ship.

## Using it

### The app

Drag the pin, or click anywhere on the map to move it there, or type coordinates into the
fields behind the pin button in the corner. Then **Set Location**.

| | |
|---|---|
| `⌘↩` | Set location |
| `⌘⌫` | Reset to the phone's real GPS |
| `⌘R` | Rescan for connected iPhones |

The pin position is remembered between launches.

### The CLI

```sh
simplyteleporter
```

| Command | |
|---|---|
| `48.8583,2.2945` | Teleport — latitude first |
| `clear` | Stop simulating, hand location back to the phone |
| `status` | Where the phone currently thinks it is |
| `devices` | Rescan USB and pick a different iPhone |
| `help` | The list above |
| `quit` | Release and exit (`Ctrl+C` works too) |

Coordinates are read loosely — `40,32`, `40, 32`, `40 32`, `(40, 32)` and `40.7°, -74.0°`
all land in the same place. Get latitude and longitude the wrong way round and it says so
rather than sending the phone to the ocean.

Pass a coordinate as an argument for one-shot use, handy from a script or a second tab.
It applies the location and then holds until you interrupt it:

```sh
simplyteleporter 48.8583,2.2945
```

## How it works

`pymobiledevice3`'s `simulate-location set` is invoked with `--native`, which piggybacks on
Apple's own `remoted` tunnel via `remotepairingd`. That is what keeps this root-free on
iOS 17+ and lets it coexist with Xcode and `devicectl` instead of fighting them for the
tunnel.

The simulated location lasts exactly as long as that process lives. Teleport parks it in
the background and holds it open, which is why quitting the app, typing `clear`, or hitting
`Ctrl+C` all hand the phone back to its real GPS — and why the CLI installs signal handlers
rather than letting the default disposition kill it, since macOS would otherwise leave an
orphan holding your phone somewhere in Paris.

Location simulation lives behind DVT services that only exist once the personalised
developer disk image is mounted. Teleport checks and mounts it for you on first use; it
survives reboots, so after that it is a no-op.

## When it doesn't work

| What you see | What it means |
|---|---|
| *pymobiledevice3 isn't installed* | `pipx install pymobiledevice3` |
| *Your iPhone is locked* | Unlock it and leave it on the Home Screen |
| *This Mac isn't trusted* | Unlock the phone and tap Trust |
| *Developer Mode is off* | Settings › Privacy & Security › Developer Mode, then restart |
| *No iPhone on USB* | Check the cable, then `devices` / `⌘R`. Wireless devices aren't supported. |
| *The developer disk image isn't available* | Unlock the phone and retry — Teleport mounts it |

The phone stays teleported after Teleport exits? Something orphaned the session. Find it
with `pgrep -fl simulate-location` and kill it.

## Repository layout

```
Sources/
  TeleportCore/       device plumbing shared by both front ends
  Teleport/           the SwiftUI map app
  SimplyTeleporter/   the terminal front end
Resources/Info.plist  bundle metadata for the app
build.sh              builds both front ends
package.sh            builds the release artifacts into dist/
install.sh            what the curl one-liner runs
```

Swift 6.2, strict concurrency (language mode v6) across every target.

## Releasing

```sh
./package.sh
```

Produces a universal `.dmg`, a `.zip` of the same app, a `.tar.gz` of the CLI, and
`SHA256SUMS.txt` over all three. Bump `CFBundleShortVersionString` in `Resources/Info.plist`
first — `package.sh` reads the version from there, and `install.sh` maps release tag
`vX.Y.Z` onto artifacts named `X.Y.Z`.

## Licence

MIT — see [LICENSE](LICENSE).

Teleport is a developer tool for testing location-dependent behaviour in software you are
working on. What you do with it is on you.
