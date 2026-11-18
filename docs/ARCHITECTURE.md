# Planarium architecture

This is an overview for contributors. Binding contracts (release paths, ownership,
timing budgets, evidence) live in [`ROADMAP.md`](../ROADMAP.md); this page explains
where things are and how they connect.

## Three areas

```
 INPUT                        MUSICAL ENGINE                         OUTPUT
 ─────                        ──────────────                         ──────
 SICK PLS scanner ─┐
  SickPLSCore        │ profiles  PlanariumDomain                      PlanariumSoundCore
  SickPLSMacTransport├────────►  (cells, layers, scenes, PlayEngine)  (OutputRouter, ownership,
  PlanariumInput    ─┘                │                               planning, port adapters)
                                      │  MusicEvent                         │            │
 Game controller ──┐                  ▼                                     ▼            ▼
  PlanariumController├─reports─► PlanariumRuntime  ──── MusicEvent ───►  PlanariumAudio  PlanariumMIDI
  Input (GameController)│       (one serial queue "Q":                  (AU host,       (CoreMIDI,
                       │         both sources, panic,                   mixer, inserts)  clock)
 On-screen simulation ─┘         release paths, arpeggiator)
                                      ▲
                       PlanariumControllerCore
                       (ControllerEngine, layout,
                        assistants)
                                      ▲
                       PlanariumMusicCore (Foundation only: MusicEvent, routing targets,
                       value programs, scales, ownership keys)
```

- **PlanariumMusicCore** is the shared musical vocabulary, including the generic
  `NoteLedger`. It imports only Foundation.
- **PlanariumSoundCore** turns `MusicEvent`s into port commands: one router, note
  planning and port adapters, exclusive ownership per output target and class
  (notes vs. controls). Each source keeps its own ledger (the scanner's play state,
  the `ControllerEngine`).
- **PlanariumControllerCore** interprets game-controller state (buttons, triggers,
  sticks, touchpad) with assignments into `MusicEvent`s. It knows nothing about the
  scanner and nothing about Audio Units.
- **PlanariumDomain** is the spatial instrument: polar cells (1 cm × 0.5°), layers,
  surfaces, scenes, detection. It still depends on the scanner's geometry
  (`SickPLSCore`, `PLSDeviceValues`); that is intended — it is the scanner's
  musical model.
- **PlanariumRuntime** runs everything on one serial queue: scanner profiles,
  controller reports, simulation, panic, sleep, port changes. Both sources are
  reconciled against one router, so a note has exactly one owner.
- **PlanariumAudio** hosts Audio Unit instruments and effects in process (8 channel
  strips); **PlanariumMIDI** sends to CoreMIDI and sends or follows MIDI clock.
- **PlanariumApplication** composes the parts for the app; **SickPLSMonitor** is the
  SwiftUI/AppKit app.

Module edges are enforced by tests: `TargetBoundaryTests` checks every production
target against an allow-list (`ManifestBoundaries`), and import rules forbid, for
example, Audio Unit code in the musical core.

## Rules that every change keeps

- **Nothing sounds without a defined end.** Every loss, stop, preset change, sleep,
  quit and PANIC releases what the affected source plays. Gate and Note-Off never
  come from a prediction.
- **One owner per output.** A source claims an output (Audio Unit strip or MIDI
  endpoint/channel) per class; a conflicting assignment stays silent and is shown.
- **Source-local release.** Losing the game controller ends its notes, never the
  scanner's, and vice versa.
- **macOS 12** is the minimum; no required newer API.
- **The scanner path is receive-only.** Device configuration uses a separate,
  typed boundary.

## Where to start

| You want to … | Look at |
|---|---|
| change how a controller element plays | `Sources/PlanariumControllerCore/ControllerEngine.swift`, tests in `Tests/PlanariumControllerCoreTests` |
| add a ready-made controller setup | `ControllerAssistant.swift` (drums, melody, chords) |
| change how notes reach instruments | `Sources/PlanariumSoundCore/OutputRouter.swift` |
| see both sources together | `Sources/PlanariumRuntime/PerformanceRuntime.swift`, `Tests/PlanariumRuntimeTests/ControllerSourceRuntimeTests.swift` |
| build presets offline | [`PatchKit/README.md`](../PatchKit/README.md) |
| change the controller view | `Sources/SickPLSMonitor/ControllerStageView.swift`, `ControllerAssignmentInspector.swift` |

A general input-source interface (so that new devices plug in without touching the
runtime) is planned once a third kind of input is added; today the runtime knows
the scanner and the game controller by name.
