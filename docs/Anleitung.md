# Bedienungsanleitung – Planarium

## Inhaltsverzeichnis

1. [Was ist Planarium?](#was-ist-planarium)
2. [Scanner verbinden](#scanner-verbinden)
3. [Die Arbeitsfläche](#die-arbeitsflaeche)
4. [Ebenen und Zellen](#ebenen-und-zellen)
5. [Klänge zuweisen](#klaenge-zuweisen)
6. [Szenen und Umschaltzellen](#szenen-und-umschaltzellen)
7. [Presets](#presets)
8. [Kanalzug, Audio Units und MIDI](#kanalzug-audio-units-und-midi)
9. [Erkennung und Raumkontur](#erkennung-und-raumkontur)
10. [Gerätefelder und „Scanner flag bits"](#geraetefelder-und-scanner-flag-bits)
11. [PANIC und wann Töne enden](#panic-und-wann-toene-enden)
12. [Tastenkürzel](#tastenkuerzel)

## Was ist Planarium?

Planarium macht einen abgekündigten Laserscanner zu einem räumlichen Instrument.
Du bewegst deine Hand im Raum, und die App spielt die Zellen, die du gemalt hast.
Nur echte Messpunkte aus dem Scanner öffnen Töne und Gates.
Die Scanner-Felder sind in diesem Projekt keine Sicherheitsfunktion.
Lesen oder Schreiben von Feldern macht keine Aussage über eine Sicherheitsfunktion oder Zertifizierung.

## Scanner verbinden

Wähle einen Port und klicke auf „Connect".
Unter „Measurement" ist „Full scan 361" die Standardwahl; „MMK 90" bleibt wählbar und Rückfall.
Die Wahl wird auf diesem Mac gemerkt, unabhängig von Presets.
Beim Umschalten werden klingende Ausgänge gelöst, der Datenstrom gestoppt und die neue Betriebsart angefordert.
Die Punktzahl des neuen Stroms muss zur gewählten Betriebsart passen.
Bei einem Fehler wird ein Rückfall auf MMK versucht und das Ergebnis angezeigt.
„Ready" zeigt die gemessenen Punkte und die Rate.

## Die Arbeitsfläche

Die Statuszeile oben zeigt Eingang, Rate, Preset und Szene.
Schalter in der Statuszeile blenden die Bereiche ein und aus.
Mit „View" oder ⌘1–⌘4 zeigst du „Setup", „Layers", „Cell" und „Channel strip".
In schmalen Fenstern erscheinen die Bereiche als Reiter.
„Perform" (⌘⇧P) blendet die Inspektoren aus und sperrt Malen, Verschieben und Auswahl.
Zoomen und Verschieben der Ansicht bleiben verfügbar.
„Edit" stellt dein vorheriges Layout wieder her.
Bei Verbindungsverlust wird die Statuszeile rot und Töne werden gelöst.
Vollbild ist unabhängig vom Performance-Modus.

## Ebenen und Zellen

Male Zellen in einer Ebene und wähle „Output" und „Controls" im Inspector.
Das Feld verwendet polare Zellen in Zentimetern.
Zoom und Raster sind Hilfsmittel zum Bearbeiten; ein Rasterwechsel behält bestehende Zellen.
Ziehe von einer markierten Zelle, um die aktuelle Auswahl zu verschieben.
Pfeiltasten verschieben die Auswahl einen Schritt: vor/zurück = Abstand, seitlich = Drehen.
Mit ⇧ oder ⌘ wählst du in der Ebenenliste mehrere Ebenen; sind mindestens zwei gewählt (oder „Select all layers"), verschiebt das Ziehen ganze Ebenen, sonst nur die markierten Zellen.
Beim Loslassen wird ein Undo-Schritt gespeichert; „Escape" bricht die Vorschau ab.
Am Feldrand hält die Auswahl an und ein Hinweis erscheint.
Dupliziere eine Ebene mit ⌘D: gleiche Zellen und Ziele, dieselben Szenen.
Kopiere und füge Ebenen mit ⌘C/⌘V ein; eingefügte Ebenen treten der aktiven Szene bei.

## Klänge zuweisen

Die Zuweisung liegt im Ebenen-Inspector („Layers"), Abschnitte „OUTPUT" und „ASSIGNMENT".
„Output": „No output", „AU instrument" oder „MIDI".
Danach „Controls": „Notes", „AU-Parameter" (nur beschreibbare Parameter des Plug-ins), „CC", „Pitch Bend", „Pressure" (nur MIDI), „All Notes Off".
Bei MIDI wählst du den „MIDI channel".
„Type" für Noten: „Scale", „Random scale" oder „Chord".
„Scale": „Root", Tonumfang „From"/„To", „Scale" = „Chromatic", „Major", „Natural minor", „Major pentatonic", „Minor pentatonic", dazu „Direction".
„Chord": Akkord aus einer Liste oder „Custom"; die Klaviatur darunter zeigt und setzt die Töne, „Octave" mit ‹ ›.
„Transition" (wie Töne ineinander übergehen): „Retrigger", „Legato", „Overlap 35 ms", „Hold till next trigger" (Ton/Akkord bleibt nach dem Verlassen stehen, bis ein neuer Klang auf demselben Ausgabekanal kommt).
„All Notes Off": jede farbige Zelle dieser Ebene löst alle gehaltenen Töne dieses Ausgangs – praktisch als „Stopp-Zelle".
Einzelne Zellen können eigene Werte bekommen; das zeigt und bearbeitet der Zell-Inspector („Cell"): Lage, Ton/Akkord bzw. Wert, Herkunft, „Reset to layer" entfernt die eigenen Werte der Zelle.
Nur gemessene Scanpunkte öffnen Töne und Gates.

## Szenen und Umschaltzellen

Eine Szene speichert, welche Ebenen aktiv sind und welche stumm.
Klicke den Szenennamen über dem Feld, um sie zu aktivieren.
„+" legt eine Szene an; das Kontextmenü benennt, aktualisiert, verschiebt oder löscht sie.
Punkte in der Ebenenliste zeigen die Szenenmitgliedschaft.
Wähle Umschaltzellen und setze das Ziel auf „Next", „Previous" oder eine benannte Szene.
Ohne eigenes Ziel gilt die Ebenenvorgabe.
„Reset to layer" entfernt die eigenen Zellziele.
Eine fehlende Szene löst nichts aus.
Die Verweilzeit gehört zur Ebene; jede Zelle lädt erst nach Verlassen neu.
Ein Szenenwechsel beendet keinen Ton: Töne stumm werdender Ebenen enden beim Verlassen ihrer Zelle.
Stumme Ebenen starten keinen Ton.

## Presets

Ein Preset speichert den kompletten Kanal, Ebenen, Erkennungseinstellungen und Viewport.
Wähle ein Preset aus, um es zu laden; bei ungespeicherten Änderungen erscheint eine Rückfrage.
„Delete" wirkt auf das geladene Preset.
„Import Preset…" (⌘⇧I) fügt eine oder mehrere JSON-Dateien hinzu, ohne das aktuelle Preset zu wechseln.
Konflikte werden als „Name 2" benannt.
„Export Preset…" (⌘⇧E) schreibt das aktuelle Preset als Datei.
Presets tragen optional einen Beschreibungstext; über 1000 Zeichen werden abgelehnt.
Kontur, Ein-/Aus und Toleranz gehören zum Programmlauf und überstehen Presetwechsel; sie werden nie in ein Preset gespeichert.

## Kanalzug, Audio Units und MIDI

Der Kanalzug zeigt das Instrument und die Insert-Zustände.
Der Fader steuert die Ausgangslautstärke; das Meter misst hinter dem Fader in dBFS.
Klicke den roten Indikator, um Überlastung zurückzusetzen.
Wähle ein Instrument oder Insert aus dem Systemkatalog.
Zustände: „Loading", „Loaded", „Bypassed", „Failed".
Jedes Plug-in hat ein eigenes Editor-Fenster.
„Aus" setzt den Bypass; das Plug-in bleibt im Signalweg.
Instrumentwechsel blenden über 10 ms aus und wieder ein.
MIDI ist ein paralleler Ausgang derselben Performance.
Wähle das MIDI-Ziel im Kanalzug.
„Panic" löst Töne auf jedem gebundenen Ausgang; das nächste gültige Profil kann wieder spielen.

## Erkennung und Raumkontur

Der Bereich „Detection" über dem Messfeld ist aufklappbar; die Zeile zeigt die aktuellen Werte.
Einstellungen werden im Preset gespeichert.
Drehregler (ziehen auf/ab, Doppelklick = Standard):
- „Smoothing": Glättung jedes Strahls über die Zeit; „Weight α" (Gewicht der neuesten Messung), „Window" (Anzahl vergangener Scans).
- „Min. gap": radialer Abstand, der Objekte trennt (fehlende Messungen trennen ebenfalls).
- „Minimum points": Mindestzahl Messungen je Objekt.
- „Min. angle": Mindestwinkel zwischen Objekten; innerhalb spielt nur das nächste Objekt; 0 = aus.
- „Representative" und „Offset": welcher Punkt ein Objekt vertritt.
- „Edge margin": Rand innerhalb jeder Zelle gegen Flattern an Grenzen.
- „Confirmation": wie viele Scans eine Zelle bestätigen müssen.
- „Hold margin": hält stetige Werte ruhig.
- „Contour tol.": erlaubter Abstand zu jeder erfassten Wand.

Raumkontur: „Capture room" zeichnet die aktuelle Raumkontur auf („Cancel capture" bricht ab); „Room contour" filtert Rückläufer außerhalb der Kontur.
Passt die Kontur nicht mehr zur Scanner-Einstellung, erscheint ein Hinweis; dann neu erfassen.
Die Raumkontur wird nie in ein Preset gespeichert.
„Show raw scan" zeigt die rohen Messpunkte, „Merge zones" fasst Zonen zusammen.

## Gerätefelder und „Scanner flag bits"

„Device fields" öffnet einen separaten Offline-Editor.
Du zeichnest „Protective field" (bis 4 m, OSSD 1/2) und „Warning field" (bis 50 m, WEAK SIGNAL).
Ziehen wählt Zellen; Option-Ziehen malt; „Fill selection" und „Erase selection" ändern das gewählte Feld.
„Select" oder „Pan" nutzt die üblichen Feldwerkzeuge.
„Semicircle" und „Rectangle" erstellen Referenzformen in Metern.
Wähle 90, 180 oder 360 Segmente; 180 hat kein verifiziertes Format und kann nicht exportiert werden.
„Export contour" schreibt nur Diagnosebytes in eine Datei und zeigt die Differenz zum letzten Export.
„Show device fields" steuert Anzeige und Performance getrennt; Performance erlaubt nur Anzeige.
Diese Felder landen nie in einem Preset, spielen nie und machen keine Sicherheitsaussage.
„Scanner flag bits" färbt Messpunkte nach dem rohen Wert 0…7 und zeigt Zählwerte.
Die Einstellung bleibt lokal und startet ausgeschaltet.

## PANIC und wann Töne enden

Gate, Note-Off und Panic kommen nie aus einer Vorhersage.
Panic, Verbindungsverlust, Stopp, Schlaf und Beendigung lösen aktive Töne.
Wenn Audio vor dem Schlaf lief, startet es nach dem Aufwachen neu; Töne brauchen ein frisches Profil.
„Panic" löst Töne auf jedem gebundenen Ausgang.
Ein Szenenwechsel beendet keinen Ton: Töne enden beim Verlassen der Zelle oder über jeden Löseweg.
Stumme Ebenen starten keinen Ton.

## Tastenkürzel

| Kürzel | Funktion |
|--------|----------|
| ⌘1 | „Setup" anzeigen |
| ⌘2 | „Layers" anzeigen |
| ⌘3 | „Cell" anzeigen |
| ⌘4 | „Channel strip" anzeigen |
| ⌘⇧P | „Perform" ein/aus |
| ⌘D | Ebene duplizieren |
| ⌘C | Ebenen kopieren |
| ⌘V | Ebenen einfügen |
| ⌘⇧I | „Import Preset…" |
| ⌘⇧E | „Export Preset…" |
| Pfeiltasten | Auswahl verschieben |
| Escape | Vorschau abbrechen |
| ⇧ / ⌘ + Klick | Mehrfachauswahl |
| Option + Ziehen | Pinsel (Gerätefelder) |
