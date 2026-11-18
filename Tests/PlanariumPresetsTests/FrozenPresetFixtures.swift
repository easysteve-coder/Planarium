import Foundation

/// **Eingefrorene echte Presetbelege** (M-0, Revisorauftrag vom 27.09.2026).
///
/// Diese Zeichenketten sind **wörtlich** das, was der Encoder am 28.09.2026 im
/// Format 3 geschrieben hat, bevor der Umbau auf das Geräteraster begann. Sie
/// werden **nie** neu erzeugt: ein mit dem jeweils aktuellen Encoder gebautes
/// Objekt würde nur JSON-Symmetrie belegen, nicht die physische Bedeutung der
/// gespeicherten Zahlen. Genau die ist der Gegenstand der Migration.
///
/// Wer hier etwas ändert, ändert einen Beleg. Das ist nur zulässig, wenn ein
/// echter Altstand falsch abgebildet war -- nicht, um einen Test grün zu machen.
enum FrozenPresetFixtures {

    /// Format 3 mit **alter adaptiver Polaradresse**.
    ///
    /// Die eine bemalte Zelle ist `(ring: 2, angularIndex: 8)` bei
    /// `grid.cellSizeMeters == 0.5`. Unter der **alten** Adressfunktion deckt
    /// sie nachgemessen:
    ///
    /// - Radius **1,0 m bis 1,5 m** (`ring * 0.5` bis `(ring+1) * 0.5`),
    /// - Peilung **0,0° bis 22,5°** (`angularIndex * 22.5 - 180`; die adaptive
    ///   Schrittweite ist bei Außenradius 1,5 m und Ringhöhe 0,5 m genau 22,5°).
    ///
    /// Daraus folgt die **physische** Trefferwartung auf dem 361-Punkt-Raster
    /// (`bearing = -90 + tick * 0.5`, also Tick 180 = 0°, Tick 225 = 22,5°):
    ///
    /// | Probe | Tick | Rohwert cm | trifft |
    /// |---|---:|---:|---|
    /// | innen, unterer Rand | 180 | 100 | ja |
    /// | innen, oberer Rand | 224 | 149 | ja |
    /// | winklig darunter | 179 | 120 | nein |
    /// | winklig darüber | 225 | 120 | nein |
    /// | radial darunter | 200 | 99 | nein |
    /// | radial darüber | 200 | 150 | nein |
    ///
    /// Die Zelle trägt genau eine Aktion: MIDI-Note 60, Velocity 100, Kanal 0.
    /// Dass diese Aktion die Migration übersteht, ist Teil des Vertrags.
    static let polarVersion3 = #"""
{
  "assignment" : {
    "gate" : "98465FC8-882E-4D0C-9BBA-CBC2C9AA9626",
    "pitch" : "D17C138E-7C87-40C7-BFAF-51CAEE911BC8"
  },
  "audioUnits" : {
    "entries" : [
      {
        "componentManufacturer" : 2,
        "componentSubType" : 1,
        "componentType" : 1635083896,
        "isBypassed" : true
      }
    ]
  },
  "delay" : {
    "feedbackPercent" : 30,
    "isEnabled" : true,
    "sendLevel" : 0.3,
    "timeSeconds" : 0.25
  },
  "formatVersion" : 3,
  "gate" : {
    "polarity" : "aboveThreshold",
    "threshold" : 0.5
  },
  "layers" : [
    {
      "mixRule" : "firstActive",
      "role" : "pitch",
      "targetKind" : "discrete",
      "zoneIDs" : [
        "D17C138E-7C87-40C7-BFAF-51CAEE911BC8"
      ]
    },
    {
      "mixRule" : "firstActive",
      "role" : "volume",
      "targetKind" : "continuous",
      "zoneIDs" : [

      ]
    },
    {
      "mixRule" : "firstActive",
      "role" : "filter",
      "targetKind" : "continuous",
      "zoneIDs" : [

      ]
    },
    {
      "mixRule" : "firstActive",
      "role" : "gate",
      "targetKind" : "gate",
      "zoneIDs" : [
        "98465FC8-882E-4D0C-9BBA-CBC2C9AA9626"
      ]
    },
    {
      "mixRule" : "firstActive",
      "role" : "effectSend",
      "targetKind" : "continuous",
      "zoneIDs" : [

      ]
    }
  ],
  "mapping" : {
    "effectSendPolarity" : "normal",
    "filterHighestHz" : 8000,
    "filterLowestHz" : 200,
    "filterPolarity" : "normal",
    "maximumAmplitude" : 0.8,
    "pitchHighestHz" : 880,
    "pitchLowestHz" : 110,
    "pitchPolarity" : "normal",
    "volumeCurve" : "linear",
    "volumePolarity" : "normal"
  },
  "masterGain" : 0.7,
  "midi" : {
    "bendRangeSemitones" : 12,
    "channel" : 3,
    "effectSendController" : 91,
    "filterController" : 74,
    "pitchInverted" : false,
    "rootNote" : 33,
    "spanSemitones" : 60,
    "volumeController" : 7
  },
  "name" : "M0-Polar-v3",
  "prediction" : {
    "alpha" : 0.5,
    "beta" : 0.1,
    "outlierThreshold" : 0.3,
    "predictionHorizonSeconds" : 0.05,
    "staleTimeoutSeconds" : 0.5
  },
  "reverb" : {
    "character" : "smallRoom",
    "isEnabled" : false,
    "sendLevel" : 0.2
  },
  "spatialWorkspace" : {
    "coordinateMode" : "polar",
    "grid" : {
      "cellSizeMeters" : 0.5
    },
    "layers" : [
      {
        "color" : {
          "alpha" : 1,
          "blue" : 0,
          "green" : 0.55,
          "red" : 1
        },
        "id" : "5C43E8C0-EFE3-473B-BF92-C97217602232",
        "isActive" : true,
        "isLocked" : false,
        "isSoloed" : false,
        "isVisible" : true,
        "name" : "Noten",
        "polarCellOverrides" : [
          {
            "angularIndex" : 8,
            "ring" : 2
          },
          [
            {
              "target" : {
                "midiNote" : {
                  "channel" : 0
                }
              },
              "value" : {
                "note" : {
                  "number" : 60,
                  "velocity" : 100
                }
              }
            }
          ]
        ],
        "polarCells" : [
          {
            "angularIndex" : 8,
            "ring" : 2
          }
        ],
        "routings" : [

        ]
      }
    ],
    "selectedLayerID" : "5C43E8C0-EFE3-473B-BF92-C97217602232"
  },
  "timbre" : {
    "attackSeconds" : 0.01,
    "decaySeconds" : 0.1,
    "filterResonance" : 1.5,
    "morph" : 0.5,
    "releaseSeconds" : 0.2,
    "sustainLevel" : 0.8
  },
  "viewport" : {
    "centerX" : 0.1,
    "centerY" : 0.2,
    "halfExtent" : 0.4
  },
  "zones" : [
    {
      "id" : "D17C138E-7C87-40C7-BFAF-51CAEE911BC8",
      "indexLowerBound" : 0,
      "indexUpperBound" : 0.5,
      "isEnabled" : true,
      "role" : "pitch",
      "shape" : {
        "columns" : 2,
        "kind" : "grid",
        "range" : 4,
        "rows" : 2,
        "values" : [
          0,
          1,
          2,
          3
        ]
      },
      "valueLowerBound" : 100,
      "valueUpperBound" : 4000
    },
    {
      "id" : "98465FC8-882E-4D0C-9BBA-CBC2C9AA9626",
      "indexLowerBound" : 0.5,
      "indexUpperBound" : 1,
      "isEnabled" : true,
      "role" : "gate",
      "shape" : {
        "kind" : "strip"
      },
      "valueLowerBound" : 100,
      "valueUpperBound" : 4000
    }
  ]
}
"""#

    /// Format 3 mit **kartesischer Altform** — der Beleg für die Importzusage
    /// aus `e3eedcf`.
    ///
    /// Die Ebene trägt `cells` und `cellOverrides` statt `polarCells`, und das
    /// Dokument trägt `coordinateMode: "cartesian"`. Diese Form kann der heutige
    /// Encoder **nicht mehr schreiben**; sie ist über den Legacy-Spiegel aus
    /// `Tests/SickPLSMonitorKitTests/LegacyDocumentFixtures.swift` erzeugt und
    /// dann in ein echtes v3-Preset eingesetzt worden.
    ///
    /// Die eine alte Zelle ist `(column: 0, row: 2)` bei
    /// `grid.cellSizeMeters == 0.5`. Sie deckt `x 0,0…0,5 m` und `y 1,0…1,5 m`;
    /// ihr Mittelpunkt liegt bei `(0,25 / 1,25)`. Die zugesagte Mittelpunktregel
    /// bildet sie nachgemessen auf `(ring: 2, angularIndex: 8)` ab — **dieselbe**
    /// Zelle wie ``polarVersion3``, und damit gilt für beide Belege dieselbe
    /// physische Trefferwartung (Tabelle dort).
    ///
    /// Die Zelle trägt genau eine Aktion: MIDI-Note 60, Velocity 100, Kanal 0.
    /// Nach dem Dekodieren liegt sie an der migrierten Polaradresse.
    static let cartesianVersion3 = #"""
{
  "assignment": {
    "gate": "98465FC8-882E-4D0C-9BBA-CBC2C9AA9626",
    "pitch": "D17C138E-7C87-40C7-BFAF-51CAEE911BC8"
  },
  "audioUnits": {
    "entries": [
      {
        "componentManufacturer": 2,
        "componentSubType": 1,
        "componentType": 1635083896,
        "isBypassed": true
      }
    ]
  },
  "delay": {
    "feedbackPercent": 30,
    "isEnabled": true,
    "sendLevel": 0.3,
    "timeSeconds": 0.25
  },
  "formatVersion": 3,
  "gate": {
    "polarity": "aboveThreshold",
    "threshold": 0.5
  },
  "layers": [
    {
      "mixRule": "firstActive",
      "role": "pitch",
      "targetKind": "discrete",
      "zoneIDs": [
        "D17C138E-7C87-40C7-BFAF-51CAEE911BC8"
      ]
    },
    {
      "mixRule": "firstActive",
      "role": "volume",
      "targetKind": "continuous",
      "zoneIDs": []
    },
    {
      "mixRule": "firstActive",
      "role": "filter",
      "targetKind": "continuous",
      "zoneIDs": []
    },
    {
      "mixRule": "firstActive",
      "role": "gate",
      "targetKind": "gate",
      "zoneIDs": [
        "98465FC8-882E-4D0C-9BBA-CBC2C9AA9626"
      ]
    },
    {
      "mixRule": "firstActive",
      "role": "effectSend",
      "targetKind": "continuous",
      "zoneIDs": []
    }
  ],
  "mapping": {
    "effectSendPolarity": "normal",
    "filterHighestHz": 8000,
    "filterLowestHz": 200,
    "filterPolarity": "normal",
    "maximumAmplitude": 0.8,
    "pitchHighestHz": 880,
    "pitchLowestHz": 110,
    "pitchPolarity": "normal",
    "volumeCurve": "linear",
    "volumePolarity": "normal"
  },
  "masterGain": 0.7,
  "midi": {
    "bendRangeSemitones": 12,
    "channel": 3,
    "effectSendController": 91,
    "filterController": 74,
    "pitchInverted": false,
    "rootNote": 33,
    "spanSemitones": 60,
    "volumeController": 7
  },
  "name": "M0-Kartesisch-v3",
  "prediction": {
    "alpha": 0.5,
    "beta": 0.1,
    "outlierThreshold": 0.3,
    "predictionHorizonSeconds": 0.05,
    "staleTimeoutSeconds": 0.5
  },
  "reverb": {
    "character": "smallRoom",
    "isEnabled": false,
    "sendLevel": 0.2
  },
  "spatialWorkspace": {
    "coordinateMode": "cartesian",
    "grid": {
      "cellSizeMeters": 0.5
    },
    "layers": [
      {
        "cellOverrides": [
          {
            "column": 0,
            "row": 2
          },
          [
            {
              "target": {
                "midiNote": {
                  "channel": 0
                }
              },
              "value": {
                "note": {
                  "number": 60,
                  "velocity": 100
                }
              }
            }
          ]
        ],
        "cells": [
          {
            "column": 0,
            "row": 2
          }
        ],
        "color": {
          "alpha": 1,
          "blue": 0,
          "green": 0.55,
          "red": 1
        },
        "id": "11111111-2222-3333-4444-555555555555",
        "isActive": true,
        "isLocked": false,
        "isSoloed": false,
        "isVisible": true,
        "name": "Noten",
        "routings": []
      }
    ],
    "selectedLayerID": "11111111-2222-3333-4444-555555555555"
  },
  "timbre": {
    "attackSeconds": 0.01,
    "decaySeconds": 0.1,
    "filterResonance": 1.5,
    "morph": 0.5,
    "releaseSeconds": 0.2,
    "sustainLevel": 0.8
  },
  "viewport": {
    "centerX": 0.1,
    "centerY": 0.2,
    "halfExtent": 0.4
  },
  "zones": [
    {
      "id": "D17C138E-7C87-40C7-BFAF-51CAEE911BC8",
      "indexLowerBound": 0,
      "indexUpperBound": 0.5,
      "isEnabled": true,
      "role": "pitch",
      "shape": {
        "columns": 2,
        "kind": "grid",
        "range": 4,
        "rows": 2,
        "values": [
          0,
          1,
          2,
          3
        ]
      },
      "valueLowerBound": 100,
      "valueUpperBound": 4000
    },
    {
      "id": "98465FC8-882E-4D0C-9BBA-CBC2C9AA9626",
      "indexLowerBound": 0.5,
      "indexUpperBound": 1,
      "isEnabled": true,
      "role": "gate",
      "shape": {
        "kind": "strip"
      },
      "valueLowerBound": 100,
      "valueUpperBound": 4000
    }
  ]
}
"""#

    /// Handgeschriebener synthetischer Altbeleg: Format 1 kannte Zuweisungen,
    /// aber noch keine geordneten Rollenstacks und keinen spatialWorkspace.
    static let historicalVersion1 = #"""
{
  "formatVersion": 1,
  "name": "M-1b-historical-v1",
  "zones": [
    {"id":"11111111-1111-1111-1111-111111111111","indexLowerBound":0,"indexUpperBound":0.2,"valueLowerBound":100,"valueUpperBound":4000,"role":"pitch","isEnabled":true,"shape":{"kind":"grid","columns":2,"rows":2,"values":[0,1,2,3],"range":4}},
    {"id":"22222222-2222-2222-2222-222222222222","indexLowerBound":0.2,"indexUpperBound":0.4,"valueLowerBound":0,"valueUpperBound":1,"role":"volume","isEnabled":true,"shape":{"kind":"strip"}},
    {"id":"33333333-3333-3333-3333-333333333333","indexLowerBound":0.4,"indexUpperBound":0.6,"valueLowerBound":200,"valueUpperBound":8000,"role":"filter","isEnabled":true,"shape":{"kind":"grid","columns":2,"rows":2,"values":[0,1,2,3],"range":4}},
    {"id":"44444444-4444-4444-4444-444444444444","indexLowerBound":0.6,"indexUpperBound":0.8,"valueLowerBound":0,"valueUpperBound":1,"role":"gate","isEnabled":true,"shape":{"kind":"grid","columns":2,"rows":2,"values":[0,1,2,3],"range":4}},
    {"id":"55555555-5555-5555-5555-555555555555","indexLowerBound":0.8,"indexUpperBound":1,"valueLowerBound":0,"valueUpperBound":1,"role":"effectSend","isEnabled":true,"shape":{"kind":"grid","columns":2,"rows":2,"values":[0,1,2,3],"range":4}}
  ],
  "assignment":{"pitch":"11111111-1111-1111-1111-111111111111","volume":"22222222-2222-2222-2222-222222222222","filter":"33333333-3333-3333-3333-333333333333","gate":"44444444-4444-4444-4444-444444444444"},
  "gate":{"threshold":0.5,"polarity":"aboveThreshold"},
  "mapping":{"pitchLowestHz":110,"pitchHighestHz":880,"pitchPolarity":"normal","filterLowestHz":200,"filterHighestHz":8000,"filterPolarity":"normal","maximumAmplitude":0.8,"volumeCurve":"linear","volumePolarity":"normal","effectSendPolarity":"normal"},
  "timbre":{"morph":0.5,"filterResonance":1.5,"attackSeconds":0.01,"decaySeconds":0.1,"sustainLevel":0.8,"releaseSeconds":0.2},
  "masterGain":0.7,
  "delay":{"isEnabled":true,"sendLevel":0.3,"timeSeconds":0.25,"feedbackPercent":30},
  "reverb":{"isEnabled":false,"sendLevel":0.2,"character":"smallRoom"},
  "prediction":{"alpha":0.5,"beta":0.1,"predictionHorizonSeconds":0.05,"staleTimeoutSeconds":0.5,"outlierThreshold":0.3},
  "audioUnits":{"entries":[{"componentType":1635083896,"componentSubType":1,"componentManufacturer":2,"isBypassed":true}]},
  "midi":{"channel":3,"bendRangeSemitones":12,"rootNote":33,"spanSemitones":60,"pitchInverted":false,"volumeController":7,"filterController":74,"effectSendController":91},
  "viewport":{"centerX":0.1,"centerY":0.2,"halfExtent":0.4}
}
"""#

    /// Handgeschriebener synthetischer Altbeleg: Format 2 trägt die bereits
    /// migrierten Rollenstacks unverändert, aber weiterhin keinen Raum.
    static let historicalVersion2 = #"""
{
  "formatVersion": 2,
  "name": "M-1b-historical-v1",
  "zones": [
    {"id":"11111111-1111-1111-1111-111111111111","indexLowerBound":0,"indexUpperBound":0.2,"valueLowerBound":100,"valueUpperBound":4000,"role":"pitch","isEnabled":true,"shape":{"kind":"grid","columns":2,"rows":2,"values":[0,1,2,3],"range":4}},
    {"id":"22222222-2222-2222-2222-222222222222","indexLowerBound":0.2,"indexUpperBound":0.4,"valueLowerBound":0,"valueUpperBound":1,"role":"volume","isEnabled":true,"shape":{"kind":"strip"}},
    {"id":"33333333-3333-3333-3333-333333333333","indexLowerBound":0.4,"indexUpperBound":0.6,"valueLowerBound":200,"valueUpperBound":8000,"role":"filter","isEnabled":true,"shape":{"kind":"grid","columns":2,"rows":2,"values":[0,1,2,3],"range":4}},
    {"id":"44444444-4444-4444-4444-444444444444","indexLowerBound":0.6,"indexUpperBound":0.8,"valueLowerBound":0,"valueUpperBound":1,"role":"gate","isEnabled":true,"shape":{"kind":"grid","columns":2,"rows":2,"values":[0,1,2,3],"range":4}},
    {"id":"55555555-5555-5555-5555-555555555555","indexLowerBound":0.8,"indexUpperBound":1,"valueLowerBound":0,"valueUpperBound":1,"role":"effectSend","isEnabled":true,"shape":{"kind":"grid","columns":2,"rows":2,"values":[0,1,2,3],"range":4}}
  ],
  "assignment":{"pitch":"11111111-1111-1111-1111-111111111111","volume":"22222222-2222-2222-2222-222222222222","filter":"33333333-3333-3333-3333-333333333333","gate":"44444444-4444-4444-4444-444444444444"},
  "layers":[
    {"role":"pitch","targetKind":"discrete","zoneIDs":["11111111-1111-1111-1111-111111111111"],"mixRule":"firstActive"},
    {"role":"volume","targetKind":"continuous","zoneIDs":["22222222-2222-2222-2222-222222222222"],"mixRule":"firstActive"},
    {"role":"filter","targetKind":"discrete","zoneIDs":["33333333-3333-3333-3333-333333333333"],"mixRule":"firstActive"},
    {"role":"effectSend","targetKind":"continuous","zoneIDs":[],"mixRule":"firstActive"},
    {"role":"gate","targetKind":"gate","zoneIDs":["44444444-4444-4444-4444-444444444444"],"mixRule":"firstActive"}
  ],
  "gate":{"threshold":0.5,"polarity":"aboveThreshold"},
  "mapping":{"pitchLowestHz":110,"pitchHighestHz":880,"pitchPolarity":"normal","filterLowestHz":200,"filterHighestHz":8000,"filterPolarity":"normal","maximumAmplitude":0.8,"volumeCurve":"linear","volumePolarity":"normal","effectSendPolarity":"normal"},
  "timbre":{"morph":0.5,"filterResonance":1.5,"attackSeconds":0.01,"decaySeconds":0.1,"sustainLevel":0.8,"releaseSeconds":0.2},
  "masterGain":0.7,
  "delay":{"isEnabled":true,"sendLevel":0.3,"timeSeconds":0.25,"feedbackPercent":30},
  "reverb":{"isEnabled":false,"sendLevel":0.2,"character":"smallRoom"},
  "prediction":{"alpha":0.5,"beta":0.1,"predictionHorizonSeconds":0.05,"staleTimeoutSeconds":0.5,"outlierThreshold":0.3},
  "audioUnits":{"entries":[{"componentType":1635083896,"componentSubType":1,"componentManufacturer":2,"isBypassed":true}]},
  "midi":{"channel":3,"bendRangeSemitones":12,"rootNote":33,"spanSemitones":60,"pitchInverted":false,"volumeController":7,"filterController":74,"effectSendController":91},
  "viewport":{"centerX":0.1,"centerY":0.2,"halfExtent":0.4}
}
"""#
}
