# Roadmap

Diese Datei enthält die Ist-Architektur, Produktverträge, Risiken und Evidenz.
Die offene Reihenfolge steht ausschließlich in [END_PRODUCT_ROADMAP.md](END_PRODUCT_ROADMAP.md),
die geltenden Coder-Checks in [CLAUDE.md](CLAUDE.md). Datierte Altpläne sind
Herkunft; sie setzen diese Zuständigkeiten nicht außer Kraft.

## Ist-Architektur und Nachweisstand

**Stand: 18.10.2026. Architekturgrundstand QUALITÄT-E (`3f6db2a`), ergänzt um die Leistungs- und Editoränderungen. Der Abnahmestand steht im [Checkpoint](.agent_handoff/checkpoint.md).**
Die folgenden Links führen zum vorhandenen Produktweg. Implementierung,
automatischer Offline-Nachweis und reale Bestätigung werden getrennt geführt.
Ein gebautes Owner-Bundle oder eine offene Testliste ist keine Bestätigung.

Die Feldhörbarkeit besitzt einen eigenen Gleichheitsschlüssel neben der
Geometrieidentität (`SpatialFieldPlan.audibilityOpacity`). Runtime-Szenen
aktualisieren ihn und den vorbereiteten Labelbesitz, ohne Pfade oder Adjazenz
neu zu bauen; der Dokumentbesitzer publiziert die gespiegelte Szene einmal.
Labelbesitz wird beim Hörbarkeitswechsel aus den vorhandenen Zellen neu
vorbereitet, nicht je Profil. Perform-Namen beobachten nur entdoppelte aktive
Zellen (sowie den diskreten Workspace), der Rückstauhinweis nur seinen Status.
Offline-Nachweise: `SceneAuthoringTests`,
`FieldRenderingContractTests.testRuntimeSceneFieldWideAndNarrow` und
`MacOS12PerformanceTests`; reale Bestätigung dieses Anzeigewegs steht aus.

### Produktpfad und Übergaben

Zusammengesetzt wird der Weg in **PlanariumApplication**:
[PlanariumComposition.swift](Sources/PlanariumApplication/PlanariumComposition.swift);
der App-Einstieg ist **SickPLSMonitor**:
[SickPLSMonitorApp.swift](Sources/SickPLSMonitor/SickPLSMonitorApp.swift).

| Schritt | Zieltarget und Einstiegsdatei | Übergabe |
| --- | --- | --- |
| Scanner vorbereiten | **SickPLSCommissioningControl** · [StandardConnectionControlModel.swift](Sources/SickPLSCommissioningControl/StandardConnectionControlModel.swift), [StandardConnectionRun.swift](Sources/SickPLSCommissioningControl/StandardConnectionRun.swift) | Typisierter TX-Aufbau; echter Portschluss vor RX, kein TX am laufenden RX-Transport |
| Scanner / Simulation einlesen | **PlanariumInput** · [InputOwner.swift](Sources/PlanariumInput/InputOwner.swift), [RXSession.swift](Sources/PlanariumInput/RXSession.swift); **SickPLSSimulationLink** · [SimulationLink.swift](Sources/SickPLSSimulationLink/SimulationLink.swift) | Dieselbe Byte-/Profilgrenze für beide Quellen; Reader → geordnete Profile an Q |
| Profil adaptieren und detektieren | **PlanariumDomain** · [FullScanProfileAdapter.swift](Sources/PlanariumDomain/FullScanProfileAdapter.swift), [SpatialDetectionPipeline.swift](Sources/PlanariumDomain/SpatialDetectionPipeline.swift), [DetectionStagePlan.swift](Sources/PlanariumDomain/DetectionStagePlan.swift) | Auf Q: Raum → Beams → Gruppen → Edge → Winkeltrennung → Core → Time → Repräsentant → Cells; bei Core Off liegt Time vor Beams (historische Semantik). Der Stufenplan ist die ausführbare Quelle |
| Dokument bearbeiten / kompilieren | **PlanariumApplication** · [SpatialInstrumentRuntimeModel.swift](Sources/PlanariumApplication/SpatialInstrumentRuntimeModel.swift), [CanvasDocumentProjection.swift](Sources/PlanariumApplication/CanvasDocumentProjection.swift); **PlanariumDomain** · [InstrumentDocument.swift](Sources/PlanariumDomain/InstrumentDocument.swift) (`InstrumentCompiler`), [CompiledInstrument.swift](Sources/PlanariumDomain/CompiledInstrument.swift) | MainActor validiert vor History und Übernahme; musikalische Änderungen kompilieren, kompatible Metadaten übernehmen den bestehenden Index. Unveränderliches Compilat an Q. Diese Konfiguration steuert die Detektion; Dokumentbearbeitung ist kein Schritt je Profil |
| Zellen / Musik / Lösekanten | **PlanariumRuntime** · [PerformanceRuntime.swift](Sources/PlanariumRuntime/PerformanceRuntime.swift), [OutputRouter.swift](Sources/PlanariumRuntime/OutputRouter.swift); **PlanariumDomain** · [PlayEngine.swift](Sources/PlanariumDomain/PlayEngine.swift) | Serielle Q besitzt PlayState und Ausgangsreihenfolge; [DisplayFrame.swift](Sources/PlanariumRuntime/DisplayFrame.swift) ist die Mailbox zur Anzeige, kein Rückkanal für Dokumentänderungen |
| Audio und Noten-/Control-MIDI | **PlanariumAudio** · [AudioHost.swift](Sources/PlanariumAudio/AudioHost.swift), [AVAudioGraph.swift](Sources/PlanariumAudio/AVAudioGraph.swift); **PlanariumMIDI** · [MIDIPortOwner.swift](Sources/PlanariumMIDI/MIDIPortOwner.swift) | Vorbereitete AU-Schedules/MIDI-Ports an Q; Graph/Editor-Lebensdauer auf Main, Audio-Render auf dem Systemthread |
| Clock senden / empfangen / AU-Hostzeit | **PlanariumMIDI** · [MIDIClockDriver.swift](Sources/PlanariumMIDI/MIDIClockDriver.swift), [MIDIClockReceiver.swift](Sources/PlanariumMIDI/MIDIClockReceiver.swift); **PlanariumRuntime** · [HostMusicalClock.swift](Sources/PlanariumRuntime/HostMusicalClock.swift); **PlanariumHostClockDSP** · [PlanariumHostClockDSP.m](Sources/PlanariumHostClockDSP/PlanariumHostClockDSP.m) | Eigene Clock-Queues, Send/Receive/Off exklusiv; kohärenter nativer Snapshot für den Rendercallback |

### Modulgrenzen und Zustandsbesitz

Die einzige Rollentabelle für direkte/transitive Targetkanten, Testhilfen und
begründete Bestandsausnahmen ist `ManifestBoundaries.rules` in
[TargetBoundaryTests.swift](Tests/PlanariumPresetsTests/TargetBoundaryTests.swift).
Sie prüft den echten `swift package dump-package`-Graphen, einschließlich
unbekannter Produktionsziele und Fehlschlag-Fixtures. Lokaler Prüfbefehl:
`scripts/suite-summary.sh --filter TargetBoundaryTests`; im Produktcode-Rücklauf
läuft derselbe Test durch `scripts/suite-summary.sh` ohne Argumente.
Import-/RX-/TX-Quellprüfungen ergänzen den Paketgraphen.

**Soundkern ohne Scanner (KERN-TRENNUNG, 18.11.2026).** `PlanariumMusicCore` (nur
Foundation) hält die Musik- und Ausgabewerte: Routingziele und Wertprogramme, Szenen,
Farben, Pitch/Tempo/Arpeggiator/AU-Identität, Kanalzüge, `MusicEvent`, die Auswertung
`RoutingEvaluation<Cell>` und den Notenbesitz `NoteLedger<Cell>`. `PlanariumSoundCore`
hält Router, Ports, Notenplanung, Uhren und Arpeggios; Audio Units an ihn bindet
`OutputPortHost`. `PlanariumAudio` und `PlanariumMIDI` hängen nur an diesen beiden.
Jede Eingangsquelle liefert ihre Aktivierungsidentität als `LedgerCell`; die einzige
geometrische Frage des Ledgers (setzt ein Nachbar den gehaltenen Kontakt fort?) beantwortet
die Quelle, der Scanner mit `PolarDeviceLattice` (eine Handbreite, 10 cm). Domain und
Runtime re-exportieren die Kernmodule. Wächter: Rollen `musicCore`/`soundCore` in
`ManifestBoundaries`, Gegenfixture „MIDI über Domain“, Import-Erlaubnisliste
(`DomainBoundaryContractTests.testSoundModulesImportOnlyAllowedModules`). Beleg der
Bitgleichheit: Randpunkte-Replay-Digest modulneutral (Typnamen ohne Modul), alter und neuer
Stand liefern denselben Wert.

**Gamecontroller als zweite Spielquelle (CONTROLLER, 18.11.2026).** Vertrag (Owner 18.11., Konzept
`.agent_handoff/konzept-controller.md` §0):

- Eine App, Scanner und Controller (zuerst PS5 DualSense) gleichzeitig spielbar.
  `PlanariumControllerCore` hängt nur am Musikkern, `PlanariumControllerInput` ist der einzige
  Gerätebesitzer (GameController, nur Empfang; die Lightbar-Farbe ist die einzige Ausgabe ans Pad).
- **Exklusiver Besitz je Ziel und Klasse.** Ziel ist ein AU-Kanalzug (ganzes Instrument) oder
  MIDI-Endpunkt + Kanal; die Summenausgabe und ihr expliziter Endpunkt sind dasselbe Ziel.
  Klasse *Noten* = Note on/off, Anschlag, Halten, Programmwechsel, Bank (CC0/32), Kanalmodus
  (CC120–127); Klasse *Regler* = übrige CCs inkl. Sustain, Pitch Bend, Aftertouch. Der Scanner
  (Instrument) besitzt seine Ziele zuerst; eine Controllerzuweisung auf ein besetztes Ziel/Klasse
  bleibt stumm und wird im Inspector gemeldet (`CompiledControllerLayout.conflicts`).
- **Lösematrix je Quelle.** Controller-Trennung/Neuverbindung löst nur Controllernoten und setzt nur
  eigene Regler zurück (CC64/CC1 → 0, Bend → Mitte, Druck → 0; kein kanalweites All-Notes-Off).
  Scannerverlust, Rückstau und Sitzungswechsel setzen die Reglerkanäle des Controllers nicht zurück
  (`OutputRouter.releaseControllers(sparing:)`). Panic, Benutzerstopp, Schlaf, Beenden und ein neues
  Preset (neue Sitzung) lösen beide Quellen. Nach Panic bleibt ein noch gehaltenes Element stumm, bis
  es losgelassen wurde. Der Router gleicht jeden Port gegen die Vereinigung beider Klangbestände ab.
- **Regler folgen ihrem Element:** solange es gespielt wird, wird gesendet; beim Loslassen kehrt ein
  geschalteter Regler (Konstante) auf 0 zurück (Sustain-Taste: 127 → 0), ein stufenloser auf seinen
  Ruhewert (Trigger oben, Stick/Touch mittig). Sendebelege führen das wirklich benutzte Ziel
  (Endpunkt/Kanalzug), Rücksetzungen gehen genau dorthin.
- **Kein Anschlag ohne neue Kante:** Was in der ersten Meldung einer Verbindung, nach Panic, nach
  einer Audio-Freigabe oder bei einer neuen/geänderten Zuweisung schon gehalten ist, bleibt stumm bis
  zum Loslassen. Ein Layoutwechsel löst entfernte, geänderte oder neu verweigerte Zuweisungen am alten
  Ziel (Noten, Hold, Toggle, Regler), bevor das neue Layout gilt; unveränderte klingen weiter.
- **Audio-Freigaben** (Kanalzug lösen, Audio-Neukonfiguration) erreichen auch den Controller-Ledger;
  seine MIDI-Noten bleiben. Arpeggios gehören der Quelle, der die Noten ihres Kanalzugs gehören;
  scannerlokale Abbrüche (Sitzungsende, Rückstau, Szenenwechsel) lassen Pad-Arpeggios laufen.
- **Kompilierer:** Ziel und Programm müssen dieselbe Nachrichtenart meinen (Noten → Notenziel,
  Programmwechsel → PC-Ziel, Konstante/stufenlos → CC/Bend/Druck/AU-Parameter); Kanal ≤ 16,
  CC ≤ 127, Noten und Anschlag im MIDI-Bereich. Ebenen-/Szenensteuerung und MIDI-Effektparameter sind
  vom Controller aus nicht spielbar und werden abgelehnt. Mehrere Zuweisungen auf derselben Note
  teilen sie physisch (endet mit der letzten).
- **Eingangsgrenze:** Controllermeldungen werden nie ausgedünnt (jede angenommene Kante klingt in
  Reihenfolge). Über `controllerBacklogLimit` (512 Meldungen ≈ 2 s) werden weitere abgewiesen und
  genau eine quellenlokale Überlastfreigabe folgt (wie Panic, nur Controller): nichts klingt weiter,
  Gehaltenes bleibt bis zum Loslassen stumm; ein abgewiesener Druck ist verloren, nie hängend.
- **Besitzwechsel atomar:** Scannerplan und der gegen ihn kompilierte Controllerplan gehen als ein
  Runtime-Befehl (`install(_:controller:)`); alte Pad-Besitzer werden an ihren alten Zielen gelöst,
  bevor irgendetwas des neuen Scannerplans klingt. Audio-Freigaben erfassen auch ausklingende
  Overlap-Töne und setzen die Regler des Controllers am betroffenen Kanalzug zurück.
- **Verpasste Töne nach Renderpause:** Der Renderring verwirft ein geplantes Note-On, das mehr
  als 4096 Frames hinter dem gerenderten Sample liegt, statt es mit anderen auf Offset 0 zu legen;
  Note-Offs gehen immer hinaus, sofort-Noten sind ausgenommen (Zähler `planarium_note_ring_stale_ons`).
- **Messpunkte:** Controller-Zeit = Callback-Eingang → Rückkehr des Routers auf Q; Bluetooth-/
  Treiberzeit davor und der Audiopuffer danach sind nicht enthalten.
- **Darstellung** auf nativer Live-Ebene (`LiveLayerView`); Gerätemeldungen und Mausbewegung zeichnen
  nur diese Ebene neu, die SwiftUI-Bühne wird dabei nicht ausgewertet (Test
  `testPadMovementRedrawsTheNativeLayerOnly`).
- **Simulation** auf der Bühne nutzt denselben Weg wie das Gerät (`simulateController`, mit dem
  Gerätezustand vereinigt); Gate/Note-Off stammen nie aus Prognose.
- **Persistenz:** `InstrumentDocument.controller`, in Vollpreset und Vorlage (V6/V7-Container), nur
  geschrieben, wenn nicht leer (bestehende Presets bytegleich), beim Lesen validiert; Altformate
  bringen keine Zuweisungen. Änderungen sind Undo-Schritte.
- Offene Verifikation: echter DualSense-Lauf (Bluetooth/USB, Lightbar, Touchpad-Nullpunkt, Latenz)
  am Owner-Gerät mit Protokoll; Adaptive Trigger und Gyro sind vorgemerkte Ideen, nicht gebaut.

| Zustand | Verbindlicher Besitzer / Leser | Thread und Übernahme | Persistenz / History |
| --- | --- | --- | --- |
| Dokument / Revision | `SpatialInstrumentRuntimeModel`; Canvas, Presets, Compiler lesen | MainActor; `commit` validiert und kompiliert oder verwendet den kompatiblen Index vor `install`; Compilat auf Q erst nach Install-Befehl gültig | Presetinhalt; Revision ist keine Dateiidentität |
| Auswahl / ausgewählte Ebene | **SickPLSMonitorKit** · [CanvasSession in CanvasOwners.swift](Sources/SickPLSMonitorKit/CanvasOwners.swift); Feld/Inspector lesen Projektion. `CanvasInspectorModel` hält vorbereitete Interaktion, `CanvasLayerListModel`/`CanvasLayerSelectionModel` ausschließlich abgeleitete Listen-/Zeilenanzeige | MainActor; akzeptierter Befehl oder explizite Auswahl; Dokumentprojektion ist keine zweite schreibbare Dokumentkopie | Ansicht; reines Auswählen kein Undo. Save übernimmt ausgewählte Ebene, History stellt Auswahl nur nach ihrem bestehenden Vertrag wieder her |
| Undo / Redo | `SpatialInstrumentRuntimeModel`; Menü/Canvas lesen | MainActor; nach erfolgreicher Validierung und ggf. Kompilierung, Coalescing an Bearbeitungsgrenzen | Eine Sitzungshistory; keine zweite im Inspector/Canvas |
| Runtime / aktive Szene / Zellen | `PerformanceRuntime` / `PlayState`; Anzeige liest Mailbox | Q; FIFO für Profile und Befehle, asynchrone Main-Rückmeldung mit Revision/Szenengeneration | Flüchtig; Spielen gespeicherter Szenen erzeugt kein Dirty. Nur die noch unveränderte Runtime-Projektion von Szene/Aktivität wird beim Inhaltsvergleich neutralisiert; echte Aktivitäts-/Inhaltsänderungen bleiben sichtbar. Explizites Save darf die aktuelle Startszene übernehmen |
| Ausgänge / klingende Noten | `OutputRouter` auf Q; `AudioHost` / `MIDIPortOwner` halten Ressourcen | Senden und Retire auf Q; erst Quittung an Main erlaubt Transport-/Instanzfreigabe | Flüchtige Noten-/Portbelege; Routings und Ziele im Dokument |
| Plug-in-Zustand | **PlanariumAudio** · [PluginInstance.swift](Sources/PlanariumAudio/PluginInstance.swift); `AudioHost.snapshotMixer` liest explizit | Host/Editor auf MainActor, AU-Zustand intern beim Plug-in; vollständiger Snapshot bei Save/Duplizieren; Ladeentscheidung/Beenden verwenden Dokumentinhalt und Änderungsereignisse; Editoränderung erhöht Dokumentrevision nicht automatisch | Opaker Snapshot im Preset; Dirty-Prüfung liest keinen frischen AU-Zustand. Offene Plugin-Fenster zählen als mögliche Änderung; Fensterschluss zählt als Änderungsereignis bis Save/Load, auch ohne nachweisbare Parameteränderung |
| Audioausgang / Ein-Zustand | `AudioOutputDeviceControlModel`; Kanalzüge lesen denselben Besitzer | MainActor; CoreAudio-Geräteliste/Systemziel ereignisgebunden, Callback nur Mailbox; bestehender Audio-Retire vor Gerätewechsel. Wiederkehrendes Gerät wird angeboten; keine automatische Rückschaltung im Spiel | App-Einstellung nach stabiler UID, kein Preset. Ein-Zustand überlebt Start/Update, Schlaf und Beenden; expliziter Stop speichert Aus. Fehlendes Startgerät: Hinweis, zunächst kein Ton. Strip zeigt reale nominale Geräterate; Karten-Picker bleibt Kanal-Verarbeitungsrate |
| AU-Editor / nativer Bypass | `PluginInstance` / `AudioHost` | Editor nur nach expliziter Strip-Auswahl und geladenem Zustand, Auswahl-Lease + Perform-/History-Sperre auch bei spätem Editor-Callback. Offizieller `shouldBypassEffect`-Weg, inklusive v2-Brücke; Callback nur Bool-Mailbox, gebündelt Main, Abmeldung vor Release | Nativer Bypass ist reine Anzeigeübernahme; kein versteckter Undo-/Dokumenteintrag. Strip-Klick setzt den dokumentierten Bypass ausdrücklich. Keine proprietäre Parameternamens-Heuristik |
| Presetentscheidung / Dateiidentität | **PlanariumPresets** · [PresetControlModel.swift](Sources/PlanariumPresets/PresetControlModel.swift) | MainActor; Anfrage-ID + Revision + semantischer Snapshot inkl. Plug-in-Zustand/Beschreibung vor Save/Load | Ladecheckpoint flüchtig; atomare Dateiablage ist keine allgemeine Transaktion externer Wirkungen |
| Scanner-Portbesitz | `InputOwner` / [SerialPortOwnership.swift](Sources/SickPLSCommissioning/SerialPortOwnership.swift); Setup und RX beanspruchen über diese Grenze | MainActor; echter Close-/Release-Beleg des Reader-/TX-Wegs vor neuer Übernahme | Sitzung; weder Preset noch Undo; ein Profil- und ein Portfreigabeabonnement |
| Raumkontur | `SpatialInstrumentRuntimeModel` hält Sitzungsevidenz; Q erhält Wertkopie, Fit/Anzeige lesen | Eingangsabzweigung nimmt profilzeitgebunden auf eigener Queue auf; Main übernimmt Fortschritt/Ergebnis, `runtime.roomContour` auf Q; Abbruch erhält vorherige Kontur | Kontur, Filterzustand und Toleranz gelten für den Programmlauf; Presetwechsel erhält sie. Fit verändert dagegen dokumentierte Zellen mit Undo |

Die Ablehnungsgrenze (Dokument, Auswahl, ganze History, Runtime, aktive Ausgaben)
ist in [DocumentEditingContractTests.swift](Tests/SickPLSMonitorTests/DocumentEditingContractTests.swift)
und [PresetProductionTests.swift](Tests/PlanariumPresetsTests/PresetProductionTests.swift)
belegt. Nach akzeptierter Dokumentübernahme können externe Audio-/Dateischritte
separat fehlschlagen; ein vollständiger Rollback wird dafür nicht zugesagt.
Fehler-/Löseverträge bleiben an ihrer bestehenden Stelle: [Halten/Toggle und
Lösematrix/PANIC](#vollständige-lösematrix), [Port-Retire, Perform und Lebenszyklus](#1-produktziel-und-feste-grenzen),
[Presetentscheidung](#daten--und-besitzgrenzen).
Der historische QUALITÄT-1-Rücklauf ist per
`git show 827601d:.agent_handoff/latest_claude.md` nachlesbar; Besitzer oben
wurden zusätzlich gegen den genannten Checkout geprüft.

### Nachweisstand tragender Produktaussagen

Alle Commitangaben bezeichnen implementierten Code, keine erneute Messung.
Prüfstand der automatischen Belege: vorhandene Tests und abgenommene Rückläufe
bis 17.10.2026 (siehe datierte Einträge im [Checkpoint](.agent_handoff/checkpoint.md));
frische Stichproben dieser Doku-Runde stehen ausschließlich im
[letzten Rücklauf](.agent_handoff/latest_claude.md). Befehle laufen ab Projektwurzel.
Filter in der Tabelle sind XCTest-Namen; der Befehl lautet jeweils
`scripts/suite-summary.sh --filter '<Filter>'` (Baufehler/Abstürze werden mitgezählt).
Versions-, Build- und Punktzahlangaben sind Format-/Aufbaukennungen; Hz- und
Zeitangaben benennen den jeweiligen Test- oder Geräteumfang, keine pauschale
Leistungszusage. Fakes, synthetische Profile und Offline-Hosting sind kein realer Spieltest.

| Produktaussage | Implementiert (Commit / Code) | Automatisch geprüft (Testdatei · Filter für obigen Befehl / Umfang) | Real bestätigt |
| --- | --- | --- | --- |
| USB-Autostart, Vollscan mit 361 Punkten bei 25 Hz | `7f4edc2` · `StandardConnectionControlModel` / App-Einstieg oben | [StartRoomTests.swift](Tests/SickPLSMonitorTests/StartRoomTests.swift) · `StartRoomTests.testSceneUSBWatchUsesSharedSetupRouteAndStopsWatchingOnCancellation` (Fake-Ports) | **Teilbeleg:** Supervisor, Build 926, 14.10.2026: Autostart nach manuellem Reset, danach erneuter Start erfolgreich; kein Dauerlauf. [Geräteprotokoll/Befund](.agent_handoff/befunde-owner-test-842.md#supervisor-gerätelauf-14102026-2255-build-926-start-raum). Automatischer Reset bei `a0 02` offen |
| Detektionsstufen einschließlich Edge/Core | `cc3802d`, `a57ac9d` + Korrektur `87a69ea` · `SpatialDetectionPipeline` / Stufenplan oben | [DetectionStageRegressionTests.swift](Tests/PlanariumDomainTests/DetectionStageRegressionTests.swift) · `DetectionStageRegressionTests.testMovingCoreIsSmoothedBeforeCellChoiceAndMeasuredExitReleasesNote`; [EdgePointCoreTests.swift](Tests/PlanariumDomainTests/EdgePointCoreTests.swift) · `EdgePointCoreTests` (synthetisch) | offen: unabhängige Owner-Aufnahmen fehlen; Replay-Hashes sind selbst erzeugte Regressionserwartungen |
| Zellwahl / Noten bei unterstützten Profilgeometrien | `3f6db2a` · `PlayEngine` / `FullScanProfileAdapter` oben | [ProductionCompositionTests.swift](Tests/PlanariumApplicationTests/ProductionCompositionTests.swift) · `ProductionCompositionTests.testFullScan361PlaysThroughProductionRoot` (Reader-/MIDI-/AU-Fakes; weitere Geometriefälle in derselben Klasse) | offen für diesen Checkout; Testname „Scanner“ bezeichnet dort einen Fake-Reader |
| Halten / Toggle / Schutzzeit | `2bf3500`, `f0fe290` · [SpatialNoteLedger.swift](Sources/PlanariumDomain/SpatialNoteLedger.swift) / `PlayEngine` | [HaltenToggleRuntimeTests.swift](Tests/PlanariumRuntimeTests/HaltenToggleRuntimeTests.swift) · `HaltenToggleRuntimeTests.testCompleteReleaseMatrixThroughMIDIFakeAndAUFakeAt90And361` und `HaltenToggleRuntimeTests.testGuardUsesProfileTimeOnBothFakeOutputsAndDiscardsEarlyEntry` | offen: Owner-Abnahme der aktuellen Löse-/Defaultmatrix |
| PANIC löst und hält betretene zusammenhängende Fläche gleicher Zellen stumm bis gemessener Flächenwechsel (auch Snap 0) | RUNDE-E · Commit durch Supervisor ausstehend · `PlanariumComposition.panic` → Q | [ProductionCompositionTests.swift](Tests/PlanariumApplicationTests/ProductionCompositionTests.swift) · `ProductionCompositionTests.testRundeEPanicSurfaceDriftAndIndependentLayerPartitions90And361` und `testStageReleaseMatrixAfterMixerAndSceneFor90And361` (synthetisch, MIDI-/AU-Fakes) | offen: aktueller realer Klang-/MIDI-Beleg |
| AU-Hosting / unabhängige Kanalzüge | `f3e5fb7` · `AudioHost` / `AVAudioGraph` oben | [ChannelMixerHostTests.swift](Tests/PlanariumAudioTests/ChannelMixerHostTests.swift) · `ChannelMixerHostTests.testSeparateInstancesSchedulesSoloAndSnapshotPreserveEachStrip` (Fakes); [ChannelMixerOfflineTests.swift](Tests/PlanariumAudioTests/ChannelMixerOfflineTests.swift) · `ChannelMixerOfflineTests.testAppleHeldChordAndIndependentMelodySoloMuteAndSumOffline` (Apple-AUs offline) | offen: reales Hören, Drittanbieter-Lastmessung (KZ-4); Offline-AU ist kein Treiber-/Bühnenbeleg |
| Presets V6: Mischpult / opake Zustände / Harmonievorlage | `f3e5fb7` · [InstrumentPresetV6.swift](Sources/PlanariumPresets/InstrumentPresetV6.swift) | [PresetV6Tests.swift](Tests/PlanariumPresetsTests/PresetV6Tests.swift) · `PresetV6Tests.testAllStripsMasterOpaqueStatesAndSummaryRoundTripAndTemplatePreservesMixer` (synthetische Zustände) | offen: Dateitreue mit lebenden Drittanbieter-Editorzuständen |
| Save/Discard verwirft veraltete Ladeentscheidungen | `827601d` · `PresetControlModel` oben | [PresetProductionTests.swift](Tests/PlanariumPresetsTests/PresetProductionTests.swift) · `PresetProductionTests.testPendingDiscardRejectsRevisionEvenWhenUndoRestoresIdenticalSemantics` (MainActor/Dateifixture) | offen: native Dialog- und Editorbedienung in Build 943; gebautes Bundle allein reicht nicht |
| MIDI-Clock senden | `89321ad` · `MIDIClockDriver` oben | [MIDIClockTests.swift](Tests/SickCoreMIDIOutputTests/MIDIClockTests.swift) · `MIDIClockTests.testTenMinutesWithTempoChangesAndIrregularPlanningHaveZeroGridDrift` (synthetische Zeit, Fake-Sink; zehn simulierte Minuten) | offen: MainStage/Kabel/Bluetooth im Owner-Aufbau |
| MIDI-Clock empfangen / Transportverlust | `e71c264` · `MIDIClockReceiver` oben | [MIDIClockReceiverTests.swift](Tests/SickCoreMIDIOutputTests/MIDIClockReceiverTests.swift) · `MIDIClockReceiverTests.testStartStopContinueLossAndRecoveryPreserveMusicalPosition` (synthetische Pakete/Zeit) | offen: externe Clockquelle im Owner-Aufbau |
| AU-Hostkontext aus gemeinsamem Takt | `5fc52a6` · `HostMusicalClock` / `PlanariumHostClockDSP` oben | [HostClockOfflineTests.swift](Tests/PlanariumAudioTests/HostClockOfflineTests.swift) · `HostClockOfflineTests.testAUv2BridgeInstallsAllLegacyHostCallbacks` (native AUv2-Bridge offline; kein Audio-Gerät) | offen: UADx/andere Sync-Plug-ins; [Owner-Testliste](.agent_handoff/testliste-build-943.md) ist Prüfauftrag, keine Rückmeldung |
| Program Change / Bank / Ebenenziele | `dfa34ae` · [PortAdapters.swift](Sources/PlanariumRuntime/PortAdapters.swift) / `OutputRouter` | [ProductionCompositionTests.swift](Tests/PlanariumApplicationTests/ProductionCompositionTests.swift) · `ProductionCompositionTests.testProgramChangePerformLockLayerTargetsAndProductionReleaseMatrix` (Fake-MIDI, synthetischer Eintritt) | offen: H90-/Fremdgerätewechsel beim Owner |
| Profilaufnahme: Rohgeometrie ohne zweiten Eingang | `cc3802d` · [ProfileRecordingModel.swift](Sources/PlanariumApplication/ProfileRecordingModel.swift) | [ProfileRecordingTests.swift](Tests/PlanariumApplicationTests/ProfileRecordingTests.swift) · `ProfileRecordingTests.testTenSecondsCopiesEveryProfileThroughOneBindingWhileMainIsBlockedAndRoundTripsRawGeometry` (zehn simulierte Sekunden, Fake-Reader/Datei) | offen: aktuelle Owner-Dateien als unabhängige Referenz (QUALITÄT-3); Opt-in `PLANARIUM_RECORDING` in [EdgePointCoreTests.swift](Tests/PlanariumDomainTests/EdgePointCoreTests.swift) (`EdgePointCoreTests.testOptInOwnerRecordingMetrics`) ohne Datei übersprungen |
| Raumkontur: Vorlauf / Abbruch / Sitzungslebensdauer | `7f4edc2`, `3f6db2a` · `SpatialInstrumentRuntimeModel` oben | [StartRoomTests.swift](Tests/SickPLSMonitorTests/StartRoomTests.swift) · `StartRoomTests.testCancellationMatrixPreservesPreviousContourAndStaleTicksCannotRestart`; [ProductionCompositionTests.swift](Tests/PlanariumApplicationTests/ProductionCompositionTests.swift) · `ProductionCompositionTests.testProductionContourSurvivesDisconnectReconnectAndDocumentReplacement` (synthetisch) | offen: aktuelle Aufnahme mit realer Raumreferenz; keine Gleichsetzung mit Geräte-Schutz-/Warnfeldern |
| Perform-Sperre lässt nur erlaubte Änderungen durch | `8532727`, `dfa34ae` · `SpatialInstrumentRuntimeModel.authorize` | [ProductionCompositionTests.swift](Tests/PlanariumApplicationTests/ProductionCompositionTests.swift) · `ProductionCompositionTests.testProgramChangePerformLockLayerTargetsAndProductionReleaseMatrix` (direkte Produktionsaufrufe/Fakes) | offen: vollständige aktuelle Bedienmatrix; ältere Mockup-Freigabe ist kein Bedienbeleg |
| Ansichtsbudget am synthetischen Profilweg | `18cf7c4` · Detektion oben / [CartesianScanFieldView.swift](Sources/SickPLSMonitor/CartesianScanFieldView.swift) | [AcceptanceAViewBudgetTests.swift](Tests/SickPLSMonitorTests/AcceptanceAViewBudgetTests.swift) · `AcceptanceAViewBudgetTests.testProfile25HzMeter30HzInvalidateOnlyCanvasAndMeter90And361` (Offline-Hosting, synthetische Profil-/Meter-Takte; lastabhängig, Nachlauf laut CLAUDE). [Serieller Messweg](scripts/perf-szenarien.sh), [Messvertrag](#reproduzierbare-leistungsmessung), Basistabelle und Prüfergebnisse im [QUALITÄT-D-Rücklauf](.agent_handoff/latest_claude.md#basistabelle-qualität-d) | offen: reale Eingabe-bis-Anzeige-/GPU-/Audioleistung; frühere CPU-Einzelwerte sind keine allgemeine Zusage |
| Port-Retire vor Schließen / Wiederanbindung | `3f6db2a` · `PerformanceRuntime.retire` / `MIDIPortOwner` | [ProductionCompositionTests.swift](Tests/PlanariumApplicationTests/ProductionCompositionTests.swift) · `ProductionCompositionTests.testMIDITargetChangeRetiresBeforeClosingAndAttachesOnlyAfterAck` (Fake-Transport) | offen: Portexklusivität über Prozesse (BÜHNE-FEST-E); dieser Test belegt nur die interne Quittungskante |

### Offene Audio-Nachweise aus dem SoundCraft-Review (24.10.2026)

Quelle ist die [Erkenntnisübergabe des SoundCraft-Teams](.agent_handoff/review-soundcraft-erkenntnisse-2026-10-24.md)
zu DAW-RV-001/002 einschließlich Fable-Gegenprüfung und korrigierter Supervisorbewertung,
Reviewstand `2917ad8`. Der Supervisor hat die benannten Reset-Aufrufstellen im aktuellen
Code nachgelesen; es gab dazu keinen neuen Test-, Audio- oder Gerätelauf. Die
[offene Reihenfolge](END_PRODUCT_ROADMAP.md#offene-reihenfolge) führt die nächsten Schritte.

- **Fade-Reset / Renderpause zuerst untersuchen.** `AVAudioGraph.stop` beendet die gemeinsame
  Engine nur, wenn kein Root-/Branch mehr läuft, ruft anschließend aber `fadeUnit.reset` auf.
  `setMuted` wählt Reset anhand des lokalen `running`. `planarium_fade_reset` schreibt
  nicht-atomare Renderfelder; das atomare Request/Reached-Protokoll belegt die Sicherheit
  dieses Resets nicht. Ob derselbe Branch dabei noch gerendert wird, ist offen. Es liegt
  kein nachgewiesenes Datenrennen vor; ein mögliches C-Datenrennen wäre jedoch nicht auf
  hörbare Klicks begrenzt. Vor einer Änderung alle Root-/Branch-Verbindungen und Reset-Wege
  inventarisieren und die Renderpause bzw. Übergabe belegen. Gegenprobe: zwei verbundene
  Branches, einer läuft weiter, der andere stoppt oder ändert Mute; Reset und Render im
  Offline-Harness gezielt überlappen lassen. Falls die Pause fehlt, Quieszenz oder ein
  ausdrücklich entworfenes Renderkommando herstellen; Lebensdauer, Wiederanlauf und
  Fade-Bestätigungstoken erhalten. Bestehende `FadeConcurrencyTests` prüfen Request/Reached
  und ersetzen keine Reset-Gegenprobe.
- **Diagnose danach entlang der ganzen Aufruferkette prüfen.** Kandidaten sind
  Clock-Seqlock-Fallback, abgewiesene Note-Ring-Ereignisse und ungültige DSP-Ausgabe.
  Vor neuen Zählern C-Rückgabewerte bis Runtime und Status verfolgen; ein fehlender
  C-Zähler beweist keine fehlende Erfassung im Aufrufer. Vorhandene Q-Diagnose und Meter
  erhalten und nicht doppeln. Neue Ereignisse nur als feste Codes/Skalare im Renderpfad
  erfassen und außerhalb auslesen; dort keine Formatierung, Dateiausgabe oder neue
  unbegrenzte Arbeit. Gegenproben erzwingen Fallback und Abweisung und prüfen begrenzte,
  sichtbare Fehlerzustellung; ungültige DSP-Ausgabe gezielt injizieren.

Die vorhandenen begrenzten Clock-Snapshot-Leseversuche, kohärenten Fallbacks, Note-Ringe
und Generationswechsel bleiben die Grundlage. Ein Kernersatz durch SoundCraft ist nicht
geplant. Callback-Warten auf Worker sowie Struktur-/Plugin-Aufbau im Callback werden nicht
übernommen. Etwaige konkrete Codeübernahmen brauchen eine Lizenz-/Noticeprüfung.
Diese Einträge sind Untersuchung und Planung, keine pauschale Echtzeitfreigabe oder
Freigabe realer Audio-/AU-/MIDI-/Geräteläufe.

### Reproduzierbare Leistungsmessung

Die drei vorhandenen Szenarien messen unterschiedliche Grenzen; ihre Werte
werden weder addiert noch als reale Eingabe-bis-Anzeige-Latenz ausgegeben.

| Szenario / Test | Beginn → Ende; Eingabe und Vorwärmung | Bestehendes Budget und Herkunft |
| --- | --- | --- |
| Häufige Bedienaktion · `SelectionTempoTests.testNativeLayerAndCellSelectionVisibleWithinFiftyMillisecondsWithoutDocumentPublication` | Uptime vor nativem MouseDown/Up → nach Inspector-/Host-Layout, 1-ms-Runloop und Display-Aufruf. Je ein Ebenen- und Zellklick für Harmony 29, Harmony 30 und die versionierte Keller-03-Fixture; 1500 × 1000, offscreen NSWindow; vorgewärmt durch Layout + 100-ms-Runloop + Layout, erster Wechsel je frisch aufgebautem Preset. Dispatch-/Hostinganteil zusätzlich im Originalprotokoll | Harmony 29, Harmony 30 und Keller 03 jeweils **< 50 ms**, AUSWAHL-TEMPO-Ziel vom 12.10.2026; [SelectionTempo-Assert](Tests/SickPLSMonitorTests/AcceptanceAViewBudgetTests.swift), in AUSWAHL-HARMONY auf beide Harmony-Presets erweitert. Lastabhängige Gegenprüfung nach CLAUDE.md; keine Grenzwertlockerung |
| Stressfall · `AcceptanceAViewBudgetTests.testProfile25HzMeter30HzInvalidateOnlyCanvasAndMeter90And361` | Main-Thread-CPU vor → nach unverändertem 3-s-Fenster, geteilt durch dessen Walltime. 90/361 Strahlen (separat), synthetische Profile 25 Hz + Fake-Meter 30 Hz, Harmony 27, 1500 × 1000 in unsichtbarem, als sichtbar gemeldetem Fenster mit Fenster-Aktualisierungszyklus (seit LIVE-NATIV). Host durch Layout/Display + 200-ms-Runloop vorgewärmt; frischer Detektor, erste Profilprobe enthalten. Enthält Profilbau, Detektion, Mailbox-Lesen, Publizieren und Hostarbeit | **< 25 %** Main-Thread-CPU, in BUDGET-361 (15.10.2026, `18cf7c4`) ausdrücklich unverändert beibehaltener [Abnahme-Assert](Tests/SickPLSMonitorTests/AcceptanceAViewBudgetTests.swift); kein Prozess-/Gesamt-CPU-Wert |
| Abbruchweg und Profilreferenz · `ProductionLatencyTests` | Profil: Zeitstempel des echten Reader-Queue-Adapters im Fake-Transport → Fake-MIDI-Send, 10 000 alternierende Profile (361 Strahlen, 100/150 cm, 2 Zellen, CC, Detektion off). PANIC: monotone Uhr direkt vor `root.panic()` → erster Fake-Note-Off, 1000-mal nach gemessenem Austritt/Wiedereintritt (eine Zelle, Note 60). Frische Root/Verbindung, kein verworfener Warmup; erste Probe enthalten, danach gleicher Prozess | Unverändert aus `ProductionLatencyTests` (P5-/A9-Vertrag): Profil **p99 ≤ 20 ms, max < 40 ms**, PANIC **p99 ≤ 5 ms**. Die strengeren weiteren RuntimeLoad-A9-Asserts werden nicht auf diese Messgrenze übertragen |

Feldbeschriftungen einschließlich Überdeckungsbesitz werden für jede sichtbare
Ebenenauswahl beim Aufbau des unveränderlichen Feldplans vorbereitet; ein Klick
liest nur das passende Array (verdeckte/unbekannte Ebenen nutzen den vorbereiteten
Zustand ohne sichtbare Auswahlebene). Das verlagert zusätzliche Arbeit und
Speicherbedarf an die Dokumentänderung, nicht an den Auswahlweg.
Mixerwerte und Tempo werden vor der History mit den skalaren Compilerregeln
validiert. Sie ändern Dokument und Clock bzw. Mixer, ohne Recompile,
Feldplanaufbau, MIDI-Neubindung oder neuen Runtime-Install. Auch Undo/Redo dieser
Werte erhält den installierten Musikzustand. Metadaten ohne musikalische Wirkung
verwenden den bestehenden Index und stempeln seine Handles über den bisherigen
Installationsweg auf die neue Revision; Namen/Farben erreichen weiterhin die
Feld- und Inspector-Projektion. Eine geänderte Detektion durchläuft eine billige
Vorprüfung und genau einen Compile im Commit. Der Labelbesitz wird je
Malreihenfolge vorbereitet; die Auswahl verschiebt nur die eigenen Zellen
innerhalb ihrer Hörbarkeitsgruppe. Ebenen vergleichen ihren vollständigen Wert
nach Normalisierung der vier Präsentationsfelder Name, Farbe, Sichtbarkeit und
Sperre; neue musikalische Ebenenfelder nehmen dadurch automatisch am Vergleich
teil. Kanäle und Szenen vergleichen ebenfalls nach Normalisierung ihrer
ausgenommenen Metadaten/Skalare den gesamten Wert. `InstrumentDocumentTests`
prüft jedes ausgeschlossene musikalische Feld einzeln und jeden erlaubten
Metadatenwechsel einzeln sowie kombiniert gegen ein frisches Compilat.
`ProductionCompositionTests` prüft Zell-Overrides und Ebenenzuweisungen bis zur
installierten Runtime-Notenausgabe sowie Edits, Ablehnung, History und die
vorhandenen Löse-/Szenenkanten.

`CanvasSession.presentation` wird bis zur nächsten tatsächlichen Sitzungs- oder
Dokumentänderung wiederverwendet. Auswahlfilter nutzen Ebenen-Dictionaries und
entfallen bei unverändertem Auswahldomänenzustand. Die Auswahlgrafik samt
Verschiebevorschau, Rahmen und Griffen bereitet ihre Pfade hinter einer eigenen
Gleichheitsgrenze vor; Profilwechsel zeichnen nur die Live-Grafik. Der
Perform-Wechsel friert die Auswahl ein und blendet wie bisher nur den
Bearbeitungsrahmen aus. `CanvasDocumentOwnerValueTests` und
`FieldRenderingContractTests.testEditorLargeSelectionFiftyProfilesReusesProjectionAndPathsWideNarrow`
prüfen die echte Invalidierung und das Ausbleiben von Auswahlaufbereitung bei
Profilen in Edit, Perform und beim Rückwechsel, jeweils breit und schmal.
Ebenen- und Kanalnamen im direkten Namensfeld werden erst bei Enter oder
Fokusverlust übernommen, mit einem History-Schritt je Übernahme; Escape verwirft
den Entwurf. Das Kanal-Rename-Sheet behält ihre explizite
Rename-/Cancel-Entscheidung. Ein fremder Wert-/Kontextwechsel oder Perform
verwirft einen noch offenen direkten Entwurf. Native Offline-Proben stehen in
`AcceptanceAViewBudgetTests` und `ProgramNumberEntryTests`; ein realer
Bediennachweis dieser Editoroptimierung steht aus.

Die Auswahl bereitet den Inspector-Eingang einmal pro Änderung vor. Eine
Ebenenzeile besitzt eine eigene Hosting-Grenze mit unverändertem 24-Punkt-
Namensfeld plus oben und unten je fünf Punkten Rand; Auswahlfarben werden nur für die betroffenen
Zeilen publiziert. Listeneingaben haben einen eigenen, ausschließlich an
Ebenen-/Szenenänderungen gebundenen Besitzer; ein Klick erstellt keine Eingaben
für unveränderte Ebenenzeilen. Befehlsrahmen, unveränderte Szenenschaltflächen und
Feldtext-Eingaben werden dabei nicht neu aufgebaut. Textidentitäten hängen an
Regionen, damit sich ändernde Überdeckung keine unveränderten Nachbartexte
über verschobene Arraypositionen neu aufbaut. Die Zählprobe prüft diese
Grenzen auch mit zusätzlichen Szenen und über den Rückwechsel; eine echte
Dokumentänderung muss die erhaltenen Zeilen und Inspector-Werte weiter erreichen.
Beim **Inspector-Inhaltswechsel** bleiben Musik-, Steuer-, MIDI-Ziel- und
Programm-Bedienelemente erhalten. Eingeklappte Inhalte sind nicht bedienbar
und aus der Accessibility-Hierarchie verborgen; ihre Zahlenfelder sind gesperrt.
Der Musikteil und die Steuerabschnitte besitzen native Hosting-Grenzen:
Beim Verbergen setzen sie `NSView.isHidden`, ohne das SwiftUI-Root sämtlicher
Unterelemente umzuschalten. Eine Gleichheitsgrenze vor verborgenen Steuerhosts
vergleicht den beim Aufbau erfassten Sichtbarkeitswert; live gelesene Prädikate
würden beide Seiten eines Wechsels bereits im neuen Zustand sehen. Verborgene
Steuerhosts liefern intrinsische Höhe null und eine Fitting-Höhe null, ohne ihren Formularinhalt neu zu vermessen. Ihr natives Kind bleibt
eingehängt, damit Sichtbarkeitsänderungen die Zahlenfelder erreichen und keine
erneuten Mounts auslösen. Eine zusätzliche Breitenbeobachtung entfällt; der
native Größenvertrag reicht echte Fenstergrößenänderungen an sichtbare Hosts
weiter. Reine Musikdokumente brauchen keine einklappbare Cell-Fallbacksektion.
Sobald ein Cell-Formular vorbereitet wurde, bleibt diese Erhaltungsgrenze für
die Lebensdauer des Inspectors bestehen, auch beim Entfernen des Routingtyps.
Das MIDI-Zielmenü bleibt als SwiftUI-Menü mit natürlicher
Inhaltsgröße erhalten; verborgen sind sein Rahmen null, Hit-Testing und
Accessibility abgeschaltet. Es braucht keinen weiteren nativen Host. Explizite
Stacks bewahren die bisherigen Ausrichtungen und Abstände über die Hosting-
Grenze. Sichtbare Roots lesen die aktuellen Werte und Sperren. Sichtbare Steuerhosts
fordern ihre ideale vertikale Größe an und invalidieren nach Root-/Sichtbarkeits-
wechsel ihre intrinsische Größe; die Nullhöhe verborgener Hosts darf nicht
als sichtbare Formularhöhe erhalten bleiben. Die Offline-Rahmenprobe deckt
AU/MIDI × Notes/CC/PC/PB/Pressure, breit/schmal und alle Wechselrichtungen ab;
absichtliche Überlagerung schwarzer/weißer Klaviertasten ist ausgenommen.
Alle eingebetteten Hosts setzen ihr dunkles Farbschema als Environment und
geben keine Fensterpräferenz über `preferredColorScheme` weiter.

Die Vorbereitung teilt den letzten Ebenenstand und berechnet bei Änderungen
an Ebenen oder Raster höchstens eine Programm- und eine Steuervorlage. Nur
im Dokument vorhandene Typen werden vor dem ersten Auswahlwechsel vorbereitet;
weitere Inhalte entstehen bei Bedarf. Ohne entsprechenden Formulartyp werden
auch keine leeren Formularzustände angelegt. Jeder Host behält genau seine letzte
Präsentation, keinen wachsenden Zell-/Ebenen-Viewcache. Eine weitere einzelne
Projektion hält die aktuelle Zellinformation über Workspace, Auswahl und
Perform-Sperre; auch die PC-Binding-Getter lesen diesen aktuellen Besitzerstand.
Die wirksamen Ebenen-IDs werden einmal je Auswahlzustand gebildet. Unveränderte
Output-Menüs und Programmformulare haben eigene Präsentationsgrenzen; eine echte
Dokument-, Wert- oder Kontextänderung erreicht ihre erhaltenen Steuerelemente.

Nur Hosts mit Zahlenfeldern abonnieren den Sichtbarkeitszustand; dessen aktiven
Wert reichen sie als Environment an die Zahlenfelder weiter. Die Publikation folgt
synchron auf die bestehende Inspector-Publikation, vor dem View-Update; in
`updateNSView` wird kein beobachteter Zustand publiziert. Menüs und Stepper
ohne Zahlenfelder brauchen diese zusätzliche Bindung nicht. Die Bindung endet
mit der nativen Ansicht. Zahlenentwürfe gehören genau einem Auswahlkontext;
Kontextwechsel verwerfen sie, ohne native Steuerelemente neu anzulegen.
PC-Getter lesen den aktuellen Besitzer, Setter prüfen den ursprünglichen
Auswahlkontext. Verborgene CC-Formatter behalten ihre zuletzt dargestellten
Werte und können keinen Entwurf in einen anderen Kontext übernehmen. Auch ein
Zielwechsel derselben Zelle verwirft den Zahlenentwurf; ein früheres Return prüft
den ursprünglichen Routing-Zieltyp, bevor es einen neuen Wert schreiben darf.
MIDI-Zielpublikationen beobachtet nur das Menü.

`SelectionTempoTests.testInspectorContentSwitchWorkIsBounded` und
`testCCProgramAndSingleNoteInspectorSwitchWorkIsBounded` prüfen beide Richtungen
für Harmony 29/30 und Keller 03 (Keller hat im gespeicherten Stand nur Akkorde;
Steuerwerte werden ausschließlich im Test im Speicher angelegt). Die Probe hält
echte AppKit-Steuerelemente fest, verhindert damit eine Wiederverwendung ihrer
Adressen und verlangt bei Wiederkehr unveränderten Inhalts null neue Controls.
Sie prüft jede native Sichtbarkeitskante und die gesperrten verborgenen
Zahlenfelder; Zellinformation höchstens einmal, keine erneute Dokumentvorbereitung.
Wiederkehrender Inhalt erzeugt keine Tastenlayouts, Tasten-/Akkordtexte oder
Programmfeld-Mounts; andere Noten dürfen die zwei festen Klaviaturen aktualisieren.
`ProgramNumberEntryTests` sichern Entwürfe, Kontextwechsel, Undo, Escape, Perform
sowie das Ende der nativen Ansicht und ihrer Auswahlbindung ab.
Erstaufbau und Wiederkehr stehen getrennt im Messprotokoll. Das Inhaltswechsel-
Ziel bleibt < 50 ms. Nach drei isolierten Basis/Diff-Paaren mit grünen warmen
Steuer-/CC-/PC-Werten prüfen beide Zähltests auch deren 50-ms-Grenze;
Erstaufbau und Bildexport bleiben getrennt. Zeiten einschließlich
Überschreitungen stehen im Rücklauf. Der vorhandene 50-ms-Assert für gewöhnliche
native Auswahl bleibt bestehen. Bildexport ist eine getrennte Messphase außerhalb der Auswahl-Latenz.

Die feste Zwei-Oktaven-Klaviatur wird getrennt gezählt. Text-Zähler messen
Produkt-Eingaben für Text, keine privaten CoreText-/SwiftUI-internen Aufrufe.
Das weiterhin nötige Zeichnen sichtbarer Regionen und ausgewählter Zellen ist
von dieser Aufbereitung getrennt und wird nicht als größenunabhängig ausgegeben.
Bildvergleiche laufen mit `SWIFT_DETERMINISTIC_HASHING=1`: die bisherige
Set-Reihenfolge überlappender Auswahlkanten kann sonst einzelne Mischpixel
ändern. Der Hash-Startwert wird ausschließlich im Offline-Test gesetzt.

Wiederholung ab Projektwurzel, bei ruhiger Maschine und ohne andere Builds/Tests:

```sh
SICK_TEST_ARTIFACT_DIR="$PWD/.agent_handoff/runs/perf-$(date +%Y%m%d-%H%M%S)" scripts/perf-szenarien.sh 5 debug
```

Das Skript prüft einmal laufende Build-/Testprozesse und schützt eigene
Aufrufe mit einem atomaren Lock. Andere Teaminstanzen müssen währenddessen
ruhen; der Lock ersetzt keine teamübergreifende Absprache. Vorhandene
Messlogs werden nicht überschrieben. Jeder Swift-Aufruf wird abgewartet,
Fehler/Abstürze zählen über den bestehenden Suite-Parser. Auch rote Läufe
bleiben in der Tabelle und führen zu einem Fehlerstatus. Fehlende/doppelte
Szenarioprotokolle werden abgelehnt. Kein Retry wird stillschweigend entfernt.

[Gemeinsamer Reporter](scripts/perf-report.py): `SICK-PERF`-JSON je Messreihe
mit Rohwerten, Commit aus `SICK_PERF_COMMIT` (ohne Umgebung: „unbekannt“),
kompiliertem Debug/Release, Hardware-Modell, macOS, logischen CPU-Kernen und
Lastmitteln 1/5/15 Minuten nach dem Messfenster. Das Skript setzt Commit und
Laufnummer. Reporterfehler ändern keinen XCTest-Assert; das Skript erkennt
fehlende Berichte. Statistik: min/max immer, p50/p95 erst ab fünf Werten,
Nearest-rank; die Basistabelle poolt die Rohwerte je Preset/Aktion/Punktzahl,
niemals Perzentile oder unterschiedliche Einheiten. Bei fünf Werten ist p95
das Maximum und keine belastbare Tail-Schätzung. CPU-Prozentwerte sind je
ein vollständiges 3-s-Fenster, Profil-/PANIC-Werte einzelne Ereignisse.
Debug und Release sind getrennte Bedingungen; Vorher/Nachher braucht gleiche
Konfiguration, Maschine, Eingaben und vergleichbare Last. Es wurde hier kein
Produktpfad optimiert; funktionale Assertions bleiben im selben Lauf aktiv.

**Deterministisch:** keine Dokumentpublikation/Rekompilierung durch Auswahl,
unveränderte Revision/Planidentität, begrenzte Body-Auswertungen und korrekte
Zell-/Note-Off-Ergebnisse bleiben harte Assertions. **Lastabhängig:** Zeit,
CPU-Anteil und rechtzeitig gelieferte Takte werden getrennt protokolliert;
unveränderte Grenzwerte, Einzel-Nachlauf gemäß CLAUDE.md bei rotem Zeitbudget.
`RuntimeLoadTests` und die Release-Opt-ins `PLANARIUM_DETECTION_LATENCY`,
`SICK_VIEW_COST`/`SICK_DETECTION_COST` bleiben ergänzende Messungen mit anderer
Grenze; dieses Skript schaltet sie nicht ein.

**Nicht gemessen:** GPU/Compositor/physisches Display, reales Audio und AU-DSP,
CoreMIDI/Kabel/Zielgerät, serieller Scanner/Scanphase und die vollständige
physische Eingabe-bis-Anzeige-/Klang-Latenz. Layout/Display-Aufrufe im Hosting
belegen keine sichtbare Bildschirmreaktion. Lastmittel allein beweisen keine
exklusive oder ruhige Maschine; Startbedingungen und Abweichungen stehen
mit der Basistabelle im Rücklauf.

### Historischer Planungsrahmen vom 25.09.2026 (nicht maßgeblich)

Die folgenden ehemaligen AR-/Modell-/Prüfpläne bleiben als Herkunft erhalten.
Ihre Zahlen gehören zum damaligen Aufbau; undatierte Messumfänge sind kein
aktueller Nachweis. Reihenfolge: ausschließlich END_PRODUCT_ROADMAP; Checks
und Modellwahl: ausschließlich CLAUDE/AGENTS. Aktueller Produktpfad: oben.

#### Vorrangige Architekturrevision AR-0 bis AR-6

Die Konzeptphase hat belegbar parallele Legacy-/Spatial-Pfade, zwei
Verbindungsorchestrierungen, einen doppelten Audio-/Presetumfang, breite
SwiftUI-Invalidierungen und quadratisch skalierende Zellberechnungen im
aktiven Produkt aufgebaut. Deshalb gilt ab 25.09.2026 ein Feature-Freeze.

Ownerentscheidung 30.09.2026: Der Planarium-GUI-Neubau samt M-2…M-6 läuft
vorab; Reihenfolge in `END_PRODUCT_ROADMAP.md`. Für alle weiteren
SICK-043-Funktionen werden die
Runden **AR-0 bis AR-6** aus
`.agent_handoff/review-architecture-performance-2026-09-25.md` in dieser
Reihenfolge umgesetzt und abgenommen:

1. messbare Baseline,
2. eine Produktwahrheit und Entfernung toter Pfade,
3. kompilierter Instrumentstand und Runtime außerhalb des MainActor,
4. kleine SwiftUI-Zustandsflächen und getrennter statischer/dynamischer
   Canvas,
5. ein Verbindungsdienst,
6. AU-only Audio plus aktuelles Presetschema,
7. risikobasiert bereinigte Testsuite und Gesamtbeleg.

Die Zielgrenze ist verbindlich: ein Profileingang, eine Projektion, eine
Trefferschicht, ein Instrumentdokument, ein kompilierter Laufzeitstand, ein
Verbindungszustand und ein AU-Audiopfad. Legacy ist nur noch als Importformat
zulässig. Ein längerfristiger Parallelbetrieb oder weitere lokale
Timer-/Dispatch-/Observable-Patches sind keine akzeptierte Lösung.

**Umsetzungsentscheidung:** selektiver Kernneubau mit atomarem Cutover. Die
geprüften Protokoll-/Transport-/Systemgrenzen werden wiederverwendet; die
gekoppelte Produktmitte wird neu gebaut und der alte Weg anschließend
gelöscht. Verbindliche Keep/Replace/Delete-Matrix:
`.agent_handoff/decision-selective-core-rebuild-2026-09-25.md`.

#### Modellroute der Bereinigung

Die Modellwahl folgt dem Risiko des jeweiligen AR-Slices:

- **Opus:** Architektur über mehrere Targets, Nebenläufigkeit, Portbesitz,
  Geräteprotokoll/TX, Redaktions-/Sicherheitsgrenzen, echte Geräte- oder
  Audio-Lebenszyklen sowie Korrekturen an solchen Meilensteinen.
- **Sonnet:** klar lokale SwiftUI-/Layoutarbeit, mechanische Migration,
  isolierte Tests und Dokumentation ohne diese Grenzen.
- Ein Sonnet-Slice mit einem im ersten Review belegten Architektur-, Besitz-,
  Nebenläufigkeits- oder Gerätewirkungsfehler wechselt für die Korrektur auf
  Opus, statt weitere Sonnet-Mikrorunden zu erzeugen.

Die frühere Fable-/Big-Bang-Route ist durch die abgeschlossene Lieferung und
die jetzige Revision historisch. Sie steuert AR-0 bis AR-6 nicht. Die
Architektur-, Concurrency-, Audio- und Besitzslices benötigen ein dafür
geeignetes starkes Coding-Modell; mechanische Löschungen werden erst nach
belegtem Cutover gebündelt. Es gibt keinen weiteren Big Bang ohne messbare
Zwischenabnahmen an den Architekturgrenzen.

#### Risikobasierte Prüfstrategie

Die vollständige Suite bleibt vor jedem Coder-Rücklauf mit Produktcode
Pflicht; sie kostet auf dem dokumentierten Rechner rund 24 Sekunden und ist
nicht der Ressourcenschwerpunkt. Optimiert werden Wiederholung und Prosa:

- Der Coder führt die Vollsuite einmal aus und meldet eine Check-Zeile.
  Supervisor und Revisor wiederholen sie nur bei unplausiblem Ergebnis,
  geänderten Prüfhilfen oder einem markierten Revisor-Meilenstein.
- Clean Build nur bei `Package.swift`, hinzugefügten/entfernten Dateien,
  targetübergreifender Migration und Release; `minos` nur bei Änderung der
  `platforms`-Zeile.
- Strikte Concurrency ist ein Diagnosendiff gegen eine feste Referenz, kein
  bloßer Exit-0-Check. Gezählt wird jede eindeutige Diagnose nach
  `Datei:Zeile:Spalte + normalisiertem Meldungstext`, nicht nur der Quellort:
  aktuell 28 Diagnosen an 24 Orten in 12 Dateien. Die fünf Diagnosen in
  `ScanSession.swift` werden in SICK-0330b geschlossen oder einzeln
  begründet.
- Gegenproben bleiben Pflicht für geänderte Entscheidungsregeln und
  sicherheitsrelevante Löse-/Redaktions-/Besitzgrenzen; Layout und reine Doku
  brauchen sie nicht pauschal.
- Bildnachweise: breit und schmal, je sichtbar unterschiedlichem Zustand;
  reine Textvarianten über Präsentationstests.
- Verbindliche Detailmatrix und Selbstprüfung stehen ausschließlich in
  `CLAUDE.md`; absorbierte Pflichten in
  `.agent_handoff/abnahmepunkte.md`.

## 1. Produktziel und feste Grenzen

Die App wird ein spielbares, professionelles Laser-Theremin für macOS 12.
Der SICK PLS101-316 liefert die Eingabe; dieselben ausgewerteten Steuerwerte
speisen ein bewusst geladenes AU-Instrument und optional MIDI. Der Kanalzug
verwendet ausschließlich Audio Units: `aumu` als Instrument und `aufx` als
serielle Audioeffekte. Eigener Synth, eigenes Delay und eigener Hall entfallen
aus dem Zielprodukt.

**Kanalzugvertrag (Owner 10.10.2026, Konzept A–G):** Das Instrument enthält
höchstens acht geordnete Züge mit stabiler Identität, eigenem Instrument,
Inserts, Plug-in-Zuständen und Mischwerten. AU-Noten, Parameter und
All-Notes-Off tragen eine nicht-optionale Zug-ID; ein fehlender Zug bleibt „missing
channel“ und stumm. Halten/Toggle werden nur im betreffenden Zug ersetzt
oder gelöst. Ein AU-Instrumentwechsel löst nur den betroffenen Zug, nicht
MIDI; MIDI hat eine globale Zielwahl am Dokument/an der Summe; die Routings
bestimmen ihre MIDI-Kanäle unabhängig von der Zugreihenfolge. Genau ein globaler
PANIC-Knopf steht an der rechts feststehenden Summe, auch in Performance. PANIC
und Transport-Stopp reagieren beim ersten Mausklick auch bei vorne liegendem
Plugin-/Monitorfenster oder Sheet. „Instrument → PANIC — All Notes Off“ und
⌘⌥. erreichen PANIC aus jedem App-Fenster; eine lokale Ereignisregistrierung
verhindert doppelte Auslösung und wiederholte Tastendrücke.
Jeder Kanalzug speist den Master und zeigt im Ausgangsfeld „Master“.
Sein erster Klick öffnet die gemeinsame Gerätekarte; bei gestopptem Audio
startet er zusätzlich Audio. Das Gerät wird am Master/SUM angezeigt und gewählt,
nie als eigener Hardwareausgang eines einzelnen Kanalzugs.

**Bewusst akzeptiertes Risiko (Owner 19.10.2026):** PANIC bleibt über Oberfläche
und ⌘⌥. Main-gebunden; bei blockiertem Main verzögert sich die Auslösung.
Owner 19.10.2026 abends: Ein optionaler MIDI-Fußschalter bietet den zweiten,
Main-unabhängigen PANIC-Weg. Die app-weite Quellwahl und Note-/CC-Learn gehören
zum Rig, nicht zum Preset. Note On mit Velocity > 0 bzw. CC ≥ 64 auf dem
gelernten Kanal lösen direkt aus dem Eingangsblock Runtime-PANIC und Clock-Stopp
aus; Main erhält erst danach die Anzeige. Wiederholungen sind idempotent,
Release-Nachrichten lösen nicht aus. Quellenverlust ist sichtbar, Rückkehr
verbindet automatisch neu; der Eingang erzeugt und leitet keine Noten weiter.
Vertrag: [PANIK-FUSSSCHALTER](.agent_handoff/task-panik-fussschalter.md).
Eine gemeinsame Engine summiert die Unterzweige; Master-Fader, Summen-Meter und
Überlastanzeige sind getrennt von den Zugpegeln. V6 persistiert das
Mischpult; V3–V5 migrieren ihre AU-Ziele auf „Ch 1“. Duplizieren erzeugt
neue Instanzen mit gleichem Zustand und kopiert keine Ebenen. KZ-4
(Lastmessung realer Plug-ins) bleibt außerhalb des Offline-Slices.

**AU-MIDI-Steuerungen:** CC, Program Change mit optionalen Banken, Pitch
Bend und Channel Pressure haben eigene typisierte AU-Ziele mit Kanalzug-ID;
die alten MIDI- und AU-Noten-Wireformen bleiben unverändert. Gemeinsamer
Encoder, Auswertung und Retarget übertragen Programm-/Zellwerte AU ↔ MIDI.
Q sendet die Nachrichten synchron und geordnet über denselben vorbereiteten
`scheduleMIDIEventBlock` wie Noten (`AUEventSampleTimeImmediate`); im Render-
Callback entsteht kein neuer Pfad. Der Output Monitor zeigt erfolgreiche
CC-/PC-Ausgaben je gebundenem AU-Port (Bank-CCs zählen mit). Fehlerzähler
bleiben getrennt; eine nur teilweise gesendete Bank-/Programmfolge zählt
noch nicht als vollständige Auswahl.
Sustain und Pitch Bend werden pro physischem Port/Kanal nach erfolgreichem
Senden verfolgt. PANIC, Stopp, Schlaf/Wecken, Beenden, Eingangsverlust und
Watchdog setzen aktive Sustain-/Bend-Zustände neutral; Retire löst vor seiner
Quittung. Ziel-/Instrumentwechsel betreffen nur die alte Ausgabe/den alten
Kanal, Audio-Konfigurationswechsel nur AU. Abgewiesene Resets bleiben für
den nächsten Löseversuch vorgemerkt. Wiederanbindungen setzen auf allen 16
Kanälen Sustain, Pitch Bend und All Notes Off vor der ersten neuen Nachricht;
eine abgewiesene Phase blockiert weitere musikalische Ausgabe bis zum Retry.
Noten und bewusste Halte-/Toggle-Besitzer
behalten ihre bestehende Lösematrix.

**Program-Change-/MIDI-Zielvertrag (TEMPO-4, Owner 14.10.2026):** Eine
Zellzuweisung kann Program Change senden, gerätegenerisch auf Kanal 1–16.
Preset und optionale Bankwerte liegen auf dem Draht immer in 0–127;
„Device shows 0–127 / 1–128“ ändert nur die Anzeige je Zuweisung, „sends“
zeigt daneben das tatsächliche Programmbyte. Die zuletzt gewählte Zählweise
wird als App-Einstellung je MIDI-Ziel-UID gespeichert (Summe wird auf ihre
aktuelle UID aufgelöst, virtuelle Quelle UID 0). Neue PC-Zuweisungen und
noch nicht selbst belegte PC-Zellen verwenden diese Vorgabe; vorhandene
explizite Zuweisungen und Presetwerte bleiben erhalten. CC0 (MSB) und CC32
(LSB) sind einzeln optional und werden synchron vor dem zwei Byte langen PC
gesendet. Der Layer-Standard und eigene Zellwerte nutzen dieselbe Form.
Preset- und eingeschaltete Banknummern sind direkt eintippbar, mit Stepper
für Feinschritte. Enter und Fokusverlust übernehmen genau einen gültigen
Ganzzahlwert (Preset je Zählweise 1–128 oder 0–127, Banken 0–127) direkt
ins Dokument, auch beim Layer-Standard ohne zusätzlichen Apply-Klick.
Der native Ende-der-Eingabe-Callback übergibt auch über getrennte Hosting-
Roots hinweg. Vor Auswahlwechsel und Speichern endet der native Feldeditor,
damit ausgeblendete Formatter nicht während des Layouts zurückschreiben;
unveränderte native Feldwerte werden nicht erneut gesetzt.
Vor Ebenen-/Zellwechsel und explizitem Speichern werden offene
PC-, Bank- und CC-Zahlenentwürfe beim bisherigen Besitzer übernommen;
passive Snapshots übernehmen keinen Entwurf. Escape verwirft weiterhin.
CC-Nummern sind frei eintippbar (0–127), mit Stepper und Namensliste häufiger
Controller; CC-Zellwerte verwenden denselben Übernahmevertrag.
Leere, nichtnumerische oder außerhalb des Bereichs liegende Eingaben
stellen den bisherigen Wert mit Bereichshinweis wieder her; Escape verwirft
den Textentwurf. Jede geänderte Texteingabe bildet einen Undo-Schritt,
aufeinanderfolgende Stepper-Klicks je Feld werden zusammengefasst. Ein
offener Entwurf wechselt nie seine Zählweise oder seinen Auswahlbesitzer;
Textresponder behalten Einzeltasten und Text-Undo. Perform sperrt alle Felder.
Auslöser ist ausschließlich ein frisches Betreten der bestätigten Zelle
im echten Profilweg, mit derselben Bestätigung/Snap-Regel wie Noten.
Verlassen und Prognose senden nichts. Der physisch gebundene Ausgang merkt
die letzte erfolgreich gesendete PC-/Bankauswahl je Kanal; eine gleiche
Auswahl lädt das Gerät auch nach Wiedereintritt oder in einer anderen
Zelle nicht erneut. Stop, PANIC, Ziel- und Presetwechsel löschen dieses
Gedächtnis. Eingangsverlust hat für PC nichts zu lösen; PANIC sendet weder
PC noch Bank Select und erhält die vorhandene Noten-Lösematrix.

Ein optionales MIDI-Ziel je Ebene ergänzt das bisherige Summenziel. Es gilt
für Noten und vorhandene Controls (CC, Pitch Bend, Pressure), unabhängig
von Clock-Zielen. Ohne Feld bleibt das bisherige Verhalten bytegleich;
ein explizit fehlendes Ziel fällt nicht auf ein anderes Gerät zurück.
Kabel, IAC, Netzwerk und gekoppeltes Bluetooth-MIDI nutzen dieselbe
CoreMIDI-Zielliste. Ein eigener CoreMIDI-Katalogclient beobachtet Setup-,
Objekt- und Eigenschaftsänderungen auch ohne geöffneten Ausgang. Alle Menüs
beobachten dieselbe veröffentlichte Liste und bieten zusätzlich Refresh;
ein verschwundenes gespeichertes Ziel bleibt als „Unavailable“ sichtbar.
Mehrere Ebenen mit demselben Ziel teilen eine Bindung;
Retire löst Noten auf Q, erst die Main-Quittung schließt den Transport.
Senden bleibt in Perform erlaubt; Zuweisung, Kanal, Ziel, Bank, Nummer
und Zählweise sind über die bestehende `InstrumentAction.edit`-Grenze
gesperrt. Neue Presetfelder sind optional; alte Werk-/Owner-Dateien
behalten ihre eingefrorenen Encoding-Hashes. Realer H90-Test bleibt beim Owner.

**Tempo-/Clock-Vertrag (TEMPO-1/2/3, Owner 13./14.10.2026):** BPM ist Presetinhalt
im Bereich 30–300, Standard 120; fehlendes Feld lädt 120, der Standard
wird nicht geschrieben. Tap mittelt die letzten vier Abstände, beginnt
nach mehr als zwei Sekunden Pause neu und wird per Kopfleistenknopf oder
T ausgelöst. Ein appweit besessener lokaler Keydown-Monitor nimmt nur ein
einzelnes T ohne ⌘⌥⌃ oder Shift in einem Instrumentfenster an; Texteingabe
(auch Feldeditor), Blatt, modaler Dialog und andere Fenster einschließlich
Einstellungen reichen das Ereignis unverändert weiter. Das Menü hat kein
T-Key-Equivalent. BPM und Tap sind in Perform erlaubt (Owner 14.10.2026),
zentral über `InstrumentAction.tempo`. Sie ändern Clock und Dokumenthistorie
ohne Runtime-Neuinstallation, Noten-Rebind oder Verlust klingender Noten.
Clock-Richtung Send/Receive/Off, mehrere Ziel-IDs und genau eine Quell-ID
liegen in den vorhandenen Mac-Workspace-Einstellungen; das Notenziel
bleibt unabhängig. Alte globale Send-Einstellungen werden übernommen.
Richtung, Ziele und Quelle bleiben in Perform gesperrt.

Clock hat einen eigenen Transportknopf in der Kopfleiste; das bisherige
Play-Piktogramm dort schaltet ausschließlich Perform um. Der vorhandene
Audio-Start/Stop im Kanalzug startet/stoppt ebenfalls die Clock. Eine eigene
serielle Queue plant 24 ppqn als Ursprung plus ganzzahliger Tickindex mit
100 ms Vorlauf und 25 ms Planungsintervall. CoreMIDI erhält Hostzeitstempel;
vor einem Tempowechsel werden die noch geplanten Pakete am betroffenen
Ziel verworfen, der nächste alte Rasterpunkt bleibt die Phasengrenze und
danach gilt das neue Intervall. Ein noch geplanter Start wird dabei erhalten.
Ein Preset-Wechsel ändert BPM ohne Clock-Stop: Der Taktgeber bleibt für
externe Effekte verfügbar, während das Preset die musikalische Belegung
ersetzt. Stop, PANIC, Schlaf, Beenden, Off und Zielabwahl verwerfen geplante
Pakete, senden Stop und schließen die betreffende Clock-Bindung. Nach
Schlaf, Zielrückkehr, Zielauswahl oder Off→Send gibt es keinen Mitten-Einstieg;
erst ein neuer Transportstart bindet die gewählten Ziele. Verlust ist pro
Bindung verriegelt, auch wenn dieselbe CoreMIDI-ID wieder erscheint.

Clock geht an normale CoreMIDI-Destinations (auch IAC für MainStage).
Es wird keine neue virtuelle Source angelegt: Deren bereits an Clients
übergebene Zukunftspakete wären nicht gezielt widerrufbar.
`MIDIFlushOutput` wirkt endpointweit, auch auf Zukunftspakete anderer
Absender am selben Ziel; die Planarium-Notenpakete sind weiterhin immediate.
Eine versäumte Planungsfrist stoppt die Clock und meldet den erforderlichen
Transport-Neustart; überfällige Pakete werden nie als Burst nachgesendet.
Zielprobleme und unbestätigte Clock-Stops werden ebenfalls sichtbar gemeldet.

Receive besitzt einen eigenen CoreMIDI-Eingangsport und wertet nur
F8/FA/FB/FC auf einer eigenen seriellen Queue aus, ohne Thru oder
Notenpfad. Vor dem Eingangsbinden ist der Send-Stop einschließlich
Flush/Schließen bestätigt; vor einem neuen Send-Lauf ist der Eingang
geschlossen. Eine Generation verwirft Callbacks alter Bindungen und
überholte Aktivierungen. Host-Paketzeitstempel bestimmen das Tempo;
Zeitstempel 0 bedeutet in CoreMIDI „jetzt“ und verwendet die im Callback
gemessene monotone Ankunftszeit, weil keine präzisere Quellzeit vorliegt.
Ein Fenster aus 25 Tickzeitpunkten (24 Abstände, ein Viertel) schätzt die
Periode über den Median paarweiser Steigungen. Isolierte Ausreißer werden
verworfen; eine konsistente ±2-ms-Hülle stabilisiert den konstanten Takt,
bei Rampen gilt die robuste Steigung. Es gibt kein zweites Glättungsfenster.

`MIDIClockReceiver.snapshot` ist die Queue-eigene Quelle für externes
Tempo, Transport und Tickzähler seit Start. Musikalische Hostzeit wird direkt
auf der Empfangsqueue aktualisiert, unabhängig von Main. Die Anzeige liest
nur `ClockDisplayState`: Tempo auf 0,1 BPM, läuft/steht, verloren und Quelle
vorhanden; Publikation nur bei sichtbarer Änderung. Tickzähler und Rohsnapshot
werden nicht von Ansichten beobachtet. Die Kopfleiste zeigt „Ext“ mit
Quellenname im Tooltip. BPM, Tap (auch T/Menü)
und lokales Clock-Play/Stop sind bei Receive gesperrt. Externe Updates
ändern weder Preset-BPM noch Historie, Dokumentrevision oder Dirty-Zustand;
Off/Send zeigt wieder das Presettempo. FA startet und setzt den Tickzähler
zurück, FB setzt ihn fort, FC hält ihn an. F8 misst auch bei stehendem
Transport das Tempo; nur laufender Transport zählt weiter. Keine dieser
Nachrichten löst oder startet Instrumentnoten.

Fehlen Ticks länger als zwei Viertel des zuletzt gemessenen Tempos
(mindestens 0,5 s), steht der externe Transport und die Zeile
„External clock lost“ erscheint; das letzte Tempo bleibt erhalten.
Nach Ticks kehrt der zuvor laufende externe Transport zurück; ein
vorheriges FC bleibt stehen. Eine entfernte Quelle wird geschlossen;
Endpoint-Ereignisse lösen neue Bindungsversuche aus, ohne Dauertimer.
Der gespeicherte Quellenname bleibt sichtbar
als „Unavailable“ und lässt sich auf „None“ abwählen. Schlaf schließt den
Port; Aufwachen bindet die gewählte Quelle neu. Off, Quellwechsel und
Beenden schließen ebenfalls; Beenden verhindert jede Wiederöffnung.

Gehostete Instrumente und Effekte erhalten einen gemeinsamen Host-Takt
(`AudioHost.hostMusicalClock`, von allen Kanalzweigen geteilt): Send folgt
dem internen Clock-Start und dessen nächster Tickgrenze bei Tempowechsel;
Receive folgt direkt der Eingangsqueue mit Paketzeit und Tickzähler/24,
zwischen Ticks wird interpoliert. Off liefert das Dokumenttempo bei
stehendem Transport. Verlust und Lebenszyklus-Stop halten den Transport an;
ein Presetwechsel erhält den Takt und übernimmt das neue Dokumenttempo.
Die feste Taktart ist 4/4; der Taktanfang ist floor(Beat/4) × 4.

`AVAudioGraph.attach` setzt je Instanz beide AU-Host-Blöcke und den
Pre-Render-Beobachter vor der Render-Allokation, auch beim Wiederaufbau.
Die AUv2-Bridge setzt damit die Legacy-Host-Callbacks; es gibt keinen
zweiten AUv2-Pfad. Der Beobachter verwendet den Sample-Zeitstempel des
Renderaufrufs. Hostzeit im Zeitstempel richtet nur dessen Epoche aus;
offline teilen alle Instanzen eine Sample-Epoche. Der Renderpfad liest
ein C-Snapshot aus ausschließlich lock-freien atomaren Feldern. Ein
serialisierter Kontrollschreiber veröffentlicht mit Sequenzzähler;
nach höchstens drei Leseversuchen gilt der vorherige kohärente Snapshot
der Instanz. Keine Sperre, Allokation, Swift-Objektoperation, aktuelle
Wanduhr oder Queue-Zustellung liegt im Callback. Speicherbesitz ändert
sich nur beim Binden/Freigeben, nach Stop/Detach. Callback-Speicher bleibt
über Neuallokation und Graph-Neuaufbau für die ganze AU-Instanz erhalten,
auch wenn das Plug-in die Blöcke gecacht hat. Die Bindung hält dabei auch
den nativen AVAudioUnit-Knoten bis nach der Callback-Bereinigung: Eine
gehaltene AUv2-Bridge allein hält dessen nativen Handle nicht am Leben.
Das Transport-Changed-Flag wird pro Instanz seit der letzten Abfrage
einmal geliefert; auch ein erneutes FA markiert den Positions-Neustart.

Die Offline-Belege stehen im letzten Coder-Rücklauf. Echte Treiber-/Kabel-/
Bluetooth-Wirkung, Empfang von MainStage und das Verhalten realer
Sync-Plug-ins (einschließlich UADx) bleiben Owner-Test.

**USB-Start und Raumvorlauf (Owner 14.10.2026):** Start und neu erscheinende
USB-Seriell-Adapter nutzen den vorhandenen Setup-/RX-Verbindungsweg; bei
mehreren Kandidaten sequenziell in stabiler Pfadreihenfolge.
Ein während Setup oder RX-Öffnen erscheinender Adapter wartet auf den
tatsächlich freien Port; erfolgreicher Anschluss, Simulation oder bewusstes
Trennen verwerfen diesen wartenden Start.
Auch ein verspäteter erfolgreicher Setup-/Schlussbericht startet nach einem
bewussten Trennen kein RX mehr; der belegte TX-Schluss gibt nur den Besitz frei.
Automatik und normale Portliste enthalten ausschließlich `usbserial*`, `usbmodem*`,
`SLAB_USBtoUART*` und `wchusbserial*` unter `/dev/cu.*`. Unbekannte Namen
bleiben Supportports, sichtbar gedämpft über „Show all ports“, nie automatische
Kandidaten. Die vorhandene Auflistungsgrenze liefert nur Namen, keine
IOKit-Eigenschaft; es wird keine zusätzliche Geräteerkennung eingeführt.
Ohne Adapter: „No USB serial adapter found · connect the scanner cable“.
Simulation verlangt ausdrückliche Eingangswahl. Bewusstes Trennen/Abbrechen
sperrt USB-Autostart bis zur nächsten manuellen Verbindung; Verlust allein
löst keine Wiederholungsautomatik aus.

„Capture room“ beginnt mit drei Sekunden „Hands out · 3 · 2 · 1“ im
Room-Modul und groß im Feld. Drei absolute Fristen der monotonen Runtime-Uhr
steuern nur die Anzeige; die Aufnahme nimmt erst das erste Profil mit
Empfangszeit ab der Startfrist auf. Danach gelten unverändert 125 Profile
(fünf Sekunden bei nominal 25 Hz). Knopf und Esc brechen Vorlauf/Aufnahme ab;
Scannerverlust, Sitzungs-/Geometriewechsel, Presetladen und Perform-Wechsel
ebenfalls, jeweils mit Grundzeile und Erhalt der bisherigen Kontur. Im
Perform darf eine neue Aufnahme beginnen. Die Kontur bleibt Sitzungsevidenz
und wird nicht gespeichert.

„Contour pen“ ergänzt diese Sitzungsevidenz je Strahl nach innen:
wirksam ist das Minimum aus gemessener und gezeichneter Distanz. Freihand
interpoliert alle überstrichenen Strahlen, ⇧ zeichnet die Strecke vom
Gestenstart, ⌥ radiert zur gemessenen Wand bzw. ins Unbegrenzte zurück.
„Clear drawn contour“ entfernt nur die Zeichnung. Bei 90 ↔ 361 wird nach
dem nächsten Strahlwinkel umgerechnet. Die bestehende Konturlinie zeigt
Vorschau und Ergebnis; Detektion und Raum-Fit verwenden dieselbe Grenze,
auch ohne Aufnahme. Die Fit-Glättung darf gezeichnete Einbuchtungen nicht
öffnen. Zeichnen/Radieren ist in Perform gesperrt. Kein eigenes Undo;
Zeichnungen bleiben bei Preset-/Szenen-/Ebenenwechsel erhalten und gehören
weder zum Dokument noch zum Preset oder zu UserDefaults.

**Perform-Vertrag (Owner 12./14.10.2026):** Bedienbar bleiben BPM/Tap, Pegel, Pan und
Mute/Solo der Kanalzüge, der vorhandene Summenpegel, Szene per Klick,
Presetladen sowie Raumaufnahme/Fit to room. Mischwerte dürfen weder
Instrument, Inserts, Name, Farbe noch MIDI-Ziel mitändern; die bestehende
AU-Instanz bleibt erhalten. Alle anderen Instrument-/Preset-Schreibwege
einschließlich Sichern, Sichern unter, Beschreibung, Import/Export,
Kanal-/Zell-/Ebenenbearbeitung, Undo/Redo und Einstellungen sind gesperrt.
`SpatialInstrumentRuntimeModel.authorize` erzwingt die Erlaubnisliste auch
bei direkten Aufrufen, alten Menüs und offenen Bestätigungen. Ein Versuch
zeigt den Grund in einer festen einzeiligen Meldung; gesperrte Einträge
entfallen in Kontextmenüs. Ansichtsnavigation, gemessene Veröffentlichung,
PANIC, Stopp und Beenden bleiben unabhängig von der Schreibsperre möglich.
Reine Mischwerte und Tempoänderungen laufen ohne Runtime-Install; ihre
Dokumentrevision und Undo-/Preset-Historie werden weitergeführt. Die
Mailboxrevision bezeichnet den letzten musikalischen Install. Die Laufzeit
besitzt Szene, aktiven Ebenensatz und Szenengeneration. Jeder Install aus
dem Dokumentbesitzer trägt die zuletzt bestätigte Generation; ein älterer
Spiegelstand darf die laufende Szene nicht zurücksetzen. Bewusste
Aktivitätsänderungen und Presetladen ersetzen die Szene ausdrücklich.
Main übernimmt nur Rückmeldungen der aktuellen Dokumentsitzung, mindestens
der letzten Installrevision und keiner älteren Szenengeneration. Bei
unveränderter Musik bleiben Eintritts-Latches, PANIC-Sperren, weiterklingende gemessene
Zellen stummgeschalteter Ebenen und Eintrittssperren neu aktiver Ebenen
über Installs erhalten. PANIC, Stopp, bewusster Eingangswechsel, Presetladen,
Schlaf und Beenden lösen weiterhin alle Noten einschließlich Halten/Toggle.

**Messbetriebsart (Owner 10.10.2026):** Full scan 361 ist der Standard
beim Verbinden. MMK 90 bleibt wählbar und Rückfall; die Wahl wird auf dem
Mac gemerkt. Owner-Test Build 792: Vollscan bei 500 kBaud etwa 25 Hz.
Die iPhone-Simulation beginnt mit 361 Einzelstrahlen. Raumkontur sowie
Ein-/Aus und Toleranz gehören ausschließlich zum Programmlauf; Presetwechsel
ändern sie nicht. Alte `roomFilter`-Felder werden gelesen und ignoriert.
Eine Kontur gilt über den gleichen Winkelbereich für MMK und Vollscan,
mit konservativer Zuordnung über die Strahlspanne.

### Sicherheits- und Plattformvertrag

- **Der PLS ist hier kein Sicherheitsgerät.** Die verwendete Baureihe ist
  abgekündigt und das Projektgerät wird nicht mehr für Schutzaufgaben
  eingesetzt. Schutz- und Warnfelder sind deshalb für dieses Instrument
  Referenz- und Konfigurationsdaten, keine sicherheitstechnische Freigabe.
- **Schreibzugriffe am Projektgerät sind grundsätzlich freigegeben.** Diese
  stehende Owner-Freigabe umfasst insbesondere Modus, Baudrate, Adresse sowie
  Schutz- und Warnfelder. Jeder Lauf bleibt zielgerichtet, protokolliert die
  beabsichtigte Wirkung und prüft den Zustand anschließend durch Read-back
  oder einen gleichwertigen realen Beleg.
- **Das veröffentlichte PLS-Standardpasswort ist kein Geheimnis.** Es darf für
  Einrichtung und Diagnose verwendet und in der Oberfläche angezeigt werden.
  Andere Zugangsdaten bleiben von dieser Ausnahme unberührt.

- **Der Messpfad ist RX-only, der Produktablauf nicht künstlich TX-frei.**
  `SickPLSMacTransport` bleibt strukturell ohne Schreibmethode. Der
  Verbindungskoordinator darf über die getrennte, typisierte TX-Grenze die
  Befehle ausführen, die für Identität, Einstellungsmodus, 38.400 Baud und MMK
  fachlich nötig sind.
- Der Klick auf `Verbinden` übernimmt ausschließlich einen bereits laufenden
  B0-Messstrom bei 38.400 Baud. Bleibt der Strom aus, endet der Versuch
  portfrei und ohne TX mit dem Hinweis auf den Support-Bereich.
- Die aktive Vorbereitung ist vollständig handbedient: 9600 prüfen,
  `20 30` an Adresse 0, `20 00` an Adresse 1, Baudkommando, Neuöffnung und
  Verifikation bei 38.400, danach MMK. Jeder Schritt hält an und verlangt die
  nächste ausdrückliche Bedienhandlung; es gibt keine automatische
  Login-Wiederholung.
- Die Automatiksuche arbeitet sequenziell, hält höchstens einen Port und zeigt
  den geprüften Kandidaten. Sie verwendet ausschließlich typisierte,
  dokumentierte Identitäts-/Commissioning-Funktionen, nie frei eingegebene
  Rohtelegramme.
- Für Schreibzugriffe auf das benannte PLS-Projektgerät gilt die stehende
  Owner-Freigabe oben. Der jeweilige Auftrag benennt weiterhin Wirkung,
  Nachweis und Rückweg; Zugriffe auf andere reale Geräte sind davon nicht
  umfasst.
- Der Scanner kann nach lokalem Trennen weiter senden. Dieser Zustand wird
  sichtbar erklärt; Trennen behauptet keine Änderung am Gerät.
- Keine Rohcaptures in der Versionierung. Vollständige Telegramme dürfen in
  lokalen Entwicklungslogs erscheinen, wenn das für die Protokollanalyse
  erforderlich ist; sie werden nicht ungeprüft in Produktdiagnosen oder
  Release-Artefakte übernommen. Die Standardpasswort-Ausnahme oben macht
  sonstige Secrets nicht veröffentlichbar.
- macOS 12 bleibt Deployment Target. Keine zwingende macOS-13/14-API,
  insbesondere kein SwiftData, kein Observation-Makro und kein importiertes
  macOS-14-`XAirUI`.
- **Owner-Entscheidung 12.10.2026: Dieser Scanner hat 0 % Sicherheitsrelevanz.** Er ist ein Musikinstrument, kein Sicherheitsgerät: keine Schutz- oder Warnfeldfunktion, keine sicherheitsrelevanten Einstellungen, keine geheimen Passwörter. Das Passwort ist der öffentliche PLS-Standardwert `SICK_PLS`. Telegramme, Passwortbytes, Konfigurationsblöcke und Mitschnittinhalte werden vollständig und nachvollziehbar dokumentiert, nichts wird geschwärzt. Die App darf jede Einstellung (auch Wiederanlaufsperre, Felder) selbst setzen.

### Instrumentvertrag

- Das große Messfeld ist die primäre Arbeitsfläche. Die kanonische
  Scanner-Einheit ist Zentimeter; die fachliche Benutzerwelt ist
  ausschließlich polar und zeigt Winkel sowie Radius in Metern
  (`Meter = PLS-Rohdistanz / 100`). Adaptive Ringsektoren sind die einzige
  Zellidentität für Editor, Persistenz und Laufzeitauswertung. Einen XY-Modus
  oder eine umschaltbare zweite Topologie gibt es im Zielprodukt nicht.
- Zoom, Pan, Einpassen, Fokus und gespeicherter Ausschnitt verändern niemals
  Messdaten, Zonen, Felder, Learn-Ergebnis oder Steuerwerte.
- Eine zusätzliche Entfernungskalibrierung über Schutz- oder Warnfelder ist
  **nicht erforderlich**: Einheit und 13-Bit-Distanzdekodierung sind durch den
  PLS-spezifischen SickToolbox-Code, Herstellerunterlagen und reale Profile
  ausreichend belegt. Reale Referenzkörper beziehungsweise 1×1-m-/2×2-m-
  Gerätefelder prüfen optional Maßstab, Winkelrichtung, Ursprung und
  Feldidentität; sie definieren die Meterskala nicht.
- Die musikalischen Flächen liegen auf einem polaren Raster aus adaptiven
  Ringsektoren. Der Benutzer malt und löscht Sektoren mit der Maus; radial
  verdeckte Sektoren lösen nicht gleichzeitig aus.
- Der UI-Scan wird auf höchstens 12,5 Hz aktualisiert. Messaufnahme und
  Audiosteuerung bleiben davon entkoppelt und verarbeiten jedes zugestellte
  Profil. Vorläufig gibt es weder Glättung noch Prognose im Klang- oder
  Darstellungsweg; aktuelle Messwerte wirken direkt.
- Gate stammt nur aus echter Messung, wird nie prognostiziert und nie
  gehalten. Jeder Lebenszyklusweg hat ein definiertes Aus.
- Audio, AU und MIDI erhalten Werte aus genau einem Profileingang und genau
  einer Feld-/Zonenauswertung.

## 2. Historischer Belegstand (23.09.2026)

Diese Tabelle bewahrt den damaligen Umfang einschließlich seiner offenen
Grenzen. Der aktuelle Nachweisstand steht [im Einstieg](#nachweisstand-tragender-produktaussagen);
die alten Zahlen sind keine neue Messung am heutigen Produkt.

| Bereich | Belegt | Offen |
|---|---|---|
| CRC, Framing, B0, RX-Transport | real gegen Gerätebytes; RX-Transport ohne Schreibmethode | keine Daueraussage |
| Metrik und Feldbytes | SickToolbox: PLS-Distanzen in cm; reale B0-Werte plausibel; zwei reale `0x43`-Konturen passen exakt auf 360/90 Segmente plus Eckradius | Winkelursprung/-richtung, Feldidentität und direktes PLS-Lesekommando |
| Commissioning 9600 → 38.400 und B1-Verifikation | real am 22.09.2026 über getrennten TX-Pfad | Neustartpersistenz, B1 bei laufendem Strom und Loginpflicht für MMK bei 38.400 |
| B0-Strom bei 38.400 | einmal real: 90 Punkte, ungefähr 12,5 Hz | fünf Minuten, Batchhäufigkeit, Dauerstabilität |
| Messfeld, Zoom, Einpassen, Zonenbearbeitung | SICK-032b2c einschließlich K1/K2 offline abgenommen | Bild-/Bediennachweis mit realem Profil fehlt |
| Learn | Modell, Kartenbedienung, Kandidatenvorschau und Notice-Host (auch ohne Draft); K2-Capture opak und lesbar; K3 ersetzt das fehlende, echte Grundprofilbild | Lernen mit echten Scannerprofilen fehlt |
| Synth, Sends, AU-Rack | Offline-Rendering und Host-Sonden; Kanalzug, Inserts, Rackmodell mit Bypass (SICK-033a/b) | noch nie real gehört; keine Drittanbieter-AU geladen |
| Steuerkern, Felder | `FieldHit`/`ControlSink`, strip/grid/fan/key vorhanden | kartesischer Rasterpfad und Ebenen/Mischmatrix ohne vollständigen Produktpfad; alte Prognose wird deaktiviert; Bildnachweis fehlt |
| MIDI | Übersetzer bitgenau, Senke am gemeinsamen Steuerweg, CoreMIDI-Transport, Karte mit Panic (SICK-036a) | realer Monitor/Synth fehlt |
| Presets | v1-Format, Migrationsgerüst, atomar, lösen vor setzen, kein Autostart (SICK-037) | Spieltest fehlt |
| Schlaf/Wake, Concurrency | Uhr läuft im Schlaf weiter, Failsafe offline belegt | strikter Build schlägt fehl; Prüfshellskript falsch-grün; Dauerlauf, Budgets, realer Schlaf/Wake fehlen |
| App-Bundle | lokal gestartet; Signier-/Notarisierungsskript als Ownerschritt; Hilfe im Hilfemenü | Signierung und Notarisierung nicht ausgeführt |

Aktuell dokumentierter Prüfstand nach dem Supervisor-Review vom 23.09.2026:
alle Tests grün; Deploymentziel `minos 12.0` am App-Binary bestätigt. Der
isolierte strenge Build schlägt mit fünf Fehlerdiagnosen fehl; das bisherige
Diff-Skript verliert den Build-Exitstatus und meldet deshalb fälschlich null.
Verbindlicher Befund: `.agent_handoff/review-sick-release-big-bang.md`.

## 3. Historischer Architekturentwurf und fortgeführte Verträge

Der Datenflussentwurf ist Herkunft. Der heutige Aufbau steht ausschließlich
[im Einstieg](#ist-architektur-und-nachweisstand). Die fortgeschriebenen
Besitz-/Fehlerverträge und die Lösematrix unten bleiben Vertragsquelle; der
[Neuplan vom 05.10.](.agent_handoff/architektur-neuplan-2026-10-05.md) ist historisch.

### Daten- und Besitzgrenzen

```text
Verbinden ─► ConnectionCoordinator
             ├─ geeigneten B0-Strom übernehmen
             └─ nötigenfalls B1/Login/38.400/MMK ─► Portschluss
                                                   └─► ScanSession

Profile ─► FieldHit-Folge ─► Feld-/Ebenen-Auswertung ─► ControlSnapshot
                                                     ├─► Audio-Senke
                                                     └─► MIDI-Senke

Audio-Senke/MIDI-Steuerung ─► AU-Instrument ─► AU-FX-Slots ─► Gerät
```

Verbindlich:

1. Genau eine `SerialPortOwnership`-Instanz, ein
   `performanceProfiles`-Abonnement und ein `portReleased`-Abonnement.
2. Der Verbindungsorchestrator hält nur Ablauf und Fristen; Besitz und reale
   Sitzung werden nicht kopiert.
3. `ready` entsteht erst nach einem CRC-validen Profil. Ein offener Port ist
   kein Betriebsbeleg.
4. TX schließt seinen Port vollständig, bevor RX Besitz beanspruchen darf.
5. SwiftUI löst keine Transportoperation direkt aus.

Die AU-Wartegrenze ist davon getrennt: Fehlt das geroutete AU-Instrument oder
ist es noch nicht bereit, gilt der AU-Ausgang als **nicht gebunden**. Die
Dokumentbarriere schließt trotzdem und nimmt weitere Profile an; Noten ohne
bereites AU werden als „Plug-in-Ausgang nicht bereit“ gezählt. Sobald das
Instrument vorbereitet ist, bindet der bestehende Ressourcen-/Snapshotweg
nach. Für die Annahme von Messungen ist kein manueller AU-Ladevorgang nötig;
zum Spielen bleibt ein bereites AU erforderlich.

Ein AU-Send gilt bei stehender Engine als `.unbound`, für Noten und
Parameter. Die native Konfigurationsmeldung sperrt die alte Bindung schon
beim Eingang, bevor Main den Graphen wieder aufbaut. Fade-Enden werden
außerhalb von Main anhand des atomaren Render-Belegs geprüft, mit höchstens
80 ms Wartezeit und einer Abschlusszustellung auf Main. Der Callback-Wait
für den eigenen Fade-AU-Aufbau auf Main ist auf 50 ms begrenzt; ein Timeout
wird sichtbar gemeldet, verspätete Ergebnisse verworfen, ein erneuter
Aufbau bleibt möglich. Fremd-AU-Instanziierung bleibt asynchron.
Host-Veröffentlichungen erfassen leere Plug-in-Zustände einmal je Instanz;
Speichern und Duplizieren lesen weiterhin den vollständigen aktuellen Zustand.
Dirty-Anzeige, Lade- und Beendigungsentscheidungen vergleichen den gespeicherten
Dokumentinhalt und die Beschreibung ohne frische AU-Zustandsabfrage.
Aktuell offene Plugin-Fenster zählen bei Dirty-/Lade-/Beendigungsprüfungen
als mögliche ungespeicherte Änderung (billige Fensterabfrage über alle Kanäle).
Plugin-Änderungen zählen nach dem Schließen eines Plugin-Fensters weiter als
ungespeichert; Save/Load setzt die Ereignisreferenz zurück. Ein Fensterschluss
kann daher auch ohne bearbeiteten Parameter eine Speicherfrage auslösen.
Eine offene Ladeentscheidung gilt für Dokumentrevision, Beschreibung und
Mischpult-/Plugin-Änderungsgeneration. Kanaländerungen und Plugin-Fensterschluss
erhöhen diese Generation. Save und Don't Save fragen bei einer inzwischen
geänderten Marke oder geändertem Offen-Zustand einmal pro Klick erneut („Changed meanwhile – choose again“).
Eine veraltete Alert-ID entscheidet über die aktuelle offene Ladeanfrage.
Cancel und Alert-Schließen verwerfen sie unabhängig von ID oder Marken;
sie laden und speichern nichts. Frische flüchtige Plugin-Bytes lösen weder
eine Speicherfrage noch eine Wiederholung aus.

### Feld- und Insertmodell

Die räumliche Produktdomäne ist polar: Scanwinkel und Zentimeterdistanz
adressieren direkt einen adaptiven Ringsektor. Sektorbreiten werden so
unterteilt, dass ihre äußere Bogenbreite höchstens das 1,5-Fache ihrer radialen
Höhe beträgt; bemalte Sektoren bilden musikalische Flächen. Geräteinterne Schutz-
und Warnfelder werden, sobald ihr Read-back belegt ist, ausschließlich als
separate, gesperrte Referenzebene darübergelegt.

Ein Channelstrip-Eintrag repräsentiert ein **Ziel**, nicht zugleich Quelle,
Prozessor und Ausgang:

- **Kontrollziel:** Pitch, Volume, Filter, Gate oder ein später ausdrücklich
  definiertes AU-Parameterziel.
  Seine Karte enthält Ebenen und räumliche Felder, die genau dieses Ziel
  steuern.
- **Prozessor:** AU-Instrument oder AU-FX-Slot. Ein/Aus bedeutet Aktivierung
  bzw. Bypass; AU-Bypass mutiert den laufenden Graphen nicht.
- **Ausgang:** Audio oder MIDI. Ein/Aus startet bzw. stoppt ausdrücklich;
  MIDI-Aus und Zielverlust lösen Note-Off/Panic aus.

`FieldHit` ist eine geordnete Folge gemessener Treffer pro Profil und trägt
mindestens normierten Messpunktindex, linearen Rohwert, Flags und stabile
Reihenfolge. Die erste Produktversion verfolgt keine mehreren Hände als
getrennte Identitäten. Jedes Feld wählt aus seinen Treffern nach einer
sichtbaren, getesteten Politik genau einen effektiven Treffer. Für bestehende
Zonen bleibt „kleinster Rohwert gewinnt“ bitgleich. Überlappung und
Ebenenmischung verwenden geschlossene, parameterabhängige Regeln ohne
`default`-Fallback.

Werte sind typisiert als `continuous`, `discrete` oder `gate`. Alle drei
Typen verwenden vorläufig den aktuellen Messwert direkt; kein Wert erreicht
im aktiven Produktpfad Predictor oder Glättung. Pitch wird vor Raster und MIDI
als Halbtöne plus Cent relativ zur Grundnote vereinheitlicht.

### Vollständige Lösematrix

Vor MIDI und Presets müssen Audio und alle Ausgabesenken mindestens diese
Ursachen explizit behandeln:

| Ursache | Pflichtwirkung |
|---|---|
| Feld/Zone verlassen | gewöhnliche Gate/Note aus; Halten/Toggle siehe Vertrag unten |
| Unfreiwilliger Eingangsverlust (`stale`, `inputLost`, Sitzungsende durch Fehler) | gewöhnliche Noten und Overlap-Enden aus; bewusste Halte- und Toggle-Noten bleiben (Owner A, 10.10.2026) |
| Profilrückstau über 2 s (50 wartende Profile bei belegten 25 Hz, 90/361 Punkte; zusätzlich Altersprüfung vor Verarbeitung) | alle aktiven Noten einschließlich Hold/Toggle aus; wartende Profile verwerfen, Bedien-/Lebenszyklusbefehle erhalten; sichtbare Meldung auch bei blockierter Q; nach Abbau neue Messungen wieder spielbar |
| Zone, Feld, Ebene oder Kontrollziel deaktiviert | Gate/Note aus |
| Rollen-/Slot-Abwahl | Gate/Note aus |
| Presetwechsel oder ungültiges Preset | aktive Ausgänge zuerst lösen; kein Teilzustand |
| MIDI-Zielverlust | Note-Off soweit möglich, danach Panic-Zustand sichtbar |
| MIDI-Wiederanbindung/Zielwechsel nach einer Bindung | am neuen Ziel zuerst CC123 auf allen 16 Kanälen, einschließlich früher benutzter Kanäle; fehlgeschlagenen Reset vor neuen Noten wiederholen |
| Audio-Geräte-/Sampleratenwechsel oder native Engine-Konfigurationsmeldung | nur Audio-Noten einschließlich Hold/Toggle lösen und Audio-CC123 senden soweit gebunden; nach abgewiesenem Lösen die erhaltene AU beim Wiederbinden vor neuen Noten mit CC123 zurücksetzen; MIDI-Noten und MIDI-Gates erhalten |
| Audio-/MIDI-Stop | Gate aus bzw. Panic |
| Systemschlaf/Wake | beim Wake vor Wiederaufnahme lösen und neu synchronisieren |
| App-Beenden | bestmöglicher Stop/Panic, ohne den Abschluss zu blockieren |

`holdUntilNext` bleibt kanalweit: jeder neue Klang desselben Ausgabekanals
ersetzt im selben Frame den vollständigen bisherigen Haltebesitz, auch wenn
dessen Zone weiter berührt wird. Je Ziel (AU-Strip bzw. MIDI-Endpunkt) und
MIDI-Kanal gibt es höchstens einen Haltebesitzer. Neue Eintritte konkurrieren
vor der Ausgabe: der Repräsentant der zum gewählten Träger gehörenden Hand
bestimmt den Vorrang. Eine Zone, die ihn enthält, gewinnt; andernfalls gilt
der kleinste quadratische metrische Abstand zur gewählten Zelle. Jede Hand
behält ihren eigenen Repräsentanten; gleiche Priorität bzw. fehlende
Repräsentanten fallen stabil auf Dokument-Ebenen-/Routingreihenfolge zurück.
Die Zuordnung der Hand bleibt als Messungsordnung im gewählten Träger;
der Ledger erhält ausschließlich die bereits berechnete Priorität. Alle Eintritte werden verbraucht; eine
abgelöste oder unterlegene Zone gewinnt erst nach gemessenem Verlassen und
neuem Eintritt wieder, oder mit einem neuen Klang. Owner-Präzisierung
18.10. (Mitschnitt Am/C): Verlässt der gemessene Kontakt den aktuellen
Haltebesitzer und bleibt ein anderer bereits betreten, gilt dieser freigelegte
Nachbar als neuer Klang; der vorherige Akkord bleibt dort nicht hängen.
Die Übergabe verlangt einen unmittelbar vorher gemessenen Besitzerkontakt
und einen räumlich fortgesetzten Handkontakt (höchstens 10 cm zwischen den
gewählten Feinzellen). Ein späterer Kontakt nach Lücke oder ein größerer
Sprung aktiviert keinen verbrauchten Verlierer. Ohne solchen Nachbarn hält der Akkord weiter. Weiteres Verweilen bei
weiter gemessenem Gewinner erzeugt keinen Wechsel. Ein Install darf abgelöste Besitzer nicht über gemeinsame
Tonhöhen wiederherstellen.
Die Feldanzeige übernimmt gehaltene Zellen aus dem Ledger im bestehenden
Anzeigeframe: Bei reinen Hold-Ebenen leuchten nur klingende Besitzer,
nicht unterlegene geometrische Kandidaten. Handkontakt des klingenden
Besitzers bleibt voll hervorgehoben, Hold/Toggle ohne Hand
erscheint in derselben Farbe mit ruhiger Füllung, Kontur und einer eindeutigen
Beschriftung des klingenden Ebenennamens (auch bei überlappenden Masken). Toggle zeigt
die tatsächlich angeschlagene Zelle, während seine Flächenidentität für
Eintritt/Schutzzeit unverändert bleibt. Eingangsverlust erhält bewusste
Latches; explizite Lösewege entfernen auch deren Anzeige.

Der „Output Monitor“ (Fenstermenü, ⌘⇧M, Klaviatursymbol im Kopf) liest
bestätigte Port-Sendungen. Pro Port liegen vorbereitete numerische Noten-/CC-
Tabellen und ein Ring für 200 Ereignisse auf Q; unveränderte Tabellen werden
nicht erneut kopiert. Geschlossen/verdecktes Fenster deaktiviert Erfassung
und UI-Abonnement; Wiederöffnen übernimmt die noch offenen Notenbelege,
CC-/Ereignisgeschichte beginnt mit der neuen Beobachtung. Die gemeinsame
Anzeigepumpe liefert die Werte; der Monitor begrenzt seine Publikation auf
höchstens 30 Hz. Farben/Latch-Markierung stammen aus dem Ledgerbesitz,
Tonhöhen/Velocity/Controllerwerte aus erfolgreichen Sendungen. Unzuordenbare
Belege erscheinen orange. Tempo/Clock zeigen den Transportstatus, keine
Bestätigung einzelner Clock-Ticks. Filter begrenzen die sichtbaren Ausgänge
auf die Ziele/Kanäle der gewählten Ebene; gemeinsam verwendete Ziele bleiben
physisch gemeinsame Ausgänge. Der Monitor verändert weder Gate noch Ausgabe.

Die Ebenenwahl „Common notes“ hält mit `keep` (Vorgabe, auch bei Altdateien ohne
`commonNotes`) gemeinsame Töne ohne erneuten Anschlag. `retrigger` sendet beim
neuen Klang für gemeinsame Töne unmittelbar Note-Off und Note-On. Sie gilt auch
beim Legato-Wechsel und beim Einschalten einer weiteren Toggle-Fläche;
Toggle-Aus bleibt besitzabhängig. Die Piktogramme neben Transition besitzen
Tooltips und sind in Perform bzw. bei gesperrter Ebene gesperrt.
„Single note“ spielt einen gewählten Ton mit
Velocity in jeder Zelle der Ebene; Übergänge bleiben Ebeneneigenschaft,
auch für Zell-Overrides. Scale bleibt je Feinsegment abgestuft.
`toggle` schaltet Ton- und Akkordflächen unabhängig: eine kantenverbundene
gezeichnete Fläche mit gleichen Zellinhalten bildet einen Eintrittsschlüssel,
kein 1-cm-/0,5°-Feinsegment. Unterschiedliche Overrides und getrennte Flächen
bleiben unabhängig. Erster frischer gemessener Eintritt an, nächster Eintritt
nach gemessenem Verlassen aus. Bewegung innerhalb der Fläche und weitere
Messstrahlen darin erzeugen keinen Eintritt. Nach jedem Umschalten (an oder
aus) schützt „Toggle guard“ die Fläche für die Ebenenvorgabe von 0–2 s;
neue Ebenen und Werkspresets beginnen mit 0,5 s, Altdateien ohne das Feld
`toggleGuardSeconds` laden mit 0 (bisheriges Verhalten). Die Schutzzeit gilt
je Eintrittsschlüssel, nicht global je Ebene, und verwendet ausschließlich
die monotone Profilzeit der Runtime. Der erste Eintritt schaltet sofort.
Ein Eintritt innerhalb der Schutzzeit wird verworfen und auch nach Ablauf
bei Verweilen nicht nachgeholt; erst gemessenes Verlassen und ein neuer
Eintritt können wieder umschalten. 0 deaktiviert den Schutz. Der Regler
steht neben Transition, ist nur bei Toggle aktiv und in Perform gesperrt.
Alle expliziten Lösewege einschließlich „Release layer“, Löschen,
Verschieben und Umrouten wirken sofort, unabhängig von der Schutzzeit;
unfreiwilliger Eingangsverlust erhält Besitz und gemessene Eintrittssperren
einschließlich Schutzzeit nach dem bestehenden Owner-A-Vertrag.
Die Default-Aufteilung neu/alt bleibt beim Owner-Test zu bestätigen.
Scale und Random scale bieten
kein Toggle; bestehende Dokumente werden beim Laden auf Retrigger gesetzt,
mit sichtbarem Hinweis (Owner 12.10.2026). Verweilen,
Verlassen und andere Zellen beenden Toggle-Noten nicht. Geteilte Noten erzeugen
ein Note-On und erst beim letzten Besitzer ein Note-Off. Löschen, Verschieben
oder Umrouten löst betroffene Toggle-Zellen. „Release layer“ ist eine
Steuerebene mit Ebenenvorgabe und Ziel je Zelle; frischer Eintritt löst nur
Halte- und Toggle-Besitz der Zielebene. Fehlende Ziele („missing layer“) wirken
nicht; Steuerebenen gehören nicht in Szenen. Nach Eingangsverlust laufen
bewusste Halte-/Toggle-Noten weiter; Wiederkehr ersetzt keine gemessene
Verlassenskante. PANIC, Stopp, Preset-/Instrumentwechsel, bewusstes Trennen,
Eingangswechsel, Schlaf und Beenden lösen alles. Fehler und Nutzerende werden
typisiert unterschieden. Gate, neue Note-On und Lösekanten entstehen nie aus
Prognose.

Die UI bietet spätestens mit SICK-036c einen sichtbaren Panic-Knopf.

## 4. UX-Verträge

### Verbindung

Der Spielweg zeigt nur Portauswahl, Steckersymbol und Status. `Automatisch`
prüft Kandidaten sequenziell und verwendet passiven Strom, B1 sowie
Commissioning nur soweit nötig. Mögliche Zustände sind mindestens:

- nicht verbunden;
- Scanner wird gesucht, mit Portfortschritt;
- Identität wird geprüft;
- Scanner wird auf 38.400/MMK vorbereitet;
- bereit mit beobachteter Rate, Punktzahl und rollierender Profilrate;
- Passwort oder Vorbereitung benötigt, mit konkreter nächster Handlung;
- Port belegt;
- Strom verloren;
- wird getrennt;
- getrennt — Scanner kann weiter senden.

Der Standardweg braucht keinen zweiten Vorbereitungsdialog. Eine
Support-/Einstellungsansicht darf Diagnose, Passwortpflege und einen gezielten
erneuten Vorbereitungsversuch anbieten. Der Status zeigt aktive Gerätewirkung
und Abbruchverhalten, ohne den Musiker mit Telegramm- oder Bauddetails zu
belasten. Kein Passwort erscheint im Zustandsmodell, Audit oder Export.

### Learn, Fokus und kartesischer Arbeitsbereich

Eine neue Zone ist zunächst ein eigener `LearnDraft`, keine formal gültige
und keine laufzeitwirksame `Zone`.

- Ohne Profil: Entwurf sichtbar, „Warte auf Messwerte“, Abbrechen und Löschen
  möglich; keine erfundene Geometrie.
- Mit erstem stabilen Profil: genau einmaliges Einpassen mit dokumentierter
  Polsterung und Mindestspanne.
- Nach manuellem Zoom oder Pan: kein automatisches Überschreiben der
  Benutzeransicht; erneutes Einpassen nur per ausdrücklicher Aktion.
- Learn zeigt Grundprofil, aktuelle Messung, Bewegungscluster und Vorschau
  unterscheidbar im Messfeld.
- Übernehmen erzeugt eine valide, ausgeschaltete Zone, wählt sie aus und
  führt einmalig Messung plus Zone in den sichtbaren Ausschnitt.
- Abbruch, Löschen, erneuter Start und Verbindungsverlust haben getrennte,
  verständliche Endzustände.
- Eine manuelle Zonenbearbeitung ist erst möglich, sobald valide Grenzen
  existieren; sie ist kein versteckter Fernbereich-Default.
- [ERSETZT durch Ownerentscheidung Flächeneditor (FLÄCHENEDITOR-KERN-1): Flächen sind
  Formen mit eigener Zuordnung und Achse; Zellen sind abgeleitet. Zellmalen bleibt
  nur für exakte Altmasken. Frühere Fassung:] Die neue Flächenbearbeitung malt oder löscht quadratische Rasterzellen.
  Primärdrag malt, ein klarer Löschmodus entfernt; Pan hat ein eigenes
  Werkzeug beziehungsweise eine eindeutige Modifikatortaste und darf niemals
  versehentlich Zellen verändern.
- [Stand FLÄCHENEDITOR-UI-1: die Flächenoberfläche ist umgesetzt; das Zellraster ist dort nur
  ein optionales Messraster, Zellmalen liegt im Expertenmodus „Cell editor (advanced)“.]
- Rasterweite, Zoom und Pan bleiben unabhängig. Eine Änderung der Rasterweite
  transformiert vorhandene Flächen nicht still, sondern verlangt eine
  sichtbare Übernahme- oder Neuanlageentscheidung.

### Channelstrip

HELMUT R340 ist die Gesamtbild-, R315 die Zeilenreferenz. Geometrie und Tokens
werden für macOS 12 neu umgesetzt. Verbindliche Außenmaße sind 176 pt für den
Inspector, 40 pt für die externe dB-Skalenrinne und 67 pt für den Strip. Der
korrekte geriffelte 17 × 35-pt-Strip-Fadergriff ist zugleich der einzige
Fadergriff des Inspectors; der in HELMUT noch abweichende Inspector-Griff ist
ausdrücklich keine Referenz. Die 16-pt-Referenzzeile ist kein Freibrief
für zu kleine Bedienziele: Fokus, Tastaturbedienung, Tooltip/Accessibility und
die reale klickbare Fläche werden separat abgenommen. Insertzeilen folgen dem
HELMUT-R315-Vertrag: in Ruhe nur der Name, im Hover drei unveränderte
Teilflächen (18 pt / Rest / 18 pt) für ON/OFF, Einstellungen und Auswahl mit
0,5-pt-Trennern. Die drei Aktionen müssen einzeln per VoiceOver und UI-Test
adressierbar sein. Zustandswechsel dürfen Außenmaße nicht verschieben.
Die rechte Arbeitszone wird vollständig neu komponiert: ein optisch und
funktional an HELMUT/Logic orientierter einzelner Kanalzug plus eigener
Inspectorplatz. Die Aufgabe des Inspectors ist noch nicht festgelegt; er darf
bis dahin keine provisorische Fachkarte vortäuschen. Der Instrument-Slot und
alle Audio-FX-Slots beginnen leer und bieten ausschließlich installierte
Audio Units des passenden Typs an. Es gibt kein Sammel-Rack und keine eigenen
Synth-, Delay- oder Hall-Inserts. Audio-Unit-Herstelleroberflächen werden als
eigene Plugin-Fenster gehostet.
Die Verdrahtung einzelner
Kanalzugmodule ist ein Folgeschritt und darf das Layout nicht mit provisorischen
Fachkarten überladen.

### Detektionsstufen

`DetectionConfiguration` enthält Room, Beams/MMK, Groups, Edge, Core,
Representative, Time und Cells als eigene Konfigurationswerte. Jede Stufe
besitzt Standard-/Altwerte, flache historische Codable-Schlüssel, reine
Berechnungen und ihre Reglerbeschreibungen (Name, Symbol, Tooltip, Bereich,
Einheit, Perform-Sperre und vorhandenes Overlay). Die bisherigen Feldnamen
bleiben als berechnete Zugriffe erhalten. Raumkontur bleibt Sitzungseinstellung;
`ProfileRecording` speichert ihren Filter unverändert separat. Der gemeinsame
Start- und Resetwert der Konturtoleranz ist 5 cm (Owner 18.10.2026),
der Bereich bleibt 1…30 cm. Explizite Werte in Aufnahmen bleiben erhalten.
Ownerbestätigung 18.10.2026: Der Sitzungsvertrag bleibt bestehen; historische
`roomFilter`-Werte in Instrumenten/Presets werden weiterhin ignoriert.
Aktuelle Werkspresets werden ohne dieses ausgemusterte Feld generiert.

`DetectionStagePlan` bestimmt die musikalische Reihenfolge: Room → Beams →
Groups → Edge → Winkeltrennung → Core → Time → Representative → Cells.
Mit Core Off liegt Time historisch vor Beams. Historie, Snap und Bestätigung
bleiben beim gemeinsamen Pipeline-Besitzer. Musik und Anzeige rufen dieselben
Stufenberechnungen auf; die Reglerlisten bestimmen keine zweite Detektion.
Das Presetformat bleibt flach und bytegleich. Die alten V3-Zellmengen haben
weiter ihre historische variable Array-Reihenfolge; vollständige Vorher-/Nachher-
Bytevergleiche verwenden `SWIFT_DETERMINISTIC_HASHING=1`, ohne den Encoder zu ändern.

Teil B ist ausschließlich eine Offline-Vorschau aus echten SwiftUI-Reglern
mit explizitem `detectionStagePreview`-Eingang; der App-Aufrufer setzt ihn nicht.
Freigabe und Fertigstellung der Oberfläche sowie die späteren Laienregler
(Teil C) stehen aus. Der aktive Auftrag bestimmt die nächste Runde.

Im Performance-Modus sind szenenstumme Ebenen einschließlich Zellen,
Beschriftungen, Snap- und Halten-Anzeigen ausgeblendet. Editieren zeigt sie
standardmäßig gedimmt; „Show inactive scene layers“ ist ein flüchtiger
Anzeigeschalter. Szenenwechsel aktualisieren Sichtbarkeit und Beschriftungen
mit der vorhandenen Szenenprojektion, ohne neue Feldgeometrie. Nur dargestellte
Ebenen nehmen an der Beschriftungsplatzierung teil; die Schrift schrumpft bis
10 pt und wird bei weiterem Platzmangel einzeilig gekürzt.

Szenenflächen (Next, Previous, benannte Szene) schalten für Scanner und Audition
sofort beim akzeptierten Eintritt, genau einmal bis zum Verlassen. Alte
`dwellSeconds`-Werte bleiben lesbar, werden in der Laufzeit aber ignoriert;
neue Zuweisungen und Werkspresets verwenden 0. Die konfigurierte
Profilbestätigung der Detektion bleibt vorgelagert erhalten.

„Audition“ (P) ist ein gesperrtes Bearbeitungswerkzeug in Perform. Drücken
und Ziehen liefern eine zusätzliche akzeptierte Hand nach der Detektion an Q,
vor der gemeinsamen `CompiledInstrument.evaluate`-/Ledger-Auswertung. Der
Mausabstand liefert den Continuous-Wert. Scanner sind optional; ein
Scannerverlust entfernt nur gemessene Hände. Loslassen, Werkzeug-/Fensterwechsel,
App-Deaktivierung, Esc, Preset-/Szenenwechsel, PANIC, Stopp, Schlafen und Beenden
entfernen die virtuelle Hand; Halten/Toggle folgen dabei ihren normalen Regeln.
Der vorhandene Q-Deadlineweg wertet den akzeptierten Zeiger während des
Drückens weiter aus, ohne Scannerprofile
zu erzeugen. Zeiger und Sichtbarkeit gehören zum Canvas-Zustand; sie publizieren
keine Dokumentänderung. Der gelbe Handzeiger kennzeichnet ausschließlich diese virtuelle Hand.
Die Detektionsvorschau/Probe-Hände bleiben reine Anzeige.

### Wirkung der Detektionsregler

Hover oder Drehen zeigt im Messfeld genau das aktive Regler-Overlay, mit
Vorrang des gezogenen Reglers. Ende von Hover/Zug, Einklappen und Perform
entfernen es sofort. Konturtoleranz setzt eine passende, aktivierte Aufnahme
voraus; ihr Band liegt ± Toleranz um die Wand und färbt darin liegende echte
Punkte grau. Die übrigen Overlays begleiten die Probe-Hände. Gruppenzugehörigkeit
und Verschmelzung stammen aus dem Produktdetektor; echte Punktfarben stammen
aus einem separaten Lauf mit dem unveränderten realen Profil. Die Anzeige
übermittelt keine Profile, Zellen oder Ereignisse an den spielenden Runtime-Weg.

Die Zeitprobe speist acht bewegte synthetische Profile in eine lokale
Detektionshistorie. Confirm zeigt an drei Händen einen routingsfreien,
synthetischen Zwei-Zellen-Wechsel durch den echten Selector (n/N, farbig erst
bei vollzogener Umschaltung), unabhängig davon, ob dort eine musikalische
Zelle gemalt ist. Zelllinien zeigen innen den Snap-Abstand und außen den
Hold-Abstand als metrische Hilfsmaße; sie ändern die bestehende Snap-Geometrie
und das radiale kontinuierliche Totband nicht. MMK-Fächer verwenden dieselbe
Fensterbreitenfunktion wie die Detektion; Weichheit erscheint als Randabfall.

Probe-Lagen folgen dem freien Raum je Winkelsektor: passende Kontur,
aktuelle Messwerte und sichtbarer Viewport begrenzen die Entfernung. Drei
Gruppen liegen ungefähr bei 30/55/80 % der freien Distanz links, mittig und
rechts. Reserve für Randtiefe, Konturtoleranz und den ganzen Offset-Bereich
verhindert Wandtreffer; reicht der Platz nicht, entfällt eine ganze Gruppe.
Synthetische Silhouetten teilen keine Messstrahlen. Abstandsangaben zeigen
die tatsächliche Lage; ganze Textkästen bleiben kollisionsfrei im Feld.
Representative/Offset zeigen die tatsächlichen Gruppen-/Kernpunkte der
Stufen und einen Pfeil vom unverschobenen zum verschobenen Spielpunkt.
Die benutzte Punktzahl steht am Repräsentanten; mit schmalem Core können
Mean und Median denselben gemessenen Punkt wählen.
Min. angle/Minimum points klassifizieren nur Punkte nach dem Raumfilter;
behaltene Objekte zeigen einen schwachen Winkelschatten. MMK-Fenster sind
gefüllte Keile mit dem Gewicht der Beams-Stufe; ein dimensionsloses
Gewichtsdiagramm macht den Randverlauf auch bei kleinen Fenstern lesbar.
Die Glättungsprobe zeigt verbundene, nach Alter verblassende Linien und
unterscheidet rohe von geglätteten Repräsentanten über die Fensterlänge.
Diese Darstellung bleibt ausschließlich beim separaten Anzeigedetektor.

### Randpunkte, Spielkern und Profilbeleg

Groups besitzt „Edge points“ (Off / 1 / 2) und „Core width“ (Off / 1–10 cm).
Edge points entfernt je Ende höchstens die gewählte Zahl von Punkten, wenn
der Endpunkt mehr als 3 cm weiter entfernt ist als sein innerer Nachbar.
Mindestens max(1, Minimum points) bleiben erhalten; näher liegende Endpunkte
werden nie entfernt. Die Schwelle ist vorläufig: synthetisch geprüft,
mit Owner-Aufnahmen noch zu bestätigen.

Nach dem Kürzen bestimmt der mittlere gemessene Gruppenstrahl die
Kernpeilung. Zum Kern gehören Punkte mit tangentialem Abstand ≤ halbe
Kernbreite; bei leerem Kern bleibt der mittlere Strahl. Nur der Kern speist
Repräsentant, zeitliche Glättung und Zellwahl. Die Scheibe zeigt das ganze
gekürzte Objekt und darin den helleren metrischen Kernstreifen. Target width
bleibt unabhängig das räumliche MMK-Fenster je Strahl. Mit Core Off bleibt
die historische Reihenfolge der Strahlglättung erhalten. Neue Dokumente und
Werkspresets starten mit Edge 1 / Core 3 cm; fehlende Felder in Altdateien
bedeuten Off und bleiben beim Speichern feldlos. Beide Regler sind in Perform
gesperrt; Probe-Hände benutzen dieselbe Anzeige-Pipeline und zeigen verworfene
Rand- und Seitenpunkte blass.

„Record profiles“ im Scanner-Development-Fenster kopiert zehn Sekunden vom
einzigen vorhandenen Profilabonnement auf eine eigene Queue. Das JSON enthält
Rohmessungen einschließlich Flags, Geometrie, Sitzung, Sequenz, monotone Zeit,
Detektionskonfiguration und vorhandene Raumkontur, keine Telegrammbytes.
Ziel: `~/Library/Application Support/Planarium/Recordings/<Zeit>-<ID>.json`.
Aufnahme, Fortschritt und Finder-Verweis sind auch in Perform erlaubt;
Abbruch, Verbindungsende, Sitzungswechsel, fehlende Profile und Schreibfehler
werden sichtbar. Die Aufnahme öffnet keinen Port und ändert keinen Ausgang.
Das versionierte Format wird durch den opt-in-Test
`EdgePointCoreTests.testOptInOwnerRecordingMetrics` mit
`PLANARIUM_RECORDING=<Pfad>` ausgewertet: nächstes Objekt, Scheibendurchmesser
(Median/p95/Max) und Repräsentantensprung (Median/p95) für Edge Off/1/2 ×
Core Off/2/3/5 cm bei den übrigen aufgenommenen Preseteinstellungen.
Reale Owner-Scans und die daraus abgeleitete Schwellenbewertung fehlen noch.

### Diagnose und Latenz

Ein einziges Supportfenster bündelt Evidenzkarte, Ratendiagnose, redigiertes
Audit und aggregierten Export. „Latenz“ wird getrennt benannt:

- Profilabstand und Batchdiagnose;
- **Steuerpfad-Latenz** von Ingest bis Parameterübergabe;
- hörbare Ende-zu-Ende-Latenz nur, wenn sie mit Audio-I/O tatsächlich gemessen
  wurde.

## 5. Historische Slice-Details (keine Ausführungsreihenfolge)

Die gesamte Folge steht in `END_PRODUCT_ROADMAP.md`. Die nächsten Runden sind
hier ausführlich genug beschrieben, um daraus jeweils einen Auftrag zu
schneiden.

### SICK-032b2c — planarer Canvas-Viewport *(abgenommen)*

Der Slice ist einschließlich der Korrekturen K1/K2 abgenommen. Zentrierter
isotroper Canvas, gemeinsamer Zeichenclip, analytische Zonen-Sichtbarkeit und
an `canvasRect` gebundene Gesten sind durch Codeprüfung, Gegenproben,
vollständige Tests und strengen Build bestätigt.

### SICK-032c3a — Learn-Entwurf und Fokusmodell *(abgenommen)*

- **Eine Frage:** Wie existieren neue Zonen sicher, bevor Learn valide Grenzen
  geliefert hat?
- **Umfang:** reiner `LearnDraft`-Lebenszyklus; relevanter Profilbereich;
  einmalige Auto-Fit-/Fokusentscheidung; Padding, Mindestspanne und
  Ausreißerregel; Abbruch/Löschen/Neustart/Verbindungsverlust.
- **Abnahme:** Kein Draft erreicht Gate, Mapping oder Audio. Profil `21...169`
  erzeugt nie still eine Zone `1000...4000`. Manuelles Navigieren sperrt
  weiteres Auto-Fit bis zum ausdrücklichen Einpassen. Gegenproben für fehlendes
  Profil, Ausreißer und bereits vorhandene Ansicht.
- **Nicht enthalten:** SwiftUI-Komposition, Scanner, Port, TX, neue
  Learn-Heuristik oder Audio.

### SICK-032c3b — sichtbares Learn im Messfeld *(einschließlich K1/K2/K3 abgenommen)*

- **Eine Frage:** Versteht der Spieler jeden Learn-Schritt und sieht er das
  räumliche Ergebnis dort, wo er spielt?
- **Umfang:** nichtmodale Schrittanzeige, Grundprofil, Messung, Cluster,
  Vorschau, Draftkarte und einmaliger Fokus während des laufenden Entwurfs;
  die Übernahme selbst verändert den Ausschnitt nicht erneut.
- **Abnahme:** Bild-/Bediennachweis für Warten, Grundprofil, Bewegung,
  Vorschlag, Verweigerung, Abbruch, Verbindungsverlust und Übernahme. Aktivierung
  bleibt aus; Viewportänderung lässt Fachwerte bitgleich.
- **Nicht enthalten:** neue Heuristik, Meter, Port/TX, Audio oder Feldsystem.
- **Umgesetzt:** `LearnDraftCardView` (nichtmodal, im Messfeldstrang),
  `LearnCandidatePreviewView` teilt sich mit `ZoneOverlayView` die neue,
  gemeinsame `ZoneSectorGeometryFactory` (`SickPLSMonitorKit`) — keine zweite
  Formel, numerisch belegt (`ZoneSectorGeometryTests`). Fokus ausschließlich
  über `resolveLearnDraftFocus(_:within:)`; „tatsächlich wirksam" entscheidet
  `ScanFieldViewState` (Bool-Rückgabe je Werkzeug), nicht eine zweite
  SwiftUI-Heuristik. Präsentations-/Aktionsvertrag erschöpfend geprüft
  (`LearnDraftPresentationExhaustiveTests`, alle 7 erreichbaren
  `ZoneLearningPhase`-Fälle).
- **K1 fachlich akzeptiert:** `LearnDraftSurface` (`SickPLSPerformanceSession`) trifft
  die Host-Entscheidung für `learnDraftNotice` einmal, pur; mit Draft in der
  Karte, ohne Draft in der neuen `LearnDraftNoticeBarView` im Messfeldbereich
  — strukturell nie doppelt. Der app-basierte K1-Bildsatz enthält echte
  native Buttons, ist aber großflächig schwarz/transparent und belegt weder
  alle Pflichttexte noch die vollständige schmale Stapelkomposition.
  Supervisor-Review: `.agent_handoff/review-sick-032c3b-k1.md`; K2 erzeugt
  ausschließlich den vollständig lesbaren fensterbasierten Nachweis.
- **K2 fachlich akzeptiert bis auf ein Bild:** `.agent_handoff/
  review-sick-032c3b-k2.md` akzeptierte elf der zwölf K2-Bilder, die
  Capturetechnik (`CALayer.render(in:)`), Notice-Host, Fokus, Geometrie,
  Navigationssperre und Übernahme vollständig; Bild 2 zeigte aber
  `.collectingMovement` statt des behaupteten `.collectingBaseline`, weil
  zwanzig ruhige Profile die fünf-Profil-Grundfensterschwelle
  (`ZoneLearningConfiguration.default.baselineProfileCount`) überschritten.
  **SICK-032c3b-K3 ersetzt genau dieses eine Bild** durch eine Aufnahme mit
  exakt einem eingespeisten Profil (Read-Script strukturell auf ein Frame
  begrenzt) — „Grundprofil 1 von 5" real erreicht und im Bild lesbar. Alle
  elf übrigen K2-Bilder, Produktcode und Tests unverändert. Details:
  `.agent_handoff/sick-032c3b-k2-visual-proof.md` (in-place korrigiert,
  Abschnitt „Korrektur SICK-032c3b-K3").
- **SICK-032c3b vollständig abgenommen:** Der Supervisor hat das ersetzte
  Bild in Originalauflösung geprüft: sichtbarer Produktzustand
  `.collectingBaseline`, „Grundprofil 1 von 5“, opak und vollständig
  gezeichnet. Temporärer Harness entfernt; 1759 Tests, strenger Build und
  macOS 12 grün. Review: `.agent_handoff/review-sick-032c3b-k3.md`.

### SICK-0330r — Verbindungspolitik und minimal nötige Gerätewirkung *(einschließlich K1/K2 abgenommen)*

- **Eine Frage:** Welche kleinste Wirkung ist nötig, um nach einem
  `Verbinden`-Klick zu einem echten Messstrom zu kommen?
- **Umfang:** reines Entscheidungsmodell für expliziten Port und sequenzielle
  Automatik: vorhandenen B0-Strom übernehmen, B1-Identität prüfen, vorhandene
  38.400-Konfiguration erkennen oder Commissioning anfordern; Abbruch,
  Portfehler, Stromverlust und Portfreigabe.
- **Abnahme:** keine I/O im Reducer; vollständige Tabelle ohne `default`;
  geeigneter B0-Strom löst kein TX aus, fehlender Strom endet nicht in einer
  Sackgasse, sondern in genau einer typisierten nächsten Aktion; höchstens ein
  Port vorgesehen.
- **Nicht enthalten:** Executor, SwiftUI und echter Portlauf.
- **Umgesetzt und zur Supervisor-Prüfung vorgelegt** (`Sources/
  SickPLSCommissioningControl/ConnectionPolicy.swift`, kein neues Target).
  `ConnectionPolicyModel` (Wertreducer, kein `atMillis`-Parameter, da keine
  einzige Frist selbst berechnet wird) mit `ConnectionPolicyPhase` (neun
  Fälle, zwei davon — `openingPort`/`closingPort` — mit fachlich
  unterschiedlich reagierenden Ausprägungen), `ConnectionPolicyEvent` (zehn
  Fälle), `ConnectionPolicyDirective` (sieben Fälle, keine trägt eine
  Frist), `ConnectionPolicyIdentityGap` (die drei Nicht-B1-Ausgänge,
  strukturell ohne `.identified`), `ConnectionPolicyFailure` und
  `ConnectionPolicyPort` (validierende Fabrik, Hausmuster). Der passive
  Fast Path erreicht `ready` ohne jedes TX; kein B0 löst nach der
  Beobachtungsphase genau eine B1-Probe bei 38.400 aus; valides B1 führt zu
  `continuingActively` (Port bleibt gehalten, `requestActiveContinuation`);
  Timeout/unerwartete/unauswertbare Antwort schließen den Port erst
  bestätigt und erreichen dann `continuingViaCommissioning(gap)`
  (`requestCommissioningContinuation`). Ein während der B1-Prüfung
  eintreffendes B0 gewinnt strukturell (`ready`), eine danach verspätet
  eintreffende B1-Antwort bleibt dort wirkungslos. Abbruch/Fehler mit
  vorgesehenem oder offenem Port laufen immer über `closingPort` und
  erreichen den Endzustand erst nach bestätigtem `portClosed`/
  `portCloseFailed`; ein noch nicht bestätigter Öffnungsversuch merkt den
  Grund nur vor (`openingPort(windDownTo:)`) und entscheidet erst am
  wirklichen Ergebnis. Terminale Zustände (`continuingActively`,
  `continuingViaCommissioning`, `failed`) ignorieren jedes weitere
  Ereignis — keine Lauf-/Generationskennung nötig, ein neuer Lauf ist ein
  neuer Modellwert. 42 neue Tests (28 `ConnectionPolicyTests`, davon einer
  je Pflichtnachweis plus Gegenproben; 11 `ConnectionPolicyTransitionTableTests`
  — elf strukturell erreichbare Zustandsformen, jede gegen alle zehn
  Ereignisse, `checkingIdentityAtTargetRate` zusätzlich gegen alle vier
  `IdentityProbeOutcome`-Fälle; 3 `ConnectionPolicyBoundaryTests` — kein
  Port/Dateideskriptor/Schreiben/Timer/SwiftUI, kein `default` in der
  Datei, nur die beiden erlaubten Importe). Testaufschlüsselung
  `SickPLSCommissioningControl`: 94 → **136 (+42)**; Gesamtprojekt: 1759 →
  **1801**, 0 Fehler. Sauberer `rm -rf .build && swift build` bestätigt
  weiterhin `LC_BUILD_VERSION minos 12.0`; isolierter strenger
  Concurrency-Build (`-strict-concurrency=complete`, eigener
  Scratch-Path) bleibt grün (Exit 0), keine neue Warnung aus der neuen
  Datei. **Ehrlich offen für SICK-0330a-0:** ob im aktiven
  Fortsetzungspfad ein Login nötig ist und wie B0 nach der
  MMK-Anforderung die Wirkung belegt, entscheidet dieser Slice
  ausdrücklich nicht — er fordert die Fortsetzung nur typisiert an. Auch
  offen: die reale Beobachtungsfrist selbst (bewusst beim späteren
  Executor, SICK-0330a-1) und ob `ConnectionPolicyFailure.connectionLost`
  jemals vor `ready` real ausgelöst wird oder in der Praxis nur danach
  vorkommt (das Modell lässt beides strukturell gleich zu, ohne dafür eine
  Gerätebeobachtung zu behaupten).
- **Supervisor-Review: K1 erforderlich (geschlossen).** Fast Path und
  B0-/B1-Entscheidung waren bereits akzeptiert. Vier Grenzfehler mussten
  behoben werden: Abbruch während der Commissioning-Freigabe wurde
  ignoriert; `portCloseFailed` wurde ohne echte Freigabe terminal/portfrei;
  Folgedirektiven trugen den ausgewählten Port nicht; freie Fehlerstrings
  umgingen die Redaktionsgrenze. Review: `.agent_handoff/review-sick-0330r.md`;
  Korrekturauftrag: `.agent_handoff/task-sick-0330r-k1.md`.
- **SICK-0330r-K1 umgesetzt und zur Supervisor-Prüfung vorgelegt** (nur
  `Sources/SickPLSCommissioningControl/ConnectionPolicy.swift` geändert,
  kein neues Target, kein Executor, kein echter Port). **H1 — Abbruch
  bleibt bis zur wirklichen Freigabe dominant:** `operatorAborted` in
  `closingPort(.commissioningContinuation(...))` verwirft die vorgemerkte
  Fortsetzung jetzt unwiderruflich (`abortedOutcome(from:)`); das
  Ergebnis endet garantiert `.aborted`, nie mit einer aktiven oder
  Commissioning-Direktive — belegt an der wörtlichen Auftragssequenz
  B0-Timeout → B1-Timeout → closePort → operatorAborted → portClosed.
  **H2 — ein fehlgeschlagener Portschluss ist keine Freigabe:** die neue,
  **nichtterminale** Phase `ConnectionPolicyPhase.closeFailed(_:)` hält den
  Port sichtbar vorgesehen (`needsPort == true`) und sperrt jede
  Folgedirektive, bis ein späteres, tatsächlich bestätigtes `portClosed`
  regulär freigibt — kein automatischer Retry, kein stiller
  Zustandssprung nach `failed`; ein Abbruch in `closeFailed` verwirft
  weiterhin eine vorgemerkte Commissioning-Fortsetzung, markiert den Port
  aber nicht fälschlich als geschlossen. **H3 — jede wirkende Direktive
  trägt ihren Port:** jeder Fall in `ConnectionPolicyDirective` außer
  `.none` trägt jetzt `ConnectionPolicyPort` als eigenen Wert — eine
  Direktive ohne Port ist seither nicht mehr kompilierbar; wo eine Rate
  zur Aktion gehört (Fast Path/B1/aktive Fortsetzung bei 38.400,
  Commissioning-Fortsetzung bei 9600), steht sie ebenfalls explizit als
  `SerialPortBaudRate` dabei. **H4 — Fehler sind geschlossene, redigierte
  Kategorien:** die drei früheren `String`-Nutzlasten (Portöffnung,
  Verbindungsverlust, Portschluss) sind durch das gemeinsame, feldlose
  `ConnectionPolicyIOFailure` ersetzt (kein String, Pfad, Fehlercode,
  Bytewert, Payload oder Geheimnis); Ereignis und Zustand teilen sich
  denselben Wert, die fachliche Unterscheidung der drei Operationen bleibt
  über die eigenen `case`-Namen erhalten. **Zwei echte, revert-basierte
  Gegenproben durchgeführt** (nicht nur inline-Assertions): H1 zurückgesetzt
  (kein `abortedOutcome`-Aufruf) bricht 2 Tests (6 Einzelaussagen) exakt am
  geforderten Sequenztest; H2 zurückgesetzt (`portCloseFailed` sofort
  terminal `.failed`, wie vor der Korrektur) bricht 84 Einzelaussagen über
  praktisch jeden Schließpfad-Test — danach beide Male byteidentisch
  wiederhergestellt (`diff` bestätigt). Übergangstabelle um zwei neue,
  strukturell erreichbare Zustandsformen erweitert —
  `closeFailed(.failure(...))` und `closeFailed(.commissioningContinuation(...))`
  — jede gegen alle zehn Ereignisse geprüft; **dreizehn** Zustandsformen
  insgesamt. 12 neue Tests (9 `ConnectionPolicyTests`, 2
  `ConnectionPolicyTransitionTableTests`, 1 `ConnectionPolicyBoundaryTests`
  — Quelltextgrenze gegen die drei früheren `String`-Signaturen sowie rohe
  Byte-/Fehlercode-/Payload-Typen an ihrer Stelle). Testaufschlüsselung
  `SickPLSCommissioningControl`: 136 → **148 (+12)**; Gesamtprojekt: 1801 →
  **1813**, 0 Fehler. Sauberer `rm -rf .build && swift build` bestätigt
  weiterhin `LC_BUILD_VERSION minos 12.0`; isolierter strenger
  Concurrency-Build (`-strict-concurrency=complete`, eigener Scratch-Path)
  bleibt grün (Exit 0), keine neue Warnung aus `ConnectionPolicy.swift`.
  Fast Path, B0-/B1-Wahrheit, die drei Identitätslücken, sequenzielle
  Commissioning-Entscheidung, reiner Reducer, kein `default`, kein I/O und
  kein zweiter Portbesitz sind unverändert. **Korrigierte, bisher falsche
  Aussagen aus der Erstfassung:** `operatorAborted` war **nicht** in allen
  laufenden Phasen mit demselben Effekt abgedeckt (in
  `closingPort(.commissioningContinuation(...))` blieb es bis K1 wirkungslos)
  — jetzt ist Abbruch aus jeder nichtterminalen Zustandsform typisiert
  möglich und überall dominant; ein Schließfehler bedeutete **nicht** eine
  Portfreigabe (`needsPort` sprang fälschlich auf `false`) — jetzt bleibt er
  bis zum bestätigten `portClosed` nichtterminal mit gehaltenem Port.
- **Supervisor-Review K1: enger K2 erforderlich.** H1 bis H3 sind
  akzeptiert; 1813 Tests, strenger Concurrency-Build und macOS 12 sind
  grün. Zwei Typgrenzen bleiben: Die erreichbare `closeFailed`-Phase
  verwirft den geschlossenen Portschlussgrund aus dem Ereignis, und
  `ConnectionPolicyIdentityGap.unexpectedResponse` transportiert weiterhin
  ein rohes `UInt8`-Kommandobyte. Review:
  `.agent_handoff/review-sick-0330r-k1.md`; Korrekturauftrag:
  `.agent_handoff/task-sick-0330r-k2.md`. SICK-0330a-0 bleibt gesperrt.
- **SICK-0330r-K2 umgesetzt und zur Supervisor-Prüfung vorgelegt** (nur
  `Sources/SickPLSCommissioningControl/ConnectionPolicy.swift` und seine
  drei Testdateien geändert; kein neues Target, kein Executor, kein echter
  Port). Fast Path, B0-/B1-Wahrheit sowie H1–H3 unverändert. **K2-1 — der
  Portschlussgrund wird gebunden statt verworfen:** `applyWhileClosingPort`s
  `.portCloseFailed`-Zweig band das mitgelieferte `ConnectionPolicyIOFailure`
  nie; `ConnectionPolicyPhase.closeFailed` trägt seither
  `(ConnectionPolicyClosingOutcome, reason: ConnectionPolicyIOFailure)`,
  gebunden aus dem auslösenden Ereignis. Ein wiederholtes `portCloseFailed`
  ersetzt den gespeicherten Grund durch den zuletzt gemeldeten;
  `operatorAborted` in `closeFailed` lässt ihn unverändert und ersetzt nur
  das vorgemerkte Ergebnis. Der produktiv unerreichbare Fall
  `ConnectionPolicyFailure.portCloseFailed(ConnectionPolicyIOFailure)` ist
  ersatzlos entfernt (ihn erreichbar zu machen hätte eine Frist-/Zählgrenze
  verlangt, die dieser Reducer bewusst nie berechnet). **K2-2 — die
  Identitätslücke ist an der Policy-Grenze datenfrei:**
  `ConnectionPolicyIdentityGap.unexpectedResponse` trägt kein
  `commandByte: UInt8` mehr; das niedrigere
  `IdentityProbeOutcome.unexpectedResponse(commandByte:)` bleibt
  unverändert, jeder Bytewert bildet beim Eintritt auf dieselbe
  geschlossene Kategorie ab. Neue Quelltextgrenze verbietet
  `UInt8`/`commandByte`/`[UInt8]`/`Data` im Deklarationsblock des Typs.
  **Zwei echte, revert-basierte Gegenproben durchgeführt:** `closeFailed`
  auf die alte Ein-Wert-Form zurückgesetzt lässt das Paket **nicht mehr
  kompilieren** (vier exakte Fehlerstellen); `unexpectedResponse` mit
  `commandByte: UInt8` zurückgesetzt ebenfalls **nicht mehr kompilierbar**
  (die einzige produktive Konstruktionsstelle verlangt dann ein fehlendes
  Argument) — beide Korrekturen sind damit strukturell erzwungen, nicht nur
  per Konvention; danach byteidentisch wiederhergestellt (`diff` bestätigt).
  8 neue Tests (7 `ConnectionPolicyTests`, 1 `ConnectionPolicyBoundaryTests`).
  Testaufschlüsselung `SickPLSCommissioningControl`: 148 → **156 (+8)**;
  Gesamtprojekt: 1813 → **1821**, 0 Fehler. Sauberer `rm -rf .build && swift build`
  bestätigt weiterhin `LC_BUILD_VERSION minos 12.0`; isolierter strenger
  Concurrency-Build (`-strict-concurrency=complete`, eigener Scratch-Path)
  bleibt grün (Exit 0), keine neue Warnung. Kein Executor, keine echte
  Frist/Uhr, keine SwiftUI-Änderung, keine Integration in Sitzung oder
  Portbesitz, keine Änderung am niedrigeren Commissioning-/Identity-
  Protokoll, kein echter Portlauf, kein Scanner, kein TX/RX, keine
  Owner-App, kein Git. SICK-0330a-0 bleibt bis zur Abnahme dieser Runde
  gesperrt.
- **Supervisor-Abnahme K2 und Gesamtslice:** Der Portschlussgrund ist im
  erreichbaren Zustand erhalten, Abbruch wahrt Grund und Portbesitz, und die
  Identitätslücke ist datenfrei. Vollständiger Testlauf Exit 0 (autoritativ
  1821 Tests, 0 Fehler), strenger Concurrency-Build Exit 0 und
  `LC_BUILD_VERSION minos 12.0`. Review:
  `.agent_handoff/review-sick-0330r-k2.md`. **SICK-0330a-0 ist freigegeben**;
  Auftrag: `.agent_handoff/task-sick-0330a-0.md`.
- **SICK-0330a-0 umgesetzt und zur Supervisor-Prüfung vorgelegt** (nur
  `Sources/SickPLSCommissioning/CommissioningState.swift`/`CommissioningRecipe.swift`
  und ihre Tests laut Auftrag, dazu drei betroffene Downstream-Sources und
  zwei Downstream-Tests außerhalb des nominalen Zuschnitts, offen gelegt,
  notwendig für ein kompilierbares Gesamtprojekt). Neues, feldloses
  `CommissioningEvent.identityAlreadyConfirmedAtTargetRate` übernimmt einen
  bereits belegten B1-Beleg ohne zweite Probe/Login (nur aus `.idle`, kein
  Telegramm, kein Audit-Eintrag). Neue Phasen
  `awaitingMeasurementStream(deadlineMillis:)`/`measurementStreamConfirmed`
  ersetzen `requestingMeasurementMode`/`measurementModeAcknowledged`; nur
  `.acknowledgement(.observedScanProfile)` schließt MMK erfolgreich, nur
  `.acknowledgement(.rejected)` scheitert sofort, jede andere Zwischenantwort
  lässt Frist/Phase unangetastet; ein B0 vor der Anforderung erfüllt sie
  nicht. Neuer, einziger Fehlerfall `measurementStreamAbsent` ersetzt
  `measurementModeUnanswered`/`measurementModeAmbiguous`. Neues Rezeptfeld
  `measurementStreamTimeoutMilliseconds` (3.000 ms, getrennt vom
  allgemeinen 2.000-ms-Fenster). Entdeckte, bewusst unbehobene Lücke in
  `CommissioningExecutor`s B0-Behandlung (ignoriert das `.hold`-Ergebnis
  während `awaitingMeasurementStream`) als Vorbedingung für SICK-0330a-1
  dokumentiert. Gegenprobe (ACK als verfrühter Erfolg) bricht 14
  Einzelaussagen, byteidentisch restauriert. 14 neue Nettotests,
  Testaufschlüsselung `SickPLSCommissioning`: 156 → **169 (+13)**;
  Gesamtprojekt: 1821 → **1834**, 0 Fehler. Sauberer `rm -rf .build && swift build`
  bestätigt `LC_BUILD_VERSION minos 12.0`; isolierter strenger
  Concurrency-Build bleibt grün (Exit 0), keine neue Warnung. Kein Executor,
  kein echter Port, kein Gerätelauf, keine kooperative
  Abbruchimplementierung, keine Verbindungspolitikänderung, kein
  Orchestrator, keine Sitzungs-/Portbesitzintegration, kein SwiftUI, kein
  Scanner, kein TX/RX, keine Owner-App, kein Git. SICK-0330a-0 liegt jetzt
  zur Supervisor-Prüfung bereit.
- **Supervisor-Review: enger K1 erforderlich.** B1-Übernahme, B0-Wahrheit,
  feste Rezeptfrist und NACK-Pfad sind akzeptiert. Zwei Reducer-Grenzen
  bleiben: Nicht ablehnende MMK-Antworten werden tatsächlich nicht
  auditiert, und der Zustandswert `deadlineMillis` entscheidet nicht gegen
  `atMillis`, sodass ein verspätetes B0 noch Erfolg wird. Review:
  `.agent_handoff/review-sick-0330a-0.md`; Korrekturauftrag:
  `.agent_handoff/task-sick-0330a-0-k1.md`. SICK-0330a-1 bleibt gesperrt.
- **SICK-0330a-0-K1 umgesetzt und zur Supervisor-Prüfung vorgelegt** (nur
  `Sources/SickPLSCommissioning/CommissioningState.swift`/`CommissioningAudit.swift`
  und ihre Tests laut Auftrag, keine Downstream-Anpassung nötig). **K1-1:**
  Neues, feldloses `CommissioningImmediateResponse` (ACK/abgelehnt/unlesbar)
  auf `CommissioningAuditEntry.immediateResponse`, `nil` bildet „keine
  unmittelbare Antwort" ab; getrennt von `outcome` auf demselben Eintrag,
  keins überschreibt das andere. **K1-2:** Der Dispatcher reicht
  `deadlineMillis` jetzt an die Übergangslogik weiter; jedes
  `.acknowledgement(...)`-Ereignis wird zuerst gegen die Frist geprüft — bei
  oder nach ihr entscheidet der Inhalt nichts mehr, der Lauf endet eindeutig
  `.measurementStreamAbsent`; ein verfrühtes `deadlineReached` bleibt
  wirkungslos; am exakten Grenzwert gilt die Frist als abgelaufen. Zwei
  Gegenproben (Zeitvergleich entfernt bricht 12 Einzelaussagen,
  Antwortaufzeichnung entfernt bricht 4), byteidentisch restauriert. 7 neue
  Tests, Testaufschlüsselung `SickPLSCommissioning`: 169 → **176 (+7)**;
  Gesamtprojekt: 1834 → **1841**, 0 Fehler. Sauberer `rm -rf .build && swift build`
  bestätigt `LC_BUILD_VERSION minos 12.0`; isolierter strenger
  Concurrency-Build bleibt grün (Exit 0), keine neue Warnung. Die
  dokumentierte Executor-Lücke bleibt unverändert SICK-0330a-1 vorbehalten.
  Kein Executor, Transport, Orchestrator, Portbesitz, SwiftUI-Umbau, echter
  Port, Scanner, TX/RX, Owner-App oder Git. SICK-0330a-0-K1 liegt jetzt zur
  Supervisor-Prüfung bereit.
- **Supervisor-Abnahme K1 und Gesamtslice:** Antwortbeobachtung und
  Stromwirkung sind gleichzeitig im Audit erhalten; die absolute Frist
  unterscheidet 7.999/8.000/8.001 ms korrekt und verfrühte Fristereignisse
  bleiben wirkungslos. Vollständiger Testlauf Exit 0 (autoritativ 1841
  Tests, 0 Fehler), strenger Concurrency-Build Exit 0 und
  `LC_BUILD_VERSION minos 12.0`. Review:
  `.agent_handoff/review-sick-0330a-0-k1.md`. **SICK-0330a-1 ist
  freigegeben**; Auftrag: `.agent_handoff/task-sick-0330a-1.md`.

### SICK-0330a-0 / SICK-0330a-1 / SICK-0330a — aktiver Teil des Standardwegs

Diese drei Slices bleiben klein und getrennt:

1. **Reducer** *(einschließlich K1 abgenommen)*: B1 ist alleiniger
   Ratenbeleg — ein bereits belegter B1-Beleg der `ConnectionPolicy` wird
   ohne zweite Probe/Login übernommen (`identityAlreadyConfirmedAtTargetRate`,
   nur aus `.idle`); B0 nach MMK-Anforderung ist **einziger** Betriebsbeleg
   (`awaitingMeasurementStream`/`measurementStreamConfirmed`, feste
   3-Sekunden-Frist); eindeutiges NACK bleibt sofortiger Fehler
   (`measurementModeRejected`); jede andere Zwischenantwort lässt Frist und
   Phase unangetastet bis zur Entscheidung (`measurementStreamAbsent` bei
   Fristablauf ohne B0). Auftrag: `.agent_handoff/task-sick-0330a-0.md`.
   **Seit K1** (`.agent_handoff/task-sick-0330a-0-k1.md`) sind die beiden
   vom Review benannten Abnahmeblocker geschlossen: die unmittelbare
   MMK-Antwort ist eine eigene, geschlossene Audit-Tatsache
   (`CommissioningImmediateResponse` — ACK/abgelehnt/unlesbar/keine —,
   getrennt von der späteren Stromwirkung auf demselben Eintrag), und die
   gespeicherte Frist entscheidet den Übergang selbst — bei oder nach
   `deadlineMillis` erzeugen B0/ACK/NACK keinen Erfolg und keine verspätete
   Ablehnung mehr, ein verfrühtes `deadlineReached` verkürzt sie nicht.
   1841 Tests (+7), strenger Concurrency-Build und `LC_BUILD_VERSION
   minos 12.0` grün. Abnahme:
   `.agent_handoff/review-sick-0330a-0-k1.md`.
2. **Executor** *(einschließlich K1/K2/K3 abgenommen)*: kooperativer Abbruch
   bis in jede Restfrist (drei Prüfpunkte, neue `CommissioningAbortToken`
   über `os_unfair_lock`); die zuvor dokumentierte B0-Beobachtungslücke ist
   geschlossen (`awaitResponse` verwirft die vom Reducer gelieferte
   `.hold`-Direktive nicht mehr); Abschluss und Portfreigabe erst nach
   einem wirklich gelungenen `closePort()` (`isFinal`/`isPortHeld` sind
   jetzt vom Executor selbst beobachtete Felder). Auftrag:
   `.agent_handoff/task-sick-0330a-1.md`. Review benannte vier
   Randgrenzen (`.agent_handoff/review-sick-0330a-1.md`): der finale
   Parser-Drain verwarf B0, ein Portwechsel-Schließfehler löste einen
   automatischen zweiten Schluss aus, das Bedienmodell verlor einen nicht
   finalen porthaltenden Run, und eine späte/doppelte Abbruchmarke konnte
   den nächsten Lauf vergiften. **Seit K1**
   (`.agent_handoff/task-sick-0330a-1-k1.md`) sind B0-Drain,
   Schließ-Retry, Besitz-/Hinweisweg und die strukturelle Provider-Grenze
   geschlossen:
   B0 aus `parser.feed(...)` und `parser.finish()` läuft über eine
   gemeinsame `processFrames`-Auswertung; ein Portwechsel-Schließfehler
   löst genau einen `closePort()`-Versuch je `perform` aus und hält den
   Run/Besitz über die Control-Ebene bis zum ausdrücklich wiederholten,
   wirklich gelungenen Schluss; `makeRun(portPath:)`
   garantiert Abbruchfähigkeit strukturell
   (`CommissioningRunning & CommissioningAborting`) statt über einen
   optionalen Cast. Sechs echte, revert-basierte Gegenproben (drei aus
   SICK-0330a-1, drei aus K1) bestätigt. 1865 Tests (+8 gegenüber
   SICK-0330a-1), strenger Concurrency-Build und `LC_BUILD_VERSION
   minos 12.0` grün. **K2 bleibt erforderlich:** Das einmalige
   `discardStaleRequest()` bei späterer Main-Zustellung ist keine atomare
   Laufkante; ein anderer Thread kann direkt danach noch eine alte Marke
   setzen. Review: `.agent_handoff/review-sick-0330a-1-k1.md`; Auftrag:
   `.agent_handoff/task-sick-0330a-1-k2.md`. **Seit K2** ersetzt eine
   generationsbasierte `CommissioningRunEdge` (`CommissioningAbortToken`,
   dieselbe `os_unfair_lock`-Sperre) das einmalige Aufräumen:
   `beginRunIfNeeded()` reserviert synchron vor dem Einplanen
   (`CommissioningControlModel.start(...)` ruft `activeRun.beginRun()`
   außerhalb des `dispatcher.runSerialized`-Blocks), `endRun(_:)` schließt
   Aktiv- und Abbruchmarke atomar genau dort, wo `perform` zurückkehrt —
   nicht erst bei der Main-Thread-Zustellung. `discardStaleAbortRequest()`
   ist ersatzlos entfernt. Zwei deterministische Zwei-Seiten-Gegenproben
   mit echten Threads/Semaphoren (Anforderung unmittelbar vor/nach dem
   Schließen) plus eine dritte, lokal nachgebaute alte best-effort-
   Semantik als Gegenbeleg bestätigt. 1875 Tests (+18 gegenüber K1),
   strenger Concurrency-Build und `LC_BUILD_VERSION minos 12.0` grün.
   **K3 bleibt erforderlich:** Ein frischer Token reserviert derzeit bereits
   Generation 0, obwohl noch kein Lauf eingeplant ist. Dadurch kann ein
   Leerlauf-Abbruch den späteren ersten Lauf treffen. Review:
   `.agent_handoff/review-sick-0330a-1-k2.md`; Auftrag:
   `.agent_handoff/task-sick-0330a-1-k3.md`. **Seit K3** startet
   `activeGeneration` bei `nil` statt bei der vorreservierten Generation
   `0` — genau wie jede spätere Lücke zwischen zwei Läufen; die
   generationsbasierte K2-Mechanik selbst ist unverändert.
   `requestAbort()` vor jeder Reservierung ist damit strukturell
   wirkungslos. Der bisherige Alttest, der einen bloßen `requestAbort()`
   vor dem ersten `perform` (ohne `beginRun()`) noch beobachtet erwartete,
   kodierte genau die Phantomkante und wurde umgedreht: Ein frischer,
   direkter `perform`-Aufruf läuft jetzt regulär durch; der tatsächlich
   gemeinte Vor-Start-Fall (Anforderung nach `beginRun()`, vor `perform`)
   bleibt als eigener, unveränderter Nachweis grün. Eine echte,
   revert-basierte Gegenprobe (Rückkehr zur vorreservierten `0`) bricht
   genau die beiden dafür vorgesehenen Nachweise, byteidentisch
   restauriert. 1877 Tests (+2 gegenüber K2), strenger Concurrency-Build
   und `LC_BUILD_VERSION minos 12.0` grün.
   Der Supervisor hat K3 und damit SICK-0330a-1 vollständig abgenommen.
   Review: `.agent_handoff/review-sick-0330a-1-k3.md`.
3. **Orchestrator** *(K1 aktiv)*: der
   testbare, synchrone, vollständig injizierbare `StandardConnectionRun`
   (`SickPLSCommissioningControl`) komponiert `ConnectionPolicyModel`
   (SICK-0330r/K1/K2) und `CommissioningModel`/`CommissioningExecutor`
   (SICK-0330a-0/K1, SICK-0330a-1/K1/K2/K3) ohne zweites Telegramm-/
   Login-Wissen: passiv beobachten (feste 1,5-s-Frist) → bei Bedarf eine
   harmlose B1-Probe bei 38.400 (belegtes B1 übernimmt
   `CommissioningExecutor.adoptAlreadyOpenConnectionWithConfirmedIdentity()`
   ohne zweiten Versuch) → bei Bedarf der vollständige 9600-Fallback
   (Passwort aus `ScannerPasswordStoring` erst unmittelbar vor Login/
   Baudwechsel, nie als Laufzustand gehalten). Geteilter
   `CommissioningAbortToken` zwischen eigener Schleife und delegiertem
   Executor. Ein erfolgreicher Bericht lässt den Port
   bewusst offen und gehalten — SICK-0330b schließt ihn wirklich, bevor
   RX beginnt. 13 Pflichtnachweise über echte Übergänge, zwei
   revert-basierte Gegenproben. 1910 Tests (+33 gegenüber SICK-0330a-1),
   strenger Concurrency-Build und `LC_BUILD_VERSION minos 12.0` grün.
   Supervisor-Review belegt sechs Restfehler an Batchvorrang, Laufkante,
   Schließ-Retry, öffentlicher Redaktion, Fortschrittsmatrix und
   Übernahmesichtbarkeit: `.agent_handoff/review-sick-0330a.md`. Aktiver
   Korrekturauftrag: `.agent_handoff/task-sick-0330a-k1.md`.

Jede Runde bleibt ohne reale Hardware. Ein späterer Realtest braucht eine
eigene Owner-Auslösung.

### SICK-0330b — gebündelte App-Verbindung

SICK-0330b absorbiert SICK-0331. Derselbe Slice bindet passive Beobachtung,
nötige TX-Schritte und RX-Sitzung an denselben Besitz **und** liefert die
kompakte Verbindungsleiste. Die eine Nutzerfrage lautet: Kann ich sichtbar
verbinden und trennen, ohne parallelen Port, zweiten Profilsubscriber oder
verschleierte Gerätewirkung? Der Revisor prüft danach Architektur und
Bediennachweis gemeinsam. Die Offline-Evidenzkarte samt redigiertem Textexport
wird bereits hier gebaut, damit SICK-034 nichts Unsichtbares messen muss.
Zusätzlich erhält der strikte Build eine feste Warnungsreferenz; die fünf
`ScanSession`-Warnungen werden geschlossen oder einzeln begründet.

## 6. Slice-Verträge und historische Planstände

Die Ausführungsreihenfolge steht ausschließlich in [END_PRODUCT_ROADMAP.md](END_PRODUCT_ROADMAP.md).

### SICK-034 — gebündelte reale Scannerabnahme

SICK-034 absorbiert SICK-034b und SICK-034d in denselben vorbereiteten
Gerätetermin: Fünf-Minuten-Strom, Wiederverbinden, EBUSY, Geräteneustart und
Referenzdistanzen werden in einem Protokoll geprüft. Die Referenzdistanzen
verifizieren die bereits belegte Zentimeter-/Meterskala; sie schalten die
Meteranzeige nicht erst frei. Nur ein tatsächlich beobachteter
Frame-Batch oberhalb der **vor der Sitzung numerisch festgelegten** Schwelle
öffnet den bedingten Korrekturslice SICK-034c. Dafür liest das Protokoll
Gesamtreads und `readsWithDroppedProfiles` ausdrücklich aus.

### SICK-033a — Channelstrip bis zum ersten echten Ton

SICK-033a absorbiert SICK-033g, SICK-033a-0, SICK-033a-1, SICK-033a-2,
SICK-033c und SICK-038-light. Designsystem, Struktur, Gate-Bedienung, Synth,
Delay/Hall, Referenzvergleich und erster Hörtest gehören zu derselben
Oberfläche und werden gemeinsam abgenommen. Der Hörtest prüft Pitch, Volume,
Gate, Stop und alle bis dahin vorhandenen Lösewege ohne hängenden Ton. Die
Abnahme ist innerhalb desselben Slices gestuft: zuerst realer Ton samt
vollständiger Lösematrix und Gate-Schwelle **mit Polarität**, danach
Referenzvergleich und Accessibility. Ein Politurfehler öffnet keine neue
Roadmap-Runde und macht den belegten Hörpfad nicht wieder ungeschehen.
Die sichtbare Neufassung verwendet einen einzigen HELMUT-/Logic-orientierten
Kanalzug und einen getrennten Inspector-/Pluginfensterbereich. Bestehende
Fachkarten sind keine Layoutreferenz und dürfen beim Umbau entfallen.

### SICK-033b — Audio Units Ende-zu-Ende

SICK-033b absorbiert SICK-033b-0 und SICK-033b-1. Katalog-/Statusmodell,
Rackbedienung und der reale Drittanbieter-Test beantworten gemeinsam, ob eine
AU bewusst gefunden, geladen, umgangen und im Fehlerfall verstanden werden
kann. Auswahl lädt nichts; Bypass mutiert den laufenden Graphen nicht. Die
frühen Grenzen von vier sichtbaren bzw. acht modellierten FX-Slots sind keine
Produktregel und werden entfernt. Die serielle Insertliste wächst über einen
abschließenden leeren Slot; eine reale Ressourcen- oder Pluginverweigerung wird
sichtbar, statt eine willkürliche Zahl als fachliche Grenze auszugeben.

### SICK-033d / SICK-033e — Steuerkern und Feldinstrument

SICK-033d absorbiert SICK-036a-0, SICK-035b und SICK-033d-1: eine
ausgabeneutrale Senke, eine Pitch-Domäne, eine `FieldHit`-Trefferschicht und
die Migration des Produktpfads werden als eine Architekturfrage abgenommen.
SICK-033e wird durch die Ownerentscheidung vom 25.09. präzisiert: Die primäre
Arbeitsfläche ist ein polares, bemalbares Ringsektorraster. Streifen,
Raster, Fächer und Tonartfelder bleiben als musikalische Feldlogiken im
Release; Vektorfelder entfallen [ERSETZT: der Flächeneditor mit Achse je Zuordnung
und Wertverlauf-Vorschau übernimmt diese Rolle; Vorschau ist nie Gate/Off/Panic]. Die bisherige sichtbare Prognose sowie jede
Glättung sind vorläufig aus dem aktiven Produktpfad zu nehmen. Ein späteres
Wiedereinführen braucht eine neue Hörentscheidung und darf Gate oder diskrete
Werte weiterhin nie erzeugen.

### SICK-041 — historischer Instrument-Prototyp *(offline belegt, ersetzt)*

Dieser gebündelte Slice setzt den UX-Neustart ohne Scannerhardware um:

1. metrische Weltkoordinate in Zentimetern/Meter und affine Projektion ohne
   vierte Wurzel oder `0...8191`-Normalisierung in der Darstellung;
2. konfigurierbares Quadratraster, Zellenmalen/-löschen sowie konfliktfreies
   Pan/Zoom;
3. auf 12,5 Hz begrenzte sichtbare Scanaktualisierung bei ungedrosseltem
   Profil-/Audiopfad;
4. Entfernung von Predictor/Glättung aus dem aktiven Klang- und Sichtpfad;
5. neue rechte Oberfläche mit einem HELMUT-/Logic-orientierten Kanalzug,
   Inspectorplatz und Fenstergrenzen für Synth/FX/AU;
6. Migration nur der fachlich weiterverwendbaren Zustände; die alten polaren
   Flächen werden nicht künstlich in Rasterzellen umgerechnet.

Abnahme: reine Geometrie- und Interaktionstests, direkter Messwert-zu-
Steuerwert-Nachweis, UI-Takt gegen Fake-Zeit, breite/schmale Bildnachweise und
vollständige Offline-Suite. Kein Port, kein TX/RX und kein Hardwareclaim.

**Supervisor-Abnahme 24.09.2026:** Der metrische Kern, die affine Projektion,
das bemalbare Raster, lückenloses Malen/Löschen, Pan/Zoom, bestätigungspflichtiger
Rasterwechsel und der 12,5-Hz-Anzeigetakt sind umgesetzt. Der Produktpfad
verarbeitet weiterhin jedes echte Profil, gibt zwischen Profilen aber keine
Predictorwerte mehr an den Klangpfad aus; Input-Loss und Gate-Off bleiben
erhalten. Kanalzug und Inspector stehen in breiten Fenstern rechts und in
schmalen Fenstern erreichbar im gestapelten Arbeitsbereich. Breite und schmale
Sichtprüfung, vollständige Testsuite sowie strikter Concurrency-Build sind
grün. Die eigene AU-Pluginfenster-Instanzierung bleibt fachgerecht Teil von
SICK-033b; SICK-041 schafft dafür nur die beschlossene Oberflächengrenze.
Scannerwinkel und reales Profilbild werden erst im gebündelten Hardwarefenster
bestätigt und sind keine nachträgliche Offline-Behauptung.

**Ownerentscheidung 25.09.2026:** Der kartesische Teil dieser Abnahme ist nur
noch historischer Prototypbeleg. Das Zielprodukt übernimmt ausschließlich das
polare Ringsektormodell mit radialer Verdeckung. XY-Modus, Quadratzellen und
Konvertierung werden im Architektur-Cutover entfernt.

### SICK-043 — Ebenen-, Zellen- und Parameterinstrument

Dieser eine gebündelte Produktslice ersetzt die provisorische feste
Pitch/Volume/Filter/Gate-Zuordnung durch ein einheitliches räumliches
Routingmodell. Er wird intern in Kern, Inspector und Assistenten umgesetzt,
aber gemeinsam abgenommen; dafür entstehen keine eigenen Korrekturslices.

1. **Ziele:** Jede schreibbare AU-Parameteradresse eines geladenen
   `aumu`/`aufx` und MIDI-Out-Ziele (Note, Akkord, CC, Pitch Bend und
   Channel Pressure) sind typisierte, gleichrangige Routingziele. Persistiert
   werden Komponentenidentität, Parameteradresse und stabile Kennung; fehlt
   ein Ziel nach Pluginwechsel, bleibt die Zuordnung sichtbar defekt und wird
   niemals still auf einen anderen Parameter gelegt.
2. **Ebenen:** Der bisher unbenutzte Inspector wird Ebenen-Manager. Jede Ebene
   besitzt Name, Reihenfolge, Farbe, Sichtbarkeit, Sperre, Solo/Aktivität,
   Zellmaske und beliebig viele Zielzuordnungen. Sichtbarkeit ist ausschließlich
   Darstellung; Aktivität entscheidet über Klang/MIDI. Mehrere Ebenen und
   mehrere Aktionen pro Zelle dürfen sich überlagern.
3. **Zellen:** Jedes bemalte Quadrat kann eigene konstante, diskrete oder
   kontinuierliche Werte sowie Noten/Akkorde tragen. Gemeinsame Werte werden
   strukturell als Ebenen-/Bereichsvorgabe mit sparsamen Zellüberschreibungen
   gespeichert, nicht tausendfach kopiert.
4. **Notenlebenszyklus:** Notenziele erzeugen Note-on/off selbst. Ein separates
   musikalisches Gate ist dafür nicht erforderlich. Der boolesche Gate-Typ
   bleibt nur für ausdrücklich boolesche Ziele und alte Presets. Übergänge
   bieten Retrigger, Legato, definierte Überlappung und **Halten bis zum
   nächsten Ton/Akkord**. Im Haltemodus bleibt der zuletzt ausgelöste Klang
   nach Verlassen der Fläche stehen; der nächste Klang desselben MIDI-Kanals
   ersetzt ihn. Eine frei malbare **All-Notes-Off-Fläche** löst flankengesteuert
   bekannte Note-offs plus MIDI-CC 123 aus. Stopp, Zielverlust, Ebenenaus,
   Presetwechsel und Verbindungsverlust folgen der vollständigen Lösematrix
   in Abschnitt 3 (einschließlich Owner-Ausnahme A).
5. **Assistenten:** Ein Bereich kann nach Grundton, Tonumfang, Skala
   (chromatisch, Dur, Moll, Pentatonik sowie spätere Skalen), Richtung in Grad,
   auf-/absteigender Ordnung und Oktavlage belegt werden. Weitere Modi sind
   deterministisch zufällige Verteilung mit gespeichertem Seed,
   Akkord/Umkehrung/Voicing und kontinuierliche AU-/CC-Verläufe mit Minimum,
   Maximum und Kurve. Danach bleibt jede Zelle frei editierbar.
6. **Viewport:** Die gewählte Ebene zeigt ihre Farbe; gerichtete diskrete oder
   kontinuierliche Zuordnungen erscheinen als Farbverlauf entlang ihres
   Richtungsvektors. Akkorde und Mehrfachaktionen erhalten zusätzliche
   Markierungen. Bei mehreren sichtbaren Ebenen bleibt die gewählte Ebene
   dominant, damit sich widersprechende Verläufe nicht zu einer falschen Farbe
   vermischen.
7. **Zellauswahl und Zuweisung — Canvas-Vertrag (Owner 11.10.2026):**
   Leitprinzip ist direkte Manipulation am Zellraster statt Auswahlmenüs;
   Vorbild für das Bediengefühl ist der Step-Sequenzer FirstOfFifth. Neben
   Stift, Radierer und Verschieben gibt es ein Auswahlwerkzeug. Es wählt
   **Paare aus Ebene und gemalter polarer Zelle** sichtbarer, ungesperrter
   Ebenen. Klick trifft die oberste zulässige Ebene und macht sie aktiv;
   ⇧ ergänzt einen Bereich, ⌘ schaltet einen Treffer um. Rechteck und ⌘A
   erfassen alle zulässigen Ebenen, Listenwahl markiert deren Zellen sichtbar.
   Doppelklick wählt die kantenverbundene Insel gleichen effektiven Inhalts
   in der getroffenen Ebene; ⇧ ergänzt die Insel, ⌘ schaltet ihre Zellen um.
   Inhaltsgleichheit wird gemeinsam mit `CompiledRoutingPlan.toggleRegionByCell`
   definiert: identische eigene Noten/Werte und Ebenenvorgaben gehören zusammen.
   **Snap (Owner 13.10.2026)** hält je Ebene die aktive gezeichnete Zelle bzw.
   kantenverbundene Fläche gleichen effektiven Inhalts, bis die Hand ihre
   Grenze um mehr als 0–10 cm überschreitet (Standard 0). Radial zählt der
   Abstand zur gezeichneten inneren/äußeren Kante, seitlich die Bogenlänge
   am aktuellen Handabstand; auch gebrochene Winkelgrenzen bleiben exakt.
   Eine gezeichnete Zelle ist die kleinste Haltefläche, auch bei wechselnden
   Skalen-/Zufallswerten ihrer Feinsegmente. Inseln, Lücken und eigene Werte
   begrenzen die Fläche; ein umschließendes Rechteck ersetzt sie nicht.
   Eintritt aus dem Leeren hat keinen zusätzlichen Snap-Widerstand;
   die gesonderte Scan-Bestätigung bleibt wirksam. Mehrere Toggle-Hände
   behalten eigene Eintrittszustände; Bewegung im Snap-Band ist kein
   erneuter Eintritt. Snap 0 erhält die bisherige Feinsegmentwahl.
   Presets behalten den Schlüssel `boundaryMarginCentimeters` und lesen
   frühere Edge-margin-Werte als Snap gleichen Werts. Gate/Note-Off folgen
   ausschließlich akzeptierten Messprofilen und der bestehenden Lösematrix,
   niemals einer Prognose. REGLER-OVERLAYS zeigt den eingestellten Abstand
   als innere Zelllinie; dies ist ein Abstandsmaß, keine zweite Haltegeometrie.
   Das musikalische Gefühl ist noch durch den Owner live zu prüfen.
   Nachbarringe verbinden sich nur bei überlappendem Winkelbereich; reine
   Eckberührung verbindet nicht. Listenwahl und Kontextmenü „Select layer“
   wählen weiterhin die ganze Ebene. Verschieben, Löschen und eigene Werte wirken
   auf dieselben Paare; ein zweiter, versteckter Verschiebebereich existiert
   nicht. V = Auswahl, B = Malen, E = Radieren, H = Hand; gehaltene Leertaste
   nutzt Hand vorübergehend. Malen/Radieren bearbeiten die im Feldkopf
   genannte aktive Ebene. Der Ringsektorrahmen verschiebt oder transformiert
   Abstand und Winkel über Bögen, Kanten und Ecken nach derselben Rasterregel
   wie das Einpassen; am Feldrand wird die größte zulässige Änderung angenommen.
   Eine Geste ist ein Undo-Schritt. ⌥-Verschieben kopiert, Pfeile verschieben
   um einen Schritt (⇧ zehn). ⌫/Entf löscht samt eigenen Werten. ⌘C/⌘X/⌘V
   transportieren Zellen samt Werten in ihre ursprünglichen Ebenen, bei
   fehlender Ebene in die aktive; ⌘D dupliziert im Feld Zellen, in der Liste
   Ebenen. Esc bricht eine Geste ab oder hebt die Auswahl auf. Kontextmenü
   und Tastatur verwenden dieselben Aktionen; wirkungslose Aktionen nennen
   ihren Grund unter dem Feld. Auswahl, aktive Ebene und Zellzwischenablage
   sind Sitzungszustand: Auswahlklicks erzeugen keinen Dokument-Edit,
   Undo-Eintrag oder neuen Instrumentplan. Die aktive Ebene wird beim Speichern
   ohne erneute Zellvalidierung ins bestehende Dokumentformat gespiegelt.
   Undo einer Metadatenänderung erhält die spätere Auswahl; geometrische
   Bearbeitungen stellen ihre zugehörige Auswahl wieder her. Der getrennte
   Gerätefeld-Referenzeditor behält seine reine Bereichsauswahl.
   Die Zuweisung geschieht in der **Inspector-Spalte**, die sich der Ebene
   anpasst: bei Notenebenen eine Klaviatur für Ton oder Akkord, bei CC-Ebenen
   ein CC-Regler. Mehrere Zellen dürfen denselben Ton oder Akkord tragen. Eine
   Mehrfachauswahl kann einen kontinuierlichen Verlauf von Ton, Akkord oder CC
   entlang der Ring- oder Winkelachse erhalten; der Tonverlauf ist
   umschaltbar zwischen tonleitertreu und chromatisch, CC bleibt linear. Der
   Verlauf erscheint als Farbverlauf. Die bisherigen Auswahlmenüs für Skala,
   Grundton und ähnliches entfallen, sobald die direkten Wege stehen.
   **Card:** Der Inspector ist der vorgesehene Ort. Auswahl und Zuweisung
   bleiben deshalb als ansichtsunabhängiges Modell gebaut, damit eine
   zusätzliche Zell-Card später ohne Umbau möglich bleibt, falls sie sich als
   sinnvoll erweist. Leere Zellen und Zellen ohne Routing erhalten einen
   verständlichen Leerzustand; Ebenenwechsel, Löschen und Rasterwechsel
   bereinigen eine ungültig gewordene Auswahl deterministisch. Schritte S1–S4
   und Owner-Weichen: `.agent_handoff/design-planarium-gui.md`.
8. **Preset an den Raum anpassen (FIT-RAUMFORM, Owner 18.10.2026):**
   „Fit to room“ passt Radien je 0,5°-Peilung direkt im dokumentierten
   1-cm-Geräteraster an, einschließlich Vergrößerung bis zum bestehenden
   Spielradius 2 m. Maßstab = (Wand minus Rand) / äußerster Presetradius
   dieser Richtung; Standardrand 10 cm. Bracketierte Messlücken werden
   linear überbrückt, ungemessene Ränder bleiben unbegrenzt. Beidseitig
   begrenzte Einbrüche unter 10 cm Bogenlänge an den umgebenden Wandpunkten
   werden für den Fit überbrückt (Rückgabe Owner 18.10.); die Rohaufnahme und
   der Detektor bleiben unverändert. Breitere Wände bleiben bindend. Zusammenhängende
   Peilungsbereiche gleicher Ebenenbelegung (höchstens 30° je Band) nutzen den
   kleinsten zulässigen Außenradius ihres Bereichs. So entstehen Kreisbänder
   statt Sägezähne je 0,5°; keine Feinzelle überschreitet die daraus belegte Wand.
   Die gestrichelte Fit-Kontur zeigt diese abgeleitete Evidenz.
   Peilung und radiale Reihenfolge bleiben erhalten; Metadaten werden kopiert,
   Overrides folgen ihrer Quellzelle. Schlafende Überschreibungen außerhalb
   aktiver Masken bleiben unverändert; würde der Fit eine davon aktivieren,
   bleibt das gesamte Dokument unverändert und ein Hinweis nennt den Grund.
   Bei Rasterkollision gewinnt die nähere
   Quelladresse deterministisch; der Fit-Hinweis nennt die Anzahl der
   Zusammenfälle ausdrücklich. Die Untergrenze erhält eine brauchbare
   1-cm-Zelle; unmöglich enge Räume bleiben über Außerhalb-/Schmalwarnungen
   sichtbar. Kontur und Rand bleiben Sitzungswerte. Einpassen erzeugt genau
   einen Undo-Schritt und speichert nicht. Die bestehende Perform-Erlaubnis
   gilt weiter. Neue Instrumente und Werkspresets zeigen 5-cm-Editorzellen;
   gespeicherte Dokumente behalten ihre Rasterweite. Werkspreset-Musikmasken
   werden durch die feinere Anzeige nicht neu berechnet.

**Offline-Umsetzung 24.09.2026:** Das persistierbare Workspace-Modell,
Ebenen-Inspector, Zellüberschreibungen, Rastermigration mit Konfliktanzeige,
dynamische AU-Inserts, AU-Instrumente, AU-Parameter- und MIDI-Routing sowie
Skalen-, Zufalls-, Akkord-, Verlauf-, Überlappungs-, Halte- und
All-Notes-Off-Modus sind im einen vorhandenen Profilweg integriert. Presetformat
3 trägt den Workspace; ältere Presets migrieren weiter. Standardbuild und die
vollständige Testsuite einschließlich Architektur-, Modell- und
Auswertungsverträgen sind grün. Die
nachfolgende reale/visuelle Abnahme bleibt davon getrennt.

Abnahme: Parameterbaum gegen Apple-AUs und mindestens eine Drittanbieter-AU,
MIDI-Monitor für Noten/CC/Pitch Bend, Note-Lösematrix einschließlich
Legato/Überlappung/Halten/All Notes Off, Preset-Rundlauf, breite und schmale
Inspector-Prüfung sowie ein realer Spieltest. Das ist **räumliche Zuordnung**,
keine zeitachsenbasierte Automation oder Aufnahme/Wiedergabe von
Faderfahrten.

Vor dieser realen/visuellen Abnahme folgt der GUI-Neubau aus Punkt 7 als
zusammenhängende UX-Ergänzung innerhalb von SICK-043. Ihr Nachweis umfasst
polare Sektortreffertests, typabhängige Inspector-Zustände (Klaviatur, CC),
Tastatur-/VoiceOver-Fokus und den Gegenbeleg, dass bloßes Auswählen weder
MIDI/AU sendet noch Zellen bemalt.

### SICK-036a — MIDI Ende-zu-Ende

SICK-036a absorbiert SICK-036b, SICK-036c und SICK-036d. Übersetzer,
CoreMIDI-Transport, Bedienkarte, Panic und realer Test sind ein vertikaler
Ausgang desselben Steuerwegs. Note-Off/Panic wird für die vollständige
Lösematrix geprüft, nicht nur für Zone verlassen, Eingangsverlust und Abwahl.

### SICK-037 / SICK-039 — Produktabschluss

- SICK-037 absorbiert SICK-037a und SICK-038: migrationssichere, atomare
  statische Presets und der vollständige reale Spiel- und Regressionstest
  werden gemeinsam abgenommen. Laden startet nichts und löst aktive
  Audio-/MIDI-Ausgänge vor dem Zustandswechsel.
- **Owner-Entscheidungen vom 23./24.09.2026:** Zeitachsenautomation
  einschließlich SICK-035a und SICK-038a entfällt; es wird kein
  zeitabhängiger Automationszustand aufgenommen oder abgespielt. Davon
  ausdrücklich verschieden und mit SICK-043 verbindlich ist das räumliche
  Routing von Rasterzellen auf AU-Parameter und MIDI-Ziele.
- SICK-039 bleibt als eigene Releasegrenze für Schlaf/Wake, Dauerlauf,
  Speicher, Threads, Bedienung, Signierung und Notarisierung erhalten. Vor
  SICK-037 legt der Owner konkrete Budgets für Steuerlatenz, Dropouts, CPU und
  Speicherwachstum fest; ohne Budget gibt es keinen professionellen
  Release-Claim.

## 7. Offene Entscheidungen und Risiken

1. **TX-Erweiterbarkeit:** TX ist reguläre, typisierte Gerätefähigkeit, wo die
   Produktfunktion sie braucht. Neue Befehlsfamilien erhalten eigene Modelle
   und Abnahmen; ein generisches Rohtelegramm-Terminal ist daraus nicht
   abgeleitet.
2. **Stromstabilität und Neustartpersistenz:** gebündelter SICK-034, nicht aus
   einer Einzelbeobachtung ableiten.
3. **MMK bei bereits auf 38.400 laufendem Gerät:** B1-Antwort und Loginpflicht
   bleiben Beobachtungsfragen für den nächsten freigegebenen Realtest.
4. **Mehrere Frames je Read:** SICK-034 entscheidet, ob 034c überhaupt nötig
   ist.
5. **Learn-Parameter:** erst im realen Hör-/Spieltest von SICK-033a/SICK-037
   kalibrieren; heutige Werte bleiben Startwerte, keine Geräteeigenschaft.
6. **Mehrhand-Spiel:** erste Feldversion wählt einen effektiven Treffer je
   Feld; unabhängiges Handtracking ist nicht versprochen.
7. **AU-Fehlerisolation:** Ladeort und Opt-in sind keine Sandbox-Zusage.
8. **Release-Budgets:** konkrete Zahlen fehlen noch und sind vor SICK-037 eine
   Owner-Entscheidung.
9. **Developer-ID/Notarisierung:** brauchen Apple-Developer-Zugang und bleiben
   Ownerschritt in SICK-039.

## 8. Optionale Gerätefeld-Referenz — keine Entfernungskalibrierung

Schutz- und Warnfelder sind für die Meterskala nicht nötig. Sie bleiben eine
sinnvolle optionale Referenzebene und ein eigener Gerätefunktionsstrang. Der
aktuelle SickToolbox-/Realabgleich ist in
`.agent_handoff/research-sicktoolbox-fields-2026-09-24.md` belegt: reale
`0x43`-Telegramme tragen strukturell 360/90 Segmente plus 361/91 Radien; reale
B0-Statusbits änderten sich bei gleicher Distanz nach einer Feldänderung.
Feldidentität, Bitsemantik und direktes Lesekommando sind noch offen.

**Offline-Vertrag BÜNDEL-1010:** `ScannerFieldContour` in
`PLSDeviceValues` hält 90/180/360 Segmente mit N+1 Zentimeterradien und
getrennten oberen drei Statusbits. `ScannerFieldContourCodec` liegt neben
`CommissioningTelegram` und unterstützt ausschließlich die belegten
`0x43/0x5A`- und `0x43/0xFE`-Payloads; 180 ist kein freigegebenes
Drahtformat. Er besitzt keinen Sender und keinen Messpfadaufrufer.
`ScannerFieldRepresentation` prüft polare Editorzellen auf Erreichbarkeit
vom Scanner ohne radiale Lücken, auch zwischen Gerätewinkeln, und verwirft
Winkeldetails unter der gewählten Segmentauflösung. Die Außenkontur wird
auf ganze Zentimeter gerundet; Polygonkanten zwischen Strahlen nähern
gekrümmte Editorgrenzen an. Das ersetzt keinen geometrischen Realabgleich.
Der lokale, standardmäßig ausgeschaltete Modus „Scanner flag bits“ färbt
gemessene Punkte nach 0…7 und zählt alle Rohmessungen je Wert. Er deutet
keine Bits und verändert weder Detektion noch Instrumentdokument.

SICK-040a bis SICK-040d bleiben deshalb vorgemerkt:

1. **SICK-040a:** Offline-Codec und passive Flagdarstellung implementiert;
   Rekonstruktion des PLS-Lese-/Commitvertrags bleibt offen.
2. **SICK-040b:** typisiertes Feldmodell, Visualisierung, Offline-Editor,
   Validierung und verständlicher Soll/Ist-Diff.
3. **SICK-040c:** gezieltes Schreiben über die bestehende aktive
   Gerätegrenze, mit sichtbarer Zusammenfassung und anschließendem Read-back.
   Nur bestätigte Unterschiede werden als übernommen angezeigt.
4. **SICK-040d:** kontrollierter Realtest: Ausgangszustand lesen, bekannte
   1×1-m-/2×2-m-Referenzfelder schreiben, zurücklesen und Soll/Ist vergleichen.
   Die stehende Owner-Freigabe deckt diese Wirkung am Projektgerät ab.

Diese Planung macht keine Aussage über eine zertifizierte Schutzwirkung und
setzt keine sicherheitsbezogene Abnahme vorweg. Das ist keine TX-Sperre,
sondern eine ehrliche Grenze der derzeit vorhandenen Evidenz.

## 8a. Ownerentscheidung 27.09.2026 — striktes Polarmodell am Geräteraster

**Entscheidung.** Das Modell kennt ausschließlich Radius und Peilung. Kein x und
kein y, außer im letzten Schritt vor den Pixeln: die Zeichenfläche ist
unvermeidlich kartesisch, das ist aber keine Modellwahrheit. Sektorgrenzen liegen
auf ganzzahligen Vielfachen der **0,5°-Messteilung**, Ringgrenzen auf
ganzzahligen Vielfachen von **5 cm**. Jede Messung fällt damit über
Ganzzahlarithmetik in genau einen Ringsektor; es gibt keinen Grenzfall, über den
eine Fließkommarundung entscheidet.

**Evidenzlage der Gerätezahlen.** Eine vom Owner benannte externe Untersuchung
eines **PLS101-112** nennt ausdrücklich 5 cm Distanzauflösung, 0,5°
Winkelauflösung und 40 ms je 180°-Scan. Das Projektgerät ist ein PLS101-316, also
eine andere Variante derselben Familie; ein gemeinsamer Messkern ist plausibel,
aber nicht belegt. Die 40 ms stützt eine eigene Messung: RX bei 500.000 Baud
liefert stabil etwa 25 Hz. Die 0,5° sind modellseitig konsistent, weil 361
Indizes über 180° genau 0,5° je Index ergeben. Die **Einheit** ist nach dem
Instrumentvertrag in Abschnitt 1 belegt und festgelegt: kanonisch Zentimeter,
`Meter = PLS-Rohdistanz / 100`, gestützt auf den PLS-spezifischen
SickToolbox-Code, Herstellerunterlagen und reale Profile. Die **eigene**
Referenzmessung gegen bekannte Abstände ist am 28.09.2026 gefahren worden und
in `.agent_handoff/abnahmepunkte.md` belegt: fünf verwertbare Abstände von 20
bis 40 cm, Steigung 0,953 ± 0,027 gegen den wahren Abstand, größter Rest
0,59 cm. Ein grober Maßstabsfehler ist damit ausgeschlossen, `Meter =
PLS-Rohdistanz / 100` über diesen Bereich bestätigt. Offen bleibt der
**Arbeitsbereich**: alle Punkte lagen unter einem halben Meter; für die
Verifikation über die volle Reichweite fehlen noch je ein Abstand bei etwa
2 m und 4 m. Die Messung *verifiziert* den Maßstab und schaltet die
Meteranzeige nicht erst frei. Der Satz „Keine Meteranzeige ohne dokumentierte reale
Kalibrierung" in `CLAUDE.md` stammt aus dem Grundcommit und ist von diesem
Vertrag überholt; die Auflösung dieses Widerspruchs liegt beim Owner.

**Befund 29.09.2026: die Winkelabtastung des laufenden Geräts ist 2°, nicht
0,5°.** `PolarDeviceLattice` rechnet mit 361 Ticks über 180°, also 0,5° je
Tick. Das Projektgerät liefert im heutigen Betrieb aber **90 Punkte**, die
`PolarProfileGeometry` gleichmäßig über das Feld verteilt — 180/89 =
**2,022°** je Punkt. Seitlicher Abstand benachbarter Messpunkte: 0,71 cm bei
20 cm, 3,53 cm bei 100 cm, **7,06 cm bei 200 cm**.

Folgen, klar getrennt:

- **Radial** ist die Feinheit voll vorhanden; der Scanner meldet jeden
  Zentimeter. Der 1-cm-Ringquant wirkt dort sofort.
- **Seitlich** hängt der Nutzen einer feinen Zelle an der Punktzahl. Bei 90
  Punkten und 2 m Abstand würde die Mehrzahl der feinen Zellen nie getroffen.

**Warum 90 ankommen, ist belegt und nicht offen:** Es ist der
Minimum-Dauermodus MMK (`20 20`). Der Gerätelauf vom 22.09.2026 hat ihn
angefordert und danach einen B0-Strom mit 90 Punkten bei 12,5 Hz auf
38.400 empfangen (`PROJECT_LOG.md`, `CHANGELOG.md`); der heutige
500000-Strom liefert dieselben 90 Punkte bei 25 Hz. Zwei Läufe, dieselbe
Betriebsart, dieselbe Punktzahl. Der Name sagt es: **Minimum** kontinuierlich.

**Der volle Scan existiert und ist aufgezeichnet, nicht offen.**
`SICK Doku/b0-scan-profile.md` §3/§4 belegt 361 Punkte (0,5°, ≈4,11 Hz) in
Runde 12 (84 Frames RX-only), 22 und 25/27 — mit echten Werten (min 20, max
5106, Median 91) — sowie 180 Punkte (1,0°, ≈8,05 Hz) in Runde 22/25. Alle drei
Punktzahlen 90/180/361 sind real; ein Parser liest `num_measurements` je Frame.

**Auslöser geklärt am 29.09.2026 (🟢, `SICK Doku/skills/SICK-Telegramme.md`):**
`20 24` ohne Login → 361 Punkte, `20 20` → 90 (MMK), `20 22` → NACK. Der
folgende Absatz ist der Stand davor.

**Offen ist der Auslöser, nicht die Existenz.** Für keine der drei Punktzahlen
ist ein isoliertes Umschalt-Telegramm bestätigt; 180 und 361 wurden nur als
bereits aktiver Zustand vorgefunden. Die Diskrepanz 90/180/361 am selben
PLSIBS-Menüpunkt ist ungeklärt. Der Gerätelauf in Schritt E2 sucht, ob sich
der volle Scan vom heutigen 90-Punkt-Zustand aus kommandieren lässt — die
Zellstruktur des vollen Scans kann dagegen schon jetzt gegen die
aufgezeichnete 361-Punkt-Geometrie entworfen werden.

*Supervisorfehler, zweifach festgehalten:* Der Supervisor nannte den vollen
Scan am 29.09.2026 „unbelegt", obwohl er in `SICK Doku/b0-scan-profile.md`
mehrfach RX-only aufgezeichnet ist — er hatte nur nach „90 Punkte" gesucht.
Zuvor hatte er die MMK-Punktzahl als ⚪ aus einem Review zitiert, das dem
klärenden Gerätelauf einen Tag vorausging. Gemeinsame Ursache: Die
SICK-Doku-Captures werden vor einer „unbekannt"-Aussage über Geräteverhalten
nicht gründlich genug durchsucht. Beide Male hat der Owner korrigiert.

`PolarDeviceLattice(tick:rawCentimeters:)` hat heute **genau einen**
Aufrufer, die Migration. Einen Produktionsweg vom Messpunkt zur Gerätezelle
gibt es noch nicht; er entsteht bei M-4 und entscheidet die Abbildung
Profilindex → Tick **an der Punktzahl**, nicht fest auf 361
(Ownerentscheidung `.agent_handoff/owner-decision-beide-betriebsarten.md`).

**Befund: die 5 cm sind nicht die Drahtrasterung.** Die im Projekt beobachteten
Rohwerte sind keine Vielfachen von 5 — Minimum 20, Median 91, Maximum 5106, Index
199 von 440 bis 896. Die 5 cm sind die kleinste zuverlässig unterscheidbare
Abstandsdifferenz, nicht die Schrittweite des übertragenen Wertes. Genau deshalb
ist die Vorgabe richtig: ein Ring, der feiner als die Geräteauflösung wäre, würde
allein durch Rauschen flattern statt durch Bewegung.

**Befund: das heutige Raster verletzt die Messteilung ab 2 m.** Die adaptive
Sektorbreite halbiert sich fortlaufend von 90°: 45°, 22,5°, 11,25°, 5,625°,
2,8125°, 1,40625°. Nur die ersten beiden sind ganzzahlige Vielfache von 0,5°. Ab
Ring 3, also ab 2 m, ist ein Sektor 22,5 Messschritte breit — benachbarte
Sektoren enthalten abwechselnd 22 und 23 Messungen; weit draußen 2 oder 3, also
bis zu 50 % Unterschied in der Ansprache zwischen Nachbarn.

**Offen und nicht durch diese Entscheidung gelöst.** Eine Rasterung beseitigt
kein Zittern für ein Objekt, das genau auf einer Grenze steht; das braucht eine
Hysterese und ist ein eigener Vertrag. Die Kalibrierung der Einheit bleibt offen.
Die ausführliche Evidenzlage steht in `SICK Doku/integration/b0-scan-profile.md`;
dieser Ordner ist per `.gitignore` **nicht** versioniert, weshalb die für die
Architektur bindenden Aussagen hier stehen.

## 8b. Rastervertrag L-1a — geschlossen, 27.09.2026

Der Revisor hat L-1 in der ersten Kurzform als nicht schnittreif zurückgewiesen
(`.agent_handoff/review-polar-lattice-2026-09-27.md`, B3): ein Arrayindex ist kein
Geräte-Tick, und Winkelursprung, Endpunktregel, zugelassene Profilformen und
Halbkreis müssen vorher feststehen. Der Owner hat die zwei blockierenden Fragen
am 27.09.2026 entschieden. Damit ist der Vertrag geschlossen und **vollständig
ganzzahlig**; er gilt für Adresse, Darstellung, Persistenz und Auswertung
gemeinsam.

> **Änderung 30.09.2026 (Owner, `.agent_handoff/owner-decision-preset-raster.md`
> und `owner-decision-beide-betriebsarten.md`):** Punkt 1 „andere Punktzahl wird
> abgewiesen" ist aufgehoben. Das Dokument bleibt im 361-Tick-Raster; 90 Punkte
> (MMK, 🟢 Segment-Minima über die 361 Rohwerte) werden in M-4 an der Punktzahl
> auf Ticks abgebildet. Punkt 2: Das Ringquant ist seit 29.09.2026 **1 cm**
> (`owner-decision-zellgroesse.md`, `5212864`), Ringe 0…8190; die 5-cm-Zahlen
> unten sind historisch.

**1. Winkel.** Nur das vollständige Geräteprofil mit **361 Messpunkten** speist
das Instrument. Der Tick ist der Messpunktindex selbst: `tick = index`,
`tick ∈ 0…360`, Tick 0 = −90°, Tick 180 = 0° (Blickrichtung), Tick 360 = +90°.
Jeder Tick ist genau 0,5°. Eine andere Punktzahl erreicht den Instrumentpfad
**nicht** — sie wird abgewiesen, nicht umgerechnet. 90- und 180-Punkt-Profile
bleiben synthetische Testhilfen und sind kein Produktweg. Adressen hinter dem
Scanner gibt es nicht; der Vollkreis von heute entfällt.

**2. Ring.** Die Ringhöhe ist **ein 5-cm-Quant**, überall. Die Adresse entsteht
per Ganzzahldivision aus dem unveränderten Zentimeterrohwert:
`ring = rawCentimeters / 5`. Aus der brauchbaren Spanne 1…8190 folgen die Ringe
0…1638, also 1639 Ringe. Die Regel ist von sich aus halboffen — Ring `k` enthält
`5k…5k+4` —, ein Sonderfall an der Ringgrenze existiert nicht.

**3. Sektor.** Die Tickzahl je Sektor ist immer ein **Teiler von 360**. Damit
teilen die Sektoren die 360 Winkelintervalle restlos, und jede Sektorgrenze liegt
auf einem Messwinkel. Gewählt wird je Ring der größte Teiler von 360, dessen
Bogenbreite am Außenradius die Ringhöhe nicht überschreitet — die Zelle wird so
quadratisch, wie es ganzzahlig geht.

Diese Regel braucht **kein Gleitkomma**. Aus
`(ring+1)·5cm · d·0,5°·π/180 ≤ 5cm` folgt `d·(ring+1) ≤ 180/(0,5π) = 114,59`,
also die rein ganzzahlige Bedingung

```
ticksPerSector · (ring + 1) ≤ 114
```

Beide Formen sind für alle 1639 Ringe gegeneinander geprüft; kein Ring weicht ab.
Damit kommt in Adresse **und** Sektorwahl weder `π` noch eine Rundung vor:

| Ring | Außenradius | Ticks/Sektor | Sektorbreite | Sektoren im Ring |
|---:|---:|---:|---:|---:|
| 0 | 0,05 m | 90 | 45° | 4 |
| 1 | 0,10 m | 45 | 22,5° | 8 |
| 3 | 0,20 m | 24 | 12° | 15 |
| 9 | 0,50 m | 10 | 5° | 36 |
| 19 | 1,00 m | 5 | 2,5° | 72 |
| 39 | 2,00 m | 2 | 1° | 180 |
| **57** | **2,90 m** | **1** | **0,5°** | **360** |
| 1638 | 81,95 m | 1 | 0,5° | 360 |

**Ab Ring 57, also ab 2,90 m, ist ein Sektor genau einen Messschritt breit.**

**Korrektur des Supervisors nach dem Review vom 27.09.2026 (B7).** Die frühere
Fassung dieses Absatzes behauptete, ab Ring 57 sitze „genau eine Messung in genau
einer Zelle". Das ist zu stark. Richtig sind **zwei getrennte Aussagen**:

- *Jede Messung erhält eindeutig genau eine Adresse.* Das gilt überall und ist
  die Eigenschaft, die die Ownerentscheidung verlangt.
- *Jede Zelle enthält genau eine Messung.* Das gilt für die **letzte** Zelle
  nicht: 361 Messpunkte teilen 360 Winkelintervalle, und die Endpunktregel legt
  Tick 360 in denselben Sektor wie Tick 359. Der letzte Sektor eines Rings mit
  `ticksPerSector == 1` enthält also zwei Messungen.

Dokumentation, Leistungsszenarien und Tests dürfen die beiden Aussagen nicht
vermischen. Eine injektive Zuordnung aller 361 Ticks widerspräche der
beschlossenen Teilung in 360 Intervalle und wäre eine **neue
Ownerentscheidung**.

**4. Endpunktregel.** 361 Messpunkte sind 360 Intervalle. Alle Sektoren sind
halboffen, **der letzte ist an beiden Enden geschlossen**: Tick 360 gehört in den
letzten Sektor. Formal
`sector = min(tick / ticksPerSector, 360 / ticksPerSector − 1)`. Ohne diese Regel
adressierte Tick 360 einen Sektor, den es nicht gibt.

**5. Was damit verboten ist.** Im Zell-, Persistenz- und Auswertungsmodell
kommen `MetricSquareGrid`, `MetricScanPoint`, `ScanAngularSpan`, `floor` auf einem
Gleitkommawert und ein frei geteiltes Segment nicht mehr vor. Kartesisch ist
ausschließlich der letzte Schritt vor den Pixeln. Der kartesische Legacy-Import
bleibt als ausdrücklich benannte, lesende Ausnahme am Dokumentrand erhalten
(Revisorempfehlung 4, Zusage aus `e3eedcf`); er schreibt nie kartesischen Zustand
zurück.

**6. Der Rohwert überlebt die Quantisierung.** 101 cm und 104 cm sind zwei
unveränderte Gerätebeobachtungen, aber **eine** topologische Wahrheit: derselbe
Ring. Der Zentimeterwert wird beim Eintritt **nicht** überschrieben — er bleibt
für Nachvollziehbarkeit, Rohdarstellung, Trefferwahl und die spätere Hysterese
erhalten. Er treibt aber keine zweite, zentimetergenaue Zellzuordnung. Eine
kontinuierliche Distanzmodulation innerhalb eines Rings wäre eine neue
Produktentscheidung (Revisorempfehlung 3, offen gehalten).

**Preis der Entscheidung, ausdrücklich benannt — und vom Supervisor zu niedrig
geschätzt.** Die frühere Fassung nannte „etwa die zehnfache Zellzahl". Zehnfach
ist nur die **radiale** Verfeinerung von 50 cm auf 5 cm. Die **winklige**
Verfeinerung kommt dazu: im Bereich 1,0…1,5 m stehen 22,5° alt gegen 2,5°…1,5°
neu. Der Revisor hat die Menge neuer Zellen je alter Zelle nachgerechnet — 73 bei
0,5…1,0 m, **120** bei 1,0…1,5 m, 230 bei 3,0…3,5 m. Für dieselbe physische
bemalte Fläche liegt die Vergrößerung dort bei **Faktor 120, nicht 10**. Das ist
zugleich ein Persistenz-, Compiler- und Leistungsbefund. Die Auswertung wächst schon heute überlinear mit der Zellzahl —
`s5000-r16` kostet 22,9 ms gegen 40 ms Budget —, weil `directionalFraction` je
Trefferzelle die ganze Ebene neu rechnet. L-2 muss diese Rechnung deshalb
beseitigen, nicht nur polar machen, und das Budget ist nach L-1b neu zu messen.
Der Adressraum selbst ist kein Problem: gespeichert werden nur bemalte Zellen.

### Migrationsvertrag M-1 — ganzzahlig, 28.09.2026

Die Altzellmigration ruft die alte Adressfunktion **nicht** auf. Sie stützt sich
auf `sin`, `cos`, `atan2` und `hypot`; ein gespeichertes Dokument darf nicht von
der Mathematikbibliothek abhängen. Maßgeblich ist die Fläche, die die alte
Adresse *bezeichnet*, nicht die Rundungsnarbe einer Laufzeit
(`.agent_handoff/review-migration-determinism-2026-09-28.md`; der Revisor hat
seine eigene gegenteilige Empfehlung dort zurückgenommen).

Beide Achsen werden ganzzahlig entschieden:

- **Radius:** `ring·cs ≤ raw < (ring+1)·cs`, in Zentimetern. Ein Altraster, das
  kein ganzzahliges Zentimetermaß ist, wird **benannt abgelehnt**; stilles
  Runden ist unzulässig.
- **Peilung:** `180·idx ≤ (180+tick)·2^k < 180·(idx+1)`. Eine Grenze darf echt
  zwischen zwei Ticks liegen — dann gibt es nichts aufzurunden.
- **Exponent:** `k` ist das kleinste `k ≥ 0` mit `3·2^k ≥ (ring+1)·π`, entschieden
  über `3·2^k·10^9 ≥ (ring+1)·3_141_592_654`. Die Rasterweite kürzt sich heraus;
  `k` hängt allein am Altring. Nachgemessen: **0 Abweichungen in 32.000 Fällen**
  (acht historische Rasterweiten × 4.000 Ringe). Kleinster Abstand zur Schranke
  0,363 gegen einen Fehler der Ganzzahlschranke von 1,6·10⁻⁶ — Sicherheitsfaktor
  221.137. Größtes Zwischenergebnis 6,1·10¹² gegen `Int64` 9,2·10¹⁸.

**Der Altsektor kann feiner sein als der Messschritt.** Ab Altring 122 bei
Rasterweite 0,5 m ist die alte Winkelzelle 0,3516° breit, also schmaler als die
0,5° des Geräts. Dort existieren gültige Altzellen, die **keine einzige**
Geräteprobe enthalten — bei 0,5 m sind es 6.384 (Beispiel: Altring 122,
Index 259). Das ist kein Rechenfehler, sondern eine Eigenschaft des alten
Rasters, und es ist der Grund, weshalb eine leere Migrationsmenge gemeldet
werden muss und nicht stillschweigend gelten darf.

### Abnahmekante M-1b — Compatibility-Grenze, 28.09.2026

Festgelegt in `.agent_handoff/review-m1b-scope-2026-09-28.md`. M-1b importiert
v1–v3 **rein und vollständig** in einen stabilen Compatibility-Zwischenwert der
neuen Lattice-Semantik und ruft die Migration bereits auf. Eine Menge je Rolle
wäre verlustbehaftet: Rollen, Lagen, Reihenfolge, Auswahl, Mappings, Overrides
und stabile Identitäten bleiben erhalten. Das heutige `InstrumentPreset` und
sein Produktionsdecoder bleiben unberührt; die Grenze hat bis M-2/M-6 bewusst
keinen Produktionsaufrufer.

Gemeldet, aber **nicht entschieden** werden zwei Befunde — die Politik fällt mit
der Ownerentscheidung bei M-6:

- Altzelle vollständig außerhalb des Scannerfelds;
- Altzelle im oder am Feld, aber ohne zulässige Geräteprobe.

Ebenfalls zu melden ist die **teilweise** an der Feldgrenze abgeschnittene
Altzelle; sonst bliebe Teilverlust unsichtbar. Nachgemessen, wo Beschnitt
überhaupt auftritt:

- **Winklig nur an der oberen Kante, und zwar genau einmal je Altring:** der
  Index `3·2^k` beginnt exakt bei Tick 360 (+90°) und reicht darüber hinaus. An
  der unteren Kante tritt kein Beschnitt auf, weil die Altschrittweite `90/2^k`
  die 90° teilt und das Intervall dort auf der Kante endet statt sie zu
  überschreiten (0 Fälle in 200 Altringen).
- **Radial am äußeren Rand genau ein Altring je Rasterweite:** bei 0,5 m ist es
  Altring 163 (8150…8199 cm gegen die Nutzgrenze 8190 cm), Verlust höchstens
  9 cm.
- **Radial am inneren Rand kein Verlust:** Altring 0 beginnt bei 0 cm, und
  Rohwert 0 ist keine zulässige Geräteprobe.

In allen drei Fällen enthält der abgeschnittene Teil **keine** Geräteprobe. Der
Beschnitt entfernt also nur unbeobachtbare Fläche. Gemeldet wird er dennoch,
weil die Meldung nicht behaupten darf, die Altzelle sei vollständig übernommen
worden. Benannt **abgelehnt** wird
dagegen sofort, was nicht wohldefiniert ist: nicht-ganzzahliges
Zentimeterraster, unlesbare Version, strukturell ungültige Pflichtfelder. Ein
stilles leeres Set ist in keinem Fall ein ausreichendes Ergebnis.

Die Grenze bleibt eine reine Funktion: kein Dateisystem, keine UI, kein Logging,
keine Zeit, kein Gerät, kein veränderlicher globaler Zustand. Ein Dateiname darf
als Diagnosekontext übergeben werden. Fehlende Identitäten werden
deterministisch abgeleitet oder abgelehnt, nie aus Zufall oder Datum erzeugt.

**Weiter offen.** Hysterese für ein Objekt genau auf einer Grenze (H-1, eigener
Vertrag mit vollständigem Aus-Weg); bis dahin ist das Produkt **nicht** als
flatterfrei abgenommen. Die Bedeutung von `fieldFlags` und `partialScanIndex`
bleibt unmodelliert und darf nicht nebenbei zur Gültigkeits- oder Winkelregel
werden.

## 9. Historischer Status und damaliger nächster Schritt

Die folgenden datierten Rückblicke sind Herkunft; für die heutige Reihenfolge
gilt [END_PRODUCT_ROADMAP.md](END_PRODUCT_ROADMAP.md).

**Aktuell (24.09.2026):** Der Coder hat den Big Bang beendet; die
Supervisor-Gesamtabnahme ist **nicht erteilt**
(`.agent_handoff/review-sick-release-big-bang.md`). Von den damaligen
Offline-Blockern ist der fehlende Ebenen-/Mischpfad mit SICK-042/H1 und dem
räumlichen Instrumentkern von SICK-043 inzwischen geschlossen; Strict-Build,
CoreMIDI-Fremdthreadkante und automatischer Portkandidatenlauf sind inzwischen
korrigiert und belegt. Reale Belege sind ebenfalls offen und in
`.agent_handoff/protokoll-sick-*.md` vorbereitet.
Da die Hardware erst am Abend verfügbar ist, ist SICK-041 nun vollständig
offline abgenommen. Auch H4, der automatische Portkandidatenlauf, ist jetzt
offline geschlossen: „Automatisch“ prüft eine feste Portmomentaufnahme
sequenziell, zeigt Kandidat und Gesamtzahl, nutzt pro Port ausschließlich den
bestehenden `StandardConnectionRun` und stoppt am ersten belegten Scanner.
Ein erkannter Scanner mit konkretem Handlungsfehler bleibt sichtbar; nur
echte Nichttreffer führen zum nächsten Port. SICK-034 und der optionale
SICK-040d werden für das anschließende
gemeinsame Hardwarefenster vorbereitet und nicht simuliert. Die beiden alten
Big-Bang-Blocker sind damit auf H1 reduziert. **Ownerfreigabe 24.09.2026:**
SICK-042/H1 ist offline implementiert: geordnete Ebenen je Kontrollziel,
typgerechte Mischregeln im einen Steuerweg, sichtbare Bedienung und statische
Presetmigration. **Abnahme 24.09.2026:** Der unabhängige Hauptreview fand
keinen Vertragsfehler; M1/L1/L2 wurden durch dokumentierte und sichtbare
Ebenenpriorität sowie eine zusätzliche Migrationsgegenprobe geschlossen und
im unabhängigen K1-Review bestätigt. H1 ist damit abgenommen
(`review-sick-042-h1.md`, `review-sick-042-h1-k1.md`). H4 ist durch
Modelltests, Gesamtsuite, strikten Build und sichtbare App-Kante belegt; der
reale Mehrportlauf bleibt Teil von SICK-034.

**Stand vor dem Big Bang:** SICK-0330r einschließlich K1/K2, SICK-0330a-0 einschließlich
K1 und SICK-0330a-1 einschließlich K1/K2/K3 sind abgenommen. **SICK-0330a
ist noch nicht abgenommen; K1 ist aktiv.** Der `StandardConnectionRun`
komponiert `ConnectionPolicyModel` und
`CommissioningModel`/`CommissioningExecutor` ohne zweites Telegramm-Wissen,
bleibt zuerst passiv (feste 1,5-s-Frist), sendet B1 nur ohne beobachtetes
B0 und führt den vollständigen 9600-Fallback (Login/Baud/MMK) nur aus, wenn
die B1-Probe keine Identität belegt; das Passwort wird erst unmittelbar vor
Login/Baudwechsel gelesen und nie als Laufzustand gehalten. Ein
erfolgreicher Bericht lässt den Port bewusst offen und gehalten. Unabhängig
geprüft: 1910 Tests, 0 Fehler; strenger Concurrency-Build und
`LC_BUILD_VERSION minos 12.0` grün. Sechs Grenzfehler bleiben an
Batchvorrang, laufweiter Abbruchkante, dominantem/retryfähigem Schluss,
öffentlicher Fehlerredaktion, beobachtbarer Fortschrittsmatrix und enger
Übernahmesichtbarkeit. Review: `.agent_handoff/review-sick-0330a.md`;
Korrekturauftrag: `.agent_handoff/task-sick-0330a-k1.md`.

**Nächster Schritt:** zuerst SICK-0330a-K1. Der gebündelte SICK-0330b
(App-Integration einschließlich der früheren SICK-0331-UI) bleibt bis zu
dessen Abnahme gesperrt. Kein echter Port-, Scanner-, TX-/RX-Lauf.

### Historischer Stand vor der SICK-0330a-Folge

SICK-032c3a ist einschließlich K1/K2 abgenommen. In SICK-032c3b-K1 ist der
Notice-Host fachlich akzeptiert. Der app-basierte Bildsatz war wegen
schwarz/transparent verschwundener Pflichtinhalte nicht abnahmefähig;
SICK-032c3b-K2 hat den Bildsatz mit einer robusteren Erfassungstechnik
(`CALayer.render(in:)` statt `cacheDisplay`) erneut erzeugt; Capture,
Fallback-Notices und Stapelkomposition sind akzeptiert. Ein Bild zeigte aber
bereits Bewegung statt des behaupteten Grundprofilfortschritts;
**SICK-032c3b-K3 hat genau diese eine Aufnahme ersetzt** — ein eigener,
isolierter Nachweislauf speiste exakt ein echtes Profil ein (Read-Script
strukturell auf ein Frame begrenzt, keine Möglichkeit für ein zweites vor
der Aufnahme) und erreichte real „Grundprofil 1 von 5". Elf der zwölf
K2-Bilder, Produktcode und Tests bleiben unverändert; 1759 Tests, 0 Fehler.
SICK-032c3b ist einschließlich K1/K2/K3 vollständig abgenommen; Review:
`.agent_handoff/review-sick-032c3b-k3.md`. **SICK-0330r-K1 ist umgesetzt und
liegt zur Supervisor-Prüfung bereit:** Der bereits akzeptierte Fast Path und
die B0-/B1-Verzweigung sind unverändert; korrigiert wurden Abbruch während
Commissioning-Schließen (H1, jetzt dominant bis zur wirklichen Freigabe),
echte Freigabe nach Schließfehler (H2, neue nichtterminale Phase
`closeFailed`), Portbindung jeder wirkenden Direktive (H3, kein `.none`
mehr ohne Port kompilierbar) und geschlossene redigierte Fehlerkategorien
(H4, `ConnectionPolicyIOFailure` statt freier `String`s). Zwei echte,
revert-basierte Gegenproben (H1: 2 Tests/6 Aussagen; H2: 84 Aussagen)
bestätigen, dass die Korrekturen tragend sind; danach byteidentisch
wiederhergestellt. 1813 Tests (+12), strenger Concurrency-Build und
`minos 12.0` bleiben grün. Kein Scanner, echter Port/TX/RX oder neue
Learn-Heuristik. Review: `.agent_handoff/review-sick-0330r.md`;
Korrekturauftrag: `.agent_handoff/task-sick-0330r-k1.md`. SICK-0330a-0
bleibt bis zur Supervisor-Abnahme dieser Runde gesperrt.

**SICK-0330r-K1 war entgegen der eigenen Schlusszeile nicht vollständig
abgenommen** — Review `.agent_handoff/review-sick-0330r-k1.md` verlangte
einen engen K2: die erreichbare `closeFailed`-Phase verwarf den
geschlossenen Portschlussgrund aus dem Ereignis, und
`ConnectionPolicyIdentityGap.unexpectedResponse` transportierte weiterhin
ein rohes `UInt8`-Kommandobyte. **SICK-0330r-K2 ist umgesetzt und liegt
zur Supervisor-Prüfung bereit:** Fast Path, B0-/B1-Wahrheit sowie H1–H3
unverändert. `closeFailed` bindet den Schließgrund jetzt aus dem Ereignis
(`closeFailed(_:reason:)` statt Ein-Wert-Form); der produktiv
unerreichbare Fall `ConnectionPolicyFailure.portCloseFailed` ist
ersatzlos entfernt statt künstlich erreichbar gemacht.
`ConnectionPolicyIdentityGap.unexpectedResponse` trägt kein Kommandobyte
mehr, eine neue Quelltextgrenze verbietet `UInt8`/`commandByte`/`[UInt8]`/`Data`
im Deklarationsblock. Zwei echte, revert-basierte Gegenproben zeigen: beide
Rücknahmen lassen das Paket **nicht mehr kompilieren** — strukturell
erzwungen; danach byteidentisch wiederhergestellt. 1821 Tests (+8),
strenger Concurrency-Build und `minos 12.0` bleiben grün. Kein Scanner,
echter Port/TX/RX, Executor oder echte Frist/Uhr. Korrekturauftrag:
`.agent_handoff/task-sick-0330r-k2.md`. SICK-0330a-0 bleibt bis zur Abnahme
dieser Runde gesperrt.

**SICK-0330a war entgegen der eigenen Schlusszeile nicht abgenommen** —
`.agent_handoff/review-sick-0330a.md` benannte sechs belegte Grenzfehler
(H1–H6). **SICK-0330a-K1 ist umgesetzt und liegt zur Supervisor-Prüfung
bereit:** Grundarchitektur, passiver Fast Path, feste 1,5-Sekunden-Frist,
B1-/Fallback-Entscheidung, Passwortzeitpunkt und der bewusst offene
Erfolgsport bleiben unverändert. B0-Vorrang gilt jetzt für den vollständigen
Read-Batch; ein `connect`-Aufruf hält über alle delegierten Teilschritte
hinweg **eine** Abbruchkante (neue paketinterne
`CommissioningExecutor.performUsingLoanedEdge(_:secret:edge:)`, manueller
`perform` unverändert); ein fehlgeschlagener Portschluss ist überall
dominant, nicht final und über genau einen realen Versuch je `retryClose()`
auflösbar; `StandardConnectionFailure` bettet keinen rohen
`CommissioningFailure` mehr ein, sondern bildet ihn auf vierzehn datenfreie
Fälle ab und gibt jedem einen festen Satz (neue
`StandardConnectionPresentation.swift`); eine schmale, injizierbare
Fortschrittsgrenze macht jede Zwischenphase mit wahrem Portstatus sichtbar;
die Übernahmegrenze ist `package` statt `public`. Drei echte,
revert-basierte Gegenproben (Batchvorrang, unreservierte Teillücke,
öffentliche Commissioning-Redaktion), jeweils byteidentisch
wiederhergestellt; die drei Lückennachweise laufen deterministisch über
Semaphor-Haltepunkte statt über geratene Zeitspannen. Kein echter Port,
Scanner, TX/RX, kein RX-Start, keine SwiftUI-Integration, keine Owner-App,
kein Git. Korrekturauftrag: `.agent_handoff/task-sick-0330a-k1.md`.

**Der erste K1-Rücklauf war nicht abgenommen** —
`.agent_handoff/review-sick-0330a-k1.md` benannte drei zusammenhängende
Befunde, die **im selben Slice** korrigiert sind (keine neue K-Runde):
(H1) `StandardConnectionPhase` bettet keine `CommissioningPhase` mehr ein,
sondern den eigenen, feldlosen `StandardConnectionCommissioningStage` —
damit kann auch ein fremder Aufrufer keine öffentliche Standardphase mit
einem textführenden `CommissioningFailure` mehr konstruieren; eine
Quelltextgrenze prüft die Deklarationsrümpfe aller öffentlichen
Standardtypen. (H2) Vor jedem delegierten blockierenden Abschnitt wird ein
eigener, wahrer Zustand mit wahrem Portstatus gemeldet —
`checkingStartingRate`, `loggingInAndSwitchingBaudRate` und
`awaitingMeasurementStream`, jeweils nachweislich **vor** der zugehörigen
Sendung. (H3) Die neue Meldung `adoptingConfirmedIdentity` nach bestätigtem
B1 und vor der Übernahme ist der deterministische Haltepunkt für den bis
dahin fehlenden B1→MMK-Schlussnachweis: Abbruch dort, scheiternder
Portschluss, öffentlich `.portCloseFailed`/gehalten/nicht final, danach
genau ein erfolgreicher `retryClose()`. Drei echte, revert-basierte
Gegenproben, jeweils byteidentisch wiederhergestellt. SICK-0330b bleibt bis
zur Abnahme dieser Runde gesperrt.

## macOS-12-Präsentationslast (MACOS12-LEISTUNG)

`MeasurementSessionStatus` und beide `barState.ready`-Werte enthalten keine
Rate. Statusabonnenten erhalten nur diskrete Übergänge; beide Bedienmodelle
vergleichen den vollständigen Folgezustand vor der Publikation. Das
Simulationsmodell übernimmt den empfangenen Statuswert, statt im `willSet`
den noch alten Koordinatorwert zu lesen. `RXSession.profileRateDisplay`
übernimmt Rate getrennt, höchstens einmal pro monotone Sekunde und auf
0,01 Hz gerundet; neue/fehlgeschlagene/beendete Verbindungen löschen den
alten Wert sofort. Nur Hz-Textblätter beobachten dieses Objekt. Die
Evidenzkarte baut ihren Exporttext bei Statuswechseln und auf ausdrücklichen
Export neu; aktuelle Raten/Zähler sind ein unabhängiger Exportsnapshot.

Der App-Szenengraph besitzt die Komposition über `AppOwnership`, ohne
Publikationen ihrer Kindmodelle weiterzureichen. Commands beobachten nur den
entdoppelten Menüwert (Undo/Redo, Sperre, Modus, Sichtbarkeit und
Clock-Richtung). Der Settings-Rahmen beobachtet den Arbeitsbereich; Profilrate,
Entwicklungslog und Scanner-Livezustand gehören eigenen Teilansichten.
Kopfleistenknöpfe beobachten keine RX-/Simulationsstatusrate. Auch die
Referenzmesskarte beobachtet Messwerte ausschließlich im Live-Textblatt. Scanner-Handoffs
werden erst nach dem `willSet`-Durchlauf konsumiert; vor dem Verbindungsversuch
wird der aktuelle Wert erneut geprüft, damit Abbruch, Ersatz und mehrere
Fenster keine veralteten oder doppelten Versuche auslösen. Editable
Scanner-Development-Regler übernehmen nur geänderte Kontrollwerte nach dem
vollständigen Main-Thread-Übergang. Alle Settings-Reiter einschließlich
Perform erzwingen StageTheme und dunkle Darstellung auch im System-Hellmodus.

Der harte Offline-Zählvertrag gilt nach eingeschwungenem Streaming: Ohne
menürelevanten Übergang darf kein Profil die Szenen-Besitzgrenze, Commands,
Settings-Regler oder Kopfleistenknöpfe invalidieren. Die Vorhergrenze bildet
die früheren App-Abonnements im Offline-Hosting nach; sie ist keine gestartete
SwiftUI-App. Zahlen, Gegenprobe und Bilder stehen im aktuellen Coder-Rücklauf.
Der Owner-sample vom 17.10. belegt SwiftUI-Szenen-/Menü-/Buttonlast am
Intel-iMac; die CPU-Wirkung des Umbaus auf macOS 12 bleibt durch einen neuen
Owner-Lauf mit `sample` zu bestätigen.

`scripts/make-app-bundle.sh release --universal` baut beide Architekturen mit
macOS-12-Triple in getrennten Scratch-Verzeichnissen, vereinigt erst danach
mit `lipo` und signiert das fertige Bundle. Der Standardaufruf bleibt nativ.
Mit `SICK_TEST_ARTIFACT_DIR` liegen Bundle und Universal-Scratch ausschließlich
im Artefaktordner; dieser Weg registriert das Bundle nicht bei LaunchServices.


## Verlustfreie Raumaufnahme und ruhende Anzeige (LEISTUNG-2)

Die einzige Eingangsbindung verzweigt jedes Sitzungsereignis zusätzlich zum
Runtime-Pfad an `RoomCaptureWorker`. Seine serielle Queue ordnet Beginn,
Abbruch, Profil und Sitzungsende; der dreisekündige Countdown richtet sich
weiter nach Profilzeit. Danach werden genau 125 aufeinanderfolgende Profile
einer Sitzung aufgenommen. Verlust, Sitzungs-/Geometriewechsel und eine
Sequenzlücke brechen mit Hinweis ab; vorhandene Konturen bleiben erhalten.
Main erhält ganzzahlige Prozentwerte (höchstens 100 Fortschrittsänderungen)
und das bestehende Konturergebnis. Generationen verwerfen alte Rückläufe nach
Abbruch, Preset- oder Moduswechsel. Fit und die Perform-Erlaubnis bleiben im
Dokumentbesitzer. Die Messfeldsichtbarkeit hat keinen Einfluss auf Aufnahme,
Runtime, Audio, MIDI oder Clock.

Die Anzeigepumpe hat keinen Timer: Der Briefkasten signalisiert neue Stände
über genau einen ausstehenden Main-RunLoop-Block für Normal- und
Tracking-Modus. Rückstau wird auf das neueste Bild zusammengefasst; ein
Generationszähler ersetzt den vollständigen Bildvergleich. Diskrete
Überlastmeldungen nutzen dieselbe Pumpe, auch wenn Q auf eine Ausgabe wartet.
Die Statusübergabe bleibt bewusst getrennt: Ihre 64er-Bündel erhalten
Lern-/Referenzproben und die Reihenfolge bis zur Portfreigabe. Sie kann weder
von der Anzeigesichtbarkeit abhängen noch durch „neuestes Bild gewinnt“
ersetzt werden. Es bleibt genau ein Profilabonnement und ein Portbesitzer.

Ein Beobachter am Instrumentfenster verarbeitet Verdeckung, Minimierung und
App-Ausblenden. Er pausiert Pumpe, Canvas, Pegel- und Diagnoseleser; Rückkehr
fordert genau ein aktuelles Bild an. Die Mini-Klaviatur meldet nur ihre
Montage; die native Fenstersichtbarkeit begrenzt ihren Monitorbedarf.
Beim Wiederanlauf publiziert Q nach Monitoraktivierung das aktuelle Bild,
ohne vorgeschaltete alte Catch-up-Kopie. Beide Reihenfolgen von Montage-
und Sichtbarkeitsänderung sind abgedeckt. Pegel und Diagnose verwenden tolerante
Timer (20 % Leeway); Diagnose publiziert nur geänderte Anzeigewerte und hält
keine ungenutzte Bildkopie. USB-Hotplug kommt über IOKit-Benachrichtigungen
für BSD-Serial-Services ohne Portöffnung. Nur bei abgewiesener Registrierung
bleibt die 1-Hz-Abfrage mit 200 ms Leeway. Musikalische Deadlines und Clock
verwenden weiterhin den exakten Zeitweg ohne Leeway.

Implementiert; automatische Zähl-/Lebenszyklusprüfungen und gemessene
Gegenproben im letzten Coder-Rücklauf. Reale Einmessdauer bei verdecktem
Messfeld und CPU-/`sample`-Vergleich am Intel-iMac bleiben Owner-Abnahme.


## Clock-, Pegel- und Profilpräsentation (LEISTUNG-3)

Das Dokumentmodell publiziert weder Clock-Empfang noch Profil- oder
Pegeltelemetrie. `ClockDisplayState` ist ein eigenes Beobachtungsobjekt für
Tempo-Kopfleiste und Sync-Settings. Der 100-ms-Empfangstimer läuft nur bis zur
Verlusterkennung und ruht danach auch bei einer ausgewählten stummen Quelle.
Das erste neue Clock-Paket reaktiviert ihn. Start/Continue nach Verlust
reaktiviert auch ohne folgende Ticks genau die nötige Verlustprüfung, damit
die musikalische Hostzeit wieder anhält. Fehlende MIDI-Quellen werden
ereignisgesteuert über CoreMIDI-Endpoint-Benachrichtigungen erneut geöffnet,
ohne Wiederverbindungstimer. Abwahl, Schlaf und Beenden entfernen Beobachtung,
Timer und Port; späte Meldungen prüfen die aktuelle Auswahl auf der Queue.
Clock-Senden und der musikalische Hostzeitweg behalten ihre exakten Deadlines.

Alle sichtbaren Kanal- und Summenleser teilen einen 30-Hz-`MeterReadPulse`.
Decay-Hüllkurve, Tap-Zähler und Clip-Haltezeit bleiben privat. Publiziert
werden nur Pegeländerungen auf 0,5 dB (unter −60 dBFS Stille) und der Wechsel
der Übersteuerungsanzeige. Nach Einschwingen verursachen Stille und konstanter
Pegel keine Publikationen. Live-Balken, Clip-Knopf und statische
`equatable()`-Skala haben eigene Beobachtungsgrenzen. Sichtbarkeit und
Audiolauf schalten die Leser weiter nach dem LEISTUNG-2-Vertrag.

Häufig wiederholbare Abweisungen gehören `InstrumentNoticeState`, ohne das
Dokument mitzupublizieren. Undo/Redo sind abgeleitete Werte ohne eigenen Takt;
internes Tempo, Transport und Richtung ändern sich nur durch echte Bedienung.
Diese diskreten Dokumentänderungen bleiben beim Dokumentbesitzer.

`RXSession` aktualisiert vollständige Evidenz samt letztem Profil in-place
auf Main; Diagnose und Zonenwerkzeuge lesen sie bei Bedarf. Beobachter erhalten
nur den entdoppelten `measurementStatus`, die Rate ihr eigenes Anzeigeobjekt.
Der bestehende einzelne Lern-/Referenz-Profilweg bleibt erhalten. Nur aktive
Sammler verändern Editor-/Referenzwerte; im ruhenden Editor wird weder kopiert
noch die große Struktur verglichen. Anzeigeprofile werden über Sitzung und
Sequenz identifiziert, Zelländerungen auf demselben Profil bleiben sichtbar.
`DisplayFrame.activeCells` wird beim Erstellen auf Q nach UUID-Bytes sortiert;
die Anzeige verwendet die bereits adaptierte unveränderliche Eingangsgeometrie
auch für Detektionsoverlays und den Canvas-Kontext.

Automatisch geprüft: echte Fake-Eingangswege Scanner/Simulation × 90/361 mit
laufender Fake-Clock und Fake-Pegeln, Clock-/Pegel-Publikationszähler,
Verlust/Stille/Rückkehr, Quellwechsel, Schlaf und Beenden sowie Offline-Bilder.
Reale CPU-/`sample`-Messung am Intel-iMac bleibt Supervisor-/Owner-Nachweis.
Parser, Eingangspuffer und die doppelte Eingangsdekodierung (Review P7) sind
ausdrücklich außerhalb dieses Vertrags und unverändert.


## Native Live-Ebenen (LIVE-NATIV, 17.11.2026)

Anlass: FIRSTofFIFTH v1.20.5 maß auf dem 5K-iMac den Hauptthread zu 86 % belegt,
überwiegend `CA::Transaction::commit → NSHostingView.layout → ViewRendererHost.render`.
Planarium zeigte dasselbe Muster trotz sauberer Beobachtungsgrenzen: Jede
SwiftUI-Invalidierung, auch nur eines Canvas-Blatts, legt das ganze Fenster neu aus
und baut dessen Display-Liste neu (Prüfstand vorher: 150 Wurzel-Layouts in 3 s).

Vertrag:

- Messbild (`LiveMeasurementCanvas`), aktive/gehaltene Zellen
  (`SpatialInstrumentActiveLayer`) und Pegelbalken (`HostedMeterBars`) sind
  layer-backed `NSView`s hinter `NSViewRepresentable`. Die Anzeigeobjekte markieren sie
  per Combine direkt zur Anzeige (`needsDisplay`); SwiftUI wertet sie nur bei Editor-
  oder Strukturänderungen aus und installiert dann einen neuen Maler.
- `@Published` sendet vor dem Setzen: Das Messbild markiert nur und zeichnet im
  Anzeigezyklus mit dem dann aktuellen Stand; aktive Zellen und Pegel speichern den
  gelieferten Wert. Aktive und gehaltene Zellen werden als Paar entdoppelt.
- `LiveLayerView` zeichnet nicht in eine Bitmap. Der Maler zeichnet Vektoroperationen
  auf (`LiveCanvas`, Teilmenge von `GraphicsContext`); `updateLayer` überträgt sie auf
  wiederverwendete `CAShapeLayer`s, die Core Animation außerhalb des Prozesses rendert.
  Eine feldgroße CPU-Bitmap je Profil (gemessen ≈ 4 ms auf M1, wächst mit der
  Pixelfläche) entfällt. `draw(_:)` spielt dieselben Operationen für `cacheDisplay`-
  Bilder ab. Jeder Aufruf bleibt eine eigene Operation in Aufrufreihenfolge (keine
  automatische Zusammenlegung: halbtransparente Überlappungen bleiben exakt); bewusst
  gebündelt zeichnet nur der Aufrufer (Rohscanpunkte als ein Pfad). Clip ist auf seinen
  Block begrenzt, Strichmuster gelten je Strich, Text wird als zwischengespeicherte
  Glyphenkontur gezeichnet, Farbglyphen (Emoji) als kleine Bitmap. Dynamische Farben
  werden im Erscheinungsbild der Ansicht aufgelöst wie in SwiftUI.
- Pegelbalken sind klein und zeichnen per `draw(_:)` (zwei Balken, Verlauf), ohne
  SwiftUI-Transaktion. Clip-LED und Skala bleiben SwiftUI (ereignisgesteuert bzw.
  `equatable()`).
- Die Flaggenlegende beobachtet nur entdoppelte Flaggenzählungen.

Nachweis: `AcceptanceAViewBudgetTests` läuft jetzt in einem unsichtbaren, als sichtbar
gemeldeten Fenster mit dem Fenster-Aktualisierungszyklus (`layoutIfNeeded`,
`displayIfNeeded`) und verlangt höchstens zwei Wurzel-Layouts bei 75 Profilen und 90
Pegeltakten, zugleich mehr als 50 native Messbilder (Frischeprobe). Release, M1,
3 Läufe je Fassung: vorher 19,1–20,6 % Main-CPU / 150 Wurzel-Layouts, nachher
6,7–10,1 % / 1. `LiveLayerViewTests` vergleicht Bühnenweg (Layerbaum) und Bildweg,
einschließlich Alpha-Überlappung, Slot-Wiederverwendung, Emoji-Text, Quellwechsel der
Abos und Pegel-Neuzeichnung bei Größenwechsel (Befunde aus dem Codex-Review).
Offen: Messung am Intel-iMac 5K/macOS 12; bewusst nicht nativ sind Perform-Zellnamen,
Mini-Klaviatur im Mixerkopf, Arpeggiator-Modulationsanzeige, Hz-Anzeige und das
Output-Monitor-Fenster (eigener SwiftUI-Host, im Prüfstand ≈ 27 % bei offenem Fenster).

## MIDI-FX-Kanalvertrag (MIDI-FX-1 B2a)

AU-Kanalzüge besitzen bis zu vier geordnete `midiEffects` mit stabiler Platz-ID,
Typ, Bypass und Chord-Parametern. Fehlendes Feld bedeutet leere Kette; leere
Ketten werden nicht zusätzlich serialisiert. V6- und Kanalpreset-Formate bleiben
lesbar; Werkspresets werden nicht umgeschrieben. Externe MIDI-Ziele haben in
B2a keine Effektkette und keinen Effektknopf im SUM-Bereich; ihre persistente
Kanalzug-Zuordnung gehört zu B2b.

Chord transformiert nur Notenwerte für die zugehörige AU-stripID vor dem
SpatialNoteLedger. Die Tonhöhentabellen werden beim Kompilieren aufgebaut;
Besitzer, Velocity, Übergangsart und PANIC-Flächensperre bleiben beim Ledger.
Scale wählt die nächste Skalenstufe (Gleichstand abwärts), bildet jeden zweiten
Skalenton als Drei-/Vierklang und wendet Umkehrung, Oktavlage und offene Lage
an. Single transponiert einen gelernten Akkord relativ zur Lerntaste. Multi
speichert absolute Akkorde pro Taste; unbelegte Tasten reichen den Originalton durch.
Doppelte Ausgangstonhöhen werden auf die höchste Velocity zusammengeführt. Außerhalb
des Auslösebereichs werden Noten unverändert durchgereicht. Tonhöhen außerhalb
0–127 werden verworfen. Mehrere Plätze laufen in Dokumentreihenfolge.

Hold/Toggle und Verlust folgen dem bestehenden Lösevertrag. Änderungen einer
Kette lösen zuvor besessene Noten dieses AU-Kanalzugs bei der Installation;
für reine Chord-Ketten bleibt der bisherige Ausgabepfad bestehen. Leere und überbrückte Ketten verändern
die Ereignisausgabe nicht. Lernen erfolgt ausschließlich per Mini-Klaviatur:
Learn, Auslösetaste, Akkordtöne, Learn beenden. Bezug für Single/Multi,
Auslösebereich und Lernfolge: [Apple Chord Trigger](https://support.apple.com/en-in/guide/logicpro/lgce9d7955e9/mac).

### Arpeggiator im AU-Kanalzug (MIDI-FX-1 B3a)

Ein Kanalzug enthält höchstens einen Arpeggiator (Owner 20.10.2026). Chord davor liefert den
Ledger-Eingangssatz; Chord danach transformiert jeden erzeugten Schritt.
Die Ledger-Töne klingen mit aktivem Arpeggiator nicht direkt. Hold und Toggle
halten dessen Eingangssatz. Externe MIDI-Ziele bleiben unverändert.

Q plant mit 50 ms Vorlauf; der vorhandene Instrument-PreRender-Observer
liest einen vorallokierten SPSC-Ring (256 Ereignisse) und übergibt die
MIDI-Bytes anhand absoluter Samplepositionen. Nur die Samplezeit des
Renderzyklus bestimmt die Ausgabe. Ein fester Anker je Generation hält die
Hostzeit-Sample-Umrechnung auch bei 44,1 kHz unabhängig von Q-Ankunftszeiten.
Ein fester Render-Kalender ordnet vorgezogene neue Schritte vor langen alten
Gate-Offs ein; Ring und Kalender teilen dasselbe Budget von 256 Ereignissen.
Stimmenkennungen verhindern, dass alte Offs erneut angeschlagene Töne lösen.
Render führt sein Off-Buch synchron zur
Übergabe jedes On/Off; dort laufen weder Swift noch Locks oder Allokationen.
Abbruch invalidiert die Kanalzug-Generation und löst spätestens im nächsten
Renderzyklus das Off-Buch. Q sendet zusätzlich sofortige Offs und Offs hinter
dem möglicherweise noch laufenden Quantum; eine Sample-Barriere verhindert
vorzeitigen Neustart derselben Tonhöhe. Bei stehender Engine bleibt dieser
Q-Löseweg wirksam. Ringüberlauf invalidiert den Besitzer und sperrt ihn bis
zur Eingangsfreigabe oder einem expliziten Reset.

Up, Down, Up/Down (ohne doppelte Endpunkte), Random und As Played arbeiten
mit 1–4 Oktaven. Rate: 1/4, 1/8, 1/8T, 1/16, 1/16T, 1/32; Gate 10–100 %,
Swing 0–75 % für gerade Teilungen, Velocity ursprünglich oder fest 1–127.
Der erste Schritt beginnt sofort im nächsten Renderzyklus; Sync to beat
wartet auf den nächsten Rasterpunkt. Tempoänderungen beeinflussen nur noch
nicht geschriebene Schritte; eine Tempo-Weckquelle erreicht Q auch ohne
neue Profile bei Hold/Toggle. Externer Transport-Stopp behält das letzte Tempo.
Handsteuerung nutzt ausschließlich bestehende Continuous-Flächen und den gemessenen
Skalar. Ziele adressieren Kanalzug, Arpeggiator-Slot und Rate/Oktaven/Gate/Swing/Velocity.
Der Compiler markiert fehlende, falsche und überbrückte Slots als inaktiv; der Inspector
zeigt den fehlenden Empfänger. Der nächste Compilerlauf stellt gültige Ziele wieder her.

Live-Modulation bleibt Q-Zustand und wird als Anzeige-Snapshot an den Editor geliefert;
Dokument, Preset und Undo behalten die Editorwerte; nur der offene Effekteditor abonniert
die Live-Anzeige, nicht der Dokument-Publisher. Die zuletzt betretene aktive Fläche
gewinnt je Ziel; bei Austritt übernimmt die vorherige aktive Fläche, sonst der Editorwert.
Rate (sechs Teilungen), Oktaven (1–4) und Velocity (1–127) werden gerundet; die Hysterese
hält den bisherigen Rasterwert bis einen halben Schritt über der Rundungsgrenze.
Gate bildet 10–100 %, Swing 0–75 % ab. PANIC, Stopp, Szene, Presetwechsel und Eingangsverlust
verwerfen die Modulation. Bereits geschriebene On/Off-Ereignisse behalten Zeit und Generation.
Ratenwechsel setzen den nächsten ungeschriebenen Schritt relativ zum letzten geplanten
Schritt fort. Vor dem ersten geschriebenen Schritt wird ein wartender Sync-Start
auf das neue Raster ausgerichtet. Liegen neue Rasterpunkte bei einem Wechsel von langsam zu schnell bereits
in der Vergangenheit, wird phasentreu der erste noch erreichbare Punkt gewählt; vergangene
Schritte werden nicht als Schwall nachgeholt. Der Renderpfad bleibt unverändert. „MIDI FX“ im Zielmenü weist die Fläche
zu; `hand.raised` zeigt den aktuellen Live-Wert neben den unveränderten Editorreglern.

## Bühnenaktivität und Wiederanlauf

Die Composition besitzt höchstens eine ProcessInfo-Aktivität, solange Audio
läuft oder der Scanner-Port für Messbetrieb belegt ist. Audio und Scanner
teilen den Besitzer; nach Ende beider und beim Beenden wird sie geschlossen.
App Nap und Displayschlaf sind unterdrückt, expliziter Systemschlaf bleibt
möglich und benutzt den vorhandenen Löse-/Frischprofilpfad.

„Reopen last preset“ ist standardmäßig an. Erfolgreiches Laden und Speichern
merkt den kanonischen Namen (einschließlich Factory-Präfix) und die Szene;
Szenenwechsel aktualisieren diese app-weite Präferenz. Der Start benutzt den
normalen Preset-Ladepfad einschließlich Plugin-Wiederherstellung. Fehlende
Presets oder beschädigte Recovery führen zum leeren Start mit Hinweis, ohne
Alert. Ohne frische Messung gibt es keine Gate-Auslösung.

Dokument-/Mischpult-Edits, Beschreibung und das Schließen eines Plugin-Fensters
markieren Recovery ohne Zustandsabfrage. Zehn Sekunden nach dem letzten Ereignis
wird genau ein Snapshot aufgenommen; unter Performance-Sperre bleibt die Marke
bis zum Entsperren offen. Ohne Änderung gibt es keine Abfrage. Abseits
Main wird im V6-Presetformat atomar nach Application Support/SickPLSMonitor/Recovery
geschrieben. Nur eine neuere Recovery als die letzte Speicherung/Ladebaseline
hat beim Start Vorrang (Anzeige „Recovered – not saved“). Eine app-weite
Dateigeneration im V6-Namen entwertet ältere, noch eingereihte Snapshots sofort
bei Save/Load; ein Absturz zwischen spätem Schreiben und Löschung stellt somit
nicht den älteren Stand wieder her. Sie überschreibt
kein Preset; erfolgreiches Speichern oder regulärer Ladewechsel entfernt sie.
