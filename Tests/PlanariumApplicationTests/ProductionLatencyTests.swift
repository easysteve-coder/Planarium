import XCTest
import Foundation
import Dispatch
import PlanariumApplication
import PlanariumDomain
import PlanariumRuntime
import SickPLSControlCore

@MainActor final class ProductionLatencyTests: XCTestCase {
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.0001)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    private func report(_ samples: [Double], name: String) -> (p99: Double, max: Double) {
        reportPerformance("production/" + name, samples: samples, unit: "ms")
        let sorted = samples.sorted()
        let p50 = sorted[Int(ceil(Double(sorted.count) * 0.5))-1]
        let p99 = sorted[Int(ceil(Double(sorted.count) * 0.99))-1]
        let max = sorted.last!
        print("P5-LATENCY \(name) n=\(samples.count) p50=\(p50)ms p99=\(p99)ms max=\(max)ms")
        return (p99, max)
    }
    func testTenThousandProfilesFromRealReaderQueueToFakeMIDISend() throws {
        let f = try RootFixture()
        let a = PolarDeviceLattice(tick: 180, rawCentimeters: 100)!
        let b = PolarDeviceLattice(tick: 180, rawCentimeters: 150)!
        let target = SpatialRoutingTarget.midiCC(channel: 0, controller: 1)
        let layer = SpatialDocumentLayer(id: UUID(), name: "Latency", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [a,b], routings: [.init(target: target, program: .constant(0))],
            cellOverrides: [a: [.init(target: target, value: .scalar(0.25))], b: [.init(target: target, value: .scalar(0.75))]])
        try f.root.document.edit { doc in
            doc.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
            doc.detection = .allStagesOff; doc.midiTarget = .init(uniqueID: 1)
        }
        f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
        let bytes = [try f.bytes(100), try f.bytes(150)]
        var samples: [Double] = []; samples.reserveCapacity(10_000)
        for index in 0..<10_000 {
            f.scanner.descriptors[0].append(.bytes(bytes[index & 1]))
            until { f.midi.sends[0].sendTimes.count > index }
            until { f.root.runtime.mailbox.read()?.profile?.sequence == UInt64(index+1) }
            let profile = try XCTUnwrap(f.root.runtime.mailbox.read()?.profile)
            samples.append((f.midi.sends[0].sendTimes[index] - profile.time) * 1_000)
        }
        let result = report(samples, name: "profile-to-send")
        XCTAssertEqual(samples.count, 10_000); XCTAssertGreaterThanOrEqual(samples.min()!, 0)
        XCTAssertLessThanOrEqual(result.p99, 20); XCTAssertLessThan(result.max, 40)
        var done = false; f.root.terminate { done = true }; until { done }
    }
    func testThousandPanicsThroughProductionRootToNoteOff() throws {
        let f = try RootFixture(); try f.install()
        f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
        let bytes = try f.bytes()
        let exitBytes = try f.bytes(8191)
        var samples: [Double] = []
        for _ in 0..<1_000 {
            let previous = f.root.runtime.mailbox.read()?.processedProfiles ?? 0
            f.scanner.descriptors[0].append(.bytes(exitBytes))
            until { (f.root.runtime.mailbox.read()?.processedProfiles ?? 0) > previous }
            let beforeOn = f.midi.sends[0].sent.filter { $0.first == 0x90 }.count
            f.scanner.descriptors[0].append(.bytes(bytes))
            until { f.midi.sends[0].sent.filter { $0.first == 0x90 }.count > beforeOn }
            let before = f.midi.sends[0].sent.count
            let start = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            f.root.panic()
            until { f.midi.sends[0].sent.count > before }
            XCTAssertEqual(f.midi.sends[0].sent[before].first, 0x80)
            samples.append((f.midi.sends[0].sendTimes[before] - start) * 1_000)
            let ack = expectation(description: "Panic acknowledged")
            f.root.runtime.acknowledge { ack.fulfill() }; wait(for: [ack], timeout: 5)
        }
        let result = report(samples, name: "panic-to-off")
        XCTAssertLessThanOrEqual(result.p99, 5)
        var done = false; f.root.terminate { done = true }; until { done }
    }
}

// Thin target-local bridge; format, environment and percentiles live in the
// shared reporter. Called only AFTER the timed interval. Reporting failure is
// observational and must never alter a performance assertion's outcome.
private func reportPerformance(_ scenario: String, samples: [Double], unit: String) {
    #if DEBUG
    let build = "debug"
    #else
    let build = "release"
    #endif
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/perf-report.py").path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        let data = try JSONSerialization.data(withJSONObject: ["scenario": scenario, "samples": samples, "unit": unit, "build": build])
        try process.run()
        input.fileHandleForWriting.write(data); input.fileHandleForWriting.closeFile()
        let evidence = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        FileHandle.standardError.write(evidence)
        if process.terminationStatus != 0 { print("SICK-PERF reporting unavailable: status=\(process.terminationStatus)") }
    } catch { print("SICK-PERF reporting unavailable: \(error)") }
}
