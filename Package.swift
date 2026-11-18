// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SickPLSCore",
    platforms: [
        .macOS(.v12), .iOS(.v15)
    ],
    products: [
        .executable(name: "planarium-preset-tool", targets: ["PlanariumPresetTool"]),
        .library(name: "PlanariumInput", targets: ["PlanariumInput"]),
        .library(name: "PlanariumMIDI", targets: ["PlanariumMIDI"]),
        .library(name: "PlanariumApplication", targets: ["PlanariumApplication"]),
        .library(name: "SickPLSCore", targets: ["SickPLSCore"]),
        .library(name: "SickPLSDeviceModel", targets: ["SickPLSDeviceModel"]),
        .library(name: "SickPLSMacTransport", targets: ["SickPLSMacTransport"]),
        .library(name: "SickPLSSimulationLink", targets: ["SickPLSSimulationLink"]),
        .library(name: "SickPLSSimulationBroadcast", targets: ["SickPLSSimulationBroadcast"]),
        .library(name: "SickPLSSimulationControl", targets: ["SickPLSSimulationControl"]),
        .library(name: "SickPLSActiveControl", targets: ["SickPLSActiveControl"]),
        .library(name: "PlanariumDomain", targets: ["PlanariumDomain"]),
        .library(name: "PlanariumRuntime", targets: ["PlanariumRuntime"]),
        .library(name: "PlanariumAudio", targets: ["PlanariumAudio"]),
        .library(name: "SickPLSMonitorKit", targets: ["SickPLSMonitorKit"]),
        .library(name: "SickPLSControlCore", targets: ["SickPLSControlCore"]),

        .library(name: "SickPLSCommissioning", targets: ["SickPLSCommissioning"]),
        .library(name: "SickPLSCommissioningControl", targets: ["SickPLSCommissioningControl"]),
        .library(name: "SickPLSSetupControl", targets: ["SickPLSSetupControl"]),

        .library(name: "PlanariumPresets", targets: ["PlanariumPresets"]),
        .library(name: "SickPolarBenchmark", targets: ["SickPolarBenchmark"]),
        .executable(name: "sick-polar-bench", targets: ["SickPolarBenchmarkCLI"]),
        .executable(name: "sick-pls-diag", targets: ["SickPLSDiagnosticCLI"]),
        .executable(name: "SickPLSMonitor", targets: ["SickPLSMonitor"]),
        .executable(name: "SickPLSSetup", targets: ["SickPLSSetup"])
    ],
    targets: [
        .target(name: "LegacyPresetTestSupport", dependencies: ["PlanariumDomain", "PlanariumPresets", "SickPLSControlCore", "SickPLSMonitorKit"], path: "Tests/LegacyPresetTestSupport"),
        .executableTarget(name: "PlanariumPresetTool", dependencies: ["PlanariumDomain", "PlanariumPresets", "SickPLSControlCore"]),
        .target(name: "SickPLSCore"),
        .testTarget(name: "SickPLSCoreTests", dependencies: ["SickPLSCore"]),
        .target(name: "SickPLSDeviceModel", dependencies: ["SickPLSCore"]),
        .testTarget(name: "SickPLSDeviceModelTests", dependencies: ["SickPLSCore", "SickPLSDeviceModel"]),
        .target(name: "SickPLSMacTransport", dependencies: ["SickPLSCore"]),
        .target(name: "SickPLSSimulationLink", dependencies: ["SickPLSCore"]),
        .target(name: "SickPLSSimulationBroadcast", dependencies: ["SickPLSCore", "SickPLSDeviceModel", "SickPLSSimulationLink"]),
        .target(name: "SickPLSSimulationControl", dependencies: ["PlanariumInput", "SickPLSCommissioning", "SickPLSCore", "SickPLSMacTransport", "SickPLSMonitorKit", "SickPLSSimulationLink"], path: "Sources/SickPLSSimulationControl"),
        .testTarget(
            name: "SickPLSSimulationControlTests",
            dependencies: ["PlanariumInput", "PlanariumScannerUI", "SickPLSCommissioning", "SickPLSCore", "SickPLSDeviceModel", "SickPLSMacTransport", "SickPLSMonitorKit", "SickPLSSimulationBroadcast", "SickPLSSimulationControl", "SickPLSSimulationLink"]
        ),
        .testTarget(name: "SickPLSMacTransportTests", dependencies: ["SickPLSCore", "SickPLSMacTransport"]),
        .testTarget(name: "SickPLSSimulationLinkTests", dependencies: ["SickPLSControlCore", "SickPLSCore", "SickPLSSimulationLink"]),
        .testTarget(name: "SickPLSSimulationBroadcastTests", dependencies: ["PlanariumInput", "PlanariumScannerUI", "SickPLSCore", "SickPLSDeviceModel", "SickPLSMonitorKit", "SickPLSSimulationBroadcast", "SickPLSSimulationControl", "SickPLSSimulationLink"]),
        .target(name: "SickPLSActiveControl", dependencies: ["SickPLSCore", "SickPLSMacTransport"]),
        .testTarget(name: "SickPLSActiveControlTests", dependencies: ["SickPLSActiveControl", "SickPLSCore", "SickPLSMacTransport"]),
        .executableTarget(
            name: "SickPLSDiagnosticCLI",
            dependencies: ["SickPLSActiveControl", "SickPLSCore", "SickPLSMacTransport"]
        ),
        .testTarget(
            name: "SickPLSDiagnosticCLITests",
            dependencies: ["SickPLSActiveControl", "SickPLSCore", "SickPLSDiagnosticCLI", "SickPLSMacTransport"]
        ),
        .target(name: "PLSDeviceValues", dependencies: ["SickPLSCore"]),
        .target(name: "SickPLSControlCore", dependencies: ["PLSDeviceValues", "SickPLSCore"]),
        .testTarget(name: "SickPLSControlCoreTests", dependencies: ["SickPLSControlCore", "SickPLSCore"]),
        .testTarget(name: "PlanariumScannerUITests", dependencies: ["PlanariumApplication", "PlanariumAudio", "PlanariumDomain", "PlanariumInput", "PlanariumMIDI", "PlanariumPresets", "PlanariumRuntime", "PlanariumScannerUI", "SickPLSActiveControl", "SickPLSCommissioning", "SickPLSCommissioningControl", "SickPLSControlCore", "SickPLSCore", "SickPLSMacTransport", "SickPLSMonitorKit", "SickPLSSimulationControl", "SickPLSSimulationLink"], path: "Tests/SickPLSPerformanceSessionTests"),
        .testTarget(name: "PlanariumPresetValuesTests", dependencies: ["LegacyPresetTestSupport", "PlanariumDomain", "PlanariumPresets"], path: "Tests/SickSynthAudioTests"),
        .testTarget(name: "PitchDomainTests", dependencies: ["PlanariumDomain"], path: "Tests/SickThereminControlTests"),
        .testTarget(name: "PlanariumMIDIContractTests", dependencies: ["PlanariumMIDI"], path: "Tests/SickCoreMIDIOutputTests"),
        .testTarget(name: "PlanariumApplicationTests", dependencies: ["PlanariumApplication", "PlanariumAudio", "PlanariumDomain", "PlanariumInput", "PlanariumMIDI", "PlanariumRuntime", "SickPLSControlCore", "SickPLSCore", "SickPLSMacTransport", "SickPLSMonitorKit", "PlanariumPresets"]),
        .target(name: "PlanariumDomain", dependencies: ["PLSDeviceValues", "SickPLSCore"]),
        .target(name: "PlanariumHostClockDSP"),
        .target(name: "PlanariumRuntime", dependencies: ["PlanariumDomain", "PlanariumHostClockDSP"]),
        .target(name: "PlanariumInput", dependencies: ["PlanariumDomain", "PlanariumRuntime", "SickPLSCommissioning", "SickPLSCore", "SickPLSMacTransport"]),
        .target(name: "PlanariumScannerUI", dependencies: ["PlanariumInput", "SickPLSCommissioning", "SickPLSCommissioningControl", "SickPLSControlCore", "SickPLSCore", "SickPLSMacTransport", "SickPLSMonitorKit"]),
        .target(name: "PlanariumMIDI", dependencies: ["PlanariumDomain", "PlanariumRuntime"]),
        .target(name: "PlanariumApplication", dependencies: ["PlanariumAudio", "PlanariumDomain", "PlanariumInput", "PlanariumMIDI", "PlanariumRuntime", "SickPLSControlCore", "SickPLSCore", "SickPLSMacTransport", "SickPLSMonitorKit", "PlanariumPresets"]),
        .target(name: "PlanariumFadeDSP"),
        .target(name: "PlanariumObjCCatch"),
        .target(name: "PlanariumAudio", dependencies: ["PlanariumDomain", "PlanariumFadeDSP", "PlanariumObjCCatch", "PlanariumRuntime", "PlanariumHostClockDSP"]),
        .testTarget(name: "PlanariumAudioTests", dependencies: ["PlanariumAudio", "PlanariumDomain", "PlanariumFadeDSP", "PlanariumRuntime", "PlanariumMIDI"]),
        .testTarget(name: "PlanariumRuntimeTests", dependencies: ["PlanariumDomain", "PlanariumRuntime", "SickPLSControlCore"]),
        .testTarget(name: "PlanariumDomainTests", dependencies: ["PlanariumDomain", "SickPLSControlCore", "SickPLSCore", "SickPLSMonitorKit", "SickPLSSimulationLink"]),
        .target(name: "SickPLSMonitorKit", dependencies: ["PlanariumDomain", "PlanariumInput", "SickPLSControlCore", "SickPLSCore", "SickPLSMacTransport"]),

        .testTarget(
            name: "SickPLSMonitorKitTests",
            dependencies: ["LegacyPresetTestSupport", "PlanariumApplication", "PlanariumDomain", "PlanariumInput", "PlanariumMIDI", "PlanariumPresets", "PlanariumRuntime", "SickPLSControlCore", "SickPLSCore", "SickPLSMacTransport", "SickPLSMonitorKit", "SickPLSSimulationLink"]
        ),
        .target(name: "SickPolarBenchmark", dependencies: ["PlanariumDomain", "SickPLSControlCore", "SickPLSCore", "SickPLSMonitorKit"]),
        .testTarget(name: "SickPolarBenchmarkTests", dependencies: ["SickPLSControlCore", "SickPLSCore", "SickPLSMonitorKit", "SickPolarBenchmark"]),
        .executableTarget(
            name: "SickPolarBenchmarkCLI",
            dependencies: ["SickPLSControlCore", "SickPLSCore", "SickPLSMonitorKit", "SickPolarBenchmark"]
        ),

        .executableTarget(name: "SickPLSMonitor", dependencies: ["PlanariumApplication", "PlanariumAudio", "PlanariumDomain", "PlanariumInput", "PlanariumMIDI", "PlanariumPresets", "PlanariumRuntime", "PlanariumScannerUI", "SickPLSCommissioning", "SickPLSCommissioningControl", "SickPLSControlCore", "SickPLSCore", "SickPLSMacTransport", "SickPLSMonitorKit", "SickPLSSetupControl", "SickPLSSimulationControl", "SickPLSSimulationLink"]),
        // Kleiner, eigenständiger Diagnosehelfer für den belegten
        // 9600→38400→MMK-Ablauf. Er besitzt keine Audio-, MIDI-,
        // Zonen- oder Performance-Abhängigkeit und sendet nie ohne
        // ausdrückliche Bedienhandlung.
        .executableTarget(
            name: "SickPLSSetup",
            dependencies: ["SickPLSActiveControl", "SickPLSCommissioning", "SickPLSCore", "SickPLSMacTransport", "SickPLSSetupControl"],
            path: "Sources/SickPLSSetup",
            exclude: [
                "SetupConsoleModel.swift", "HexTelegramInput.swift",
                "SafeScannerSetupWorkflow.swift",
                "HeadlessBaudSetup.swift"
            ],
            sources: ["SickPLSSetupApp.swift"]
        ),
        .testTarget(
            name: "SickPLSMonitorTests",
            dependencies: ["PlanariumApplication", "PlanariumAudio", "PlanariumDomain", "PlanariumInput", "PlanariumMIDI", "PlanariumPresets", "PlanariumRuntime", "PlanariumScannerUI", "SickPLSCommissioning", "SickPLSCommissioningControl", "SickPLSControlCore", "SickPLSCore", "SickPLSMacTransport", "SickPLSMonitor", "SickPLSMonitorKit", "SickPLSSetupControl", "SickPLSSimulationControl", "SickPLSSimulationLink"],
            exclude: ["Fixtures"]
        ),
        .target(
            name: "SickPLSSetupControl",
            dependencies: ["SickPLSActiveControl", "SickPLSCommissioning", "SickPLSCore", "SickPLSMacTransport"],
            path: "Sources/SickPLSSetup",
            exclude: ["SickPLSSetupApp.swift"],
            sources: [
                "SetupConsoleModel.swift", "HexTelegramInput.swift",
                "SafeScannerSetupWorkflow.swift",
                "HeadlessBaudSetup.swift"
            ]
        ),
        .testTarget(
            name: "SickPLSSetupTests",
            dependencies: ["SickPLSActiveControl", "SickPLSCommissioning", "SickPLSCore", "SickPLSMacTransport", "SickPLSSetupControl"]
        ),
        // SICK-037: versioniertes Presetformat, Auflösung in geprüfte
        // Domänenwerte, atomare Ablage und das Bedienmodell, das erst
        // löst, dann setzt und nie startet.
        .target(
            name: "PlanariumPresets",
            dependencies: ["PlanariumDomain", "SickPLSControlCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "PlanariumPresetsTests",
            dependencies: ["LegacyPresetTestSupport", "PlanariumApplication", "PlanariumAudio", "PlanariumDomain", "PlanariumInput", "PlanariumMIDI", "PlanariumPresets", "PlanariumRuntime", "PlanariumScannerUI", "SickPLSControlCore", "SickPLSCore", "SickPLSMacTransport", "SickPLSMonitorKit"],
            resources: [.copy("Fixtures")]
        ),

        // SICK-036b: der einzige Ort, der CoreMIDI importiert.

        // SICK-033b: das Bedienmodell des Audio-Unit-Racks. Es kennt
        // Katalog und Dienst, aber weder SwiftUI noch Scanner, Steuerweg
        // oder Lebenszyklus der Ausgabe -- Auswahl lädt nichts, Laden
        // nur auf ausdrücklichen Klick, Bypass ohne Graphmutation.

        // Schritt 1 der SICK-030-Folge: die prüfbaren Fachverträge des
        // Scanner-Commissionings. **Frameworkfrei** -- kein Foundation,
        // kein SwiftUI, kein AVFoundation, kein CoreMIDI, kein
        // `SickPLSMonitorKit`, kein Audio. **Keine I/O-Schleife und kein
        // Portzugriff**; die entstehen erst in SICK-031.
        .target(
            name: "SickPLSCommissioning",
            dependencies: ["PLSDeviceValues", "SickPLSActiveControl", "SickPLSCore", "SickPLSMacTransport"]
        ),
        .testTarget(
            name: "SickPLSCommissioningTests",
            dependencies: ["PlanariumInput", "SickPLSActiveControl", "SickPLSCommissioning", "SickPLSCore", "SickPLSMacTransport"]
        ),

        // SICK-032a: der sichtbare Commissioning-Bedienpfad (Auflage E3).
        // Er liegt bewusst **nicht** in `SickPLSPerformanceSession` --
        // dort ist `SickPLSActiveControl` verboten, das zum Bau des
        // realen Transports aber gebraucht wird -- und **nicht** im
        // App-Ziel, das kein Testziel hat. Kein SwiftUI: die Ansicht
        // komponiert nur.
        .target(
            name: "SickPLSCommissioningControl",
            dependencies: ["PlanariumInput", "SickPLSActiveControl", "SickPLSCommissioning", "SickPLSCore", "SickPLSMacTransport"]
        ),
        .testTarget(
            name: "SickPLSCommissioningControlTests",
            dependencies: ["PlanariumInput", "PlanariumPresets", "PlanariumScannerUI", "SickPLSActiveControl", "SickPLSCommissioning", "SickPLSCommissioningControl", "SickPLSCore", "SickPLSMacTransport", "SickPLSMonitorKit"]
        )
    ],
    cxxLanguageStandard: .cxx17
)
