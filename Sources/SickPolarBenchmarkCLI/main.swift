//
//  main.swift
//  sick-polar-bench
//
//  Startbefehl: swift run -c release sick-polar-bench > /tmp/polar-benchmark.json
//
//  Messmatrix: sectorCount 100, 1000, 5000 x routingCount 1, 4, 16
//  jeweils pointCount: 90, Standardseed; Reihenfolge Sektoren außen, Routings innen.
//
//  JSON geht auf stdout, die Zusammenfassung auf stderr.
//  Kein Schreiben in das Repository, kein Rohcapture, keine Datei im Projekt.
//

import Foundation
import SickPolarBenchmark

// MARK: - Argument Parsing

func parseArguments(_ args: [String]) -> (warmup: Int, iterations: Int, help: Bool, error: String?) {
    var warmup = 5
    var iterations = 60
    var help = false
    var index = 1

    while index < args.count {
        let arg = args[index]

        switch arg {
        case "--warmup":
            index += 1
            if index >= args.count {
                return (0, 0, false, "Missing value for --warmup")
            }
            if let value = Int(args[index]) {
                warmup = value
            } else {
                return (0, 0, false, "Invalid value for --warmup: \(args[index])")
            }

        case "--iterations":
            index += 1
            if index >= args.count {
                return (0, 0, false, "Missing value for --iterations")
            }
            if let value = Int(args[index]) {
                iterations = value
            } else {
                return (0, 0, false, "Invalid value for --iterations: \(args[index])")
            }

        case "--help", "-h":
            help = true

        default:
            if arg.hasPrefix("--") {
                return (0, 0, false, "Unknown argument: \(arg)")
            } else {
                // Nicht-Option-Argumente ignorieren (könnten Programname Varianten sein)
                break
            }
        }

        index += 1
    }

    return (warmup, iterations, help, nil)
}

func printHelp() {
    let helpText = """
Usage: sick-polar-bench [OPTIONS]

Run: swift run -c release sick-polar-bench > /tmp/polar-benchmark.json
Matrix: sectorCount 100, 1000, 5000 x routingCount 1, 4, 16;
pointCount 90, standard seed; sectors first, routings second.
JSON goes to stdout, summary to stderr.

Options:
  --warmup <n>       Warmup iterations (default: 5)
  --iterations <n>   Measured iterations (default: 60)
  --help             Show this help
"""
    fputs(helpText, stderr)
}

// MARK: - Messmatrix

func buildMessmatrix() -> [PolarBenchmarkScenario] {
    let sectorCounts = [100, 1000, 5000]
    let routingCounts = [1, 4, 16]

    var scenarios: [PolarBenchmarkScenario] = []

    // Reihenfolge: Sektoren außen, Routings innen
    for sectorCount in sectorCounts {
        for routingCount in routingCounts {
            let scenario = PolarBenchmarkScenario(
                sectorCount: sectorCount,
                routingCount: routingCount,
                pointCount: 90,
                seed: 0x9E3779B97F4A7C15
            )
            scenarios.append(scenario)
        }
    }

    return scenarios
}

// MARK: - Main

do {
    let args = CommandLine.arguments
    let (warmup, iterations, help, error) = parseArguments(args)

    if help {
        printHelp()
        exit(0)
    }

    if let error = error {
        fputs("Error: \(error)\n", stderr)
        exit(2)
    }

    let scenarios = buildMessmatrix()
    let runner = PolarBenchmarkRunner(
        factory: PolarBenchmarkScenarioFactory(),
        warmupIterations: warmup,
        measuredIterations: iterations
    )

    let measurements: [PolarBenchmarkMeasurement]
    do {
        measurements = try runner.run(scenarios)
    } catch let error as PolarBenchmarkError {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    } catch {
        fputs("Unexpected error: \(error)\n", stderr)
        exit(1)
    }

    let report = PolarBenchmarkReport(
        measurements: measurements,
        warmupIterations: warmup,
        measuredIterations: iterations
    )

    // JSON auf stdout
    let jsonData = try report.jsonData()
    try FileHandle.standardOutput.write(contentsOf: jsonData)

    // Zusammenfassung auf stderr
    fputs("\n\(report.summaryText)\n", stderr)

    exit(0)
} catch {
    fputs("Fatal error: \(error)\n", stderr)
    exit(1)
}
