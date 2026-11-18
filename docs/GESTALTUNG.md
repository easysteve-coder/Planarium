# Gestaltung Planarium: „Gebürstetes Studiogerät“

Übernommen am 20.10.2026 auf Owner-Wunsch („bitte übernehmen“) aus
`../FIRSTofFIFTH/Docs/GUI_DESIGN_SYSTEM.md`, Musterfassung 1, Stand FoF
`548159c` / v1.12.14. Dieses Dokument ist Planariums **geltender
Gestaltungsvertrag**. Die FoF-Datei bleibt das Muster mit den Bildnachweisen
(`../FIRSTofFIFTH/Docs/GUI_REFERENCES/`). Die Umsetzung erfolgt modulweise,
siehe Abschnitt 5. Bis dahin gilt die bisherige Optik weiter.

## 1. Richtung

Ein gepflegtes, leicht gealtertes Studiogerät:
- gebürstetes Anthrazitmetall;
- satiniertes Aluminium;
- plastische Kunststofftaster;
- versenkte Glasanzeigen;
- geriffelte Fadergriffe und Drehknöpfe.

Das Licht kommt von links oben, in allen Bausteinen gleich. Die
Arbeitsflächen bleiben ruhig, Akzente sind gezielt gesetzt.

**Vorrang in Planarium:** Messfeld, Zellen, Hand und Einblendungen gehen
immer vor Dekoration. Das Messfeld bekommt keine Bürstung und keine Textur.

## 2. Materialrollen und ihre Zuordnung zu Planarium

| Rolle (FoF-Token) | Material | Planarium-Module |
|---|---|---|
| Gehäuse/Modulrahmen (`darkMetal` 0.20/0.20/0.215 → 0.12/0.12/0.13) | gebürstetes Anthrazit, helle Ober-, dunkle Unterkante | Fensterrahmen, Kopfleiste, Preset-Leiste, Mixer-Hintergrund (`HelmutChrome.gutter`) |
| Parametergruppe (`lightAluminium` 0.79/0.775/0.74 → 0.62/0.605/0.575, Patina) | warmes satiniertes Alu, dunkle Schrift | Kanalzug-Körper (`HelmutChrome.strip`), Inspector-Parametergruppen, Effekt-Editoren (Chord, Arpeggiator) |
| Arbeitsbereich (`gridWell` 0.085/0.085/0.095 → 0.115/0.115/0.125) | ruhige dunkle Einlassung, dezente obere Schattenkante | **Messfeld/Canvas**, Klaviaturen, Schrittanzeige des Arpeggiators |
| Anzeige (`displayGlass` 0.035/0.035/0.04) | dunkles versenktes Glas, keine Reflexion über Ziffern | dB-/Wert-Anzeigen, Tempo, Preset-Name, Kanalname, Audio-Output-Karte |
| Taster (`plasticKey` 0.26/0.26/0.28 → 0.15/0.15/0.165) | gewölbter Kunststoff, gedrückt sichtbar tiefer | Mute/Solo, PANIC, Werkzeugknöpfe, MIDI-FX-/Insert-Plätze |
| Fader/Knopf | geriffelt, klare Kontur, dunkler Mittelindex/Zeiger | `LogicFaderCap`/`LogicVerticalFader` (FoF-Vorbild stammt von hier), `HelmutPanKnob`, Detektionsregler |
| Klaviatur (Planarium-Rolle „Elfenbein“, Owner 20.10.2026) | weiße Tasten warmes, leicht vergilbtes Elfenbein mit feiner Längsmaserung und dezenter Patina; schwarze Tasten Ebenholz-/Kunststoffschwarz mit Glanzlicht oben links; echte Klaviaturgeometrie | Output Monitor, Inspector-Klaviatur, Chord-Editor, Mixer-Minitastatur, OUTPUT-Anzeige |
| Schrift auf Alu (`inkOnLight` 0.07/0.07/0.08, sekundär 0.17/0.17/0.18) | — | Beschriftungen auf Alu-Platten |

Planarium behält seine **Funktions- und Ebenenfarben**: Zellfarben,
Ebenenfarben, Amber (`StageTheme.amber`), PANIC-Rot und Meter-Grün. Übernommen
werden Material und Bedeutung der Rollen. Gleiche Funktion bekommt dieselbe
Farbrolle. Farbige Schrift auf Alu ist nur nach Kontrastprüfung erlaubt,
sonst ein dunkles Namensglas. Fehler, Auswahl und Fokus hängen nie allein an
einer Farbe.

Rollen der Effektplätze: AU-Instrument Violett (`HelmutChrome.purple`),
AU-Insert Blau (`HelmutChrome.blue`), **MIDI FX** Petrol/Türkis
(`HelmutChrome.midiFX`, RGB 0.20/0.62/0.66). MIDI-FX-Beschriftungen sind
dunkel auf Petrol; bei Bypass bleibt Petrol mit 30 % Deckkraft und heller
Beschriftung sichtbar.

## 3. Alterung

Die Alterung bleibt dezent:
- Alu ist leicht wärmer und nachgedunkelt;
- feine Spuren laufen in Bürstungsrichtung;
- Anthrazit hat wenige weiche Mattstellen.

Nicht erlaubt sind ausgebleichte Zahlen, verschmutzte Skalen, Kratzer über
Anzeigen, Risse, Rost und Zufallsflecken. Bei 100 % bleibt jede Beschriftung
sowie jeder LED-, Fokus- und Auswahlkontrast voll erhalten.

Technik:
- deterministische Textur-Kacheln, einmal erzeugt; FoF nutzt 128 × 64 pt
  bei @2x;
- keine Neuberechnung je Render oder Messbild;
- keine Timer und keine modellweite Beobachtung für Dekor.

Planarium-spezifisch: Texturen dürfen kein Messbild-Update invalidieren. Es
gelten die Budgettests `AcceptanceAViewBudgetTests` und die Messung am iMac.

## 4. Bedienelemente und Zustände

Bedienflächen sind mindestens 20 × 20 pt groß. Knopfbeschriftungen haben
mindestens 10 pt und 4,5:1 Textkontrast. Unabhängige Bedienelemente halten
mindestens 4 pt Abstand; native Segmente, die Teile eines Insert-Platzes
und die zusammengehörigen Ebenenpfeile sind ausdrücklich gruppiert.
Überlappungen sind auch innerhalb dieser Gruppen unzulässig.
`LayoutGuardian` in `SickPLSMonitorTests` prüft Hauptansichten bei schmaler
und breiter Breite, Labels an/aus und langen Namen im normalen Testlauf.
Eigene Buttonflächen beziehen Darstellung und Auditwerte aus denselben
Farbrollen (`auditedButtonSurface`); native Kontrollen aus AppKit.


- **Fader:** `LogicFaderCap` 17 × 35 pt mit zwei Riffelzonen und dunkler
  Mittellinie bleibt. Faderweg 200 pt (Owner 20.10.2026). `FaderLaw`,
  Feinmodus, Reset, Undo und Modellübergabe bleiben Planariums Sache. Es
  wird **nur die Optik** angeglichen, keine FoF-Draglogik übernommen.
- **PANIC (Owner 20.10.2026):** Er ist der einzige Taster aus **klarem,
  durchscheinendem Kunststoff**. Er sieht aus wie eine gewölbte Klarkappe,
  unter der ein rotes Feld bzw. eine rote Leuchte sitzt. Ein Glanzlicht oben
  links und eine leichte Lichtbrechung am Rand geben die Tiefe. Gedrückt
  sitzt die Kappe sichtbar tiefer, und das Rot leuchtet kurz auf. Er hebt
  sich klar von allen anderen Tastern ab, ohne zu pulsieren. Die Größe und
  die Trefferfläche bleiben, ebenso der Erstklick bei Plugin- oder
  Monitorfenster vorne. Die Gesperrt-Anzeige je Fläche bleibt lesbar.
- **Drehknöpfe:** dunkler Körper, geriffelter Rand, kontrastreicher Zeiger,
  Skalenbogen. Steht der Wert schon in einer Anzeige daneben, steht er nicht
  noch einmal unter dem Knopf.
- **Zustände:** Jeder Zustand braucht ein eigenes sichtbares Signal:
  normal, gedrückt, aktiv, ausgewählt, Learn-Ziel (Chord-/Fußschalter-Learn),
  Wiedergabe (lokale LED, keine pulsierenden Flächen), Tastaturfokus,
  deaktiviert/gesperrt (Performance-Sperre) und Fehler.
- **Schrift:** monospaced für Werte, ruhige Ziffern. Die Größe richtet sich
  nach der Lesbarkeit am iMac bei 100 %, nicht nach FoF-Größen.
- **Layout:**
  - gemeinsame Fluchten und Höhen gleichartiger Module (Mixer-Schiene);
  - Arbeitsfläche und feste Randbedienung haben getrennte Trefferbereiche;
  - wesentliche Aktionen bleiben bei Mindestbreite sichtbar;
  - keine unsichtbaren oder winzigen Trefferflächen;
  - Piktogramme mit Tooltip (Owner 12.10.).

## 5. Einführung in Planarium

1. **Pilotmodul: Mixer-Kanalzug mit SUM.** Er ist repräsentativ, mit Fader,
   Knopf, Tastern, Anzeigen und Plätzen. Es werden eigene Materialbausteine
   gebaut (gelesen nach FoF `Theme/VintageMaterials.swift`, eigener Code,
   keine Produktabhängigkeit zu FoF). Dazu je ein Bild vorher und nachher
   in breit und schmal mit allen Zuständen. Danach beurteilt der Owner das
   Ergebnis am iMac.
2. Erst nach Owner-OK folgen dieselben Rollen für Inspector, Preset-Leiste,
   Effekt-Editoren und Kopfleiste. Das Messfeld bekommt nur die
   `gridWell`-Einlassung als Rahmen.
3. Vorgaben für jeden Schritt:
   - macOS 12, Intel und Apple Silicon;
   - Leistungsbudgets unverändert;
   - Accessibility, Fokus und Tastatur erhalten;
   - keine Fremd-Assets (Re-Rebirth-Bild nur Anschauung);
   - neue Texturen selbst erzeugen;
   - bei Nutzung freier Vorlagen Acknowledgements (siehe GUI-Vorlagen).

**Nicht übernehmen:** die in FoF offenen Befunde GR-01 bis GR-15, also
Überlappungen, winzige Eck-Griffe und Debug-Overlays.
