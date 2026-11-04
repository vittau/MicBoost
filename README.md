<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/design/readme/header-dark.png"><img src="docs/design/readme/header-light.png" alt="MicBoost — microphone icon with ascending level bars, next to the MicBoost wordmark" width="740"></picture></p>

# MicBoost

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](#what-you-need)
[![Apple Silicon and Intel](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-black.svg)](#what-you-need)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ff69b4.svg)](https://github.com/sponsors/vittau)

**Make your microphone louder and clearer in calls and recordings on your Mac.** MicBoost lives
in the menu bar, boosts and cleans up your voice, and works with any app: Zoom, Google Meet,
Microsoft Teams, FaceTime, Discord, QuickTime and more.

> [!NOTE]
> This project is developed and maintained with the help of AI agents, under the direction and
> review of its human maintainer.

> [!WARNING]
> **Early version (0.1.0).** It works for everyday calls, but some situations are still being
> tested.

## What it does

- **Makes a quiet microphone loud enough**: up to 16 times louder (+24 dB), with a simple slider.
- **Makes your voice clearer**: a voice preset removes low rumble and adds a touch of presence,
  without making you sound thin. Bass, mids and treble are adjustable if you want.
- **Keeps loud moments from distorting**: if you laugh, cough or clap, MicBoost holds the level
  down automatically. A **Limiter active** badge shows when it does.
- **Works with any app**, without setting anything up in each one.
- **One switch to turn it off** and give your microphone back to the system.
- **Recovers on its own** if you unplug the microphone or the Mac sleeps.
- **Adds almost no delay**: about 15 milliseconds with a USB microphone, far below what anyone
  can notice in a call.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/eq-dark.png">
    <img src="docs/screenshots/eq-light.png" alt="MicBoost menu with the on/off switch, gain, level meters, microphone list and equalizer" width="320">
  </picture>
  <br>
  <sub>The MicBoost menu: on/off switch, volume, level meters, microphone and equalizer.</sub>
</p>

## What you need

- A Mac with macOS 14 Sonoma or later (Apple Silicon or Intel).
- **BlackHole 2ch**, a free audio driver. MicBoost sends your processed voice to it, and your
  apps listen to it like a microphone. The steps below install it.

## Install

1. **Install BlackHole 2ch.** Download the installer from the
   [BlackHole website](https://existential.audio/blackhole/) and run it. It asks for your Mac
   password. If you use Homebrew, `brew install --cask blackhole-2ch` does the same.
2. **Download MicBoost.** On the [Releases page](https://github.com/vittau/MicBoost/releases),
   download `MicBoost-<version>.zip`.
3. **Unzip it** (double-click) and **drag `MicBoost.app` to your Applications folder**.
4. **Open MicBoost.** The first time, macOS blocks it, because MicBoost is a free app that is not
   registered with Apple. That is expected:
   1. Open **System Settings → Privacy & Security**.
   2. Scroll down to the message about MicBoost and click **Open Anyway**.
   3. Confirm with your password or Touch ID.

   You only do this once. Never follow advice to turn off Mac security features to open an app.
5. **Allow microphone access** when macOS asks.

## How to use

1. Click the **MicBoost icon** in the menu bar.
2. Under **Microphone**, choose the microphone you want to use.
3. Make sure the switch at the top is **on**.
4. In your call or recording app, choose the microphone **BlackHole 2ch**, or leave it on the
   system default. MicBoost sets itself as the system microphone while it is on.
5. Speak normally and move the slider until the **Output** bar moves well with your voice. If
   **Limiter active** shows up all the time, it is too loud: move the slider down a little.

Close the menu whenever you like; MicBoost keeps working. To stop, turn the switch off. When you
quit MicBoost, your previous microphone comes back.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-dark.png">
    <img src="docs/screenshots/settings-light.png" alt="MicBoost settings window with the Audio, Diagnostics and About sections" width="540">
  </picture>
  <br>
  <sub>Settings, under "Settings…" in the menu. You rarely need it.</sub>
</p>

## Good to know

- **A louder microphone also makes background noise louder.** If you can, speak closer to the
  microphone, or turn up its own volume knob first.
- **Bluetooth headsets** (such as AirPods) sound worse while their microphone is in use. This is
  how Bluetooth works, not MicBoost. A USB or built-in microphone sounds better.
- **The iPhone microphone** (Continuity) adds a noticeable delay of its own.
- **The MacBook's built-in microphone is off when the lid is closed.**

## Something's wrong?

**macOS says it can't open MicBoost.** See step 4 of [Install](#install).

**People in the call can't hear me.** In the call app's settings, choose the microphone
**BlackHole 2ch** (or the system default), and check that the MicBoost switch is on.

**MicBoost says "BlackHole 2ch not found".** Install BlackHole (step 1 of [Install](#install)).
If you just installed it, restart the Mac.

**MicBoost says it has no access to the microphone.** Click **Open Privacy Settings** in the
message and turn MicBoost on. macOS may ask to reopen the app.

**The sound stopped.** Turn the MicBoost switch off and on again. If the microphone was
unplugged, plug it back in; MicBoost picks it up again on its own.

## Uninstall

1. Choose **Quit MicBoost** in its menu, so your previous microphone comes back.
2. Drag `MicBoost.app` from Applications to the Trash.

BlackHole stays installed, because other apps may use it. To remove it, follow the instructions on
the [BlackHole website](https://existential.audio/blackhole/).

## Support

MicBoost is free and made in spare time. If it helps you, you can chip in:

[![GitHub Sponsors](https://img.shields.io/badge/GitHub-Sponsor-ea4aaa.svg)](https://github.com/sponsors/vittau)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-vittau-ffdd00.svg)](https://www.buymeacoffee.com/vittau)

## For developers

MicBoost captures the chosen microphone directly and runs a 3-band EQ, gain and a peak limiter
in a single real-time callback on a private aggregate device, then writes to BlackHole 2ch, with
no audio queue in between. Measured latency, stability results and the full specification are in
[`docs/`](docs/README.md). To build it yourself (Xcode 27.2):

```sh
git clone https://github.com/vittau/MicBoost.git
cd MicBoost
swift test
scripts/build-app.sh debug
open build/MicBoost.app
```

Releases are ad-hoc signed and not notarized; see [docs/distribution.md](docs/distribution.md).

## License

MicBoost is free software, released under the [GNU General Public License v3.0](LICENSE). You may
use, study, modify and share it; versions you distribute must stay under the same license, with
their source code available.

## Credits

- **[BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole)** by Existential Audio — the
  free audio driver MicBoost sends its sound to. It is installed separately and used unmodified.
- **[VirtuMic](https://github.com/ShotgunZZ/VirtuMic)** and **LitLink** — apps evaluated before
  MicBoost, whose limitations motivated it. MicBoost is an independent implementation and reuses
  no code or assets from either.

MicBoost is not affiliated with, endorsed by or sponsored by Apple Inc. or Existential Audio.
**Apple**, **macOS** and **Mac** are trademarks of Apple Inc.; **BlackHole** is a product of
Existential Audio. All trademarks belong to their respective owners.
