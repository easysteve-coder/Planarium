import SickPLSCore
import PlanariumInput
import PlanariumAudio
import PlanariumDomain
import XCTest
import AppKit
import SwiftUI
import PlanariumApplication
import SickPLSControlCore
import SickPLSMonitorKit
import PlanariumPresets
import PlanariumMIDI
import PlanariumRuntime
import Combine
import PlanariumScannerUI
@testable import SickPLSMonitor

final class DiagnosticsPresentationTests: XCTestCase {
    @MainActor func testDiagnosticsReadsAtMostFourTimesPerSecondAndStopsWhenHidden() async throws {
        let reader = DiagnosticsReader()
        let fixture = try MonitorRootFixture()
        var publications = 0
        let subscription = reader.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel(); reader.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(publications, 0)
        for _ in 0..<2 {
            let before = publications, readsBefore = reader.readCount
            let sample = { DiagnosticSnapshot.read(input: fixture.root.input, runtime: fixture.root.runtime, host: fixture.root.audio, midi: fixture.root.midi) }
            reader.start(sample: sample); reader.start(sample: sample)
            try await Task.sleep(nanoseconds: 1_050_000_000)
            XCTAssertGreaterThan(reader.readCount - readsBefore, 0)
            XCTAssertLessThanOrEqual(reader.readCount - readsBefore, 4)
            XCTAssertLessThanOrEqual(publications - before, 4)
            XCTAssertNotNil(reader.snapshot)
            reader.stop()
            let hidden = publications
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(publications, hidden)
        }
    }
    func testBuildStandPresentationCoversLocalAndUnknownRevisions() {
        let local = PlanariumBuildIdentity(buildNumber: "7", gitRevision: "deadbeef+local")
        let unknown = PlanariumBuildIdentity()

        XCTAssertEqual(local.presentationLine, "Version 0.1 · Build 7\nRevision deadbeef+local")
        XCTAssertEqual(unknown.presentationLine, "Version 0.1 · Build unknown\nRevision unknown")
    }

    @MainActor
    func testARCH3DiagnosticsRendersWideAndNarrowReferenceImages() throws {
        let fixture = try MonitorRootFixture()
        let root = DiagnosticsView(input: fixture.root.input, runtime: fixture.root.runtime, host: fixture.root.audio, midi: fixture.root.midi)
        let runDirectory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try render(root, width: 900, name: "arch3-diagnostics-wide.png", in: runDirectory)
        try render(root, width: 360, name: "arch3-diagnostics-narrow.png", in: runDirectory)
    }

    @MainActor
    private func render<Content: View>(
        _ view: Content,
        width: CGFloat,
        name: String,
        in directory: URL
    ) throws {
        let host = NSHostingView(rootView: view.background(Color.white))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width),
            pixelsHigh: 900,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "ARCH3Rendering", code: 1)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ARCH3Rendering", code: 2)
        }
        try data.write(to: directory.appendingPathComponent(name))
    }
}
