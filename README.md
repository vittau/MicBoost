<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/design/readme/header-dark.png"><img src="docs/design/readme/header-light.png" alt="MicBoost — microphone icon with ascending level bars, next to the MicBoost wordmark" width="740"></picture></p>

# MicBoost

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](#requirements)
[![Apple Silicon and Intel](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-black.svg)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](#requirements)
[![Not notarized](https://img.shields.io/badge/signing-ad--hoc%2C%20not%20notarized-red.svg)](#first-launch)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ff69b4.svg)](https://github.com/sponsors/vittau)

A native macOS menu bar app that captures the microphone you choose, boosts and shapes it, and
hands the result to [BlackHole 2ch](https://existential.audio/blackhole/) so that every app —
calls, recorders, anything — hears the processed voice.

> [!NOTE]
> This project is developed and maintained with the help of AI agents, under the direction and
> review of its human maintainer.

> [!WARNING]
> **Pre-release:** the menu bar panel, EQ and settings are available from source. Releases,
> the Homebrew tap and full recovery/accessibility validation remain pending.

## Screenshots

| Panel (light) | Panel (dark) |
| --- | --- |
| ![Panel](docs/screenshots/panel-light.png) | ![Panel dark](docs/screenshots/panel-dark.png) |
| EQ expanded | Settings |
| ![EQ](docs/screenshots/eq-light.png) | ![Settings](docs/screenshots/settings-light.png) |
| Missing driver | Missing driver (dark) |
| ![Error](docs/screenshots/error-light.png) | ![Error dark](docs/screenshots/error-dark.png) |

Off-screen renders of the real SwiftUI views with sample state; live panel transparency
adapts to your desktop and macOS appearance. Generated with
`scripts/render-screenshots.sh`. Both appearances for every view are in `docs/screenshots/`.

## How it works

```text
Microphone → 3-band EQ → gain → peak protection → BlackHole 2ch → apps
```

The engine creates a **private aggregate device** with two sub-devices: the chosen source as the
clock master and BlackHole 2ch with drift compensation. A single C IOProc receives the source
input and writes the BlackHole output in the same cycle, so nothing is queued between callbacks.
The added latency is bounded by the buffer and the device safety offsets, and the drift between
the two clocks is handled by Core Audio's drift resampler instead of a ring buffer that grows.
The aggregate is private: other apps never see it, and it disappears with the process.

Gain, mute and the 3-band EQ can be adjusted in the menu bar panel. Peak protection
keeps the output below −1 dBFS; human voice calibration and listening checks remain pending.

## Features

Available today:

- **Gain from −12 to +24 dB**, mute and peak protection; mute and the limiting indicator keep
  the panel layout stable.
- **3-band EQ** with adjustable bass, parametric mids and treble, bypass and reset. Click its
  title or disclosure arrow to expand or collapse the adjustments; the EQ switch stays visible
  in the header. Expansion is immediate to keep the menu stable. Each band has a clear section heading.

- **Any Core Audio input**, captured explicitly by UID — the source does not have to be the
  system default input.
- **No audio queue**: private aggregate device and one IOProc, with latency measured and
  documented below.
- **BlackHole 2ch as the destination**, with BlackHole variants and aggregates containing
  BlackHole excluded from the source list, so feedback cannot be selected.
- **Safe silence on zero input**: a source that delivers zeros — the built-in microphone with the
  lid closed, for example — produces silence in BlackHole, not noise.

- **Recognizable menu bar icon**, with a microphone and rising bars matching the app icon;
  a slash across the bars indicates that processing is switched off.
- **Standard macOS menu surface**, with system-managed appearance and dismissal, without a popover arrow.
- **Gain readout** shows the percentage first, followed by decibels, for example `126% (+2.0dB)`.
- **Slim level meters**, matching the gain slider track, refresh about 20 times per second
  with gradual peak decay. Their rounded native slider tracks
  show each new peak directly; the stable **Limiter active** indicator shows
  peak protection. Bar lengths follow linear peak amplitude: 200% gain doubles the output
  length with flat EQ and no limiting. The protected −1 dBFS output reaches about 89.1% of the bar. This visual decay does not delay the audio.
- **Menu bar panel** with gain, meters, routing status, microphones and EQ, plus settings for
  buffer, channels, automatic system input switching and diagnostics, using native grouped
  sections and switches. Buffer sizes are labeled in frames, with guidance on latency and audio stability;
  channel options each explain how the microphone inputs map to the left and right output.
- **Voice preset** for rumble reduction and gentle presence, plus a flat EQ reset.
- **Processing switch** releases the microphone; quitting restores the previous system input
  when MicBoost still manages it.

Planned for v1:

- **Recovery** from a disconnected source, sleep/wake, format changes and a missing BlackHole
  (stage 5).
- **Homebrew tap and `.zip` release** (stage 6).

## Requirements

- macOS 14 Sonoma or later, on Apple Silicon or Intel.
- [BlackHole 2ch](https://existential.audio/blackhole/) installed as a separate driver.
- Microphone permission for MicBoost (and for your terminal when using diagnostics).
- To build from source: Xcode 27.2 / Swift 6.4.

## Install

MicBoost is not released yet. **The only way to run it today is to build from source** — see
[Building from source](#building-from-source).

**Planned, not available:** a Homebrew tap (`vittau/micboost`, cask `micboost`) that depends on
the `blackhole-2ch` cask, and a `.zip` release on GitHub Releases. Neither exists yet; do not
expect those commands to work.

BlackHole 2ch itself is installable now:

```sh
brew install --cask blackhole-2ch
```

## First launch

A build you compile locally is ad-hoc signed and not quarantined, so it opens normally. The
"Open Anyway" flow below applies once a downloadable build exists:

1. Open MicBoost. macOS blocks it because the app is not notarized.
2. Go to System Settings → Privacy & Security, click **Open Anyway** and confirm with your
   password or Touch ID.
3. Later launches show no warning. A new binary may repeat the flow.

On macOS 15 and later, Control-click → Open no longer bypasses the block; use step 2. MicBoost
never disables Gatekeeper or SIP and never removes the quarantine flag, and neither should you.

## Usage

1. Open MicBoost and allow microphone access.
2. Click its menu bar icon and choose your microphone. MicBoost sets the processed input as
   the system input automatically by default; disable this in Audio settings if desired.
3. Adjust gain, mute and EQ in the panel. Close the panel whenever you like; audio keeps running.
4. In your calling or recording app, choose **BlackHole 2ch** or **System Default**.
5. Turn processing off to release the microphone, or choose **Quit MicBoost** from the text menu
   at the bottom of the panel. Standard macOS shortcuts include ⌘, for settings and ⌘Q to quit. The previous
   system input is restored if automatic switching is enabled and you have not changed it yourself.

### Diagnostics

`swift run micboost-diag devices` lists inputs. The CLI also supports capture, latency and
stability measurements; see [the diagnostic reference](docs/testing.md).

## Latency

The number that matters is the **added latency**: from a sample being available at the source to
the same sample being available to a reader of BlackHole 2ch. It is measured by
`micboost-diag latency`, which runs the engine in-process, records the source and the BlackHole
input with host timestamps, correlates the room signal between both recordings and reports the
median of repeated trials. The consumer app's own latency is measured separately and is not part
of this figure.

Recorded on a MacBook Neo (Apple A18 Pro), macOS 27.2, with room-signal correlation and 3 trials
per buffer:

| Buffer | USB mic at 48 kHz | USB webcam mic at 16 kHz |
| --- | --- | --- |
| 64 frames | 7.3 ms | 14.9 ms |
| 128 frames | 10.0 ms | 22.9 ms |
| 256 frames (default) | 15.3 ms | 38.9 ms |

A buffer is a fixed number of frames, so it lasts three times longer at 16 kHz than at 48 kHz;
that is why the low-rate source is slower.

- **v1 acceptance:** median ≤ 100 ms for every supported source, except sources whose own
  reported input latency already exceeds that value — Continuity is one, at 125 ms.
- **Engineering goal:** median < 20 ms at the default buffer for USB and built-in sources at
  48 kHz — met by the USB microphone above. This is the requirement of the v2 monitor mode, where
  the total delay must stay under 20 ms to avoid hearing an echo.
- **Stability:** a 20-minute run at the default buffer stayed within 0.7 ms of its starting
  latency, with no overloads, no missing input, stable memory (about 13 MB) and about 0.5% of one
  CPU core.
- **Recovery:** unplugging the USB microphone during a run moves the engine to "recovering", with
  silence in BlackHole; plugging it back in resumes the bridge on its own.
- **Still pending:** built-in microphone and Bluetooth measurements.

Full results and conditions: [docs/testing.md](docs/testing.md#resultados-registrados).

## Known limitations

- **Bluetooth headsets** use the voice profile (HFP) while their microphone is active: the
  sample rate drops to 16 or 24 kHz, the headset's own output degrades, and latency grows.
  Bluetooth is supported with these limitations.
- **Continuity (iPhone microphone)** reports 6000 frames of input latency — 125 ms at 48 kHz —
  before MicBoost adds anything. The 100 ms acceptance does not apply to a source that already
  exceeds it.
- **The built-in microphone is muted by hardware when the lid is closed.** macOS keeps the
  permission granted and the callbacks keep firing, but they deliver zeros; MicBoost cannot
  capture audio in that state.
- **Digital gain amplifies noise too**, and it cannot recover audio that was already clipped at
  the source.

## Troubleshooting

**The app is blocked by macOS.** That is expected for a non-notarized build — see
[First launch](#first-launch). Do not remove the quarantine flag.

**No microphone audio.** Check System Settings → Privacy & Security → Microphone. When running
the CLI, the permission belongs to the terminal application, not to MicBoost.

**BlackHole 2ch is not found.** Install it with `brew install --cask blackhole-2ch` and run
`swift run micboost-diag devices`; the second line of the output reports the detected BlackHole.
MicBoost does not install or bundle the driver.

**The other app hears silence.** Make sure it is listening to **BlackHole 2ch** or **System
Default**, and that System Settings → Sound → Input is set to BlackHole 2ch. Apps with their own
device picker ignore the system default.

**Captures come back as zeros.** Check the microphone permission first, then whether the source is
a Continuity or Bluetooth device that has not connected yet.

**A feedback loop.** BlackHole cannot be chosen as the source; the list excludes it. If you hear
feedback, the calling app is monitoring its own output.

## Uninstall

MicBoost is not installed anywhere yet. To clean up a local build, quit MicBoost from its panel, then delete the checkout and its
`build/` directory. Settings are removed with:

```sh
defaults delete io.github.vittau.MicBoost
```

BlackHole is never removed by MicBoost, because other apps may depend on it. Remove it yourself
with `brew uninstall --cask blackhole-2ch` if you no longer need it.

## Building from source

```sh
git clone https://github.com/vittau/MicBoost.git
cd MicBoost
swift build
swift test
scripts/build-app.sh debug
open build/MicBoost.app
```

`swift test` runs without audio hardware, BlackHole or microphone permission. `build-app.sh`
assembles and ad-hoc signs `build/MicBoost.app`. The app opens a menu bar panel. The project is a single SwiftPM package — there is
no `.xcodeproj`.

## Support

MicBoost is a spare-time project. If it saves you from buying a microphone booster, you can chip
in:

[![GitHub Sponsors](https://img.shields.io/badge/GitHub-Sponsor-ea4aaa.svg)](https://github.com/sponsors/vittau)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-vittau-ffdd00.svg)](https://www.buymeacoffee.com/vittau)

## License

**Not decided yet.** The repository carries no license grant while the choice is open; GPL-3.0 is
the current recommendation, because it aligns with BlackHole and simplifies a future combined
installer. See the open decisions in [the roadmap](docs/roadmap.md#decisões-em-aberto).

## Credits

- **[BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole)** by Existential Audio — the
  virtual audio driver MicBoost writes to. It is installed separately and used unmodified;
  MicBoost does not bundle it or incorporate its code.
- **[VirtuMic](https://github.com/ShotgunZZ/VirtuMic)** and **LitLink** — products evaluated
  before building MicBoost, whose limitations motivated it. MicBoost is an independent
  implementation and reuses no code or assets from either.
- The section structure of this README was inspired by the VirtuMic README, and its presentation
  by the [Doom-Deck-Launcher](https://github.com/vittau/Doom-Deck-Launcher) README. No text was
  copied from either.
- The icon and the header images are original artwork for this project.

MicBoost is not affiliated with, endorsed by or sponsored by Apple Inc. or Existential Audio.
**Apple**, **macOS** and **Mac** are trademarks of Apple Inc.; **BlackHole** is a product of
Existential Audio. All trademarks belong to their respective owners and are used here only to
describe what MicBoost does.
