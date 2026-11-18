# Harmonische Presets, Teil 2: neue Presets und Beschreibungen (04.10.2026)

Ergänzt `harmonie-presets-vorschlag.md` (Presets 1–14). Quellen liegen in der
Owner-Ablage `../_Literatur` und sind nicht im Repo:

- **Callipari, Illustrierte Harmonie** (dt. PDF, Juni 2025). Im PDF steht kein
  englischer Titel. Die gedruckte Seitenzahl ist gleich der PDF-Seite.
- **Lizzio, Chord Progression Codex** (2023). Angegeben sind gedruckte Seiten;
  die PDF-Seite liegt 6 weiter.

Beide Bücher wurden vollständig gelesen: Text ganz, Callipari-Grafiken zu allen
zitierten Stellen. Hier stehen nur Akkordfolgen, eigene Formulierungen und
Seitenangaben.

## Gemeinsame Regeln für alle Voicings

- **Tonklassen-Fenster:** Jede Tonklasse liegt im ganzen Preset auf genau
  einer MIDI-Note. Alle Noten passen in ein Fenster von höchstens einer
  Oktave innerhalb 55..76. Dann klingt jeder Akkord in enger Lage (Spanne
  ≤ 12), und jeder gemeinsame Ton bleibt beim Wechsel auf derselben Taste.
  Ein Rechenlauf hat das für jedes Preset gefunden, bei Szenen-Presets über
  alle Szenen hinweg. Sogar alle 24 Dur- und Mollakkorde gehen zugleich mit
  der Belegung B♭3=58 … A4=69.
- Einzige Ausnahme ist Nr. 26 **Line Cliché**. Dort braucht die absteigende
  Oberstimme ein verdoppeltes C (60 und 72) bzw. A (57 und 69). Gemeinsame
  Töne liegen trotzdem überall auf derselben Note.
- **Radien:** innen 0,5–1,0 m, Mitte 1,0–1,5 m, außen 1,5–2,0 m.
- **Winkel:** Sektoren von links (−90°) nach rechts (+90°). Bei „n Sektoren“
  ist das Feld gleichmäßig geteilt.
- **Szenen:** So markierte Presets brauchen Umschaltzellen. Ohne Szenen
  spielt jedes von ihnen sinnvoll seine erste Szene.

## Tabelle A: neue Presets (15)

Nummern 15–29 setzen die vorhandenen 1–14 fort.

| # | Name | Akkorde | Anordnung | Szenen | Voicing (MIDI) | Fundstelle | Warum es trägt |
|---|---|---|---|---|---|---|---|
| 15 | **Proximity Pyramid** | C · Em Cm Am · E G Gm Eb Ab Fm F A Dbm | innen C. Mitte 3 Sektoren: Em, Cm, Am. Außen 9 Sektoren: E, G, Gm, Eb, Ab, Fm, F, A, Dbm | – | C 60 64 67 · Cm 60 63 67 · Em 64 67 71 · Am 57 60 64 · E 64 68 71 · G 67 71 74 · Gm 67 70 74 · Eb 63 67 70 · Ab 60 63 68 · Fm 60 65 68 · F 57 60 65 · A 57 61 64 · Dbm 61 64 68 | Callipari S. 26–27, 35, 39 | Der Abstand vom Zentrum ist genau Calliparis Nähe-Rang: Der Mittelring teilt zwei Töne mit C, der Außenring einen. Außen teilt jeder Nachbar mindestens einen Ton. Weiter weg heißt also hörbar fremder, und jeder Rückweg nach innen ist kurz. |
| 16 | **Third Chain** | statisch: Dm F Am C Em G Bm · Szenen: alle 12 Tonarten | 7 Sektoren über die volle Tiefe, C bei 0°. Mit Szenen: 6 Sektoren je Tonart, Umschaltzellen außen ganz links (eine Quinte abwärts) und ganz rechts (aufwärts) | **Szenen:** je Tonart ein 6er-Fenster der Terzkette, z. B. F: Gm Bb Dm F Am C · C: Dm F Am C Em G · G: Am C Em G Bm D · D: Em G Bm D F#m A · B♭: Cm Eb Gm Bb Dm F. Beim Wechsel rückt das Fenster um zwei Plätze, vier Akkorde bleiben. | Dm 62 65 69 · F 60 65 69 · Am 60 64 69 · C 60 64 67 · Em 59 64 67 · G 59 62 67 · Bm 59 62 66; weitere Akkorde aus derselben Belegung: Gm 58 62 67 · Bb 58 62 65 · D 62 66 69 · F#m 61 66 69 · A 61 64 69 · Cm 60 63 67 · Eb 58 63 67 | Callipari S. 62–65, 123–125; Lizzio S. 198–199, 323 | Die Kette wechselt Dur und Moll immer ab der Terz. Jeder Nachbar teilt zwei Töne, eine Handbewegung ändert also nur eine Stimme. Die Akkorde einer Tonart liegen nebeneinander, das Fenster dreht wie Calliparis Schablone. So wird der Weg durch alle zwölf Tonarten möglich. |
| 17 | **Secondary Dominants** | C · Dm F Am Em G · A7 C7 E7 B7 D7 | innen C. Mitte 5 Sektoren: Dm, F, Am, Em, G. Außen jeweils genau darüber: A7, C7, E7, B7, D7 | – | C 64 67 72 · Dm 62 65 69 · F 65 69 72 · Am 64 69 72 · Em 64 67 71 · G 62 67 71 · A7 61 64 67 69 · C7 64 67 70 72 · E7 62 64 68 71 · B7 63 66 69 71 · D7 62 66 69 72 | Callipari S. 67, 83–86; Lizzio S. 170–178 | Jeder Schritt nach innen ist eine Auflösung V7 → Ziel, also weiter innen mehr Ruhe. Jeder Schritt nach außen baut Spannung auf genau den Akkord darunter auf. Seitwärts bleibt man in C. |
| 18 | **Cadence Spokes** | drei Speichen, je innen → außen: G° C7 Fm Bb7 Eb · D° G7 Cm F7 Bb · A° D7 Gm C7 F | 3 Speichen à 60°, 5 Ringe à 30 cm. Mitte = B♭-Speiche. C7 liegt in zwei Speichen. | – | G° 67 70 73 · C7 60 64 67 70 · Fm 60 65 68 · Bb7 62 65 68 70 · Eb 63 67 70 · D° 62 65 68 · G7 59 62 65 67 · Cm 60 63 67 · F7 57 60 63 65 · Bb 62 65 70 · A° 57 60 63 · D7 57 60 62 66 · Gm 62 67 70 · F 57 60 65 | Callipari S. 69, 73, 97–98; Lizzio S. 95, 199–200 | Nach außen läuft eine Moll-2-5-1, deren Ziel sofort zur 2 der nächsten Dur-2-5-1 wird. Seitwärts liegt in jedem Ring dieselbe Funktion eine Quinte versetzt, also eine Dominantenkette. Radial = Kadenz, quer = Quintenzirkel. |
| 19 | **Augmented Far Star** | C+ · Db F Cm Abm Em A · Ab7 C7 G7 Eb7 B7 E7 | innen C+. Mitte 6 Sektoren: Db, F, Cm, Abm, Em, A. Außen darüber die jeweilige Dominante | – | C+ 60 64 68 · Db 61 65 68 · F 57 60 65 · Cm 60 63 67 · Abm 59 63 68 · Em 59 64 67 · A 57 61 64 · Ab7 60 63 66 68 · C7 58 60 64 67 · G7 59 62 65 67 · Eb7 58 61 63 67 · B7 57 59 63 66 · E7 59 62 64 68 | Callipari S. 114–116; Lizzio S. 49 | Das ist die „zweite Schale“ um C+: Je zwei Töne des übermäßigen Akkords rücken einen Halbton. Nachbarn im Ring teilen je einen Ton, z. B. Db–F über F und Cm–Abm über E♭. Der Außenring bildet Calliparis Dominantenkette. Ergänzt den Hexatonik-Stern (Nr. 7) ohne Dublette. |
| 20 | **Augmented Pull** | C · G+ C+ · Dm G7 F Am | innen C. Mitte: G+ links (−90..0°), C+ rechts. Außen 4 Sektoren: Dm, G7, F, Am | – | C 60 64 67 · G+ 59 63 67 · C+ 60 64 68 · Dm 57 62 65 · G7 59 62 65 67 · F 57 60 65 · Am 57 60 64 | Callipari S. 120–121; Lizzio S. 165–167, 223–224 | Links: Dm → G7 → G+ → C, der übermäßige Akkord zieht die Quinte hinauf in die Terz von C. Rechts: C → C+ → F oder Am, die hochgeschobene Quinte will zur 6. So ist links „Einatmen“ zur Tonika hin und rechts „Ausatmen“ von ihr weg. |
| 21 | **Fifths Loop** | Am Dm G C F B° E | außen (1,25–2,0 m) 4 Sektoren: Am, Dm, G, C. Innen (0,5–1,25 m) 3 Sektoren: E, B°, F | – | Am 57 60 64 · Dm 57 62 65 · G 59 62 67 · C 60 64 67 · F 57 60 65 · B° 59 62 65 · E 56 59 64 | Lizzio S. 195; Callipari S. 68–69 | Die Schleife läuft vollständig im Quintenfall: außen von links nach rechts, rechts nach innen, innen zurück nach links und wieder hinaus zu Am. Jeder Schritt ist eine Quinte abwärts, die Hand zieht eine geschlossene U-förmige Bahn durchs Feld. |
| 22 | **Diminished Staircase** | C C#°7 Dm D#°7 Em · F F#°7 G G#°7 Am | innen (0,5–1,25 m) 5 Sektoren: C, C#°7, Dm, D#°7, Em. Außen 5 Sektoren: Am, G#°7, G, F#°7, F (F liegt über Em) | – | C 60 64 67 · C#°7 58 61 64 67 · Dm 57 62 65 · D#°7 57 60 63 66 · Em 59 64 67 · F 57 60 65 · F#°7 57 60 63 66 · G 59 62 67 · G#°7 59 62 65 68 · Am 57 60 64 | Lizzio S. 209–212 | Zwischen zwei Akkorden im Ganztonabstand steht jeweils ihr Durchgangs-°7. Er löst einen Halbton aufwärts auf. Die Hand läuft eine Schlange: innen hinauf, bei Em/F nach außen, außen zurück bis Am. Am liegt über C. |
| 23 | **Neapolitan** | Am · F Dm · Bb E7 | innen Am. Mitte: F links, Dm rechts. Außen: B♭ links, E7 rechts | – | Am 64 69 72 · F 65 69 72 · Dm 62 65 69 · Bb 58 62 65 · E7 56 59 62 64 | Lizzio S. 118, 287–288, 305–306 | Weg i → ♭VI → ♭II → V7 → i: Am → F → B♭ → E7 → Am. Der neapolitanische B♭ liegt ganz außen, also als größte Spannung, direkt neben E7. Dm → E7 rechts ergibt die phrygische Halbkadenz. |
| 24 | **Rising Sun** | Am · C D G · F Dm E | innen Am. Mitte 3 Sektoren: C, D, G. Außen 3 Sektoren: F, Dm, E | – | Am 64 69 72 · C 64 67 72 · D 62 66 69 · G 59 62 67 · F 65 69 72 · Dm 62 65 69 · E 56 59 64 | Lizzio S. 302–303 | Moll, das sich das helle IV aus Dorisch leiht: In der Mitte liegen die hellen Akkorde mit D-Dur. Außen liegen die dunklen bzw. spannenden Akkorde mit Dm und E. Beide Acht-Akkord-Schleifen des Buchs lassen sich als Nachbarschritte spielen. |
| 25 | **Romanian Night** | Am · Dm Cm · B E7 | innen Am. Mitte: Dm links, Cm rechts. Außen: B links, E7 rechts | – | Am 57 60 64 · Dm 57 62 65 · Cm 60 63 67 · B 59 63 66 · E7 56 59 62 64 | Lizzio S. 396–397 | Die Farbe der rumänischen (dorisch #4) Skala: i–II, i–♭iii und i–iv–II über liegendem A. B und E7 liegen außen nebeneinander (V/V → V). So bleibt der exotische Klang innen, die Auflösung außen. |
| 26 | **Line Cliché** | links: C Cmaj7 C7 F Fm · rechts: Am AmMaj7 Am7 Am6 D | 2 Speichen à 90°, 5 Ringe à 30 cm von innen nach außen | – | C 60 64 67 72 · Cmaj7 60 64 67 71 · C7 60 64 67 70 · F 60 65 69 · Fm 60 65 68 · Am 57 60 64 69 · AmMaj7 57 60 64 68 · Am7 57 60 64 67 · Am6 57 60 64 66 · D 57 62 66 | Lizzio S. 219, 235–236 | Der Akkord bleibt stehen, nur die Oberstimme sinkt je Ring einen Halbton: C–B–B♭–A–A♭ bzw. A–G♯–G–F♯. Nach außen greifen heißt also hörbar „absinken“. C und Am liegen innen nebeneinander. |
| 27 | **Twelve-Bar Blues** | Dur: C7 F7 G7 A7 D7 · Moll: Cm7 Fm7 G7 Ab Gm7 | innen I. Mitte: IV links, V rechts. Außen: Wendepunkt-Akkorde links/rechts, Umschaltzelle außen bei 0° | **Szenen:** „Major Blues“ C7 · F7 · G7 · A7 · D7 / „Minor Blues“ Cm7 · Fm7 · G7 · Ab · Gm7. G7 bleibt auf derselben Zelle. | C7 58 60 64 67 · F7 60 63 65 69 · G7 59 62 65 67 · A7 61 64 67 69 · D7 60 62 66 69 · Cm7 58 60 63 67 · Fm7 60 63 65 68 · Ab 60 63 68 · Gm7 58 62 65 67 | Lizzio S. 256–263 | Die zwölf Takte sind räumlich drei Orte: Mitte, links, rechts. Den Wendepunkt (VI7 → II7 → V7) spielt man außen. Die Moll-Szene tauscht die Farbe, nicht den Weg. |
| 28 | **Picardy Switch** | Day: C Dm F Am Em G7 · Night: Cm D° Fm Ab Eb G7 | innen Tonika. Mitte 4 Sektoren: ii, IV, vi, iii. Außen G7 (−60..60°), Umschaltzellen außen an beiden Rändern | **Szenen:** „Day“ C · Dm · F · Am · Em · G7 / „Night“ Cm · D° · Fm · A♭ · E♭ · G7. Jede Zelle behält ihre Stufe, G7 gilt für beide. | C 60 64 67 · Dm 57 62 65 · F 57 60 65 · Am 57 60 64 · Em 59 64 67 · G7 59 62 65 67 · Cm 60 63 67 · D° 62 65 68 · Fm 60 65 68 · Ab 60 63 68 · Eb 63 67 70 | Lizzio S. 198, 266–267, 278–282; Callipari S. 76, 78 | Der Wechsel in die gleichnamige Tonart ist ein Licht-aus. Weil jede Stufe ihren Ort behält, spielt die Hand denselben Weg in anderer Farbe. G7 ist Dominante von C und Cm; über ihn kann man beim Rückweg die Szene wechseln. |
| 29 | **Mode Wheel** | Tonika C bzw. Cm, 6 Stufen-Plätze | innen Tonika. Mitte+außen 6 Sektoren für die Stufen II–VII. Umschaltzellen außen: rechts heller, links dunkler | **Szenen** (je ein Ton anders als der Nachbar): Lydian C · D · Em · – · G · Am · Bm / Ionian C · Dm · Em · F · G · Am · – / Mixolydian C · Dm · – · F · Gm · Am · B♭ / Dorian Cm · Dm · E♭ · F · Gm · – · B♭ / Aeolian Cm · – · E♭ · Fm · Gm · A♭ · B♭ / Phrygian Cm · D♭ · E♭ · Fm · – · A♭ · B♭m. „–“ = verminderter Akkord, Platz bleibt stumm. | C 60 64 67 · D 57 62 66 · Em 59 64 67 · G 59 62 67 · Am 57 60 64 · Bm 59 62 66 · Dm 57 62 65 · F 57 60 65 · Gm 62 67 70 · Bb 62 65 70 · Cm 60 63 67 · Eb 63 67 70 · Fm 60 65 68 · Ab 60 63 68 · Db 65 68 73 · Bbm 65 70 73 | Lizzio S. 294–323 | Die sechs Modi sind nach Helligkeit sortiert. Jeder Schritt ändert genau einen Skalenton, also meist nur ein oder zwei Plätze. Man dimmt die Tonart, ohne den Grundton zu verlassen. Die Tonika bleibt innen liegen; das ist das Prinzip der Nachbar-Modi. Erweitert den Modus-Schalter (Nr. 6, nur Paare) zur vollständigen Skala. |

Alle 15 sind gegen die Presets 1–14 abgegrenzt:
- Nr. 19 nutzt die zweite Schale um C+, nicht die erste (Nr. 7).
- Nr. 24 nutzt dorisches IV in Moll, nicht das Andalusische (Nr. 5).
- Nr. 28 tauscht die ganze Tonart, statt einzelne Akkorde zu leihen (Nr. 2, 3).
- Nr. 29 nutzt vollständige Skalen statt Paaren (Nr. 6).

Bewusst nicht aufgenommen, weil sie zu nah an Vorhandenem liegen:
- Phrygisch-Dominant E–F–G (gleicher Akkordsatz wie Nr. 5);
- „Royal Road“ F–G–Em–Am (≈ Nr. 14);
- „Key of Rock“ (≈ Nr. 3);
- Mixolydisch ♭6 C–Fm (≈ Nr. 2).

## Tabelle B: Beschreibungen aller Presets (englisch, für die App)

Seitenprüfung der vorhandenen 14:
- **bestätigt:** 3, 5, 6, 8, 9, 13;
- **bestätigt mit ergänzter Zweitquelle:** 7, 10;
- **präzisiert bzw. korrigiert:** 1, 2, 4, 11, 12, 14. Details stehen in der
  Spalte „Prüfung“.

| # | Preset | English description | Prüfung |
|---|---|---|---|
| 1 | Ruhe und Spannung (*Rest and Tension*) | Home chords sit in the middle, the chords that lean away from home sit further out. Walk outward to build tension and come back to C to release it. Source: Callipari, Illustrierte Harmonie, p. 42–44; Lizzio, Chord Progression Codex, p. 62–72 | korrigiert: Callipari S. 67 gehört zu den Zwischendominanten, nicht zu diesem Preset. Die Funktionsgruppen stehen S. 42–44. Codex 63–71 → 62–72, denn die Tonika beginnt S. 62 und vii° steht S. 71–72. |
| 2 | Sehnsucht (*Longing*) | C sits in the middle, and the hand can lean into F and then into the bittersweet F minor over a held C. Going back from F minor to C is the classic tear-jerker ending. Source: Lizzio, Chord Progression Codex, p. 270–271 | präzisiert: 269 → 270. S. 269 behandelt den geliehenen ii°; iv und Fm/C stehen S. 270–271. |
| 3 | Episch (*Epic*) | Around a bright C lie three chords borrowed from C minor: A♭, B♭ and E♭. Each one opens the sound like a film score, and A♭–B♭–C is the triumphant "Mario" ending. Source: Lizzio, Chord Progression Codex, p. 270–275, 282 | bestätigt |
| 4 | Moll-Dreieck (*Minor Triangle*) | A minor, F, G and C play in any order. It is the backbone of countless pop and rock choruses. Linger on C and the mood turns from dark to bright. Source: Lizzio, Chord Progression Codex, p. 84–90 | bestätigt; Kern S. 89–90, Relativität S. 85 |
| 5 | Andalusisch (*Andalusian*) | A minor steps down through G and F to a fiery E major and back. It is the flamenco descent behind many classic rock songs. Source: Lizzio, Chord Progression Codex, p. 93–94, 236 | bestätigt |
| 6 | Modus-Schalter (*Mode Switch*) | Four pairs, each a home chord with one neighbor that colors it in a different mode: Dorian, Phrygian, Lydian, Mixolydian. Rock back and forth inside one pair to hear what that mode feels like. Source: Lizzio, Chord Progression Codex, p. 300–318 | bestätigt |
| 7 | Hexatonik-Stern (*Hexatonic Star*) | An augmented chord in the middle leads by a single half-step move to six major and minor chords around it. Every spoke shares two notes with the center, so even distant keys connect smoothly. Source: Callipari, Illustrierte Harmonie, p. 108–113; Lizzio, Chord Progression Codex, p. 49 | bestätigt; Codex S. 49 ergänzt, dort führt C+ per Halbtonschritt u. a. zu C♯m, Fm, Am |
| 8 | Terz-Ring (*Third Ring*) | Four keys a minor third apart, each as a major/minor pair, form a closed ring. Neighbors are either the same root in major and minor or relative keys, so every step is close. Source: Callipari, Illustrierte Harmonie, p. 78–82 | bestätigt |
| 9 | Götterakkorde (*Divine Chords*) | C is surrounded by major chords a third away: A, E, A♭ and E♭. Each jump keeps one note and sounds like a sudden sci-fi or fantasy reveal. Source: Lizzio, Chord Progression Codex, p. 290–291 | bestätigt |
| 10 | Tritonus-Brücke (*Tritone Bridge*) | The home chords of C sit on one side and those of G♭ on the other. Dominant pairs that share the same tense core link the two sides. Two far-apart keys turn out to be next-door neighbors. Source: Callipari, Illustrierte Harmonie, p. 129–137; Lizzio, Chord Progression Codex, p. 288–289 | bestätigt; Codex S. 288–289 ergänzt (Tritonus-Substitution) |
| 11 | Drehtür (*Revolving Door*) | One diminished seventh chord in the middle can resolve to C, E♭, G♭ or A, because each of its notes can act as the leading tone. Step in, turn, and walk out into a different key. Source: Callipari, Illustrierte Harmonie, p. 90–95; Lizzio, Chord Progression Codex, p. 205–208 | korrigiert: 92–103 → 90–95. Die Symmetrie steht S. 90–91, der Weg C → G♭ S. 92, °7 → Tonika im ganzen Kreis S. 94–95. Ab S. 96 geht es um anderes. Codex S. 205–208 ergänzt (acht Ziele). |
| 12 | Liegender Ton C (*Held Note C*) | Every chord in this set contains the note C, so a melody can hold C while the harmony moves underneath it. Moods range from bright C and F to dark C minor and A♭. Source: Callipari, Illustrierte Harmonie, p. 35–36, 40; Lizzio, Chord Progression Codex, p. 234 | präzisiert: 35–38 → 35–36, 40. S. 37 ist das Tonalsystem, S. 38 die Dominanten; der Weg C → Cm → A♭ steht S. 35 und 40. |
| 13 | Spuk (*Haunted*) | C minor is surrounded by minor chords a third away, plus an A minor ↔ G♯ pendulum. Nothing resolves, which is exactly why film scores use this for ghosts and mysteries. Source: Lizzio, Chord Progression Codex, p. 291–292, 325 | bestätigt |
| 14 | Pop-Netz (*Pop Network*) | The six everyday chords of C major can be combined in any order. Most four-chord pop songs live inside this net. Source: Lizzio, Chord Progression Codex, p. 62–77, 102–105 | korrigiert: S. 294 ist nur die Kurzwiederholung im Modus-Kapitel; die C/Am-Mehrdeutigkeit steht S. 102–105. 63 → 62 (Tonika). |
| 15 | Proximity Pyramid | The closer a chord sits to the center, the more notes it shares with C: two in the middle ring, one on the outside. Reach outward for color and come back in to feel at home. Source: Callipari, Illustrierte Harmonie, p. 26–27, 35, 39 | neu |
| 16 | Third Chain | Major and minor chords alternate, each built on the third of the one before, so neighbors always share two notes. With scenes, the window slides one key at a time and can tour all twelve keys. Source: Callipari, Illustrierte Harmonie, p. 62–65, 123–125; Lizzio, Chord Progression Codex, p. 198–199, 323 | neu |
| 17 | Secondary Dominants | The chords of C major sit in a ring around C, each with its own dominant directly behind it. Reach out to grab tension, fall inward to resolve it onto the chord below. Source: Callipari, Illustrierte Harmonie, p. 67, 83–86; Lizzio, Chord Progression Codex, p. 170–178 | neu |
| 18 | Cadence Spokes | Moving outward along a spoke plays a minor cadence that flows straight into a major one. Moving sideways shifts everything by a fifth. Every path tells a small story that ends somewhere new. Source: Callipari, Illustrierte Harmonie, p. 69, 73, 97–98; Lizzio, Chord Progression Codex, p. 95, 199–200 | neu |
| 19 | Augmented Far Star | Around an augmented chord lie six chords reached by moving two of its notes by a half step, each paired with its dominant further out. It is the wider, more surprising cousin of the Hexatonic Star. Source: Callipari, Illustrierte Harmonie, p. 114–116; Lizzio, Chord Progression Codex, p. 49 | neu |
| 20 | Augmented Pull | On the left an augmented G pulls you home into C; on the right an augmented C pushes you away toward F or A minor. One rising note does all the work. Source: Callipari, Illustrierte Harmonie, p. 120–121; Lizzio, Chord Progression Codex, p. 165–167, 223–224 | neu |
| 21 | Fifths Loop | Seven chords form a closed loop in which every step falls by a fifth, the engine behind many disco and jazz songs. Follow the U-shaped path and you always arrive back at A minor. Source: Lizzio, Chord Progression Codex, p. 195; Callipari, Illustrierte Harmonie, p. 68–69 | neu |
| 22 | Diminished Staircase | Each pair of neighboring chords has a diminished chord in between that slides up into the next step. Snake through the field and the harmony climbs from C to A minor. Source: Lizzio, Chord Progression Codex, p. 209–212 | neu |
| 23 | Neapolitan | A minor leads through F to the dramatic B♭ at the edge, then to E7 and home. It is an old, operatic way to make a minor cadence feel inevitable. Source: Lizzio, Chord Progression Codex, p. 118, 287–288, 305–306 | neu |
| 24 | Rising Sun | A minor borrows a bright D major from the Dorian mode while keeping its dark chords. Bright chords sit in the middle ring, tense ones at the edge. Two famous eight-chord loops fit here step by step. Source: Lizzio, Chord Progression Codex, p. 302–303 | neu |
| 25 | Romanian Night | A minor is colored by B major and C minor, the exotic sound of the Romanian scale. B and E7 at the edge lead firmly back home. Source: Lizzio, Chord Progression Codex, p. 396–397 | neu |
| 26 | Line Cliché | The chord stays put while its top note sinks a half step with every ring outward, in C on one side and in A minor on the other. It is the sound of countless classic ballads. Source: Lizzio, Chord Progression Codex, p. 219, 235–236 | neu |
| 27 | Twelve-Bar Blues | Home in the middle, the IV chord to the left, the V chord to the right, and the turnaround at the edge. A scene switch turns the major blues into a minor blues without changing the path. Source: Lizzio, Chord Progression Codex, p. 256–263 | neu |
| 28 | Picardy Switch | The same map is played in C major by day and in C minor by night. Every chord keeps its place, and G7 leads home in both worlds. Source: Lizzio, Chord Progression Codex, p. 198, 266–267, 278–282; Callipari, Illustrierte Harmonie, p. 76, 78 | neu |
| 29 | Mode Wheel | The keynote stays in the middle while the surrounding chords switch between six modes, from dreamy Lydian to dark Phrygian. Each scene step changes only one note, so the light dims gradually. Source: Lizzio, Chord Progression Codex, p. 294–323 | neu |

## Hinweise zur Umsetzung

- Die Voicings in Tabelle A erzeugt die Rechenregel „ein Tonklassen-Fenster je
  Preset“. Sie lässt sich in `scripts/make-harmony-presets.py` statt
  `voice()` einsetzen; die Einzelnoten oben sind ihr Ergebnis.
- Ohne Szenen gehen sofort: Nr. 15, 16 (statisch), 17–26.
- Nr. 16, 27, 28 und 29 entfalten ihre Wirkung erst mit
  Szenen/Umschaltzellen (HARMONIE-1).
- Für schmale Sektoren (Nr. 15 außen 9 × 20°, Nr. 16 mit 7 Sektoren) gilt die
  Spielfeldtiefe 0,5–2 m. Bei 25 cm Zellgröße sind 20° am Außenrand rund
  60 cm breit, am Innenrand von 1,5 m rund 50 cm.

## Nachtrag 04.10.: Nr. 27 Harmony Codex (Owner: „aus dem Schwesterprojekt“)

Quelle ist das Schwesterprojekt `HarmonyEngine3D`, `HarmonyScene.swift`,
`buildHarmonyCodexLayout`. Dort stehen 24 Akkorde auf einer Kreisbahn
(„The Infinite Staircase“, nach dem Steven-Wilson-Album *The Harmony Codex*,
2023): E Em B Bm F♯ F♯m … A Am, Quintenkreis aufwärts, je Dur und Moll.

Im Planarium:
- 12 Sektoren von links nach rechts E B F♯ C♯ A♭ E♭ B♭ F C G D A;
- innen (0,5–1,25 m) Dur, außen (1,25–2,0 m) die gleichnamige Mollvariante;
- Tonklassen-Fenster B♭3..A4: Jeder Ton liegt im ganzen Preset auf einer
  Taste.

Die Treppe läuft im Zickzack: Dur → Moll nach außen, dann schräg nach innen
zur nächsten Quinte.

Mit Szenen (HARMONIE-1) kann das Ende A/Am wieder an E anschließen. Erst
dann ist die Treppe wirklich „unendlich“.

Beschreibung (englisch, für die App): „The Infinite Staircase from the sister
project HarmonyEngine3D: all 24 major and minor chords along the circle of
fifths. Major inside, its parallel minor outside — zigzag outward and inward
to climb by fifths. Every note stays on one key across all chords. Source:
HarmonyEngine3D ‘Harmony Codex’ layout, after Steven Wilson, The Harmony
Codex (2023).“

Die Szenen-Presets aus Tabelle A werden damit **28 Twelve-Bar Blues,
29 Picardy Switch, 30 Mode Wheel**.
