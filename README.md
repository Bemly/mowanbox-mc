# MowanBox (mowanbox-mc)

[简体中文](README.zh.md)

An in-game overlay mod menu ("toolbox") for Minecraft: Pocket Edition on jailbroken iOS devices. It is built as a Cydia Substrate tweak, injected into the game process, and renders a pixel-art UIKit overlay inspired by the classic MCPE Toolbox layout: a category rail on the left, a settings panel on the right.

> Local, offline, single-player use only. Do not use it on multiplayer servers, Realms, or anti-cheat protected environments.

## Highlights

- Draggable avatar button with a pass-through overlay window
- Five-page menu: Cheats / World / Items / Float / Model
- Creative item browser with categories, variants, recipes, and a spawn-egg tab
- Runtime GLB model rendering ("4D skin") and a model showcase
- Runtime Chinese localization for 0.10 without modifying game bundles
- Minimap, slime-chunk overlay, and a four-view camera slider
- Runtime game-version detection with per-version hook backends

## Supported game versions

The version is detected from `CFBundleShortVersionString` first, then from the size of the main binary as a fallback (`MWBVersion.mm`). The tweak filter covers six bundle IDs.

| Game | Bundle ID | Status |
|---|---|---|
| 0.10.0 | `moe.bemly.mcpe.0.10` | Full implementation; primary target |
| 1.1.7 | `moe.bemly.mcpe.1.1` | Partial: abilities, time, held-item enchant |
| 1.2.15 | `moe.bemly.mcpe.1.2` | Partial: abilities, time, weather, heal, enchant; not device-verified |
| 1.4.3 | `moe.bemly.mcpe.1.4` | Partial: abilities, time, weather, heal, enchant |
| 1.13.3 | `moe.bemly.mcpe.1.13` | Partial: abilities, time, weather, kill aura, minimap, heal, teleport, fill |
| 1.20.62 | `moe.bemly.mcpe.1.20` | Experimental: ECS hooks, time control; most other features are observation-only |

Controls without a working backend are disabled (dimmed) by the UI.

## Features

### Cheats page

Toggles: Invincible, Fly, Instabreak, Noclip, Night Vision, Kill Aura, Minimap, Slime Chunks, Debug logging, Fast Run, Super Jump, 4D Skin.

### World page

- Time presets: sunrise, day, noon, dusk, night, midnight, plus `-233` / `+233` tick adjust
- Weather: clear / rain / thunder (1.2.15, 1.4.3, 1.13.3 only)
- Actions: heal, enchant held item to level 255, teleport up 10 blocks, fill a 5x5x5 stone area
- Difficulty: peaceful / easy / normal / hard
- Nether reactor: ignite
- Explosion at the player position
- Game mode: survival / creative

Time presets beyond day/night, tick adjust, difficulty, reactor, explosion, game mode, teleport, and fill currently have 0.10-only menu backends unless noted above.

### Items page

An EMI-style creative item browser:

- Tabs: all / equipment / functional / building blocks / spawn eggs
- Single tap gives one item; double tap gives a stack; long press shows the crafting recipe
- Multi-variant items open a variant picker
- The spawn-egg tab spawns 15 mob types near the player
- Item IDs and metadata are read from the game's own item registry; recipes come from the game's `Recipes` singleton

The item grid, item giving, variant selection, recipes, and mob spawning are implemented on 0.10.

### Float page

Overlay size (small / medium / large), opacity (low / medium / high), position reset, and UI language (Chinese / English on 0.10).

### Model page

- Scans `/var/mobile/Documents/mwbmodels/` for `<id>.glb` and `<id>_anim.json`
- Card showcase with pre-baked intro/loop sprite strips
- Per-model settings generated from the sidecar JSON (checkbox, range, radio)
- Selecting a model switches the 4D skin; the GLB replaces the local player in third person only

### Other

- **Minimap**: draggable and position-persistent; surface/cave scanning on 0.10, single-layer sampling on 1.13.3
- **Camera**: turns the 0.10 third-person toggle into a four-step slider (first person / third-person back / third-person front / face-follow)
- **Localization**: rewrites the game's in-memory `I18n` map on 0.10 with 853 GUI, entity, item, death, and achievement strings plus block names; no bundle files are modified

## Requirements

- Jailbroken arm64 iOS device, iOS 12.0+ (tested on iPad mini 2, iOS 12.5.8)
- Cydia Substrate / MobileSubstrate
- macOS with Xcode and the iOS SDK for building
- [Theos](https://theos.dev/), `dpkg`, and `xz`

## Build

```bash
export THEOS=~/theos
export PATH="$THEOS/bin:$PATH"

make package                  # debug build: writes /var/mobile/Documents/mowanbox.log
make package FINALPACKAGE=1   # release build: logging compiled out
```

Artifacts are written to `packages/`. The Makefile injects a build tag (`git rev-list --count`, short hash, dirty marker) into the binary and logs it at startup.

CI (`.github/workflows/build.yml`) builds both debug and release packages on pushes to `main` and on pull requests. Pushing a `v*` tag, or running the workflow manually with "release" enabled, creates a GitHub Release with both `.deb` files.

## Install

```bash
scp packages/*.deb root@<device-ip>:/tmp/mowanbox.deb
ssh root@<device-ip> "dpkg -i /tmp/mowanbox.deb"
```

Restart the game so the tweak is injected. On the reference device `killall` and `ps` can hang, so use `launchctl` plus `SIGTERM`:

```bash
ssh root@<device-ip> "launchctl list | grep -i mcpe"   # note the PID
ssh root@<device-ip> "kill -15 <pid>"
ssh root@<device-ip> "uiopen moe.bemly.mcpe.0.10"
```

The bundle ID in the last command must match the installed game.

## Usage

Tap the floating avatar to open the menu and drag it to move it. The overlay window passes touches through outside the panel, so the game remains playable. Use the side rail to switch pages and the close button to dismiss the menu.

## Files on device

| Path | Purpose |
|---|---|
| `/var/mobile/Documents/mowanbox.log` | Debug log (debug builds only) |
| `/var/mobile/Documents/mwbfloat.plist` | Overlay size, opacity, and position |
| `/var/mobile/Documents/mwbminimap.plist` | Minimap position |
| `/var/mobile/Documents/mwbmodels/<id>.glb` | GLB model |
| `/var/mobile/Documents/mwbmodels/<id>_anim.json` | YSM animation sidecar |
| `/var/mobile/Documents/mwbmodels/<id>_thumb_intro.png` | Showcase intro strip |
| `/var/mobile/Documents/mwbmodels/<id>_thumb_loop.png` | Showcase loop strip |

Plugin preferences are stored separately from game saves. The tweak does not edit save files directly; world changes go through the game's own APIs.

## Project layout

| Path | Description |
|---|---|
| `Tweak.xm` | Entry point, global state, version dispatch |
| `MWBVersion.{h,mm}` | Runtime version detection |
| `MWBCommon.h` | Shared globals, offsets, and cross-file interfaces |
| `MWBUI.{h,mm}` | Pixel-art UI toolkit |
| `MWBMenu.{h,mm}` | Five-page options menu |
| `MWBFloat.{h,mm}` | Floating button, overlay window, and preferences |
| `MWBHooks010.mm` | 0.10 hooks (primary backend) |
| `MWBHooks117.mm`, `MWBHooks1215.mm`, `MWBHooks143.mm`, `MWBHooks1133.mm` | 1.1.7 / 1.2.15 / 1.4.3 / 1.13.3 backends |
| `MWBHooks120.mm` | 1.20.62 ECS hooks (experimental) |
| `MWBActions.mm` | Cross-version action dispatcher and `/tmp/mwbcmd-*` flag channel |
| `MWBCamera010.mm` | 0.10 four-view camera |
| `MWBMinimap.mm` | Minimap rendering |
| `EMI*.{h,mm}` | Item browser, item table, views, and window |
| `MWBSkin4D.{h,mm}`, `MWBGLBModel.{h,mm}`, `MWBGLBMolang.{h,mm}` | GLB parsing, Molang, rendering, and 4D skin |
| `MWBYSMAnim.*`, `MWBYSMCodec.*`, `MWBYSMMenu.mm`, `MWBYSMModel.*`, `MWBYSMRender.mm` | YSM model decoding, animation, and showcase |
| `MWBZhLang.mm`, `MWBZhGui.mm`, `MWBZhBlocks.mm` | 0.10 runtime Chinese localization |
| `MWBDebug.mm` | Touch simulation and debug helpers |
| `web/` | Browser-side GLB validation harness |
| `tools/` | Offline model baking and sidecar scripts |
| `docs/` | Reverse-engineering notes |

## Automation / flag channel

For debugging, actions can be triggered by creating files under `/tmp` on the device:

```bash
touch /tmp/mwbcmd-inv-1
touch /tmp/mwbcmd-time-2
touch /tmp/mwbcmd-menupage-1
```

See the comment block at the top of `MWBActions.mm` for the full command list.

## Limitations

- 0.10.0 is the only fully implemented backend; other versions expose a subset and dim unsupported controls.
- 1.2.15 hooks are included but have not been verified on a device.
- 1.20.62 support is experimental.
- 4D skin and the model showcase require 0.10 and GLB assets placed on the device.
- The repository does not include or redistribute Minecraft assets, textures, sounds, or game binaries.

## License

Released under the **SIL Open Font License 1.1 (OFL-1.1)**. See [LICENSE](LICENSE) for the full text.

OFL was originally designed for font software. Third-party components included in this repository remain under their own licenses; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The embedded Fusion Pixel font is Copyright (c) 2022 TakWolf and is also licensed under OFL-1.1.

## Disclaimer

This project is for learning and local offline experimentation only. It is not affiliated with Mojang or Microsoft. Minecraft is a trademark of Mojang Synergies AB. Do not use it to cheat on multiplayer servers.
