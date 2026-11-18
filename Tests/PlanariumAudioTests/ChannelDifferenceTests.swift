import XCTest
import PlanariumDomain
@testable import PlanariumAudio

final class ChannelDifferenceTests: XCTestCase {
    func testInstrumentIdentityStateAndRemoval() {
        let a = InstrumentChannel(instrument: plugin())
        XCTAssertEqual(ChannelDifference.steps(from: a, to: a), [])
        var b = a; b.instrument?.state = Data([4])
        XCTAssertEqual(ChannelDifference.steps(from: a, to: b), [.state(.instrument, Data([4]))])
        b.instrument = plugin(2)
        XCTAssertEqual(ChannelDifference.steps(from: a, to: b), [.instrument(plugin(2))])
        XCTAssertEqual(ChannelDifference.steps(from: a, to: .init()), [.instrument(nil)])
        XCTAssertEqual(ChannelDifference.steps(from: .init(), to: a), [.instrument(plugin())])
    }
    func testInsertIdentityOrderStateBypassAndLevelIndependently() {
        let x = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false))
        let y = InstrumentInsert(id: UUID(), plugin: plugin(4, instrument: false))
        let old = InstrumentChannel(inserts: [x, y])
        var next = old; next.inserts.reverse()
        XCTAssertEqual(ChannelDifference.steps(from: old, to: next), [.insertOrder([y.id, x.id])])
        next = old; next.inserts[0].bypassed = true
        XCTAssertEqual(ChannelDifference.steps(from: old, to: next), [.bypass(x.id, true)])
        next = old; next.inserts[0].plugin.state = Data([5])
        XCTAssertEqual(ChannelDifference.steps(from: old, to: next), [.state(.insert(x.id), Data([5]))])
        next = old; next.levelDecibels = -6
        XCTAssertEqual(ChannelDifference.steps(from: old, to: next), [.level(-6)])
        next = old; next.inserts.removeFirst()
        XCTAssertEqual(ChannelDifference.steps(from: old, to: next), [.removeInsert(x.id), .insertOrder([y.id])])
        XCTAssertEqual(ChannelDifference.steps(from: next, to: old), [.addInsert(x), .insertOrder([x.id, y.id])])
        next = old; next.inserts[0].plugin.identity = identity(5, instrument: false)
        XCTAssertEqual(ChannelDifference.steps(from: old, to: next), [.removeInsert(x.id), .addInsert(next.inserts[0])])
        next = old; next.midiTarget = .init(uniqueID: 8)
        XCTAssertEqual(ChannelDifference.steps(from: old, to: next), [])
    }
    func testExhaustiveSmallChannelProduct() {
        let x = UUID(), y = UUID()
        var values: [InstrumentChannel] = []
        for instrument in [nil, plugin(1), plugin(1, state: 2), plugin(2)] {
            for mask in 0..<4 {
                for reverse in [false, true] {
                    for bypass in [false, true] {
                        for state: UInt8 in [0, 1] {
                            var inserts: [InstrumentInsert] = []
                            if mask & 1 != 0 { inserts.append(.init(id: x, plugin: plugin(3, instrument: false, state: state), bypassed: bypass)) }
                            if mask & 2 != 0 { inserts.append(.init(id: y, plugin: plugin(4, instrument: false), bypassed: false)) }
                            if reverse { inserts.reverse() }
                            for level in [0.0, -6] { values.append(.init(instrument: instrument, inserts: inserts, levelDecibels: level)) }
                        }
                    }
                }
            }
        }
        for old in values {
            for new in values {
                var result = old
                for step in ChannelDifference.steps(from: old, to: new) {
                    switch step {
                    case .instrument(let plugin): result.instrument = plugin
                    case .removeInsert(let id): result.inserts.removeAll { $0.id == id }
                    case .addInsert(let insert): result.inserts.append(insert)
                    case .insertOrder(let ids): result.inserts = ids.compactMap { id in result.inserts.first { $0.id == id } }
                    case .bypass(let id, let value): result.inserts[result.inserts.firstIndex { $0.id == id }!].bypassed = value
                    case .state(.instrument, let data): result.instrument?.state = data
                    case .state(.insert(let id), let data): result.inserts[result.inserts.firstIndex { $0.id == id }!].plugin.state = data
                    case .level(let level): result.levelDecibels = level
                    case .pan(let pan): result.pan = pan
                    }
                }
                XCTAssertEqual(result, new)
                let replacementCount = ChannelDifference.steps(from: old, to: new).filter { if case .instrument = $0 { return true }; return false }.count
                XCTAssertEqual(replacementCount, old.instrument?.identity == new.instrument?.identity ? 0 : 1)
            }
        }
    }
}
