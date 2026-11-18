import XCTest
@testable import PlanariumRuntime
import PlanariumDomain

final class OutputMonitorTests: XCTestCase {
    func testOnlySuccessfulSendsChangeTablesAndClosedMonitorDoesNoWork() {
        var router = OutputRouter()
        router.attach(.init(destination: .midi) { _ in .sent })
        let on = MusicEvent.noteOn(destination: .midi, channel: 0, note: .init(number: 60, velocity: 91))
        router.route([on], sounding: [on], allowOn: true)
        XCTAssertTrue(router.monitorSnapshots.isEmpty)
        router.setMonitorVisible(true)
        XCTAssertEqual(router.monitorSnapshots.first?.notes[60], 91, "Opening catches actual receipts")
        let cc = SpatialRoutingTarget.midiCC(channel: 0, controller: 1)
        router.route([.midiValue(destination: .midi, target: cc, value: 0.5), .midiValue(destination: .midi, target: cc, value: 1)], sounding: [on], allowOn: true)
        XCTAssertEqual(router.monitorSnapshots.first?.controllers[1], 127)
        router.panic()
        XCTAssertEqual(router.monitorSnapshots.first?.notes.filter { $0 > 0 }.count, 0)
        router.setMonitorVisible(false)
        router.route([on], sounding: [on], allowOn: true)
        XCTAssertTrue(router.monitorSnapshots.isEmpty)
        var failed = OutputRouter()
        failed.setMonitorVisible(true)
        failed.attach(.init(destination: .midi) { _ in .faulted })
        failed.route([on], sounding: [on], allowOn: true)
        XCTAssertEqual(failed.monitorSnapshots.first?.generation, 0)
    }
    func testRingIsBoundedAndSnapshotsDoNotAliasMutableTables() {
        var storage = OutputMonitorStorage()
        for _ in 0..<300 { storage.record(status: 0x90, number: 60, value: 100) }
        XCTAssertEqual(storage.generation, 0, "Closed means zero event evaluations")
        storage.enabled = true
        for i in 0..<250 { storage.record(status: 0xB0, number: 1, value: UInt16(i % 128)) }
        let before = storage.snapshot(id: UUID(), destination: .midi)!
        storage.record(status: 0xB0, number: 1, value: 127)
        XCTAssertEqual(before.events.count, 200)
        XCTAssertEqual(before.events.first?.sequence, 51)
        XCTAssertEqual(before.controllers[1], 121)
        XCTAssertEqual(storage.generation, 251)
    }
}
