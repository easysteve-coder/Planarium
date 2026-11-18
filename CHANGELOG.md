# Changelog

## Unreleased

**LIVE-NATIV (17.11.) · Messbild, aktive Zellen und Pegel ohne Fenster-Neuaufbau**

- Messbild, aktive/gehaltene Zellen und Pegelbalken zeichnen in eigenen nativen
  Ebenen. Profile und Pegeltakte legen das Fenster nicht mehr neu aus.
- Das Messbild wird als Vektorformen an Core Animation übergeben statt als feldgroße
  Bitmap gerastert; die Kosten wachsen nicht mehr mit der Bildschirmauflösung.
- Prüfstand (Release, M1): Hauptthread 19–21 % → 7–10 %, Wurzel-Layouts 150 → 1.
- Die Flaggenlegende aktualisiert sich nur bei geänderten Zählungen.

- Flächeneditor-Nacharbeit (UI-1, nach Supervisor- und Fable-Review): Anfasser springen beim
  Greifen nicht mehr (Griffversatz wird über die Geste geführt, auch Sektor- und Randgriffe);
  Inspector-Stepper sind eine Undo-Serie; ein Polygonentwurf endet mit jedem Dokumentwechsel;
  Zeichnung zeigt den gewählten Verlauf der Zuordnung; ein inverser CC-Bereich bleibt bei Endwert-,
  Kurven-, Kanal- und Ausgabeänderung erhalten; ⌘X legt die Fläche vollständig auf die
  Zwischenablage (Legacy-Flächen werden abgewiesen); Pfeilentwurf beim Ziehen, kein Flächenoverlay
  im Zellmodus, B/E im Flächenmodus abgewiesen, Zielebene bei Mehrebenenwahl eindeutig.
- Flächeneditor-Oberfläche (FLÄCHENEDITOR-UI-1): Die Benutzereinheit ist die Fläche.
  Werkzeuge Auswahl, Rechteck, Kreis, Polygon (Enter/Doppelklick schließt, Esc verwirft,
  ⌫ nimmt die letzte Ecke zurück), Ringsektor, Hand, Audition; Auswahl nach wirklicher
  Form, ⇧-Mehrfachwahl, Auswahlbox, Anfasser (16 pt, am Canvasrand gehalten) zum
  Skalieren/Drehen/Eckenziehen, Pfeilspitze dreht die Achse, Pfeiltasten schieben als eine
  Undo-Serie. Mehrere Flächen je Ebene; eine Ebene mit Altzellen wird beim ersten Zeichnen
  in demselben Undo-Schritt zur exakten Fläche. Pointer-Drag ist ein Entwurf (analytische
  Vorschau aus `SurfaceEditor.placement`), genau ein validierter Commit beim Loslassen.
  Inspector: Name/Farbe, Maße in cm, Note/Akkord/Tonleiter/CC über `SpatialAssignmentDraft`,
  mehrere Zuordnungen, Pfeil (Peilung, Umkehren), CC-Wertebereich, Verlaufsfarben,
  „Gewählter Spielbereich“ mit Refuse/Clip; Altflächen mit deaktivierten Griffen und
  ausdrücklichem Ersetzen mit Verlustanzeige. CC-Verlauf und Tonleiterstufen (mit
  Notennamen) kommen aus `SurfaceValueField`, keine zweite Formel. Das alte Zelleneditor
  bleibt als „Cell editor (advanced)“ erhalten. B5: alle Hände einer Ebene leuchten
  (`activeCellSets`); B6: Tonhöhenbefehle wirken auf gewählte Flächen, Zellauswahl auf
  Flächenebenen wird abgewiesen statt still ignoriert; Mixer- und Flächengesten teilen
  keine Undo-Grenze mehr.
- Flächenkern (FLÄCHENEDITOR-KERN-1, ohne GUI): Ebenen können mehrere Flächen
  (`SpatialSurface`: Form + Platzierung oder exakte Altmaske, eigene Zuordnungen,
  Achse, Farben) tragen; Zellen werden daraus abgeleitet. Jede Fläche läuft als eigene
  Produktionspartition (eigene Hysterese/Panic-Einheit, eigener Wertebereich);
  `releaseLayer` meint weiter die ganze Ebene. Presets: Format V7 nur bei Flächen
  (sonst bytegleich V6), mit Rasterversion/Zellzahl/Prüfsumme; V6-Schreiber verweigert
  Flächen. Geometrie des Kits liegt jetzt in PlanariumDomain (Kit-Ausgaben bytegleich).
  Reine `SurfaceEditor`-Transaktionen, `SurfaceValueField`-Vorschau.
  Nacharbeit nach Supervisorreview: Pfeil/Anteil/Legende folgen bei umgekehrtem CC-Bereich
  und absteigender Tonleiter dem wirklichen Wertverlauf; eine kopierte Ebene gibt sich
  selbst frei (fremde Ziele bleiben); absurde Maskenversätze werden abgelehnt statt zu
  trappen; das 64-Flächen-Limit gilt je Ebene (Partitionen/Zellen/Zuordnungen weiter
  dokumentweit); Undo-Serien nur ausdrücklich (`beginSurfaceEditSeries` /
  `endSurfaceEditSeries` / `cancelSurfaceEditSeries`, auf der vorhandenen Gesten-ID).
- Patch Construction Kit v2: Rezeptversion 2 beschreibt Flächen statt Ringbänder
  (Rechteck, Kreis, Polygon, Ringsektor; Verschieben/Drehen gegen den Uhrzeigersinn/
  Spiegeln) auf einer einstellbaren Spielfläche (Rechteck oder Sektor) in
  Zentimetern, Scanner bei (0, 0). Das Rezept bleibt das parametrische Original;
  das V6-Preset ist weiterhin nur das Ausführungsartefakt (Zellen). Zellen
  entstehen über eine gemeinsame reine Geometrie-/Rastergrenze auf dem
  polarDeviceV2-Gitter; `outsidePolicy` error/clip meldet Zellzahlen, leere
  Ergebnisse sind immer Fehler, Überlappungen werden an fertigen Zellmengen
  geprüft. Neu: `kit preview` (statische SVG der wirklichen Zellen). v1-Rezepte
  und ihre Presets bleiben bytegleich.
- Patch Construction Kit (`planarium-preset-tool kit …`, Einstieg `PatchKit/README.md`):
  Ein kurzes Rezept (Notenbänder in Zentimetern, Notennamen, Kanäle mit
  Klangaliases) plus Klangkatalog erzeugt über die vorhandenen Domain- und
  V6-Codec-Wege ein Preset – ohne Wireformat-, UUID- oder Base64-Handarbeit.
  v1: nur Gate, ganze Ringbänder im vorderen Halbkreis, 0–200 cm. Fehlende,
  leere oder rollenwidrige Klangzustände scheitern sichtbar; es gibt keinen
  Ersatzklang. Katalogeinträge entstehen nur durch `import-state` vorhandener
  Zustände. Das alte `cells` bleibt unverändert und ist als Legacy beschriftet.
- Anfasser der Mehrfachauswahl auf dem feinen Raster sind sicher greifbar: Die
  Griffgröße folgt der ganzen Auswahl statt einer 5-cm-Zelle, die Trefferfläche
  umfasst das sichtbare Quadrat plus Toleranz, und am Canvasrand bleiben die
  Griffe im sichtbaren Bild. Ein Doppelklick auf einen Anfasser startet das
  Vergrößern, statt die Auswahl zu ersetzen.
- Perform blendet szenenstumme Ebenen einschließlich ihrer Feldanzeigen aus.
  „Show inactive scene layers“ steuert die Editieransicht; Szenenwechsel
  behalten die vorbereiteten Feldpfade. Flächenbeschriftungen verwenden die
  sichtbaren Ebenen und passen ihre Schrift bis zur Mindestgröße an.
- Kanalzüge zeigen als Ausgang „Master“. Ihr erster Klick öffnet die globale
  Gerätekarte auch bei gestopptem Audio; die Gerätewahl steht ebenfalls an SUM.
- „Audition“ (P) spielt im Editieren mit einer virtuellen Hand über denselben
  Q-/Ledger-/Ausgabeweg wie gemessene Hände. Loslassen und die Lebenszyklus-
  Abbrüche entfernen die Hand; Halten und Toggle folgen ihren bestehenden Regeln.

- Wiederhergestellte Presets tragen bis zum erfolgreichen Speichern oder Neuladen
  eine orange Markierung „(recovered)“ mit Symbol und Hinweis zum unveränderten Werkspreset.
- Ein Layout-Wächter prüft die Hauptansichten auf Überlauf, Überlappungen,
  Abstände, Trefferflächen und Knopfbeschriftungen. Apply/Discard,
  Einstellungsnavigation und kleine Bedienelemente sind entsprechend angepasst.

- MIDI-FX-Plätze zeigen Petrol mit gedimmtem Bypass; Instrument und AU-Insert
  unterscheiden sich durch Violett und Blau.

- Auswahlwerkzeug: app-weiter Schalter für Zell- oder Flächenklick; im Flächenmodus
  wählt der Doppelklick eine Zelle. Inspector-Knöpfe bleiben bei schmaler Breite
  sichtbar; Ebenenpfeile stehen zusammen. Transpose nutzt Zahlenfeld und Apply.
- Alle Klaviaturen nutzen dieselbe echte Tastenanordnung mit warmem Elfenbein.
  Der Output Monitor zeichnet seine 128 Tasten auf einer Fläche. Detection,
  Diagnose-/Preset-Aufklappzeilen und Kanal-Auswahl nutzen volle Klickflächen.
- Jede Ebenenzeile zeigt einen Farbstreifen und den Palettenpunkt. Die Palette
  bietet 24 Farben und freie Farbwahl; neue Ebenen wechseln reihum durch die
  Palette, gespeicherte Presetfarben bleiben erhalten.

- AU-Kanalzüge bieten einen Arpeggiator mit Sample-Takt aus dem Audio-Render,
  Richtungen, Rate, Oktaven, Gate, Swing, Velocity und Sync to beat.
  Chord kann davor und danach stehen; Hold/Toggle, Presets und Undo bleiben erhalten.

- Bühnenbetrieb hält App und Display wach, solange Audio oder Scanner aktiv sind.
  Ein optionaler gelernter MIDI-Fußschalter löst PANIC unabhängig von Main aus.
- Letztes Preset und Szene werden auf Wunsch wieder geöffnet; eine neuere
  Wiederherstellungsdatei bewahrt ungesicherte Änderungen getrennt vom Preset.
- Unbelegte Multi-Tasten reichen den Originalton durch; überlappende
  Effektakkorde behalten pro Tonhöhe die höchste Velocity.

- AU-Kanalzüge besitzen vier MIDI-FX-Plätze mit Bypass, ziehbarer Reihenfolge
  und Chord-Editor (Scale, Single, Multi, Lernen per Mini-Klaviatur).
  Effektketten bleiben in Gesamt-/Kanalpresets und Undo erhalten; externe MIDI-Ziele bleiben unverändert.

**RUNDE-D (18.10.) · Mehrfachbearbeitung, Tonhöhen und Kanal-Presets**

- Mixerzüge nutzen ein gemeinsames Raster und die verfügbare Faderhöhe;
  Ausgabegeräte-Karte und Mini-Klaviatur stehen darüber. Vier Insertplätze je Kanal
  und vorbereitete Sends A/B (deaktiviert, mit rückwärtskompatiblen Presetfeldern).
- Zielgruppen zeigen direkt erreichbare Schalter, lassen sich pro Instrument einklappen,
  übernehmen beim Anlegen das Ziel und unterstützen Zielwechsel per Ziehen.
- Zweizeilige Knopfbeschriftungen erhalten passende Flächen; kurze Texte mit
  vollständigen Tooltips passen auch in schmale Spalten. Das View-Menü ist einmalig.
- Ebenenauswahl erfasst auch leere und gesperrte Ebenen. Gemeinsame Ziele und
  Eigenschaften lassen sich zusammen bearbeiten; gemischte Werte sind sichtbar,
  gesperrte Mitglieder bleiben unverändert und können ausdrücklich entsperrt werden.
- Transponieren und Akkordumkehrungen bearbeiten Grundzuweisung und eigene
  Zellwerte mit einem Undo. Bereichsüberschreitungen lehnen den gesamten Befehl ab;
  der Akkordgrundton bleibt bei einer Umkehrung erhalten.
- Kanal-Presets speichern Instrument, Inserts und Pluginzustände getrennt von
  Gesamtpresets. Laden löst den gewählten Kanal und bewahrt seinen vorherigen
  Pluginzustand für Undo. Ebenen lassen sich aus einem gespeicherten Preset
  übernehmen, ohne dessen Szenen zu importieren.

**KONTUR-TOLERANZ (18.10.) · Vorgabe und Beschriftung**

- Frische Konturtoleranz und Regler-Reset verwenden gemeinsam 5 cm.
  Aufnahmen behalten ihre gespeicherte Toleranz.
- Detektionsregler zeigen ausgeschriebene Namen zentriert in bis zu zwei
  Zeilen, bei unveränderter Schriftgröße und Reglerbreite.

**AU-MIDI-STEUER (18.10.) · AU-Controls und bedienbare Inspector-Zahlen**

- AU-Instrumente empfangen CC, Program Change mit Bank, Pitch Bend und Pressure
  über den gewählten Kanalzug. Der Output Monitor zählt CC/PC; Sustain/Bend
  werden auf den Lösewegen neutralisiert.
- Erhaltene Steuerformulare fordern beim Einblenden ihre volle Höhe an.
  CC-Nummern haben Zahlenfeld, Stepper und Namensliste; Eingaben werden bei
  Fokusverlust, Auswahlwechsel und Speichern übernommen. Die PC-Zählweise
  nennt den Gerätebereich, zeigt das gesendete Byte und wird je MIDI-Ziel gemerkt.
- MIDI-Ziellisten folgen Setup-/Hot-Plug-Änderungen automatisch und haben
  sichtbare Refresh-Knöpfe. Eigene Skalarwerte lassen sich wieder aus den vom
  aktuellen Encoder geschriebenen Presets laden; die alte Schreibweise bleibt lesbar.

**HALTEN-WECHSEL (18.10.) · Ein Haltebesitzer je Ausgabekanal**

- Ein neuer gehaltener Akkord löst den bisherigen auch bei gleichzeitig
  berührten Zonen vollständig ab. Unterlegene Zonen holen den Kanal beim
  Verweilen nicht zurück; gleichzeitige Eintritte folgen der Ebenenreihenfolge.
- Gemeinsame Töne bleiben standardmäßig liegen. „Common notes“ neben Transition
  erlaubt erneuten Anschlag, auch für Legato und Toggle-An; Undo, Presets und
  Altdateien berücksichtigen die Wahl.


**EDITOR-LAST (18.10.) · Editorarbeit ohne Vollneubau je Regler oder Profil**

- Mixer und Tempo validieren und übernehmen Werte ohne Compile oder neuen
  Feldplan; Metadaten übernehmen den kompatiblen Musikindex, Detektion
  kompiliert einmal je Änderung. Undo/Redo folgt derselben Grenze.
- Der Indexvergleich normalisiert erlaubte Metadaten und vergleicht danach
  vollständige Ebenen-, Kanal- und Szenenwerte. Feldweise Ausschlusstests sowie
  Zell-/Ebenenzuweisungen bis zur Runtime-Ausgabe sichern die Grenze ab.
- Ebenen- und direkte Kanalnamen übernehmen erst bei Enter oder Fokusverlust;
  eine Übernahme ist ein Undo-Schritt, Escape verwirft den Entwurf.
- Das Feld verwendet eine vorbereitete Sitzungsprojektion und getrennte
  Auswahlgrafik. Die Auswahl bleibt in Perform erhalten; laufende Profile
  erzeugen weder Auswahlpfade noch erneute Auswahlfilter.
- Labelbesitz nutzt die gemeinsame Malreihenfolge, Auswahlklicks lesen
  vorbereitete Labels. Zählproben sichern diese Arbeitsgrenzen ab.

**AUFTRITT-LAST (18.10.) · Szenenfärbung und ruhige Auftrittsanzeigen**

- Szenenklicks und gemessene Szenenwechsel aktualisieren Feldhörbarkeit und
  Labelbesitz ohne neue Zellpfade; das Dokument wird einmal publiziert.
- Die großen Zellnamen reagieren auf aktive Zellen und Workspace-Änderungen;
  gleiche Messfolgen lösen keine Namensberechnung aus. Nicht richtungsabhängige
  Einzelzellwerte benötigen keine Wertzellenmenge der ganzen Ebene.
- Der Rückstauhinweis beobachtet nur entdoppelte Statusänderungen. Die
  Profilmatrix begrenzt auch Ratenpublikation und die beiden Hz-Anzeigen.

**INSPECTOR-WECHSEL (18.10.) · Vorbereitete Musik- und Programm-Bedienelemente**

- Klaviaturen und Akkordauswahl behalten ihre Identität beim Inhaltswechsel;
  unveränderte Tasten und Menüzeilen werden nicht erneut ausgewertet.
- Programm-Zahlenfelder bleiben vorbereitet, ihre Entwürfe verfallen weiter
  beim Zell-/Ebenenwechsel und bei Perform. Die Anzeige liest die aktuelle Zelle.
- MIDI-Zielaktualisierungen erreichen das Zieldropdown statt der Ebenenliste.
  Wechselarbeit, native Texteingabe und Offline-Bilder sind getrennt abgesichert.
- Verborgene Musik im Ebeneninspector erhält keine Root-Aktualisierung;
  die native Sichtbarkeitsgrenze bewahrt den schnellen gewöhnlichen Zellwechsel.

**PC-NUMMER (18.10.) · Preset- und Banknummern direkt eintippen**

- Preset, Bank MSB und Bank LSB haben Zahlenfelder neben den Steppern;
  Enter oder Fokusverlust übernehmen gültige Werte direkt in Ebene und Zelle.
- Ungültige Eingaben zeigen den Bereich und erhalten den bisherigen Wert;
  Escape verwirft, Text-Undo und Einzeltasten bleiben beim Textfeld.
- Eine Texteingabe ist ein Undo-Schritt, Stepper-Klickfolgen je Feld werden
  zusammengefasst. Perform sperrt die Eingaben über die vorhandene Edit-Grenze.

**AUSWAHL-HARMONY (18.10.) · Auswahl auf geänderte Inspector-Teile begrenzt**

- Inspector-Eingaben werden einmal vorbereitet; erhaltene Ebenenzeilen haben
  eigene Hosting-Grenzen und getrennte Auswahlmarkierungen.
- Beschriftungspositionen werden mit dem Feldplan vorbereitet; ein Klick
  wählt das fertige Array. Listeneingaben ändern sich nur mit Ebenen und Szenen.
- Unveränderte Szenenschaltflächen und Feldtexte bleiben erhalten. Native
  Auswahl, Umbenennen, Dokumentänderungen und Auswahlgeschichte bleiben geprüft.
- Harmony 29/30 stehen zusammen mit Keller 03 im unveränderten 50-ms-Budget;
  Zählproben mit zusätzlichen Szenen sichern die eingesparte Arbeit ab.


**LEISTUNG-3 (17.10.) · Clock und Pegel publizieren nur Sichtbares**

- Empfangene Clock und Hinweise aktualisieren eigene Anzeigeobjekte;
  Dokument und unbeteiligte Ansichten bleiben im Spielbetrieb ruhig.
- Stumme Clock-Quellen wecken nach der Verlustfrist nicht weiter;
  Wiederverbindung erfolgt über Endpoint-Ereignisse.
- Kanal- und Summenpegel teilen einen Lesetakt und publizieren nur sichtbare
  Pegel-/Clip-Änderungen; statische Skala und Bedienknopf bleiben unabhängig.
- Profilanzeige nutzt Sitzung/Sequenz und vorhandene Geometrie; Zellen werden
  auf der Runtime-Queue vorsortiert. RX-Beobachter erhalten nur diskreten
  Status, ruhende Lern-/Referenzmodelle bleiben unberührt.


**LEISTUNG-2 (17.10.) · Raumaufnahme unabhängig von der Anzeige**

- Raumaufnahme zählt 125 aufeinanderfolgende Eingangsprofile auch bei
  verdecktem Messfeld oder blockiertem Hauptthread; Sitzungswechsel und
  Verlust brechen ab, vorhandene Konturen bleiben erhalten.
- Eine ereignisgesteuerte Anzeigepumpe ersetzt den ständigen 25-Hz-Timer.
  Verdeckung, Minimierung und App-Ausblenden pausieren Anzeige, Pegel und
  Diagnose; Runtime und Instrument laufen weiter.
- USB-Hotplug nutzt IOKit-Benachrichtigungen. Nichtmusikalische Anzeigetimer
  erlauben Leeway; unveränderte Diagnosewerte lösen keine Publikation aus.

**MACOS12-LEISTUNG (17.10.) · Profilstrom von Szenen und Reglern trennen**

- App-Szenen und Menüs beobachten nur ihren eigenen Präsentationszustand.
  Profilrate läuft getrennt vom Verbindungsstatus in kleinen Hz-Anzeigen;
  Verbindungsleiste, Evidenzkarte und Simulationsknöpfe bleiben bei Profilen ruhig.
- Alle Settings-Reiter und Perform verwenden den dunklen Bühnenhintergrund,
  auch wenn macOS auf helle Darstellung eingestellt ist.
- Das Bundle-Skript unterstützt `--universal` für arm64 und Intel;
  `SICK_TEST_ARTIFACT_DIR` hält Test-Bundles vom Owner-Bundle getrennt.

**QUALITÄT-2 (17.10.) · Paketgrenzen vollständig prüfen**

- Der bestehende Manifesttest prüft alle Produktionsziele nach expliziten
  Rollen, direkten Kanten und transitiven Grenzen; neue unbekannte Ziele
  und Produktionsabhängigkeiten auf Testhilfen schlagen fehl.
- Fehlermeldungen nennen Ziel, Abhängigkeit, Grenze und indirekten Pfad.
  JSON-Fixtures sichern erlaubte und verbotene Graphen ab; bestehende
  Ausnahmen sind einzeln begründet, Paketabhängigkeiten bleiben unverändert.

**QUALITÄT-1 (17.10.) · Veraltete Ladeentscheidungen verwerfen**

- Save und Don't Save ersetzen keine Änderungen, die seit dem Öffnen des
  Presetdialogs hinzugekommen sind, einschließlich nativer Plug-in-Zustände.
  Die App zeigt „Changed meanwhile – choose again“ und fragt erneut.
- Ablehnung, ausstehende Verlustbestätigung, Abbruch und veraltete Bestätigung
  sind über Dokument, Canvas-Auswahl, ganze History, Runtime und klingende
  Fake-Ausgaben gemeinsam abgesichert.

**BUDGET-361 (15.10.) · Weniger Arbeit je Anzeigetakt**

- Gleichfarbige Rohscanpunkte werden gemeinsam gezeichnet,
  Editor- und Konturpräsentation je Zeichenaufruf einmal berechnet.
- Bei lückenlosen Profilen durchsucht MMK nur die Nachbarstrahlen im
  wirksamen Winkel; Messwerte, Gewichtung und Auswahlreihenfolge bleiben gleich.
- Opt-in-Messung der Main-Thread-CPU je Abschnitt, ohne verändertes Ansichtsbudget.

**KOPFLEISTE (15.10.) · Mehr Platz für das Messfeld**

- Werkzeuge, Zellgröße, Ansicht, Szenen und Gerätefelder stehen in einer
  gemeinsamen, bei Platzmangel umbrechenden Leiste; Layer und Zellzahl rechts.
- Rechtsklick schaltet global gespeicherte Kurznamen unter den Symbolen ein
  oder aus. Statusmeldungen belegen feste einzeilige Flächen unter dem Feld.
- Detection bleibt in seiner bisherigen einklappbaren Zeile.

**OVERLAYS-2 (15.10.) · Reglerwirkung im kleinen Raum**

- Probe-Objekte und ihre Abstandsangaben passen sich Kontur und sichtbarem
  Feld an; Representative/Offset, Winkelschatten, gefüllte MMK-Fenster und
  verbundene Roh-/Glättungsspuren zeigen die tatsächlichen Stufenwerte.
- Raumkonturpunkte erscheinen bei Objektreglern nicht als verworfen.
  Zellselektor und EXP-Glätter schreiben ihren Zustand ohne zusätzliche Kopie fort.

**DETEKTION-STUFEN A (14.10.) · Modulare Detektion, Layoutvorschau**

- Detektionsstufen besitzen eigene Konfigurationen, Berechnungen und
  Reglerbeschreibungen; eine gemeinsame Kettenbeschreibung erhält Presets,
  Musik und Aufnahme-Replay unverändert.
- Breite und schmale Bilder entstehen aus den echten Views. Die produktive
  Layoutumstellung wartet auf Owner-Freigabe (`ROADMAP.md`).

**RANDPUNKTE (14.10.) · Randkürzung, Spielkern und Profilaufnahme**

- Groups ergänzt Edge points und eine metrische Core width; die Scheiben
  behalten die Objektgröße und zeigen den Spielkern als helleren Streifen.
- Neue Dokumente und Werkspresets verwenden Edge 1 / Core 3 cm, Altdateien
  bleiben unverändert Off. Beide Regler respektieren die Perform-Sperre.
- Scanner Development nimmt zehn Sekunden Rohprofile als JSON auf,
  einschließlich Fortschritt und Finder-Verweis, auch in Perform.
  Offline-Auswertung und synthetischer Beleg sind vorbereitet; reale
  Owner-Aufnahmen und Schwellenbestätigung stehen aus (`ROADMAP.md`).
- Die unbenutzte automatische Verbindungsroute samt Tests wurde entfernt.

**REGLER-OVERLAYS (14.10.) · Detektionswirkung im Messfeld**

- Hover und Drehen zeigen Konturtoleranz, Lückenmaß, akzeptierte/verwarfene
  Punkte, Zellabstände, Probe-Historie, Bestätigungszähler und MMK-Fenster.
- Probe-Gruppenfarben folgen der tatsächlichen Strahlzugehörigkeit aus dem
  Detektor. Alle Darstellungen bleiben ohne musikalische Ausgänge und
  verschwinden beim Verlassen; Perform zeigt keine Overlays.

**TEMPO-3 (14.10.) · AU-Tempo und Transport**

- Gehostete Instrumente und Effekte erhalten Tempo, Beat-Position und
  4/4-Transport aus dem gemeinsamen internen oder empfangenen Takt.
- Off liefert das Presettempo bei stehendem Transport. Neue Instanzen,
  Preset- und Kanalwechsel erhalten dieselbe Host-Anbindung, auch AUv2.
- Render-Callbacks lesen einen lock-freien Snapshot und berechnen die
  Position aus Sample-Zeitstempeln. Reale Sync-Plug-ins bleiben Owner-Test.

**TEMPO-2 (14.10.) · Externer MIDI Clock folgen**

- „Tempo & Sync“ erlaubt Receive mit einer global gespeicherten Quelle.
- Die Kopfleiste zeigt externes Tempo, Transport und Clock-Verlust;
  Presettempo und klingende Noten bleiben erhalten. Richtung/Quelle sind
  in Perform gesperrt, Tempo/Tap folgen in Receive ausschließlich der Quelle.
- Paketzeitstempel werden unabhängig vom Main-Thread ausgewertet;
  Quellenrückkehr und Schlaf/Beenden schließen den Eingangslebenszyklus.

**TEMPO-1b (14.10.) · T bei Texteingabe erhalten**

- Tap per T respektiert Texteingaben, Blätter, Einstellungen und
  Zusatztasten. „Tap Tempo (T)“ im Menü bleibt anklickbar.
- BPM und Tap sind auch in Perform erlaubt und erhalten klingende Noten
  und das installierte Instrument; Clock-Einstellungen bleiben gesperrt.

**TEMPO-1 (14.10.) · Tempo und MIDI Clock senden**

- Presets tragen BPM; Kopfleiste mit BPM, Tap (T) und Clock-Play/Stop.
- „Tempo & Sync“ speichert Send/Off und mehrere Clock-Ziele global;
  Receive ist als nächster Schritt sichtbar. Noten behalten ihr eigenes Ziel.
- Zeitgestempelte Clock läuft auf einer eigenen Queue, übernimmt BPM beim
  Presetladen und stoppt definiert auf den Lebenszykluswegen. Zielrückkehr
  wartet auf den nächsten Transportstart. Details und Grenzen: `ROADMAP.md`.

**TOGGLE-SCHUTZZEIT (14.10.) · Versehentliches Umschalten abfangen**

- „Toggle guard“ schützt jede Toggle-Fläche nach dem Umschalten; frühe
  Eintritte werden verworfen. Einstellbar bei Transition, in Perform gesperrt.
- Neue Ebenen und Werkspresets starten mit 0,5 s, Altdateien ohne Feld mit
  0 s. Explizites Lösen wirkt weiterhin sofort (Vertrag in `ROADMAP.md`).

**BÜHNE-FEST-C (13.10.) · Rückstau sichtbar begrenzen**

- Profilrückstau über zwei Sekunden löst auch gehaltene und Toggle-Noten;
  die Messfläche meldet Überlauf und Erholung. Neue Messungen spielen nach
  dem Abbau wieder, Bedien- und Lebenszyklusbefehle bleiben erhalten.
- Der aktive Zellanzeigepfad projiziert ohne `try!`. Dokument- und
  Presetdecoder lehnen ungeeignete Editorraster vor der Anzeige ab.

**GERÄT-825-ZURÜCK (12.10.) · Verbindungsmechanik von Build 825 wiederhergestellt**

- Owner-Entscheidung nach Gerätetest Build 842: Die neue Geräteautomatik
  (GERÄT-HÄRTEN, `667984e`) fand den Scanner nicht. Sie erkannte den
  laufenden Zielstrom (361 Punkte, 500000 Baud), übernahm ihn aber nicht,
  sondern scheiterte wiederholt am Anhalten des Stroms.
- Gerätecode wieder bytegleich Build 825 (`a99ff02`): Verbinden übernimmt einen
  passenden Strom, sonst Einrichtung auf den gewählten Modus 361 oder 90.

**BEDIENUNG-NEU (12.10.) · Canvas-Bedienung mit einer Auswahlregel**

- Auswahl merkt sich die Ebene jeder Zelle; Löschen, Verschieben, Kopieren
  und Zuweisen wirken auf genau diese Zellen, auch über mehrere Ebenen.
- Sichtbare Werkzeuge Auswahl (V), Malen (B), Radieren (E), Hand (H,
  Leertaste); Rahmen mit Anfassern zum Verschieben und Stauchen.
- Tastatur, Kontextmenü und Zwischenablage auf Zellen; gesperrte und
  ausgeblendete Ebenen sind nicht auswählbar, jede Nicht-Wirkung wird gemeldet.

**GERÄT-HÄRTEN (12.10.) · Messmoduswechsel automatisch und ehrlich**

- Verbinden, Moduswechsel und Wiederverbinden erkennen den Ist-Zustand
  (500000/38400/9600, 90/180/361 Punkte) und erreichen den Zielmodus über
  eine gemeinsame Automatik; Ablauf als eine Tabelle in `ROADMAP.md`.
- Restprofile des alten Stroms werden verworfen statt als Fehler gewertet;
  Erfolg erst nach drei CRC-gültigen Zielprofilen; bis zu drei Versuche,
  bei 361 danach MMK-Rückfall ab der belegten Rate.
- 180-Punkt-Strom wird benannt, nie „unreachable“, solange gültige
  Telegramme ankommen; Abbrechen jederzeit, ohne Rückfall.

**PRESET-EINPASSEN (11.10.) · Presets radial an den aufgenommenen Raum anpassen**

- „Fit to room“ neben „Capture room“, mit einstellbarem Wandabstand,
  Warnmarkierungen und Hinweisen auf Zonen unter Handbreite.
- Gemeinsame Polarregel für Verschieben, Stauchen und lückenloses Strecken;
  Zellwerte und Aktionen folgen der bestehenden Gewinnerregel.
- Ein Undo-Schritt für alle Ebenen; Originaldatei, Szenen und Kanalzüge
  bleiben erhalten. Rahmen und neue Canvas-Bedienung folgen separat.

**KANALZÜGE-1 (10.10.) · Mischpult mit bis zu acht unabhängigen Zügen**

- Verpflichtende stabile Zug-IDs für AU-Noten, All Notes Off und Parameter,
  auch beim Wechsel im Ebenenmenü; Halten und Toggle besitzen
  ihre Töne je Zug. Gelöschte Ziele bleiben sichtbar als „missing channel“
  und spielen nicht auf einem anderen Zug weiter.
- Eigene Instrument-/Insert-Instanzen, Pegel, Pan, Mute/Solo und Meter je
  Zug in einem gemeinsamen Audiographen; separate Summe mit Master-Fader.
- Mischpult mit Hinzufügen, Umbenennen, Farbe, Duplizieren und Löschen;
  Zugknöpfe im Output, horizontales Scrollen und Performance-Mini-Züge.
  Genau ein globaler PANIC an der Summe; AU-Instrumentwechsel lösen nur
  den betroffenen Zug und lassen andere Züge sowie MIDI stehen.
- Presetformat V6 speichert das gesamte Mischpult einschließlich Zuständen
  und Beschreibung. Alte Formate migrieren auf „Ch 1“; Werkspresets werden
  vom Generator als V6 erzeugt. Reale Plug-in-Messung bleibt KZ-4.

**HALTEN-TOGGLE (10.10.) · Toggle für Loops, Release layer, Halten übersteht Eingangsverlust**

- Neuer Übergang „Toggle: on / next entry off“: erster Eintritt schaltet
  die Zelle an, der nächste frische Eintritt in dieselbe Zelle aus; Zellen
  unabhängig, kanalweites Halten ersetzt sie nicht.
- Zellfunktion „Release layer“ (Ebenenvorgabe und je Zelle): löst nur
  gehaltene und umgeschaltete Töne der Zielebene; Feld zeigt „Release …“,
  fehlende Ebene „missing“.
- Owner-Ausnahme A: gehaltene und umgeschaltete Töne überstehen
  unfreiwilligen Eingangsverlust (stale, inputLost, Sitzungsende durch
  Fehler); PANIC, Stopp, Preset-/Instrumentwechsel, Trennen, Eingangs-
  wechsel, Schlaf und Beenden lösen alles.

**BÜNDEL-1010B (10.10.) · Betriebsart wählbar, Feldeditor, schnellere Glättung**

- Verbindungsbereich: „Measurement: MMK 90 · Full scan 361“, je Mac
  gemerkt. Umschalten löst klingende Ausgänge, stoppt den Strom, fordert
  die Betriebsart an und prüft die Punktzahl des neuen Stroms; bei Fehler
  Rückfall auf MMK.
- Feldeditor „Device fields“ (offline): Schutz- und Warnfeld getrennt von
  den Musikebenen zeichnen, laufende Prüfung (Insel, Ring, Lücke, 4 m /
  50 m), Ausgangshinweis OSSD / WEAK SIGNAL, Export der Kontur nur als
  Datei. Kein Senden ans Gerät.
- Glättung (Mittel/Median/Exponentiell) liest die Historie je Messindex
  statt sie je Punkt zu durchsuchen; Ergebnis bitgleich, 361 Punkte mit
  Glättung jetzt p99 ≈ 0,35 ms statt ≈ 3,3 ms (Release).

**BÜNDEL-1010 · Targetgrenzen, Presetbeschreibungen, Scannerfeldwerte**

- Audio und Presets erreichen keine Scanner-Eingabe oder Geräteschicht
  mehr; gemeinsame Viewport- und AU-Metadaten liegen in der Wertdomäne.
- V5-Presets tragen optional einen Beschreibungstext: ausklappbare Anzeige
  des geladenen Presets, separat kopierbare Quelle, native Menütooltips und
  Bearbeitung beim Speichern. Über 1000 Zeichen werden mit Meldung abgelehnt.
  Die Werkbeschreibungen kommen wortgetreu aus der freigegebenen Tabelle.
- „Scanner flag bits“ färbt Messpunkte nach dem rohen Wert 0…7 und zeigt
  Zählwerte; die Einstellung bleibt lokal und startet ausgeschaltet.
- Segmentierte Scannerfeldkonturen lassen sich rein offline kodieren,
  dekodieren und als metrisches Polygon prüfen. Polare Flächen mit Inseln
  oder radialen Lücken werden abgelehnt. Kein Gerätezugriff oder TX-Pfad.

**OWNER-LAUF-0910B (09.10.) · Befunde Owner-Test Build 766**

- Preset wird schon beim Auswählen geladen (Knopf „Load“ entfällt); bei
  ungespeicherten Änderungen Rückfrage, Abbrechen lässt die Auswahl beim
  geladenen Preset. „Delete“ wirkt auf das geladene Preset.
- Zellen nach außen ziehen: Ein einfacher Klick auf eine Ebene macht nicht
  mehr die ganze Ebene zum Verschiebeziel (Ursache: eine 2-m-Zelle der Ebene
  blockierte jede Bewegung nach außen). Ganze Ebenen nur bei Wahl von
  mindestens zwei Ebenen. Anschlag am Feldrand mit Hinweis unter dem Feld.
- Zell-Inspector zeigt nach Zellwechsel immer den Inhalt der gewählten Zelle
  (kein „on“ in Akkordzellen); Notenzeile unter der Klaviatur entfällt.
- Ebenen-Inspector zeigt nur die Ebenenvorgabe; Szenenaktion als
  Menütitel. Gewählte Ebene ruhig markiert (auch stumm), Szenenpunkte in
  eigener Spalte, lange Namen gekürzt.
- Statusschalter in beiden Zuständen auf der ganzen Fläche klickbar.

**AUSTAUSCH-EBENEN (09.10.) · Presets ex-/importieren, Ebenen duplizieren und kopieren**

- File → Import Preset… (⌘⇧I, Mehrfachauswahl) und Export Preset… (⌘⇧E),
  auch im Presetbereich. Import prüft jede Datei einzeln, legt sie
  kanonisch als V5 ab (unabhängig vom offenen Preset), benennt Konflikte
  „Name 2“ und wechselt das aktuelle Preset nicht.
- Ebene duplizieren (Knopf, Kontextmenü, ⌘D in Ebenenliste/Feld): neue IDs,
  gleiche Zellen und Ziele, dieselben Szenen wie das Original.
- Ebenen kopieren/einfügen (⌘C/⌘V in Ebenenliste/Feld, Kontextmenü), auch
  zwischen Presets; eingefügte Ebenen treten der aktiven Szene bei.
  Textfelder behalten ihr normales Kopieren/Einfügen.

**LAYOUT-2 (09.10.) · Zell-Inspector, Szenenleiste, Performance-Modus**

- Zell-Inspector: Lage, Ton/Akkord bzw. Wert, Herkunft, „Reset to layer“;
  Umschaltzellen zeigen ihr Ziel.
- Umschaltziel je Zelle (Next, Previous oder bestimmte Szene); ohne eigenes
  Ziel gilt die Ebenenvorgabe. Alte Presets unverändert.
- Szenenleiste über dem Feld (Klick aktiviert, Kontextmenü), Punkte in der
  Ebenenliste zeigen die Szenenmitgliedschaft.
- Performance-Modus (⌘⇧P): nur Feld, Szenenleiste, Statuszeile und
  Mini-Kanalzug; Feld gegen Bearbeiten gesperrt; gespielter Akkord groß;
  Verbindungsverlust rot in der Statuszeile.
- Feld beschriftet bei ortsgleichen Ebenen die hörbare.

**LAYOUT-1 (09.10.) · neues Fenstergerüst**

- Statuszeile oben (Eingang, Rate, Preset, Szene) mit Schaltern für die
  Bereiche; Menü „View“ mit ⌘1 Setup, ⌘2 Layers, ⌘3 Cell, ⌘4 Channel
  strip.
- Setup-Leiste klappt bei laufender Verbindung ein und bei Verlust auf;
  von Hand geöffnet bleibt sie offen.
- Ebenen (300 pt) und neuer Zellbereich (220 pt) nebeneinander, bei
  schmalem Fenster als Reiter. Aufteilung wird je Mac gemerkt.

**OWNER-LAUF-0910**

- Insert aus/an wie in Logic: das Plug-in bleibt im Signalweg, „aus“ setzt
  seinen Bypass. Kein Loch mehr; Nachhall bleibt erhalten, sofern das
  Plug-in seinen Bypass weich schaltet (Apple-Effekte schalten hart).
- Master-Fader zeichnet den Griff sofort aus der Mausposition; Lautstärke
  und Dokument folgen gebündelt.

**ZELLEN-VERSCHIEBEN (09.10.)**

- Markierte Zellen per Ziehen (auf der Auswahl beginnen) oder Pfeiltasten
  verschieben: vor/zurück = Abstand, seitlich = Drehen um den Scanner.
  Mit „Select all layers“ wandern alle Zellen aller gewählten Ebenen.
  Vorschau beim Ziehen, Escape bricht ab, ein Undo-Schritt; am Rand des
  Spielbereichs hält die Auswahl an. Zellwerte wandern mit.

**PRESET-SZENEN (09.10.) · drei Werkspresets mit Szenen**

- Harmony 28 Twelve-Bar Blues (Dur-/Moll-Blues), 29 Picardy Switch
  (C-Dur bei Tag, C-Moll bei Nacht), 30 Mode Wheel (sechs Modi, rechts
  heller, links dunkler). Umschaltzellen außerhalb der Akkordflächen.
- Szenen speichern ihre Ebenen in fester Reihenfolge; ein unverändertes
  Preset behält beim Speichern seine Bytes.

**AUDIO-HOST-1 (09.10.) · Host absturz- und gerätewechselfest**

- Lehnt ein Plug-in beim Verkabeln das Format ab, erscheint es als
  fehlgeschlagen; die übrige Kette spielt weiter (vorher Programmabsturz).
- Gerätewechsel, abgezogener Ausgang oder geänderte Abtastrate bauen den
  Audioweg neu auf und starten ihn wieder; ein verschwundenes Gerät fällt
  sichtbar auf „System Output“ zurück.
- Instrumentwechsel blendet über 10 ms aus und wieder ein (kein Knacks).

**HARMONIE-1 (08.10.) · Szenen und Umschaltzellen**

- Szenen legen fest, welche Ebenen aktiv sind (Inspector: anlegen,
  umbenennen, sortieren, „Remember“, löschen); im Preset gespeichert, alte
  Presets unverändert.
- Neues Ziel „Scene switch“ (nächste, vorige, bestimmte Szene) mit
  Verweilzeit (Standard 0,2 s); löst nur aus echter Messung und erst nach
  Verlassen der Zelle erneut aus. Ebenen mit Umschaltzellen bleiben immer
  aktiv.
- Ein Szenenwechsel beendet keinen Ton: Töne stumm werdender Ebenen enden
  beim Verlassen ihrer Zelle bzw. über jeden Löseweg; stumme Ebenen starten
  keinen Ton.

**AUDIO-FADE (07.10.)**

- Insertwechsel blenden den Ausgang über 10 ms aus, verdrahten erst nach
  gemeldeter Stille neu und blenden wieder ein. Schnelle Änderungen werden
  auf den letzten Stand zusammengefasst; ohne Renderantwort endet das Warten
  nach 80 ms. Kanal-Stumm verwendet dieselbe Rampe.

**Owner-Lauf 07.10. · Befunde Build 729**

- „Detection“ klappt beim Klick sofort auf und zu (der Ausklappzustand fehlte
  in der Neuzeichnen-Identität des stabilen Kopfbereichs).
- Der Scanner bleibt an der Unterkante des Messfelds, auch nach Fenster-
  oder Layoutänderung und nach dem Laden eines Presets (Zoom und seitliche
  Lage kommen aus dem Preset). Verschieben/Zoomen/Einpassen lösen die
  Verankerung, „Reset view“ setzt sie wieder.
- Plug-in-Fenster zeigen beim Wiederöffnen die echte Oberfläche: Der Editor
  wird je Plug-in einmal angefordert und behalten; beim Schließen wird er nur
  aus dem Fenster gelöst, freigegeben erst mit dem Plug-in.
- Pegelanzeige läuft wieder: Jede Pegelansicht meldet sich einzeln am
  gemeinsamen Leser an und ab; ein neu aufgebauter Kanalzug stoppt ihn nicht
  mehr.
- PANIC bleibt rot, auch wenn ein Plug-in-Fenster den Fokus hat.
- Pegelbalken sichtbar: Seit dem schmaleren Kanalzug (B2) hatte die
  Pegelanzeige nur 18 pt, die Ziffern belegten 12 pt, die Balken hatten
  0 pt; nur die Übersteuerungslampe war zu sehen. Neue Aufteilung
  16/18/26 pt mit Mindestbreite der Balken, Pixeltest an Produktbreite.
- Plug-in-Fenster sind schwebende Panels wie in Logic: Sie bleiben über dem
  Hauptfenster und nehmen ihm den Fokus nicht; der erste Klick auf Fader oder
  PANIC wirkt sofort.
- Knopf „Select all layers“ in der Ebenen-Kopfzeile; der Übergangsmodus
  gilt dann für alle Ebenen. „Hold until next note“ heißt jetzt „Hold till
  next trigger“.

**R5 Teil 1 · toter Altkern entfernt (07.10.)**

- 18 Quelldateien ohne Produktionsaufrufer entfernt (vom App-Einstieg aus
  nachgerechnet, vom Compiler bestätigt): alte Zonen-Prognosepipeline mit
  Predictor, `PreparedOutput*`-Familie, alte Gitter-Anzeigeplanung
  (`DeviceLattice*`), `SpatialDocumentBlockPaint`, `UIPublicationLedger`,
  `PerformanceSignposts`, `MetricDisplayCadence`, `ZoneSectorGeometry`,
  `FieldCellGeometry`, `SegmentedFieldContour`, Zeitquellen und zwei
  Zonen-Anzeigehilfen. Mit ihnen 142 Testfälle, die nur diesen Code prüften.
- Behalten: Altformat-Datensätze für die Preset-Migration
  (`MIDIOutputConfiguration`, `ControlValuePredictorConfiguration`).

**ABNAHME-B3 (06.10.)**

- Pegelanzeige mit Farbverlauf im Balken: grün, ab −6 dBFS orange, oben rot.
  Die Übersteuerungsanzeige erlischt nach 2 s ohne neue Übersteuerung von
  selbst; ein Klick löscht sie sofort.
- Glättung als Drehschalter OFF/MEAN/MEDIAN/EXP; OFF behält das Fenster.
- Alle übrigen Detektionsregler als rastende Drehknöpfe (ziehen, Doppelklick
  = Vorgabe) in einer Reihe; ausgegraut, wenn sie gerade nicht wirken.

**ABNAHME-B2 (06.10.)**

- Messfeldkopf kompakt: Titel und Untertitel in einer Zeile, „Merge zones“/
  „Show raw scan“ in der Werkzeugleiste, Detektionsblock standardmäßig
  eingeklappt mit Zusammenfassungszeile; Warnungen zur Raumkontur bleiben
  sichtbar. Messfeld bei 1440×900 von 800 auf 870 pt.
- Kanalzug 72 statt 108 pt breit; Insert- und Instrumentenslots 30 pt hoch,
  Name zweizeilig; Fader und Pegelbalken 200 statt 244 pt hoch.
- Großer PANIC-Knopf auf dem Kanalzug über M/S; der Knopf im Ebenenkopf
  entfällt.
- Ebenenzeilen niedriger, Symbole rechts gruppiert; Klaviatur 52/54 pt.

**ABNAHME-B1 (06.10.)**

- Der Übergangsmodus (Retrigger, Legato, Overlap, Hold) gilt sofort für alle
  Notenrouten der Ebene, ohne Zellauswahl; mit ⌘-/⇧-Klick für mehrere Ebenen
  in einem Rückgängig-Schritt, gemischte Werte zeigen „Mixed“.
- Ebenen-Stumm als „M“ wie im Kanalzug.
- Letzte deutsche Texte englisch („Output“, „System Output“, „Transition“);
  die Sprachregel erkennt zusätzlich deutsche Wortendungen.

**ABNAHME-A (06.10.)**

- Plug-in-Fenster bauen ihre Oberfläche beim Schließen vollständig ab und
  lassen sich nicht mehr von Hand vergrößern; die Größe folgt dem Plug-in.
- Insert „Aus“ nimmt das Plug-in aus dem Signalweg; Zustand und Position
  bleiben erhalten.
- Panic: Zellen, in denen die Hand ist, bleiben still bis zum Verlassen und
  Neubetreten; andere Ebenen spielen sofort.
- Leuchtanzeige der aktiven Zelle nutzt dieselbe exakte Rasterregel wie die
  Füllung (kein Ring-Versatz an 10-cm-Grenzen).
- Raumgrenze je Strahl aus dem zweitkleinsten Messwert der Aufnahme;
  Toleranz-Vorgabe 3 cm.
- Neuer Detektionsregler „Min. angle“ (Vorgabe 20°) gegen Randtreffer
  hinter der Hand.
- Profil- und Pegelaktualisierung zeichnen nur Messfeld und Pegelbalken neu.
- Zähler „reads with several profiles“ statt „dropped profiles“.
- Ein im Kanalzug gewähltes Instrument startet nach erfolgreichem Laden.

**UMBAU-P8-BEFUNDE (06.10.)**

- Eine neue Dokumentrevision (Fader, Pan, Name, Zellen) startet die laufende
  Detektion nicht mehr neu; klingende Noten bleiben, solange der neue Stand
  sie trägt.
- „Hold until next note“ hält nach Verlassen der Fläche bis zum nächsten Ton
  desselben Ziels/Kanals, gleich welcher Übergangsmodus diesen nächsten Ton
  spielt; andere Polyphonie bleibt. Stopp, Verlust, Panic und Presetwechsel
  lösen weiterhin.
- Ein Faderzug, Panzug oder Reglerzug ist genau ein Rückgängig-Schritt.
- Rückwahl „System Output“ folgt wieder dem Systemstandard; eine
  fehlgeschlagene Gerätewahl ändert die Anzeige nicht.
- Zeitbelege zusätzlich mit eingeschalteter Glättung (Release, 90/361).

**UMBAU-P7 (06.10.)**

- Pegelanzeige mit echtem Messweg: Tap hinter Fader-Gain, nur bei laufendem
  Audio und sichtbarem Kanalzug; Anzeige ≤ 30 Hz mit 20 dB/s Abfall,
  Übersteuerung hält bis Reset. Mono erscheint auf beiden Kanälen.
- Diagnose: Messfenster und „Copy diagnostic report“ zurück, gespeist aus
  Input, Runtime (Profil-/Panic-Zeiten, Überläufe) und Ports (A10); Bericht
  datenfrei.
- Alle Nutzertexte englisch einschließlich Setup, CLI und Bundle; Sprachregel
  über alle Targets. Kanalzug-Schalter folgen ausschließlich dem Hoststatus.

**FELD-BESCHRIFTUNG + FADER-PLUS6 (05.10.)**

- Messfeld: Alle sichtbaren Ebenen sind beschriftet. Akkordnamen folgen dem
  Ebenennamen, wenn er zur Tonmenge der Zelle passt, sonst einer festen
  Erkennungspriorität in jeder Umkehrung. Zusammenhängende gleichwertige
  Zellen erscheinen als eine Fläche mit einem Akkordsymbol („Merge zones“,
  Standard an; reine Ansicht). Bearbeitung und Spielanzeige bleiben zellgenau.
- Zellklick wählt die Ebene der Zelle. Zellen stummer oder durch fremdes Solo
  unterdrückter Ebenen sind blass (dieselbe Regel wie der Klangpfad).
- Pan/Zoom transformiert nur vorbereitete Flächen. Die sichtbare Raumgrenze
  ist die wirksame Filtergrenze; bei passender Kontur zeigt das Feld Objekte
  als Kreise. Wandstreuung über der Toleranz wird mit Vorschlag gemeldet.
- Fader −∞ … +6 dB mit Logic-Skala, 0 dB bei drei Vierteln; Verstärkung über
  eine dokumentierte Gain-Stufe hinter dem Hauptmischer. Pegelanzeige mit
  eigener dBFS-Skala und haltender Übersteuerungsanzeige; der Messweg folgt
  in P7.

**UMBAU-VERTRAG-BC (05.10.)**

- Owner-Lauf 2: Alle Objektgruppen liefern ihren Repräsentanten samt
  MMK-Spanne an die Zellwahl; mehrere Ebenen können gleichzeitig klingen,
  je Ebene bleibt die nächste Zelle maßgeblich. Ohne Gruppierung zählt
  jeder Messwert. Messlücken trennen Objekte; „Min. gap“ stellt den
  radialen Gruppenabstand ein.
- Kanalzug-Felder: Einstellungen liegen neben Ein/Aus, Auswahlpfeile am
  rechten Feldrand; Trefferflächen und Aktionen folgen der neuen Position.
- V5 speichert Zellen und identische benachbarte Einzelwerte als kanonische
  Ringintervalle; ausgeschriebene v5-Dateien bleiben lesbar. Alle Werksdateien
  und die feste Kanal-Fixture sind auf das kompakte Format umgestellt.
- Produkt-Undo fasst Namen und Farben zusammen; Ebenenwahl bleibt Ansicht.
  Malrasterwechsel erhalten feine Zellen und Einzelwerte. ⌘A wählt spielbare
  Zellen; Deaktivieren erhält Einzelwerte. Ein verlustbehafteter Ausgangswechsel
  nennt die Zahl und wartet auf Bestätigung; passende Werte wechseln mit.
- Detektion bietet Glättungsart, Fenster/α, Gruppenschwelle, Mindestpunkte
  und Versatz. Ausschalten erhält die gespeicherten Parameter. Eigene Zellwerte
  sind markiert; der nicht erfüllte Verschiebehinweis entfällt.
- Die reine Domäne hängt an `PLSDeviceValues` und dem Telegrammkern. Der alte
  Auswerter, Runtime und unbenutzte Ansichten entfallen mit ihren spezifischen
  Tests. Der Offline-Benchmark nutzt den Produktionscompiler.
- Diagnose-Takt und Sichtbarkeit sind über den produktiven Leser geprüft.

**UMBAU-P6 Presets v5 (05.10.)**

- Vertragsprüfung A: alle Klangprofile in FIFO-Reihenfolge; Überläufe sichtbar,
  nur Anzeige gedrosselt. Raumkontur übersteht Sitzungs- und Presetwechsel.
  Wake stellt zuvor laufendes Audio wieder her. Start/Stop gilt in allen
  Retire-Zweigen; Instrument-Reattach und Graph-Neustart geben unbetroffene
  Inserts nicht frei. Detektion und Zeitziele werden im Produktionspfad geprüft.
- Beenden wartet höchstens zwei Sekunden auf hängende MIDI-/AU-Ausgänge.
  Panic wird vorher beauftragt; unbestätigte Note-Offs mit Port, Kanal und Note
  stehen im lokalen Protokoll und der typisierten Beendigungsdiagnose.
- Owner-Befund 1: MMK 90 sowie 180/361 Punkte laufen über dieselbe Geometrie
  zu Detektion, Anzeige und Diagnose. MMK-Segmentspannen bleiben auch nach
  Glättung/Repräsentantenbildung erhalten; Teilscans werden sichtbar abgewiesen.
- Harmonievorlagen enthalten keinen Kanal und erhalten den laufenden Kanal
  samt Editor-Zuständen und Kanalmetadaten. Beide Werksstarter bleiben ganze
  Kanäle. Der AudioHost übernimmt bereits live vorliegende Zustände ohne
  erneuten Zustandsschreibzugriff.
- Die Messfeld-Regler werden vom Profil-Takt entkoppelt. Instrument-/Insert-
  Felder sind einfarbig mit mittigem Herstellernamen; die Auswahl trifft die
  ganze Mittelfläche, Ein/Aus und Editor bleiben eigene Randflächen.
- Review 1: Feste Byte-Orakel für alle Werkspresets und einen vollständigen
  kleinen v5-Kanal sichern die kanonische Kodierung. Auch der MIDI-Werksstarter
  erhält seine endgültigen Bytes vom Produktionswriter.
- Presets speichern den vollständigen Kanal samt Instrument, Insert-Reihenfolge,
  Bypass, Plug-in-Zuständen, Pegel/Pan/Mute/Solo, MIDI-Ziel, Detektion und feinen
  Zellen. JSON bleibt deterministisch und lesbar; Plug-in-Zustände sind Base64.
- Ein gemeinsamer Leser importiert v1–v4. Laden installiert eine Revision und
  wendet nur die Audio-Differenz an. Alte Dateien ohne Kanal erhalten den ganzen
  laufenden Kanal; die Owner-Dateien werden nicht automatisch migriert.
- „Dirty“ erkennt auch Änderungen im Plug-in-Editor. Verwerfen/Laden stellt
  gespeicherte Zustände auf derselben AU-Instanz wieder her; Laden startet keine
  Audioausgabe und öffnet keinen Editor.
- Werks- und Harmonie-Presets liegen als v5-Ressourcen vor. Ein Offline-Werkzeug
  verwendet die produktive Geometrie statt einer Python-Kopie. Gleichnamige
  Owner-Dateien und Werksfassungen bleiben getrennt auswählbar.
- Die Presetmodule sind in `PlanariumPresets` gebündelt. Inaktive Altvalidatoren
  und Altformat-Schreibhelfer liegen nur noch im Test-Support; die alten
  Verhaltenstests bleiben erhalten.


**UMBAU-P5 Umschalten (05.10.)**

- Review 1: Plug-in-Fenster übernehmen auch den Editor-Controller als Kind
  ihres Container-Controllers und lösen diese Beziehung bei der Freigabe.
  Der Offline-Prüfstand wartet nach Zustandswechsel auf den bestätigten
  Wiederanlauf nach Retire; echte Apple-AU-Wiederholung beim Supervisor.

- App, Scanner/Simulation, Dokument, MIDI und Audio benutzen einen gemeinsamen
  Spielpfad. Kanaländerungen, Rückgängig/Wiederholen und Preset-Laden gehen
  durch denselben Dokumentbesitzer; Presets ohne Kanal erhalten den laufenden
  Kanal einschließlich Plug-ins und Zuständen.
- Panic, Trennen, Schlafen, Zielwechsel und Beenden lösen über die Runtime;
  Transport und Plug-ins bleiben bis zur Quittung erhalten. Das frühere Nichtstarten bei Wake ist durch Vertragsprüfung A5
  korrigiert: ein zuvor laufender Host wird wieder gestartet. Messfeldanzeige bleibt auch beim Ziehen aktuell.
- Alte Engine, Cutover, Automaton, Profile-Tor, Legacy-Mailbox und zusätzliche
  Transport-/Leaseketten entfernt. Bildtests schreiben standardmäßig temporär.
- Plug-in-Fenster folgen auch reinen View-Frame-Änderungen: eigener Container
  verhindert, dass das Fenster die neue Plug-in-Größe zurücksetzt. Fake-Probe
  korrigiert; echte Apple-AU-Wiederholung und Startprobe beim Supervisor.


**UMBAU-P4 AudioHost (05.10.)**

- Neues `PlanariumAudio`: ein Besitzer des Audiographen und eine langlebige
  Instanz je Instrument bzw. Insert. Kanaländerungen verbinden nur geänderte
  Kanten; Zustand, Bypass und Pegel erhalten die vorhandenen Plug-ins.
- Instrumentfreigabe erst nach Runtime-Retire und Main-Quittung. Lade- und
  Formatfehler bleiben am betroffenen Platz, fehlende Inserts werden überbrückt.
- Jedes Plug-in hält seinen einmal abgerufenen Editor und sein eigenes Fenster;
  bevorzugte Größe und View-Frame steuern Wachstum wie Verkleinerung.
- Fake-Prüfungen und ein separat freigeschalteter Apple-AU-Prüfstand für reines
  Offline-Rendering. Noch kein App-Anschluss; Umschaltung folgt in P5.

**UMBAU-P3 Runtime (05.10.)**

- Neues `PlanariumRuntime` mit einer seriellen Warteschlange, begrenztem
  Profileingang, bedarfsgesteuerten Deadlines und einem vollständig
  synchronisierten Postfach für die Anzeige.
- MIDI- und AU-Ports führen getrennte Sendeergebnisse und Notenbücher.
  Fehler bleiben am Ausgang; neu gebundene Ports beginnen erst beim nächsten
  echten Profil. Retire löst den Port vor der asynchronen Main-Quittung.
- Eine gemeinsame Fabrik für die künftige App-Komposition und den Prüfstand;
  Modellfolgen, Löseweg-Gegenproben, Last- und Latenzmessungen gegen gefälschte
  Grenzen. Noch kein App-Anschluss, AudioHost folgt in P4, Umschaltung in P5.

### 05.10.2026: Umbau „Planarium 2“ beschlossen

- Neuer verbindlicher Architekturplan
  (`.agent_handoff/architektur-neuplan-2026-10-05.md`): eine Wahrheit je
  Sache, ein serieller Takt für alles Musikalische, lokale Fehler ohne
  globalen Fehlerzustand, Plug-ins mit eigenem Besitzer und Fenster, Presets
  als ganzer Kanal. Ersetzt ROADMAP §3 und die Blöcke A–F.
- Theremin-Spielpfad und eigener Synthesizer werden entfernt (Owner E1).

**UMBAU-P1 Rückbau (05.10.)**

- Gelöscht: `SickThereminPerformance`, `SickThereminRuntime`,
  `SickThereminAudioControl`, `SickSynthDSP`, `SickSynthBridge`,
  `SickSynthDSPTestSupport`, Theremin-Teile in Control, MIDI, Koordinator,
  Presets und App sowie der tote Main-Thread-Raumpfad. Klang nur noch über
  Audio Units. Rund 21 500 Zeilen weniger (10 200 Quelle, 11 100 Tests).
- Verschoben (unverändert): `AdvanceTicker` nach MonitorKit,
  `ThereminMappingConfiguration` und `EffectInserts` nach SynthAudio.
- AU-Hosting, Release-Barriere, Legacy-Kern und Cutover unverändert; alte
  Presets mit Theremin-/Synth-Feldern bleiben lesbar, das Format ist gleich.
- Tests 3440 → 2910 (537 Fälle gelöschten Codes entfallen, 7 neu, kein neuer
  Skip).

**UMBAU-P2 Domäne (05.10.)**

- `PlanariumDomain` besitzt den bisherigen Compiler, V2-Rechenkern,
  Detektion, Polargeometrie und Notenbuch. Raumkonturwerte und ihre
  Messwertreduktion sind reine Rechnung; synchronisierter Speicher und
  Aufnahme bleiben vorübergehend im Kit.
- Neues vollständiges `InstrumentDocument` mit Detektion, Kanal,
  Plug-in-Zuständen, geordneten Inserts, Pegel, MIDI-Ziel und Revision;
  Kompilierung erzeugt einen unveränderlichen Snapshot.
- `PlayEngine` berechnet Musikereignisse aus Wertzustand und Eingabe.
  Lösematrix, gemeinsame Notenträger, Overlap, Eingangsverlust und
  Wiedereinstieg werden reproduzierbar geprüft.
- Legacy-Spielpfad bleibt bis zum Anschluss der Runtime erhalten;
  Oberfläche, Presetformat und Geräte-/Audiozugriffe bleiben unverändert.

### 01.–04.10.2026: Klang vor Optik, Bedienung, Architekturumbau

**Oberfläche englisch, Teil 1 (ENGLISCH-TOOLTIPS, 05.10.)**

- Tonnamen englisch aus einer Quelle: B statt H, B♭; der Parser lehnt H ab.
  Presets bleiben MIDI-nummernbasiert, keine Migration.
- Messfeld, Detektion, Inspector, Kanalzug und Diagnose englisch mit Tooltips
  an jedem dieser Bedienelemente. Der Bestätigungs-Tooltip rechnet seine
  Verzögerung aus der Detektionslogik.
- Detektionsleiste mit sprechenden Namen statt S-Kürzeln. Werkzeug- und
  Detektionsleiste fließen in Gruppen um, ohne Abschneiden oder Überlappen
  (geprüft bei 1190, 900 und 420 pt sowie in der echten App).
- Inspector: Ausgang und Steuerung untereinander, Klaviatur flacher,
  Tastenbeschriftung einzeilig, „1 cell“.
- Trefferflächen: Kanalname, MAIN-Warnung, Farbpunkt (18 pt), Symbolknöpfe,
  Portzeile und Auswahlzeilen voll klickbar; ein Regeltest erkennt das alte
  PANIC-Muster.
- „Copy diagnostic report“ immer erreichbar.
- Toter Code gelöscht: `MIDIOutputCardView`, `AudioUnitsCardView`,
  `ZoneInsertsView`.
- Offen (Qwen): übrige Texte (Eingang, Presets, Akkordnamen, Zellinfo).

**Preset-Laden, Teil 1 (FEHLERBEHEBUNG-2, 05.10.)**

- Preset A → B lädt wieder: Der Klangkern übernimmt den neuen Stand, Zellen
  von B leuchten, Profile werden angenommen. Ursache: Das Laufzeitmodell
  meldete jede Dokumentänderung ein zweites Mal am Snapshot vorbei; der
  Kernautomat zählte dadurch eine Revision weiter und wies den echten
  Snapshot als veraltet ab. Jetzt gibt es genau eine Revisionsquelle, die
  Komposition.
- Nach erfolgreicher Raumaufnahme ist die Raumkontur sofort aktiv.
- Plug-in-Fenster folgen der Editorgröße in beide Richtungen.
- Profil und aktive Zellen laufen über das Anzeigemodell statt über das
  appweite Laufzeitobjekt (weniger SwiftUI-Neuauswertung je Profil).
- Diagnose: „snapshot sent“ getrennt von „snapshot installed“
  (Automatenbestätigung), jeder Automatenschritt mit Token,
  AU-Ressourcenphasen, Preset-Apply-Grenzen.

**Preset-Laden, Teil 2 (FEHLERBEHEBUNG-2, 05.10.)**

- Leerlauf: Die App zeichnet ohne Messung nicht mehr ständig neu.
  Diagnose-Takt nur, solange die Diagnose sichtbar ist; Pegelanzeigen nur bei
  laufender Ausgabe. Gemessen: Prozess-CPU 22 % → 0,9 %, Hauptthread 71 % →
  97 % frei.
- Effekt-Plug-ins (z. B. Temperance): Der Editor wird je Instanz einmal
  angefordert und lebt genau so lange wie die Instanz. Plug-ins liefern ihn
  nur einmal. Ob das die Ursache für „Temperance lässt sich nicht
  einschalten“ war, klärt der Owner-Prüflauf.
- Vertrag: Ein fehlendes oder noch nicht bereites Instrument-Plug-in hält die
  Messung nicht an. Profile werden angenommen, Noten zählen als „Plug-in-Ausgang
  nicht bereit“, das Plug-in bindet nach, sobald es bereit ist.
- Raumaufnahme mit dem Simulationsprofil belegt: 100 %, passende Geometrie,
  Kontur aktiv, gefilterte Punkte verschwinden.

**Fehlerbehebung nach dem Owner-Diagnoselauf (FEHLERBEHEBUNG-1, 04.10.)**

- „Keine Auswertung mehr“ nach Preset-Laden oder Detektionswechsel: zwei
  Ursachen behoben.
  - Der Übergangsautomat verwarf die aktuelle Quittung als veraltet, wenn
    während einer offenen Barriere eine neue Vorbereitung begann.
  - Eine Dokumentbarriere ohne musikalische Änderung bekam nie einen neuen
    Stand. Jetzt garantiert eine zentrale Stelle genau einen Abschluss je
    Barriere.
  - Detektionsregler wirken ohne Barriere und ohne Note-Off.
- Plug-in-Oberfläche: Der Editor-Controller wird je Instanz einmal
  angefordert und wiederverwendet. Plug-ins liefern ihn nur einmal, belegt
  am Apple-DLS-Prüfstand und an UADx Opal.
- Der Repräsentant liegt immer auf einem gemessenen Punkt seines Objekts.
  Eine Wandecke löst keine Zelle im leeren Raum mehr aus.
- „Raum aufnehmen“ ist beliebig oft möglich.
- Diagnose:
  - eigener Ring für seltene Ereignisse;
  - Release-Gründe mit Lücke bis zum nächsten Note-On;
  - Snapshot-Installationen mit Auslöser.

**Erkennung (BLOCK-C-DETEKTION, 04.10.)**

- Eine einstellbare Detektionskette wählt die Zelle aus den Rohpunkten:
  Filter, Repräsentant (Mittelwert bzw. nächster Punkt), Gruppierung,
  Halterand und Bestätigung nach 1 oder 2 Scans. Sie läuft im Klang- und im
  Anzeigeweg, und ein Regler wirkt ab dem nächsten Profil ohne
  Neuinstallation.
- Raumkontur: den leeren Raum etwa 2 s aufnehmen; danach zählt nur, was
  davor liegt. Toleranz 1–30 cm, Konturlinie im Messfeld. Die Kontur gilt
  nur bis Programmende, weil der Scanner mobil ist. Passt sie nicht zur
  Geometrie, ist sie sichtbar inaktiv.
- Inspector: Ausgang und Steuert stehen wieder als Dropdowns unter jeder
  Ebene. Das Kontextmenü bietet dieselben Ziele, auch AU-Parameter. Die
  ganze Ebenenzeile ist klickbar.
- Das Plug-in-Fenster folgt der Plug-in-Größe und lässt sich vergrößern.

**Klang und Ausgabe**

Der räumliche Klangpfad läuft jetzt seriell außerhalb des Main-Threads
(KVO-1 bis KVO-3p). Damit ist der Rückstau von 7,3 Hz vom 01.10. beseitigt.
Im Einzelnen:
- Ressourcen für MIDI, AU und Beenden laufen über Transaktionen.
- Panic holt das Planarium ohne Neustart aus dem Fehlerzustand.
- Beenden verklemmt nicht mehr.
- Die Audiokette lässt sich bei laufendem Ton umbauen (Instrument und Effekte
  wechseln). Nach einem Instrument- oder FX-Wechsel verstummt der Klang nicht
  mehr.
- Die AU-Parameterliste folgt einem nachgereichten Parameterbaum.
- Der MIDI-Ausgang folgt dem Dokument. Ein AU-Umbau lässt gehaltene externe
  MIDI-Noten unberührt (ARCH-2a). Ein Wechsel des MIDI-Ziels beendet sie
  weiterhin sauber.
- Räumliche Zellen sprechen nur noch Instrumente und Effekte an, die
  tatsächlich im laufenden Klangweg hängen (ARCH-2b). Fällt der Klangweg
  aus, verliert die Zelle ihre AU-Bindung sichtbar. Vorher hat sie still
  „erfolgreich“ ins Leere gesendet.
- Nach einem fehlgeschlagenen Start bringt erneutes Laden desselben
  Instruments den Klangweg wieder in Gang (ARCH-2c).
- Ein geladenes Instrument schaltet die Ausgabe einmal automatisch ein. Ein
  ausgeschaltetes Insert erscheint grau wie in Logic.

- Kanalzug und Ebenen (KANALZUG-1):
  - Der Inspector passt wieder in seine 220-pt-Spalte. Ein Test erkennt
    einen Überlauf.
  - Der Abschnitt EBENE entfällt. Umbenennen, Farbe, Ausgang und
    Steuerung laufen über Rechtsklick auf die Ebenenzeile, Doppelklick
    benennt um, und der Farbpunkt öffnet die Palette.
  - Der Kanalname heißt „PLANARIUM“. Name und Farbe sind per Rechtsklick
    änderbar, gespeichert im Dokument und rückgängig machbar.
  - Fader, Skala und Pegel stehen mittig. Der Pegel ist Stereo (L/R). Der
    Kanalzug endet bündig unten.
  - „MAIN“ öffnet eine Karte mit Ausgabegerät und Rate und zeigt bei
    Meldungen ein Warnzeichen.
- Der Inspector ist kompakter (INSPECTOR-KOMPAKT):
  - Ausgang und Steuerung stehen nur noch einmal.
  - Grundton (bei Tonleitern ohne Oktave) und Skala teilen sich eine Zeile,
    der Notenbereich steht als „von … bis …“ in einer Zeile.
  - Haken, X und Würfel sind Symbolknöpfe.
  - Der Zellwert lässt sich eintippen („G4“, „Fis3“).
  - Jede Klaviaturtaste ist klickbar, vorher reagierte nur das linke C
    (KLAVIATUR-TREFFER).
- Der Inspector zeigt das Ziel ohne die Vorsätze „Ausgang:“ und
  „Steuert: AU-Instrument · “ (LABELS-KURZ).

- Der ganze Klangweg läuft im Takt des Ausgabegeräts. Vorher blieb ein
  AU-Instrument auf 44,1 kHz, während das Gerät mit 48 kHz lief, und das
  klang kratzig (KLANG-SAUBER). Lehnt ein Plug-in die Rate ab, rechnet ein
  sichtbarer Konverter genau an dieser Stelle um.
- Ein Raten- oder Gerätewechsel während des Spielens baut den Klangweg im
  neuen Takt neu auf. Die Plug-ins bleiben dabei geladen und starten selbst
  neu. Lehnt eines das ab, wird es mit seinen Einstellungen neu geladen.
  Lief der Ton vorher, läuft er danach weiter (KLANG-WECHSEL).
- Ausgabegerät und Abtastrate des Geräts sind im Kanalzug wählbar. Die
  Systemausgabe folgt dem Mac, und angesteckte Geräte erscheinen von selbst.
  Diagnose und Kanalzug melden gemischte Abtastraten.

**Version und Signatur**

- Jedes Bundle trägt die Build-Nummer aus der Git-Commitzahl und den
  Code-Stand (`PlanariumGitRevision`, mit `+lokal` bzw. `unbekannt`). Beides
  erscheint in „Über Planarium“, in der Diagnose und am Anfang des
  Messberichts (VERSION-1).
- Das Bundle wird stabil mit der Apple-Development-Identität signiert, per
  Hash statt per Name und ohne Hardened Runtime. Die macOS-Abfrage
  „Dokumente“ für geladene Plug-ins muss deshalb nur einmal erlaubt werden
  (SIGNATUR-1).

**Messung und Diagnose**

- Messfenster mit Ownerkanten.
- Datenfreier Messkern (ARCH-0): Zeiten von Eingang, Warten, Rechnen und
  Senke, getrennt gemessen. Dazu Raten und ein Ereignisring.
- „Messbericht kopieren“ im Diagnosebereich.
- Messanzeige in Alltagssprache (ARCH-3): Raten, Warten, Rechnen, Senke,
  Anzeige und das Bildalter von der Hand bis auf den Schirm. Dazu Quelle,
  Baudrate und Framegröße.

**Editor und Inspector**

- Tonhöhe bzw. Wert in den Zellen.
- „Auf Messung zoomen“.
- Echte Klaviatur im Zuweisen-Popover und im Inspector.
- Widerrufen und Wiederholen mit benannten Menüeinträgen.
- Löschen und Esc arbeiten sauber.
- Messfeldbefehle wirken über den Fokus.
- Raster 1–5 cm.
- Die Anzeige ist vom Klang entkoppelt. Das Messfeld läuft beim Ziehen und
  bei offenen Menüs weiter.
- Ein Anzeigetakt mit 25 Hz statt 12,5 Hz (Block B). Messlinie und leuchtende
  Zellen gehören immer zum selben Messbild. Unnötige Neuzeichnungen sind
  entfallen.
- Inspector:
  - Ebenen oben, Eigenschaften darunter.
  - Eine Ebene hat ein Ziel.
  - Echter MIDI-Kanal, wahrer Ebenenstand, Zellinfo zur angeklickten Zelle.
  - Beschriftungen Ausgang, Steuert, Kein Ausgang.
- Kanalzug:
  - Eine dB-Kennlinie für Fader, Anzeige und Messer.
  - Bedienbarer Pan.
  - MIDI-Gerät nur dann, wenn eine Ebene MIDI nutzt.
  - Kanalzug und Inspector reichen bündig bis unten.
- Panic- und Ausgangsknöpfe sind auf der ganzen Fläche klickbar.

**App**

- Rückfrage beim Beenden, Ersetzen und Löschen mit ungesicherten Änderungen.
- Es läuft nur eine Planarium-Instanz.
- Das neue Planarium-Logo ist das App-Icon.
- Der Masterfader springt nicht mehr und ist per Pfeiltasten bedienbar.

**iPhone-Simulation**

- Echter Verbindungsstatus.
- Der Messfeldrand wird standardmäßig gesendet.
- Netzwerktransport mit Modusbefehlen.
- Der Messmodus ist aus der Simulationsleiste umschaltbar, dazu die Auswahl
  „Bei 90 Punkten“.
- Die Anzeige läuft im 25-Hz-Takt.

**Intern, ohne sichtbare Wirkung**

- Gemeinsame Composition-Root für App und Tests (ARCH-1).
- V2-Laufzeitkern, Geräteraster-Wertpläne und Preset-Format 4 sind gebaut,
  aber noch nicht angeschlossen (ARCH-8).

### Hinzugefügt (Geräteraster, noch ohne Produktionsanschluss bis M-6)

- **Preset-Format 4 und ein Leser für Version 1–4** (M-2c1/M-2c2): neue
  Presets speichern das räumliche Dokument auf dem 1-cm-Geräteraster; alte
  Presets werden über den Kompatibilitätsimport gelesen, Verluste werden
  geordnet gemeldet. Die App liest und schreibt weiterhin Format 3.
- **Kompiliertes Instrument** (M-3a): bemalte Zellen in einem Index je
  Scannerrichtung; eine Anfrage findet die getroffene Zelle in wenigen
  Schritten, unabhängig von der Zellzahl.
- **Zellwahl auf dem Geräteraster** (M-4a1): je Ebene die nächste Zelle mit
  derselben Flatterbremse wie bisher (5 cm, 2 Richtungen, 2 Profile); bis
  zum Gerätebeleg nur für den vollen 361-Punkt-Scan.
- **Bildschirmgeometrie für Feinzellen und grobe Malzellen** (M-5a/M-5b):
  Zelle unter dem Mauszeiger, Zellumriss, Blöcke aus Feinzellen.
- **Grobblock bemalen und Anzeigeplan** (E-1/R-1): ein Grobblock wird in
  einem Schritt auf eine Ebene gemalt (Größenprüfung vorher, Sperre wird
  beachtet); der Anzeigeplan liefert die sichtbaren bemalten Zellen in
  Zeichenreihenfolge.

### Behoben

- **Thread-Prüfung (TSan) läuft vollständig:** der vermeintlich hängende
  Lauf brauchte nur länger als das gesetzte Zeitlimit (154 s); acht
  Warnungen in zwei Testhelfern sind behoben.

### Geändert

- **Verbindungsfreigabe bleibt nicht mehr hinter Messwerten hängen:** Der
  Lesethread stellt höchstens einen Main-Thread-Auftrag gleichzeitig zu. Eine
  echte Portfreigabe entfernt noch wartende alte Leseereignisse und kann nach
  dem aktuell bearbeiteten Ereignis übernommen werden; der Port gilt weiterhin
  erst nach dem realen `close` als frei.
- **MIDI-Ziel direkt im Ebenen-Inspector:** Zielgerät und Start/Stopp stehen
  jetzt oben im Ausgangsbereich und bleiben auch bei laufendem Scanner
  bedienbar. Ein Zielwechsel während laufendem MIDI sendet zuerst Panic/Stop
  ans alte Ziel und startet anschließend am neuen Ziel.
- **AU-Editorfenster folgen der echten Instanz:** Herstelleransichten öffnen
  in ihrer nativen Inhaltsgröße, erhalten Tastatur-/Mausfokus und schließen
  beim Entfernen oder Wechseln des zugehörigen Instruments beziehungsweise
  Effekt-Racks.
- **Nur ein Cursorbesitzer im Messfeld:** Während der Zeiger im Canvas liegt,
  sind konkurrierende Fenster-Cursorrechtecke ausgesetzt; Stift, Radierer oder
  Hand flackern dadurch nicht mehr abwechselnd mit dem Standardpfeil.

- **Koordinatenwechsel wandelt jetzt die Instrumenttopologie:** `XY` und
  `rφ` sind nicht länger zwei parallel aktive Masken. Beim Umschalten wird
  jede belegte Zelle über ihren metrischen Mittelpunkt in eine echte Zelle
  des Zielrasters eingerastet; Zellaktionen werden mitgenommen und bei einer
  Kollision verlustfrei zusammengeführt. Danach werden die Zellen der alten
  Topologie entfernt. Der aktive Modus gehört zum gespeicherten Workspace,
  wird von Presets erhalten und ist die einzige Wahrheit für Darstellung,
  Gesten und Audio-/MIDI-Auswertung. Im Polarmodus kann deshalb an einem
  Messwinkel nur der getroffene Ringsektor auslösen; ein radial dahinter
  liegender Sektor bleibt verdeckt.
- **Echte Audio-Unit-Oberflächen statt Platzhalter:** Instrument- und
  Effekt-Slots öffnen keinen nachgebauten Studiogeräte-Dialog mehr. AUv3 nutzt
  den Hersteller-View-Controller; klassische AUv2-Plug-ins werden über ihre
  Cocoa-UI geladen. Fehlt eine eigene Herstelleransicht, erscheint Apples
  direkt an dieselbe Instanz gebundene Parameteransicht `AUGenericView`. Die
  frühere Platzhalter- und Reglerimplementierung wurde vollständig entfernt.
- **Werkzeugcursor wieder sichtbar und weiß:** Stift, Radierer und Hand werden
  nach SwiftUIs eigener Ereignisverarbeitung nochmals positionsgeprüft gesetzt,
  sodass ein Canvas-Update sie nicht wieder durch den Standardpfeil ersetzt.
  Die Symbole sind für das dunkle Bühnen-Theme jetzt weiß statt orange.
- **Trackpad-Navigation entkoppelt:** Zwei Finger ohne Drücken zoomen wie
  bisher. Erst ein Zwei-Finger-Klick mit anschließendem Drag verschiebt den
  Messfeldinhalt horizontal und vertikal. Pinch und Mausrad bleiben ebenfalls
  Zoomgesten. Eine laufende Mal-/Radier-/Handgeste kann nicht gleichzeitig
  durch den gedrückten Trackpad-Drag verschoben werden.
- **Polarraster ohne unfüllbare Lücken:** Ringsektoren besitzen jetzt eigene,
  persistierbare Ring-/Winkeladressen statt einer verlustbehafteten Projektion
  kartesischer Zellmittelpunkte. Zeichnen, Radieren, Zell-Overrides,
  Rastermigration und die direkte Audio-/MIDI-Trefferauswertung verwenden
  denselben Zelltyp. Alte Presets ohne Polardaten bleiben lesbar.
- **Durchgehend dunkles Bühnen-Theme:** Die Hauptarbeitsfläche erzwingt eine
  dunkle macOS-Darstellung und besitzt feste, systemunabhängige Farben für
  Fenstergrund, Messfeld, Raster und Rahmen. Ein hell konfiguriertes macOS
  kann den Canvas damit nicht mehr blendend weiß darstellen; Seitenleisten,
  Toolbar, Inspector und Kanalzug folgen demselben dunklen Kontrastvertrag.
  Messfeldraster, Scanlinie, Scannerursprung, Bedientint und neue erste Ebene
  verwenden die originalen Amber-/Vintagewerte aus FIRSTofFIFTH.
- **Werkzeugcursor gegen Canvas-Neuzeichnungen gehärtet:** Stift, Radierer
  und Hand verlassen sich nicht mehr nur auf AppKit-Cursorrechtecke einer
  absichtlich hit-test-unsichtbaren Overlay-View. Ein nicht konsumierender
  lokaler Mausbeobachter setzt das aktive Werkzeug beim Betreten, Bewegen,
  Ziehen und Werkzeugwechsel erneut; SwiftUI-Neuzeichnungen können es damit
  nicht dauerhaft auf den Pfeil zurücksetzen.
  Alle drei Werkzeugcursor tragen festes FIRSTofFIFTH-Amber und bleiben damit
  auf dem dunklen Bühnen-Canvas klar erkennbar.
- **Messfeld wahlweise kartesisch oder polar:** Der Viewport lässt sich über
  `XY`/`rφ` umschalten. Beide Rastertopologien liegen im selben metrischen
  Raum und werden unmittelbar gegen dieselben Scannerpunkte ausgewertet;
  Polarflächen sind echte Ringsektoren mit zwei Radien und zwei Kreisbögen.
  Die Rasterlinien beider Ansichten sind für die Bühnenbedienung
  deutlich kräftiger. Wird ein Ringsektor am äußeren Bogen breiter als seine
  1,5-fache radiale Höhe, teilt ihn das Polarraster automatisch in gleich
  breite Winkelsegmente. Bemalte Flächen rasten exakt auf diese Ring- und
  Winkelgrenzen ein; die frühere quadratisch wirkende Näherung ist entfernt.
  Die kartesische Ansicht zeigt passend dazu ein reines Linienraster ohne
  Schachbrettfüllung.
  Polarraster, Kontur, Spiegelung, Pan/Zoom sowie Malen und Radieren arbeiten
  im gemeinsamen Viewport. Es entsteht kein zweiter Workspace und keine
  abweichende Audio- oder MIDI-Auswertung.
- **Spielpfad und Kanalzug von Altlasten befreit:** Das Rasterinstrument
  startet keinen parallelen 60-Hz-Legacy-Thereminpfad mehr; Scannerwerte
  erreichen Audio weiterhin mit voller Rate, während die sichtbare Kontur
  höchstens mit 12,5 Hz aktualisiert wird. Ein einzelnes inaktives Profil
  löst gehaltene Noten nicht mehr aus und sofort wieder ein. Der Kanalzug
  enthält nur noch den aktiven HELMUT-/AU-Pfad; 883 Zeilen des verworfenen
  internen Synth-/Delay-/Hall-/Diagnoseentwurfs und dessen unnötige
  View-Eingaben sind entfernt. Die Pegelanzeige liest nun einen echten,
  lock-frei übertragenen Peak des Hauptmixers statt eines festen Demowerts.
  AU-Fenster- und verzögerte Note-off-Callbacks besitzen explizite
  Main-Queue-Übergaben. Der automatische Einzeladapter-Weg verwendet die
  vorhandene sichere Erkennung für 500.000/38.400/9.600 Baud statt des alten
  festen 38.400-Baud-Starts. Die Hardware-Gegenprobe bleibt nach dem
  Abziehen des Scanners offen.
- **Ebenen-Inspector auf einen Bedienweg reduziert:** Die Bedienfolge lautet
  jetzt Ausgang, Ebene, Belegung und optional einzelne Zelle. Doppelte MIDI-/
  AU- und CC-Aktionen im früheren Assistenten sind entfallen. Dunkle Felder und
  Menüs besitzen explizit hellen Text; der Ebenenname bleibt auch im hellen
  macOS-Erscheinungsbild lesbar. Musikalische Werte werden als Notennamen
  (`C4`, `C♯4`, `H4`) statt als rohe MIDI-Zahlen gewählt. Tonleiter,
  Zufallsbelegung und zehn Akkordtypen einschließlich Haltemodus sind direkt
  auswählbar; dasselbe gilt für eine abweichende Einzelzelle.
- **Native AU-Oberflächen zuverlässig im Vordergrund:** AU-Instrument- und
  Effektfenster werden nach ihrer asynchronen Bereitstellung erneut aktiviert
  und vor das Hauptfenster geholt. Der reale Bundle-Test öffnete die native
  AUSampler-Oberfläche. Logic-interne, nicht systemweit als `aumu`
  registrierte Instrumente bleiben technisch bedingt unsichtbar.
- **SICK-043 offline implementiert:** Der Inspector verwaltet persistierbare
  Ebenen mit Farbe, Sichtbarkeit, Aktivität, Solo, Sperre, Zellmasken und
  beliebig vielen Routings. Bemalte Rasterzellen steuern Noten, Akkorde,
  MIDI-CC, Pitch Bend, Channel Pressure und exakte Parameteradressen geladener
  AU-Instrumente/AU-Effekte; Skalen-, Zufalls- und Verlaufsassistenten sowie
  Zellüberschreibungen und konfliktbewusste Rastermigration sind integriert.
  Der neue Modus „Halten bis nächster Ton“ hält Akkorde/Borduntöne kanalweit,
  bis eine neue gehaltene Fläche sie ersetzt. Eine eigene All-Notes-Off-Fläche
  löst nur beim Betreten bekannte Note-offs und CC 123 aus. Der MIDI-Kanal ist
  bei 1–16 wählbar. Presetformat 3 speichert den gesamten Workspace.
- **Zelleninstrument ist jetzt der normale Audiostart:** „Audio starten“ und
  der AU-Instrument-Schalter verlangen keine alten Pitch-/Volume-/Gate-Zonen
  mehr. Der eine bestehende Audiohost bleibt gekapselt im Performance-
  Controller; Benutzerstopp, Systemschlaf und App-Ende lösen zuerst sämtliche
  vom Zelleninstrument gehaltenen Noten. Der Kanalzug zeigt live die Zahl der
  aktiven Routings und gehaltenen Noten.
- **SICK-042/H1 abgenommen:** Musikalische Kontrollziele
  besitzen jetzt autoritative, geordnete Ebenenstapel. Kontinuierliche Ebenen
  unterstützen erste aktive, Maximum und Minimum; diskrete Ziele und Gate
  bleiben strukturell bei erster aktiver Ebene. Der bestehende eine Profilweg
  wertet alle Ebenen aus. Entfernen, Deaktivieren, Flächenartwechsel und
  Presetwechsel nutzen die vorhandenen Lösewege; ungültige Mischungen werden
  atomar und sichtbar verweigert. Der Kanalzug zeigt Ebenenauswahl und
  zulässige Mischregel. Presetformat 2 persistiert alle Stapel; Format 1
  migriert auf je eine Ebene. Offline-Tests, vollständige Suite, strikter
  Build, Bundlebau und sichtbare App-Prüfung sind ausgeführt. Kein Scanner und
  kein realer Audio-/MIDI-Ausgang wurden benutzt. Unabhängiger Haupt- und
  K1-Review bestätigen den Vertrag; die Ebenenpriorität ist zusätzlich
  sichtbar nummeriert und per Hoch-/Runter-Piktogrammen bedienbar.
- **Logic-artige AU-Slots, HELMUT-Kanalzug und Werkzeugcursor:** Die zunächst frei entworfene
  196-pt-Karte ist durch die HELMUT-R340-Geometrie ersetzt: 176-pt-Inspector
  links, eigene 40-pt-dB-Skalenrinne und 67-pt-Strip ganz rechts. Inspector
  und Strip verwenden denselben geriffelten 17 × 35-pt-Logic-Fadergriff;
  der echte Masterwert ist an beide Darstellungen gebunden. PREAMP, PEGEL,
  EQ, DYNAMIK, INSERT und GRUPPEN folgen der Referenzreihenfolge. Die
  Inserts übernehmen zusätzlich den HELMUT-R315-Hoververtrag: In Ruhe ist nur
  der Name sichtbar, beim Hover erscheinen getrennt ON/OFF, Einstellungen und
  Auswahl. Jede Teilfläche ist auch für VoiceOver und UI-Tests einzeln
  adressierbar. Der Instrument-Slot und die dynamische Audio-FX-Liste beginnen leer;
  sie bieten ausschließlich die auf dem Mac gefundenen AU-Instrumente bzw.
  AU-Effekte an. Ein Sammel-Rack sowie die eigenen Synth-, Delay- und
  Hall-Einträge sind aus diesem Bedienpfad entfernt. Belegte AU-FX-Slots
  laden gezielt genau die gewählte Komponente und öffnen ein eigenes,
  nichtmodales Gerätefenster. AU-Instrumente werden katalogisiert, als echte
  `AVAudioUnit`-Instanz geladen und anstelle der internen Renderquelle in den
  Audio-Graphen gehängt. Derselbe ausgewertete Pitch-/Gate-/Controllerstrom
  erreicht sie als MIDI; Auswahl, Vorbereitung, Graphstart und Fehler bleiben
  getrennt und sichtbar. Offen ist nur noch das Einbetten der nativen
  Herstelleroberfläche. Der Inspector beherbergt inzwischen den
  Ebenen-Manager.
  Die kompaktere rechte Arbeitszone gibt den frei gewordenen Platz an das
  Messfeld zurück.
  Im Messfeld folgt der Cursor dem gewählten Stift-, Radierer- oder
  Verschieben-Werkzeug. Rasterweiten reichen bis 2 cm.
- **Automatische Scanner-Portsuche:** Die Verbindungsleiste kann eine feste
  Momentaufnahme aller angebotenen seriellen Anschlüsse sequenziell prüfen
  und zeigt dabei den aktuellen Port als `n/m`. Sie verwendet pro Kandidat
  denselben Standardverbindungslauf wie die manuelle Auswahl, gibt den Port
  vor dem nächsten Versuch frei und stoppt am ersten belegten Scanner. Ein
  konkreter Scannerfehler bleibt sichtbar und wird nicht durch weitere
  Kandidaten überschrieben.

- **Kartesischer Instrument-Arbeitsplatz:** Das Messfeld arbeitet jetzt in
  Metern auf einem variablen Schachbrettraster. Zellen lassen sich lückenlos
  malen und löschen; Pan und Zoom verändern ausschließlich die Ansicht, und
  ein Rasterwechsel löscht bemalte Zellen nur nach Bestätigung. Die sichtbare
  Aktualisierung ist auf 12,5 Hz begrenzt, ohne Profile oder Audio zu
  drosseln. Predictor/Glättung sind im aktiven Produktpfad abgeschaltet,
  während Input-Loss weiterhin sicher Gate-Off auslöst. Rechts stehen ein
  kompakter Kanalzug und ein eigener Inspector nebeneinander; schmale Fenster
  bleiben scrollbar bedienbar. Alte polare Zonen werden nicht still in das
  neue Raster migriert.

- **Projektweite PLS-Schreibfreigabe dokumentiert:** Die abgekündigten
  PLS-Scanner werden hier nicht mehr für Sicherheitsaufgaben eingesetzt. Der
  Owner erlaubt deshalb Schreibzugriffe am Projektgerät einschließlich Modus,
  Baudrate sowie Schutz- und Warnfeldern. Das öffentlich dokumentierte
  Standardpasswort gilt nicht als Secret. Typisierte Produktpfade,
  vollständige Entwicklungsprotokolle und Read-back bleiben erhalten; daraus
  wird keine Sicherheits- oder Zertifizierungsaussage abgeleitet.

- **Scanner-Basis bleibt beim Zoomen unten:** Die graue Orientierungslinie
  gehört jetzt fest zum unteren Canvasrand und nicht mehr zur verschobenen
  Weltprojektion. Messkurve, Zonen und Kreisbogen bleiben weiterhin gemeinsam,
  isotrop und formtreu zoombar; nur die Basislinie wandert beim Einpassen,
  Zoomen oder Verschieben nicht mehr mit.

- **Scanner-Setup speist jetzt automatisch das Hauptfenster:** Ein sicher
  belegter MMK-Strom ist unmittelbar die Verbindung der gesamten App; ein
  zusätzlicher Übergabeknopf entfällt. Die App schließt zuerst den TX-fähigen
  Setup-Port und öffnet danach denselben Anschluss mit der real belegten
  Baudrate für RX. Profile erscheinen im Messfeld und erreichen Zonen, Audio
  und MIDI. Auch ein späteres „Trennen“/„Verbinden“ im Hauptfenster verwendet
  weiter die belegte Rate statt unbemerkt auf den alten festen
  38.400-Baud-Ablauf zurückzufallen. Bei einem frischen App-Start führt schon
  „Verbinden“ im Hauptfenster den sicheren Erkennungs-/MMK-Ablauf aus; die
  frühere zweite Verbindungssemantik ist aus der Oberfläche entfernt.

- **Unterbrechungsfester Scanner-Setup-Ablauf:** Die
  Scanner-Entwicklung erkennt den Ist-Zustand jetzt unabhängig von einem
  früheren App-Lauf bei 500.000, 38.400 oder 9.600 Baud. Ein neuer sicherer
  Bedienvorgang beendet bei Bedarf den B0-Strom, belegt Identität und
  Anmeldung, wechselt die Baudrate, öffnet den Host neu und gibt den Port erst
  nach einem CRC-gültigen MMK-Profil frei. Bei einem unklaren Abbruch wird die
  Rate neu erkannt statt der alte UI-Wert weiterverwendet. Reale Headless-
  Nachweise decken 500.000 → 38.400 → 9.600 → 500.000 sowie zwei
  voneinander unabhängige Prozessstarts ab. `0x27` bleibt experimentell und
  außerhalb dieses sicheren Ablaufs. Die reale Gegenprobe mit Zieladresse
  `01` stoppte den Messstrom nicht und wurde vor Anmeldung/Baudkommando sicher
  abgebrochen; deshalb ist `00` die belegte Vorgabe, weitere Adressen bleiben
  ausdrücklich einstellbar.

- **RS-422/500-kBaud und manuelle Messmodi direkt in der Theremin-App:**
  Die Einstellungen besitzen nun den Bereich „Scanner-Entwicklung“ mit
  9600, 38.400 und exakt 500.000 Baud, einstellbarer Zieladresse,
  Einrichtungs-/Login-Schritten, Baudcodes `20 42`/`20 40`/`20 48`, MMK
  (`20 20`), Ruhe/Anfrage (`20 25`) sowie mittigen 90°-/120°- und freien
  `20 27`-Teilbereichen. Der aktuelle Portzustand, gültiger B0-Strom,
  Punktzahl und gemessene Profilrate bleiben sichtbar; TX/RX wird live
  protokolliert. 500.000 Baud verwendet unter Darwin `IOSSIOSPEED` und den
  hardwarebelegten Abstand von 55 µs zwischen Hostbytes. Der 90°-/120°-Weg
  ist sichtbar experimentell: 500 kBaud + MMK ist real positiv belegt,
  `0x27` dagegen noch nicht. Eine ausdrücklich gestartete
  Theremin-Messverbindung übernimmt die gewählte Rate unverändert und führt
  ihre B0-Profile durch den bestehenden Zonen-, Audio- und MIDI-Pfad.

- **Eigenständige, vollständig handbediente Setup-Konsole:** `SickPLSSetup`
  öffnet 9600 oder 38.400 Baud explizit, bietet die sechs dokumentierten
  Schritte einzeln an und zeigt TX, RX sowie erkannte CRC-gültige Frames live.
  Die Zieladresse ist als Hexwert einstellbar (Vorgabe `01`); `81` bleibt als
  Scanner-Antwortadresse gesperrt. Ein separates Feld sendet vollständige,
  CRC-gültige Telegramme. Kennwortbytes werden im Liveprotokoll und Export
  maskiert. Es gibt keine automatische Sendefolge.
  Ein zweites Fenster zeigt den aktuellen B0-Messverlauf mit Profilzahl,
  Punktzahl sowie Rohwert-Minimum und -Maximum. Kommunikations- und
  Messfenster teilen exakt dieselbe serielle Sitzung. Roh-RX und B0 lassen
  sich im Kommunikationsfenster ausblenden, ohne den vollständigen Mitschnitt
  oder Export zu verkürzen.
  Das öffentliche Standardkennwort ist vorbelegt. Ein während eines laufenden
  Schreibvorgangs angeklickter Befehl verschwindet nicht mehr still: Er wird
  sichtbar als nicht gesendet protokolliert und nicht nachträglich ausgeführt.

- **Scanner-Einrichtung wieder vollständig handbedient:** Der automatische
  9600-Fallback ist im produktiven „Verbinden“-Pfad abgeschaltet; dieser
  übernimmt nur noch einen bereits laufenden B0-Messstrom und sendet andernfalls
  nichts. Im Support-Bereich stehen die belegten Schritte einzeln und in fester
  Reihenfolge bereit: 9600 prüfen, `20 30` an Adresse 1, `20 00` an Adresse 1,
  38.400 einstellen, Port bei 38.400 neu öffnen und prüfen, MMK starten. Jeder
  bestätigte Schritt hält an; auch ein Login-Timeout wiederholt nicht ohne neuen
  Klick. Ein redigierter Export protokolliert Relativzeit, Schritt, Versuch,
  Adresse und klassifiziertes Ergebnis, aber weder Passwort noch Rohtelegramm.
  Grundlage ist der Abgleich mit R26 sowie den Windows-Mitschnitten C7/C10.

- **Realer Verbindungsbefund: Einstellungsmodus vor Anmeldung ergänzt:** Der
  9600-Baud-Fallback folgt jetzt der am Gerät erforderlichen Reihenfolge
  B1-Prüfung → allgemeiner Einstellungsmodus → adressierte Anmeldung →
  38.400-Baud-Umschaltung → B1-Verifikation → MMK. Ohne bestätigten
  Einstellungsmodus wird keine Anmeldung gesendet; Ablehnung, Stille und
  unlesbare Antwort bleiben eigene, redigierte Fehler. Nach dem ersten realen
  Gegenversuch wurde außerdem die aus `RepeatCounter=2` folgende Schranke
  korrigiert: erster Anmeldeversuch plus höchstens zwei identische
  Wiederholungen, jeweils erst nach dem bewährten vollständigen
  2-Sekunden-Lesefenster. Der interne Windows-Wert
  `ACKResponseTimeout=500` wird nicht unbelegt als Gesamtfrist umgedeutet.
  Telegrammreihenfolge, Portbesitz, Audit und UI-Fortschritt sind durch
  Offline-Tests belegt. Die
  vollständige Suite (2172 Tests), der strikte Concurrency-Build und ein neu
  gebautes, ad-hoc signiertes Release-Bundle für macOS 12 sind grün. Die
  physische Wiederholungsprüfung steht unmittelbar aus.

- **Supervisor-Korrektur H2/H3 des Release-Big-Bang:** Der Diagnose-CLI hält
  seinen Referenzzustand lokal und reicht ihn explizit an Hilfsfunktionen;
  `scripts/strict-concurrency-diff.sh` bewahrt und prüft den echten
  Build-Exitstatus. Ein frischer vollständiger Strict-Concurrency-Build ist
  mit 0 Diagnosen bei Baseline 0 grün. CoreMIDI-Zielverlust wird an der
  Systemgrenze als unveränderliche Übergabe auf den Main-/Kontrollthread
  gestellt, bevor Transportzustand, MIDI-Senke oder UI verändert werden; ein
  Fremdthreadtest belegt die Kante. Vollständige Testsuite und frischer
  Release-Bundlebau sind grün, die ad-hoc signierte App hält `minos 12.0` ein.
  H1 (Ebenen/Mischmatrix) und H4 (Auto-Port) bleiben offen.

- **Restroadmap auf neun vertikale Produkt-Slices nach K1 gebündelt:** Die bisherigen
  33 offenen Mikrorunden bleiben als Abnahmeanforderungen nachvollziehbar,
  werden aber nicht mehr einzeln beauftragt. App-Verbindung, reale
  Scannerabnahme, Channelstrip/Hörtest, Audio Units, gemeinsame Steuerung,
  Feldinstrument, MIDI und Presets/Spieltest werden jeweils Ende-zu-Ende
  umgesetzt und geprüft; SICK-039 bleibt die eigene
  Releasegrenze. Nur ein real belegter Frame-Batch kann zusätzlich SICK-034c
  öffnen. Streifen, Raster, Fächer und Tonartfelder bleiben im Release,
  Vektorfelder und Automation entfallen. Nach Abschluss der Opus-Korrektur
  laufen die neun verbleibenden Produktbereiche nach Owner-Entscheidung als
  eine Fable-Big-Bang-Session mit einer Gesamtübergabe.

### Hinzugefügt

- **SICK-RELEASE-BIG-BANG umgesetzt, zur Supervisor-Gesamtabnahme vorgelegt:**
  App-Verbindungsleiste als einziger Produktionsaufrufer des Standardlaufs
  (SICK-0330b); vorbereitetes Scannerprotokoll mit 034c-Schwelle (SICK-034);
  Kanalzug mit Gate-Polarität, Inserts und vollständiger Lösematrix samt
  Schlaf/Wake/Beenden (SICK-033a); Audio-Unit-Rack mit sechs Zuständen, Laden
  nur per Klick und Bypass ohne Graphmutation (SICK-033b); gemeinsame
  Treffer- und Steuerschicht mit `ControlSink`, Audio nur als Senke,
  `PitchDomain` bitgleich (SICK-033d); Streifen/Raster/Fächer/Tonartfelder
  mit sichtbarer Prognosetrennung (SICK-033e); MIDI Ende-zu-Ende mit Note-Off
  auf jedem Löseweg und Panic (SICK-036a); versionierte, atomare statische
  Presets, die lösen, setzen und nie starten (SICK-037); Schlaf/Wake-Failsafe
  über eine im Schlaf weiterlaufende Uhr, strikter Concurrency-Build ohne
  Diagnose, Signier-/Notarisierungsskript als Ownerschritt und In-App-Hilfe
  (SICK-039). Reale Belege stehen aus und wurden nicht simuliert.
- **SICK-0330a-K1 umgesetzt, zur Supervisor-Prüfung vorgelegt:** Die sechs
  Grenzfehler aus `.agent_handoff/review-sick-0330a.md` sind geschlossen.
  B0-Vorrang gilt jetzt für den vollständigen Read-Batch; ein `connect`-Aufruf
  hält über alle delegierten Teilschritte hinweg **eine** Abbruchkante (neue
  paketinterne `CommissioningExecutor.performUsingLoanedEdge(_:secret:edge:)`,
  der manuelle `perform` bleibt unverändert); ein fehlgeschlagener Portschluss
  ist überall dominant, nicht final und über genau einen realen Versuch je
  `retryClose()` auflösbar; `StandardConnectionFailure` bettet keinen rohen
  `CommissioningFailure` mehr ein, sondern bildet ihn auf vierzehn datenfreie
  Fälle ab und gibt jedem einen festen Satz (neue
  `StandardConnectionPresentation.swift`); eine schmale, injizierbare
  Fortschrittsgrenze macht jede Zwischenphase mit wahrem Portstatus sichtbar;
  die Übernahme einer bereits offenen, identitätsbelegten Verbindung ist
  `package` statt `public`. Drei echte revert-basierte Gegenproben, sauberer
  macOS-12-Build und strenger Concurrency-Build grün. Weiterhin kein echter
  Port, kein Gerät, kein TX/RX, keine SwiftUI-Integration und kein Git.

- **SICK-0330a-K1 im selben Slice nachgeschärft** (keine neue K-Runde,
  Grundlage `.agent_handoff/review-sick-0330a-k1.md`): Die öffentliche
  Standardverbindungsgrenze ist jetzt auch **strukturell** datenfrei — der
  neue, feldlose `StandardConnectionCommissioningStage` ersetzt die
  eingebettete `CommissioningPhase`, sodass kein Aufrufer eine öffentliche
  Standardphase mit einem textführenden `CommissioningFailure` mehr bauen
  kann; eine Quelltextgrenze prüft die Deklarationsrümpfe aller
  öffentlichen Standardtypen, und die Redaktionsprüfung läuft zusätzlich
  über `String(reflecting:)` und einen rekursiven `Mirror` bis Tiefe 5 mit
  vorgeschaltetem positivem Gegenbeweis am unteren Rohwert. Vor jedem
  delegierten blockierenden Abschnitt wird ein eigener, wahrer Zustand mit
  wahrem Portstatus gemeldet (`checkingStartingRate`,
  `loggingInAndSwitchingBaudRate`, `awaitingMeasurementStream`), jeweils
  nachweislich vor der zugehörigen Sendung. Die neue Meldung
  `adoptingConfirmedIdentity` nach bestätigtem B1 und vor der Übernahme
  dient als deterministischer Haltepunkt für den bis dahin fehlenden
  B1→MMK-Schließfehler- und Retrynachweis. Drei echte revert-basierte
  Gegenproben, jeweils byteidentisch wiederhergestellt; strenger
  Concurrency-Build ohne Warnungsdiff gegen
  `.agent_handoff/strict-concurrency-baseline.txt`.

- **SICK-0330a umgesetzt, zur Supervisor-Prüfung vorgelegt:** neuer
  `StandardConnectionRun` (`SickPLSCommissioningControl`) — ein
  testbarer, synchroner, vollständig injizierbarer Standardverbindungs-
  lauf, der einen gewählten Port zuerst rein passiv beobachtet
  (feste 1,5-s-Frist auf einen CRC-validen B0-Frame, kein Flush/Write/
  Passwortzugriff), bei Bedarf genau eine harmlose B1-Identitätsprobe
  bei 38.400 sendet (ein währenddessen eintreffendes B0 gewinnt
  strukturell sofort; belegtes B1 übernimmt über die neue
  `CommissioningExecutor.adoptAlreadyOpenConnectionWithConfirmedIdentity()`
  ohne zweiten Versuch, ohne Login, ohne Baudtelegramm, ohne
  Port-Reopen) und nur bei Timeout/unerwarteter/unauswertbarer
  Identitätsantwort auf den vollständigen, bereits abgenommenen
  9600-Commissioning-Fallback zurückfällt (Passwort aus
  `ScannerPasswordStoring` erst unmittelbar vor Login/Baudwechsel
  gelesen, nie als Laufzustand gehalten). Komponiert `ConnectionPolicyModel`
  (SICK-0330r/K1/K2) und `CommissioningModel`/`CommissioningExecutor`
  (SICK-0330a-0/K1, SICK-0330a-1/K1/K2/K3) ohne zweites Telegramm-/CRC-/
  Login-Wissen. Geteilter `CommissioningAbortToken` zwischen eigener
  I/O-Schleife und delegiertem Executor; ein fehlgeschlagener Schluss
  ist dominant gegenüber der Abbruchursache
  (`.failed(.portCloseFailed)` statt `.failed(.aborted)`, nicht final,
  expliziter `retryClose()`). Ein erfolgreicher Bericht (`.ready(_)`)
  lässt den Port bewusst offen und gehalten — SICK-0330b schließt ihn
  wirklich, bevor RX beginnt. 13 Pflichtnachweise über echte Übergänge
  (u. a. B0-vor-B1-Vorrang im selben Lesevorgang, MMK-Wahrheitstabelle,
  vollständige Abbruchmatrix, Redaktion ohne jedes Rohbyte, zwei
  echte revert-basierte Gegenproben). 33 neue Tests, 1910 Tests
  insgesamt, strenger Concurrency-Build und `LC_BUILD_VERSION minos
  12.0` grün. Kein echter Port, kein Gerät, kein TX/RX, keine PTY,
  keine SwiftUI-/`ScanSession`-Integration, kein Git. Auftrag:
  `.agent_handoff/task-sick-0330a.md`.

- **SICK-0330a-1-K3 umgesetzt, zur Supervisor-Prüfung vorgelegt:**
  SICK-0330a-1-K2 war bis auf eine vorreservierte Phantomkante akzeptiert
  (`.agent_handoff/review-sick-0330a-1-k2.md`): `CommissioningAbortToken`
  initialisierte `activeGeneration` absichtlich mit `0`, sodass unmittelbar
  nach `init()` bereits eine gültige Abbruchkante existierte, obwohl weder
  `beginRun()` noch `perform()` je aufgerufen wurde — ein beliebig früher
  `requestAbort()` im echten Leerlauf wurde dadurch gespeichert und hätte
  den späteren ersten tatsächlichen Lauf beendet. Behoben durch die
  einfachste mögliche Korrektur: `activeGeneration` startet jetzt bei
  `nil` statt bei `0` — eine frisch erzeugte Instanz beginnt mit „keiner
  reservierten Kante", genau wie jede spätere Lücke zwischen zwei Läufen.
  Die gesamte generationsbasierte K2-Race-Lösung
  (`beginRunIfNeeded()`/`endRun(_:)`/`consumeIfRequested(for:)`, die
  atomaren Zwei-Seiten-Garantien) ist unverändert. Der bisherige Alttest,
  der einen bloßen `requestAbort()` **vor** dem ersten `perform` (ohne
  vorheriges `beginRun()`) noch beobachtet erwartete, kodierte genau
  diesen Fehler — der geforderte Vor-Start-Fall lautet „nach Einplanung/
  Reservierung, vor Beginn von `perform`", nicht „im Leerlauf vor jeder
  Reservierung". Zwei Tests (Token- und Executor-Ebene) wurden
  entsprechend umgedreht: Ein frischer, direkter `perform`-Aufruf ohne
  vorheriges `beginRun()` läuft jetzt regulär mit sichtbarer
  Gerätewirkung durch, statt sofort mit `.abortedByOperator` zu enden;
  der tatsächlich gemeinte Vor-Start-Fall (`beginRun()` →
  `requestAbort()` → `perform()`) steht als eigener, unveränderter
  Nachweis daneben und bleibt grün. Eine echte, revert-basierte
  Gegenprobe (`activeGeneration` wieder auf die vorreservierte `0`
  zurückgesetzt) bricht genau die beiden dafür vorgesehenen Nachweise auf
  Token- und Executor-Ebene, byteidentisch restauriert. B0-, Schließ-,
  Besitz- und Hinweislogik sowie die gesamte K1-Funktionalität bleiben
  unverändert. 1877 Tests (+2 gegenüber K2), strenger Concurrency-Build
  und `LC_BUILD_VERSION minos 12.0` sind grün. Kein echter Port- oder
  Gerätelauf, keine Owner-App, kein Git. Auftrag:
  `.agent_handoff/task-sick-0330a-1-k3.md`.

- **SICK-0330a-1-K2 umgesetzt, zur Supervisor-Prüfung vorgelegt:**
  SICK-0330a-1-K1 war bis auf die atomare Abbruch-Laufkante akzeptiert
  (`.agent_handoff/review-sick-0330a-1-k1.md`): Das einmalige
  `discardStaleAbortRequest()` bei später Main-Thread-Zustellung war eine
  best-effort-Bereinigung, keine atomare, laufgebundene Kante — eine
  Anforderung, die nach dieser einmaligen Zustellung, aber vor dem
  nächsten `perform`-Aufruf über einen anderen Thread eintraf, konnte
  unbemerkt stehen bleiben und den nächsten, gänzlich anderen Lauf
  vergiften. Behoben durch eine generationsbasierte
  `CommissioningRunEdge`/`CommissioningAbortToken`-Primitive: unter
  derselben `os_unfair_lock`-Sperre führt der Token eine monoton
  wachsende Generation, eine „aktive" und eine „abgebrochene" Generation.
  `beginRunIfNeeded() -> CommissioningRunEdge` reserviert **synchron, vor
  dem Einplanen** des Hintergrundaufrufs — `CommissioningControlModel.
  start(...)` ruft `activeRun.beginRun()` jetzt außerhalb des
  `dispatcher.runSerialized`-Blocks; `perform` reserviert dieselbe,
  extern schon bestehende Kante idempotent weiter (eine Anforderung aus
  der Einplanungslücke bleibt dadurch erhalten) und schließt sie über
  `defer { abortToken.endRun(edge) }` **genau dort, wo `perform`
  zurückkehrt** — nicht erst bei der späteren Zustellung.
  `endRun(_:)` setzt Aktiv- und Abbruchmarke in **derselben** gesperrten
  Sektion zurück, wodurch ein Folgelauf strukturell eine neue Generation
  reserviert und eine kurz vor oder kurz nach dem Schließen eintreffende
  Anforderung nicht mehr sehen kann. `discardStaleAbortRequest()` ist
  ersatzlos entfernt; `CommissioningAborting` hat seither `requestAbort()`
  und `beginRun()`. Zwei deterministische Zwei-Seiten-Gegenproben mit
  echten Threads/Semaphoren (Anforderung unmittelbar vor bzw. unmittelbar
  nach dem Schließen) belegen, dass in keiner Reihenfolge etwas für den
  nächsten Lauf übrig bleibt; eine dritte, lokal nachgebaute alte
  best-effort-Semantik zeigt, dass genau diese Reihenfolge dort leckte
  (Pflichtnachweis 8). B0-, Schließ-, Besitz- und Hinweislogik aus K1
  bleiben unverändert. 1875 Tests (+18 gegenüber K1: 8 neue
  `CommissioningAbortTokenTests`, 1 neuer und 1 überarbeiteter Test in
  `CommissioningRealRunTests`, 1 neuer Test in
  `CommissioningControlModelTests` für die synchrone Reservierung),
  strenger Concurrency-Build und `LC_BUILD_VERSION minos 12.0` sind grün.
  Kein echter Port- oder Gerätelauf, keine Owner-App, kein Git. Auftrag:
  `.agent_handoff/task-sick-0330a-1-k2.md`.

- **SICK-0330a-1-K1 umgesetzt, zur Supervisor-Prüfung vorgelegt:**
  SICK-0330a-1 war noch nicht abgenommen — Korrigiert wurden genau die vier
  vom Review (`.agent_handoff/review-sick-0330a-1.md`) benannten Randfälle
  H1–H4; der akzeptierte B0-Soforterfolg, der kooperative Abbruch während
  Reads und die reale `isFinal`/`isPortHeld`-Ableitung bleiben unangetastet.
  **H1 — finaler B0-Drain:** neue gemeinsame private
  `processFrames(_:expecting:)` in `awaitResponse` wertet Frames aus
  `parser.feed(...)` **und** `parser.finish()` (wirkliches Stromende)
  identisch aus — ein erst im finalen Drain geborgener B0 erreicht
  `measurementStreamConfirmed`, kein anschließendes `writeFailed`
  überschreibt ihn mehr. **H2/H3 — kein automatischer Schließ-Retry:** ein
  neuer `wasClosingPort`-Merker in `perform`s Hauptschleife verhindert einen
  zweiten `closeIfStillOpen()`-Aufruf im selben `perform` nach einem
  fehlschlagenden Portwechsel-Schluss; neue
  `CommissioningStepPolicy.allowedSteps(after report:)` bietet bei
  `restingDirective == .stop && isPortHeld` unabhängig von der fachlichen
  Phase nur `[.finishSession]` an, `CommissioningControlModel.finishRun`
  räumt Run/Besitz erst bei `.sessionFinished && isFinal` gemeinsam auf und
  meldet mit dem neuen `closeFailedWhileStoppingText` nie „Anschluss frei“,
  solange der Port real gehalten bleibt. **H4 — Abbruchlebensdauer und
  strukturelle Grenze:** neues `CommissioningAbortToken.discardStaleRequest()`
  wird als erster Schritt jeder Berichtszustellung gerufen und löscht eine
  im Scheduling-Fenster zwischen echtem Hintergrundende und Main-Zustellung
  eingetroffene Abbruchmarke, bevor sie den nächsten Lauf vergiften kann;
  `CommissioningRunProviding.makeRun(portPath:) throws ->
  CommissioningRunning & CommissioningAborting` macht einen nicht
  abbrechbaren, aber als gestartet gemeldeten Lauf am Typsystem unmöglich
  und ersetzt den vorher lügenden optionalen Cast. Drei echte,
  revert-basierte Gegenproben (B0-Direktive wieder verworfen, Guard gegen
  den zweiten Schließversuch entfernt, stale Abbruchmarke nicht verworfen)
  brechen jeweils exakt die dafür geschriebenen Tests, danach byteidentisch
  wiederhergestellt. 12 neue Tests netto. Testaufschlüsselung
  `SickPLSCommissioning`: 192 → 196 (+4); `SickPLSCommissioningControl`:
  156 → 160 (+4); Gesamtprojekt: 1857 → **1865**, 0 Fehler. Sauberer
  `rm -rf .build && swift build` bestätigt `LC_BUILD_VERSION minos 12.0`;
  isolierter strenger Concurrency-Build bleibt grün, keine neue Warnung.
  Kein echter Port, kein Gerätelauf, keine Owner-App, kein Git, kein
  Standardverbindungs-Orchestrator, keine neue Verbindungsleiste, keine
  `ConnectionPolicy`-Änderung.

- **SICK-0330a-1 umgesetzt, zur Supervisor-Prüfung vorgelegt:** SICK-0330a-0
  (einschließlich K1) ist abgenommen. Drei zusammenhängende Korrekturen am
  Executor (`CommissioningExecutor.swift`), keine neue Rezept-, Transport-,
  Orchestrator- oder Sitzungslogik, kein echter Port/Gerätelauf.
  **1. B0-Direktive nicht mehr verworfen:** `awaitResponse`s B0-Sonderzweig
  wirft die Rückgabe von `apply(.acknowledgement(.observedScanProfile))`
  nicht mehr weg — jede wirkende Direktive (insbesondere `.hold` beim
  MMK-Erfolg) wird sofort zurückgegeben statt hinter einem bedingungslosen
  `continue` zu verschwinden. **2. Echte kooperative Abbruchgrenze:** neues,
  framework-freies `CommissioningAbortToken` (`import os`,
  `os_unfair_lock_s` — die einzige macOS-12-taugliche Sperre ohne
  Foundation/Dispatch; `Synchronization.Mutex`/`Atomic` direkt gegengeprüft
  und verlangen macOS 15). Öffentlich, von jedem Thread sicher aufrufbar,
  geprüft an drei Stellen: vor dem ersten Schritt, vor jeder neuen
  Gerätewirkung zwischen zwei Reducer-Direktiven, und zweimal um jeden
  blockierenden Read — beide Read-Checks sind tragend, selbst wenn der
  laufende Read die erfolgreiche MMK-B0-Antwort trägt. Neue
  `CommissioningAborting`-Protokollgrenze in `SickPLSCommissioningControl`
  (eigenständig, nicht Mitglied von `CommissioningRunning`, sonst bräche
  `testTheRunBoundaryDeclaresExactlyOneMember`); `performStep(.abort)` ruft
  sie bei laufendem Lauf statt einen zweiten `perform(.abort)` hinter dem
  blockierenden Aufruf einzureihen. **3. Wahrer Portschlussvertrag:**
  `CommissioningStepReport.isFinal` ist jetzt ein eigenes, vom Executor
  beobachtetes Feld — `closeIfStillOpen()` verbucht den Port erst nach
  einem tatsächlich erfolgreichen Schließen als fort; ein Fehlschlag hält
  ihn sichtbar offen, ohne stillen Release. Drei echte, revert-basierte
  Gegenproben (B0-Direktive wieder verworfen, Nach-Read-Abbruchcheck
  entfernt — deckte eine echte anfängliche Testlücke auf und wurde durch
  einen eigenen Test geschlossen —, geschluckter Schließfehler
  zurückgesetzt), alle byteidentisch restauriert. 16 neue Tests, darunter
  ein echter Nebenläufigkeitsnachweis (`DispatchSemaphore`-Paar, `perform`
  auf einem echten Hintergrund-Thread, Abbruch vom Hauptthread während
  eines wirklich blockierenden Reads) sowie sechs gezielte
  Abbruch-während-Read-Tests über alle relevanten Sendephasen.
  Testaufschlüsselung `SickPLSCommissioning`: 176 → 192; 1857 Tests
  insgesamt, 0 Fehler; strenger Concurrency-Build und `minos 12.0`
  weiterhin grün.

- **SICK-0330a-0-K1 umgesetzt, zur Supervisor-Prüfung vorgelegt:** SICK-0330a-0
  war entgegen der eigenen Schlusszeile **nicht** vollständig abgenommen —
  `review-sick-0330a-0.md` benannte zwei Abnahmeblocker (K1-1/K1-2;
  Korrekturauftrag `task-sick-0330a-0-k1.md`). B1-Übernahme, Login-Wiederholung,
  Baudwechsel, Diagnose, Rezeptwerte unverändert; nur `CommissioningState.swift`/
  `CommissioningAudit.swift` und ihre Tests geändert. **K1-1:** Die unmittelbare
  MMK-Antwort ist jetzt eine eigene, vom späteren Stromeffekt getrennte
  Audit-Tatsache — neues, feldloses `CommissioningImmediateResponse`
  (`acknowledged`/`rejected`/`unreadable`) auf `CommissioningAuditEntry.immediateResponse`,
  `nil` bildet „keine unmittelbare Antwort" ohne eigenen vierten Fall ab; ein
  späterer B0 überschreibt ein zuvor vermerktes ACK/Unlesbar nicht, und
  umgekehrt. Unbekannte Status-/Kommandobytes werden redigiert auf
  `.unreadable` abgebildet — kein Rohbyte erreicht das Audit. **K1-2:** Der
  Dispatcher reicht `deadlineMillis` jetzt tatsächlich an die Übergangslogik
  weiter; jedes `.acknowledgement(...)`-Ereignis wird zuerst gegen die Frist
  geprüft — bei oder nach der Frist entscheidet der Inhalt (B0/ACK/NACK)
  nichts mehr, der Lauf endet eindeutig `.measurementStreamAbsent`; ein
  verfrühtes `.deadlineReached` bleibt wirkungslos; am exakten Grenzwert gilt
  die Frist als abgelaufen. Zwei Gegenproben (Zeitvergleich entfernt bricht
  12 Einzelaussagen, Antwortaufzeichnung entfernt bricht 4), byteidentisch
  restauriert. 7 neue Tests, Testaufschlüsselung `SickPLSCommissioning`: 169
  → 176; 1841 Tests insgesamt, 0 Fehler; strenger Concurrency-Build und
  `minos 12.0` weiterhin grün. Die dokumentierte Executor-Lücke bleibt
  unverändert SICK-0330a-1 vorbehalten.

- **SICK-0330a-0 umgesetzt, zur Supervisor-Prüfung vorgelegt:** SICK-0330r
  (K1+K2) ist vollständig abgenommen; der Commissioning-Reducer übernimmt
  seither einen bereits belegten B1-Beleg der oberen `ConnectionPolicy`
  ohne zweite Probe/Login (neues, feldloses
  `CommissioningEvent.identityAlreadyConfirmedAtTargetRate`, nur aus
  `.idle`, direkt nach `.verified`) und beweist den experimentellen
  Messmodus ausschließlich über einen neuen, echten CRC-validen B0-Strom
  innerhalb einer festen 3-Sekunden-Frist statt über ein bloßes ACK. Neue
  Phasen `awaitingMeasurementStream(deadlineMillis:)`/`measurementStreamConfirmed`
  ersetzen `requestingMeasurementMode`/`measurementModeAcknowledged`; der
  neue, einzige Fehlerfall `measurementStreamAbsent` ersetzt
  `measurementModeUnanswered`/`measurementModeAmbiguous`. Neues Rezeptfeld
  `measurementStreamTimeoutMilliseconds` (3.000 ms, getrennt vom
  allgemeinen 2.000-ms-Fenster). Drei betroffene Downstream-Sources und
  zwei Downstream-Tests außerhalb des nominalen Dateizuschnitts wurden
  mechanisch mitgezogen, um das Gesamtprojekt kompilierbar zu halten —
  offen gelegt, nicht als Umfangserweiterung. Eine entdeckte, aber bewusst
  unbehobene Lücke in `CommissioningExecutor`s B0-Behandlung (ignoriert
  bislang das `.hold`-Ergebnis während `awaitingMeasurementStream`) ist als
  Vorbedingung für SICK-0330a-1 dokumentiert. Gegenprobe (ACK als
  verfrühter Erfolg) bricht 14 Einzelaussagen, byteidentisch restauriert.
  14 neue Nettotests, Testaufschlüsselung `SickPLSCommissioning`: 156 →
  169; 1834 Tests insgesamt, 0 Fehler; strenger Concurrency-Build und
  `minos 12.0` weiterhin grün.

- **SICK-0330r-K2 umgesetzt, zur Supervisor-Prüfung vorgelegt:** SICK-0330r-K1
  war entgegen der eigenen Schlusszeile **nicht** vollständig abgenommen —
  `review-sick-0330r-k1.md` benannte zwei verbleibende Typgrenzen (K2-1/K2-2;
  Korrekturauftrag `task-sick-0330r-k2.md`). Fast Path, B0-/B1-Wahrheit sowie
  H1–H3 unverändert; nur `ConnectionPolicy.swift` und seine drei Testdateien
  geändert. **K2-1:** `applyWhileClosingPort`s `.portCloseFailed`-Zweig band
  das mitgelieferte `ConnectionPolicyIOFailure` nie — `ConnectionPolicyPhase.closeFailed`
  trägt seither `(ConnectionPolicyClosingOutcome, reason: ConnectionPolicyIOFailure)`,
  gebunden aus dem auslösenden Ereignis; ein wiederholtes `portCloseFailed`
  ersetzt den Grund durch den zuletzt gemeldeten, `operatorAborted` lässt ihn
  unverändert. Der produktiv unerreichbare Fall
  `ConnectionPolicyFailure.portCloseFailed(ConnectionPolicyIOFailure)` ist
  ersatzlos entfernt. **K2-2:** `ConnectionPolicyIdentityGap.unexpectedResponse`
  trägt kein `commandByte: UInt8` mehr — das niedrigere `IdentityProbeOutcome`
  bleibt unverändert, jeder Bytewert bildet an der Policy-Grenze auf dieselbe
  geschlossene Kategorie ab; neue Quelltextgrenze verbietet
  `UInt8`/`commandByte`/`[UInt8]`/`Data` im Deklarationsblock. Zwei echte,
  revert-basierte Gegenproben: beide Rücknahmen lassen das Paket **nicht
  mehr kompilieren** (strukturell erzwungen, nicht nur per Konvention),
  danach byteidentisch wiederhergestellt. 8 neue Tests, Testaufschlüsselung
  `SickPLSCommissioningControl`: 148 → 156; 1821 Tests insgesamt, 0 Fehler;
  strenger Concurrency-Build und `minos 12.0` weiterhin grün.

- **SICK-0330r-K1 umgesetzt, zur Supervisor-Prüfung vorgelegt:** Korrektur der
  vier von `review-sick-0330r.md` benannten Grenzfehler an `ConnectionPolicy.swift`
  (kein neues Target, kein Executor, kein echter Port). **H1:** `operatorAborted`
  in `closingPort(.commissioningContinuation(...))` verwirft die vorgemerkte
  Fortsetzung jetzt unwiderruflich (`abortedOutcome(from:)`) — das Ergebnis endet
  garantiert `.aborted`, nie aktiv oder Commissioning. **H2:** die neue
  nichtterminale Phase `ConnectionPolicyPhase.closeFailed(_:)` hält den Port nach
  einem Schließfehler sichtbar gehalten (`needsPort == true`), kein automatischer
  Retry, erst ein später bestätigtes `portClosed` löst regulär auf. **H3:** jeder
  Fall in `ConnectionPolicyDirective` außer `.none` trägt jetzt `ConnectionPolicyPort`
  als eigenen Wert (nicht mehr kompilierbar ohne) und, wo zutreffend, die explizite
  `SerialPortBaudRate`. **H4:** die drei früheren `String`-Fehlernutzlasten sind
  durch das gemeinsame, feldlose `ConnectionPolicyIOFailure` ersetzt. Zwei echte,
  revert-basierte Gegenproben bestätigen beide Kernkorrekturen (H1: 2 Tests/6
  Aussagen; H2: 84 Aussagen), danach byteidentisch wiederhergestellt. Übergangstabelle
  um zwei neue Zustandsformen (`closeFailed(.failure(...))`/
  `closeFailed(.commissioningContinuation(...))`) erweitert, je gegen alle zehn
  Ereignisse geprüft. 12 neue Tests, Testaufschlüsselung `SickPLSCommissioningControl`:
  136 → 148; 1813 Tests insgesamt, 0 Fehler; strenger Concurrency-Build und
  `minos 12.0` weiterhin grün. Fast Path und B0-/B1-Entscheidung unverändert.

- **SICK-0330r umgesetzt, zur Supervisor-Prüfung vorgelegt:** `ConnectionPolicyModel`
  (`Sources/SickPLSCommissioningControl/ConnectionPolicy.swift`) ist die reine,
  deterministische Verbindungspolitik — kein Port, keine Uhr, kein Thread, keine
  I/O. Passiver B0-Fast-Path erreicht `ready` ohne jedes TX; ohne B0 folgt genau
  eine B1-Identitätsprobe bei 38.400; valides B1 fordert genau eine typisierte
  aktive Fortsetzung an (Port bleibt gehalten); Timeout/unerwartete/unauswertbare
  Antwort fordern erst nach bestätigtem Portschluss genau eine typisierte
  Commissioning-Fortsetzung ab 9600 an. Ein B0 während der B1-Prüfung gewinnt
  strukturell. Abbruch/Fehler mit vorgesehenem oder offenem Port erreichen ihren
  Endzustand erst nach bestätigter Freigabe; terminale Zustände ignorieren jedes
  weitere Ereignis. 42 neue Tests (28 Pflichtnachweise/Gegenproben, 11 vollständige
  Übergangstabelle, 3 Quelltextgrenze), 1801 Tests insgesamt, 0 Fehler; strenger
  Concurrency-Build und `minos 12.0` weiterhin grün. Kein Executor, kein SwiftUI,
  kein echter Portlauf.

- **SICK-032c3b einschließlich K1/K2/K3 abgenommen:** Der Supervisor hat das
  ersetzte Grundprofilbild in Originalauflösung geprüft; es zeigt den echten
  Produktzustand `.collectingBaseline` mit „Grundprofil 1 von 5“, ist opak
  und vollständig gezeichnet. Der isolierte K3-Harness ist restlos entfernt;
  1759 Tests, strenger Concurrency-Build und macOS-12-Deploymentnachweis sind
  grün. Review: `.agent_handoff/review-sick-032c3b-k3.md`. SICK-0330r ist als
  reine, hardwarefreie Verbindungspolitik freigegeben.

- Projektfundament und Planungsdokumentation für den RX-only macOS-Start.
- Roadmap R0 bis R7 für Protokollkern, Monitor, Mapping, MIDI, Synthese, Kalibrierung und separat freigegebene TX-Forschung.
- Verbindliches Kompatibilitätsziel macOS 12 (Monterey) mit API-Availability-Checks je Slice.
- Swift Package `SickPLSCore` (macOS 12): Frame-Konstanten, kanonisches SICK-CRC16 (BSD-SickToolbox-Quelle), Frame-Werttyp mit Serialisierung/Decodierung eines vollständigen Frames, XCTest-Abdeckung inkl. unabhängiger CRC-Vektoren (SICK-003).
- Inkrementeller `StreamParser` (Ringpuffer-Framing nach `wire-protocol.md` §5a), `Frame.decodePrefix`/`Frame.decodeExact` auf `RandomAccessCollection` (Array/ArraySlice/Data) mit `consumedBytes`, `THIRD-PARTY-NOTICES.md` (BSD-Lizenztext), `.gitignore` (SICK-004).
- `LICENSE`: eigene Projektbeiträge unter MIT, Copyright (c) 2026 Stephan Schmitt (Owner-Entscheidung, SICK-004a); CRC-Port bleibt separat unter BSD (`THIRD-PARTY-NOTICES.md`).
- `B0ScanProfile.decode(from:)`: Parser für CRC-valide B0-Scanprofil-Payloads (dynamische Punktzahl, `partialScanIndex`, 13-Bit-Messwerte, 3-Bit-`field_flags`), keine Einheiten-/Teilscan-Interpretation. Damit ist R1 (`SickPLSCore`) inhaltlich abgeschlossen (SICK-005).

- `B0ScanProfile.trailingBytes`/`rawHeaderByte2`: überzählige Payload-Bytes und das vollständige, unmodellierte Header-Byte 2 werden roh erhalten statt verworfen (SICK-006).
- `StreamParser.finish() -> [Frame]`: Batch-Semantik-Abschluss für endliche Ströme, verwirft unvollständige Restkandidaten byteweise statt sie hängen zu lassen; öffentliche, fortlaufende `StreamParser.Diagnostics` (valide Frames, verworfene Kandidaten nach Oversize/CRC/Abschluss, übersprungene Rauschbytes); gepinnter informations-erhaltender B0-Rundlauftest; Validierungs-Checkliste für den ersten RX-only-Mitschnitt im Checkpoint (SICK-007).
- `StreamParser.Diagnostics.discardedCandidates`: berechneter Summenzähler über alle drei Verwurfsursachen; `Diagnostics.init()` öffentlich. `B0ScanProfile.Measurement.build(value:fieldFlags:)`/`B0ScanProfile.build(partialScanIndex:measurements:trailingBytes:)`: öffentliche, validierende Fabriken für synthetische Profile (UI/Previews), lehnen Werte außerhalb ihres Bitbereichs ab. Byte-Bilanz-Invariante des Streamparsers als Test gepinnt (SICK-008).
- Neue Bibliothek `SickPLSMacTransport` (abhängig von `SickPLSCore`, Darwin/POSIX-`termios`): reine Lese-API (`SerialPortOpener`/`SerialPortFileDescriptor`, keine `write`-Methode, keine TX-Kommandos), feste Konfiguration 38 400 8E1 ohne Flow-Control (`SerialPortSettings`), `SerialPortEnumeration` ausschließlich für `/dev/cu.*`, `SickPLSSerialConnection` vermittelt `StreamParser`-Frames und -Diagnostik; ein Lesetimeout löst nachweislich kein `finish()` aus, nur ein echtes Stromende. Neues ausführbares Target `SickPLSDiagnosticCLI` (`sick-pls-diag`): verbindet nur bei explizitem `--port`, `--list-ports` ohne Verbindungsaufbau, loggt keine Rohcaptures. 12 neue Tests, ausschließlich mit Fakes, kein physisches Gerät geöffnet (SICK-009).
- Testbare `RawSerialSyscalls`-Abstraktion für rohes `poll(2)`/`read(2)`/`close(2)`, macht die Poll-dann-Read-Reihenfolge und errno-Klassifikation in `DarwinSerialPortFileDescriptor` ohne PTY/Gerät testbar (SICK-010).
- `SerialPortOpenError.pathNotAllowed(String)`: neuer Fehlerfall, wenn `SickPLSSerialConnection.open(portPath:baudRate:opener:)` mit einem Pfad außerhalb von `/dev/cu.*` aufgerufen wird (SICK-010, Revisor-Review-Finding N6 aus `review-sick-009.md`).
- `sick-pls-diag`: `ProfileStatistics`/`computeStatistics(for:)` (`CLIReporting.swift`) — min/max/Median, Anteil der Messwerte bei `0`/`8191`, größter Nachbarsprung in Empfangsreihenfolge, statt Rohbytes auszugeben (SICK-010, Revisor-Review-Finding M5 aus `review-sick-009.md`). SIGINT-Handling: sauberes `close()` + Abschlussdiagnose wie beim regulären `--duration`-Ende. Argumentparsing (`CLIArguments.swift`) und Ausgabeformatierung (`CLIReporting.swift`) in eigene, testbare Dateien ausgelagert; neues Testziel `SickPLSDiagnosticCLITests` (32 Tests).
- 13 neue Tests in `DarwinSerialPortFileDescriptorTests` (M1–M4) und 6 neue Tests in `SickPLSSerialConnectionTests` (3 für N6, 3 für die explizite Baudrate), alle mit Fakes, kein PTY/Gerät (SICK-010).
- `SerialPortBaudRate`: geschlossenes Enum mit genau zwei benannten, dokumentierten Werten (`.baud9600`, `.baud38400`), kein Auto-Baud, kein beliebiger `Int32` (SICK-010, Owner-Scope-Änderung 2026-09-21 — der aktuell angeschlossene Scanner läuft mit 9600 statt der historisch verifizierten 38400 Baud, keine Hardwareaktion für diese Änderung). `sick-pls-diag`: neue Pflichtoption `--baud 9600|38400`, zeigt den gewählten Wert inkl. Evidenzkennzeichnung in der Verbunden-Meldung.
- Neue Bibliothek `SickPLSActiveControl` (abhängig von `SickPLSCore`/`SickPLSMacTransport`) — **die erste und bisher einzige TX-fähige Bibliothek des Projekts**; `SickPLSMacTransport` bleibt unverändert und strukturell RX-only (SICK-011). `ConfirmedTargetAddress`: typisierte, fehlschlagbare Zieladresse, `.universal` (`0x00`) als dokumentierter Default, lehnt `0x81` (Scanner-Antwortadresse) strukturell ab. `IdentityProbe`: `requestFrame(address:)`/`isExpectedResponse(_:)` für den einen dokumentierten, zustandsfreien `0x31 → 0xB1`-Pfad. `IdentityProbeOutcome`: vier getrennte Ergebnisse (`identified`/`timeout`/`unexpectedResponse(commandByte:)`/`ambiguous`), trägt nie rohen Antwort-Payload. `ActiveControlSerialPort`/`ActiveControlSerialPortOpener`: eigene TX-fähige Protokollgrenze mit `write`; reale Implementierung `DarwinActiveControlSerialPort`/`-Opener` verwendet als einzige Stelle im Projekt `O_RDWR`, mit eigener `RawDuplexSyscalls`-Testgrenze. `BaudProbe`: begrenzte lokale Baud-Erkennung über `[.baud9600, .baud38400]`, je Kandidat genau ein Probe-Frame, Stopp bei erstem Erfolg, `/dev/cu.*`-Pfadgrenze, überspringt autonome `0xB0`-Broadcasts als bekanntes Rauschen. 33 neue Tests in `SickPLSActiveControlTests`, ausschließlich mit Fakes, kein physisches Gerät geöffnet.
- `sick-pls-diag`: neue Opt-in-Option `--probe-baud [--target-address <n>]` (`ProbeReporting.swift`) — sichtbar, nie automatisch, zeigt vor jedem Sendeversuch Ziel/Raten/Wirkung. Neue `CLIArgumentError`-Fälle `.invalidTargetAddress`. 19 neue Tests in `SickPLSDiagnosticCLITests` (SICK-011).
- `MonotonicClock`/`DarwinMonotonicClock` (`MonotonicClock.swift`, `SickPLSActiveControl`): injizierbare monotone Uhr über `clock_gettime(CLOCK_MONOTONIC, ...)`, macht die harte Gesamtfrist von `BaudProbe.probeOnce` ohne reale Sleeps testbar (SICK-011a). 3 neue Tests in `BaudProbeTests` (fortlaufendes Rauschen bis zur Deadline → begrenzt `.ambiguous`; fragmentierte B1-Antwort vor der Deadline → `.identified`; abgelaufene Deadline vor dem ersten Leseversuch → `.timeout` ohne zu lesen); `FakeActiveControlSerialPort` zeichnet zusätzlich `readTimeoutsRequested` auf.
- Neue Bibliothek `SickPLSMonitorKit` (abhängig ausschließlich von `SickPLSCore`/`SickPLSMacTransport` — rein RX-only, kein `SickPLSActiveControl`) und neues SwiftUI-App-Target `SickPLSMonitor` (macOS 12) — der erste R3-Grundschnitt (SICK-012). `ScanSessionState`: reiner, unveränderlicher Zustandswert mit `applying...`-Methoden (alter Zustand + Ereignis + vom Aufrufer übergebener Zeitstempel -> neuer Zustand), `ConnectionStatus` (vier Fälle, nie automatisch verbunden), rollierende `profileRateHz` über ein Fenster von 8 Profilen. `ScanSession`/`ReadLoopWorker`: `ObservableObject` mit explizitem `connect(portPath:baudRate:)`/`disconnect()`, Hintergrund-Leseloop auf einem eigenen Thread mit kooperativer `DispatchWorkItem`-Stornierung, Verbindungsdeskriptor ausschließlich vom Hintergrund-Thread selbst angefasst. `PolarProfileGeometry`: reine, SwiftUI-unabhängige Geometrie-/Skalierungsschicht, `radiusFraction` relativ zur festen 13-Bit-Obergrenze (`0x1FFF`), nicht zum Profil-Maximum. SwiftUI-Views `ConnectionControlsView`/`ConnectionStatusView`/`DiagnosticsView`/`PolarScanView`/`ContentView` (kein Canvas/Swift Charts, `ObservableObject`/`@Published` statt Observation-Makros). 25 neue Tests in `SickPLSMonitorKitTests`.
- Erster echter RX-only-Mitschnitt dieses Projekts (aggregiert dokumentiert, kein Rohcapture, SICK-012): 9600 Baud, B1-Identität bestätigt, 20 valide B0-Profile in 5 s (≈ 4 Hz), 90 Punkte, `partialScanIndex` durchgehend `0`, `trailingBytes.count` durchgehend `1`, eine erwartete initiale CRC-Verwerfung und ein erwarteter Abschlussrest — erfüllt erstmals alle drei Kriterien der Validierungs-Checkliste (Checkpoint) real statt nur gegen einen unabhängigen Software-Port.
- 4 neue Tests in `ScanSessionTests` (SICK-012a): `ReadLoopWorker` wird nachweislich nach `disconnect()` bzw. nach vollständiger Freigabe von `ScanSession` deallokiert (`weak`-Referenzprüfung); ein verspätetes Ereignis eines bereits getrennten/ersetzten Workers überschreibt weder den zurückgesetzten Leerzustand noch den Zustand einer neu aufgebauten Verbindung.
- `PolarProfileGeometry.Point.displayRadiusFraction` (SICK-012b): rein darstellungsbezogene, monotone Kompression (vierte Wurzel) von `radiusFraction`, ausschließlich zur Sichtbarkeit — keine physikalische Bedeutung, keine Kalibrierung, keine Abhängigkeit von anderen Punkten desselben oder eines vorherigen Profils. 6 neue Tests in `PolarProfileGeometryTests`.
- 1 neuer Test in `ScanSessionTests` (SICK-012b): `testManyRapidConnectDisconnectCyclesRemainConsistentAndLeaveNoWorkerBehind` treibt 25 rasche `connect()`/`disconnect()`-Zyklen über die echte asynchrone API und belegt einen konsistenten, konfliktfreien Endzustand für den jetzt thread-sicheren `ReadLoopWorker.workItem`-Zugriff.
- Sichtbarer UI-Nachweis für SICK-012b als PNG unter `.agent_handoff/sick-012b-empty-state.png`/`sick-012b-synthetic-profile.png` (Details siehe Checkpoint/Coder-Rücklauf, inkl. Begründung, warum kein echtes Fenster-Screenshot des laufenden `SickPLSMonitor` möglich war).
- Neue Bibliothek `SickPLSControlCore` (SICK-013, abhängig ausschließlich von `SickPLSCore` — UI-, Transport-, MIDI-, Audio- und gerätefrei): der testbare Zonen-/Mappingvertrag für Schritt 2 des freigegebenen Prototypenpfads. `ZoneRole`: geschlossenes Enum, mindestens `pitch`/`volume`/`filter`/`gate`/`effectSend`. `Zone`: rein relativer Indexbereich (`0...1`) + Rohwertbereich (`0...8191`) + Rolle, `Zone.build(...)` als öffentliche, validierende Fabrik (Muster wie `Frame.build`/`B0ScanProfile.build`). `Zone.evaluate(against:)`: reine Funktion ohne jeden Zustand, bewertet ausschließlich das echte, übergebene `B0ScanProfile` — kein Schätzer, keine Vorhersage; liefert nur `ZoneEvaluationResult.controlValue(Double)` (`0...1`) oder `.inactive`, nie MIDI/Noten/Frequenzen/Audio. Auswahlregel bei mehreren Treffern: kleinster Rohwert im Zonenbereich gewinnt. `Sequence<Zone>.evaluating(against:)`: mehrere, auch überlappende Zonen unabhängig ausgewertet, keine implizite Priorität. 18 neue Tests in `SickPLSControlCoreTests`.
- `ROADMAP.md`: neuer Abschnitt „Freigegebener Prototypenpfad" (SICK-013) mit den zehn Schritten des kompletten, vom Owner freigegebenen Laser-Theremin-Prototypen sowie den verbindlichen Leitplanken (macOS 12, HarmonyEngine3D als selektive Referenz, C++-DSP-Kern mit Objective-C++-Brücke, Audio-Unit-Host-Rack, FIRSTofFIFTH-Vergleichsslice-Pflicht, Windows-Doku als Pflicht-Input vor dem aktiven Konfigurationsslice).
- Grafischer Zoneneditor in `SickPLSMonitor` (SICK-014, Schritt 3 des freigegebenen Prototypenpfads). Neu in `SickPLSMonitorKit`: `ZoneEditorGeometry` (reine Umrechnung Anzeige-komprimierte Fächerposition ↔ relativer Index-/Rohwertraum, inverse vierte Wurzel zur jetzt öffentlichen `PolarProfileGeometry.displayRadiusFraction(fromRadiusFraction:)`); `FanScreenGeometry` (Bildschirm ↔ Fächerkoordinate, aus `PolarScanView` herausgelöst, jetzt von `PolarScanView` und dem neuen `ZoneOverlayView` gemeinsam genutzt); `EditableZone` (reiner `UUID`-Identitäts-Wrapper für SwiftUI-Listen, keine Parallelsemantik zu `SickPLSControlCore.Zone`); `ZoneDraft` (editierbarer Zwischenzustand mit `clamp()` + `resolvedZone()`, validiert ausschließlich über `Zone.build(...)`); `ZoneEditorState` (reiner Reducer nach dem Muster von `ScanSessionState`: `addZone`/`select`/`removeSelectedZone`/`updateDraft`/`commitDraft`, plus `evaluations(against:)` — leer ohne Profil, nie ein zwischengespeicherter/vorhergesagter Wert). Neu in `SickPLSMonitor`: `ZoneOverlayView` (farblich unterscheidbare Ringsektor-Flächen je Zone, Tippen zum Auswählen über `DragGesture(minimumDistance: 0)` statt des erst ab macOS 13 verfügbaren `SpatialTapGesture`); `ZoneListView` (Hinzufügen mit Rollenauswahl, Auswählen, Löschen); `ZoneInspectorView` (vier präzise `TextField(_:value:format:.number)`-Felder für Index-/Rohwertgrenzen plus Rollenauswahl, live Bewertungsanzeige); `ZoneRole+Display`/`ZoneEditorDesignTokens` (erste eigene, von FIRSTofFIFTH abgeleitete Design-Tokens). 45 neue Tests in `SickPLSMonitorKitTests` (`ZoneEditorGeometryTests` 10, `FanScreenGeometryTests` 6, `ZoneDraftTests` 11, `ZoneEditorStateTests` 18). Sichtnachweis ohne Gerät als PNG unter `.agent_handoff/sick-014-empty-state.png`/`sick-014-zones.png` (kein Desktopaufnahme, dasselbe `ImageRenderer`-Verfahren wie SICK-012b).

- Bewegungsprognose für kontinuierliche Zonensignale (SICK-015, Schritt 4 des freigegebenen Prototypenpfads). Neu in `SickPLSControlCore`: `ControlValuePredictor` — reiner Alpha-Beta-Schätzer mit konstanter Geschwindigkeit für **einen** normierten Steuerwert (`0...1`), Zeitbasis ausschließlich `Double`-Sekunden einer monotonen, vom Aufrufer gestellten Uhr (kein `Date`, keine Systemzeitabfrage); `observe(value:atTime:)` akzeptiert nur endliche Werte in `0...1` und strikt fortschreitende Zeitstempel und lässt den Zustand bei Verletzung nachweislich unangetastet, sichtbar über `ControlValueObservation` statt über `throws` oder Absturz; `estimate(at:)` liefert `ControlValueEstimate` mit drei explizit getrennten Fällen (`inactive`/`measured`/`predicted`), sagt nur vorwärts und nur bis zum konfigurierten Horizont voraus (dahinter dessen Endwert haltend, nie weiter extrapolierend), wird nach der Stale-Grenze zwingend inaktiv und bleibt stets in `0...1`, ohne Rückwärtsprojektion; ein Residuum über dem Ausreißergrenzwert initialisiert mit der **echten** Beobachtung und Geschwindigkeit `0` neu. `ControlValuePredictorConfiguration` — validierende Fabrik (`build(...) throws`, Muster wie `Frame.build`/`Zone.build`) mit eigenem `BuildError` je Regel und ohne stille Default-Korrektur; `startingPoint` als dokumentierter Startwert (Horizont 60 ms im SICK-008a-Bereich 40–80 ms, konfigurierbare Stale-Grenze 0,35 s — ausdrücklich keine Gerätebehauptung). Neu in `SickPLSMonitorKit`: `ZoneSignalPipeline`/`ZoneSignal` — reiner Zonenadapter, verarbeitet ausschließlich `Zone.evaluate(against:)` auf einem übergebenen, bereits echten `B0ScanProfile` mit stabilen `EditableZone`-IDs und injiziertem monotonen Zeitstempel; `pitch`/`volume`/`filter`/`effectSend` dürfen schätzen, **`gate` bekommt strukturell gar keinen Prädiktor** und wird nie prognostiziert oder gehalten; gelöschte Zonen, in einem echten Profil `inactive` gewordene Zonen und Rollenwechsel verwerfen die Historie vollständig, überlappende Zonen bleiben unabhängig. 59 neue Tests (`ControlValuePredictorConfigurationTests` 16, `ControlValuePredictorTests` 25, `ZoneSignalPipelineTests` 18), alle ohne Uhr, Thread, Timer oder Gerät, inklusive je eines Szenarios mit ≈ 12,5-Hz- und ≈ 4-Hz-Sample-Abstand bei identischer Konfiguration.
- `ROADMAP.md`/Checkpoint: neuer Abschnitt „Externe Evidenz aus `SICK Doku/integration/`" (SICK-015) — technische Einordnung der nun vorliegenden Windows-Dokumentation: 38 400/8E1 ohne Flusssteuerung 🟢 (Parität differenziell gegen 8N1 belegt, bestätigt unseren `SerialPortSettings`-Vertrag extern); Startzustand nach Neustart 9600/8E1 🟢 und der Weg auf 38 400 ein aktiver, mehrstufiger, login-pflichtiger Konfigurationsablauf (🟢) mit ⚪ offener Persistenz; Messmodus „Messwerte minimal kontinuierlich" weiterhin nur 🟡 capture-belegt („nie selbst gesendet", mit Gegenbeleg); dortige Profilraten (≈ 12,5/8,05/4,11 Hz bei 90/180/361 Punkten, alle bei 38 400) stützen die **Durchsatz-Hypothese**, dass der serielle Durchsatz und nicht die Bildrate die Obergrenze setzt und damit auch unsere ≈ 4 Hz bei 9600 erklären könnte — ausdrücklich eine Hypothese, kein Kausalnachweis über zwei verschiedene Sitzungen/Aufbauten hinweg; entscheidbar erst nach einer eigenen, kontrollierten 38 400-Messung am selben Aufbau (Scanner aktuell nicht verfügbar). Baud- und Messmoduswechsel sind als eigener, später liegender, hardware- und ownergesteuerter Konfigurationsmeilenstein vermerkt, nicht freigegeben und nie ausgeführt. Keine Passwörter, Telegramm-Rohbytes oder sonstigen Secrets aus dieser Dokumentation übernommen.
- `ZoneIngestReport` (`SickPLSMonitorKit`, SICK-015a) und `ControlValueObservation.resetAfterStaleGap` (`SickPLSControlCore`, SICK-015a) — Details unter „Geändert" (Befunde H1 und H2). 13 neue Tests: `ControlValuePredictorTests` +6 (Neustart nach Stale-Lücke statt Weiterführen der alten Geschwindigkeit, richtiger Grund statt `.resetAfterOutlier`, kein kurzzeitiges Ausgeben des alten Werts, inklusive Grenze exakt bei `staleTimeoutSeconds` mit exakten Binärbrüchen, knapp darüber setzt zurück, ungültige Werte bleiben auch im Stale-Fall zustandsfrei abgelehnt); `ZoneSignalPipelineTests` +7 (Gate ausschließlich als `ingest`-Ereignis, `.inactive` vor **und** nach dem Ereignis — der Test erkennt die alte `<=`-Semantik sicher —, Abtastung über 61 Zeitpunkte, Gate-Zonen hinterlassen keinen Eintrag, Koexistenz mit kontinuierlichen Zonen; geänderte Index- bzw. Wertgrenzen bei gleicher ID/Rolle verwerfen Historie, unveränderte Zone behält sie; Profil nach Stale-Lücke startet den Zonenschätzer neu).
- Neue Bibliothek `SickSynthDSP` (SICK-016, Schritt 5 des freigegebenen Prototypenpfads) — der echtzeitfähige **C++17**-Synth-DSP-Kern und das erste Nicht-Swift-Ziel des Projekts; dazu das C++-Testziel `SickSynthDSPTestSupport` und das Swift-Testziel `SickSynthDSPTests`. `Package.swift` trägt jetzt `cxxLanguageStandard: .cxx17` (sechzehn Targets inkl. Tests). **Keine Drittanbieter-Abhängigkeit, kein übernommener HarmonyEngine3D-Code.** `ThereminVoice`: monophone, mono ausgebende Theremin-Stimme (Morph-Oszillator → TPT-Tiefpass → ADSR → Amplitude) mit ausdrücklichem Echtzeitvertrag für `render()` — keine Heap-Allokation, keine Locks, keine Exceptions (`noexcept`, per `static_assert` gepinnt), keine Datei-/Logger-/Systemzeitzugriffe, keine Objective-C-/Swift-Objekte; aller Zustand liegt als Skalar oder festes Array im Objekt, Parameter kommen als `VoiceParameters`-Block-Snapshot, jeder kontinuierliche Parameter wird über den Block linear gerampt. `configure()` prüft Samplerate und Blockgröße **außerhalb** des Renderpfads und lehnt Ungültiges über `ConfigurationError` sichtbar ab; nichtendliche/außerhalb liegende Parameter werden einmal pro Block geklammert und in `Diagnostics` gezählt; `render()` schreibt nie ein nichtendliches Sample. `submitGateEvent(isOn:frameOffset:)`: Gate ist ausschließlich ein **echtes Ereignis** mit sample-genauem Versatz — der Kern erzeugt, prognostiziert oder hält selbst keines (dieselbe Haltung wie `ZoneSignalPipeline` seit SICK-015a). `MorphOscillator`: Sinus → Sägezahn → Rechteck aus einem Phasenakkumulator, Sägezahn und Rechteck PolyBLEP-korrigiert, Sägezahn bewusst **fallend**, damit die Grundwellen aller drei Formen gleichphasig sind. `StateVariableFilter`: zweipoliger TPT-Tiefpass (12 dB/Okt., Prewarping, `Q` 0,7071…8,0), unbedingt stabil, ohne Selbstoszillation. `AdsrEnvelope`: einpolige Segmente mit nachprüfbar definierter Segmentzeit (99,9-%-Strecke) und garantiert **exakt** Null spätestens nach der doppelten Release-Zeit. 34 neue Tests, alle deterministisch ohne Uhr/Thread/Timer/Gerät — darunter der instrumentierte Nachweis „keine Heap-Allokation im Renderpfad" über einen ersetzten globalen `operator new` (inklusive Gegenprobe, dass die Instrumentierung greift) und eine spektrale Messung der Bandbegrenzung (Faktor 57 bzw. 17,6 dB weniger nichtharmonische Energie als ein naiver Sägezahn; der Test fordert Faktor 8). **Noch ohne jede Audioausgabe**: kein `AVAudioEngine`, keine Objective-C++-Brücke, kein Swift-/UI-/MIDI-/Scanner-/Zonensignal-Anschluss, keine Effekte, keine Presets.
- Offline-Rendernachweis für SICK-016 unter `.agent_handoff/`: `sick-016-offline-render-stats.md` (Kennzahlen), `sick-016-offline-render.wav` (6 s, mono, 48 kHz, 16 Bit) und das reproduzierbare, **nicht ausgelieferte** Werkzeug `sick-016-offline-render-tool.cpp` (kein Paketziel, in keiner `Package.swift`, mit Reproduktionsanleitung im Dateikopf). Alles rein abgeleitet und vollständig synthetisch — kein Scannerbezug, keine Rohcaptures, keine Desktopaufnahme.
- `ROADMAP.md`/Checkpoint/`CLAUDE.md`/`README.md`/`PROJECT_LOG.md`/dieser Changelog (SICK-015a, Befund M2): die Ratendifferenz zwischen unserer einen 9600-/≈ 4-Hz-Sitzung und der externen 38 400-/≈ 12,5-Hz-Messung ist überall als ausdrücklich gekennzeichnete **Durchsatz-Hypothese** formuliert statt als aufgelöste technische Tatsache, mit dem festgehaltenen Vorbehalt: echter Vergleich erst nach einer eigenen, kontrollierten 38 400-Messung am selben Aufbau; Scanner aktuell nicht verfügbar.
- Neue Bibliothek `SickPLSCommissioningControl` plus Testziel (SICK-032a, Auflage **E3** aus `review-sick-031.md`; abhängig von `SickPLSCommissioning`/`SickPLSMacTransport`/`SickPLSActiveControl`/`SickPLSPerformanceSession` — **kein SwiftUI, kein AVFoundation, kein CoreMIDI, keine `ScanSession`, kein `SickPLSMonitorKit`, kein Timer und keine Wiederholungsautomatik**; Importe, verbotene Bezeichner und die Manifest-Abhängigkeiten prüft `CommissioningControlBoundaryTests` automatisch). **Vierunddreißig Targets insgesamt inkl. Tests.** `CommissioningControlModel` (`ObservableObject`, Kontroll-Thread) ist der erste sichtbare Commissioning-Bedienpfad: **zweistufig** — erst `requestAccess()` (kontrolliertes Trennen des Monitors und Abwarten der **echten** Portfreigabe über `MonitorPerformanceCoordinator`), dann `requestStep(_:)` und die ausdrückliche `confirmPendingStep(secretText:)`; **solange ein Schritt nur angefordert ist, geht nichts hinaus**. `CommissioningRunning` ist die Ausführungsgrenze mit **genau einem Mitglied** — damit ist Review-Befund **N2** (`executor.report` eines nie gestarteten Executors ist `isFinal` und gäbe den Port frei) **strukturell** unerreichbar statt nur verabredet. `CommissioningDispatching`/`SerialCommissioningDispatcher`: **eine** serielle Warteschlange für den blockierenden `perform`, Zustellung des Berichts **immer asynchron** auf den Main Thread (Lehre aus SICK-028), und erst dort `completeCommissioning(with:)`. `CommissioningBriefing`: Port, Start **9600/8E1**, Ziel **38400/8E1**, die aktive Wirkung am Gerät und der Geräteneustart als **einziger bekannter Rückweg** (Text unverändert aus `CommissioningFailure.recoveryHint`) — dauerhaft sichtbar, **kein Baud-, Adress- oder Rezeptwähler**. `CommissioningStepPolicy`: reine Ableitung der anbietbaren Schritte aus der Berichtsphase, **keine zweite Zustandsmaschine** — ein eigener Test fährt jeden angebotenen Schritt gegen den **echten** `CommissioningModel` in Ruhepunkten, die dieser selbst über gültige Ereignisse erreicht hat. `SystemCommissioningRunFactory` ist die **einzige** Stelle, die Transport und Executor herstellt. Neue SwiftUI-Ansicht `CommissioningControlView` (reine Komposition; der Geheimniswert lebt nur als `@State`-Text und wird direkt nach der Bestätigung geleert). 55 neue Tests, alle gegen Fakes und Spione — **kein echter Port, kein TX, keine Hardware, keine PTY, kein Capture und kein echter Geheimniswert in irgendeinem Artefakt**; darunter vier Nachweise über einen **echten** `CommissioningExecutor` an einem stillen Fake-Transport und zwei über die **reale** `SerialCommissioningDispatcher` (`perform` nicht auf dem Main Thread; Bericht erreicht den Main Thread vor dem Abschluss). **1311 Tests insgesamt.**
- **Scanner-Passwort als gewöhnliche App-Einstellung** (SICK-032a2): neue Dateien `ScannerPasswordStore.swift` (Protokollgrenze plus `UserDefaultsScannerPasswordStore`) und `ScannerPasswordSettingsModel.swift` in `SickPLSCommissioningControl`, dazu die SwiftUI-Ansicht `ScannerPasswordSettingsView` in einer eigenen `Settings`-Scene (macOS 11+, also innerhalb der macOS-12-Grundlage). Der Wert steht **im Klartext** da, ist jederzeit bearbeitbar, wird beim Tippen gespeichert, und „Vergessen" löscht Feld wie Ablage. Die Einrichtung holt ihn sich **automatisch** für genau einen Umschalt-Lauf. **Ausdrücklich nicht gebaut:** kein Schlüsselbund, keine Maskierung, kein „Anzeigen"-Klick, kein redigierter Wertetyp — eine erste Fassung dieses Slices hatte das alles und ist auf Owner-Korrektur entfallen. **Damit sind SICK-030a Auflage A5 und SICK-032a Regel 7 für diesen Wert aufgehoben.**
- **Primärer Vorbereitungsablauf und Ein-Klick-Schritte** (SICK-032a2): `CommissioningControlModel.prepareScanner()` fasst Anschlussübernahme und harmlose Ausgangsprüfung zusammen; `performStep(_:)` führt harmlose Schritte ohne Bestätigung aus; `CommissioningStepPolicy.requiresConfirmation(_:)` ist die eine Stelle, die entscheidet, was weiterhin zwei Handgriffe braucht (`switchBaudRate`, `requestMeasurementMode`).
- **`scripts/make-app-bundle.sh`** (SICK-032a2): baut `SickPLSMonitor` als echte `.app` samt `Info.plist` und ad-hoc-Signierung. **Der rohe SwiftPM-Start ist kein Endnutzerweg** — ohne Bundle behandelt macOS den Prozess nicht als reguläre App (kein Aktivieren, kein Tastaturfokus in Textfeldern, kein Vollbild). Neue `AppBundleContractTests` halten die dafür nötigen Plist-Eigenschaften fest, darunter die Abwesenheit von `LSUIElement`.
- **`ScanViewport` und `LinearScanFieldGeometry`** (SICK-032b1, in `SickPLSMonitorKit`): der **lineare** Scan-Viewport-Vertrag als Grundlage für die zentrale Darstellung in SICK-032b. `ScanViewport` ist der Ausschnitt im normierten Feldraum (`0...1` mal `0...1`) mit vier Werkzeugen — Gesamtansicht, Verschieben, Zoom am Anker, Rechteckzoom — und einer validierenden Fabrik mit eigenem Fehler je Regel. `LinearScanFieldGeometry` bildet Feldkoordinate und Bildschirm **geometrisch linear** aufeinander ab, in beide Richtungen; die Rückrichtung ist die Bediennaht für Zoom am Zeiger und Ziehrahmen. **Keine Wurzel, kein Logarithmus** — die vierte Wurzel aus SICK-012b bleibt der alten Fächerdarstellung vorbehalten. **Der Ausschnitt ist vollständig von Zonen, Learn, Mapping und Audiosteuerung getrennt:** `ScanViewport` importiert gar nichts und kennt keinen einzigen fachlichen Typ; Quelltexttests prüfen das in beide Richtungen.
- **`ScanFieldFit`, `ScanFieldViewState`, `ScanFieldView` und `ScanFieldPointerEvents`** (SICK-032b2): das **lineare, direkt bedienbare Scan-Feld**. `ScanFieldFit` leitet den Ausschnitt **aus dem gerade vorliegenden Profil** ab — Gültigkeitsgrenze `1…8190`, **dieselbe**, die der Lernvertrag seit SICK-030c benutzt; nur die Entfernungsachse wird verändert, ohne Profil oder ohne brauchbaren Messwert wird **verweigert** statt geraten, und der Ausschnitt entsteht über `zoomedToRectangle`, nie über einen zweiten Gültigkeitsweg. `ScanFieldViewState` ist der gesamte Bedienzustand als **reiner Reducer** (Werkzeugwahl, Lupe, Scrollrad, Pinch, Verschieben, Ziehrahmen, Trefferprüfung, Hinweise) — die SwiftUI-Ansicht reicht nur Größe und rohe Punkte weiter und entscheidet nichts. `ScanFieldView` macht das Messfeld zum breitesten Element des Fensters, mit sichtbarer Werkzeugleiste (Lupe −/+, Gesamtansicht, **Messung einpassen**, Werkzeugwahl *Zonen wählen | Verschieben | Rahmen*). `ScanFieldPointerEvents` führt Scrollrad und Trackpad-Pinch über einen **lokalen `NSEvent`-Monitor**, dessen `NSView` per `hitTest -> nil` unsichtbar für Treffer bleibt — deshalb konkurriert er mit keiner SwiftUI-Geste.
- **`AcknowledgementOutcome.concludesLoginAttempt`** (SICK-032a3a): entscheidet, ob ein Bestätigungsausgang den laufenden Login-**Versuch beendet** — `true` nur für `acknowledged` und `rejected`, `false` für jede nicht deutbare Antwort und für den Messstrom. `switch` ohne `default`, und **lasttragend**: Der „weiterlesen"-Zweig im Reducer steht **vor** `acknowledged`/`rejected` und wird von `where !outcome.concludesLoginAttempt` bewacht, die Eigenschaft entscheidet also wirklich. Ersetzt `permitsLoginRetry` aus SICK-032a3, das von **keiner** Produktionsstelle gelesen wurde.
- **`AcknowledgementOutcome.permitsLoginRetry`** (SICK-032a3, **durch SICK-032a3a ersetzt**) und **`CommissioningFailure.operatorSummary`** (SICK-032a3, nach dem **ersten physischen Commissioning-Lauf**): `permitsLoginRetry` (`switch` ohne `default`) entschied, ob ein Bestätigungsausgang beim Login die **eine** belegte Wiederholung rechtfertigt — `false` für `acknowledged`, `rejected` und `observedScanProfile`, `true` für jede nicht deutbare Antwort. `operatorSummary` sagt in Alltagssprache und **ohne jede Nutzlast**, welcher Befund einen Lauf beendet hat; die `String`-Nutzlasten der Adapterfehler bleiben draußen (dieselbe datenfreie Grenze wie SICK-032a1).
- **`ZoneInsertStatus` und `ZoneInsertsView`** (SICK-032c1): der **Zonen-Insert-Bereich** mit Einstellkarte. `ZoneInsertStatus` (in `SickPLSPerformanceSession`, dem einzigen Modul, das alle vier Quellen kennt — Zone und Ein/Aus aus dem Editor, die Auswertung gegen das echte Profil aus dem Steuerkern, den Spiel-Slot aus der Laufzeitschicht) trägt **fünf getrennte Angaben** und nie eine gemeinsame Ampel: Rolle, Auswahl, Aktivierung, Slot und Live-Messung. `ZoneLiveStatus` unterscheidet **`noProfile` von `notHit`** — „es wurde nichts gemessen" und „es wurde gemessen und nichts getroffen" sind zwei Lagen, und der Wert kommt unverändert aus `Zone.evaluate(against:)` auf dem gerade vorliegenden Profil, **nie aus der Prognose und nie aus einem gespeicherten Vorwert**. `playabilityLabel` hält „keinem Spiel-Slot zugewiesen" und „zugewiesen, aber ausgeschaltet — die Zuweisung bleibt erhalten" auseinander (Auflage **D4**); alle Texte entstehen im Modell, nie in der Ansicht (Regel seit SICK-028). Neue Zonen entstehen **ausgeschaltet**, ausgewählt und mit geöffneter Karte (Auflage **D2**). Zahlen werden **ohne Foundation** formatiert (`DecimalText`), weil die Grenzliste dieses Moduls es nicht zulässt.
- **`WorkspaceLayout` und `WorkspaceView`** (SICK-032b4): die **instrumentorientierte Arbeitsfläche**. `WorkspaceLayout` (in `SickPLSMonitorKit`) ist die Breitenaufteilung als **reine Rechnung** — es importiert **gar nichts**, kennt weder `Zone` noch `B0ScanProfile` noch `ScanViewport` und rechnet ausschließlich mit Punktbreiten; dieselbe Haltung wie bei `ScanViewport` (SICK-032b1): Ein Layout darf Messdaten, Zonen, Zuordnung und Audiosteuerung nicht anfassen, **nicht weil es das unterlässt, sondern weil es sie nicht kennt**. Die Regel: Ränder bekommen ihre bequeme Breite, die Mitte den Rest; fiele die Mitte damit unter die **Hälfte** der Arbeitsbreite, geben die Ränder gemeinsam nach — bis auf ihre Mindestbreiten, nie darunter. Bei 1728 pt ergibt das 300 / **1088** / 340, bei 1280 pt 300 / **640** / 340. Unterhalb von 1080 pt wird **gestapelt statt gequetscht**, das Messfeld zuerst, in einem durchgehend scrollbaren Strang. `WorkspaceView` (im App-Ziel) führt das nur aus: dieselben sieben Bedienansichten wie zuvor, mit denselben Parametern, nur in drei Bereichen statt fünf gleichrangigen Spalten — links Verbindung, Verbindungsstatus, Diagnose und Scanner-Einrichtung, in der Mitte das **unveränderte** Messfeld samt Werkzeugleiste, rechts Zonen-Inserts und Theremin-Steuerung.
- **`ZoneLearningPresentation` und `ZoneLearningSectionView`** (SICK-032c2): das **geführte Hand-Learn** in der Zonenkarte — eine reine Darstellung des seit SICK-030c/030c1 fertigen Lernvertrags, **ohne neue Heuristik**. `ZoneLearningPhase` übersetzt jeden `ZoneLearningState` in genau einen Schritt und trennt „armiert, noch kein Messwert" sichtbar von „Grundprofil läuft"; `ZoneLearningBlock` benennt die beiden Sperrgründe (Zone eingeschaltet — Auflage **D2** —, anderer Vorgang läuft) **neben** dem Schritt, statt ihn zu ersetzen, damit ein Ergebnis lesbar bleibt. `operatorText` auf `ZoneLearningRefusal`, `ZoneLearningCancellation` und `ZoneLearningFailure` gibt jeder der zwölf Endlagen ihren **eigenen, handlungsorientierten** Satz — **verweigert**, **abgebrochen** und **fehlgeschlagen** bleiben drei Anzeigen, und niemand liest bloß „Fehler". `ZoneLearningNotice` beschreibt jeden Arm- und Apply-Ausgang einzeln. `ZoneLearningConfiguration.explanations` macht alle Lernparameter als **lesbare Erklärung** sichtbar (Grundprofile, wiederholte Bewegung, Mindestgröße, Bewegungsschwelle, Index-/Wertpuffer, Hintergrundabstand, Mehrdeutigkeit) — nur „Rohwerte", „Messpunkte" und „Profile", **keine erfundene physikalische Einheit** und kein neuer einstellbarer Vorgabewert. **Der Fortschritt hat keine Uhr:** Solange kein einziges echtes Profil eingetroffen ist, steht dort „Warte auf Messwerte"; danach ausschließlich die Zahlen des Lernvertrags. Fünf neue Koordinatormethoden (`startZoneLearning`, `finishZoneLearning`, `cancelZoneLearning`, `discardZoneLearning`, `applyZoneLearningCandidate`) sind der einzige Bedienweg; `ZoneBoundsText` ist jetzt die **eine** Grenzendarstellung für Insert, Karte und Lernvorschlag. **1580 Tests insgesamt.** Bild- und Bediennachweis: `.agent_handoff/sick-032c2-visual-proof.md`.
- **Weiterleitung der Controller-Änderungsmeldung im `MonitorPerformanceCoordinator`** (SICK-032c1): `zoneInserts` ist eine **berechnete** Sicht auf vier Quellen, und eine davon liegt im `ThereminPerformanceController`. Ohne die Weiterleitung zeigte ein Insert nach einer Slot-Zuweisung weiter „keinem Slot zugewiesen", obwohl die Theremin-Spalte sie längst führte — **beim Bediennachweis real beobachtet** und von einem eigenen Test samt Gegenprobe festgehalten.
- **`ScanFieldScrollEvent` und `ScanFieldZoomInput`** (SICK-032b2b, in `SickPLSMonitorKit`): die **eine** Stelle, an der aus einem Zeigerereignis ein Zoomfaktor wird. `ScanFieldScrollEvent` ist ein reiner Ereignisbericht mit genau den drei Angaben, die macOS über ein Scrollereignis macht und die nur zusammen etwas bedeuten — Strecke, **Einheit** (`hasPreciseScrollingDeltas`: Punkte beim Trackpad, Rastungen beim Mausrad) und **Richtung** (`isDirectionInvertedFromDevice`); bewusst **ohne** validierende Fabrik, weil es keine Invariante zu sichern gibt: Ein Systemereignis darf jeden Wert tragen, und was daraus wird, entscheidet `ScanFieldZoomInput` sichtbar über ein Optional. `ScanFieldZoomInput` bringt die Strecke zuerst auf **eine** Einheit (`pointsPerWheelLine`), dann in **Geräterichtung**, begrenzt sie je Ereignis (`maximumScrollPointsPerEvent`) und übersetzt sie **multiplikativ** in einen Faktor (`scrollPointsPerDoubling`). Der Pinch bleibt bei der dokumentierten Systembedeutung `1 + magnification`, wird aber auf einen positiven, symmetrischen Bereich geklammert. **`LinearScanFieldGeometry.FieldCoordinate`/`FanScreenGeometry.FanCoordinate`**: aus den bisherigen Tupeln werden Werte mit einer dritten Angabe, `isAngleDefined` — sie ist genau dann `false`, wenn der ausgewertete Punkt mit dem Fächermittelpunkt zusammenfällt und `atan2(0, 0)` keinen Wert hat.

### Geändert
- **Roadmap und Coder-Runden konsolidiert** (Supervisor-Planung mit
  anschließender Owner-Korrektur zum TX-Zielbild, 22.09.2026):
  `END_PRODUCT_ROADMAP.md` ist jetzt die einzige verbindliche Slice-Reihenfolge,
  `ROADMAP.md` der Detailvertrag und
  `.agent_handoff/sick-033-target-architecture.md` die widerspruchsfreie
  Architekturübersicht. Der Messpfad und `SickPLSMacTransport` bleiben
  RX-only; der normale Verbindungsablauf darf über die typisierte aktive
  Grenze B1, Einstellungsmodus, 38.400 und MMK bedarfsgerecht ausführen.
  Künftige Schutz-/Warnfeldfunktionen sind als SICK-040a–d offen. Learn,
  Channelstrip, AU-/MIDI-Realtests, statische Presets und Automation wurden in
  einzeln abnehmbare Runden geteilt. Die Abhängigkeitsfehler 035a/038,
  037/Automation, die unhaltbare 034c-Zählerabnahme und die AU-Einordnung als
  paralleler Ausgang sind korrigiert. Kein Produktionscode, Gerät, Port oder
  laufender Coder-Auftrag wurde verändert.
- **Die Zoomrechnung des Scanfelds ist korrigiert** (SICK-032b2b, Owner-Fehlerbericht „beim Hineinzoomen springt das Messfeld“; **kein Scanner, kein Port, kein TX/RX, kein Capture, keine neue Bedienfunktion, keine Änderung der linearen Feldskalierung**). **Zuerst ausgeschlossen statt angenommen:** Eine Layoutmessung am laufenden Fenster (`.agent_handoff/sick-032b2b-coordinate-probe.swift`) belegt, dass die AppKit-Zeigerposition aus `ScanFieldPointerEvents` **deckungsgleich** im selben lokalen Raum liegt wie `GeometryReader` und `DragGesture.location` (gleiche Größe `880 x 608`, `dx = 0`, `dy = 0`) — dort lag der Fehler nicht. Ebenso war die **Ankererhaltung bei einem einzelnen Schritt** schon vorher exakt.
- **Der Zoomfaktor ist multiplikativ statt affin** (SICK-032b2b): `1 + Strecke * k` machte einen Zoomschritt und seinen Gegenschritt zu Nicht-Kehrwerten (`1,2 * 0,8 = 0,96`). Gemessen wuchs die Entfernungsspanne bei **zehn Mal „vor und zurück gescrollt“ von `0,25` auf `0,376`** — ein Wegdriften um die Hälfte aus einer Bewegung mit unterm Strich null Strecke; jetzt bleibt sie bei `0,25`. Ebenso hing das Ergebnis daran, **wie macOS eine Bewegung in Ereignisse zerlegt** (Strecke 40 am Stück ergab `0,1786`, dieselbe Strecke in 2×20 ergab `0,1736`) — jetzt ist es bis auf die Gleitkomma-Auflösung identisch; **bitgleich wird ausdrücklich nicht behauptet**, die Tests prüfen mit `1e-12`. Auch die Begrenzung je Ereignis ist jetzt **symmetrisch** (vorher `1,4` und `0,6`, keine Kehrwerte). **Das ist keine Skalierung der Darstellung:** Die Feldachsen bleiben streng linear, und ein eigener Test belegt, dass der Exponentialausdruck an **genau einer** Stelle des Moduls steht.
- **Zeilen und Punkte werden unterschieden, die Richtung folgt dem Gerät** (SICK-032b2b): `scrollingDeltaY` zählt beim Mausrad **Rastungen**, beim Trackpad **Punkte**; beides ging ungeprüft in dieselbe Rechnung. Zehn Rastungen ergaben deshalb insgesamt nur den Faktor `1,10` — das Rad war praktisch wirkungslos —, jetzt `2,52`. `isDirectionInvertedFromDevice` blieb unbeachtet, sodass „natürliches Scrollen“ die Wirkung derselben Handbewegung umkehrte; ein Zoom ist kein Scrollen, und die Richtung folgt jetzt dem Gerät. `ScanFieldPointerEvents` reicht dafür das **ganze** Ereignis weiter und rechnet weiterhin nichts; `ScanFieldViewState.zoomAtPointer(byScrollDelta:)` ist durch `zoomAtPointer(byScrollEvent:)` ersetzt, und die Kennzahlen `scrollZoomSensitivity`/`maximumScrollDelta` sind **ersatzlos entfallen** — sie wären eine zweite Wahrheit darüber, wie stark ein Scrollereignis wirkt.
- **An der Fächerspitze wird kein Winkel mehr erfunden** (SICK-032b2b): Die innere Kante des Ausschnitts fällt vollständig auf den Fächermittelpunkt; dort hat `atan2(0, 0)` keinen Wert, und die Umrechnung gab bisher kommentarlos den Winkelanteil **`1,0`** zurück. Ein Zoom genau auf der Spitze riss den Winkelausschnitt gegen seine obere Kante (gemessen `[0,2857 … 1,0]` nach einem Schritt) und hielt ihn dort fest. Jetzt meldet die Geometrie den Fall (`isAngleDefined`), und die Winkelachse zoomt um die **Mitte des Ausschnitts** — genau wie die Lupe, die ebenfalls keine Zeigerposition hat (`[0,1429 … 0,8571]`); die Entfernungsachse behält ihren echten Anker. **Bewusst eng gefasst:** Ein Bildpunkt neben der Spitze hat eine echte Richtung und wird weiterhin als Anker benutzt.
- 17 neue Tests (SICK-032b2b), **1608 insgesamt** (MonitorKit 356), alle ohne gerenderte Ansicht, ohne Gerät und ohne Scanner — darunter Ankererhaltung über zwölf wiederholte Schritte auf beiden Achsen und über alle drei Eingabekanäle, Randklemmung, Anschlag an der Mindestspanne und nicht endliche Eingaben. Sechs Gegenproben: affine Kennlinie wie vorher bricht **5** Tests, Rastungen wie Punkte **2**, durchschlagende Scrolleinstellung **2**, entfernter Spitzen-Sonderfall **1** (die eigene Regression), zu weit gefasster Spitzen-Sonderfall **4**, entfernte Begrenzung je Ereignis **3**. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen:** Es lag kein Gerät im Zuschnitt — die Wirkung ist ausschließlich rechnerisch belegt; **Nachlauf-Ereignisse des Trackpads** werden weiterhin wie reguläre ausgewertet; **Verschieben und Rahmenzoom** rechnen mit Winkeldifferenzen und nutzen an der Spitze weiterhin den Artefaktwert (anderer Bedienweg, außerhalb des Zoom-Zuschnitts, als Folgearbeit festgehalten).
- **Ein Learn-Lauf endet mit seiner Messsitzung** (SICK-032c2a): `ZoneLearningCancellation.disconnected` gab es seit SICK-030c im Vertrag und war seit SICK-032c2 verständlich darstellbar, aber **keine produktive Stelle löste ihn aus** — ein sammelnder Lernvorgang blieb bei einem ausdrücklichen Trennen und bei einem unerwarteten Stromende stehen und hätte nach einer Wiederverbindung mit einem **alten Grundprofil** weitergerechnet. Jetzt beendet der `MonitorPerformanceCoordinator` einen **noch sammelnden** Lauf genau einmal mit `.cancelled(.disconnected)`: sofort beim ausdrücklichen `disconnect()` (damit die Karte die Bedienhandlung unmittelbar spiegelt) und über das seit SICK-030a bestehende `ScanSession.portReleased` für **jedes andere** Ende — unerwartetes Stromende, Lesefehler und **auch ein gescheitertes Öffnen**. Dieses Ereignis feuert genau einmal je Verbindungsversuch, nach dem tatsächlichen `close()`, auf dem Main Thread und generationsgeprüft; deshalb kam **kein zweites Profilabonnement, kein Timer und keine Zustandsbeobachtung** hinzu, was ein neuer Grenztest (`testThereIsExactlyOneProfileAndOnePortReleaseSubscription`) am Quelltext erzwingt. **Bereits gefallene Ergebnisse — Vorschlag, Verweigerung, Abbruch, Fehlschlag — werden nie überschrieben**, und ein doppeltes Ende erzeugt keine zweite Zustandsänderung; die tragende Wache dafür ist das bestehende `guard learning?.isCollecting == true` in `ZoneEditorState.cancelLearn` (SICK-030c), die gleichlautende Prüfung im Koordinator ist ehrlich benannte Redundanz. Eine Trennung legt nie eine Sitzung an, fasst keine Zone, kein Ein/Aus, keine Rolle und keinen Spiel-Slot an und erzeugt **kein Gate und keinen Audiostart**; ein armierter Lauf ohne Verbindung überlebt ein `disconnect()` ins Leere. **1591 Tests insgesamt** (11 neu), alle gegen Fakes — kein Gerät, kein Port, kein TX/RX.
- **Die Zonenkarte führt das Hand-Learn** (SICK-032c2): Der Lernvertrag lag seit SICK-030c fertig und geprüft **unbedient** im Modell; jetzt ist er in der bestehenden `ZoneCardView` bedienbar. `PerformanceSessionBoundaryTests` erzwingt am Quelltext des App-Ziels, dass die Ansicht weder `editorState.armLearn`/`applyLearnCandidate`/`finishLearn`/`cancelLearn`/`discardLearn`/`ingestLearningProfile` noch `editorState.learning` anfasst **und** keinen eigenen Lernfortschritt führt (`ZoneLearningAccumulator`, `ZoneLearningSession`, `ingestLearningProfile`, `profilesSeen`, `ZoneLearningConfiguration` sind im App-Ziel verboten) — ein lokaler SwiftUI-Zähler oder ein zweiter Profileingang lässt `swift test` fehlschlagen, beides als Gegenprobe belegt. Der Profilstrom bleibt der **eine** aus `MonitorPerformanceCoordinator.receive`; es kam kein Timer, keine Uhr, kein zweites Abonnement und kein Timeout hinzu. Armieren und Übernehmen bleiben an die **ausgeschaltete** Zone gebunden, Übernehmen schaltet nicht ein und weist keinen Slot zu, und Lernen startet weder Audio noch Gate. Nebenbei korrigiert: die Erklärung schrieb „1 Messpunkte je Seite" — die Vorgabe ist `1` (beim Bildnachweis aufgefallen, jetzt von einem Test festgehalten).
- **Die fünf gleichrangigen Spalten sind entfallen** (SICK-032b4): `ContentView` platziert keine Bedienansicht mehr selbst, sondern reicht die Modelle an `WorkspaceView` durch; die ziehbaren `HSplitView`-Trenner sind **weg**. Das ist der Preis dafür, dass die Breitenpriorität der Mitte eine **prüfbare Regel** ist und nicht davon abhängt, wohin jemand zuletzt einen Trenner gezogen hat. Die Fenster-**Mindestbreite** fiel von 1580 auf 680 Punkte — sie war breiter als so mancher Bildschirm und verhinderte damit Vollbild; unterhalb der Stapelschwelle bleibt alles bedienbar, nur untereinander. `WorkspaceStructureTests` erzwingt am Quelltext, dass **genau** die sieben vorhandenen Bedienansichten vorkommen, jede genau einmal und jede im vorgesehenen Bereich, und dass in der Arbeitsfläche **kein** neuer Bedienpfad steht (kein `onAppear`/`onChange`/`Timer`/`DispatchQueue`, kein `connect`/`start`/`stop`/`sendGate`, kein direkter Editor- oder Zuweisungszugriff); ein Verhaltenstest rechnet 120 Fensterbreiten durch und weist nach, dass danach **jeder** beobachtbare Zustand bitgleich ist — Audio, sämtliche Gate-Zähler, Verbindung, Portbesitz, Zonen und Rollenzuweisung. **1547 Tests insgesamt.** Bild- und Bediennachweis: `.agent_handoff/sick-032b4-visual-proof.md`.
- **Die Zonenliste und der „Inspector" sind ersetzt** (SICK-032c1): `ZoneListView` und `ZoneInspectorView` sind **entfallen**; an ihrer Stelle stehen Inserts und eine Einstellkarte, die ausschließlich über Methoden des Koordinators schreiben — kein lokaler SwiftUI-Zonenzustand, kein zweiter Entwurf, kein zweiter Zuordnungsweg. `PerformanceSessionBoundaryTests` erzwingt das am Quelltext des App-Ziels: Ein direkter Zugriff auf `editorState.addZone`/`setZone`/`removeZone`/`select`/`apply`/`updateDraft`/`commitDraft` oder ein zweiter Zuweisungsweg (`roles.select`, `reconcileZones`, `noteZones`) lässt `swift test` fehlschlagen. Das Ausschalten einer zugewiesenen Gate-Zone löst weiterhin **genau das bestehende** sichere Gate-Off aus (Auflage **A6**, SICK-030b1) — es wurde kein neuer Gate-Pfad erfunden —, und Wiedereinschalten erzeugt weder Gate-On noch Audiostart. **1529 Tests insgesamt.** Bild- und Bediennachweis: `.agent_handoff/sick-032c1-visual-proof.md`.
- **SICK-032b3 ist vom Supervisor fachlich abgenommen** (Stand SICK-032a5a): Die gezielten Tests bestätigen die lineare direkte Zonenbearbeitung, die Werkzeugtrennung und die Abwesenheit von Gate- und Audio-Nebenwirkungen. **Offen bleibt allein ein sichtbarer Bild- und Bediennachweis mit Griffen** — ein niedriger Folgepunkt, kein Modell-, Geometrie- oder Sicherheitsbefund; er blockiert die nächste Oberflächenphase nicht.
- **Erster vollständiger Gerätelauf** (22.09.2026, Owner-Aktion, kein Slice): Der Scanner antwortete bei 9600 Baud mit seiner Identität, der aktive Ablauf schaltete ihn auf **38.400 Baud** um, und die neue Rate wurde durch eine **valide B1-Identität** bestätigt; nach der Anforderung für kontinuierliche Minimalmessung empfängt die App bei 38.400 Baud einen echten **B0-Strom mit 90 Punkten und 12,5 Hz**, `partialScanIndex` durchgehend 0, `trailingBytes` der Länge 1. Die **unmittelbare Antwort** auf die Modusanforderung war **nicht lesbar** — belegt ist der eingetretene Messzustand, nicht der Wortlaut dieser Antwort. **Nicht belegt:** eine fünfminütige Stabilitätsmessung, die Persistenz über einen Geräteneustart, die Ursache anfänglicher CRC-Verwerfungen und jede Rate unabhängig von Punktzahl und Messmodus. Damit ist die frühere Aussage überholt, 9600 sei die aktuelle Gerätewahrheit und der Weg auf 38.400 sei „nicht freigegeben und nie ausgeführt".
- **`ROADMAP.md` konsolidiert** (SICK-032a5, reiner Dokumentationsslice — kein Produktionscode, kein Port, kein Gerät, kein TX, kein Capture, kein Git): Die Datei war zu einer Slice-Chronik von über zweitausend Zeilen mit teils widersprüchlichen Aussagen angewachsen. Sie beschreibt jetzt ausschließlich **Ziel, belegten Stand und geplante Schritte** — Produktziel und Leitplanken, eine Evidenztabelle mit verbleibenden Grenzen, die aktive Oberflächenphase (SICK-032c1, 032c2, 033a, 033b, 033c, 035), die Instrument- und Steuerphase (SICK-036a/b/c, 037), die realen Meilensteine und das Release (SICK-034, 034b, 034c, 038, 039) sowie ein Register der wirklich offenen Risiken; je Schritt Ziel, Abhängigkeit, Akzeptanz und Nachweisart, und offline Baubares getrennt von Owner-Geräteaktionen. **Die Historie ist nicht gelöscht, sondern in `PROJECT_LOG.md` und den Checkpoint verlagert**; die frühere Gliederung `R0`…`R8` und der „Freigegebene Prototypenpfad" (SICK-013) sind damit Historie, der Spieltestplan steht korrigiert unter SICK-038. README, CLAUDE, Checkpoint, CHANGELOG und PROJECT_LOG geben dieselbe aktuelle Wahrheit wieder, ohne die Roadmap zu duplizieren.
- **Die laufende Scanansicht zeichnet linear durch den Ausschnitt** (SICK-032b2) — damit ist die in SICK-032b1 bewusst offen gelassene Anbindung vollzogen. `PolarScanView` und `ZoneOverlayView` gehen ausschließlich über `LinearScanFieldGeometry`; die Anzeigekompression `PolarProfileGeometry.displayRadiusFraction` (vierte Wurzel, SICK-012b) kommt in beiden **nicht mehr** vor und wird von einem Quelltexttest ferngehalten. **Messkurve und Zonenfläche teilen sich jetzt dieselbe Geometrie** — zeichnete die eine linear und die andere komprimiert, läge eine Zone nicht mehr über den Messpunkten mit demselben Rohwert, ein echter Fehler. Die in SICK-032b1 benannte Lücke schließt **nicht** ein erfundener Start-Ausschnitt, sondern „Messung einpassen": Ein 90-Punkt-Profil mit Rohwerten in der Größenordnung des einzigen dokumentierten Mitschnitts füllt danach das Bild (0,26…2,06 % des Radius in der Gesamtansicht, 8,3…91,7 % nach dem Einpassen). **Der Ausschnitt bleibt reine Ansicht:** keine Zone, kein Entwurf, kein Learn-Ergebnis, kein Mapping und keine Audiosteuerung wird verändert — belegt über bitgleiche Auswertungen und Quelltextprüfungen in beide Richtungen. Der Zustand liegt als `@State` in der Ansicht und **bewusst nicht** beim Koordinator. `ZoneOverlayView` hat zugleich **ihre eigene Geste verloren**: Im Scanfeld gibt es genau eine Ziehgeste, ihre Bedeutung entscheidet das sichtbare Werkzeug, und die Trefferprüfung liegt als reine, testbare Funktion im Modell — mit **unveränderter Auswahlregel**. **Ehrliche Grenze: es ist noch kein echtes Profil in der linearen Darstellung zu sehen** (kein Gerät im Zuschnitt, keine gespeicherte Rohaufnahme). **1460 Tests insgesamt.**

- **`ZoneHandleGeometry` und das Werkzeug „Zone bearbeiten"** (SICK-032b3): die **direkte, lineare Zonenbearbeitung im Scan-Feld**. `ZoneHandleGeometry` ist **eine** Quelle für Griffplatzierung **und** Trefferprüfung — lägen sie an zwei Stellen, könnten sie unbemerkt auseinanderlaufen, weil ein leicht danebenliegender Trefferbereich wie ein ungenauer Klick aussieht und nicht wie ein Fehler. Vier Griffe auf den Kantenmitten (je genau eine Grenze), dazu die Fläche für die ganze Zone; **Griffe schlagen die Fläche**, und unter mehreren gewinnt der **nächste** — ohne diese Reihenfolge wäre eine schmale Zone über ihre Griffe gar nicht bedienbar. Der Trefferradius (14 pt) ist **reine Treffergröße, nie eine fachliche Mindestspanne** (Befund **N7**). `ZoneGeometryReducer` rechnet jetzt gegen `LinearScanFieldGeometry` statt gegen `FanScreenGeometry` plus Anzeigekompression: **die vierte Wurzel ist damit auch aus dem Bearbeitungsweg verschwunden**, und ein Quelltexttest hält sie in beide Richtungen fern. `LinearScanFieldGeometry.isUsableForEditing` ist der **gemeinsame** Entartungsschutz von Treffer und Umrechnung — zwei getrennte Prüfungen könnten auseinanderlaufen, und dann träfe man einen Griff, dessen Geste anschließend abgelehnt wird.
- **Werkzeugtrennung statt verdeckter Vorrangregel** (SICK-032b3): `ScanFieldTool` bekommt `editZone`; nur darin bearbeiten Griffe und Fläche die **ausgewählte** Zone, und dabei wandert weder der Ausschnitt noch wechselt die Auswahl. Die zuvor erwogene Regel „Treffer auf Griff/Zone gewinnt, sonst Verschieben" ist **bewusst nicht** gebaut: Sie hätte das Verschieben über einer Zone unmöglich gemacht und die Bedienung auf eine unsichtbare Regel gestützt. `ScanFieldViewState` entscheidet nur, **was** eine Geste bedeutet, und gibt einen `ZoneGeometryCommand` heraus; geschrieben wird ausschließlich über `ZoneEditorState.apply(_:)` und den geprüften Reducer, offene Inspector-Entwürfe werden daraus neu abgeleitet (Auflage **D3**). Jede Geste rechnet aus der **Gesamtverschiebung seit dem eingefrorenen Gestenbeginn** — der Ausgangswert liegt als `let` in der Gestensitzung und kann strukturell nicht mitwandern. **Keine Aktivierung, Rollen-, Slot-, Gate-, Audio-, MIDI-, Learn-, Profil-, Viewport- oder Scannerwirkung. 1497 Tests insgesamt.**- **`PolarScanView` bleibt bewusst unverändert bei der Anzeigekompression** (SICK-032b1). Die Owner-Vorgabe verlangt eine lineare Scanansicht, aber sie verlangt sie **zusammen mit** frei wählbarem Ausschnitt. Die Zoomwerkzeuge entstehen erst in SICK-032b; eine jetzt auf linear umgestellte Ansicht zeigte bei den einzigen real gemessenen Rohwerten (≈ 21…169 von 8191, SICK-012, **eine** Sitzung, also ≈ 0,26…2,06 % des Radius) praktisch nichts mehr und böte nichts an, um das zu ändern. Ein engerer Start-Ausschnitt wäre eine Kalibrierungsvermutung aus einer einzigen Messsitzung. **1409 Tests insgesamt.**
- **Die Login-Wiederholung wartet die dokumentierte Frist ab** (SICK-032a3a, Korrektur eines in SICK-032a3 eingebauten Vertragsfehlers nach Supervisor-Prüfung). SICK-032a3 hatte die Wiederholung an die **unlesbare Antwort selbst** gehängt und damit **zu früh** ausgelöst: Ein nacktes `06` hätte das zweite Telegramm Millisekunden nach dem ersten hinausgehen lassen, und eine **spätere gültige `A0`-Antwort in derselben Frist** wäre gar nicht mehr für das erste Telegramm gezählt worden. `SICK Doku/integration/active-sequences.md` §2 belegt die Wiederholung **nach dem 2-Sekunden-Fenster**. Jetzt ist ein Login-Versuch **ein Lesefenster**: Was den Versuch nicht beendet, wird nur in einer **fensterlokalen** Marke gemerkt, der Reducer antwortet `.none`, und der Executor liest in **derselben absoluten Frist** weiter — dieselbe `.none`-Regel trägt seither Rauschen und unlesbare Antworten. **Erst `.deadlineReached`** löst die eine identische Wiederholung aus, über unverändert **eine** Sendestelle und **ein** Budget, auf **derselben** offenen Verbindung, nie eine dritte Sendung. `applyDeadline` meldet erst den Befund, dann das Fristende. **`rejected` beendet weiterhin sofort**, `acknowledged` führt weiter. Der gemeldete Grund ist der **dieses** Fensters — „`06`, dann Stille" ist deshalb ehrlich `loginUnanswered`, nicht `loginAmbiguous`; die SICK-031a-Regel **E1** entscheidet weiterhin, **wie** ein Fenster heißt, aber nicht mehr, **ob** wiederholt wird. **Unverändert offen:** Dieselbe Schwäche besteht bei den Wartefenstern für Baudwechsel, Messmodus und Identität (der erste CRC-valide Frame beendet sie) — außerhalb des Auftragszuschnitts, empfohlene Folgearbeit. Ein nacktes `06` gilt weiterhin **nicht** als Bestätigung. **1365 Tests insgesamt.**
- **Bedienung der Scanner-Einrichtung auf Alltagssprache und weniger Klicks umgestellt** (SICK-032a2): „Anschluss" statt Port, „Scanner vorbereiten", „Verbindung prüfen", „Was bisher geschah". Das Passwortfeld mitten im Ablauf ist **entfallen**; fehlt oder passt der Wert nicht, verweist der Hinweis auf die Einstellungen und es geht nichts hinaus. `confirmPendingStep(secretText:)` heißt jetzt parameterlos `confirmPendingStep()`; die Fälle `refusedMissingSecret`/`refusedInvalidSecret` sind durch `refusedScannerPassword(ScannerPasswordUsability)` ersetzt. **Bewusste Lockerung von Auflage E3:** Die Zwei-Handgriff-Regel gilt nur noch für Schritte, die den Scanner verändern. **1349 Tests insgesamt.**
- **Der Login-Retry-Vertrag folgt dem realen Befund** (SICK-032a3). **Der erste physische Commissioning-Lauf hat stattgefunden und ist nicht durchgelaufen:** Bei 9600/8E1 war die Identität `B1` bestätigt, das Login bekam beim ersten Versuch nur eine **unlesbare** Antwort, und der Ablauf brach ab — Baud- und Messmodus-Telegramm wurden **nie gesendet**, am Gerät wurde nichts verändert. Ursache war der Sammelzweig `.acknowledgement` in `CommissioningModel.applyDuringLogin`, der sofort in `.loginAmbiguous` fiel; die von `SICK Doku/integration/active-sequences.md` §2 belegte Wiederholung hing allein am Fristablauf. Jetzt rechtfertigt **jede nicht deutbare Antwort** dieselbe eine Wiederholung, über **eine** gemeinsame Sendestelle `retryLogin(from:atMillis:)` und **ein** gemeinsames Budget (`attempt < maximumLoginAttempts`) — nie eine dritte Sendung, in keiner Reihenfolge der beiden Ursachen, und **ohne Portwechsel** in derselben offenen Verbindung. **`rejected` wird nie wiederholt**, `acknowledged` führt weiter, ein Messstrom verbraucht keinen Versuch. Der gemeldete Grund bleibt der zuletzt beobachtete (`loginUnanswered` nach Frist, `loginAmbiguous` nach Lesebefund); die SICK-031a-Regel **E1** entscheidet weiterhin, welcher es ist. **Am Ablauf danach ändert sich nichts:** erst die belegte 38400-Verifikation, dann der bestätigungspflichtige Messmodus-Schritt. Ehrlichere Texte: Ein Fehlschlag nennt jetzt den Befund statt nur „fehlgeschlagen", der bestätigte Messmodus heißt „Anforderung angenommen, Wirkung noch zu belegen", und der zweite Login-Versuch ist als „zweiter, letzter Versuch" sichtbar. **Ausdrücklich nicht getan:** Ein in der Beleglage beobachtetes **nacktes `06`** gilt weiterhin **nicht** als Bestätigung. **1359 Tests insgesamt.**

- **Genau ein Commissioning-Bedienmodell je App** (SICK-032a): `SickPLSMonitorApp` erzeugt Koordinator und `CommissioningControlModel` in seinem `init()` und reicht beide an `ContentView`; ein zweites Bedienmodell hätte einen zweiten Lauf, eine zweite Sperre und einen zweiten Anspruch auf denselben Port. `PerformanceBoundaryTests.testTheAppOwnsExactlyOnePerformanceController` prüft deshalb nicht mehr eine feste Deklarationszeile, sondern dass es **genau eine** Erzeugungsstelle des Integrationsmodells gibt und sie in der App liegt.
- **Datenfreie Fehlergrenze der Commissioning-Bedienung** (SICK-032a1, Supervisor-Befund zu SICK-032a): `CommissioningRunUnavailableReason.transportRefused(String)` ist **ersatzlos entfallen** und durch das **feldlose** `transportUnavailable` ersetzt. Vorher übernahmen zwei Stellen — der Auffangzweig von `CommissioningControlModel.confirmPendingStep(secretText:)` und der Transportzweig von `SystemCommissioningRunFactory.makeRun(portPath:)` — die Beschreibung eines **beliebigen** `Error` über `String(describing:)` in einen sichtbaren `CommissioningNotice`. Die realen Adapter erzeugen heute kurze, datenfreie Texte, aber ein fremder `CommissioningRunProviding`, ein fremder Opener oder ein künftiger Transport könnte in seiner Beschreibung Port-, Payload- oder Geheimnisdaten tragen; ein Wert, den es nicht gibt, kann nicht durchsickern. Es bleiben **zwei** Nutzlastfälle, beide mit ausschließlich **eigenen, unmittelbar davor geprüften** Werten (`noPortSelected`, `pathNotAllowed(String)` mit dem selbst ausgewählten Pfad); ein bereits typisierter Grund wird **unverändert durchgereicht** statt ein zweites Mal bewertet. Der Bedienfehler bleibt sichtbar und typisiert, der Hinweis ist ein fester Satz. `CommissioningControlBoundaryTests.forbiddenIdentifiers` verbietet dem ganzen Modul zusätzlich `String(describing:`, `String(reflecting:`, `localizedDescription` und die Interpolation eines Fehlerwerts. Neue interne Naht `SystemCommissioningRunFactory(makeTransport:)`, damit der Fremdfehlerzweig überhaupt erreichbar und belegbar ist — die reale Transportgrenze prüft im Initialisierer nur den Pfad, den die Fabrik selbst schon davor prüft, der Zweig war also toter Code. 9 neue Tests (`CommissioningErrorBoundaryTests`) mit einem **erfundenen** Markertext an **beiden** Entstehungsstellen, geprüft über Rückgabe, Notice, Audit, `String(describing:)`, `String(reflecting:)` und einen `Mirror`-Gang bis Tiefe 5. **1320 Tests insgesamt.**

- `checksumMismatch`-Fehlerfall von `expected`/`computed` auf `received`/`computed` umbenannt (SICK-004, Revisor-Review-Finding N1).
- `B0ScanProfile.decode`: Mindestlängenprüfung von `payload.count == 3+2*N` auf `>= 3+2*N` gelockert; `4+2*N` gilt seither als erwartete Drahtlänge (SICK-006, Owner-Korrektur nach Revisor-Review-Finding H1).
- `StreamParser`: strukturell unerreichbarer `preconditionFailure`-Zweig durch defensive Byte-Verwurf-Behandlung ersetzt (SICK-007, Revisor-Review-Finding N1 aus `review-sick-004.md`).
- RX-only-Validierungscheckliste (Checkpoint): Kriterium 2 von „`partialScanIndex` intern konsistent" auf „erwartet durchgehend 0, jede Abweichung melden" geschärft (SICK-008, Revisor-Review-Finding M1 aus `review-sick-007.md`).
- `StreamParser.finish()`-Kopfkommentar: ausdrückliche Abgrenzung ergänzt — nur für echtes Stromende, nicht für Lesepause/Timeout (SICK-008, Revisor-Review-Finding N4 aus `review-sick-007.md`).
- `DarwinSerialPortOpener.openFlags`: `O_RDWR` auf verbindliches `O_RDONLY` geändert, kein automatischer Fallback (SICK-010, Revisor-Review-Finding M4 aus `review-sick-009.md`).
- `DarwinSerialPortFileDescriptor.read`: liest bei gesetztem `POLLIN` immer zuerst, unabhängig von gleichzeitigem `POLLHUP` (M1); `poll`/`read`-Fehler werden über `errno` klassifiziert statt pauschal als Timeout zu erscheinen, `POLLNVAL` zählt zur Stromende-Maske (M2); `deinit` schließt einen vergessenen Deskriptor als Sicherheitsnetz (M3) — alle drei aus `review-sick-009.md` (SICK-010).
- `DarwinSerialPortOpener.open(atPath:)`: prüft `cfsetispeed`/`cfsetospeed`-Rückgabewerte (N2) und löscht Darwins eigene Flow-Control-Bits `CDTR_IFLOW`/`CDSR_OFLOW`/`CCAR_OFLOW` (N3), aus `review-sick-009.md` (SICK-010).
- `SerialPortReadOutcome.closed`-Kopfkommentar: Invariante „impliziert bereits geschlossen" explizit dokumentiert (SICK-010, Revisor-Review-Finding N1 aus `review-sick-009.md`).
- `SerialPortSettings.baudRate` entfernt (war fest `38_400`); `SerialPortOpener.open(atPath:)`, `DarwinSerialPortOpener.open(atPath:)` und `SickPLSSerialConnection.open(portPath:opener:)` verlangen jetzt zusätzlich einen expliziten `baudRate: SerialPortBaudRate`-Parameter ohne Default (SICK-010, Owner-Scope-Änderung 2026-09-21).
- `BaudProbe.probeOnce`: `timeoutMilliseconds` ist jetzt eine harte, monotone Gesamtfrist ab dem Sendezeitpunkt des Probe-Frames statt eines bei jedem Leseversuch neu beginnenden Timeouts — fortlaufendes Rauschen (z. B. autonome B0-Broadcasts) konnte einen Versuch zuvor faktisch unbegrenzt verlängern. `BaudProbe.run`/`probeOnce` bekommen einen neuen `clock: MonotonicClock`-Parameter mit Default `DarwinMonotonicClock()`, bestehende Aufrufer bleiben kompatibel (SICK-011a).
- `ScanSession`/`ReadLoopWorker` (SICK-012a): zwei Retain-Cycles geschlossen. `ReadLoopWorker.start()` erfasst `self` in der `DispatchWorkItem`-Closure jetzt schwach (`[weak self]` statt `[self]`) und löscht `workItem` per `defer` sofort nach jedem Rückkehrpfad von `run()` — vorher hielten sich Worker und sein eigener `DispatchWorkItem` gegenseitig unbegrenzt am Leben. `ReadLoopWorker.onEvent` hat jetzt die Signatur `(Event, ReadLoopWorker) -> Void`: Der emittierende Worker wird als Parameter übergeben statt von der in `ScanSession.connect(portPath:baudRate:)` erzeugten Closure eingefangen zu werden — vorher bildete diese Closure (gespeichert auf demselben Worker, den sie festhielt) einen zweiten Zyklus. `ScanSession.worker` ist jetzt `internal` statt `private` (testbar per `weak`-Referenz).
- `ReadLoopWorker.workItem` (SICK-012b): jetzt eine über ein `NSLock` synchronisierte berechnete Eigenschaft statt einer unsynchronisiert von zwei Threads (Aufrufer-Thread in `start()`/`stop()`, Hintergrund-Thread in `run()`/`defer`) gleichzeitig gelesenen/geschriebenen Variable — `DispatchWorkItem.cancel()`/`.isCancelled` sind für sich threadsicher, die Speicherstelle selbst war es nicht. Kein Verhaltensunterschied für Aufrufer.
- `PolarScanView.screenPoint(for:center:radius:)` (SICK-012b): verwendet für die Bildschirmposition jetzt `displayRadiusFraction` statt des linearen `radiusFraction` — reale Rohwerte (≈ 21...169) waren linear gegenüber der festen 8191er-Grenze praktisch unsichtbar (< 3 % des Anzeigeradius).
- `ROADMAP.md` (SICK-013): R5 trägt einen Aktualisierungshinweis — der ursprünglich skizzierte „kleine `AVAudioEngine`-Synth-Prototyp" ist durch die neuen Schritte 5–8 des Prototypenpfads (C++-DSP-Kern, Audioausgabe-Integration, interne Sends, Audio-Unit-Rack) ersetzt; R5s Originaltext bleibt als historischer Ausgangspunkt stehen. Die „Explizit außerhalb des aktuellen Umfangs"-Liste ist präzisiert: Zonen selbst sind seit SICK-013 kein blanko-ausgeschlossenes Thema mehr, nur Zoneneditor-UI, physikalische Einheiten/Winkel/Gesten und musikalische Mappings bleiben ausdrücklich außerhalb.
- `PolarScanView` (SICK-014): nutzt jetzt die gemeinsame `FanScreenGeometry` statt eigener, privater Bildschirmtrigonometrie — identisches Bildergebnis, keine zweite Kopie derselben Formel neben `ZoneOverlayView`.
- `ROADMAP.md` (SICK-014): Prototypenpfad-Schritt 3 („Grafischer Zoneneditor") als erledigt markiert; neuer „Stand (SICK-014...)"-Absatz in R4.
- `ROADMAP.md` (SICK-015): Prototypenpfad-Schritt 4 („Bewegungsprognose") als erledigt markiert; neuer „Stand (SICK-015...)"-Absatz in R4. Die beiden Leitplanken-Punkte zur Windows-Dokumentation sind von „kommt noch" auf „liegt vor und ist eingeordnet" umgeschrieben; der R3-Absatz zur Ratenabweichung hat einen Nachtrag dazu (≈ 12,5 Hz sind an 90 Punkte bei 38 400 gebunden); die „Explizit außerhalb des aktuellen Umfangs"-Liste hält jetzt ausdrücklich fest, dass die vorliegende externe Dokumentation den Baud-/Messmoduswechsel technisch belegt, aber **keine Freigabe ersetzt**.
- `ThereminVoice::render()`/`submitGateEvent()` (`SickSynthDSP`, SICK-016a, Befund H1): **Frame-Offsets werden nicht mehr verkürzt.** `frameOffset` zählt Frames ab Beginn des **nächsten** `render()`-Blocks, und das Ereignis wirkt exakt auf dessen Frame `frameOffset` — auch über mehrere kürzere Blöcke hinweg. Zuvor holte `render()` nicht ausgelöste Ereignisse am **Blockende** nach; Offset 500 bei einem 128er-Block wirkte damit auf dem globalen Frame 128 statt 500, und der Kommentar „entspricht zeitlich genau dem Versatz `frameCount`" beschrieb diesen Fehler als Vertrag. Jetzt werden verbleibende Ereignisse über die Blockgrenze **fortgeführt** (Offset minus gerenderte Blocklänge; `offset == frameCount` wirkt auf Frame 0 des Folgeblocks) — nichts wird zu früh ausgelöst, nichts geht verloren.
- `ThereminVoice::submitGateEvent()` (SICK-016a): hält die feste Warteschlange per **stabiler Einfügesortierung** nach Offset sortiert, damit Einreichungen in beliebiger zeitlicher Reihenfolge zulässig sind; bei **gleichem** Offset bleibt die Einreichreihenfolge erhalten (`gateOn` dann `gateOff` auf demselben Frame ergibt etwas anderes als umgekehrt, und zwar wohldefiniert). Höchstens 15 Verschiebungen auf einem festen Array — der Steuerpfad bleibt allokations-, lock- und exceptionfrei. Zuvor setzte die Sampleschleife eine Sortierung voraus, die nirgends hergestellt wurde.
- `ThereminVoice::render()` (SICK-016a): ein **abgelehnter** Aufruf (Nullzeiger, leerer oder übergroßer Block, fehlende Konfiguration) lässt die Gate-Warteschlange jetzt **unverändert** stehen, statt sie zu leeren — dabei vergeht keine Audiozeit, Phase, Hüllkurve und Filter schreiten ebenfalls nicht fort. `reset()` und `configure()` löschen die Warteschlange unverändert weiter. Überlauf und negativer Versatz bleiben über `Diagnostics::droppedGateEvents` sichtbar gezählt; an den übrigen DSP-Semantiken wurde nichts geändert. 6 neue Tests (Kernregression Offset 500 über 128er-Blöcke; Offset genau Blockende; unsortierte Einreichung; gleiche Offsets in Einreichreihenfolge; neu eingereichtes Ereignis vor einem fortgeführten; abgelehnte Renderaufrufe), der alte Fall `gateEventBeyondTheRenderedBlockIsNotLost` ist ersetzt, weil er die Fehlsemantik zementierte.
- Interne Delay-/Hall-Sends in `SickSynthAudio` (SICK-018): zwei **parallele Sends** neben dem trockenen Signal, gebaut aus **etablierten Systembausteinen** — `AVAudioUnitDelay` und `AVAudioUnitReverb` (beide ab macOS 10.10), keine externe Bibliothek und keine selbst erfundene Reverb-Architektur. Die Quelle geht direkt und ungedämpft in den Hauptmischer (trocken, immer hörbar, bewusst kein Dry-Regler), zusätzlich über je einen eigenen Sendmischer in Delay und Hall und von dort zurück in den Hauptmischer; der Sendpegel ist die `outputVolume` des jeweiligen Sendmischers, wodurch beide Wege unabhängig sind. Beide Effektknoten laufen auf `wetDryMix = 100` (für einen Send zwingend, sonst legte ihr eigener Dry-Anteil das trockene Signal ein zweites Mal in den Mischer). Bei Sendpegel `0` ist die Ausgabe das unveränderte trockene Signal. **Die gesamte Effektverarbeitung liegt hinter dem Renderblock in Apples Engine — der Renderpfad ist unverändert und sieht die Effektparameter nicht.**
- `EffectParameters` (SICK-018): kleiner, validierter Parametersatz aus Delay-Send, Verzögerungszeit, Rückkopplung, Hall-Send und Hallcharakter. Validierende Fabrik `build(...) throws` nach dem Hausmuster mit eigenem Fehler je Regel und **ohne stille Klammerung**; nicht endliche Werte werden ausdrücklich abgelehnt. Die Delay-Rückkopplung ist bei **85 %** gedeckelt, obwohl `AVAudioUnitDelay` bis ±100 % zuließe — ab 100 % klingt die Verzögerung nicht mehr ab, sondern schaukelt sich auf. `EffectParameters.neutral` hat beide Sends auf `0`. Der Hallcharakter ist eine geschlossene Auswahl über Apples Werkspresets statt einzelner Raumregler.
- `ThereminAudioEngine.update(effects:)` und `AudioOutputHost.applyEffectParameters(_:)` (SICK-018): reine Steuer-Thread-Vorgänge an bereits verbundenen Knoten; sie bauen die Signalführung nicht um und **starten die Ausgabe nie**. Die Effektkette wird bei `prepare` immer aufgebaut und bei `stop`/Formatwechsel vollständig abgebaut — keine Doppelverbindung, kein liegengebliebener Knoten. `start()` reicht die gewollten Werte ausdrücklich an die frisch gebaute Kette durch, weil ein neu erzeugter `AVAudioMixerNode` sonst auf voller Lautstärke, also auf vollem Send, stünde. 18 neue Tests ohne Audiogerät, darunter der Nachweis, dass der trockene Pfad bei jedem Sendpegel bitgleich bleibt. **Kein Scannerwert→Effekt-Mapping; die `effectSend`-Zonen bleiben unangeschlossen.**
- Stetiger Prognoseausgang und vollständiger Gate-Lebenszyklus (SICK-026, Nachschärfung zu SICK-022…025 nach dem unabhängigen Meilenstein-Review `.agent_handoff/review-sick-025.md`; **kein neues Target, kein neuer Anschluss, keine Erweiterung des Umfangs**). **H1 — der Ton sprang nach jedem Profil zurück:** `ControlValuePredictor.estimate(at:)` lieferte zum Sample-Zeitpunkt die rohe Messung, jeden Augenblick danach aber die **gefilterte Position**, die bei `alpha = 0,5` um die Hälfte des Residuums dahinter liegt; da `ThereminRuntime` beim Profil den Messwert anwendet und Millisekunden später zum ersten Mal schätzt, entstanden **zwei Sprünge je Profil, der zweite entgegen der Bewegungsrichtung** (im Review gemessen: −217 Cent bei ≈ 4 Hz, −68 Cent bei ≈ 12,5 Hz). Der Owner hat die robuste Option freigegeben — **jeder echte Messwert bleibt am Profilzeitpunkt die hörbare Wahrheit, geglättet wird nur die Geschwindigkeit**: Der Ausgang verankert jetzt an `lastObservedValue` und nutzt vom Filter ausschließlich die geglättete Geschwindigkeit, ist damit am Sample-Zeitpunkt **für jedes zulässige `alpha` stetig**. Der interne Filter bleibt unverändert (Position und Geschwindigkeit werden weiter alpha-beta-korrigiert und gehen unverändert in Vorhersage, Residuum und Ausreißerprüfung ein); **Stale-, Horizont- und Ausreißerregeln sowie `startingPoint` sind unverändert** — `alpha` musste nicht auf `1` gezogen werden. **M1 — abgewählte Gate-Zone ließ den Ton hängen:** Nach einem Gate-On meldete der Steuervertrag bei einer Zuordnung ohne Gate-Zone zu Recht `.unassigned` und tat nichts, und der Eingangsverlust-Failsafe griff gerade **nicht**, weil laufend Profile eintrafen; `ThereminRuntime.ingest` erkennt den Übergang „vorher zugewiesen, jetzt nicht mehr" jetzt selbst und löst über die neue `ThereminAudioAdapter.releaseGateAfterUnassignment()` ausdrücklich — dieselbe Annahme-/Ablehnungs-/Wiederholungssemantik wie der Failsafe (abgewiesenes Off wird beim nächsten echten Ingest wiederholt), sichtbar im neuen Bericht-Feld `gateUnassignment` und im Zählwert `gateUnassignmentReleases`. Das **Umhängen** des Gate-Slots auf eine andere Zone bleibt ausdrücklich der reguläre `.inactive`-Weg. **M2 — nach einem Reset der Stimme war das erste Gate-On tot:** `configure`/`reset` leeren Ereignisring und Hüllkurve, der Adapter wusste davon nichts und deduplizierte das nächste echte `.event(on)`; neu ist `ThereminAudioAdapter.resynchronizeAfterVoiceReset()`, die **ausschließlich** den lokalen Gatezustand angleicht (zählt in `gateStateResynchronizations`) — **sie sendet nichts**, fasst weder Parameter noch Effekte an und bekommt **keinen** Lebenszykluszugriff; gerufen wird sie vom späteren Session-/UI-Slice nach `stop`, Formatwechsel oder gescheitertem Start, und ein Test belegt, dass `SickThereminRuntime` sie nicht selbst ruft. **N3/N4 dokumentiert:** Die Stale-Grenze bezieht sich auf die berechnete `Double`-Differenz (Schätzer und Laufzeitbrücke rechnen dieselbe Subtraktion und kippen gemeinsam — eine Epsilon-Toleranz würde beide Verträge erst auseinanderlaufen lassen); Laufzeitbrücke und Adapter sind **ein einziger Kontroll-Thread-Vertrag**, und der künftige Session-Slice muss für Profil-Ingest **und** `advance` **dieselbe monotone Zeitbasis** benutzen. 35 neue Tests, **773** insgesamt, alle ohne Audiogerät und ohne Scanner — darunter der Test, der in SICK-025 gefehlt hat: Δ in **Cent** zwischen der Tonhöhe beim Profil und der 5 ms später, bei ≈ 4 Hz und ≈ 12,5 Hz, auf- und abwärts, sowie ein voller 60-Hz-Bildtakt ohne einen einzigen Richtungswechsel. Neun Gegenproben.
- Theremin-Laufzeitbrücke (SICK-025, Schritt 8c des Prototypenpfads, weiterhin **vor** der MIDI-Ausgabe). Neues reines Swift-Target `SickThereminRuntime`, abhängig nur von `SickPLSCore`, `SickPLSControlCore`, `SickPLSMonitorKit`, `SickThereminControl` und `SickThereminAudioControl` — **kein** `AVFoundation`, CoreMIDI, SwiftUI, Combine, Foundation, Darwin oder Dispatch, keine Scanner-Session, kein Transport (Importe, verbotene Bezeichner und die Abhängigkeitsliste im Manifest automatisch geprüft). `ThereminRuntime.ingest(profile:zones:assignment:atTime:)` speist **ein** echtes, bereits decodiertes B0-Profil ein, füttert die `ZoneSignalPipeline`, wendet die unmittelbaren kontinuierlichen Signale über den SICK-024-Adapter an und erzeugt aus **demselben** Ingest-Bericht genau eine `ThereminGateDelivery`, die genau einmal zugestellt wird — damit ist die SICK-023-Bedingung eingelöst. `advance(atTime:)` ist der **einzige** Weg zwischen zwei Profilen: er fragt ausschließlich die bestehende Prognose aus SICK-015 ab und **erzeugt oder wiederholt nie ein Gate-Ereignis**; die Aufruffrequenz ist deshalb frei und ändert weder den Zwischenwert noch den Stand beim nächsten echten Profil (**keine zweite Prognose**). Neu ist ein **benannter Eingangsverlust-Failsafe**: Überschreitet der Abstand zum letzten echten Profil dieselbe `staleTimeoutSeconds`, mit der auch die Prognose arbeitet (**exakt auf der Grenze ist noch nichts verloren** — dieselbe inklusive Regel wie in `ControlValuePredictor`), meldet `advance` den Verlust und löst **einmalig** ein Gate-Off aus, aber nur eines, das der Adapter selbst erfolgreich gesetzt hat; ein vom Ereignisring abgewiesenes Off gilt nicht als erledigt und wird beim nächsten `advance` erneut versucht, Wiederholungen ergeben `inputLossHeld`, ein neues echtes Profil hebt den Zustand nachvollziehbar auf (`resumedAfterInputLoss`). **Das ist ausdrücklich nicht der SICK-023-Fall `.inactive`** und wird nirgends als Messwert ausgegeben — der Signalbericht nennt ausschließlich **Rollen und Herkunft, nie Werte**, keine Rohwerte und kein Capture. Der Adapter bekam dafür genau eine Ergänzung, `ThereminAudioAdapter.releaseGateAfterInputLoss()`: sie kann nur **lösen**, nie setzen, täuscht weder `.unassigned` noch eine Messung vor, verhält sich bei Ablehnung und Deduplizierung wie die bestehende Gate-Anwendung — und bringt **keinen automatischen Timeout** in den Adapter. **Zeitvertrag:** alle Zeitpunkte sind endliche, monotone `Double`-Sekunden **des Aufrufers** (keine Uhr, kein Timer, keine Systemzeit); ein nicht endlicher oder rückläufiger Zeitpunkt lässt Pipeline, Adapter und Runtime unangetastet und kommt als `rejectedTime` zurück; ein echtes Profil verlangt **strikt** fortschreitende Zeit, eine Abfrage darf denselben Augenblick wiederholen; vor dem ersten Profil bleibt `advance` ruhig. **Dokumentierte harte Grenze: ohne `advance` wirkt kein zeitbasierter Failsafe** — Disconnect- und Sessionpolitik bleiben späterer Zuschnitt. 43 neue Tests, **738** insgesamt, alle gegen synthetische B0-Profile und einen Fake-Dienst, **ohne Audiogerät und ohne Scanner**; acht Gegenproben, von denen eine zunächst **nicht** fiel und eine echte Testlücke aufdeckte (zwei Tests ergänzt). Kein Scanner-, Session-, UI-, Timer-, MIDI-, AU- oder Persistenzanschluss.
- Geschlossene öffentliche Eingangsgrenze der Audioübersetzung (SICK-024a, Nachschärfung zu SICK-024 — **keine neue Funktion, keine Konfigurationssemantik, keine Verhaltensänderung**). `ThereminMappingConfiguration.pitchHz`, `.filterCutoffHz`, `.amplitude`, `.delaySend` und `.reverbSend` nahmen ein beliebiges `Double`; der Adapter rief sie zwar nur mit dem bereits geprüften `ThereminControlValue.value`, aber externer Code konnte `NaN`, `±inf` oder Werte außerhalb `0...1` übergeben und damit eine widersprüchliche Frequenz, Amplitude oder einen Sendpegel erzeugen — dieselbe Lücke, die SICK-022a bei `ThereminGateEvent` geschlossen hat, nur an einer anderen API. Jetzt nehmen alle fünf öffentlichen Übersetzungen ausschließlich einen `ThereminControlValue` (`pitchHz(for:)` usw.); die Rechenkerne mit `Double` sind **privat**, sodass es keinen zweiten öffentlichen Weg an der Grenze vorbei gibt. **Die Invariante trägt der Typ:** keine zweite Bereichsprüfung, keine zweite Definition von „normierter Steuerwert", keine stille Klammerung. Der Adapter reicht den validierten Wert jetzt direkt durch, statt `.value` auszupacken. **Rechnung, Polaritäten, Patch-, Gate- und Effektsemantik sowie die Echtzeitgrenze sind exakt unverändert** — belegt durch die unverändert grünen 25 Übersetzungstests und einen neuen Regressionstest über feste Zahlenwerte an `0`, `1` und Zwischenwerten. 7 neue Tests, **695** insgesamt (struktureller Signaturnachweis, Grenzwerte, Provenienz ändert keine Zahl, feste Zahlenwerte); vier Gegenproben, darunter ein **Compile-Nachweis**, dass der alte `Double`-Aufruf nicht mehr übersetzt.
- Theremin-Audioadapter (SICK-024, Schritt 8b des Prototypenpfads, **vor** der MIDI-Ausgabe). Neues reines Swift-Target `SickThereminAudioControl`, abhängig nur von `SickThereminControl` und `SickSynthAudio` — **kein** `AVFoundation`, CoreMIDI, Scanner-, Transport- oder UI-Bezug im Ziel selbst (automatisch geprüft). `ThereminAudioControlling` ist die schmale, injizierbare Steuergrenze mit genau fünf Mitgliedern: `parameters`/`effects` lesen, `update(parameters:)`, `update(effects:)`, `sendGate(isOn:)` schreiben — **kein `start()`/`stop()`, kein Renderpfad, kein Graph, keine Audio-Unit**; `ThereminAudioEngine` erfüllt sie unverändert. `ThereminMappingConfiguration` ist die validierende Fabrik ohne stille Korrektur: **logarithmische, lückenlose** Tonhöhen- und Filterübersetzung innerhalb des sicheren Hörbereichs (20 Hz…20 kHz), Lautstärkekurve `linear`/`quadratic`, eigene Maxima für Delay- und Hall-Send, **Polarität je Rolle** (`normal`/`inverted`); Vorgaben 55…1760 Hz (fünf Oktaven), 200…12 000 Hz, Amplitude ≤ 0,8, quadratisch, Sends ≤ 0,5 — **musikalische Startwerte, keine Scanner- oder Messwahrheit**. `ThereminAudioAdapter` wendet `ThereminControlSnapshot` als **Patch** an: eine fehlende Rolle lässt den bisherigen Wert stehen (nie `0`, nie trocken, nie eine erfundene Frequenz), Morph/Resonanz/ADSR/Delayzeit/Rückkopplung/Hallcharakter bleiben unberührt, ein unveränderter Snapshot erzeugt keinen Aufruf. `effectSend` steuert **nur** die beiden internen SICK-018-Sends, **keine** AU-Parameterautomation. Die SICK-023-Zustellung ist hier eingelöst: `.event` übernimmt die echte Entscheidung, `.inactive` ergibt genau ein Gate-Off — aber nur nach einem eigenen erfolgreichen Gate-On —, Wiederholungen werden dedupliziert (`GateApplication.deduplicated`), `.unassigned` tut nichts, und ein vom Ereignisring **abgewiesenes** Gate gilt nicht als Übergang (`GateApplication.rejected`, eigener Zähler) und wird beim nächsten passenden Ingest von selbst erneut versucht. **Dokumentierte Grenze:** bei ausgelassenen echten Ingests gibt der Adapter keine Gate-Off-Garantie — er hat keine Uhr. 51 neue Tests, **688** insgesamt, alle ohne Audiogerät, darunter ein Test gegen die **echte** `ThereminAudioEngine`, der belegt, dass sie nach allen Adapteraufrufen im Leerlauf bleibt; vier Gegenproben.
- Gate-Zustellvertrag für reale Ausgänge (SICK-023, im bestehenden `SickThereminControl`-Target — **kein** Audio-, MIDI-, Session-, UI-, DSP-, AU-, Hardware- oder Scanneranschluss, keine Änderung bestehender Pipeline-Semantik). Neuer öffentlicher, ausgabeneutraler Werttyp `ThereminGateDelivery` mit **drei benannten Fällen** statt eines `Bool`-Vorgabewerts oder eines Optionals, das sie verschmilzt: `.unassigned` (keine Gate-Zone zugewiesen — ein Ausgang tut nichts), `.inactive` (die **zugewiesene** Gate-Zone hat in diesem echten Ingest nichts gesehen — **das spätere sichere Signal für Gate-Off**) und `.event(ThereminGateEvent)` (genau ein bereits validiertes Ereignis, an oder aus; ein gemessenes Aus ist ausdrücklich etwas anderes als „nichts gesehen"). Hintergrund: `gateEvent(...)` lieferte in den ersten beiden Lagen dasselbe `nil`; für einen Ausgang, der bei **jedem** echten `ZoneSignalPipeline.ingest` zustellt, hätte ein zuvor eingeschalteter Ton beim Verschwinden des Objekts deshalb kein definiertes Gate-Off bekommen und hängen bleiben können. Neue reine API `ThereminControlMapper.gateDelivery(from:assignment:policy:)` konsumiert ausschließlich `ZoneIngestReport.gateEvents` **eines soeben erfolgten echten Ingest** und liest darin nur die zugewiesene ID; fremde Werte bleiben wirkungslos (auch ungültige), ein ungültiger **zugewiesener** Wert bleibt der sichtbare `MappingError.invalidGateValue` und wird nie zu `.inactive`. `gateEvent(...)` bleibt fachlich unverändert und **leitet sich jetzt intern daraus ab** — es gibt weiterhin nur eine Validierung und eine Schwellwertanwendung. **Dokumentierte zeitliche Grenze:** `.inactive` darf **nur** ein Aufrufer als Gate-Off auslegen, der diese API für **jedes** echte Ingest genau einmal aufruft; Zwischenprofil-Abfragen, Zeitüberschreitung, Verbindungsabbruch und ein ausgelassener Aufruf erzeugen **keinen** künstlichen Gatezustand — weiterhin kein Hold, keine Vorhersage, keine Uhr, keine Erinnerung an das vorige Ergebnis. 17 neue Tests, **637** insgesamt, darunter ein Integrationsfall über die echte `ZoneSignalPipeline` (Gate aktiv in Profil A, dieselbe zugewiesene Zone in Profil B inaktiv → ausdrücklich `.inactive`); drei Gegenproben, darunter die fehlerhafte Gleichsetzung von „fehlend" mit „ungemappt" in beiden Richtungen.
- Geschlossene öffentliche Gate-Wertinvariante (SICK-022a, Nachschärfung zu SICK-022 — **keine neue Funktion, keine Änderung der Assignment-, Snapshot-, Pipeline-, Gate-Hold- oder Prognosesemantik**). `ThereminGateEvent` hatte einen öffentlichen, ungeprüften Memberwise-Initialisierer: fremder Swift-Code konnte damit ein Ereignis mit `NaN`, `±inf` oder einem Wert außerhalb `0...1` bauen, obwohl Typ und Dokumentation einen echten normierten Gatewert zusichern — im Widerspruch zum strengen Vertrag von `ThereminControlValue` im selben Slice. Jetzt: der ungeprüfte Initialisierer ist **ersatzlos entfallen**, von außen ist der Typ nur noch über die validierende Fabrik `ThereminGateEvent.build(isOn:value:)` erzeugbar, und die prüft über `ThereminControlValue.build(value:provenance:)` statt über eine zweite Bereichsabfrage (deren `BuildError` wird unverändert durchgereicht, kein zweiter gleichlautender Fehlertyp). Modulintern trägt die Invariante der **Typ** des Parameters: `init(isOn:validatedValue:)` nimmt einen bereits geprüften `ThereminControlValue` und kann deshalb gar nicht fehlschlagen — auch unter `@testable` gibt es keinen ungeprüften Weg. `ThereminControlMapper.gateEvent` verhält sich unverändert: gültige Werte werden unverändert durchgereicht, ungültige bleiben der sichtbare `MappingError.invalidGateValue` und werden nie still korrigiert. 11 neue Tests (öffentliche Grenze inkl. `NaN`/`±inf`/Bereichsgrenzen, Regression der Mapper- und Policy-Semantik über den ganzen Wertebereich), **620** insgesamt; drei Gegenproben, darunter ein Compile-Nachweis, dass der alte Aufruf nicht mehr übersetzt.
- Ausgabeneutraler Theremin-Steuervertrag (SICK-022, Zwischenschritt 8a des Prototypenpfads, **vor** der MIDI-Ausgabe). Neues reines Swift-Target `SickThereminControl` — hängt nur an `SickPLSControlCore`/`SickPLSMonitorKit`, **kein** `AVFoundation`, CoreMIDI, `SickSynthAudio`, `SickSynthBridge`, `SickPLSMacTransport`, keine UI, keine Systemuhr; vollständig mit synthetischen Signalen testbar. `ThereminZoneAssignment` (validierende Fabrik nach Hausmuster): je Rolle **ein** optionales Feld, dieselbe Zone darf nicht mehrere Rollen einnehmen (`duplicateZone`), `nil` heißt absichtlich ungemappt, **keine implizite Priorität** bei mehreren gleichartigen Zonen. `ThereminControlValue`/`ThereminControlSnapshot`: normierter Wert `0...1` **plus Herkunft** (`ControlValueProvenance.measured`/`.predicted`) je kontinuierlicher Rolle; **fehlend ist nicht `0`** (ungemappt/inaktiv ergibt `nil`, ein echter Nullwert bleibt davon unterscheidbar); nicht endliche oder außerhalb liegende Werte sind ein sichtbarer Fehler, **nie** still geklammert. `ThereminControlMapper`: zwei reine, zustandsfreie Funktionen, die ausschließlich die zugewiesenen IDs lesen und die Rollen in fester Reihenfolge durchlaufen (kein Einfluss der Dictionary-Reihenfolge auf Ergebnis oder gemeldeten Fehler); **kein Halten, kein Glätten, keine Prognose** — `ControlValuePredictor` (SICK-015) bleibt die einzige Prognoseinstanz. Gate getrennt: `GatePolicy` (Schwelle `0...1`, Default `0,5`, inklusiv `wert >= schwelle`) und eine Abbildung von **genau** `ZoneIngestReport.gateEvents` eines `ingest` auf höchstens ein `ThereminGateEvent` — kein Gate-Hold, keine Vorhersage, keine Uhr; fremde und unzugewiesene Gate-Ereignisse erzeugen nichts. **Kein** Hz-/Noten-/Controller-/Amplitudenwert, kein Scanner-Session-, SwiftUI-, Audio-, DSP-, AU-, MIDI- oder Hardwareanschluss, keine Persistenz; an der Zonen- und Prognosesemantik wurde nichts geändert. 49 neue Tests, **609** insgesamt, darunter ein Rundlauf von einem synthetischen B0-Profil über die echte `ZoneSignalPipeline` bis in den Vertrag (Herkunft bleibt erhalten); sechs Gegenproben.
- Atomarer Aufbau der Audio-Fan-out-Verbindung (SICK-021a, Korrektur eines in SICK-021 eingebauten Integrationsfehlers — **keine Verhaltensänderung an Auswahl, Instanziierung, Lifecycle, DSP oder Prozessmodusregel**). Die reale Ausführung stellte trockenen Weg, Delay-Send und Hall-Send als **drei einzelne** `engine.connect`-Aufrufe desselben Quell-Ausgangsbusses her; laut `AVAudioEngine.h` sind solche Verbindungen „always one-to-one" und brechen jede vorhandene Verbindung dieses Busses, sodass nur die letzte überlebt hätte — trockener Weg und ein Send wären stillschweigend verschwunden. Der `AudioGraphPlan` war dabei korrekt, falsch war allein die Ausführung (SICK-018 hatte es bereits richtig gelöst; die SICK-021-Umschreibung war eine Regression). Jetzt: **ein** `connect(_:to:fromBus:format:)`-Aufruf mit drei `AVAudioConnectionPoint`s, Hauptmischer über `nextAvailableInputBus`. Strukturell abgesichert: neue `AudioGraphConnectionGroup`/`AudioGraphPlan.connectionGroups` als **primäre** Planstruktur (`connections` nur noch abgeleitet), neue injizierbare Grenze `AudioGraphConnecting` mit zwei getrennten Methoden (`connectOneToOne`/`connectOneToMany`) und `executeGraphPlan(_:using:)` mit **genau einem Aufruf je Gruppe`; da jede Quelle in höchstens einer Gruppe steht, kann ein Ausgangsbus nicht mehr mehrfach einzeln verbunden werden. Die serielle Quelle→Rack-Kette bleibt einzeln, die beiden Effektausgänge → Hauptmischer bleiben getrennte Einzelwege. 6 neue Tests gegen eine aufzeichnende Fake-Grenze, **560** insgesamt; Gegenprobe mit separaten One-to-One-Verbindungen bricht genau drei davon.
- Kontrollierter Graphanschluss vorbereiteter AU-Effekt-Racks (SICK-021, dritter und letzter Teil von Schritt 8). Neu: `AudioGraphPlan`/`AudioGraphNode`/`AudioGraphConnection` — die Topologie des Ausgabegraphen als **reiner, framework-freier Wert**, einzeln getestet; `AVAudioEngineOutputHost` führt sie nur noch aus. Signalführung mit Rack: Quelle → rack[0] → … → rack[n-1] → { trocken, Delay-Send, Hall-Send } → Hauptmischer — das Rack **seriell vor** der Auffächerung, der trockene Weg **genau einmal** (bei aktivem Rack geht die Quelle nicht zusätzlich direkt in den Mischer). Ohne Rack ist die Führung exakt die aus SICK-018. `ThereminAudioEngine.activeRackEntryCount` zeigt, wie viele externe Einträge im laufenden Graphen hängen. **Ein Rack geht nur in den Signalweg, wenn seine Vorbereitung abgeschlossen und `isCompletelyReady` ist, zur aktuellen Auswahl gehört und jeder Griff auflösbar ist** — Teilfehler, leere, unvorbereitete oder überholte Auswahl ergeben **kein** externes Rack und **nie eine still verkürzte Kette**; die internen Delay-/Hall-Sends bleiben in allen Fällen vollständig funktionsfähig. **Verdrahtet wird ausschließlich bei gestopptem Host beim ausdrücklichen `start()`**; während laufender Ausgabe wird nichts angefügt, entfernt oder umverdrahtet. `AudioOutputHost.prepare(format:renderBlock:rack:)` ersetzt die bisherige Signatur; neuer Fehlerfall `AudioOutputError.rackGraphConnectionFailed(String)` geht in den bestehenden Startfehlerpfad (Host gestoppt, Graph vollständig abgebaut, Status `.failed`). `AudioUnitInstantiating.rack(for:)` bündelt die Instanzen zum Verdrahten und liefert `nil`, sobald ein Griff fehlt; `PreparedAudioUnitRack` hält die Knoten in einem `internal`-Feld, sodass die öffentliche Grenze framework-frei bleibt. **Geändert gegenüber SICK-020:** `stop()`, `handleOutputConfigurationChange()` und ein gescheiterter Start geben die Rackvorbereitung jetzt frei — eine neue Runde braucht ein neues, ausdrückliches `prepareRack()`, **kein automatisches erneutes Instanziieren**; der zugehörige SICK-020-Test wurde durch `testStoppingOutputReleasesThePreparedRack` ersetzt. Die Echtzeitgrenze ist unberührt. 22 neue Tests, **554** insgesamt, alle ohne Audiogerät und ohne Drittanbieter-AU; vier Gegenproben.
- Projektweiter Regressionsschutz für die AU-Prozessmodus-Regel (SICK-020b, **keine Verhaltensänderung**). Die SICK-020a-Korrektur hatte Adapter, Roadmap und Kopfabsatz erfasst, in zusammenfassenden und historischen Abschnitten lief der falsche Wortlaut aber weiter — in `ROADMAP.md`, `CLAUDE.md`, `CHANGELOG.md` und an vier Stellen im Checkpoint. Alle aktuellen Aussagen sind jetzt prozessneutral formuliert; die beiden Stellen, die den alten Wortlaut bewusst zitieren, nennen `SICK-020a` in derselben Zeile und weisen ihn damit als korrigierte Historie aus. Neues Testziel `AudioUnitProcessModeRuleTests` (4 Tests): liest alle `.swift` unter `Sources/SickSynthAudio/` sowie `ROADMAP.md`, `README.md`, `CHANGELOG.md`, `CLAUDE.md` und den Checkpoint und schlägt fehl, sobald eine Prozesszusage zurückkehrt — im Quelltext **ohne jede Ausnahme**, in Dokumenten nur mit der Markierung `SICK-020a` in derselben Zeile. Zwei weitere Prüfungen sichern die Gegenrichtung: der Kopfkommentar der maßgeblichen Quelle muss die Regel weiterhin begründen (Systemstandard, „nur Anfragen", AUv3, Fehlerisolation) und die Optionskonstante muss als Systemstandard dokumentiert bleiben. **Der Kopf-Check prüft bewusst nur die Region vor dem ersten `import`** — eine Suche über die ganze Datei war wirkungslos, weil dieselben Begriffe auch in der Property-Doku stehen; das fiel beim Gegenprobieren auf. 4 neue Tests, **532** insgesamt; drei Gegenproben (falsche Zusage im Quelltext, unmarkiert im Dokument, gelöschte Begründung).
- Prozessmodus der AU-Instanziierung technisch korrekt dokumentiert (SICK-020a, reine Wortlautkorrektur nach Supervisor-Befund — **keine Verhaltens- oder Scope-Änderung**). SICK-020 beschrieb `options: []` als „wir laden im eigenen Prozess"; das stimmt als Zusage nicht. Laut `AudioToolbox/AudioComponent.h` werden die meisten Komponenten in den **aufrufenden** Prozess geladen, eine **AUv3** kann dagegen in einen **eigenen Extension-Service-Prozess** geladen werden und das ist für solche Komponenten das **Standardverhalten**; `.loadOutOfProcess` und `.loadInProcess` sind **nur Anfragen an die Implementierung** und können fehlschlagen bzw. auf den Standard zurückfallen. `SystemAudioUnitInstantiation.instantiationOptions` bleibt unverändert `[]` — jetzt beschrieben als bewusste Wahl **des Systemstandards**, ohne Behauptung eines Prozessmodus und ohne Isolationszusage: **aus dieser API allein folgt keine vollständige Fehlerisolation**, denn der Ladeort bestimmt nicht, was beim Wegbrechen der Verbindung geschieht, wer neu startet und was der Nutzer hört. Erzwungen wird weiterhin nichts (kein `.loadInProcess`, kein `.loadOutOfProcess`). Neuer Test `testTheRealBoundaryRequestsTheSystemDefaultProcessMode`: **statischer** Nachweis über die benannte Konstante — der tatsächliche Prozessmodus wird ausdrücklich nicht gemessen und kein Drittanbieter geladen. Zusätzlich zwei gleichartig ungenaue Kommentare in `SystemAudioUnitComponentSource`/`AudioUnitEffectCatalog` geschärft („es wird überhaupt nichts geladen" statt „nichts in unseren Prozess geladen" — das Verbot gilt für jedes Laden). 1 neuer Test, **528** insgesamt.
- Kontrollierte Instanziierung ausgewählter Audio-Unit-Effekte in `SickSynthAudio` (SICK-020, zweiter von drei Teilen von Schritt 8 — **die Instanzen hängen an keinem Graphen und verarbeiten keinen Klang**). `SystemAudioUnitInstantiation`: verwendet ausschließlich Apples öffentliche asynchrone `AVAudioUnit.instantiate(with:options:completionHandler:)` (ab macOS 10.11) — **kein Dateipfad-Laden, kein `dlopen`, kein Bundle-Scan, keine eigene Plugin-Bridge**; eine vorgeschaltete Metadatenabfrage trennt „nicht installiert" von „ließ sich nicht laden", die sonst als ein und derselbe Systemfehler zurückkämen. `AudioUnitInstantiating`/`AudioUnitInstanceHandle`: schmale, injizierbare Grenze mit framework-freiem Ergebnis — der Griff trägt **kein** Apple-Objekt, die `AVAudioUnit` bleibt hinter der Implementierung. `ThereminAudioEngine.prepareRack()`/`discardPreparedRack()`/`rackPreparation`: **`prepareRack()` ist die einzige Stelle im Projekt, an der fremder Code geladen wird** (der Prozessmodus ist ausdrücklich nicht zugesagt, siehe SICK-020a) — Entdecken, Auswählen, `start()` und `stop()` tun es nicht. **Keine pauschale Erfolgsmeldung:** jeder Eintrag trägt sein eigenes `AudioUnitEntryPreparation` mit zwei getrennten Fehlerfällen (`componentUnavailable`, `instantiationFailed(message:)`); ein gescheiterter Eintrag lässt die übrigen unberührt, startet keine Ausgabe und fasst den internen SICK-018-Sendgraphen nicht an. Ein leeres Rack ist ausdrücklich **nicht** `isCompletelyReady`. Der Bericht steht in **Rackreihenfolge**, nicht in Abschlussreihenfolge. **Lebenszyklus:** zweite Anforderung abgelehnt mit `.alreadyPreparing` ohne die laufende zu stören; neue Vorbereitung, Verwerfen, Auswahländerung und Freigabe des Dienstes geben jede Instanz frei; veraltete Antworten gelten nie als Bereitschaft und werden sofort freigegeben (Generationszähler, da Apples Instanziierung keinen Abbruch kennt); kein Retain-Cycle. **Bewusst dokumentiert:** übergeben wird `options: []`, also der **Systemstandard** — **keine Zusage über den Prozessmodus** (Wortlaut in SICK-020a korrigiert, siehe eigener Eintrag); **Sandboxing, Fehlerisolation, Parameterautomation und der Graphanschluss bleiben offen**, und damit auch jeder Echtzeitnachweis für fremde Effekte. 27 neue Tests, **527** insgesamt; die reale Grenze ist nur so weit geprüft, wie es ohne Drittanbieter-AU ehrlich geht (zwei echte Tests gegen eine ausgedachte Kennung), der Erfolgsfall bleibt eine dokumentierte Grenze. Vier Gegenproben durchgeführt.
- Katalog und Auswahlvertrag für ein Audio-Unit-Effekt-Rack in `SickSynthAudio` (SICK-019, erste Hälfte von Schritt 8 des Prototypenpfads — **ohne jedes Hosten**). `SystemAudioUnitComponentSource`: die einzige Datei des Vertrags, die `AVFoundation` anfasst; sie entdeckt Effektkomponenten über Apples öffentlichen `AVAudioUnitComponentManager.shared().components(matching:)` mit einer `AudioComponentDescription` auf `aufx` — **kein Dateisystemscan, keine eigene Plugin-Schnittstelle**, und `components(matching:)` liefert Beschreibungen statt Instanzen: es wird nichts geladen, ausgeführt oder an einen Graphen gehängt. `AudioUnitIdentity`/`AudioUnitEffectCandidate`/`AudioUnitComponentDescription`/`EffectRackSelection`: der framework-freie Wertvertrag — **kein `AVFoundation`-Typ** an der öffentlichen App-/SwiftUI-Grenze, mitsamt Vier-Zeichen-Code-Umwandlung für die Anzeige. Validierung nach dem Hausmuster **ohne stille Korrektur**: `AudioUnitIdentity.build` lehnt alles Nicht-`aufx` (`.notAnEffectComponent`) und jede unvollständige Identität mit Subtyp oder Hersteller `0` (`.incompleteIdentity`) ab, `EffectRackSelection.build` Duplikate (`.duplicateEntry`) und mehr als acht Einträge (`.tooManyEntries`); `.empty` ist die neutrale Auswahl und der Ausgangszustand. `AudioUnitEffectCatalog`: rein und zustandsfrei — filtern, entdoppeln (erster Eintrag der Quelle gewinnt), **von Hand stabil** sortieren (Hersteller, dann Name, Gleichstand entscheidet der Ursprungsindex, weil Swifts `sort` keine Stabilität zusichert), umwandeln; ein unbrauchbarer Eintrag lässt den Rest der Liste unberührt. `AudioUnitComponentSource`: schmale, injizierbare Grenze, sodass Filterung, Sortierung und Konvertierung ohne installierte Drittanbieter-AU gegen Fakes prüfbar sind.
- `ThereminAudioEngine.rack`/`update(rack:)` (SICK-019): die Auswahl ist **ausschließlich Wunschkonfiguration** — `update(rack:)` speichert den Wert und **mehr nicht**. Es startet keine Ausgabe, lädt nichts, instanziiert nichts, verbindet nichts und verändert die internen SICK-018-Delay-/Hall-Sends auch während laufender Ausgabe nicht. **Sicherheitsgrenze:** Drittanbieter-Audio-Units sind fremder Code; eine Plugin-Auswahl darf nie dazu führen, dass welcher ausgeführt wird. **Ausdrücklich noch offen** und je eigens freizugeben: Instanziierung, Parameterautomatisierung, Sandboxing/Fehlerisolation und die kontrollierte Änderung eines laufenden Graphen; die internen Apple-Delay-/Hall-Units werden **nicht** als „Rack" ausgegeben. 24 neue Tests ohne Audiogerät und ohne Drittanbieter-AU, **500** insgesamt; vier Gegenproben durchgeführt (fehlender Index-Gleichstand, fehlende Duplikatsprüfung, fehlender `aufx`-Filter, und ein `update(rack:)`, das den Host anfasst — jeweils fallen genau die zuständigen Tests).
- `VoiceObservationChannel` (SICK-017b): hat während laufender Audioausgabe jetzt **genau einen Schreiber**. In SICK-017a schrieb `resetDiagnostics()` vom Steuer-Thread über `publishClearedCounters(...)` in denselben Seqlock, den der Audio-Thread beschreibt — ein Seqlock verlangt aber exakt einen Schreiber: zwei können dieselbe gerade Sequenz lesen, beide hochzählen und ihre Schreibvorgänge verschachteln. Die atomaren Einzelwörter verhindern dabei nur die Sanitizer-Meldung, **nicht das zerrissene Protokoll** (Gegenprobe mit wiederhergestelltem zweitem Schreiber: 456 zerrissene Lesungen, Sequenz 47 632 statt 8 002). `publishClearedCounters(...)` ist **ersatzlos entfernt**; die verbleibende Schreibmethode heißt `publishFromVoiceOwner(...)` und darf nur vom jeweils alleinigen Eigentümer der Stimme gerufen werden — im Betrieb ausschließlich vom Audio-Thread, bei gestopptem Host aus `configure`/`reset`. Im gesamten Projekt gibt es nur noch **eine** Schreibstelle (`publishVoiceObservation`).
- `-resetDiagnostics` (SICK-017b): macht nur noch zwei atomare Schritte — Brücken-/Hostzähler leeren (sofort `0`) und die Reset-Anforderung setzen. **Kein Schreibzugriff auf den Beobachtungsspiegel mehr.** Damit zeigen die `voice*`-Felder von `diagnostics` bis zum nächsten Renderblock weiter den zuletzt **gültigen** Stand statt eines künstlichen „sofort Null"; diese asynchrone Diagnosegrenze steht jetzt so im Header, im Checkpoint und in den Tests. Neu: `SickSynthBridgeObservationSequenceForTesting` macht die Seqlock-Sequenznummer prüfbar, sodass sich von außen strukturell belegen lässt, dass kein Steuerthread-Pfad in den Kanal schreibt (1000 Resets bewegen sie nicht; unter Nebenläufigkeit wächst sie exakt um zwei Schritte je Renderblock). ThreadSanitizer bleibt sauber, gilt für dieses Protokoll aber ausdrücklich nicht als Nachweis.
- `SickSynthVoiceBridge` (SICK-017a): der Steuer-Thread liest die **nichtatomare** `ThereminVoice` nicht mehr. `isVoiceActive` und die fünf `voice*`-Diagnosefelder stammen jetzt aus dem neuen atomaren `VoiceObservationChannel` (`RealtimeHandover.hpp`) — ein Seqlock derselben Bauart wie `ParameterChannel`, nur mit vertauschten Rollen (Schreiber ist der Audio-Thread). Er wird am Ende **jedes** Renderblocks veröffentlicht; ein gelesener Spiegel ist deshalb höchstens **einen Renderblock** alt und in sich stimmig (alle Werte aus demselben Block — einzelne atomare Felder könnten `renderedBlocks` aus Block N mit `sanitizedParameterBlocks` aus Block N-1 mischen). Auch `isConfigured`, `sampleRate` und `maximumBlockSize` sind eigene atomare Kopien und berühren die Stimme nicht mehr. Zuvor war jeder dieser Zugriffe während eines laufenden `render()` ein Datenrennen; ThreadSanitizer belegt das reproduzierbar (`data race AdsrEnvelope.hpp:66 in AdsrEnvelope::gateOn()`).
- `-resetDiagnostics` (SICK-017a): ist jetzt **auch während laufender Ausgabe sicher** und ruft nicht mehr `voice.resetDiagnostics()` auf dem Steuer-Thread. Die Brücken-/Hostzähler sind selbst atomar und sofort `0`, der Beobachtungsspiegel wird sofort geleert, und die Zähler **in der Stimme** setzt der Audio-Thread über eine atomare Anforderung an der nächsten Blockgrenze zurück — vor dem Rendern, damit der danach veröffentlichte Spiegel schon den zurückgesetzten Stand zeigt. Dokumentierte asynchrone Grenze: ohne weiteren Renderlauf bleibt die Anforderung stehen (sichtbar ist das nicht, der Spiegel ist bereits `0`); `configure` löst eine offene Anforderung ein, statt sie zu verwerfen.
- `SickSynthVoiceBridge.h` (SICK-017a): der Thread-Vertrag steht jetzt als zwei nummerierte Regeln im Kopf — `configure` und `reset` fassen die Stimme direkt an und sind ausschließlich bei **garantiert gestopptem Host** erlaubt; alles andere ist jederzeit sicher. `ThereminAudioEngine.start()` stellt diese Reihenfolge mit `if host.isRunning { host.stop() }` strukturell her, statt sie über jeden einzelnen Pfad hinweg nur zu behaupten (`stop()`/`handleOutputConfigurationChange()` hielten sie bereits ein). 9 neue Tests (`VoiceObservationTests`) mit getrenntem Steuer- und echtem Audio-Thread, darunter ein Kohärenznachweis über eine Invariante, deren Verletzung sichtbar wäre, statt aus einem nicht ausgelösten Rennen abgeleitet zu werden; `swift test --sanitize=thread` läuft über Brücke und Audio sauber, meldet mit dem alten Zustand aber sofort.
- Neues Target `SickSynthBridge` (SICK-017): die **enge Objective-C++-Brücke** ausschließlich für `ThereminVoice` und der einzige Ort im Projekt, an dem Objective-C und C++ aufeinandertreffen. Öffentlicher Kopf reines Objective-C/C (kein C++-Kopf, kein `namespace`, keine Klasse, kein Template, kein Smart Pointer) — Swift sieht kein C++-Detail und keine C++-Speicherverwaltung. Ausdrücklich **kein** generisches Audio-/Plugin-Framework. Steuerseite über Objective-C-Methoden, Renderseite über die C-Funktion `SickSynthBridgeRenderMono` (kein Nachrichtenversand, keine ARC-Operation im Audiopfad). `RealtimeHandover.hpp` (intern) enthält die gesamte Threadgrenze: ein **Seqlock** für den Parameter-Snapshot mit `std::atomic<float>`-Nutzlast (höchstens vier Leseversuche, danach der zuletzt gültige Satz; nie blockierend, nie eine Mischung zweier Sätze) und ein **SPSC-Ringpuffer** (64 Plätze) für Gate-**Ereignisse** (genau einmal konsumiert, nie gehalten; Überlauf gezählt statt stillschweigend überschrieben). Je Block werden höchstens 16 Ereignisse übernommen, der Rest bleibt stehen — ein Schwall wird verzögert, nicht verworfen. 18 neue Tests, alle ohne Audiogerät.
- Neues Target `SickSynthAudio` (SICK-017): der macOS-Audioausgabedienst auf `AVAudioEngine`/`AVAudioSourceNode`, abhängig ausschließlich von `SickSynthBridge`. `ThereminAudioEngine` (`ObservableObject`) startet und stoppt **ausschließlich ausdrücklich** und degradiert bei fehlendem oder nicht startbarem Gerät in einen klaren Fehlerzustand (`noOutputDevice`, `unsupportedOutputFormat`, `voiceConfigurationRejected`, `engineStartFailed`, `alreadyRunning`) statt abzustürzen; ein zweiter `start()` lässt die laufende Ausgabe unangetastet. Der Renderblock fängt ausschließlich triviale Werte ein und allokiert, sperrt, loggt und mutiert nichts threadübergreifend; der Mono-Zwischenpuffer wird in `start()` belegt und in `stop()` freigegeben (erst den Host stoppen, dann freigeben). Stereo entsteht durch Auffächern **nach** dem Rendern, die Speicheranordnung wird aus der Pufferliste selbst abgeleitet; ein Block über `maximumFrameCount` wird gekürzt, der Rest stillgeschrieben und die Kürzung gezählt, `nil` `mData` und zu kurze Puffer werden gezählt und übersprungen. `handleOutputConfigurationChange()` stoppt und wartet auf einen ausdrücklichen Neustart. Öffentliche Swift-API auf Lebenszyklus, Parameter-Snapshot, echtes Gate-Ereignis und Status/Diagnose begrenzt — **kein Scannerwert→Hz-Mapping**. 28 neue Tests, alle ohne Audiogerät gegen einen Fake-Host; der echte `AVAudioEngineOutputHost` ist als dokumentierte Grenze einmalig von Hand belegt (`.agent_handoff/sick-017-real-engine-probe.md`) und bewusst nicht als automatischer Test vorgetäuscht.
- `ZoneSignalPipeline.ingest(profile:zones:atTime:)` (SICK-015a, Befund H1): gibt statt eines `[EditableZone.ID: ControlValueObservation]`-Dictionaries jetzt einen `ZoneIngestReport` zurück (`observations` je kontinuierlicher Zone, `gateEvents` je `gate`-Zone). **`gate` hinterlässt in der Pipeline überhaupt keinen Zustand mehr:** der Wert erscheint einmalig als Ereignis im Bericht des erzeugenden `ingest`, und `signal(for:at:)` liefert für `gate` zu jedem Zeitpunkt `.inactive`. Zuvor lieferte die Zeitabfrage bei `time <= gateTime` noch `.measured` — eine Abfrage **vor** dem eingegangenen Profil bekam damit einen Wert aus der Zukunft. Bewusst kein Toleranzbereich, sondern eine Ereignisrückgabe: es gibt keinen gespeicherten Zeitstempel mehr, der falsch verglichen werden könnte.
- `ControlValuePredictor.observe(value:atTime:)` (SICK-015a, Befund H2): prüft den Abstand zum letzten akzeptierten Sample jetzt gegen `staleTimeoutSeconds` und initialisiert bei Überschreitung mit der **echten** neuen Beobachtung und Geschwindigkeit `0` neu, statt eine lange zurückliegende Geschwindigkeit über die Pause hinweg weiterzuführen. Neuer, explizit gekennzeichneter Fall `ControlValueObservation.resetAfterStaleGap`; die Prüfung steht vor der Ausreißerprüfung, damit der gemeldete Grund stimmt. Grenzregel inklusiv und identisch zu `estimate(at:)`.
- `ZoneSignalPipeline` (SICK-015a, Befund M1): führt je Zonen-ID den **vollständigen `Zone`-Wert** statt nur der Rolle mit und übernimmt einen Schätzer nur bei exakter `Zone`-Gleichheit. Geänderte Index- oder Rohwertgrenzen bei gleicher ID und Rolle verwerfen die Historie jetzt ebenfalls (zuvor lief der Schätzer mit der alten Geschwindigkeit weiter, obwohl der normierte Wert fachlich ein anderes Signal ist).
- Neues Package-Target `SickThereminPerformance` (SICK-027, Schritt 9a des Prototypenpfads — die erste spielbare Theremin-Oberfläche): das **reine Integrationsmodul**, in dem Live-Profil, Zonen, Laufzeitbrücke, Audioadapter und Synthdienst zusammenlaufen. **Kein SwiftUI, kein serieller Transport, kein MIDI, keine AU-Instanziierung, kein Scannerzugriff** — automatisch geprüft über `PerformanceBoundaryTests` (erlaubte Importe, verbotene Bezeichner, Abhängigkeitsliste im Manifest, und dass das App-Target keine Laufzeit-/Timerlogik dupliziert). `ThereminPerformanceController` (`ObservableObject`, **Main-Thread-only**) besitzt genau eine `ThereminAudioEngine`, den darauf gesetzten `ThereminAudioAdapter` und eine `ThereminRuntime`. `MonotonicTimeline`/`MonotonicTimeSource`/`SystemUptimeTimeSource`: die **eine** Zeitquelle für jedes Ingest **und** jedes `advance` — `Date` und der `ScanSessionState`-Stempel erreichen die Laufzeitbrücke nie (eine Uhrkorrektur würde dort als `rejectedTime` erscheinen und echte Profile still verwerfen); bei stehender Uhr rückt sie um genau eine Mikrosekunde vor, damit ein echtes Profil nicht am Zeitvertrag scheitert, und die nächste echte Uhrzeit holt das sofort ein. `AdvanceTicker`/`MainRunLoopAdvanceTicker`: der Nachführtakt als injizierbare Grenze (60 Hz als **dokumentierter Startwert, keine Geräteaussage**; Run-Loop-Modus `.common`, damit der Takt während Menütracking und Reglerziehen nicht stillsteht — genau dann wird der Failsafe gebraucht). `ThereminRoleAssignmentState`/`ZoneSlotOutcome`: die Rollenzuordnung als bedienbarer Zustand, zu jedem Zeitpunkt eine gültige `ThereminZoneAssignment`, gebaut ausschließlich über deren validierende Fabrik.
- Audio-Lebenszyklus vollständig geschlossen (SICK-027): der Controller startet `engine.start()` **ausschließlich auf ausdrückliche Nutzeraktion** und ruft **nach jedem** Startergebnis — **auch nach einem gescheiterten Start, weil `configure` die Stimme bereits erreicht haben kann** —, nach jedem `stop()` und bei beobachtetem `.stoppedAfterConfigurationChange` `adapter.resynchronizeAfterVoiceReset()`. Diese Methode schickt **kein** Gate; erst das nächste echte Scanprofil darf wieder eines setzen. Der 60-Hz-Takt läuft **nur** bei aktiver Ausgabe, endet mit dem Stopp, und ein verspätet zugestellter Takt erreicht die Laufzeitbrücke nicht einmal — **kein Neustart, kein neues Gate**. Kein Autostart beim App-Start, beim Verbinden des Scanners oder bei einer Zonenänderung. Neue Ausgänge `PerformanceStartOutcome` (`started`/`audioFailed`/`refused`) und `PerformanceStartRefusal` halten „der Dienst wurde gar nicht erst angefasst" und „der Dienst ist gescheitert" **getrennt**.
- Sichtbare, sichere Rollenzuweisung in `SickPLSMonitor` (SICK-027): neue `ThereminControlView` mit je einem Picker für Pitch, Volume, Filter, Effect Send und Gate, jeweils „Nicht zugewiesen" plus **ausschließlich Zonen mit genau derselben `ZoneRole`** — das schließt den stillen Rollen-Mismatch aus Befund N2 (`review-sick-025.md`), bei dem das Instrument ohne Fehler und ohne Zahl tot blieb. Dieselbe Zone kann nicht in zwei Slots stehen; ein Konflikt wird **sichtbar verweigert** statt die frühere Auswahl still zu überschreiben. Gelöschte und umgerollte Zonen werden sauber auf „Nicht zugewiesen" gesetzt. **Ein Start ist erst möglich, wenn Pitch, Volume und Gate zugewiesen sind**, und die Oberfläche benennt, welche der drei fehlt — das schließt den bekannten Fall N5 („neutrale Amplitude ist bewusst 0, also bleibt alles stumm") **ohne heimliche Grundlautstärke und ohne erfundene Gate-Zone**. Filter und Effect Send bleiben optional. Audiostatus, Start/Stopp, ein menschenlesbarer Fehlertext **ohne verstecktes Wiederholen**, Profilrate und eine knappe Laufzeitdiagnose (`isInInputLoss`, angenommene Profile, Zwischenabfragen, Failsafes, abgelehnte Zeitstempel) sind sichtbar — **keine Rohbytes, keine Captures, keine Secrets**. `ContentView` reicht neue Profile weiter und benutzt `lastProfileReceivedAt` **nur als Änderungsmarke**, nie als Zeitstempel. **Dokumentierte Beobachtungsgrenze:** `ScanSession` veröffentlicht nur das zuletzt decodierte Profil — liefert ein Lesevorgang mehrere B0-Frames, sieht der Controller davon nur das letzte; ein späterer Transport-Slice kann eine verlustfreie Profilereignisfolge liefern, **erfundene Einzelzeitstempel entstehen ausdrücklich nicht**.
- Erster Testplan für den echten Spieltest (SICK-027, ROADMAP R6, **noch nicht durchgeführt**): Ausgabegerät wählen, Lautstärke zunächst niedrig, Scanner auf 38 400 Baud und „Messwerte minimal kontinuierlich" — **ausdrücklich als nicht freigegebener, nie ausgeführter Ownerschritt am Gerät markiert**, ersatzweise 9600 Baud —, Pitch/Volume/Gate zuweisen, Audio bewusst starten, Hand langsam bewegen, dann `.inactive` und Eingangsverlust getrennt prüfen, ausdrücklich stoppen. **Jede Scannerannahme darin ist bis zur Durchführung unbestätigt.**
- 46 neue Tests in `SickThereminPerformanceTests`, **819 insgesamt**, alle ohne Audiogerät, ohne echten Timer, ohne echte Uhr und ohne Scanner. Sechs Gegenproben durchgeführt (kein Mindestvorlauf auf der Zeitleiste, entfernter Tickschutz nach dem Stopp, Resynchronisation nur bei erfolgreichem Start, aufgehobener Rollenfilter, geleerte Pflichtrollen, still überschriebener Konflikt) — jedes Mal fallen genau die zuständigen Tests. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`).
- Gerätewechsel im laufenden Betrieb werden erkannt (SICK-028, Review-Befund M2 aus `review-sick-027.md`). **Der Befund war real:** `ThereminAudioEngine.handleOutputConfigurationChange()` war seit SICK-017 gebaut und getestet, hatte außerhalb der Tests aber **keinen Aufrufer** — `AVAudioEngineOutputHost` beobachtete nichts. Im Betrieb hieß das: Kopfhörer abziehen oder Ausgabegerät wechseln → `AVAudioEngine` stoppt sich selbst → `status` blieb `.running`, die Anzeige sagte „läuft", der Nachführtakt lief weiter, und es kam kein Ton mehr; kein Fehler wurde sichtbar. Neu: `AudioOutputHost.setOutputConfigurationChangeHandler(_:)` als minimale Erweiterung der bestehenden Grenze — **bewusst ohne leere Vorgabeimplementierung**, weil genau eine solche stille Vorgabe die Lücke entstehen ließe. `OutputConfigurationChangeObserving`/`NotificationCenterOutputConfigurationChangeObserver`: die injizierbare Beobachtungsgrenze, real auf `.AVAudioEngineConfigurationChange` **und auf die eigene Engine eingeschränkt** (ohne Absenderfilter meldete jede fremde Engine im Prozess mit), Token in `stopObserving()` **und** `deinit` entfernt, die Closure fängt den Absender nicht ein. `MainThreadDispatching`/`MainQueueDispatcher`: die Übergabe auf den Kontroll-Thread — die Benachrichtigung kommt auf einem beliebigen Thread, der Dienst führt `@Published`-Zustand; **immer asynchron**, auch vom Main Thread aus, weil ein vom Aufrufer abhängiges Verhalten Reentrancy öffnete. Der Dienst löst den Rückruf in `deinit` wieder, die Meldung **startet nie etwas**, und sie ist **idempotent** (eine zweite, verspätete oder nach einem Stopp eintreffende Meldung ändert nichts).
- `ThereminPerformanceController.engine` ist **privat** (SICK-028, Review N2). Solange er öffentlich war, ließ sich `controller.engine.start()` am Controller vorbei rufen: Die Ausgabe lief ohne Nachführtakt, ohne Eingangsverlust-Failsafe und ohne Adapter-Resynchronisation, `isRunning` blieb `false` und `canStart` blieb `true`. Alles, was die Oberfläche braucht, steht als `@Published` Spiegel bereit; was nicht gespiegelt ist, gehört auch nicht nach außen.
- **Genau eine Performance-Instanz je App** (SICK-028, Review N3): `SickPLSMonitorApp` besitzt `ScanSession` **und** `ThereminPerformanceController` und reicht beide an `ContentView`. Zuvor erzeugte jede Ansicht ihren eigenen Controller — jedes weitere Fenster hätte damit eine **zweite** Audio-Engine und einen zweiten Zoneneditor an derselben Scanner-Sitzung gehabt: zwei startbare Ausgaben, zwei Töne, zwei Zuweisungen. Zusätzlich ist der „Neues Fenster"-Befehl über `CommandGroup(replacing: .newItem) {}` entfernt (macOS 11+, innerhalb der macOS-12-Grundlage) — statt eine Mehrfensterfunktion nur halb richtig zu stützen, gibt es sie nicht.
- **Automatische Slot-Bereinigungen werden sichtbar gemeldet** (SICK-028, Review M1). Neu: `ZoneReleaseReason`/`ZoneRelease` (`reconcile(with:)` liefert jetzt Rolle **und Grund** statt nur der Rollenliste — „gelöscht" und „umgerollt" sind für den Spieler zwei verschiedene Ereignisse) sowie `PerformanceNotice` mit `message` und `isAutomatic` und `ThereminPerformanceController.notice`. Zuvor verwarf `ContentView` den Rückgabewert von `reconcileZones`, und die Anzeige kannte nur den Fehler aus dem Picker-Binding: Wurde eine zugewiesene Zone gelöscht oder umgerollt, sprang der Picker wortlos auf „Nicht zugewiesen"; bei laufender Ausgabe hörte der Ton beim nächsten Profil auf, ohne dass der Grund irgendwo stand. **Der Text entsteht im Modell, nicht in der Ansicht** — sonst wäre er nicht prüfbar. Manuelle Ablehnung und automatische Bereinigung bleiben unterscheidbar (`isAutomatic`, in der Anzeige verschiedene Farben); ein Hinweis verschwindet nur durch einen **erfolgreichen** Bedienschritt an derselben Stelle, nie durch Zeitablauf und nie durch eine Zonenänderung, die nichts bewirkt hat.
- **Fünf Gate-Zählwerte in der Theremin-Spalte** (SICK-028, Review N4): zugestellte, abgewiesene und deduplizierte Gate-Ereignisse, Gate-Resynchronisationen und Freigaben nach Gate-Abwahl. Sie waren bereits öffentlich, standen aber nicht in der Anzeige — und genau sie tragen beim ersten echten Spieltest die Diagnose des „wichtigsten Einzelbefunds" (hängender Ton): Ob ein Gate zugestellt, entdoppelt oder vom Ereignisring abgewiesen wurde, entscheidet zwischen drei völlig verschiedenen Ursachen. Weiterhin **keine Rohwerte, keine Frames, keine Captures**.
- Dokumentierte Betriebsgrenzen ehrlich ergänzt (SICK-028): Die Profilweiterleitung hat **zwei** Verlustschichten — „nur das letzte Profil eines Lesevorgangs" (bekannt) **und** „nur eine Meldung je SwiftUI-Transaktion", weil sie an `.onChange` hängt (Review N1); als nächste Transportfolge festgehalten: Profile **modellseitig** abonnieren statt über den Renderpfad zu reichen. `ProcessInfo.systemUptime` zählt nur **Wachzeit**, der Eingangsverlust-Failsafe sieht einen Systemschlaf also nicht (Review N6) — unbestätigte Betriebsgrenze, keine abgesicherte Eigenschaft. ROADMAP R6 hat dafür einen eigenen, letzten Testschritt „Gerätewechsel" bekommen, ausdrücklich mit dem Hinweis, dass die Erkennung **ohne reale Hardware nicht bestätigt** ist.
- 39 neue Tests (SICK-028), **858 insgesamt**, alle ohne Audiogerät, ohne echten Timer, ohne echte Uhr und ohne Scanner; neun Gegenproben (fehlende Rückrufregistrierung — 12 Tests fallen —, Meldung ohne Threadwechsel, Bereinigung ohne Hinweis, verschmolzene Hinweisarten, Hinweis ohne Bedienschritt gelöscht, wieder öffentlicher `engine`, Controller zurück in der Ansicht, wieder vorhandener „Neues Fenster"-Befehl, Beobachter ohne Absenderfilter). Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`).
- **Modellseitige Profilzustellung** (SICK-029, schließt Review-Befund N1 aus `review-sick-027.md`). Bis SICK-028 reichte `ContentView.onChange` das jeweils letzte Profil über den **SwiftUI-Renderpfad** an die Klangerzeugung: Mehrere Zustandsänderungen in **einer** Transaktion ergaben **eine** Weitergabe, und der Ton hing daran, ob und wann SwiftUI den Body neu auswertete. Neu: `ScanSession.performanceProfiles` (`AnyPublisher<ScanProfileBatch, Never>`, nur lesend, immer auf dem Main Thread, nur für den aktuellen Worker) feuert **je abgeschlossenem Lesevorgang mit mindestens einem gültigen B0-Profil genau einmal** — unabhängig davon, ob überhaupt eine Oberfläche existiert. `ScanProfileBatch` trägt ausschließlich das Profil und `profileCountInRead`: **keine Rohframes, keine Bytes, kein `Date`**. `ScanSessionState.decodedProfiles(in:)` ist die **eine** Stelle, die entscheidet, was ein gültiges B0-Profil in einem Lesevorgang ist — `ScanSession` decodiert einmal und speist Monitorzustand und Klangpfad daraus, statt ein zweites Mal zu decodieren.
- **Neues Bibliotheks-Target `SickPLSPerformanceSession`** (SICK-029, abhängig von `SickPLSControlCore`/`SickPLSMacTransport`/`SickPLSMonitorKit`/`SickThereminPerformance` — **kein SwiftUI, kein AVFoundation, kein CoreMIDI, keine Audio-Lebenszyklusdoppelung**; Importe, verbotene Bezeichner und die Manifest-Abhängigkeiten prüft `PerformanceSessionBoundaryTests` automatisch). `MonitorPerformanceCoordinator` (`ObservableObject`) besitzt genau eine `ScanSession`, genau einen `ThereminPerformanceController` und die **einzige** Wahrheit über den `ZoneEditorState`; er abonniert die Profile **einmal im `init`** — das Abonnement gehört der Sitzung, nicht der Verbindung, deshalb legen `disconnect()` und ein neues `connect(...)` **kein zweites** an. Eine Änderung der **Zonenliste** gleicht die Rollenzuordnung sofort ab (gelöschte und umgerollte Zonen lösen ihre Slots sichtbar); eine reine Auswahl- oder Entwurfsänderung ist keine fachliche Zonenänderung und tut es nicht. **Kein Autostart:** weder ein Profil noch ein Verbinden noch eine Zonenänderung startet eine Audioausgabe.
- `SickPLSMonitor` ist damit endgültig reine Oberflächenkomposition (SICK-029): `SickPLSMonitorApp` besitzt **einen** `MonitorPerformanceCoordinator`, `ContentView` bekommt ihn gereicht und enthält **kein** `onChange` mehr — weder für Profile noch für Zonen —, keine Zeitquelle und kein Stück Audio-Lebenszyklus. Session, Controller und Editorzustand sind aus den Ansichten ins Modell gewandert.
- **Die verbleibende Grenze bleibt benannt statt versteckt** (SICK-029): Enthält **ein** Lesevorgang mehrere B0-Profile, wird für die Klangerzeugung **nur das letzte** benutzt — für die früheren gibt es **keine belastbaren Einzelzeitstempel**, und ausgedachte Mikrosekundenabstände wären Scheingenauigkeit und würden die geschätzte Geschwindigkeit der Bewegungsprognose verfälschen. `MonitorPerformanceCoordinator.readsWithDroppedProfiles` zählt diese Fälle sichtbar mit, die Theremin-Spalte zeigt sie, und die Monitoranzeige verarbeitet weiterhin **jedes** Profil. Folgearbeit bleibt ein Transport-Slice mit echten, je Profil gemessenen Zeitpunkten.
- 37 neue Tests (SICK-029), **895 insgesamt**, alle ohne Audiogerät, ohne echten Timer, ohne Scanner und **ohne jede SwiftUI-Ansicht** — die Profile laufen dabei durch die echte `ScanSession` samt echtem Hintergrund-Thread, echtem `StreamParser` und echtem `B0ScanProfile.decode`; gefälscht sind nur Dateideskriptor und Audiohost. Sechs Gegenproben (keine modellseitige Veröffentlichung — 14 Tests fallen —, jedes Profil einzeln als erfundene Serie gesendet, Profilweiterleitung zurück in `ContentView`, zweites Abonnement je `connect` — 9 Tests —, kein Zonenabgleich bei Editoränderung, Audio-Lebenszyklus im Koordinator dupliziert). Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`).
- **Die öffentliche Invariante von `ScanProfileBatch` ist strukturell geschlossen** (SICK-029a, Auflage A1 aus `review-sick-029.md`). Der Typ dokumentierte `profileCountInRead >= 1`, sein **öffentlicher** Initialisierer nahm aber auch `0` und negative Werte an — die dritte Instanz desselben Musters nach `ThereminGateEvent` (SICK-022a) und den Audioübersetzungen (SICK-024a). **Auswirkung im Produktionsweg gab es keine**: `ScanSession` übergibt `profiles.count` und sendet nur, wenn `profiles.last` existiert. Neu ist der Initialisierer **modulintern**; der Typ bleibt für Combine-Abonnenten öffentlich lesbar. **Bewusst keine validierende Fabrik** (anders als bei `Frame.build`/`Zone.build`): Ein Batch **ist** das Ergebnis eines Lesevorgangs und hat außerhalb von `ScanSession` keine fachliche Herkunft — ohne zweiten Erzeugungsweg gibt es nichts zu validieren. **Keine Verhaltensänderung am Profilweg.** Netto +2 Tests, **897 insgesamt** (zwei neu in `SickPLSMonitorKitTests`; in `SickPLSPerformanceSessionTests` wurde einer **ersetzt**, die Zahl dort bleibt gleich): Der Nachweis wandert an die Entstehungsstelle (`ScanSessionProfilePublisherTests` — Rauschen, ein Profil, leerer Lesevorgang und zwei Profile in einem Lauf; jedes veröffentlichte Ereignis trägt mindestens ein Profil, und `didDropEarlierProfiles` stimmt mit dem Zählwert überein), dazu eine Deklarationsprüfung (ein Compile-Nachweis ist unmöglich — ein Test mit dem verbotenen Aufruf ließe sich nicht übersetzen, und das Testziel importiert `@testable`). Zwei Gegenproben: wieder öffentlicher Initialisierer (1 Test fällt), ein Zählwert unter `1` veröffentlicht (4).
- **Neues frameworkfreies Package-Target `SickPLSCommissioning`** (SICK-030a, erster Teil der R8-Folge; abhängig **ausschließlich** von `SickPLSCore`, `SickPLSMacTransport` und `SickPLSActiveControl` — **kein SwiftUI, kein AVFoundation, kein CoreMIDI, kein Foundation**, und ausdrücklich **keine I/O-Schleife**; Importe, verbotene Bezeichner und die Manifest-Abhängigkeiten prüft `CommissioningBoundaryTests` automatisch, ebenso dass `SickPLSMacTransport` weiterhin keinen Schreibweg hat). Es wurde **kein Port geöffnet, kein Byte gesendet und keine Hardware angefasst** — dieser Slice baut ausschließlich prüfbare Fachverträge. `CommissioningRecipe.r26` (Auflage **A4**): das **eine** geschlossene Rezept mit gekoppelter Konfigurationsadresse, Loginmodus, Baudwechsel und Verifikationsadresse, `private init`, kein Adress-/Modus-/Baudcode-Wähler, und `SerialPortBaudRate` bleibt bei zwei Werten. `InstallationSecret` (Auflage **A5**): kurzlebiger, **nicht persistierbarer** Eingabewert — nicht `Codable`, nicht `@Published`, redigierte `description`/`debugDescription` und leerer `customMirror`, damit auch `dump()`/`String(describing:)` nichts zeigen. `CommissioningTelegram`: Encoder, die ihre Prüfwerte **ausschließlich über den bestehenden `Frame`-Vertrag** erzeugen (gerechnete Länge, gerechnete Prüfsumme) statt abgeschriebener Rohtelegramme; die Identitätsprobe ist die aus SICK-011 und keine zweite Implementierung.
- **Vollständige Antwortklassifikation** (SICK-030a): `AcknowledgementOutcome` hat acht getrennte Fälle (`acknowledged`, `rejected`, `unknownStatus`, `missingStatusByte`, `unexpectedCommandByte`, `observedScanProfile`, `timeout`, `undecodable`), und `isAcknowledged` ist für **genau einen** davon wahr. **Ein fehlendes Statusbyte ist niemals Zustimmung**, ein unbelegtes Statusbyte weder Zustimmung noch Ablehnung, und ein `0xB0`-Messstrom ist ein **eigener** Fall — nie „unerwartetes Kommandobyte" und nie ein Erfolg.
- **Reiner Wertreducer `CommissioningModel`** (SICK-030a; kein Port, keine Uhr, kein Thread, keine Fake-I/O — dasselbe Muster wie `ScanSessionState` und `ZoneEditorState`): alter Zustand plus Ereignis plus ein vom Aufrufer übergebener **monotoner** Zeitpunkt ergeben den neuen Zustand und **eine** Anweisung; der Reducer führt selbst nichts aus. Der Baudwechsel ist **eine zusammenhängende, überwachte Transaktion** (Zugang, Baudanforderung, alten Port schließen, Zielrate öffnen, Identität prüfen) — zwischen Login und Baudtelegramm liegt keine Nutzerpause, weil unbelegt ist, ob der Installationsmodus zeitlich verfällt. **Auflage A1:** Erfolg ist allein eine CRC-valide `0xB1`-Identitätsantwort am neu geöffneten Port bei der Zielrate; ein Messstrom wird höchstens als beobachtete Information geführt (`observedScanProfileStream`) und belegt nichts. **Auflage A2:** Das Login bekommt **genau eine** identische Wiederholung nach abgelaufener Frist (Default 1, Maximum 1), **jede** andere Sendung keine; ein Nicht-ACK oder Timeout stoppt den Ablauf. Alle Fristen sind **absolute, monotone Gesamtfristen** und stehen sichtbar im Modell, nicht in einer späteren Schleife. Ein gescheiterter Wechsel bietet nur die harmlose Ratendiagnose (je Rate genau eine Identitätsprobe) und den Hinweis, dass ein **Geräteneustart der einzige bekannte Rückweg** ist — es gibt **keinen** „zurück auf 9600"-Befehl, weil es dafür keinen Beleg gibt.
- **Redigiertes Audit** (SICK-030a): `CommissioningAudit` führt je Sendung Aktion, **Sendungsnummer**, Zieladresse, monotonen Zeitpunkt und Ergebnis — und **niemals Bytes, Payloads oder Geheimnisse**; die eine Login-Wiederholung ist als zweite Sendung sichtbar. `CommissioningRedaction` redigiert **inhaltsbasiert** (Bytesuche über den gesamten Puffer, jedes Vorkommen, Länge bleibt erhalten) statt an einem angenommenen Offset; die Frame-Beschreibung nennt Adresse, Kommandobyte und Payload-**Länge** und sonst nichts.
- **Strukturelle Portübergabe** (SICK-030a, Auflage **A3**). `ScanSession.portReleased` (`AnyPublisher<ScanPortRelease, Never>`) feuert **nach dem tatsächlichen `close()`**, **genau einmal je Verbindungsversuch** (auch wenn schon das Öffnen scheiterte), **auf dem Main Thread** und **nur für die aktuelle Verbindung** — eine verspätete Freigabe der alten Verbindung wird über eine aufsteigende Verbindungsnummer verworfen, statt die neue freizugeben. `ScanSession.isPortHeld` bleibt nach `disconnect()` `true`, bis das echte Schließen gemeldet ist; genau dort lag die Lücke, weil `disconnect()` sofort zurückkehrt und das `close(2)` später auf dem Lesethread passiert. `ScanPortRelease` trägt Pfad und Rate — **keine Bytes, keine Frames, keine Wanduhrzeit**. `SerialPortOwnership`/`SerialPortOwner`/`SerialPortClaimOutcome`: das Besitzmodell mit *frei*, *Monitor*, *Commissioning* — jeder Anspruch wird **sichtbar verweigert** statt still überschrieben, und nach belegter Verifikation verbindet der Monitor mit der **verifizierten** Rate statt mit einer Nutzereingabe. Die macOS-Portexklusivität (`EBUSY`) ist weiterhin **nicht** verifiziert und bleibt ausdrücklich Sicherheitsnetz, nicht Mechanismus.
- **`ReadLoopWorker` schließt jetzt auf jedem Rückkehrpfad** (SICK-030a): Am Stromende endete der Leseloop zuvor **ohne** `close()` — der Deskriptor fiel erst im `deinit`, zu einem Zeitpunkt, den niemand kennt; für eine Portübergabe ist „irgendwann" keine Zusage. Ebenso schließt `SickPLSSerialConnection.close()` den Deskriptor jetzt **auch nach einem vom Gerät ausgelösten Stromende**: „Strom zu Ende" und „Deskriptor zu" waren dasselbe Flag. Dass die reale `DarwinSerialPortFileDescriptor` sich bei EOF selbst schließt, ist **ihre** Eigenschaft und keine Zusage des Protokolls `SerialPortFileDescriptor` — auf dieser stillen Annahme stünde sonst die gesamte Portübergabe.
- **Quelltexttest gegen Geheimnisse** (SICK-030a, Auflage **A5**): `SecretLeakRuleTests` liest den Suchbegriff **zur Laufzeit aus der technischen Dokumentation** — kein Quelltext des Projekts enthält den Wert, auch der Test nicht — und prüft damit `Sources/`, `Tests/` und die Projekt-/Handoff-Dokumente. Lässt sich der Suchbegriff nicht ermitteln, **schlägt der Test fehl** statt zu überspringen (Lehre aus SICK-020b). Alle **Byteformen** werden ohne Abgrenzung gesucht; die **Textform** nur in Anführungszeichen, Backticks oder Apostrophen, weil sie zugleich ein gewöhnlicher Bezeichnerbestandteil des BSD-lizenzierten CRC-Referenzcodes ist und eine nackte Textsuche damit dauerhaft rot wäre — ein dauerhaft roter Test wird abgeschaltet, nicht gelesen.
- 81 neue Tests (SICK-030a), **978 insgesamt** (Commissioning 72, MonitorKit +8, MacTransport +1), alle **ohne Port, ohne Gerät und ohne TX**; acht Gegenproben (Login ohne Wiederholungsgrenze, fehlendes Statusbyte als Zustimmung, Messstrom als Beleg des Wechsels — zweimal, an zwei verschiedenen Stellen —, Freigabe vor dem tatsächlichen `close()`, frei editierbares Rezept, offsetbasierte Redaktion, Trennen gibt den Port sofort frei, sprechende Geheimnis-Beschreibung). Eine Gegenprobe deckte dabei eine **echte Testlücke** auf: Die Reihenfolgeaussage „Freigabe nach dem Schließen" war nicht beweisbar, solange der Fake sofort zurückkehrte — der Umweg über `DispatchQueue.main.async` ließ eine falsche Reihenfolge wieder richtig aussehen; der Fake schließt jetzt auf Wunsch **langsam**, und beide Reihenfolgetests fallen bei der falschen Variante. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`).
- **Der Portbesitz ist im produktiven Koordinator durchgesetzt** (SICK-030a1, Nachschärfung zu SICK-030a nach Supervisor-Prüfung; keine neuen Package-Targets, kein Commissioning-I/O, kein TX, keine UI-Neugestaltung). **Der Befund war berechtigt:** `SerialPortOwnership` und `ScanSession.portReleased` waren beide sauber gebaut und getestet, aber **niemand benutzte sie** — `ConnectionControlsView` rief `session.connect`/`session.disconnect` direkt. Die geforderte Portexklusivität war damit eine **Parallelstruktur**, kein erzwungener Produktpfad: Das Modell führte Buch, und der Port ging trotzdem auf. Neu: `MonitorPerformanceCoordinator` besitzt **genau ein** `SerialPortOwnership` (privat; `PerformanceSessionBoundaryTests` prüft, dass es im Modul genau eine Erzeugungsstelle gibt) und abonniert `ScanSession.portReleased` **genau einmal im `init`** — das Abonnement gehört der Sitzung, nicht der Verbindung, wie schon der Profilweg seit SICK-029.
- **Beanspruchen vor Öffnen, Markieren vor Trennen** (SICK-030a1): `MonitorPerformanceCoordinator.connect(portPath:baudRate:)` beansprucht zuerst den Monitorbesitz und fasst die Sitzung gar nicht erst an, wenn das Commissioning den Port hält; geöffnet wird mit `ownership.monitorConnectBaudRate(requested:)`, nach belegter Verifikation also mit der **verifizierten** statt der im Bedienfeld gewählten Rate. `disconnect()` markiert den Übergang **vor** dem asynchronen `ScanSession.disconnect()` — der Besitz wechselt erst auf dem **tatsächlichen** Freigabe-Ereignis zurück auf „frei", nie schon beim Trennen. Neue typisierte Rückgaben `MonitorConnectOutcome` (`connecting(baudRate:)`/`refused`) und `CommissioningAccessOutcome` (`granted`/`awaitingMonitorRelease`/`refused`) plus `@Published portAccessNotice`: **Der Text entsteht im Modell, nicht in der Ansicht** (Regel aus SICK-028), und er verschwindet nur durch einen **erfolgreichen** Bedienschritt an derselben Stelle, nie durch Zeitablauf.
- **Die I/O-freie Commissioning-Grenze für SICK-031 steht** (SICK-030a1): `requestCommissioningAccess()` vergibt ausschließlich Besitz — **öffnet nichts, sendet nichts, wartet auf nichts, kennt keine Frist**. Hält der Monitor den Port, wird **höchstens dessen kontrolliertes Trennen veranlasst** (`.awaitingMonitorRelease`); es wird kein Deskriptor weggerissen, und der Aufrufer fragt nach dem echten Freigabe-Ereignis erneut. `finishCommissioning(verifiedBaudRate:)` gibt frei und übernimmt eine Rate **nur**, wenn sie wirklich belegt wurde; ein Fehlschlag übergibt `nil` und lässt eine früher belegte Rate unangetastet.
- `ConnectionControlsView` verbindet und trennt nur noch über den Koordinator (SICK-030a1); den Sitzungs**zustand** liest sie unverändert direkt — das ist reine Anzeige. Sichtbar verändert hat sich nur eine Zeile: die Rückmeldung, wenn jemand anderes den Port hält, plus ein Hinweis auf eine belegte Rate. `PerformanceSessionBoundaryTests` schlägt fehl, sobald im App-Ziel wieder ein `session.connect`/`session.disconnect` auftaucht. Die neue Abhängigkeit `SickPLSPerformanceSession` → `SickPLSCommissioning` geht **nur in diese Richtung**; `SickPLSCommissioning` kennt weiterhin weder `SickPLSMonitorKit` noch dieses Ziel, was `CommissioningBoundaryTests` von der anderen Seite prüft. Beide Boundary-Listen wurden dafür **bewusst** erweitert.
- 15 neue Tests (SICK-030a1), **993 insgesamt**, alle ohne Gerät, ohne TX und ohne SwiftUI-Ansicht — Verbindungen und Freigaben laufen dabei durch die **echte** `ScanSession` samt echtem Hintergrund-Thread, gefälscht ist allein der Dateideskriptor. Belegt sind unter anderem: Commissioning wird erst **nach** dem echten `portReleased` gewährt (und der Fake-Deskriptor zeigt zum Zeitpunkt der Verweigerung nachweislich `closeCallCount == 0`), der Monitor kann während des Commissionings nicht verbinden (die Sitzung wird nicht einmal angefasst), ein **gescheitertes** Öffnen gibt den Port über dasselbe echte Ereignis frei, und eine verifizierte 38 400 schlägt eine Bedienanfrage mit 9600. Fünf Gegenproben (Ansicht verbindet wieder direkt; Besitz schon beim Trennen freigegeben; verifizierte Rate ignoriert; `connect` ohne Anspruch — 7 Tests fallen; Commissioning reißt den Port an sich). Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`).
- **Der Commissioning-Portvertrag ist widerspruchsfrei** (SICK-030a2, Auflage **A7** aus `review-sick-030a.md`, zwingende Vorbedingung für SICK-031; nur `CommissioningState.swift` berührt, **keine I/O-Schleife, kein Portzugriff, kein TX, keine Hardware**). **Der Befund war berechtigt:** Der Reducer sagte an seinen Ruhepunkten zweierlei — nach der bestätigten Ausgangsprüfung und nach der belegten Verifikation lieferte er `.stop` mit `needsPort == false`, der jeweils nächste Bedienbefehl sendete aber Login bzw. Messmodus **ohne** eine `openPort`-Direktive. Solange keine Schleife existierte, war das folgenlos; die Schleife hätte den Widerspruch aber selbst auflösen müssen, und eine der beiden Lesarten ergibt ein **Login auf geschlossenem Port**.
- **Neue Anweisung `CommissioningDirective.hold`** (SICK-030a2): Ruhepunkt, an dem die Schleife wartet und die Verbindung **offen hält** — genau das, was die Beleglage zwischen Identität, Login und Baudwechsel verlangt. `.stop` bedeutet ab jetzt ausschließlich „zu Ende, Port darf frei werden". `.hold` steht an drei Stellen: bestätigte Ausgangsprüfung, belegte Verifikation, bestätigter Messmodus. Der Port bleibt damit vom Beginn der Ausgangsprüfung bis zur `closingPort`-Phase durchgehend gehalten, und `needsPort` ist nun eine Aussage über **Besitz** statt über „gerade beschäftigt" (`switch` ohne `default`, damit eine neue Phase sich entscheiden muss).
- **Neues Ereignis `operatorFinishedSession` und neue Phase `sessionFinished`** (SICK-030a2): der **einzige** Freigabepunkt eines erfolgreichen Ablaufs. Bewusst ein eigener Zustand statt einer Rückkehr nach `idle` — „nie begonnen" und „bewusst beendet" sind zwei Lagen. Zulässig von jedem Ruhepunkt; **mitten in einer Sendung** ist er der reguläre `unexpectedEvent`-Fehler und nie ein stiller Erfolg (dafür gibt es den Abbruch). Fehlschlag, Abbruch und abgeschlossene Ratendiagnose geben weiterhin über `.stop` frei.
- **Die dokumentierte Regel „RX-Puffer vor jedem TX leeren" steht jetzt im Typvertrag** (SICK-030a2, Befund N1): `CommissioningDirective.requiresReceiveBufferFlush` ist `true` für Identität, **beide** Login-Sendungen, Baudwechsel und Messmodus — eine **berechnete Eigenschaft, kein Feld** (ein Feld ließe sich beim Bauen auf `false` setzen, eine Sendung ohne Leeren wäre dann eine gültige Direktive) und ohne `default`. `isSendDirective` ist deckungsgleich, was ein Test in beide Richtungen prüft; `releasesPort` trennt `.stop` von `.hold`. **Dieser Slice führt nichts davon aus** — das Leeren macht die SICK-031-Schleife.
- 8 neue Tests (SICK-030a2), **1001 insgesamt** (Commissioning 80), alle ohne Port, ohne Gerät und ohne TX; fünf Gegenproben (alte `.stop`-Semantik an den Ruhepunkten — 4 Tests fallen; `needsPort` am Ruhepunkt wieder `false` — 5; Login von der RX-Leerregel ausgenommen — 2; Sitzungsabschluss gibt nicht frei — 2; verdecktes Wiederöffnen vor dem Messmodus — 3). Die A1-/A2-Beweise sind unverändert erhalten. **Offen und ausdrücklich nicht Teil dieses Slices:** Die Ratendiagnose wechselt zwischen ihren beiden Proben die Baudrate ohne `openPort`-Direktive dazwischen — dieselbe Widerspruchsklasse, vom Review dort nicht benannt, vor SICK-031 zu klären. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`).
- **Zonen lassen sich ein- und ausschalten, und das Ausschalten ist sicher** (SICK-030b1, erster Teil des SICK-030b-Spielmodells; Auflage **A6** aus `review-sick-030-architecture.md`, **D2/D3/D4** aus `review-sick-030-ui-delta.md`. Keine neuen Targets, **keine UI-/SwiftUI-Änderung**, kein Learn, keine Griffgeometrie, kein Commissioning-I/O/TX, keine Hardware, keine Persistenz, kein MIDI). Neu: `EditableZone.isEnabled` — ein Merkmal des Editors und des Performance-Zugangs, **kein** Feld von `Zone` und ohne Vorgabewert im Initialisierer, weil „spielt mit" eine Entscheidung ist und nirgends still geerbt werden darf. **Neue Zonen aus `ZoneEditorState.addZone` entstehen deaktiviert** (D2): Eine frisch gezogene Zone ist sofort sichtbar und wird sofort bewertet, löst aber nichts aus, bis jemand sie ausdrücklich einschaltet.
- **Nur eingeschaltete Zonen spielen — gefiltert an genau einer Stelle** (SICK-030b1): `ThereminRuntime.ingest` reicht ausschließlich Zonen mit `isEnabled == true` an die `ZoneSignalPipeline` weiter. Nicht im Editor, nicht im Koordinator, nicht in der Oberfläche — so entsteht kein zweiter Profileingang und keine zweite Prognose. **Die Live-Anzeige bleibt vollständig:** `ZoneEditorState.evaluations(against:)` bewertet weiterhin jede Zone, damit man beim Einrichten sieht, was eine Zone täte, bevor man sie einschaltet.
- **Auflage A6 eingelöst, ohne neuen Sonderweg** (SICK-030b1): Das Ausschalten einer zugewiesenen, klingenden Gate-Zone löst beim nächsten echten Profil **genau ein** Gate-Off — die Zone fehlt in der Pipeline, der Steuervertrag meldet für den weiterhin belegten Slot `.inactive`, und der Adapter reicht das Off nur ein, wenn er zuvor selbst ein Gate-On gesetzt hatte. Weitere Profile werden sichtbar entdoppelt, ein Wiedereinschalten erzeugt **kein** künstliches Gate-On, und ohne vorheriges eigenes Gate-On bleibt alles stumm. **Ausschalten ist ausdrücklich kein Abwählen:** `gateUnassignmentReleases` bleibt bei `0`, und die Zuweisung bleibt bestehen — `reconcile(with:)` leert einen Slot weiterhin nur bei gelöschter oder umgerollter Zone, sonst ginge die Zuweisung beim bloßen Umlegen eines Schalters verloren.
- **„Nicht zugewiesen" und „zugewiesen, aber ausgeschaltet" sind zwei benannte Lagen** (SICK-030b1, Auflage D4): neue Typen `MissingRoleReason`/`MissingRequiredRole`; `ThereminRoleAssignmentState.missingRequiredRoles(in:)` und `isPlayable(in:)` nehmen die Zonenliste entgegen, `PerformanceStartRefusal.missingRequiredRoles` trägt denselben Grund. `ThereminPerformanceController.missingRequiredRoleStatus` ist der `@Published` Spiegel (er hängt an Zuordnung **und** Ein/Aus), `missingRequiredRoles` und `canStart` sind daraus abgeleitet. Neu ist außerdem `ZonePlaySlotStatus` mit `slotStatus(of:)`: Slot-Zustand, Ein/Aus und `Zone.role` bleiben **drei getrennte Angaben** für die späteren Insert-Karten, bewusst nicht zu einer Ampel zusammengelegt. Eine ausgeschaltete Zone bleibt zuweisbar, und **es wird nie von selbst zugewiesen**.
- **Auflage D3 im Zoneneditor** (SICK-030b1): neue reine Aktionen `ZoneEditorState.setZone(_:isEnabled:)` und `removeZone(_:)`; **jede direkte Änderung leitet den Entwurf neu aus der gespeicherten Zone ab**, statt zwei Stände zu mischen — ein ungespeicherter Eingabewert verfällt dabei sichtbar. `removeSelectedZone()` geht jetzt über `removeZone(_:)`.
- 41 neue Tests (SICK-030b1), **1042 insgesamt** (MonitorKit 138, ThereminRuntime 66, ThereminPerformance 81, PerformanceSession 51), alle ohne Audiogerät, ohne echten Timer und ohne Scanner; die Koordinatortests laufen durch die **echte** `ScanSession` samt Hintergrund-Thread, echtem `StreamParser` und echtem `B0ScanProfile.decode`. Fünf Gegenproben: Filter entfernt (5 Tests fallen, darunter der hängende Ton), Ausschalten als Slot-Löschung (8, darunter der Verlust der Zuweisung), neue Zonen eingeschaltet (4), Entwurf nicht neu abgeleitet (1), Spielbarkeit ignoriert den Schalter (6). Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`).
- **Reiner Zonen-Geometrie-Reducer** (SICK-030b2, zweiter Teil des SICK-030b-Spielmodells; Befund **N7** aus `review-sick-030-architecture.md`, Auflagen **D3**/**D5** aus `review-sick-030-ui-delta.md`. Keine neuen Targets, **keine SwiftUI-Ansicht und keine `DragGesture`**, kein Learn, keine Controller-/Audio-/AU-/Masterpegel-Arbeit, kein TX, keine Hardware, keine Persistenz, kein MIDI). Neu ist `ZoneGeometryReducer` in `SickPLSMonitorKit`: vier Griffe (`indexLowerBound`/`indexUpperBound`/`valueInnerBound`/`valueOuterBound`) und das Verschieben der ganzen Zone, als geschlossenes `ZoneGeometryGesture` statt eines optionalen Griffs. **SICK-032 zeichnet und bindet ihn**; diese Runde enthält keine Oberfläche.
- **Gesamtverschiebung seit dem Gestenstart, nie Delta-Akkumulation** (SICK-030b2): `ZoneGeometryGestureStart` trägt die **Momentaufnahme** der Ausgangszone mit. Läse der Reducer sie aus `zones[i].zone`, wanderte die Zone bei jedem Ereignis erneut um dieselbe Strecke, und ein am Rand gestoppter Griff käme beim Zurückziehen nicht an seinen Ausgangspunkt zurück. Das gilt für die ganze Zone **und** für einen einzelnen Griff — wer einen Griff nicht exakt mittig erwischt, bekommt kein Springen.
- **Befund N7 eingelöst** (SICK-030b2): Die Mindestausdehnung ist **fachlich** (`ZoneDraft.minimumIndexSpan`/`minimumValueSpan`) und nicht in Pixeln, sonst hinge die Gültigkeit einer Zone von der Fenstergröße ab. Griffe **stoppen** an der Gegengrenze und tauschen nie — vorhersagbar und ohne Umsortierung der Zuordnung; auch eine bereits minimal schmale Zone bleibt dabei gültig. Dass ein Pixel am inneren Griff im real beobachteten Bereich (≈ 21…169, SICK-012 → ≈ 22…38 % des Radius) deutlich weniger Rohwerte bewegt als am äußeren, ist die richtige Umkehrung der vierte-Wurzel-Anzeige und steht als eigener Test mit genau diesen Werten.
- **Keine zweite Geometrieformel, und eine Kopie weniger** (SICK-030b2, Auflage D5): Bildschirm → Fächer läuft ausschließlich über `FanScreenGeometry.fanCoordinate(forScreenPoint:)`, Fächer → Fachwert ausschließlich über `ZoneEditorGeometry`; die vierte-Wurzel-Umkehr steht weiterhin an genau einer Stelle. Die Index-→-Winkel-Formel stand bisher **zweimal** da (in `screenPoint` und beim Zeichnen der Ringsektoren) und ist jetzt `FanScreenGeometry.angleRadians(forIndexFraction:)`, die beide Stellen aufrufen.
- **`ZoneEditorState.applyGeometryGesture(...)` schreibt live in die eine Wahrheit** (SICK-030b2, Auflage D3): Das Ergebnis landet unmittelbar in `zones[i].zone`, und der offene Entwurf wird daraus neu abgeleitet. Unbekannte IDs (`ZoneGeometryApplication.unknownZone`, bewusst **neben** den Reducer-Gründen), entartete Fächergeometrie und nichtendliche Gestenwerte werden typisiert abgelehnt und lassen den Zustand vollständig unverändert. **Eine Geste aktiviert nichts, weist nichts zu und erzeugt kein Gate-Ereignis**; `id`, `isEnabled`, Rolle, Auswahl und jede andere Zone bleiben unberührt.
- 35 neue Tests (SICK-030b2), **1077 insgesamt** (MonitorKit 173), alle ohne Ansicht, ohne Gerät und ohne Scanner. Fünf Gegenproben: lineare statt inverser Radiusabbildung (**9** Tests fallen), Griff-Tausch statt Stopp an allen vier Griffen (**5**), entartete Fächergeometrie stillschweigend angenommen (**1** Fehlschlag **plus ein echter Prozessabsturz** — `Fatal error: Double value cannot be converted to UInt16`; der Guard verhindert also keinen falschen Wert, sondern einen Absturz), Entwurf nicht neu abgeleitet (**1**), Delta-Akkumulation am Zustand (**2**). Die letzte fiel zunächst **nicht** und legte eine echte Testlücke offen — kein Zustandstest wandte dieselbe Geste mehrfach an; zwei Tests ergänzt. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Unverändert offen und damit Vorbedingung für SICK-031:** die Ratendiagnose-Lücke aus SICK-030a2.
- **Reiner, sicherer Zone-Learn-Accumulator** (SICK-030c, dritter Teil des SICK-030b-Spielmodells; Auflage **D1** aus `review-sick-030-ui-delta.md`, Befunde **H1**/**N1**/**M5**. Keine neuen Targets, **keine SwiftUI-Ansicht**, kein `DragGesture`, kein Audio/AU/MIDI, keine Persistenz, kein Timer, **kein Scannerzugriff**, keine Hardware, kein Port, kein TX, kein Capture). Neu in `SickPLSControlCore`: `ZoneLearningConfiguration` (validierende Fabrik nach Hausmuster, ein eigener `BuildError` je Regel, alle Schwellen als **Profilanzahlen oder Rohwertdifferenzen**, nie als Wanduhrzeit) und `ZoneLearningAccumulator` (reiner Wertzustand — **keine Uhr, kein Timer, kein Thread, keine globale Variable**; Profile werden hineingereicht). Neu in `SickPLSMonitorKit`: `ZoneLearningSession` plus die Lernaktionen auf `ZoneEditorState`. Die Mathematik liegt bewusst in `SickPLSControlCore`, weil dort `Zone.indexFraction(forIndex:count:)` modulintern verfügbar ist — **dieselbe** Indexformel, die `Zone.evaluate` benutzt (Befund M5), statt einer zweiten Kopie.
- **Auflage D1 in zwei Hälften eingelöst** (SICK-030c): Rechnerisch wird die Wertobergrenze des Kandidaten unter den kleinsten **gültigen** Grundwert im Indexbereich abzüglich `backgroundClearance` geklemmt. Strukturell wird der fertige Kandidat danach gegen **jedes** Profil des Grundfensters mit dem **echten** `Zone.evaluate` geprüft und nur angeboten, wenn er überall `.inactive` ist — **bewusst kein Nachbau dieser Prüfung**: `evaluate` kennt „ungültiger Messwert" nicht, ein `0`-Punkt im Indexbereich **würde** die Zone im Betrieb aktivieren, obwohl die Statistik ihn ignoriert hat, und genau das fängt die Nachbedingung (eigener Test). Lässt sich keine sichere Zone bilden, ist das Ergebnis `refused(.backgroundInsideZone)` — **nie** ein Ersatzkandidat.
- **Das Grundprofil ist ein Fenster, nie ein einzelner Frame** (SICK-030c, Befund H1): Minimum und Maximum je Index über alle gültigen Werte **aller** Grundprofile; gegen einen zufälligen letzten Frame zu vergleichen machte jedes Hintergrundrauschen zur „Bewegung". Bewegung ist **richtungsneutral** (`< min − delta` oder `> max + delta`, Befund N1); die Richtungsannahme „Objekt näher als der Hintergrund" steckt erst in der Zonenbildung. **`0` und `8191` sind für Hüllkurve und Bewegung ungültig**, `fieldFlags` werden mitgeführt und **nirgends gedeutet**; ein Index ohne einen einzigen gültigen Grundwert kann nie ein Treffer werden.
- **Persistenz vor Cluster, Gleichstand wird verweigert** (SICK-030c): Ein Index zählt erst ab `minimumPersistenceProfiles`, Cluster entstehen allein über `maximumIndexGap` (Zahl der **fehlenden** Indizes), der stärkste gewinnt nach Trefferzahl — und erreicht der zweitstärkste mit `ambiguityToleranceFactor` den stärksten, wird **verweigert statt nach Index geraten**. Ein zu kleiner Cluster wird ebenfalls verweigert. `refused`, `cancelled` und `failed` bleiben drei getrennte Lagen („gerechnet und unsicher" / „von außen beendet" / „die Profile passen nicht zum Vorgang") und werden nie zusammengefasst.
- **Learn schaltet nie eine Zone ein** (SICK-030c, Auflagen D2/D3): Armiert wird **nur** auf einer **deaktivierten** Zone; ein Kandidat verändert **weder** `zones[i].zone` **noch** `isEnabled`. Erst `applyLearnCandidate()` schreibt, und nur an **dieselbe, weiterhin deaktivierte** Zone mit **unveränderter Rolle**, danach wird der Entwurf daraus neu abgeleitet. Entfernen, Rollenwechsel, Aktivierungswechsel und Punktzahlwechsel beenden die Sitzung mit benanntem Grund; derselbe Aktivierungswert nochmals gesetzt ist **keine** Änderung, eine reine Grenzenänderung ebenfalls nicht (sie ist genau das, was das Lernen überschreiben soll), und eine Änderung an einer **fremden** Zone berührt die Sitzung nicht. **Kein Timeout, keine Profilobergrenze** — ein Vorgang endet nur durch Abschließen, Abbrechen oder weil die Daten nicht mehr passen.
- **Genau ein Profilstrom** (SICK-030c, Auftragspunkt 8): `MonitorPerformanceCoordinator.receive` reicht **denselben** `ScanProfileBatch` nach der Klangerzeugung an das Lernen weiter. **Ein zweites `ScanSession`-Abonnement, ein Timer oder eine Parallelquelle für Learn sind ausdrücklich verboten.** Ohne armierten Vorgang ist der Aufruf wirkungslos und verändert `zones` nicht; ein laufender Lernvorgang startet keine Audioausgabe, erzeugt kein Gate und verändert die Signale der übrigen Zonen nicht.
- 64 neue Tests (SICK-030c), **1141 insgesamt** (ControlCore 109, MonitorKit 196, PerformanceSession 57), alle ohne Ansicht, ohne Uhr, ohne Audiogerät und ohne Scanner; die Koordinatortests laufen durch die **echte** `ScanSession` samt Hintergrund-Thread, echtem `StreamParser` und echtem `B0ScanProfile.decode`. Sechs Gegenproben: letzter Grundframe statt Fenster (**2** Tests fallen — der Fenstertest **und** die D1-Nachbedingung), Gleichstand per „erster Cluster gewinnt" (**1**), D1-Nachbedingung entfernt (**1**), Übernehmen schaltet ein (**2**), Armieren auf eingeschalteter Zone erlaubt (**1**), zweiter Profilweg im Koordinator (**1**). Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen:** Die Startwerte für `movementDelta`, `valuePadding` und `backgroundClearance` sind an der Größenordnung des einzigen echten Mitschnitts orientiert (Rohwerte ≈ 21…169, SICK-012) und **am realen Gerät nicht gemessen**; der gesamte Lernpfad ist bisher **ausschließlich gegen synthetische Profile** belegt, die reale Scannerverifikation steht aus. **Unverändert offen und damit Vorbedingung für SICK-031:** die Ratendiagnose-Lücke aus SICK-030a2.
- **Die Learn-Wertgrenzen folgen nur dem ausgewählten Bewegungscluster** (SICK-030c1, Nachschärfung zu SICK-030c; **keine neue API, keine UI, kein Audio/MIDI/AU, keine Hardware/Ports/TX, kein Capture**). Bis dahin sammelte `ZoneLearningAccumulator` Minimum und Maximum der Bewegung **global** über alle Treffer: Gewann ein Cluster, während ein deutlich schwächerer — und damit zu Recht nicht mehrdeutiger — zweiter Cluster ganz andere Rohwerte trug, war der Kandidat im Indexraum präzise, im Werteraum aber durch die **verworfene** Bewegung aufgeweitet. Auflage D1 verhinderte dabei jederzeit ein unsicheres Dauer-Gate, aber bei Pitch und Volume ist der Unterschied zwischen einer Zone um 500 und einer von 480 bis 2520 der Unterschied zwischen einem brauchbaren und einem beliebigen Lernergebnis.
- **Verbindliche Regel** (SICK-030c1): Die Bewegungswerte werden **je Punktindex** geführt, und die Wertgrenzen entstehen **ausschließlich** aus den **persistenten Indizes des gewählten Clusters** — nicht aus einer globalen Spanne, nicht aus dem gepolsterten Indexbereich und nicht aus einem verworfenen Cluster. Nicht persistente Indizes tragen auch dann nichts bei, wenn die Lückentoleranz sie **mitten im Cluster** überbrückt. **An D1-Reihenfolge und -Nachbedingung wurde nichts geändert** (Puffer, Klemmung gegen das gesamte Grundfenster abzüglich Sicherheitsabstand, danach `Zone.evaluate` gegen jedes Grundprofil), ebenso wenig an Ambiguitäts-, Cluster-, Profil- und Aktivierungssemantik.
- 4 neue Tests (SICK-030c1), **1145 insgesamt** (ControlCore 113). Zwei Gegenproben: die alte globale Sammlung bricht **3** Tests, Werte aus dem **gesamten** Clusterbereich statt aus den persistenten Indizes bricht **1**. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Unverändert offen und damit Vorbedingung für SICK-031:** die Ratendiagnose-Lücke aus SICK-030a2.
- **Klangfarbenauswahl und Masterpegel** (SICK-030b3, dritter Teil des SICK-030b-Spielmodells; **keine SwiftUI-Ansicht und kein Channelstrip**, keine neue AU-Suche oder -Instanziierung, kein MIDI, keine Hardware, keine Scanner-/Port-/TX-Aktion, kein Capture, keine Persistenz, keine externe Bibliothek). Neu in `SickSynthAudio`: **`SynthTimbrePreset`** — vier benannte Klangfarben (`classicTheremin` als dokumentierter Startklang, `singingReed`, `hollowFlute`, `pluckedBell`) als **geschlossenes** `enum` mit einer einzigen Werttabelle und `switch` ohne `default`; **kein frei erfundenes Preset-System, keine Persistenz**. Die Geschlossenheit ersetzt die validierende Fabrik: `SynthTimbre` hat einen `fileprivate` Initialisierer, außerhalb der Tabelle entsteht keine Klangfarbe.
- **Eine Klangfarbe bestimmt ausschließlich, was der Scanner nicht bestimmt** (SICK-030b3): Wellenformmorph, Filtergüte und die vier Hüllkurvenzeiten. `frequencyHz`, `amplitude` und `filterCutoffHz` gehören dem Mapping-Adapter und werden **nie** angefasst — `ThereminParameters.applying(_:)` legt auf, statt zu ersetzen. **Nichts wird geerbt:** dieselbe Klangfarbe auf zwei völlig verschiedene Parametersätze gelegt ergibt dieselben sechs Werte (eigener Test). Und die Scannersteuerung überschreibt den Presetanteil nicht — das folgt aus der Patch-Semantik von SICK-024 und ist jetzt geprüft, gegen Fake-Dienst, gegen den echten `ThereminAudioEngine` und über den vollständigen Weg Profil → Zonen → Laufzeitbrücke → Adapter → Dienst.
- **Neu: `MasterLevel`** (SICK-030b3) — validierter Wert, lineare Verstärkung `0...1`, `build(gain:) throws` nach Hausmuster mit eigenem Fehlerfall und **ohne stille Klammerung**; nicht endliche Werte werden ausdrücklich abgelehnt. **Bewusst kein dB-Vertrag:** Der Mischerknoten kennt nur diese Zahl, eine dB-Fassade bräuchte eine zweite Darstellung, eine Umrechnung und einen erfundenen Punkt für „minus unendlich“ — die Anzeige darf später dB beschriften. Startwert `0,8`, begründet statt geraten: Der Hauptmischer summiert trockenes Signal **und** beide Sends, bei Unity wäre die Summe übersteuert, bevor jemand etwas falsch macht. **Kein eingemessener Wert.**
- **Der Master sitzt auf dem Hauptmischer** (SICK-030b3) — dem Knoten, in den im `AudioGraphPlan` **jeder** Weg mündet, also hinter Stimme, internen Delay-/Hall-Sends und der seriellen Kette eines vorbereiteten AU-Racks; belegt über die Racklängen 0…4 (der Hauptmischer ist nie Quelle, jeder andere Zielknoten hat einen Ausgang, genau drei Eingänge). Er **ersetzt die Volume-Zone nicht und verfälscht sie nicht**. **Kein zweiter Lautstärkeregler und keine Multiplikation im Renderpfad** — dort läge er vor den Effekten und dämpfte den Hall mit; am Renderblock wurde nichts geändert.
- **`AudioOutputHost` hat genau eine neue Methode, `applyMasterLevel(_:)`, ohne Vorgabeimplementierung** (SICK-030b3) — dieselbe Lehre wie bei `setOutputConfigurationChangeHandler(_:)` aus SICK-028: Eine leere Standardmethode wäre die stille Lücke, in der ein neuer Host den Master folgenlos verschluckt. Real umgesetzt über `engine.mainMixerNode.outputVolume` **und** in allen fünf Testhosts. **Nichts davon startet etwas:** Vor `start()` gesetzte Werte werden geführt und beim Start ausdrücklich erneut übernommen, ein Wechsel im Betrieb baut nichts um, stoppt nichts und erzeugt kein Gate; ein Stopp vergisst weder Klangfarbe noch Master.
- **`ThereminPerformanceController` ist die einzige produktive Steuergrenze für Klang und Master** (SICK-030b3): Der Dienst bleibt privat (SICK-028, Befund N2), beides steht als `@Published` Spiegel bereit, dessen Anfangswerte **aus dem Dienst** kommen statt aus einer zweiten Vorgabeliste. `update(master:)` nimmt einen fertigen `MasterLevel` und **kein nacktes `Float`** — ein zweiter, ungeprüfter Weg wäre dieselbe Lücke wie in SICK-022a/024a/029a. `PerformanceSessionBoundaryTests` verbietet der Oberfläche zusätzlich `applyMasterLevel` und `AudioOutputHost`; `ThereminAudioControlling` bleibt unverändert bei fünf Mitgliedern.
- 37 neue Tests (SICK-030b3), **1182 insgesamt** (SynthAudio 168, ThereminAudioControl 74, ThereminPerformance 91), alle ohne Audiogerät, ohne echten Timer, ohne echte Uhr und ohne Scanner. Vier Gegenproben: Master in den Stimmensnapshot eingemischt (**2** Tests fallen), Klangfarbe von einem Scanner-Parameter-Update überschrieben (**4**), Master beim Start nicht erneut übernommen (**1**), Klangfarbe ersetzt den ganzen Parametersatz statt aufzuliegen (**2**). Die erste fiel zunächst nur einfach und legte eine echte Testlücke offen — der Unabhängigkeitstest setzte den Master zuletzt auf `1,0`, wo eine heimliche Multiplikation unsichtbar bleibt; er benutzt jetzt `0,5` bei Amplitude `0,9`. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen:** Es wurde **nichts gehört** — der reale Hörtest aus ROADMAP R6 steht weiterhin aus, und eine Oberfläche dafür gibt es erst mit SICK-033.
- **Die Ratendiagnose wechselt den Port explizit** (SICK-030a3; schließt die seit SICK-030a2 bekannte, blockierende Modelllücke vor SICK-031. Nur `CommissioningState.swift` berührt: **keine I/O-Schleife, kein realer Port, kein TX, keine Hardware, keine SwiftUI, kein Audio/AU/MIDI, keine Persistenz, kein Capture**). Bisher sendete `operatorRequestedDiagnostics` die Probe bei 9600 und die Probe bei 38400 nacheinander, **ohne einen dazwischenliegenden Portwechsel** — das Modell behauptete einen Ratenwechsel, den keine spätere Transportadaption korrekt ausführen könnte. Neu ist der Typ `CommissioningDiagnosticsStep` (`openingPort`/`probing`/`closingPort`) und die Phase `runningDiagnostics(step:report:)`; die Folge lautet `openPort(9600)` → bestätigtes `portOpened(9600)` → Probe → Ergebnis oder Frist auditiert → **wirkliches** `closePort` → bestätigtes `portClosed` → `openPort(38400)` → bestätigtes `portOpened(38400)` → Probe → Ergebnis auditiert → `stop` mit freigegebenem Port.
- **Das letzte Schließen liegt im `stop`-Vertrag**, nicht in einer eigenen Direktive (SICK-030a3): Die Freigabe des Portbesitzes schließt, was offen ist — und das stimmt in **beide** Richtungen, nach einer abgeschlossenen Diagnose ebenso wie nach einem gescheiterten Öffnungsversuch, bei dem gar nichts offen ist. Ein ausdrückliches `closePort` am Ende setzte ein offenes FD voraus. Das ausdrückliche `closePort` steht ausschließlich dort, wo danach **wieder geöffnet** wird.
- **Neues Ereignis und neuer Fehlerfall `portCloseFailed(String)`** (SICK-030a3): Ein Schließfehler beendet den Ablauf dort sichtbar, wo ein Wiederöffnen darauf aufbaut — in der Diagnose **und** im überwachten Wechsel —, statt als `unexpectedEvent` zu erscheinen. Ebenso beenden eine falsche oder fehlende Öffnungsbestätigung, ein Öffnungsfehler, eine unerwartete Reihenfolge und der Abbruch die Diagnose sichtbar, **ohne Konfigurationstelegramm und ohne versteckten Retry**.
- **Der Port bleibt über den ganzen Ratenwechsel hinweg gehalten** (SICK-030a3) — auch zwischen bestätigtem Schließen und Öffnen: Der Ablauf gibt ihn nicht ab, er wechselt die Rate; ein zwischenzeitlich freier Port wäre eine Einladung an den Monitor, ihn zu übernehmen. Nach dem Ende ist er frei. **Gesendet wird ausschließlich die harmlose Identitätsprobe**, je Rate genau eine, ohne Wiederholung, mit `requiresReceiveBufferFlush == true`; der Auditbericht trägt weiterhin genau zwei benannte `diagnosticProbe`-Einträge ohne Bytes und ohne Geheimnis. **Weder ein Messstrom noch eine Bestätigung noch ein vermuteter Ratenwechsel gilt als Identitätserfolg.**
- 14 neue Tests (SICK-030a3), **1196 insgesamt** (Commissioning 94), weiterhin ohne Port, ohne Gerät und ohne TX. Am Hauptrezept wurde nichts geändert: eine Login-Wiederholung, B1-Erfolg bei 38400, kein Rückstellkommando, A7-Porthaltevertrag in der eigentlichen Sitzung. Fünf Gegenproben: Zwischen-Close/Open entfernt (**12** Tests fallen, darunter Sequenz- und Porttest), Öffnungsbestätigung ohne Ratenprüfung angenommen (**1**), Probe ohne bestätigtes Öffnen gesendet (**13**), Schließfehler ignoriert (**1**), Port während des Ratenwechsels freigegeben (**2**). Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`).
- **Kontrollierte Commissioning-Transportadaption** (SICK-031; **kein echter Port, kein TX, kein Hardwarezugriff, keine Capture-Datei, keine SwiftUI, kein Audio/AU/MIDI, keine Persistenz von Geheimnis oder Zustand, keine freie Baud-/Adress-/Rezeptkonfiguration, keine externe Bibliothek**). Neu in `SickPLSCommissioning`: **`CommissioningTransport`** — eine schmale Protokollgrenze mit genau fünf Mitgliedern (öffnen, schließen, RX-Puffer leeren, schreiben, lesen); **`ActiveControlCommissioningTransport`** — die reale Umsetzung über die bestehende TX-Grenze `ActiveControlSerialPort`, mit der `/dev/cu.`-Prüfung bereits im Initialisierer; **`CommissioningExecutor`** — die **einzige** Stelle, die Direktiven ausführt. Er nimmt eine Bedienhandlung entgegen, läuft bis zum nächsten Ruhepunkt und liefert einen `CommissioningStepReport`. **Keine zweite Zustandsmaschine und keine zweite Fristberechnung:** Jede Frist stammt unverändert aus dem Reducer.
- **Echte Ein-/Ausgabe steht an genau zwei Stellen** (SICK-031): Das bisherige modulweite I/O-Verbot wurde nicht gelockert, sondern **verschärft** — `CommissioningBoundaryTests` erlaubt `ActiveControlSerialPort`, `func write(` und `open(atPath` nur noch in `CommissioningTransport.swift` und `ActiveControlCommissioningTransport.swift`, prüft zusätzlich, dass der Executor selbst keinen Port anfasst, und schlägt fehl, wenn die Prüfung ins Leere liefe. `SickPLSMacTransport` bleibt weiterhin strukturell RX-only.
- **Vor jeder Sendung wird der RX-Puffer geleert** (SICK-031), unmittelbar davor und ohne etwas dazwischen; gesendet werden ausschließlich die bestehenden typisierten Telegrammbauer. **Das Geheimnis wird nur durchgereicht** — es gilt für die Dauer genau eines `perform(...)`-Aufrufs, wird danach fallengelassen und von Executor, Koordinator und Audit weder gespeichert noch beschrieben. Ein Testwert erreicht den Produktionspfad nicht.
- **Der Portwechsel folgt dem Reducer** (SICK-031): `hold` liest und sendet nichts und hält den Port; `stop` schließt idempotent, auch nach einem vorher gescheiterten Öffnen oder Schließen. Die SICK-030a3-Ratendiagnose ist damit wirklich ausführbar — 9600 öffnen, proben, **wirklich** schließen, 38400 öffnen, proben, beenden; ein Schließfehler führt nie zu einem Öffnen bei der anderen Rate. Jeder Leseaufruf bekommt die **verbleibende** Zeit, ein `timeout` ist deshalb das Fristende selbst.
- **Keine rohen Bytes nach außen** (SICK-031): B1, ACK, NACK, Frist, Mehrdeutigkeit und ein beobachteter B0 werden in Ereignisse übersetzt; ein B0 verlängert keine Frist und belegt keine Rate. I/O-, Decodier- und Schreibfehler werden sichtbar (`writeFailed`, `portOpenFailed`, `portCloseFailed`) statt als stille Stille. **Nichts startet von selbst** — der Executor tut beim Erzeugen nichts, und `MonitorPerformanceCoordinator` bekommt nur eine vorbereitete, I/O-freie Grenze: `commissioningRunReadiness(portPath:)` beantwortet die Startvoraussetzung, ohne etwas zu tun, `completeCommissioning(with:)` gibt den Besitz **genau einmal** frei und übernimmt die Rate **ausschließlich aus dem Bericht** (Auflage A1).
- 54 neue Tests (SICK-031), **1250 insgesamt** (Commissioning 135, PerformanceSession 70), alle gegen Fakes mit injizierter monotoner Zeit, **ohne Port, ohne Gerät, ohne TX und ohne PTY-Probe**. Drei Gegenproben: RX-Leeren **nach** statt vor der Sendung bricht **2** Tests, ein Messstrom als Beleg für 38400 bricht **5** (darunter der Koordinatornachweis), der Ratenwechsel der Diagnose ohne dazwischenliegendes Schließen bricht **14** — dabei lehnt der reale Adapter das zweite Öffnen mit `portAlreadyOpen` ab. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen, ausdrücklich keine Erfolgsmeldung:** Der **erste physische Commissioning-Lauf hat nicht stattgefunden**, die **macOS-Portexklusivität (`EBUSY`) bleibt unverifiziert**, und der reale Lauf braucht eine **gesonderte, ausdrückliche Nutzeraktion**.
- **Die beiden realen Randfälle des Executors sind korrigiert** (SICK-031a; Auflagen **E1**/**E2** aus dem Meilenstein-Review, **zwingende Vorbedingung für jeden ersten realen Commissioning-Lauf**. Nur `CommissioningExecutor.swift` und die Kopfdoku von `CommissioningTransport.swift` berührt: **kein Reducer-, Rezept-, Portbesitz-, Adapter-, UI-, Audio-, MIDI- oder AU-Umbau, kein echter Port, kein TX, keine Hardware, keine PTY**).
- **E1 — ein B0-Fragment unterdrückt die Login-Wiederholung nicht mehr** (SICK-031a): „Unlesbar" gilt nur noch, wenn im gesamten Wartefenster **kein einziger gültiger Frame** decodiert wurde; kam auch nur einer, ist verbliebenes Rauschen das **Fragment eines bekannten Stroms** und das Ergebnis `deadlineReached`. Bei 9600 ist genau das der Regelfall: Der Scanner streamt dort von sich aus B0-Profile (SICK-012), das Leeren vor der Sendung räumt nur ab, was schon dasteht, und die ersten Bytes danach sind meist die Fortsetzung eines **angeschnittenen** Frames. Vorher endete ein **unbeantwortetes** Login als `.failed(.loginAmbiguous)`, und der Reducer verweigerte die **eine** belegte Wiederholung (A2), die den dokumentierten R26-Verlauf erst hat gelingen lassen. **Am Reducer und an A2 wurde nichts geändert**; die Parserdiagnosen bleiben verfügbar.
- **E2 — ein vorzeitiges Transport-Timeout ist nicht das Fristende** (SICK-031a): `.timeout` führt zurück in die Restfrist-Schleife, beendet wird das Warten ausschließlich über die absolute, monotone Grenze des Reducers. `DarwinActiveControlSerialPort` meldet ein von einem Signal unterbrochenes `poll(2)` als `.timeout` — vorher hätte ein einziges Signal einen Login-Versuch vorzeitig als „unbeantwortet" gewertet und die einzige Wiederholung verbraucht. Der Satz im Protokollvertrag, dass `read` bei Stille nicht vor Ablauf zurückkehrt, ist damit **Erläuterung statt Voraussetzung**; Test-Fakes, die `.timeout` liefern, müssen dafür die injizierte Uhr mitführen.
- 6 neue Tests (SICK-031a), **1256 insgesamt** (Commissioning 141), weiterhin ohne Port, ohne Gerät, ohne TX und ohne PTY. Darunter der geforderte Pflichtnachweis (Fragment eines B0-Frames + vollständige B0-Frames + ausbleibende Antwort → **exakt** die zweite Login-Sendung) und die Gegenrichtung als eigener Test (dieselben Rauschbytes **ohne** gültigen Frame bleiben mehrdeutig, **keine** Wiederholung). Drei Gegenproben: E1 zurückgenommen bricht **2** Tests, E2 zurückgenommen **2**, ein zu weit gefasstes E1 **2**. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen, ausdrücklich keine Erfolgsmeldung:** Der **erste physische Commissioning-Lauf bleibt gesperrt** — **E3** (Hintergrund-Thread, genau ein `perform` zur Zeit, Bericht auf den Main Thread, ausdrückliche Bestätigung vor dem Senden) gehört zu SICK-032, und es braucht zusätzlich eine **ausdrückliche Nutzeraktion**; **M2** und **N1–N7** des Reviews bleiben Folgearbeit.
- **Der Scanfeld-Zoom ist formtreu und planar statt polar umparametrisierend** (SICK-032b2c, Owner-Fehlerbericht „beim Hineinzoomen verzieht sich das Messbild"; **kein Scanner, kein Port, kein TX/RX, kein Capture, keine neue Bedienfunktion, keine Änderung der Zonenfachlogik**; die SICK-032b2b-Fixe — multiplikativer Zoomfaktor, Einheiten-/Richtungsbehandlung — bleiben unangetastet). **Ursache:** `LinearScanFieldGeometry.project` normierte Winkel- und Entfernungsbereich **getrennt** auf `0...1` und zeichnete bei jedem Ausschnitt neu einen **vollständigen** 180°-Fächer — eine polare **Umparametrisierung**, kein Bild-Zoom. **Die Korrektur:** eine kanonische Weltposition je Feldpunkt entsteht jetzt **exakt einmal** (`worldPoint(angleFraction:radiusFraction:)`, über einen wiederverwendeten „Einheitsfächer", keine neue Trigonometrie); der Ausschnitt (neuer, isotroper `ScanPlaneViewport`, ersetzt `ScanViewport` vollständig) wird darauf ausschließlich **affin** — Skalierung plus Verschiebung, kein erneutes Fächern — angewendet. Scanfeld, Zonenflächen, Griffe, Trefferprüfung, Verschieben, Rahmenzoom, Lupe, Rad und Pinch laufen ausnahmslos über diese eine Geometrie; der Feld-/Zonenraum selbst bleibt unverändert polar.
- **Zwei eigenständig gefundene, über die reine Migration hinausgehende Fehler** (SICK-032b2c), beide durch Herleitung erkannt, nicht durch Testzufall: **(1)** ein **quadratischer statt linearer Skalierungsfehler** — die erste Fassung teilte den Versatz zum Ausschnittsmittelpunkt zweimal durch `halfExtent` und hätte die Bildschirmposition quadratisch statt linear mit dem Zoom skalieren lassen (bei Gesamtansicht zufällig richtig, sonst sichtbar falsch); behoben durch eine einzige gebündelte Division. **(2)** eine **fehlende ausschnittsbezogene Randklammerung** beim Rückweg Bildschirm → Feld — die bestehende Feldklammerung von `FanScreenGeometry` bezieht sich auf das **gesamte** Feld, nicht den sichtbaren Ausschnitt; ein Zug über den sichtbaren Rand wäre bis zum Feldrand gesprungen statt dort zu stoppen (Bruch des seit SICK-030b2 geltenden Vertrags). Behoben durch eine neue **radiale** Randklammerung, begründet durch die Kreisform des gezeichneten Sektors gegenüber dem quadratischen Ausschnitt. Beide Fixes gegenprobt (gezielte Rücknahme, bestätigter erwarteter Testausfall, byteidentische Wiederherstellung).
- **Formtreue-Nachweis** (SICK-032b2c): ein asymmetrisches ≥3-Punkte-Muster wird unter wiederholtem Zoom als **eine** affine Skalierung/Verschiebung abgebildet; dieselbe Prüfung schlägt gegen eine nachgebaute **alte**, getrennt normierende Fächer-Formel nachweislich fehl (geforderte Gegenprobe im Test selbst). 2 neue Tests, **1610 insgesamt** (MonitorKit 358), alle ohne gerenderte Ansicht, ohne Gerät und ohne Scanner. Zwei Gegenproben: Skalierungsfehler wieder eingeführt bricht **3** Tests, Randklammerung entfernt bestätigt den erwarteten Ausfall exakt (`8191.0` statt `3010.0`). Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen:** Es lag kein Gerät im Zuschnitt — die Wirkung ist ausschließlich rechnerisch belegt; Verschieben und Rahmenzoom rechnen weiterhin mit Winkeldifferenzen zweier Punkte und sind von der Zoom-Anker-Vereinfachung nicht betroffen (unverändert seit SICK-032b2b als Folgearbeit festgehalten).
- **Canvas, Clipping und Zonen-Sichtbarkeit sind deckungsgleich mit dem sichtbaren planaren Viewport** (SICK-032b2c-K1, Korrekturauftrag zur Supervisor-Prüfung von SICK-032b2c; **kein Scanner, kein Port, kein Commissioning, kein B0-Pfad, kein Learn, kein Synth/Audio/AU/MIDI, keine neue Bedienfunktion, keine Änderung der Zonenfachlogik**). **Abnahmeblocker 1 — Fächeranker:** `FanScreenGeometry.init(size:)` war weiterhin an der alten, nahe dem unteren Rand liegenden Fächerspitze verankert, obwohl `project(worldPoint:)` seit SICK-032b2c voraussetzt, dass `center`/`radius` die **wirkliche** Mitte/Halbausdehnung der sichtbaren Fläche sind (belegt an 800×600: beide Fächerendpunkte lagen außerhalb `0...800`, ein verschobener Ausschnitt zentrierte falsch). Behoben durch einen **isotropen, zentrierten Quadrat-Fit** (`center = (W/2, H/2)`, `radius = min(W,H)/2`); die dadurch bewusst leer bleibende untere Fächerhälfte (der 180°-Fächer deckt nur die halbe kanonische Welt ab) sowie Letterbox-Ränder bei nicht quadratischen Ansichten sind **dokumentiert, nicht weggeclippt**. Zusätzlich: **ein** gemeinsamer Clip (`LinearScanFieldGeometry.canvasRect`, einmal in `ScanFieldView` angewendet) statt des bisherigen statischen, `project`-unabhängigen Kreis-Clips in `PolarScanView` bei gleichzeitig fehlendem Clip in `ZoneOverlayView`; die Fächerkontur wird jetzt über dieselbe `project`-Geometrie wie die Messkurve gezeichnet (ein `addArc`, mathematisch exakt, da eine isotrope affine Abbildung Kreisbögen auf Kreisbögen abbildet). `clampedToVisibleEdge` klammert jetzt **achsenweise statt radial** (der sichtbare Ausschnitt ist unter dem korrigierten Modell ein Quadrat, kein eingeschriebener Kreis) — **`LinearScanFieldGeometry.swift` enthält damit keine `squareRoot` mehr**, die bisherige Testausnahme ist entfallen. **Abnahmeblocker 2 — analytische statt abgetastete Sichtbarkeit:** `ZoneHandleGeometry.isVisible`s feste 16er-Winkelabtastung konnte das tatsächliche Bogenextremum zwischen zwei Stichproben verfehlen und eine sichtbare Zone fälschlich als unsichtbar melden (belegt: Winkelanteil `0,11...0,91`, enger Viewport um `(0,-1)` — echtes `minY = -1`, Abtastung nur `-0,9995...`). Behoben durch exakte Auswertung der Endwinkel plus jedes im Bereich liegenden kartesischen Extremwinkels (`0°/90°/180°/270°`) über die bestehende `worldPoint(angleFraction:radiusFraction:)` — **keine zweite Trigonometrie**, keine `cos`/`sin`/`import Darwin` in dieser Datei. Drei bestehende Tests an die jetzt korrekte Geometrie angepasst (Testgrundlage war selbst Teil des Abnahmeblockers, nicht Testabschwächung). 8 neue Tests, **1618 insgesamt** (MonitorKit 366), alle ohne gerenderte Ansicht, ohne Gerät und ohne Scanner. Drei Gegenproben: Fächeranker auf alte Apex-Formel zurückgesetzt bricht **5** Assertions exakt mit den Review-Zahlen, `isVisible` auf alte 16er-Abtastung zurückgesetzt bricht **3** Tests, `clampedToVisibleEdge` auf alte radiale Klammerung zurückgesetzt bricht `testNoNonLinearFormulaExistsInTheDrawingPath` exakt mit der erwarteten Meldung. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen:** weiterhin kein Gerät im Zuschnitt, ausschließlich rechnerisch belegt; Verschieben/Rahmenzoom und die Trackpad-/Pinch-Randfälle unverändert wie in SICK-032b2b/b2c dokumentiert.
- **Alle Scanfield-Gesten sind an die sichtbare Canvasgrenze gebunden** (SICK-032b2c-K2, Korrekturauftrag zur Supervisor-Prüfung von SICK-032b2c-K1; **kein Scanner, kein Port, kein Commissioning, kein B0-Pfad, kein Learn, kein Synth/Audio/AU/MIDI, keine neue Bedienfunktion, keine Änderung der Zonenfachlogik**; die K1-Zeichen-/Sichtbarkeitskorrekturen bleiben unverändert erhalten). **Restblocker:** K1 klippte Messkurve, Fächerkontur, Zonen und Griffe korrekt an `canvasRect`, aber die Ereignisebene, der Rahmenzoom und die Zustandswege für Zoom/Pan benutzten weiterhin die gesamte `GeometryReader`-Fläche einschließlich unsichtbarer Letterbox-Ränder — `worldPoint(forScreenPoint:)` (eine ungeklammerte affine Umkehrung) wurde direkt von Zeigerzoom/Scroll/Pinch, Pan-Beginn/-Fortsetzung und beiden Ecken des Rahmenzooms verwendet (belegt an `800 × 600`: Bildschirm `x = 0` lieferte Welt-`0,033333…` statt Canvasrand-`0,1`, Zoomfaktor `2` landete bei `centerX = 0,166666…` statt `0,2`). **Die Korrektur:** zwei neue Methoden `canvasClampedScreenPoint(_:)`/`boundedWorldPoint(forScreenPoint:)` als **eine** benannte Bedienumkehrung (klammert zuerst achsenweise auf `canvasRect`, bildet danach über die unveränderte `worldPoint(forScreenPoint:)` in die kanonische Welt ab); `fieldCoordinate(forScreenPoint:)` ist darauf umgestellt statt ihrer eigenen, zweiten Weltklammerung (`clampedToVisibleEdge`, entfernt) — dadurch sind Auswahl und alle vier Zonenbearbeitungsarten automatisch mitgeschlossen, ohne `ZoneGeometryReducer.swift`/`ZoneHandleGeometry.swift` anzufassen. Vier produktive Gestenwege in `ScanFieldViewState` (`zoomAtPointer`, `beginDrag`, `endDrag`s Rahmenzoom-Zweig, `applyPan`) sowie `rubberBandRect` (Property → Methode) sind entsprechend umgestellt: ein Zug, der den Canvasrand verlässt, stoppt dort funktional, ein Pan vollständig im selben Letterbox-Rand bewegt nichts, der sichtbare Gummirahmen verlässt `canvasRect` nie. 12 neue Tests, **1630 insgesamt** (MonitorKit 378), alle ohne gerenderte Ansicht, ohne Gerät und ohne Scanner. Zwei Gegenproben: alle vier produktiven Aufrufstellen auf die ungeklammerte Umkehrung zurückgesetzt bricht **5** Tests (Zoom/Pan/Rahmen), `fieldCoordinate(forScreenPoint:)` zurückgesetzt bricht **3** Tests (Auswahl/Zonenbearbeitung). Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen:** weiterhin kein Gerät im Zuschnitt, ausschließlich rechnerisch belegt; Verschieben/Rahmenzoom und die Trackpad-/Pinch-Randfälle unverändert wie in SICK-032b2b/b2c dokumentiert.
- **Vorzonaler Learn-Entwurf für eine neue Zone** (SICK-032c3a; **kein Scanner, kein Port, kein TX, kein Commissioning, keine reale Messung, keine neue Lernheuristik, kein Synth/Audio/AU/MIDI, keine Persistenz, keine SwiftUI-Komposition, kein Git, keine laufende Owner-App**). Eine neue Zone entsteht nicht mehr sofort mit erfundenen Grenzen (`NewZoneDefaults`, `1000...4000`, **ersatzlos gelöscht**), sondern als eigener, `Zone`-loser `LearnDraft`, der den bestehenden `ZoneLearningAccumulator` (SICK-030c/030c1) kapselt. `MonitorPerformanceCoordinator.addZone(role:)` startet jetzt ausschließlich einen Entwurf; erst `applyLearnDraftCandidate()` schreibt einen validen Kandidaten über die bestehende `Zone`-Validierung als neue, ausgewählte, **weiterhin ausgeschaltete** Zone. Neuer, robuster relevanter Rohwertbereich `ScanFieldFocusArea` (Median/MAD-basierte Ausreißererkennung, getrennt von der bestehenden `ScanFieldFit`): Ein einzelner ferner, aber gültiger Ausreißer zieht den Bereich nachweislich nicht auf (Gegenprobe gegen `ScanFieldFit` auf identischen Daten). Neuer, eigenständiger Fokus-Reducer `LearnFocusState`: höchstens ein automatischer Fokus je Entwurf, manuelle Navigation sperrt unwiderruflich, „Einpassen" wirkt immer und sperrt zusätzlich — echte, revert-basierte Gegenprobe (Sperrsetzung entfernt bricht exakt 2 Tests, danach byteidentisch wiederhergestellt). Neue Integrationsgrenze `LearnDraftPresentation` (Erweiterung, keine Kopie von `ZoneLearningPresentation`) für die SICK-032c3b-Oberfläche. Verbindungsverlust beendet einen sammelnden Entwurf mit `.disconnected` über denselben Zwei-Haken-Mechanismus wie beim zonengebundenen Lernen (SICK-032c2a); ein bereits gefallenes Ergebnis bleibt unangetastet. 99 neue Tests netto (16 `LearnFocusStateTests`, 22 `LearnDraftTests`, 14 `ScanFieldFocusAreaTests`, 12 `CoordinatorLearnDraftTests` am produktiven Koordinatorweg mit echter `ScanSession`; minus 1 entfernter `NewZoneDefaults`-Test), **1693 insgesamt** (MonitorKit 430, PerformanceSession 164). Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen:** keine SwiftUI-Anbindung (folgt in SICK-032c3b), kein sichtbarer Bild-/Bediennachweis, die Startwerte der robusten Ausreißerregel sind an SICK-012 orientiert und keine Gerätewahrheit.
- **Vier Abnahmeblocker von SICK-032c3a geschlossen** (SICK-032c3a-K1, Korrekturauftrag zur Supervisor-Prüfung von SICK-032c3a; `.agent_handoff/review-sick-032c3a.md` / `.agent_handoff/task-sick-032c3a-k1.md`; **kein Scanner, kein Port, kein TX, kein Commissioning, keine reale Messung, keine neue Lernheuristik, kein Synth/Audio/AU/MIDI, keine Persistenz, keine SwiftUI-Komposition, kein Git, keine laufende Owner-App**). (1) `ScanFieldFocusArea` fällt bei `MAD == 0` auf die mittlere absolute Abweichung zurück statt pauschal auf `.infinity` — ein einzelner ferner, aber gültiger Ausreißer bleibt auch bei mehrheitlich konstanten Stichproben ausgeschlossen (belegt am Fall `89×100 + 6000`). (2) `ZoneLearningSession` und `LearnDraft` schließen sich **projektweit gegenseitig aus** — beide teilten sich denselben Profilstrom und konnten vorher gleichzeitig sammeln; `armLearn`/`startLearnDraft` prüfen jetzt beide Richtungen mit benannten, in beiden Präsentationsschichten übersetzten Sperrgründen, ohne den jeweils laufenden Vorgang anzufassen. (3) Der Learn-Fokus liest jetzt eine eigene, bei **jedem** tatsächlichen Verbindungsende geleerte Profilkopie (`MonitorPerformanceCoordinator.currentSessionProfileBatch`) statt des für Diagnosezwecke bewusst stehenbleibenden `session.state.lastProfile` — ein frischer Entwurf zeigt nach unerwartetem Stromende keinen veralteten Fokusbereich mehr. (4) Fokusentscheidung und tatsächlich berechneter Bereich sind jetzt atomar gekoppelt (`resolveLearnDraftFocus` ersetzt den alten `applyLearnDraftFocusInput`) — ein fehlgeschlagenes „Einpassen" ohne Profil sperrt und verbraucht nichts, eine automatische Anfrage ohne berechenbares Ergebnis verbraucht den einmaligen Zustand ebenfalls nicht; `LearnFocusState` selbst blieb dabei unverändert. Vier echte, revert-basierte Gegenproben (je Sicherung/Rücknahme/bestätigter Fehlschlag/byteidentische Wiederherstellung). 19 neue Tests netto, **1712 insgesamt** (MonitorKit 437, PerformanceSession 176). Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen, unverändert seit SICK-032c3a:** keine SwiftUI-Anbindung (SICK-032c3b bleibt bis zur Supervisor-Abnahme dieser Runde gesperrt), kein sichtbarer Bild-/Bediennachweis, die Startwerte der robusten Ausreißerregel sind an SICK-012 orientiert und keine Gerätewahrheit.
- **Das Learn-Fokusprofil endet jetzt atomar mit der logischen Messsitzung** (SICK-032c3a-K2, Korrekturauftrag zur Supervisor-Prüfung von SICK-032c3a-K1; `.agent_handoff/review-sick-032c3a-k1.md` / `.agent_handoff/task-sick-032c3a-k2.md`; **kein Scanner, kein Port, kein TX, kein Commissioning, keine reale Messung, keine neue Lernheuristik, kein Synth/Audio/AU/MIDI, keine Persistenz, keine SwiftUI-Komposition, kein Git, keine laufende Owner-App**). **Abnahmeblocker:** `disconnect()` beendete einen sammelnden Lernvorgang bereits sofort, invalidierte `currentSessionProfileBatch` (SICK-032c3a-K1) aber erst später in `notePortReleased()` — nach dem tatsächlichen `close(2)`. Im Zeitfenster dazwischen konnte ein neu gestarteter Entwurf noch auf das Profil der bereits logisch beendeten Sitzung fokussieren. Behoben durch eine Zeile: `disconnect()` setzt `currentSessionProfileBatch = nil` jetzt sofort, innerhalb desselben, bereits bestehenden `if session.isPortHeld`-Blocks, **vor** dem asynchronen `session.disconnect()`; `notePortReleased()` bleibt unverändert als idempotenter Auffangweg für jedes andere Verbindungsende. Portbesitz und `isAwaitingPortRelease` unverändert; ein `disconnect()` ohne gehaltenen Port lässt einen nur armierten Draft weiterhin unangetastet. Zusätzlich die in K1 fehlende Nachweislücke geschlossen: ein aktuelles Profil mit ausschließlich unbrauchbaren Werten (`.noUsableMeasurement`) verbraucht den automatischen Erstfokus nicht, ein späteres brauchbares Profil derselben Sitzung fokussiert danach automatisch genau einmal. Das Zeitfenster wurde über einen neuen, default-erhaltenden `closeDelaySeconds`-Parameter am `FakeSerialPortFileDescriptor` (`PerformanceSessionTestSupport.swift`, dasselbe Muster wie in `Fakes.swift` seit SICK-030a) zuverlässig offengehalten statt zeitgeraten. 3 neue Tests, **1715 insgesamt** (PerformanceSession 179). Eine echte, revert-basierte Gegenprobe: die eine neue Zeile entfernt bricht den neuen Disconnect-Test mit exakt **sechs** Einzelfehlern, genau dem Review-Ablauf entsprechend; restauriert, byteidentisch bestätigt. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen, unverändert seit SICK-032c3a:** keine SwiftUI-Anbindung (SICK-032c3b bleibt bis zur Supervisor-Abnahme dieser Runde gesperrt), kein sichtbarer Bild-/Bediennachweis, die Startwerte der robusten Ausreißerregel sind an SICK-012 orientiert und keine Gerätewahrheit.
- **Der vorzonale Learn-Entwurf ist jetzt sichtbar im Messfeld** (SICK-032c3b; `.agent_handoff/task-sick-032c3b.md`; **kein Scanner, kein Port, kein TX, kein Commissioning, keine reale Messung, keine neue Lernheuristik, kein Synth/Audio/AU/MIDI, keine Persistenz, kein allgemeiner UI-Umbau, kein Git, keine laufende Owner-App**). „+ Zone" startet weiterhin nur den `LearnDraft` (SICK-032c3a) — eine neue, nichtmodale `LearnDraftCardView` zeigt ihn direkt im Messfeld: ehrliches „Warte auf Messwerte" ohne Balken/Uhr/Timeout, echte Fortschrittszahlen während der Bewegungssammlung, und bei einem Kandidaten eine gestrichelte Vorschau-Fläche, textlich zusätzlich als „Vorschau — noch nicht übernommen" beschriftet (Farbe allein reicht nicht). **Eine Geometrie für Vorschau und echte Zonen:** neue `ZoneSectorGeometryFactory.sector(for:in:)` (`Sources/SickPLSMonitorKit/ZoneSectorGeometry.swift`) ist die **eine** Quelle für Sichtbarkeit und Sektorform; `ZoneOverlayView` und die neue `LearnCandidatePreviewView` teilen sich zusätzlich denselben `LearnZonePathBuilder.path(for:)`-Wegbauer — numerisch (`ZoneSectorGeometryTests`, Kongruenz unter Zoom/Pan) **und** strukturell (Quelltextprüfung, dass beide Ansichten wirklich denselben Weg benutzen) belegt; die Vorschau ist `.allowsHitTesting(false)`, nie auswählbar, nie in `editorState.zones`. **Atomare Fokusintegration:** die Oberfläche liest ausschließlich `resolveLearnDraftFocus(_:within:)` (SICK-032c3a-K1/K2, unverändert) — nie den rohen Fokuszustand direkt; `.focus(result)` setzt den Ausschnitt über eine neue, benannte `ScanFieldViewState.applyLearnFocusResult(_:)`, eine abgelehnte automatische oder explizite Anfrage ändert nie den Ausschnitt. **Manuelle Navigation sperrt, Ablehnung nicht:** Alle viewport-verändernden `ScanFieldViewState`-Methoden geben jetzt `@discardResult Bool` zurück (echte Netto-Bewegung, per Vorher-/Nachher-Vergleich, nicht bloß „Methode aufgerufen") — nur eine tatsächlich wirksame Lupentaste/„Gesamtansicht"/Scrollrad/Pinch/Verschieben/Rahmenzoom meldet `.manualNavigation`; reine Werkzeugwahl, Zonenauswahl/-bearbeitung und abgelehnte/entartete/wirkungslose Gesten sperren **nicht**. Dabei ein echter Bug im bestehenden `.pan`-Zweig gefunden und behoben: er meldete bisher `.viewportChanged` bei **jeder** Drag-Fortsetzung statt nur bei echter Gesamtverschiebung seit Gestenbeginn. Textlich korrigierter „+ Zone"-Hilfetext beschreibt jetzt ehrlich den Entwurfs-/späteren-Übernahme-Ablauf. Neue `LearnDraftPresentationExhaustiveTests` (9 Tests) belegen für **jede** erreichbare `ZoneLearningPhase` (Warten/Grundprofil/Bewegung/Kandidat, alle 5 Verweigerungs-, 5 Abbruch- und 2 Fehlschlagsgründe) exakt die richtige Knopfverfügbarkeit. `PerformanceSessionBoundaryTests` um zwei neue Grenztests erweitert: kein zweiter Profileingang, kein direkter App-Zugriff auf `LearnFocusState`/`.applyFocusInput`, keine eigene Viewport-/Fokusrechnung in SwiftUI (`ScanPlaneViewport(`/`.build(`/`.zoomed(`/`.zoomedToRectangle(`/`.panned(`/`ScanFieldFocusArea.area(` verboten). Zwei echte, revert-basierte Gegenproben: die `.pan`-Korrektur zurückgesetzt bricht 2 Tests, `ZoneOverlayView.sectorPath` auf eine Ersatzgeometrie umgeleitet bricht `testZoneAreasUseTheSameLinearGeometry` — beide byteidentisch wiederhergestellt. **Bild-/Bediennachweis** über einen isolierten, nicht ausgelieferten Nachweishelfer (`.agent_handoff/sick-032c3b-render-tool.swift`, temporär als SwiftPM-Ausführungsziel gebaut, danach `Package.swift` byteidentisch zurückgesetzt) — echte Produktionsdateien, kein nachgezeichnetes Abbild, alle 8 erreichbaren Zustände plus eine schmale gestapelte Ansicht über die echte `ZoneEditorState`-API mit synthetischen Profilen erzeugt, dokumentiert in `.agent_handoff/sick-032c3b-visual-proof.md`. 33 neue Tests (17 MonitorKit, 16 PerformanceSession), **1748 insgesamt**. Sauberer `rm -rf .build && swift build` bestätigt den macOS-12-Build (`LC_BUILD_VERSION minos 12.0`). **Ehrlich offen:** native Knopfgrafik (`Button`-Chrome) rendert im bündel-losen Offline-Nachweiswerkzeug als generisches „nicht darstellbar"-Symbol statt echter Schaltflächen (bekannte AppKit-Einschränkung für gebündel-lose Prozesse, vgl. SICK-032a2) — die Knopf**verfügbarkeit** je Zustand ist davon unberührt und separat vollständig durch `LearnDraftPresentationExhaustiveTests` belegt; es wurde weiterhin nie mit echten Profilen gelernt.
- **Notice-Lebensdauer geschlossen, App-basierter UX-Nachweis** (SICK-032c3b-K1, Korrekturauftrag zur Supervisor-Prüfung von SICK-032c3b; `.agent_handoff/review-sick-032c3b.md` / `.agent_handoff/task-sick-032c3b-k1.md`; **kein Scanner, kein Port, kein TX/RX, kein Commissioning, keine reale Messung, keine neue Learn-Heuristik, kein Umbau von Fokus/Geometrie/Übernahmelogik, kein Audio/Synth/AU/MIDI/Persistenz-/allgemeiner Fensterumbau, keine Owner-App, kein Git**). **Abnahmeblocker 1 — Notice ohne Draft:** `learnDraftNotice` war absichtlich vom Draft entkoppelt, hatte aber nur einen sichtbaren Ort (die Draftkarte), der genau in den beiden wichtigsten Lagen fehlte — Verweigerung ohne je existierenden Draft, Erfolgshinweis nach sofort verschwundenem Draft. Neuer reiner Wertetyp `LearnDraftSurface` (`Sources/SickPLSPerformanceSession/LearnDraftSurface.swift`): `cardNotice`/`hostedNotice` prüfen dieselbe gespeicherte `presentation`/`notice`-Kombination und schließen sich strukturell aus — kein lokaler Fachzustand, kein Timer, keine zweite Notice-Wahrheit. `ScanFieldView` liest ausschließlich `coordinator.learnDraftSurface`; existiert ein Draft, erscheint der Hinweis in der Karte, sonst in der neuen `LearnDraftNoticeBarView` im Messfeldbereich — nie doppelt, nie verschwunden. Belegt über 6 reine `LearnDraftSurfaceTests` plus 4 neue `CoordinatorLearnDraftTests` am produktiven Weg (beide Lebensdauerfälle, Duplikatfreiheit bei bestehendem Draft, erhaltene Lösch-/Ersetzungssemantik) plus 1 neuer Grenztest (`PerformanceSessionBoundaryTests`: kein direkter `coordinator.learnDraftNotice`-Zugriff im App-Ziel). Echte, revert-basierte Gegenprobe: `hostedNotice` auf „nur mit Draft" zurückgeleitet bricht 4 Tests, danach byteidentisch wiederhergestellt. **Abnahmeblocker 2 — Bildnachweis:** Der bündellose `ImageRenderer`-Nachweis (SICK-032c3b) rendert native `Button`s als generisches Verbotssymbol und baute die schmale Ansicht von Hand in falscher Reihenfolge (Feld vor Karte) nach. Ersetzt durch eine isolierte, nicht ausgelieferte `.app`-Instanz (eigener Bundle-Identifier `de.sick.pls.k1proof.isolated`, eigener Fenstertitel), die per `NSView.cacheDisplay(in:to:)` den echten Bildschirminhalt eines echten AppKit-Fensters fotografiert — ohne Bildschirmaufnahme-Berechtigung, mit echten nativen Buttons statt Platzhaltern. Die Ansicht besteht aus den **echten, unveränderten** Produktionsdateien (`Sources/SickPLSMonitor/*.swift`, per Dateisystem-Symlink temporär in ein eigenes SwiftPM-Ziel `SICK032c3bK1Harness` eingehängt, nach dem Lauf vollständig entfernt, `Package.swift` byteidentisch zurückgesetzt und per `diff` bestätigt) und wird von einem Harness getrieben, der den echten `MonitorPerformanceCoordinator` ausschließlich über öffentliche API antreibt (`ScanSession`/`ThereminPerformanceController`/`CommissioningControlModel` mit injizierten Fakes über öffentliche Protokolle — kein `@testable import`, keine reale Scanner-/Port-/Audio-/Commissioning-Interaktion). Alle 10 geforderten Zustände (Warten, Grundprofil, Bewegung, Vorschlag, Verweigerung, Abbruch, Verbindungsverlust, Übernahme, beide Blocker-1-Lebensdauerfälle, schmale/gestapelte Produktanordnung bei 760pt) liegen als Bilder vor, einzeln eingesehen und bestätigt (native Buttons, korrekte aktiv/deaktiviert-Zustände, erkennbare Bedienfolge); Details in `.agent_handoff/sick-032c3b-k1-visual-proof.md`, die alten SICK-032c3b-Bilder/-Dokument mit Warnhinweis versehen statt gelöscht. 11 neue Tests, **1759 insgesamt** (PerformanceSession 206). Vollständige Testsuite, isolierter strenger Concurrency-Build (`-strict-concurrency=complete`, Exit 0, nur bereits bekannte Altwarnungen in `AdvanceTicker.swift`/`CommissioningDispatching.swift`/`ScanFieldPointerEvents.swift`) und macOS-12-Deploymentnachweis (`LC_BUILD_VERSION minos 12.0`) bleiben grün. **Ehrlich offen:** ein bekanntes `cacheDisplay`-Artefakt lässt in zwei der zehn Bilder Restflächen unterhalb der zuletzt gezeichneten Zeile schwarz statt weiß — Text/Buttons bleiben davon unberührt lesbar; es wurde weiterhin nie mit echten Scanner-Profilen gelernt.
- **Vollständig lesbarer, fensterbasierter UX-Nachweis** (SICK-032c3b-K2, Korrekturauftrag zur Supervisor-Prüfung von SICK-032c3b-K1; `.agent_handoff/review-sick-032c3b-k1.md` / `.agent_handoff/task-sick-032c3b-k2.md`; **kein Scanner, kein Port, kein TX/RX, kein Commissioning, kein Audioausgang, keine Owner-App, kein Git; keine Änderung an `LearnDraftSurface`, Notice-Semantik, Learn-Heuristik, Fokus, Geometrie, Navigationssperre oder Übernahmelogik**). **Der K1-Befund war berechtigt und ging über die dort genannten zwei Restflächen hinaus:** `NSView.cacheDisplay(in:to:)` fordert eine klassische `-drawRect:`-Neuzeichnung an; SwiftUI-Inhalt setzt seinen Ebeneninhalt auf macOS aber direkt über Core-Animation-Kompositing, nicht über `-drawRect:` — dadurch blieb praktisch jeder SwiftUI-eigene Bildteil (Text, Formen, Flächen) auf dem schwarzen Rohzustand des Zielpuffers stehen, sichtbar blieb nur klassisch zeichnendes natives Button-Chrome. **Die Korrektur ändert ausschließlich die Erfassungstechnik:** `CALayer.render(in:)` auf dem tatsächlich komponierten Ebenenbaum des Fensterrahmens (Titelleiste **und** Inhalt gemeinsam) statt einer Neuzeichnungsanforderung — das funktioniert unabhängig davon, ob eine View klassisch oder über Core Animation zeichnet. Der Zielkontext wird **ohne Alpha-Kanal** angelegt (`CGImageAlphaInfo.noneSkipLast`, weiß vorgefüllt), womit „kein Alpha-Kanal" strukturell garantiert statt nur behauptet ist; eine im Werkzeug eingebaute Stichprobenprüfung (120×120-Raster, Anteil naheschwarzer Pixel) bestätigt für alle zwölf Bilder `hasAlpha=false` und einen schwarzen Anteil von `0,000`–`0,001` (das eine `0,001` bei Bild 10c ist der reale schwarze Scrollbar-Griff, kein Erfassungsfehler) — sowohl am In-Memory-Bild als auch an der zurückgelesenen PNG-Datei geprüft. Das Fenster wird dafür vorher **wirklich auf den Bildschirm geholt** (`makeKeyAndOrderFront` + `activate`, erzwungene helle Erscheinung), weil Core Animation bestimmte Ebenen an einem nie sichtbar gemachten Fenster nicht komponiert. **Ein realer, während des Laufs gefundener und sofort korrigierter Fehlschlag:** Ein erstes Fenster so hoch wie der gemessene Dokumentinhalt zu machen (2412pt Zielhöhe 2492pt) scheiterte, weil macOS `NSWindow.setFrame(...)` eines tatsächlich auf dem Bildschirm befindlichen Fensters stillschweigend auf die physische Bildschirmhöhe klemmt (real beobachtet: sichtbarer Inhalt blieb bei 1056pt) — korrigiert durch die im Auftrag selbst vorgesehene Ausweichlösung, eine kurze, geordnete Bildserie desselben, bildschirmgroßen Fensters an drei realen Bildlaufpositionen der einen `NSScrollView` (per Ansichtsbaum-Introspektion gefunden, `scrollView.contentView.scroll(to:)`), oben/Mitte/unten — keine Handmontage. Derselbe Harness-Aufbau wie K1 (echte, per Dateisystem-Symlink eingehängte Produktionsdateien aus `Sources/SickPLSMonitor/`, echter `MonitorPerformanceCoordinator` über ausschließlich öffentliche API, kein `@testable import`), neuer Bundle-Identifier `de.sick.pls.k2proof.isolated` und neuer Fenstertitel „SICK-032c3b-K2 Nachweis (isoliert, nicht ausgeliefert)" — auf **jedem** der zwölf Bilder sichtbar, nicht nur auf einem. Alle zwölf geforderten Zustände (Warten, Grundprofil, Bewegung, Vorschlag inkl. wörtlichem Text „Vorschau — noch nicht übernommen" und Kandidatengrenzen, Verweigerung, Abbruch, Verbindungsverlust, Übernahme inkl. neuer ausgeschalteter Zone und Erfolgshinweis ohne Draftkarte, Verweigerung ohne Draft inkl. negativem Fallback-Hinweis, plus die dreiteilige schmale Bildlaufserie Messfeld→Anschluss→Zonen) einzeln in Originalauflösung eingesehen und gegen den jeweils erwarteten Text/Zustand geprüft — Details, vollständige Bildliste mit Prüfpunkten je Bild und Log-Auszug in `.agent_handoff/sick-032c3b-k2-visual-proof.md`. Die zehn K1-PNGs wurden auf `*.DISCARDED-see-k2.png` umbenannt (nicht gelöscht), `.agent_handoff/sick-032c3b-k1-visual-proof.md` trägt jetzt einen Warnhinweis auf K2. **Keine Teständerung** (reine Nachweistechnik-Korrektur außerhalb des Pakets) — **1759 Tests unverändert** (Core 73, MacTransport 32, DiagnosticCLI 51, ActiveControl 36, ControlCore 113, MonitorKit 454, Commissioning 156, CommissioningControl 94, ThereminControl 77, ThereminAudioControl 74, ThereminRuntime 66, ThereminPerformance 91, PerformanceSession 206, SynthDSP 39, SynthBridge 29, SynthAudio 168), 0 Fehlschläge. Vollständige Testsuite, isolierter strenger Concurrency-Build (`-strict-concurrency=complete`, Exit 0, nur dieselben drei bereits bekannten Altwarnungen) und macOS-12-Deploymentnachweis (`LC_BUILD_VERSION minos 12.0`) bleiben grün. Bereinigung vollständig bestätigt: temporäres Ziel, alle 19 Symlinks, `Package.swift` (`diff` byteidentisch), App-Bundle — alles entfernt. **Ehrlich offen:** weiterhin nie mit echten Scanner-Profilen gelernt; der Nachweis prüft die Darstellung, nicht reale Timing-Eigenschaften eines echten Scanners.
- **Fehlendes Grundprofilbild ersetzt** (SICK-032c3b-K3, Korrekturauftrag zur Supervisor-Prüfung von SICK-032c3b-K2; `.agent_handoff/review-sick-032c3b-k2.md` / `.agent_handoff/task-sick-032c3b-k3.md`; **kein Scanner, kein Port, kein TX/RX, kein Commissioning, kein Audioausgang, keine Owner-App, kein Git; keine Änderung an `LearnDraftSurface`, Notice-Semantik, Learn-Heuristik, Fokus, Geometrie, Navigationssperre, Übernahmelogik oder den elf übrigen bereits akzeptierten K2-Aufnahmen**). **Der K2-Befund war berechtigt:** `sick-032c3b-k2-02-baseline.png` war als „Grundprofil" bezeichnet, zeigte aber `.collectingMovement` — Schritttitel „Hand im gewünschten Bereich bewegen", Fortschritt „20 Profile · 0 Messpunkte verändert · 0 davon stabil". **Ursache:** Der K2-Harness speiste für dieses Bild zwanzig ruhige Profile ein; `ZoneLearningConfiguration.default.baselineProfileCount` ist **5** — nach fünf identischen Profilen schaltet `ZoneLearningAccumulator` strukturell von `.collectingBaseline` auf `.collectingMovement` um, unabhängig davon, ob sich danach etwas bewegt. Der sichtbare Grundprofil-Fortschritt fehlte im Bildsatz vollständig. **Korrektur — weniger einspeisen, nicht die Darstellung ändern:** Ein eigener, isolierter Nachweislauf (`SICK032c3bK3Harness`, Bundle-Identifier `de.sick.pls.k3proof.isolated`) speist **exakt ein** echtes, ruhiges B0-Profil ein; das Read-Script selbst verhindert, dass vor der Aufnahme ein zweites Profil konsumiert wird — auf das eine Frame folgen ausschließlich `.timeout`-Einträge, fünfzehn führende `.timeout`-Einträge geben dem Hauptthread Zeit, `startLearnDraft(role:)` vor dem Eintreffen des Frames aufzurufen. Ergebnis, real erreicht: `phase == .collectingBaseline(profilesSeen: 1, required: 5)`, angezeigt als **„Grundprofil 1 von 5"** — genau der geforderte Bereich 1–4, beim ersten Versuch gelungen. Derselbe akzeptierte, opake `CALayer.render(in:)`-Erfassungsweg wie K2, dieselbe Symlink-Technik (19 echte Produktionsdateien, ohne `SickPLSMonitorApp.swift`), derselbe Aufbau über ausschließlich öffentliche API (kein `@testable import`) — echte `ScanSession`, echter `MonitorPerformanceCoordinator`, echter `ThereminPerformanceController` über nie startenden `FakeAudioHost`, `CommissioningControlModel` über sofort werfenden `RefusingRunProvider`. Das neue Bild ersetzt **ausschließlich** `sick-032c3b-k2-02-baseline.png` (3000×2112px statt 3000×2056px — geringfügig anderer Fensterinhalt im eigenständigen Lauf, keine andere Bedeutung); alle elf übrigen K2-Bilder unverändert. `.agent_handoff/sick-032c3b-k2-visual-proof.md` in-place korrigiert (Tabellenzeile, neuer Abschnitt „Korrektur SICK-032c3b-K3") — **kein separates K3-Dokument**, K2 plus das korrigierte Bild 02 bleibt der allein maßgebliche Nachweis, wie vom Auftrag verlangt. **Keine Teständerung** — **1759 Tests unverändert** (Core 73, MacTransport 32, DiagnosticCLI 51, ActiveControl 36, ControlCore 113, MonitorKit 454, Commissioning 156, CommissioningControl 94, ThereminControl 77, ThereminAudioControl 74, ThereminRuntime 66, ThereminPerformance 91, PerformanceSession 206, SynthDSP 39, SynthBridge 29, SynthAudio 168), 0 Fehlschläge. Vollständige Testsuite, isolierter strenger Concurrency-Build (`-strict-concurrency=complete`, Exit 0, nur dieselben drei bereits bekannten Altwarnungen) und macOS-12-Deploymentnachweis (`LC_BUILD_VERSION minos 12.0`) bleiben grün. Bereinigung vollständig bestätigt: temporäres Ziel, alle 19 Symlinks, `Package.swift` (`diff` byteidentisch), App-Bundle — alles entfernt. **Ehrlich offen:** weiterhin nie mit echten Scanner-Profilen gelernt (auch das eine eingespeiste Profil ist synthetisch); der Nachweis prüft die Darstellung, nicht reale Timing-Eigenschaften eines echten Scanners. SICK-0330r bleibt bis zur Abnahme dieser Runde gesperrt.

## 24.09.2026 — Live-GUI, Spiegelung und AU-Fenster stabilisiert

- Das kartesische Messfeld lässt sich horizontal spiegeln. Sichtbare
  Rastergrenzen und Zellrechtecke werden dabei richtungsunabhängig
  normalisiert; der zuvor reproduzierbare Canvas-Absturz ist behoben.
- Jede räumliche Ebene besitzt genau einen Ausgangspfad. MIDI und
  AU-Instrument sind getrennte Notenziele; MIDI-CC und AU-Parameter werden
  nicht gemeinsam ausgesendet.
- AU-Instrumente und AU-Effekte öffnen die vom Plugin gelieferte native
  Oberfläche in einem eigenen, nichtmodalen Fenster.
- Realnachweis am PLS: RX bei 500.000 Baud, 90 Punkte und stabil etwa 25 Hz;
  Spiegeln an/aus bei weiter steigender Framezahl. `DLSMusicDevice` wurde
  geladen, seine native GUI geöffnet und der Audio-Graph gestartet. Keine
  Gerätekonfiguration und kein TX in diesem Test.
- Frisches App-Bundle gebaut; vollständige Swift-Testsuite ohne Fehler.
