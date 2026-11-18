# Contributing to Planarium

Thank you for your interest. Planarium is a musical instrument first: changes are
welcome when they make it more playable without making it harder to use.

## Before you start

- Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the modules and the rules
  every change keeps (defined release of every note, one owner per output, macOS 12).
- For larger changes, open an issue first and describe what should sound or behave
  differently. This avoids work on something that conflicts with a contract in
  [`ROADMAP.md`](ROADMAP.md).
- Comments and internal documents are mostly in German; issues and pull requests in
  English or German are both fine.

## Build and test

Requirements: macOS 12 or later, Swift 5.9 toolchain (Xcode 15 or newer).

```sh
swift build --build-tests
swift test --disable-swift-testing --filter PlanariumControllerCoreTests   # one test target
scripts/suite-summary.sh                                                    # whole suite with a reliable count
scripts/make-app-bundle.sh                                                  # app under .build/bundle/
```

`--disable-swift-testing` is intentional: the suite uses XCTest only. A few tests
check latency budgets (for example `RuntimeLoadTests`, `SelectionTempoTests`) and can
fail under heavy machine load; rerun them alone before reporting.

No scanner or controller is needed: the app plays from the mouse (scanner
audition and the on-screen game controller), and the tests use fakes.

## What a pull request contains

- A focused change with tests. For a new or changed playing rule: a test of the real
  transition (press → sound → release) and, where it matters, a test that fails
  without your change.
- For visible changes: a screenshot in a wide and a narrow window.
- No raw scanner captures, no personal paths, no credentials. Presets go through the
  production codec (`PresetDocumentWriter` or `planarium-preset-tool`), never
  hand-written.
- The whole suite green, or the failing timing tests named with a single rerun.

## Licence

Planarium is licensed under the GNU GPL v3. By contributing you agree that your
contribution is licensed under the same terms. Do not add code or assets whose
licence is incompatible with GPLv3, and name third-party material in
`THIRD-PARTY-NOTICES.md`.

## Not affiliated

Planarium is independent of SICK AG and of the makers of any game controller or
Audio Unit. In this project the scanner is a musical instrument, not a safety device.
