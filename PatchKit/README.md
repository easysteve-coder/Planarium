# Planarium Patch Construction Kit (recipe v1 and v2)

A patch is described in a short **recipe** (JSON that reads like a table) plus a
**sound catalog** of audio-unit states that were captured once. The offline tool
turns both into a real V6 preset through the production domain types and codec.
Nobody writes the preset wire format, cell lists, UUIDs, base64 or plug-in IDs by hand.

```sh
swift build --product planarium-preset-tool
TOOL="$(swift build --show-bin-path)/planarium-preset-tool"

$TOOL kit sounds       --catalog demo/sounds.json                       # what sounds exist
$TOOL kit check        --recipe my.recipe.json --catalog demo/sounds.json   # plan table, writes nothing
$TOOL kit build        --recipe my.recipe.json --catalog demo/sounds.json --out "My Patch.sickpreset.json"
$TOOL kit preview      --recipe my.recipe.json --catalog demo/sounds.json --out preview.svg   # picture of the real cells
$TOOL kit import-state --catalog demo/sounds.json --state captured.plist --alias surge.organ1 --role instrument
```

The kit loads no plug-in, plays no audio, opens no MIDI port and starts no app. A passing
`check`/`build` means the **structure** is valid; it says nothing about how the patch sounds.
Audition it in Planarium.

## Recipe v1

```json
{
  "version": 1,
  "name": "Simple Three Bands",
  "summary": "optional text, at most 1000 characters",
  "velocity": 80,
  "channels": [
    { "id": "lead", "instrument": "surge.init", "effects": ["apple.delay.eagle"], "levelDb": -9 }
  ],
  "bands": [
    { "id": "c4", "fromCm": 40, "toCm": 80, "note": "C4", "channel": "lead", "color": "#4CAF50" },
    { "id": "ch", "label": "Cmaj", "fromCm": 80, "toCm": 120, "notes": ["C4", "E4", "G4"], "channel": "lead", "color": "#FF7043", "velocity": 90 }
  ]
}
```

| Field | Meaning |
|---|---|
| `channels[].id` | your handle for the channel (letters, digits, `.` `_` `-`) |
| `channels[].instrument` | sound alias of an **instrument** (`aumu`) from the catalog |
| `channels[].effects` | optional, ordered aliases of **effects** (`aufx`), at most 4; signal order |
| `channels[].levelDb` | optional, default **-9**, range -60…6 |
| `channels[].name` | optional display name (default: the id) |
| `bands[].fromCm`, `toCm` | whole centimetres from the scanner, `fromCm` included, `toCm` excluded, `0 <= from < to <= 200` |
| `bands[].note` / `notes` | exactly one of them: a name (`A3`, `Eb4`, `C#4`; **C4 = 60**) or a MIDI number 0…127; `notes` is a chord list (1–12) |
| `bands[].channel`, `color` | existing channel id, `#RRGGBB` |
| `bands[].velocity`, top-level `velocity` | optional, 1…127, default **80** |
| `mode` | optional; v1 knows only `"gate"` |

**Play mode is gate only:** a band's notes sound while the hand is inside the band and stop when it
leaves. A band is a whole ring band over the **front half circle** (all 361 beams, −90°…+90°);
there is no angle selection in v1. Single notes and chords are both stored as the same chord program.
No CC, program change, arpeggiator, scenes, perform settings, device setup or external MIDI in v1.

Rules the kit enforces (each failure names the field, band or alias):

- unknown or misspelled fields fail instead of being ignored;
- bands on the **same channel** must not overlap (the message names both band IDs); gaps are allowed
  and listed in the plan, never filled in; bands on different channels may overlap and layer;
- a band needs a defined channel, a valid colour and defined notes; IDs and aliases must be unique;
- every referenced alias must exist in the catalog **with a real state file** — a missing sound is an
  error, never a stand-in. (`examples/eagle-blues.recipe.json` therefore fails with
  `sound "surge.organ1" is not in the catalog` until the real organ state is imported.)

Output is deterministic: the same recipe and catalog give byte-identical presets (IDs derive from your
handles, no timestamps, no random UUIDs). `build` validates everything first, writes atomically, keeps an
existing output unless you pass `--force`, and never modifies the recipe, catalog or state files — `--out` may not be the recipe, the catalog file or
any state file the catalog lists (used by the recipe or not, also through symbolic links), even with `--force`.
The output must be a new `*.sickpreset.json` and can never be one of the inputs.

## Recipe v2: shapes on a play area

Version 2 is a **new recipe format, not a new preset format**: the output is still the canonical V6
preset, v1 recipes keep working and produce byte-identical presets. **The recipe is the parametric
original** — shapes, placement, play area and IDs stay in it as numbers. The V6 preset is only the
*execution artefact* (cells + routing) and does not contain the editable shapes; never guess a shape back
from a cell list. The pure geometry/raster code (`PatchGeometry.swift`: `PatchShape`, `PatchTransform`,
`PatchPlacedShape.cells`) is the one place that turns a shape into grid cells; a later editor must reuse it.

```json
{
  "version": 2, "name": "Table 1 m", "velocity": 80, "outsidePolicy": "error",
  "channels": [ { "id": "lead", "instrument": "surge.init" } ],
  "playArea": { "type": "rectangle", "xMinCm": -50, "xMaxCm": 50, "yMinCm": 20, "yMaxCm": 100 },
  "regions": [
    { "id": "low", "shape": { "type": "rectangle", "widthCm": 40, "heightCm": 30 },
      "transform": { "xCm": -25, "yCm": 40, "rotationDegrees": 0, "mirrorX": false },
      "note": "C4", "channel": "lead", "color": "#4CAF50" }
  ]
}
```

**Coordinates (all lengths in centimetres):** the scanner is fixed at (0, 0); +x is right, +y is forward;
the visible half space is `y >= 0`. A bearing is measured from the front: -90° left, 0° front, +90° right
(`x = r·sin`, `y = r·cos`). `playArea` is a *chosen playing section*, not a measured room and not a proven
scanner range; the kit asserts no physical walls. Offline processing is limited to 1000 cm from the scanner
(a processing bound, not a hardware claim).

`playArea` is exactly one of `{"type":"rectangle","xMinCm","xMaxCm","yMinCm","yMaxCm"}` (axis-aligned, `xMin < xMax`,
`0 <= yMin < yMax`) or `{"type":"sector","fromCm","toCm","fromDegrees","toDegrees"}` (`0 <= from < to`, `-90 <= fromDegrees < toDegrees <= 90`).

`shape` is exactly one of (local coordinates, centred on (0, 0) unless stated):

| `type` | fields | note |
|---|---|---|
| `rectangle` | `widthCm`, `heightCm` | lower edges included, upper edges excluded |
| `circle` | `radiusCm` | interior **including** the border |
| `polygon` | `pointsCm: [[x,y],…]` | 3–32 distinct corners, simple closed outline, either winding; do not repeat the first point; border included |
| `sector` | `fromCm`, `toCm`, `fromDegrees`, `toDegrees` | ring sector around the scanner, radius `[from, to)`, bearing `[from, to)`; a `toDegrees` of exactly 90 includes the +90° end tick. Cannot be moved, rotated or mirrored |

`transform` (optional, rectangle/circle/polygon; defaults 0/0/0/false): **mirror** the local x coordinate first, then
**rotate counter-clockwise** (mathematically positive, `rotationDegrees` −360…360) about the local origin, then
**move** by `xCm`, `yCm`. Self-crossing or touching outlines, zero-area polygons, too few points and non-finite or
oversized numbers (±2000 cm) are refused — nothing is repaired or clamped.

**Rasterisation:** cells are the existing polarDeviceV2 cells. A cell is the point at ring `r` (the real distance in
cm, exactly `r`, not `r + 0.5`), tick `0…360`, bearing `-90° + 0.5°·tick`; rings start at 1 for v2 areas. A cell belongs
to a region when its point is inside the shape under the rules above. This is a 1 cm / 0.5° *sampling* of the shape, not a
claim about the continuum. Only trigonometric rounding noise is tolerated (1e-9 cm), never a geometric margin.

**Play area and clipping:** the result is the shape's cells inside the play area (same inclusion rules: rectangle lower
edges in, upper out). `outsidePolicy` (top level) is `"error"` (default: cells outside the area, or a part of a shape behind
the scanner, are refused with counts) or `"clip"` (cut off; the plan shows generated → kept → removed). A region with no
remaining cell — completely outside, behind the scanner, or smaller than the grid — is **always** an error.

**Overlaps** are judged on the finished cell sets, never on bounding boxes: sharing a cell on the same channel is an
error naming both IDs; on different channels it is layering, shown in the plan and in the preview. Budgets: at most
64 regions, 8 channels, one million cell assignments in total and a bounded number of grid points looked at.

`kit preview` writes a static, self-contained SVG of exactly these cells (play area edge, scanner, x/y axes, cm scale
bar, legend with region/note/channel, overlaps). Cells are drawn as merged polar boxes, nothing is left out; a pattern too
fine for 100 000 shapes is refused. The only URL in the file is the SVG namespace declaration. It loads no sound — a valid
picture says nothing about how the patch sounds. Same input protection as `build` (never overwrites the recipe, the catalog
or any catalog state, existing file only with `--force`, atomic).

Examples: `examples/table-1m.recipe.json` (rectangle, circle, triangle inside a 1 m wide table area) and
`examples/mixed-shapes.recipe.json` (turned rectangle, mirrored L polygon, clipped circle and a layered ring sector on a
second channel). Pictures made from the real preview: `.agent_handoff/runs/patch-kit-2/`.

## Sound catalog v1

`sounds.json` lists aliases; each state file lives inside the catalog folder (relative path, no `..`,
no absolute path, no symbolic-link escape).

```json
{ "version": 1, "sounds": [
  { "alias": "apple.delay.eagle", "role": "effect", "state": "states/apple.delay.eagle.plist",
    "description": "Apple AUDelay 25 % / 0.28 s / 20 %" } ] }
```

The plug-in identity (type/subtype/manufacturer) is **read from the state file** and must match the role:
instruments are `aumu`, effects `aufx`. The state must be a non-empty property-list dictionary of at most
8 MiB **and must carry a real sound payload**. v1 supports exactly the two shapes measured from real
captures: a non-empty `data` blob (Apple audio units, e.g. the Eagle delay) or a non-empty
`jucePluginState` blob (JUCE plug-ins, e.g. Surge XT). Identity/name fields alone, an empty blob or a
state with only other parameter layouts is refused by `import-state` and by every build with
`state has no sound payload` — no default sound is substituted. This is a structural check, not a claim that
every plug-in is validated or that the sound was listened to. `kit import-state` adds a state you captured earlier: it copies the file to `states/<alias>.plist`,
registers the alias, and refuses to overwrite an alias or a state file. It captures nothing.

## Examples (`PatchKit/examples/`)

- `simple-three-bands.recipe.json` — one channel, three bands (needs the demo alias `surge.init`).
- `chord-ladder.recipe.json` — same kit, only the recipe changes: four chord bands, delay insert.
- `eagle-blues.recipe.json` — 7 gate bands 40…180 cm (MIDI 57/60/62/63/64/67/69) with `surge.organ1` +
  `apple.delay.eagle`. Needs a real organ state; it must not be replaced by `surge.init`.
- `make-demo-catalog.sh` — builds a demo catalog by *importing* two states that already exist in
  `Tests/PlanariumPresetsTests/Fixtures/EaglePatch/` (the measured Eagle delay state and the Surge default InitSaw state):

```sh
PatchKit/examples/make-demo-catalog.sh "$TOOL" /tmp/demo-catalog \
  Tests/PlanariumPresetsTests/Fixtures/EaglePatch/delay-eagle-state.plist Tests/PlanariumPresetsTests/Fixtures/EaglePatch/surge-default-state.plist
$TOOL kit build --recipe PatchKit/examples/chord-ladder.recipe.json --catalog /tmp/demo-catalog/sounds.json --out /tmp/chord-ladder.sickpreset.json
```

`surge.init` is the unmodified Surge default (InitSaw): a demo sound, never an organ.

## Limits of v1

Gate mode only · v1: whole ring bands only, play area 0…200 cm (v2: shapes, see above) · no automatic scale/chord generator ·
at most 8 channels, 4 effects per channel, 64 bands · no YAML/CSV/Excel import · the older `cells`
subcommand prints legacy `PolarMetricGridCell` pairs, not canonical V6 cells (use `kit`).
