import Foundation
import PlanariumDomain

public enum ChannelSlot: Hashable, Sendable {
    case instrument
    case insert(UUID)
}

public enum ChannelChange: Equatable, Sendable {
    case instrument(InstrumentPlugin?)
    case removeInsert(UUID)
    case addInsert(InstrumentInsert)
    case insertOrder([UUID])
    case bypass(UUID, Bool)
    case state(ChannelSlot, Data)
    case level(Double)
    case pan(Double)
}

/// MIDI belongs to the parallel MIDI owner. State changes retain the AU;
/// an insert's document ID, rather than array position, owns its lifetime.
public enum ChannelDifference {
    public static func steps(from old: InstrumentChannel, to new: InstrumentChannel) -> [ChannelChange] {
        var result: [ChannelChange] = []
        if old.instrument?.identity != new.instrument?.identity {
            result.append(.instrument(new.instrument))
        } else if let plugin = new.instrument, old.instrument?.state != plugin.state {
            result.append(.state(.instrument, plugin.state))
        }
        for insert in old.inserts where !new.inserts.contains(where: {
            $0.id == insert.id && $0.plugin.identity == insert.plugin.identity
        }) { result.append(.removeInsert(insert.id)) }
        for insert in new.inserts {
            if let previous = old.inserts.first(where: {
                $0.id == insert.id && $0.plugin.identity == insert.plugin.identity
            }) {
                if previous.bypassed != insert.bypassed { result.append(.bypass(insert.id, insert.bypassed)) }
                if previous.plugin.state != insert.plugin.state { result.append(.state(.insert(insert.id), insert.plugin.state)) }
            } else { result.append(.addInsert(insert)) }
        }
        if old.inserts.map(\.id) != new.inserts.map(\.id) {
            result.append(.insertOrder(new.inserts.map(\.id)))
        }
        if old.audibleLevelDecibels != new.audibleLevelDecibels { result.append(.level(new.audibleLevelDecibels)) }
        if old.pan != new.pan { result.append(.pan(new.pan)) }
        return result
    }
}
