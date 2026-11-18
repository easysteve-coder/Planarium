#!/usr/bin/env python3
"""Erzeugt die harmonischen Planarium-Presets aus harmonie-presets-vorschlag.md.

Eine Ebene je Akkord. Lage im Polarfeld: Peilung -90..+90 Grad (0 = geradeaus),
Radius in Metern. Die Zellrechnung und der V6-Export laufen ausschließlich
im Swift-Werkzeug gegen die produktive Domäne. Keine Owner-Datei wird geändert.
"""
import argparse, functools, itertools, json, os, re, subprocess, uuid
from pathlib import Path

CELL = 0.25
EDITOR_CELL = 0.05
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("template", nargs="?", type=Path)
parser.add_argument("--tool", type=Path, default=Path(".build/debug/planarium-preset-tool"))
parser.add_argument("--summaries-only", action="store_true", help="Regenerate existing V6 files, changing only summary")
parser.add_argument("--summary-source", type=Path, default=Path(".agent_handoff/harmonie-presets-teil2.md"))
args = parser.parse_args()
OUT = args.output.resolve()
TOOL = str(args.tool.resolve())
owner = (Path.home() / "Library/Application Support/SickPLSMonitor/Presets").resolve()
if OUT == owner or owner in OUT.parents:
    parser.error("Owner presets are read-only; choose a build/output directory")

def tool(command, *values, data=None):
    return subprocess.check_output([TOOL, command, *map(str, values)], input=data)

def recipe_preset(command, data):
    # Contour tolerance is a session default, not a preset wire field.
    # Let the production reader/compiler provide its approved default.
    encoded = json.loads(tool(command, data=data))
    encoded["document"]["editorGrid"] = {"cellSizeMeters": EDITOR_CELL}
    return tool("convert", data=json.dumps(encoded, sort_keys=True).encode())

def add_summaries():
    # Table B alone is the authorized verbatim prose source.  The later
    # Harmony Codex paragraph is deliberately outside this table.
    table = args.summary_source.read_text().split("## Tabelle B:", 1)[1].split("## Hinweise", 1)[0]
    summaries = {}
    for line in table.splitlines():
        columns = [part.strip() for part in line.split("|")]
        if len(columns) >= 5 and columns[1].isdigit():
            number = int(columns[1])
            summaries[number + (1 if number >= 27 else 0)] = columns[3]
    if len(summaries) != 29:
        parser.error("Expected 29 descriptions in table B")
    for path in sorted(OUT.glob("*.sickpreset.json")):
        doc = json.loads(path.read_bytes())
        match = re.match(r"(?:Harmony|Harmonie) (\d+) ", doc["name"])
        summary = summaries.get(int(match[1]), "") if match else ""
        if summary:
            doc["summary"] = summary
        else:
            doc.pop("summary", None)
        path.write_bytes(tool("convert", data=json.dumps(doc, sort_keys=True).encode()))

if args.summaries_only:
    add_summaries()
    raise SystemExit(0)

@functools.lru_cache(maxsize=None)
def geometry(r0, r1, b0, b1):
    return frozenset(tuple(cell) for cell in json.loads(tool("cells", CELL, r0, r1, b0, b1)))

def cells_in(r0, r1, b0, b1):
    return set(geometry(r0, r1, b0, b1))

# --- Akkorde ---------------------------------------------------------------
PC = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5,
      "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10,
      "B": 11, "H": 11}
QUAL = {"": [0, 4, 7], "m": [0, 3, 7], "+": [0, 4, 8], "o": [0, 3, 6],
        "o7": [0, 3, 6, 9], "7": [0, 4, 7, 10], "maj7": [0, 4, 7, 11],
        "m7": [0, 3, 7, 10], "m6": [0, 3, 7, 9]}

def parse(sym):
    """'Fm/C', 'Ab', 'G7', 'Ho7' → (Tonklassen, Basston-Tonklasse oder None)."""
    bass = None
    if "/" in sym:
        sym, b = sym.split("/")
        bass = PC[b]
    root = sym[:2] if len(sym) > 1 and sym[1] in "#b" else sym[:1]
    q = sym[len(root):]
    return [(PC[root] + i) % 12 for i in QUAL[q]], bass

def voice(sym, ref):
    """Enge Lage in 55..76, möglichst nah an der Referenz (gemeinsame Töne bleiben)."""
    pcs, bass = parse(sym)
    best = None
    for octs in itertools.product(range(4, 7), repeat=len(pcs)):
        notes = sorted(12 * o + pc for o, pc in zip(octs, pcs))
        if notes[0] < 55 or notes[-1] > 76 or notes[-1] - notes[0] > 12:
            continue
        cost = sum(min(abs(n - r) for r in ref) for n in notes)
        if best is None or cost < best[0]:
            best = (cost, notes)
    notes = best[1]
    if bass is not None:
        b = 36 + bass
        while b + 12 < notes[0] - 7:
            b += 12
        notes = [b] + notes
    return notes

COLORS = {"ruhe": (0.25, 0.55, 1.0), "spannung": (1.0, 0.35, 0.25),
          "mitte": (1.0, 0.65, 0.1), "bruecke": (0.7, 0.4, 1.0),
          "moll": (0.3, 0.8, 0.6), "farbe": (1.0, 0.85, 0.2)}

def layer(name, sym, ref, cells, role, transition="legato", notes=None):
    r, g, b = COLORS[role]
    lid = str(uuid.uuid5(uuid.NAMESPACE_URL, "planarium:" + name + ":" + sym + ":" + repr(sorted(cells)))).upper()
    return lid, {
        "color": {"alpha": 1, "red": r, "green": g, "blue": b},
        "id": lid, "isActive": True, "isLocked": False, "isSoloed": False,
        "isVisible": True, "name": name, "toggleGuardSeconds": 0.5, "polarCellOverrides": [],
        "polarCells": [{"ring": rg, "angularIndex": ai} for rg, ai in sorted(cells)],
        "routings": [{
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, lid + ":routing")).upper(),
            "program": {"chord": {"notes": notes or voice(sym, ref), "velocity": 100,
                                  "transition": {transition: {}}}},
            "target": {"audioUnitNote": {"channel": 0}},
        }],
    }

def scene_switch_layer(name, cells, action):
    """A control layer is intentionally outside every scene and stays active."""
    lid = str(uuid.uuid5(uuid.NAMESPACE_URL, "planarium:" + name + ":" + repr(sorted(cells)))).upper()
    return lid, {
        "color": {"alpha": 1, "red": 0.7, "green": 0.4, "blue": 1.0},
        "id": lid, "isActive": True, "isLocked": False, "isSoloed": False,
        "isVisible": True, "name": name, "toggleGuardSeconds": 0.5, "polarCellOverrides": [],
        "polarCells": [{"ring": rg, "angularIndex": ai} for rg, ai in sorted(cells)],
        "routings": [{
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, lid + ":routing")).upper(),
            "program": {"constant": {"_0": 1}},
            "target": {"sceneSwitch": {"action": {action: {}}, "dwellSeconds": 0}},
        }],
    }

# --- Anordnungen -----------------------------------------------------------
INNER, MID, OUTER, MAX = 0.5, 1.0, 1.5, 2.0

def sectors(chords, r0, r1, b0=-90, b1=90):
    w = (b1 - b0) / len(chords)
    return [(c, cells_in(r0, r1, b0 + i * w, b0 + (i + 1) * w)) for i, c in enumerate(chords)]

def star(center, ring_chords):
    return [(center, cells_in(INNER, MID, -90, 90))] + sectors(ring_chords, MID, 1.75)

def bands(rows):
    """rows: [(r0, r1, [Akkorde])] — jede Reihe in gleiche Sektoren geteilt."""
    out = []
    for r0, r1, chords in rows:
        out += sectors(chords, r0, r1)
    return out

# (Akkord, Rolle) je Preset; Rolle bestimmt die Farbe.
P = []
P.append(("Harmonie 01 Ruhe und Spannung", "C", bands([
    (INNER, MID, ["Am", "C", "Em"]), (MID, OUTER, ["Dm", "F"]), (OUTER, MAX, ["G7", "Ho"])]),
    {"Am": "ruhe", "C": "ruhe", "Em": "ruhe", "Dm": "mitte", "F": "mitte", "G7": "spannung", "Ho": "spannung"}))
P.append(("Harmonie 02 Sehnsucht", "C", [("C", cells_in(INNER, MID, -90, 90))] + sectors(["F", "Fm/C"], MID, 1.75),
    {"C": "ruhe", "F": "mitte", "Fm/C": "moll"}))
P.append(("Harmonie 03 Episch", "C", star("C", ["Ab", "Bb", "Eb"]),
    {"C": "ruhe", "Ab": "farbe", "Bb": "farbe", "Eb": "farbe"}))
P.append(("Harmonie 04 Moll-Dreieck", "Am", sectors(["C", "F", "Am", "G"], INNER, 1.75),
    {"Am": "ruhe", "F": "moll", "G": "moll", "C": "mitte"}))
P.append(("Harmonie 05 Andalusisch", "Am", sectors(["Am", "G", "F", "E"], INNER, 1.75),
    {"Am": "ruhe", "G": "mitte", "F": "mitte", "E": "spannung"}))
# Modus-Schalter: vier Viertel, je innen Tonika, außen Wechselakkord.
modes = [("Am", "D/A"), ("Am", "Bb/A"), ("C", "D/C"), ("C", "Bb/C")]
mode_layout = []
for i, (a, b) in enumerate(modes):
    b0 = -90 + 45 * i
    mode_layout.append((a, cells_in(INNER, MID + 0.25, b0, b0 + 45)))
    mode_layout.append((b, cells_in(MID + 0.25, MAX, b0, b0 + 45)))
P.append(("Harmonie 06 Modus-Schalter", "Am", mode_layout,
    {"Am": "ruhe", "C": "ruhe", "D/A": "farbe", "Bb/A": "moll", "D/C": "farbe", "Bb/C": "mitte"}))
P.append(("Harmonie 07 Hexatonik-Stern", "C+", star("C+", ["C", "Am", "Fm", "Ab", "E", "C#m"]),
    {"C+": "bruecke", "C": "ruhe", "Am": "moll", "Fm": "moll", "Ab": "ruhe", "E": "ruhe", "C#m": "moll"}))
P.append(("Harmonie 08 Terz-Ring", "C", sectors(["C", "Cm", "Eb", "Ebm", "F#", "F#m", "A", "Am"], INNER, 1.75),
    {"C": "ruhe", "Cm": "moll", "Eb": "ruhe", "Ebm": "moll", "F#": "ruhe", "F#m": "moll", "A": "ruhe", "Am": "moll"}))
P.append(("Harmonie 09 Goetterakkorde", "C", star("C", ["A", "E", "Ab", "Eb"]),
    {"C": "ruhe", "A": "farbe", "E": "farbe", "Ab": "farbe", "Eb": "farbe"}))
# Tritonus-Brücke: links C-Dreieck, rechts Gb-Dreieck, Mitte die Brückenpaare.
tb = []
for (r0, r1, l, ml, mr, r) in [(INNER, MID, "C", "G7", "Db7", "Gb"),
                               (MID, OUTER, "Em", "B7", "F7", "Bbm"),
                               (OUTER, MAX, "Am", "E7", "Bb7", "Ebm")]:
    tb += [(l, cells_in(r0, r1, -90, -30)), (ml, cells_in(r0, r1, -30, 0)),
           (mr, cells_in(r0, r1, 0, 30)), (r, cells_in(r0, r1, 30, 90))]
P.append(("Harmonie 10 Tritonus-Bruecke", "C", tb,
    {"C": "ruhe", "Em": "ruhe", "Am": "ruhe", "Gb": "moll", "Bbm": "moll", "Ebm": "moll",
     "G7": "bruecke", "Db7": "bruecke", "B7": "bruecke", "F7": "bruecke", "E7": "bruecke", "Bb7": "bruecke"}))
P.append(("Harmonie 11 Drehtuer", "C", star("Ho7", ["C", "Eb", "Gb", "A"]),
    {"Ho7": "bruecke", "C": "ruhe", "Eb": "ruhe", "Gb": "ruhe", "A": "ruhe"}))
P.append(("Harmonie 12 Liegender Ton C", "C", sectors(["Am", "F", "Fm", "C", "Cm", "Ab"], INNER, 1.75),
    {"Am": "moll", "F": "mitte", "Fm": "moll", "C": "ruhe", "Cm": "moll", "Ab": "farbe"}))
P.append(("Harmonie 13 Spuk", "Cm", star("Cm", ["Am", "G#", "Em", "Ebm", "Abm"]),
    {"Cm": "moll", "Am": "moll", "G#": "spannung", "Em": "moll", "Ebm": "moll", "Abm": "moll"}))
P.append(("Harmonie 14 Pop-Netz", "C", sectors(["Dm", "F", "C", "G", "Am", "Em"], INNER, 1.75),
    {"Dm": "mitte", "F": "mitte", "C": "ruhe", "G": "spannung", "Am": "moll", "Em": "moll"}))


# --- Teil 2 (harmonie-presets-teil2.md): feste Voicings je Preset ---------
# Eintrag: (Name, [(Akkord, Zellen, Rolle)], {Akkord: MIDI-Noten}).
# Gleiche Akkorde in mehreren Flächen werden zu einer Ebene zusammengeführt.
P2 = []
IN, MI, OU = (0.5, 1.0), (1.0, 1.5), (1.5, 2.0)

def ring_sectors(chords, band, role, b0=-90, b1=90):
    return [(c, cells, role) for c, cells in sectors(chords, band[0], band[1], b0, b1)]

def spokes(columns, bands, roles):
    """columns: Akkordlisten je Speiche (innen→außen), Speichen gleich breit."""
    out, w = [], 180 / len(columns)
    for i, col in enumerate(columns):
        for j, c in enumerate(col):
            out.append((c, cells_in(bands[j][0], bands[j][1], -90 + i * w, -90 + (i + 1) * w), roles[j]))
    return out

def notes(text):
    """'C 60 64 67 · Dm 62 65 69' → {Akkord: [Noten]}"""
    out = {}
    for part in text.split("·"):
        sym, *ns = part.split()
        out[sym] = [int(n) for n in ns]
    return out

FIVE = [(0.5 + 0.25 * k, 0.75 + 0.25 * k) for k in range(5)]
FULL = (0.5, 2.0)

P2.append(("Harmony 15 Proximity Pyramid",
    [("C", cells_in(*IN, -90, 90), "ruhe")] + ring_sectors(["Em", "Cm", "Am"], MI, "mitte")
    + ring_sectors(["E", "G", "Gm", "Eb", "Ab", "Fm", "F", "A", "Dbm"], OU, "spannung"),
    notes("C 60 64 67 · Cm 60 63 67 · Em 64 67 71 · Am 57 60 64 · E 64 68 71 · G 67 71 74 · Gm 67 70 74 · Eb 63 67 70 · Ab 60 63 68 · Fm 60 65 68 · F 57 60 65 · A 57 61 64 · Dbm 61 64 68")))
P2.append(("Harmony 16 Third Chain",
    ring_sectors(["Dm", "F", "Am", "C", "Em", "G", "Bm"], FULL, "ruhe"),
    notes("Dm 62 65 69 · F 60 65 69 · Am 60 64 69 · C 60 64 67 · Em 59 64 67 · G 59 62 67 · Bm 59 62 66")))
P2.append(("Harmony 17 Secondary Dominants",
    [("C", cells_in(*IN, -90, 90), "ruhe")] + ring_sectors(["Dm", "F", "Am", "Em", "G"], MI, "mitte")
    + ring_sectors(["A7", "C7", "E7", "B7", "D7"], OU, "spannung"),
    notes("C 64 67 72 · Dm 62 65 69 · F 65 69 72 · Am 64 69 72 · Em 64 67 71 · G 62 67 71 · A7 61 64 67 69 · C7 64 67 70 72 · E7 62 64 68 71 · B7 63 66 69 71 · D7 62 66 69 72")))
P2.append(("Harmony 18 Cadence Spokes",
    spokes([["Go", "C7", "Fm", "Bb7", "Eb"], ["Do", "G7", "Cm", "F7", "Bb"], ["Ao", "D7", "Gm", "C7", "F"]],
           FIVE, ["moll", "spannung", "moll", "spannung", "ruhe"]),
    notes("Go 67 70 73 · C7 60 64 67 70 · Fm 60 65 68 · Bb7 62 65 68 70 · Eb 63 67 70 · Do 62 65 68 · G7 59 62 65 67 · Cm 60 63 67 · F7 57 60 63 65 · Bb 62 65 70 · Ao 57 60 63 · D7 57 60 62 66 · Gm 62 67 70 · F 57 60 65")))
P2.append(("Harmony 19 Augmented Far Star",
    [("C+", cells_in(*IN, -90, 90), "bruecke")] + ring_sectors(["Db", "F", "Cm", "Abm", "Em", "A"], MI, "ruhe")
    + ring_sectors(["Ab7", "C7", "G7", "Eb7", "B7", "E7"], OU, "spannung"),
    notes("C+ 60 64 68 · Db 61 65 68 · F 57 60 65 · Cm 60 63 67 · Abm 59 63 68 · Em 59 64 67 · A 57 61 64 · Ab7 60 63 66 68 · C7 58 60 64 67 · G7 59 62 65 67 · Eb7 58 61 63 67 · B7 57 59 63 66 · E7 59 62 64 68")))
P2.append(("Harmony 20 Augmented Pull",
    [("C", cells_in(*IN, -90, 90), "ruhe"), ("G+", cells_in(*MI, -90, 0), "bruecke"), ("C+", cells_in(*MI, 0, 90), "bruecke")]
    + ring_sectors(["Dm", "G7", "F", "Am"], OU, "mitte"),
    notes("C 60 64 67 · G+ 59 63 67 · C+ 60 64 68 · Dm 57 62 65 · G7 59 62 65 67 · F 57 60 65 · Am 57 60 64")))
P2.append(("Harmony 21 Fifths Loop",
    ring_sectors(["Am", "Dm", "G", "C"], (1.25, 2.0), "mitte") + ring_sectors(["E", "Bo", "F"], (0.5, 1.25), "spannung"),
    notes("Am 57 60 64 · Dm 57 62 65 · G 59 62 67 · C 60 64 67 · F 57 60 65 · Bo 59 62 65 · E 56 59 64")))
P2.append(("Harmony 22 Diminished Staircase",
    ring_sectors(["C", "C#o7", "Dm", "D#o7", "Em"], (0.5, 1.25), "ruhe")
    + ring_sectors(["Am", "G#o7", "G", "F#o7", "F"], (1.25, 2.0), "mitte"),
    notes("C 60 64 67 · C#o7 58 61 64 67 · Dm 57 62 65 · D#o7 57 60 63 66 · Em 59 64 67 · F 57 60 65 · F#o7 57 60 63 66 · G 59 62 67 · G#o7 59 62 65 68 · Am 57 60 64")))
P2.append(("Harmony 23 Neapolitan",
    [("Am", cells_in(*IN, -90, 90), "ruhe"), ("F", cells_in(*MI, -90, 0), "mitte"), ("Dm", cells_in(*MI, 0, 90), "mitte"),
     ("Bb", cells_in(*OU, -90, 0), "spannung"), ("E7", cells_in(*OU, 0, 90), "spannung")],
    notes("Am 64 69 72 · F 65 69 72 · Dm 62 65 69 · Bb 58 62 65 · E7 56 59 62 64")))
P2.append(("Harmony 24 Rising Sun",
    [("Am", cells_in(*IN, -90, 90), "ruhe")] + ring_sectors(["C", "D", "G"], MI, "farbe") + ring_sectors(["F", "Dm", "E"], OU, "spannung"),
    notes("Am 64 69 72 · C 64 67 72 · D 62 66 69 · G 59 62 67 · F 65 69 72 · Dm 62 65 69 · E 56 59 64")))
P2.append(("Harmony 25 Romanian Night",
    [("Am", cells_in(*IN, -90, 90), "ruhe"), ("Dm", cells_in(*MI, -90, 0), "moll"), ("Cm", cells_in(*MI, 0, 90), "moll"),
     ("B", cells_in(*OU, -90, 0), "spannung"), ("E7", cells_in(*OU, 0, 90), "spannung")],
    notes("Am 57 60 64 · Dm 57 62 65 · Cm 60 63 67 · B 59 63 66 · E7 56 59 62 64")))
P2.append(("Harmony 26 Line Cliche",
    spokes([["C", "Cmaj7", "C7", "F", "Fm"], ["Am", "AmMaj7", "Am7", "Am6", "D"]], FIVE,
           ["ruhe", "farbe", "farbe", "mitte", "moll"]),
    notes("C 60 64 67 72 · Cmaj7 60 64 67 71 · C7 60 64 67 70 · F 60 65 69 · Fm 60 65 68 · Am 57 60 64 69 · AmMaj7 57 60 64 68 · Am7 57 60 64 67 · Am6 57 60 64 66 · D 57 62 66")))


# Harmony Codex (HarmonyEngine3D, buildHarmonyCodexLayout): 24 Akkorde im
# Quintenkreis aufwärts, je Dur dann Moll. Hier 12 Sektoren, innen Dur,
# außen die gleichnamige Mollvariante. Tonklassen-Fenster B♭3..A4 (58..69):
# jede Tonklasse liegt im ganzen Preset auf genau einer Taste.
def window(sym):
    root = sym[:2] if len(sym) > 1 and sym[1] in "#b" else sym[:1]
    q = [0, 3, 7] if sym.endswith("m") else [0, 4, 7]
    return sorted(58 + (PC[root] + i - 10) % 12 for i in q)

CODEX = ["E", "B", "F#", "C#", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A"]
codex_layout = (ring_sectors(CODEX, (0.5, 1.25), "ruhe")
                + ring_sectors([c + "m" for c in CODEX], (1.25, 2.0), "moll"))
P2.append(("Harmony 27 Harmony Codex", codex_layout,
           {sym: window(sym) for sym, _, _ in codex_layout}))

def pretty(sym):
    s = re.sub(r"^([A-G])b", r"\1♭", sym).replace("#", "♯")
    return s.replace("o7", "°7").replace("o", "°") if re.search(r"o7?$", s) else s

template = json.loads(args.template.read_bytes() if args.template else tool("seed"))
if template.get("formatVersion") != 3:
    parser.error("The optional recipe template must be v3; output is always v6")
OUT.mkdir(parents=True, exist_ok=True)

def write(name, layers, ids):
    doc = dict(template)
    doc["name"] = name
    ws = dict(template["spatialWorkspace"])
    ws["grid"] = {"cellSizeMeters": CELL}
    ws["layers"] = layers
    ws["selectedLayerID"] = ids[0]
    doc["spatialWorkspace"] = ws
    path = os.path.join(OUT, name + ".sickpreset.json")
    Path(path).write_bytes(recipe_preset("template", json.dumps(doc, sort_keys=True).encode()))
    print(f"{name}: " + " · ".join(
        f"{l['name']} {l['routings'][0]['program']['chord']['notes']} ({len(l['polarCells'])})" for l in layers))

def write_scenes(name, layouts, scenes, switches):
    """Write scene presets with one layer per chord occurrence.

    Chords shared by scenes intentionally reuse their layer and cells.  Chords
    whose harmony changes at the same position remain separate layers.
    """
    layers, ids, by_symbol = [], [], {}
    for sym, cells, role, voicing in layouts:
        lid, value = layer(pretty(sym), sym, None, cells, role, notes=voicing)
        layers.append(value); ids.append(lid); by_symbol[sym] = lid
    switch_ids = []
    for label, cells, action in switches:
        lid, value = scene_switch_layer(label, cells, action)
        layers.append(value); ids.append(lid); switch_ids.append(lid)
    scene_values = []
    for scene_name, symbols in scenes:
        sid = str(uuid.uuid5(uuid.NAMESPACE_URL, "planarium:" + name + ":scene:" + scene_name)).upper()
        scene_values.append({"id": sid, "name": scene_name,
                             "activeLayerIDs": sorted(by_symbol[sym] for sym in symbols)})
    # Start with the first scene's audible layers; controls stay active.
    active = set(scene_values[0]["activeLayerIDs"]).union(switch_ids)
    for value in layers:
        value["isActive"] = value["id"] in active
    doc = dict(template)
    doc["name"] = name
    ws = dict(template["spatialWorkspace"])
    ws["grid"] = {"cellSizeMeters": CELL}
    ws["layers"] = layers
    ws["selectedLayerID"] = ids[0]
    doc["spatialWorkspace"] = ws
    path = os.path.join(OUT, name + ".sickpreset.json")
    compiled = json.loads(recipe_preset("template", json.dumps(doc, sort_keys=True).encode()))
    compiled["document"]["scenes"] = scene_values
    compiled["document"]["currentSceneID"] = scene_values[0]["id"]
    Path(path).write_bytes(tool("convert", data=json.dumps(compiled, sort_keys=True).encode()))
    print(f"{name}: " + " · ".join(f"{scene['name']} ({len(scene['activeLayerIDs'])})" for scene in scene_values))

for name, anchor, layout, roles in P:
    ref = voice(anchor, [60, 64, 67])
    layers, ids, seen = [], [], set()
    for sym, cells in layout:
        cells = cells - seen
        seen |= cells
        label = sym.replace("Ho7", "H°7").replace("Ho", "H°")
        lid, lay = layer(label, sym, ref, cells, roles[sym])
        layers.append(lay); ids.append(lid)
    write(name, layers, ids)

for name, layout, voicing in P2:
    merged, order, seen = {}, [], set()
    for sym, cells, role in layout:
        cells = cells - seen
        seen |= cells
        if sym not in merged:
            merged[sym] = [set(), role]; order.append(sym)
        merged[sym][0] |= cells
    assert set(order) == set(voicing), (name, set(order) ^ set(voicing))
    layers, ids = [], []
    for sym in order:
        cells, role = merged[sym]
        assert cells, (name, sym, "keine Zelle")
        lid, lay = layer(pretty(sym), sym, None, cells, role, notes=voicing[sym])
        layers.append(lay); ids.append(lid)
    write(name, layers, ids)

# --- Szenen-Presets --------------------------------------------------------
# Harmony Codex already owns number 27 in the factory library; these are the
# three scene entries that follow it.  Their musical table numbers remain
# 27–29 in harmonie-presets-teil2.md.
blues_positions = [
    (cells_in(*IN, -90, 90), "ruhe"),
    (cells_in(*MI, -90, 0), "mitte"),
    (cells_in(*MI, 0, 90), "spannung"),
    (cells_in(*OU, -90, 0) - cells_in(*OU, -10, 10), "spannung"),
    (cells_in(*OU, 0, 90) - cells_in(*OU, -10, 10), "spannung"),
]
write_scenes("Harmony 28 Twelve-Bar Blues", [
    ("C7", blues_positions[0][0], blues_positions[0][1], [58, 60, 64, 67]),
    ("Cm7", blues_positions[0][0], "moll", [58, 60, 63, 67]),
    ("F7", blues_positions[1][0], blues_positions[1][1], [60, 63, 65, 69]),
    ("Fm7", blues_positions[1][0], "moll", [60, 63, 65, 68]),
    ("G7", blues_positions[2][0], blues_positions[2][1], [59, 62, 65, 67]),
    ("A7", blues_positions[3][0], blues_positions[3][1], [61, 64, 67, 69]),
    ("Ab", blues_positions[3][0], "moll", [60, 63, 68]),
    ("D7", blues_positions[4][0], blues_positions[4][1], [60, 62, 66, 69]),
    ("Gm7", blues_positions[4][0], "moll", [58, 62, 65, 67]),
], [("Major Blues", ["C7", "F7", "G7", "A7", "D7"]),
    ("Minor Blues", ["Cm7", "Fm7", "G7", "Ab", "Gm7"])],
   [("Next scene", cells_in(*OU, -10, 10), "next")])

picardy_middle = [cells_in(*MI, -90 + 45 * i, -45 + 45 * i) for i in range(4)]
write_scenes("Harmony 29 Picardy Switch", [
    ("C", cells_in(*IN, -90, 90), "ruhe", [60, 64, 67]),
    ("Cm", cells_in(*IN, -90, 90), "moll", [60, 63, 67]),
    ("Dm", picardy_middle[0], "mitte", [57, 62, 65]),
    ("Do", picardy_middle[0], "moll", [62, 65, 68]),
    ("F", picardy_middle[1], "mitte", [57, 60, 65]),
    ("Fm", picardy_middle[1], "moll", [60, 65, 68]),
    ("Am", picardy_middle[2], "moll", [57, 60, 64]),
    ("Ab", picardy_middle[2], "moll", [60, 63, 68]),
    ("Em", picardy_middle[3], "moll", [59, 64, 67]),
    ("Eb", picardy_middle[3], "moll", [63, 67, 70]),
    ("G7", cells_in(*OU, -60, 60), "spannung", [59, 62, 65, 67]),
], [("Day", ["C", "Dm", "F", "Am", "Em", "G7"]),
    ("Night", ["Cm", "Do", "Fm", "Ab", "Eb", "G7"])],
   [("Previous scene", cells_in(*OU, -90, -60), "previous"),
    ("Next scene", cells_in(*OU, 60, 90), "next")])

mode_switches = cells_in(*OU, -90, -60).union(cells_in(*OU, 60, 90))
mode_slots = [cells_in(*MI, -90 + 30 * i, -60 + 30 * i).union(cells_in(*OU, -90 + 30 * i, -60 + 30 * i) - mode_switches) for i in range(6)]
write_scenes("Harmony 30 Mode Wheel", [
    ("C", cells_in(*IN, -90, 90), "ruhe", [60, 64, 67]),
    ("Cm", cells_in(*IN, -90, 90), "moll", [60, 63, 67]),
    ("D", mode_slots[0], "farbe", [57, 62, 66]),
    ("Db", mode_slots[0], "moll", [65, 68, 73]),
    ("Dm", mode_slots[0], "mitte", [57, 62, 65]),
    ("Em", mode_slots[1], "ruhe", [59, 64, 67]),
    ("Eb", mode_slots[1], "moll", [63, 67, 70]),
    ("F", mode_slots[2], "mitte", [57, 60, 65]),
    ("Fm", mode_slots[2], "moll", [60, 65, 68]),
    ("G", mode_slots[3], "ruhe", [59, 62, 67]),
    ("Gm", mode_slots[3], "moll", [62, 67, 70]),
    ("Am", mode_slots[4], "moll", [57, 60, 64]),
    ("Ab", mode_slots[4], "moll", [60, 63, 68]),
    ("Bm", mode_slots[5], "moll", [59, 62, 66]),
    ("Bb", mode_slots[5], "moll", [62, 65, 70]),
    ("Bbm", mode_slots[5], "moll", [65, 70, 73]),
], [("Lydian", ["C", "D", "Em", "G", "Am", "Bm"]),
    ("Ionian", ["C", "Dm", "Em", "F", "G", "Am"]),
    ("Mixolydian", ["C", "Dm", "F", "Gm", "Am", "Bb"]),
    ("Dorian", ["Cm", "Dm", "Eb", "F", "Gm", "Bb"]),
    ("Aeolian", ["Cm", "Eb", "Fm", "Gm", "Ab", "Bb"]),
    ("Phrygian", ["Cm", "Db", "Eb", "Fm", "Ab", "Bbm"])],
   [("Darker", cells_in(*OU, -90, -60), "next"),
    ("Brighter", cells_in(*OU, 60, 90), "previous")])

# Starter factory values use the identical compiler/importer, no second geometry.
blank = dict(template)
blank["name"] = "Factory 00 Blank Channel"
(OUT / (blank["name"] + ".sickpreset.json")).write_bytes(recipe_preset("convert", json.dumps(blank).encode()))
mid = dict(template)
mid["name"] = "Factory 01 MIDI Scale"
ws = dict(template["spatialWorkspace"])
mid_layers, ids = [], []
for i, (sym, cells) in enumerate(sectors(["C", "D", "E", "F", "G", "A", "B"], 0.5, 2)):
    lid, value = layer(sym, sym, None, cells, "ruhe", notes=[60 + [0, 2, 4, 5, 7, 9, 11][i]])
    value["routings"][0]["target"] = {"midiNote": {"channel": 0}}
    mid_layers.append(value); ids.append(lid)
ws["layers"] = mid_layers; ws["selectedLayerID"] = ids[0]; ws["grid"] = {"cellSizeMeters": CELL}
mid["spatialWorkspace"] = ws
v6 = json.loads(recipe_preset("convert", json.dumps(mid).encode()))
v6["document"]["channels"][0].pop("instrument", None)
v6["document"]["channels"][0]["midiTarget"] = {"uniqueID": 0}
(OUT / (mid["name"] + ".sickpreset.json")).write_bytes(tool("convert", data=json.dumps(v6, sort_keys=True).encode()))
add_summaries()
