import AppKit
import SwiftUI
import XCTest
import PlanariumAudio
import SickPLSMonitorKit
@testable import SickPLSMonitor

/// Owner 07.10.2026: „die rote LED leuchtet, die Pegelanzeige geht nicht“.
/// At the product width the bars were zero points wide. These tests count
/// lit bar pixels at exactly the product's meter width.
@MainActor final class LiveMeterBarTests: XCTestCase {
    private func litPixels<V: View>(_ view: V, update: () -> Void = {}) throws -> (before: Int, after: Int) {
        let width = ChannelStripLayout.meterWidth
        let host = NSHostingView(rootView: view.frame(width: width, height: 200))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200); host.wantsLayer = true
        func count() throws -> Int {
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
            var lit = 0
            // Bars only: skip the overload lamp at the top.
            for x in 0..<rep.pixelsWide { for y in (rep.pixelsHigh / 10)..<rep.pixelsHigh {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), max(c.redComponent, c.greenComponent) > 0.45,
                   abs(c.redComponent - c.greenComponent) > 0.2 { lit += 1 }
            } }
            return lit
        }
        let before = try count(); update(); return (before, try count())
    }

    func testBarsHaveRoomAtTheProductWidth() {
        let row = ChannelStripLayout.faderScaleWidth + ChannelStripLayout.faderWidth + ChannelStripLayout.meterWidth + 2 * ChannelStripLayout.faderRowSpacing
        XCTAssertLessThanOrEqual(row, ChannelStripLayout.stripWidth - 10, "Fader row fits inside the strip margins")
        let bars = ChannelStripLayout.meterWidth - ChannelStripLayout.meterLabelWidth - 2
        XCTAssertGreaterThanOrEqual(bars, 2 * ChannelStripLayout.meterBarMinimumWidth)
    }

    func testStaticLevelLightsBarsAndHigherLevelLightsMore() throws {
        let quiet = try litPixels(HelmutStereoMeterSample(left: 0.05, right: 0.05, clip: .constant(MeterClipState()))).after
        let loud = try litPixels(HelmutStereoMeterSample(left: 0.9, right: 0.9, clip: .constant(MeterClipState()))).after
        XCTAssertGreaterThan(quiet, 0, "-26 dBFS is visible")
        XCTAssertGreaterThan(loud, quiet)
    }

    func testLiveReaderUpdateLightsTheHostedBars() throws {
        let fixture = try MonitorRootFixture()
        let reader = ChannelMeterReader()
        let result = try litPixels(HostedStereoMeter(reader: reader, host: fixture.root.audio)) {
            reader.observe(.init(left: 0.5, right: 0.5), elapsed: 0)
        }
        XCTAssertEqual(result.before, 0, "Silent before")
        XCTAssertGreaterThan(result.after, 0, "A live reading appears in the bars")
    }
}
