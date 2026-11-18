import XCTest
import AppKit
import SwiftUI
import Foundation
import PlanariumApplication
import PlanariumDomain
import PlanariumRuntime
import PlanariumPresets
import PlanariumInput
import SickPLSCore
import SickPLSControlCore
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class MeasurementRenderingTests: XCTestCase {
    private struct Harness: View {
        @ObservedObject var instrument: SpatialInstrumentRuntimeModel
        @ObservedObject var cells: SpatialActiveCellDisplayModel
        var body: some View {
            CartesianScanFieldView(editor: instrument.canvas, profile: cells.latestProfile,
                activeCellDisplay: cells, spatialInstrument: instrument, simulationBadge: AnyView(EmptyView()))
        }
    }

    /// 30 real B0 inputs/s, the production R → Q mailbox, 25 Main renders/s.
    /// Measures the normal update/layout/display work of each 25 Hz tick.
    /// A full forced bitmap export is measured separately, once per run; it
    /// redraws the entire hierarchy and is not part of live app display.
    /// No app instance, real device, plug-in, audio or MIDI output is used.
    func testThirtyHzInputMeasurementViewMainTickBudget() throws {
        let fixture = try MonitorRootFixture()
        let instrument = fixture.root.document
        let library = FactoryPresetLibrary.standard
        let data = try XCTUnwrap(library.data(named: "Harmony 27 Harmony Codex"))
        let reading = try PresetDocumentReader.read(data).get()
        try instrument.applyPresetDocument(reading.replacing(instrument.document))
        let cells = SpatialActiveCellDisplayModel()
        let descriptor = RenderDescriptor()
        fixture.root.input.connectSimulation(serviceName: "Synthetic 30 Hz MMK", opener: RenderStream(descriptor: descriptor))
        let host = NSHostingView(rootView: Harness(instrument: instrument, cells: cells).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        host.wantsLayer = true; host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 900,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst, bytesPerRow: 0, bitsPerPixel: 0))
        let producer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "owner-render.30hz"))
        var packets: [[UInt8]] = []
        for value: UInt16 in [100, 120] {
            var payload: [UInt8] = [0xb0, 90, 0]
            for _ in 0..<90 { payload += [UInt8(value), 0] }; payload += [0]
            packets.append(try Frame.build(address: 0x81, payload: payload).encoded())
        }
        let sourcePackets = packets
        producer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333))
        producer.setEventHandler { descriptor.produce(sourcePackets) }
        producer.resume(); defer { producer.cancel() }
        var timings: [Double] = [], layoutTimes: [Double] = [], renderedSequences = Set<UInt64>()
        for tick in 0..<85 {
            let start = DispatchTime.now().uptimeNanoseconds
            fixture.root.display.read()
            if let frame = fixture.root.display.frame {
                cells.update(profileFrame: frame.profile, activeCells: [:])
                instrument.noteDisplay(frame)
                if let sequence = frame.profile?.sequence { renderedSequences.insert(sequence) }
            }
            let updated = DispatchTime.now().uptimeNanoseconds
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let laidOut = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            if tick >= 10 {
                timings.append(elapsed)
                layoutTimes.append(Double(laidOut - updated) / 1e6)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(max(0, 0.04 - elapsed / 1e3)))
        }
        let mean = timings.reduce(0, +) / Double(timings.count)
        let sorted = timings.sorted(), p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        print(String(format: "Owner render input=30Hz display=25Hz pixels=900x900 ticks=%d mean=%.3f p99=%.3f max=%.3f ms Main-budget=%.2f%% renderedProfiles=%d", timings.count, mean, p99, sorted.last!, mean * 2.5, renderedSequences.count))
        print("Owner render phase layout/display mean ms=\(layoutTimes.reduce(0,+)/Double(layoutTimes.count))")
        XCTAssertGreaterThan(renderedSequences.count, 50)
        XCTAssertLessThan(mean, 12, "Main target: 25 ticks/s × mean tick < 30%")
        let directory = TestImageDirectory.make(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exportStart = DispatchTime.now().uptimeNanoseconds
        host.cacheDisplay(in: host.bounds, to: bitmap)
        print("Owner forced full bitmap export ms=\(Double(DispatchTime.now().uptimeNanoseconds - exportStart) / 1e6)")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("owner-mmk90-measurement.png"))
        producer.cancel()
        var finished = false; fixture.root.terminate { finished = true }
        let deadline = Date().addingTimeInterval(3)
        while !finished, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(finished)
    }
}

import SickPLSMacTransport
private final class RenderDescriptor: SerialPortFileDescriptor, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var sequence = 0
    func produce(_ packets: [[UInt8]]) { lock.lock(); defer { lock.unlock() }; pending = packets[sequence % packets.count]; sequence += 1 }
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        lock.lock(); let bytes = pending; pending = []; lock.unlock()
        if bytes.isEmpty { Thread.sleep(forTimeInterval: 0.001); return .timeout }
        return .bytes(bytes)
    }
    func close() {}
}
private struct RenderStream: ScanByteStreamOpening {
    let descriptor: RenderDescriptor
    func openStream() throws -> any SerialPortFileDescriptor { descriptor }
}
