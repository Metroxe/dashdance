<div align="center">

# iSlippi

### Super Smash Bros. Melee. Slippi Online. Native on Mac, iPad, iPhone and Vision Pro.

No emulator. No Dolphin. The game itself, translated ahead of time into native Apple Silicon code and rendered with Metal — with Slippi's matchmaking, rollback netcode and replays built in. The only Melee port with Slippi rollback on Apple platforms.

<sub>An unofficial, community client. Not affiliated with or endorsed by the Slippi team or Nintendo.</sub>

<img src="docs/images/match-onett.jpg" width="820" alt="Fox versus Luigi on Onett, running natively on macOS with the Slippi delay indicator in the corner">

<sub>Real capture from an Apple M5 Pro running macOS 27. Nothing from the game is included in this repository — you bring your own disc image.</sub>

<br>

![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-000000?logo=apple&logoColor=white)
![iOS](https://img.shields.io/badge/iPadOS%20%2F%20iOS-simulator%20verified-34C759?logo=apple&logoColor=white)
![visionOS](https://img.shields.io/badge/visionOS-builds-F5A623?logo=apple&logoColor=white)
![Renderer](https://img.shields.io/badge/renderer-Metal-5E5CE6)
![Slippi](https://img.shields.io/badge/Slippi-Online%20compatible-34C759)
![License](https://img.shields.io/badge/license-GPL--2.0--or--later-lightgrey)

</div>

---

## Why this exists

Melee has always been an emulated game on the Mac: a PowerPC console, simulated instruction by instruction, with the netcode bolted onto the emulator. This project takes the other road.

- **It is the real game.** The original executable and Slippi's code patches are translated once, ahead of time, into ordinary native code. Nothing is interpreted while you play.
- **It is Slippi.** Matchmaking, the rollback netcode, replays and game reporting are ports of Slippi's own open-source code. You play Unranked, Direct and Teams against people on regular Slippi Dolphin, and they never know the difference.
- **It is a Mac app.** Metal rendering, native audio, your keyboard, any SDL-compatible controller, and the official GameCube adapter over USB.

<div align="center">
<img src="docs/images/online-play.jpg" width="400" alt="The Slippi Online Play menu">&nbsp;
<img src="docs/images/character-select.jpg" width="400" alt="Character select with Fox and Luigi ready to fight">
</div>

## Get playing

You need an Apple Silicon Mac (or an iPad, iPhone or Vision Pro), your own **Super Smash Bros. Melee NTSC 1.02** disc image (`.iso` or `.gcm`), and a free [Slippi account](https://slippi.gg) for online play.

1. **Build the app** (about ten minutes the first time — see [Build from source](#build-from-source)).
2. **Open iSlippi.** The dashboard walks you through it: choose your disc image (on iPad and iPhone, import it or drop it into the app's folder in Files). The app remembers it.
3. **Sign in to Slippi** right there — email and password, no separate app. You stay signed in, and the dashboard shows your ranked tier, rating, record, daily placement, most-played characters and your recent games.
4. **Play.**

<div align="center">
<img src="docs/images/mac-launcher.jpg" width="420" alt="The macOS dashboard: ranked profile, recent games, Slippi account, disc, controllers and display settings">
&nbsp;&nbsp;
<img src="docs/images/ipad-launcher.jpg" width="300" alt="The same dashboard on iPad">
<br><sub>The dashboard on macOS and iPad (shown with sample data). Ranked stats come from Slippi's profile API; recent games are read from your own replays.</sub>
</div>

### The dashboard

| Card | What it does |
|---|---|
| **Get started** | A checklist that ticks itself off: disc, sign-in, controller, Play. It disappears once you are set up. |
| **Ranked** | Tier (Bronze through Grandmaster, using Slippi's thresholds), rating, wins and losses with a win-rate bar, daily global and regional placement, and your mains by games played. |
| **Recent games** | Your last games parsed from the `.slp` replays the app writes: characters, opponent, stage, duration, and whether you won. |
| **Slippi Online account** | Sign in, sign out, password reset. The session is kept on the device so ranked stats reload on every launch. |
| **Game disc** | Choose or drop the disc image. |
| **Controllers** | Every connected controller, its GameCube port (auto or fixed 1–4), and a remap flow: click a GameCube control, press the button you want. Mappings are saved per controller. |
| **Display & performance** | Internal resolution (auto picks the display), anisotropic filtering, display sync, widescreen, sharpening, full screen on macOS, plus the GPU and the display's refresh rate so you can see what the app is running on. |
| **On-screen controls** (iPad, iPhone) | Opacity and size of the touch controller. |

### Controls

| GameCube | Keyboard |
|---|---|
| Control stick | Arrow keys |
| C-stick | I J K L |
| A / B / X / Y | Z / X / C / V |
| L / R / Z | Q / W / E |
| D-pad | T F G H |
| Start | Return |

Any controller SDL recognises works out of the box, over Bluetooth or a cable: PlayStation, Xbox, Switch Pro, MFi and most USB pads. On a Mac a WUP-028 GameCube adapter (the Nintendo Wii U / Switch one) is read directly over USB with the same 1 ms polling the real console uses and takes priority on the ports it has controllers plugged into. iPadOS and iOS do not expose raw USB devices to apps, so on those the adapter is not available; a Bluetooth or USB-C pad is the way to play with a physical controller there. Ports and button mappings are managed from the Controllers card on the dashboard.

### On iPad, iPhone and Vision Pro

Touch controls appear automatically and fade away the moment a Bluetooth controller connects. They follow the on-screen controller design from [VirtualFriend](https://github.com/agg23/virtualfriend): a GameCube layout with an analog stick, the A/B/X/Y cluster, Z, a C-stick and triggers, with haptic feedback on every press and presses that slide between buttons. Hold the device upright and the game sits on top with the controls below; turn it sideways and they move to the sides.

<div align="center">
<img src="docs/images/ipad-touch-controls.jpg" width="360" alt="iPad in portrait: the game on top, the touch controller below">
<br><sub>iPad Pro in the Simulator, native resolution, controls below the game.</sub>
</div>

### Built for the hardware

Slippi is competitive, so the app uses what Apple devices offer for latency:

| | |
|---|---|
| **ProMotion / variable refresh** | The game simulates at 60 Hz (rollback depends on it); every finished frame is shown on the very next refresh of a 120 Hz display instead of waiting for a 60 Hz slot, up to 8 ms sooner. Double-buffered swapchain, iPhone 120 Hz opt-in. |
| **Game Mode** | Declared as a game, so macOS and iOS give it CPU/GPU priority and cut Bluetooth controller latency in full screen. |
| **Performance cores** | The simulation and render threads run at user-interactive QoS on Apple silicon. |
| **Wi-Fi traffic class** | Netplay and matchmaking sockets use the voice service class, the lowest-latency Wi-Fi queue. |
| **Controllers** | GameCube adapter (WUP-028) over USB on macOS, any Bluetooth or MFi pad with rumble, keyboard, and touch with haptics. Ports and mappings per controller. |
| **Measured latency** | With the game's own instrumentation (`MELEE_METAL_LATENCY=1` logs XFB-copy-to-panel time from Metal's presented timestamps): about 10 ms in full screen on a 120 Hz MacBook Pro, about 25 ms in a window, because a window costs one compositor frame. Full screen is the default; ⌥⏎ toggles. The simulation itself takes about 4 ms of each 16.7 ms frame on an M5 Pro, GPU work 5–8 ms, render encoding about 1 ms. |
| **Render thread** | The simulation hands each frame to a queue and never waits for the GPU or the display. Measured on a ProMotion MacBook Pro: Metal's `nextDrawable` can block for 15–30 ms when the display pipeline holds both drawables, and with rendering on the game thread that was a dropped game frame every time (up to 80 late frames a minute). With the render thread: zero late frames in a minute of play, and the stall costs only a shown frame. |
| **Real-time simulation thread** | The simulation thread asks the kernel for a time-constraint (real-time) policy with a 16.7 ms period, so background work cannot push a frame past its deadline. `MELEE_REALTIME=0` turns it off. |
| **Honest about refresh** | The game is a 60 Hz simulation and Slippi rollback depends on it staying that way; a 120 Hz display shortens the wait between a finished frame and the pixels, it does not double the frame rate. The dashboard shows the display's real maximum. |
| **Metal** | Native renderer at integer multiples of the original resolution, supersampling, anisotropic filtering, contrast-adaptive sharpening. |

## Where it stands

| | Status |
|---|---|
| Boot, menus, offline VS matches | ✅ Working |
| Slippi Online: login, matchmaking, rollback, replays | ✅ Working — verified with two local instances staying in sync for a full game |
| Audio, keyboard, gamepads, GameCube adapter | ✅ Working |
| Memory card saves (`.gci` folder) | ✅ Working |
| Rendering | ✅ Native Metal renderer with the same Dolphin-derived shader pipeline as the Windows build, integer internal resolution up to 16× plus supersampling, 120 Hz-ready presentation |
| Native Slippi sign-in (no Slippi Launcher needed) | ✅ Working — Firebase email/password, play key from Slippi's backend |
| iPad / iPhone | ✅ Boots and renders at native resolution in the Simulator with touch controls, launcher and disc import; not yet run on a physical device |
| Apple Vision Pro | 🟡 Builds for the visionOS Simulator; no visionOS runtime is installed here yet, so untested |

This is an alpha. Expect rough edges, and please report them.

<div align="center">
<img src="docs/images/netplay-stadium.jpg" width="620" alt="An online match on Pokémon Stadium between two local instances">
<br><sub>Two instances of the app in an online match against each other on one Mac.</sub>
</div>

## How it works

1. **Translate.** `port/recomp` reads your disc's executable and Slippi's Gecko code tables and writes one C++ function per game function. Apple Clang compiles them into a static library. This step runs on your machine; nothing from the game is ever committed here.
2. **Run.** `port/runtime` is the host: guest memory, the GameCube SDK services the game expects (disc, controllers, audio DSP, memory cards), and the Slippi EXI device that Slippi's code talks to.
3. **Draw.** The game's GX commands are decoded into draw calls and rendered by a native Metal backend (`port/runtime/gx/gx_metal.mm`) with shaders generated the way Dolphin generates them, so what you see matches the Windows build.
4. **Connect.** `slippi_net` and `slippi_online` are wire-compatible ports of Slippi Dolphin's netplay client, matchmaking and reporting.

## Build from source

Requirements: Xcode Command Line Tools, Homebrew (`cmake ninja python libusb`), a checkout of [doldecomp/melee](https://github.com/doldecomp/melee) for the animation helpers, and your disc's `main.dol`.

```bash
git clone https://github.com/TheAndersMadsen/islippi.git
cd islippi
tools/bootstrap_aurora.sh
python3 tools/bootstrap_port.py --decomp-root /path/to/doldecomp-melee \
  --dol /path/to/main.dol --build-dir build/mac --gct-base 0x8065CC80 --macos-arch arm64 --stage generate
cmake -S . -B build/mac -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DMELEE_DECOMP_ROOT=/path/to/doldecomp-melee -DMELEE_DOL_PATH=/path/to/main.dol \
  -DMELEE_PORT_GENERATED_DIR=$PWD/build/mac/generated/guest \
  -DMELEE_BUILD_PORT_TESTS=ON -DMELEE_BUILD_PORT_HEADLESS=ON -DMELEE_BUILD_PORT_METAL=ON
cmake --build build/mac --target melee_port_mac --parallel
tools/package_macos_app.sh build/mac dist
open dist/iSlippi.app
```

### iPad, iPhone and Vision Pro

The same tree builds the device apps with a full Xcode install. For the iPad Simulator:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 tools/bootstrap_port.py --decomp-root /path/to/doldecomp-melee \
  --dol /path/to/main.dol --build-dir build/ios-sim --gct-base 0x8065CC80 --macos-arch arm64 --stage generate
cmake -S . -B build/ios-sim -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DMELEE_DECOMP_ROOT=/path/to/doldecomp-melee -DMELEE_DOL_PATH=/path/to/main.dol \
  -DMELEE_PORT_GENERATED_DIR=$PWD/build/ios-sim/generated/guest \
  -DMELEE_BUILD_PORT_TESTS=OFF -DMELEE_BUILD_PORT_HEADLESS=OFF -DMELEE_BUILD_PORT_METAL=ON
cmake --build build/ios-sim --target melee_port_mac --parallel
xcrun simctl install booted build/ios-sim/port/iSlippi.app
```

Use `-DCMAKE_OSX_SYSROOT=iphoneos` for a device (sign the bundle with your team) and `-DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xrsimulator -DCMAKE_OSX_DEPLOYMENT_TARGET=1.0` for the Vision Pro Simulator.

`melee_port_mac --help` lists every option (window size, volume, input delay, explicit disc or Slippi folder). `melee_port_metal` and `melee_port_headless` are offline diagnostic executables used by the test suite. Developer notes live in [docs/](docs/).

## Windows

The upstream project, [Hero88go/melee-unlocked](https://github.com/Hero88go/melee-unlocked), is the Windows build with D3D12, DLSS and an unlocked display rate. This repository tracks it and adds the Apple platforms.

## Credits and legal

Built on the work of the [Slippi](https://slippi.gg) team, the [Dolphin](https://dolphin-emu.org) project, [SDL](https://libsdl.org), [Aurora](https://github.com/encounter/aurora) (build tooling and the diagnostic renderer), the [doldecomp/melee](https://github.com/doldecomp/melee) contributors, and [Hero88go/melee-unlocked](https://github.com/Hero88go/melee-unlocked). This project is not affiliated with or endorsed by the Slippi team, Nintendo or HAL Laboratory.

GPL-2.0-or-later. Super Smash Bros. Melee is the property of Nintendo and HAL Laboratory. This repository contains no game data; you must supply your own legally obtained disc image.
