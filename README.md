# Planarium

A spatial musical instrument for macOS. Planarium turns a discontinued SICK PLS
laser scanner into a playing surface: you paint cells and surfaces into the
scan field, move your hand through the room, and Planarium plays notes, chords,
arpeggios and controller sweeps on hosted Audio Unit instruments or on external
MIDI gear.

*Deutsch: Ein räumliches Instrument für macOS. Planarium macht einen
abgekündigten SICK-PLS-Laserscanner zur Spielfläche: Zellen und Flächen ins
Messfeld malen, die Hand durch den Raum bewegen, und Planarium spielt Töne,
Akkorde, Arpeggios und Reglerverläufe auf Audio-Unit-Instrumenten oder externen
MIDI-Geräten. Bedienungsanleitung: [`docs/Anleitung.md`](docs/Anleitung.md).*

## Features

- **Spatial cells and surfaces.** The field uses the scanner's own polar grid
  (1 cm × 0.5°). Rectangles, circles, polygons and ring sectors carry a control
  axis and a musical gradient (scale, chord ladder, CC sweep).
- **Musical assignments:** single notes, chords, scales, random scales,
  program changes and continuous controllers, with hold, toggle and
  hold-until-next transitions.
- **Scenes** switched by dwelling in a control cell.
- **Channel strips** with hosted Audio Unit instruments and effects, a mixer,
  meters, an arpeggiator and a chord effect, or routing to CoreMIDI outputs.
- **MIDI clock** as master or follower.
- **Presets** in a versioned JSON format, plus an offline *Patch Construction
  Kit* (`planarium-preset-tool`, see [`PatchKit/README.md`](PatchKit/README.md)).
- **Simulation:** without a scanner, the field plays from the mouse (audition)
  or from the companion iPhone app in [`iOS/PlanariumSim`](iOS/PlanariumSim).
- **Defined release paths:** every loss, stop, preset change and quit releases
  sounding notes; PANIC releases everything.

In development: game controllers (PS5 DualSense first) as a second playing
source next to the scanner, with their own assignments and a simulated
controller in the view.

## Requirements

- macOS 12 or later (Apple silicon or Intel), Swift 5.9 toolchain (Xcode 15+).
- For live playing: a SICK PLS101-316 on a USB–RS-232/422 adapter. Everything
  else works with the built-in simulation.

## Building

```sh
swift build                                   # libraries and tools
scripts/make-app-bundle.sh                    # app bundle under .build/bundle/SickPLSMonitor.app
scripts/make-app-bundle.sh release --universal  # arm64 + x86_64
swift test --disable-swift-testing            # test suite (XCTest)
```

`scripts/suite-summary.sh` runs the whole suite with a reliable pass/fail/crash
count.

## Project layout

| Area | Modules |
|---|---|
| Scanner protocol and transport | `SickPLSCore`, `SickPLSMacTransport`, `SickPLSCommissioning`, `SickPLSActiveControl`, `PLSDeviceValues` |
| Instrument model and playing rules | `PlanariumDomain`, `PlanariumRuntime`, `PlanariumPresets` |
| Sound | `PlanariumAudio` (Audio Unit host), `PlanariumMIDI` (CoreMIDI, clock) |
| App | `SickPLSMonitor` (SwiftUI/AppKit), `SickPLSMonitorKit` |
| Simulation | `SickPLSSimulation*`, `iOS/PlanariumSim` |

Design contracts, risks and evidence: [`ROADMAP.md`](ROADMAP.md). Changes:
[`CHANGELOG.md`](CHANGELOG.md). Comments and docs are mostly in German.

## Notes

Planarium is an independent project and is not affiliated with, endorsed by or
supported by SICK AG. "SICK" and "PLS" are used only to name the compatible
hardware. In this project the scanner is a musical instrument, not a safety
device; nothing here makes any statement about safety functions.

## License

GNU General Public License v3.0, see [`LICENSE`](LICENSE). Third-party notices:
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
