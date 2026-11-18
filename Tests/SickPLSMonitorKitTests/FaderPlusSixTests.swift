import XCTest
import PlanariumDomain
import PlanariumPresets
import SickPLSMonitorKit

final class FaderPlusSixTests: XCTestCase {
    func testFaderScaleAndRoundTrip() {
        XCTAssertEqual(FaderLaw.scaleMarks.map(\.dB), [-60,-40,-30,-20,-15,-10,-6,-3,0,3,6])
        XCTAssertEqual(FaderLaw.position(forDecibels: 0), 0.75)
        XCTAssertEqual(FaderLaw.decibels(forPosition: 1), 6)
        XCTAssertEqual(FaderLaw.gain(forPosition: 0), 0)
        XCTAssertEqual(FaderLaw.decibelLabel(forPosition: 0), "−∞")
        XCTAssertEqual(FaderLaw.scaleMarks.last?.label, "+6")
        for i in 0...1000 {
            let position = Double(i)/1000
            let db = FaderLaw.decibels(forPosition: position)
            XCTAssertEqual(FaderLaw.position(forDecibels: db), position, accuracy: 1e-12)
        }
        XCTAssertEqual(FaderLaw.gain(forPosition: 1), 1.99526231496888, accuracy: 1e-12)
        XCTAssertEqual(FaderLaw.position(forGain: 1), FaderLaw.unityPosition)
    }
    func testMeterHasSeparateDBFSScaleAndClipLatch() {
        XCTAssertEqual(MeterLaw.scaleDecibels, Array(stride(from: 0, through: -60, by: -3)))
        XCTAssertEqual(MeterLaw.position(forDecibels: 0), 1)
        XCTAssertEqual(MeterLaw.position(forDecibels: -30), 0.5)
        XCTAssertEqual(MeterLaw.position(forGain: 0), 0)
        XCTAssertEqual(MeterLaw.position(forGain: 1), 1)
        XCTAssertNotEqual(MeterLaw.position(forGain: 1), FaderLaw.position(forGain: 1))
        var clip = MeterClipState()
        clip.observe(peak: 1); XCTAssertFalse(clip.isClipped)
        clip.observe(peak: 1.01); XCTAssertTrue(clip.isClipped)
        clip.observe(peak: 0); XCTAssertTrue(clip.isClipped)
        clip.reset(); XCTAssertFalse(clip.isClipped)
        clip.observe(peak: .nan); XCTAssertFalse(clip.isClipped)
    }
    func testLevelsAboveSixRejectInsteadOfStoringAValueTheGraphCannotApply() throws {
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmonie 01 Ruhe und Spannung"))
        var preset = try JSONDecoder().decode(InstrumentPresetV6.self,from: data)
        preset.document.channel.levelDecibels = 6.001
        XCTAssertThrowsError(try PresetV6Codec.encode(preset))
        XCTAssertEqual(FaderLaw.gain(forPosition: .nan),0)
    }
    func testLegacyVersionsOneThroughFourKeepSavedGainAtOrBelowUnity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Tests/PlanariumPresetsTests/FrozenPresetV4Fixtures.swift"))
        let literal = try XCTUnwrap(source.components(separatedBy: "static let record = #\"\"\"").last?.components(separatedBy: "\"\"\"#").first)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: Any])
        let current = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmonie 01 Ruhe und Spannung"))
        let live = try JSONDecoder().decode(InstrumentPresetV6.self,from: current).document
        for version in 1...4 {
            for gain in [0.0,0.1,0.7,1] {
                var wire = base
                wire["formatVersion"] = version; wire["masterGain"] = gain
                wire["instrumentChannel"] = ["id":"primary","pan":0]
                let reading = try PresetDocumentReader.read(JSONSerialization.data(withJSONObject: wire)).get()
                let loaded = try reading.replacing(live)
                let expected = max(-120,20*log10(max(0.000001,Double(Float(gain)))))
                XCTAssertEqual(loaded.channel.levelDecibels,expected,accuracy: 1e-12)
            }
        }
    }
    func testStoredChannelLevelsAtOrBelowUnityLoadUnchanged() throws {
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmonie 01 Ruhe und Spannung"))
        var preset = try JSONDecoder().decode(InstrumentPresetV6.self, from: data)
        for db in [-300.0,-120.0,-60,-40,-30,-20,-15,-10,-5,0,6] {
            var document = preset.document; document.channel.levelDecibels = db
            preset = .init(name: "Migration", document: document, includesChannel: true)
            let encoded = try PresetV6Codec.encode(preset)
            let loaded = try PresetDocumentReader.read(encoded).get().replacing(document)
            XCTAssertEqual(loaded.channel.levelDecibels, db)
            if db > -60 {
                XCTAssertEqual(20*log10(FaderLaw.gain(forPosition: FaderLaw.position(forDecibels: db))), db, accuracy: 1e-12)
            }
        }
    }
    func testClipHoldsTwoSecondsThenClearsAndNewOverloadRestartsHold() {
        var clip = MeterClipState()
        clip.observe(peak: 1.5)
        clip.advance(elapsed: 1.99); XCTAssertTrue(clip.isClipped)
        clip.observe(peak: 1.2)
        clip.advance(elapsed: 1.99); XCTAssertTrue(clip.isClipped)
        clip.advance(elapsed: 0.02); XCTAssertFalse(clip.isClipped)
        clip.advance(elapsed: 5); XCTAssertFalse(clip.isClipped)
        clip.observe(peak: 1.2); clip.advance(elapsed: .nan); clip.advance(elapsed: -1)
        XCTAssertTrue(clip.isClipped, "Invalid elapsed time never clears")
    }
    func testMeterColorZonesRiseGreenOrangeRedAlongTheBar() {
        let stops = MeterLaw.colorStops
        XCTAssertEqual(stops.map(\.decibels), stops.map(\.decibels).sorted())
        XCTAssertEqual(stops.first?.decibels, -60); XCTAssertEqual(stops.last?.decibels, 0)
        XCTAssertEqual(stops.first?.zone, .safe); XCTAssertEqual(stops.last?.zone, .over)
        func zone(at decibels: Double) -> MeterLaw.Zone { stops.last { $0.decibels <= decibels }!.zone }
        XCTAssertEqual(zone(at: -20), .safe); XCTAssertEqual(zone(at: -12), .safe)
        XCTAssertEqual(zone(at: -6), .warning); XCTAssertEqual(zone(at: -4), .warning)
        XCTAssertEqual(zone(at: 0), .over)
    }
}
