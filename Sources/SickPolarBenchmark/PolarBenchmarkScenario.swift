//
//  PolarBenchmarkScenario.swift
//
//  Created for AR-0A - deterministische Polarszenarien
//

import Foundation
import SickPLSCore
import SickPLSControlCore
import SickPLSMonitorKit

// MARK: - SplitMix64 PRNG (deterministisch, nicht öffentlich)

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - PolarBenchmarkScenario

public struct PolarBenchmarkScenario: Equatable, Sendable {
    public let sectorCount: Int
    public let routingCount: Int
    public let pointCount: Int
    public let seed: UInt64

    public init(
        sectorCount: Int,
        routingCount: Int,
        pointCount: Int = 90,
        seed: UInt64 = 0x9E3779B97F4A7C15
    ) {
        self.sectorCount = sectorCount
        self.routingCount = routingCount
        self.pointCount = pointCount
        self.seed = seed
    }

    public var label: String {
        "s\(sectorCount)-r\(routingCount)"
    }
}

// MARK: - PolarBenchmarkScenarioFactory

public struct PolarBenchmarkScenarioFactory: Sendable {
    public private(set) var grid: MetricSquareGrid

    public init(grid: MetricSquareGrid = .fiveCentimeter) {
        self.grid = grid
    }

    // MARK: Sectors

    public func sectors(for scenario: PolarBenchmarkScenario) -> [PolarMetricGridCell] {
        var cells: [PolarMetricGridCell] = []
        var ring = 0

        while cells.count < scenario.sectorCount {
            let outer = Double(ring + 1) * grid.cellSizeMeters
            let step = PolarMetricCellSegment.angularStepDegrees(
                outerRadiusMeters: outer,
                radialHeightMeters: grid.cellSizeMeters
            )
            let count = max(1, Int((360.0 / step).rounded(.down)))

            for angularIndex in 0..<count {
                if cells.count >= scenario.sectorCount {
                    break
                }
                let cell = PolarMetricGridCell(
                    ring: ring,
                    angularIndex: angularIndex
                )
                cells.append(cell)
            }

            ring += 1
        }

        return cells
    }

    // MARK: Profile

    public func profile(for scenario: PolarBenchmarkScenario) throws -> B0ScanProfile {
        var prng = SplitMix64(seed: scenario.seed)
        var measurements: [B0ScanProfile.Measurement] = []
        measurements.reserveCapacity(scenario.pointCount)

        for _ in 0..<scenario.pointCount {
            let value = UInt16(50 + (prng.next() % 151))
            let measurement = try B0ScanProfile.Measurement.build(
                value: value,
                fieldFlags: 0
            )
            measurements.append(measurement)
        }

        return try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: measurements
        )
    }

    // MARK: Workspace

    public func workspace(for scenario: PolarBenchmarkScenario) -> SpatialInstrumentWorkspace {
        let sectors = self.sectors(for: scenario)
        let routings = Self.routings(count: scenario.routingCount)

        let layer = SpatialInstrumentLayer(
            name: "Benchmark",
            color: .orange,
            isActive: true,
            polarCells: Set(sectors),
            routings: routings
        )

        return SpatialInstrumentWorkspace(
            grid: grid,
            layers: [layer],
            coordinateMode: .polar
        )
    }

    // MARK: Routings (stabil, deterministisch)

    private static func routings(count: Int) -> [SpatialRouting] {
        var routings: [SpatialRouting] = []
        routings.reserveCapacity(count)

        for index in 0..<count {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            let target: SpatialRoutingTarget
            let program: SpatialValueProgram

            switch index % 4 {
            case 0:
                target = .midiNote(channel: 0)
                program = .scale(
                    rootMIDINote: 48,
                    lowestMIDINote: 36,
                    highestMIDINote: 84,
                    scale: .majorPentatonic,
                    directionDegrees: 0,
                    ascending: true,
                    transition: .retrigger
                )
            case 1:
                target = .midiCC(channel: 0, controller: UInt8(70 + index % 8))
                program = .continuous(
                    minimum: 0,
                    maximum: 1,
                    directionDegrees: 90,
                    curve: .linear
                )
            case 2:
                target = .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)
                program = .chord(
                    notes: [48, 55, 60],
                    velocity: 100,
                    transition: .legato
                )
            default:
                target = .boolean(name: "flag\(index)")
                program = .constant(1)
            }

            routings.append(SpatialRouting(id: id, target: target, program: program))
        }

        return routings
    }
}
