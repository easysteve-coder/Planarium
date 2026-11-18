import XCTest
@testable import SickPLSMonitorKit

final class InspektorEinsModelTests: XCTestCase {

    // D1: destination
    func testD1_destination() {
        XCTAssertEqual(SpatialRoutingTarget.midiCC(channel: 0, controller: 74).destination, .midi)
        XCTAssertEqual(SpatialRoutingTarget.audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID).destination, .audioUnit)
        XCTAssertEqual(SpatialRoutingTarget.boolean(name: "x").destination, .other)
    }

    // D2: withMIDIChannel
    func testD2_withMIDIChannel() {
        let cc = SpatialRoutingTarget.midiCC(channel: 0, controller: 74)
        XCTAssertEqual(cc.withMIDIChannel(3), .midiCC(channel: 3, controller: 74))

        let note = SpatialRoutingTarget.midiNote(channel: 0)
        XCTAssertEqual(note.withMIDIChannel(3), .midiNote(channel: 3))

        let au = SpatialRoutingTarget.audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)
        XCTAssertEqual(au.withMIDIChannel(3), .audioUnitNote(channel: 3, stripID: InstrumentChannel.legacyID))
        let controls: [SpatialRoutingTarget] = [.audioUnitCC(channel: 0, controller: 11, stripID: InstrumentChannel.legacyID),
            .audioUnitProgramChange(channel: 0, stripID: InstrumentChannel.legacyID),
            .audioUnitPitchBend(channel: 0, stripID: InstrumentChannel.legacyID),
            .audioUnitChannelPressure(channel: 0, stripID: InstrumentChannel.legacyID)]
        for target in controls {
            XCTAssertEqual(target.withMIDIChannel(3).midiChannel, 3)
            XCTAssertEqual(target.withMIDIChannel(3).stripID, InstrumentChannel.legacyID)
        }
    }

    // D3: setMIDIChannel
    func testD3_setMIDIChannel() {
        let cell = PolarMetricGridCell(ring: 2, angularIndex: 4)
        var layer = SpatialInstrumentLayer(
            name: "Test",
            color: .orange,
            routings: [SpatialRouting(target: .midiNote(channel: 0), program: .constant(0.5))],
            polarCellOverrides: [cell: [SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 60, velocity: 100))]]
        )

        layer.setMIDIChannel(5)

        XCTAssertEqual(layer.routings[0].target, .midiNote(channel: 5))
        let actions = layer.polarCellOverrides[cell]
        XCTAssertNotNil(actions)
        XCTAssertEqual(actions?.count, 1)
        XCTAssertEqual(actions?.first?.target, .midiNote(channel: 5))
    }

    // D4: deleteSelectedLayer solo
    func testD4_deleteSelectedLayerSolo() {
        var workspace = SpatialInstrumentWorkspace(layers: [
            SpatialInstrumentLayer(name: "A", color: .orange, isSoloed: true),
            SpatialInstrumentLayer(name: "B", color: .blue, isSoloed: true)
        ])
        workspace.selectLayer(workspace.layers[1].id)
        workspace.deleteSelectedLayer()

        XCTAssertEqual(workspace.layers.count, 1)
        XCTAssertFalse(workspace.layers[0].isSoloed)
    }

    // D5: midiChannel
    func testD5_midiChannel() {
        XCTAssertEqual(SpatialRoutingTarget.midiCC(channel: 4, controller: 1).midiChannel, 4)
        XCTAssertEqual(SpatialRoutingTarget.midiNote(channel: 0).midiChannel, 0)
        XCTAssertEqual(SpatialRoutingTarget.audioUnitNote(channel: 2, stripID: InstrumentChannel.legacyID).midiChannel, 2)
    }

    func testD4_deleteSelectedLayerSoloThreeLayers() {
        var workspace = SpatialInstrumentWorkspace(layers: [
            SpatialInstrumentLayer(name: "A", color: .orange, isSoloed: true),
            SpatialInstrumentLayer(name: "B", color: .blue, isSoloed: true),
            SpatialInstrumentLayer(name: "C", color: .green, isSoloed: true)
        ])
        workspace.selectLayer(workspace.layers[1].id)
        workspace.deleteSelectedLayer()

        XCTAssertEqual(workspace.layers.count, 2)
        XCTAssertTrue(workspace.layers[0].isSoloed)
        XCTAssertTrue(workspace.layers[1].isSoloed)
    }
}
