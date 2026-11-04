# MicBoost X.Y.Z

MicBoost captures the microphone you choose, applies a 3-band EQ, gain and peak protection, and
delivers the result to BlackHole 2ch, which stays as the system input. This build is **ad-hoc
signed and not notarized**; it carries no Developer ID certificate.

## Requirements

- macOS 14 Sonoma or later, on Apple Silicon or Intel.
- [BlackHole 2ch](https://existential.audio/blackhole/), installed separately:
  - `brew install --cask blackhole-2ch`, or
  - the upstream installer from the BlackHole project.

## Install from the release

1. Download `MicBoost-X.Y.Z.zip` and check it against the published checksum:

   ```sh
   shasum -a 256 -c MicBoost-X.Y.Z.zip.sha256
   ```

2. Unzip the archive and move `MicBoost.app` to `/Applications`.

## First launch

MicBoost is not notarized, so macOS blocks the first launch:

1. Open MicBoost. macOS reports that it cannot verify the app.
2. Open System Settings → Privacy & Security, click **Open Anyway** and confirm with your password
   or Touch ID.
3. Allow microphone access when macOS asks.

Later launches show no warning. A new binary may repeat the flow. On macOS 15 and later,
Control-click → Open no longer bypasses the block; use step 2. MicBoost never disables Gatekeeper
or SIP and never removes the quarantine flag, and neither should you.

## Install with Homebrew

```sh
brew tap vittau/micboost
brew install --cask micboost
```

The cask installs BlackHole 2ch as a dependency, so it may ask for an administrator password and
may need `coreaudiod` restarted. `brew uninstall --cask micboost` removes the app and keeps
BlackHole, because other apps may use it.

## Changes

- <user-facing change>

## License

MicBoost is free software under the [GNU General Public License v3.0](https://github.com/vittau/MicBoost/blob/main/LICENSE).
The archive contains only the app; the license text lives in the repository, and the source for
this version is the tag `vX.Y.Z`.

## Checksums

```text
SHA256  MicBoost-X.Y.Z.zip
```
