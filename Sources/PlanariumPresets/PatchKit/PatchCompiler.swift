import Foundation
import PlanariumDomain

/// What a recipe turned into, readable as a table before anything is written.
public struct PatchPlan: Equatable, Sendable {
    public struct ChannelLine: Equatable, Sendable {
        public let id: String, name: String, levelDb: Double
        public let instrument: String, instrumentIdentity: String, instrumentStateBytes: Int
        public let effects: [(alias: String, identity: String, stateBytes: Int)]
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.levelDb == rhs.levelDb && lhs.instrument == rhs.instrument
                && lhs.instrumentIdentity == rhs.instrumentIdentity && lhs.instrumentStateBytes == rhs.instrumentStateBytes
                && lhs.effects.map(\.alias) == rhs.effects.map(\.alias)
        }
    }
    public struct BandLine: Equatable, Sendable {
        public let id: String, label: String, channel: String, color: String
        public let fromCm: Int, toCm: Int, velocity: Int, notes: [Int]
        public var cells: Int { (toCm - fromCm) * (PolarDeviceLatticeConstants.sectors) }
    }
    public struct RegionLine: Equatable, Sendable {
        public let id: String, label: String, channel: String, color: String
        public let velocity: Int, notes: [Int]
        public let shape: String, placement: String, extent: String
        /// Grid cells the shape produced, and the cells that remain in the preset.
        public let generatedCells: Int, cells: Int
    }
    public let name: String
    public let channels: [ChannelLine]
    public let bands: [BandLine]
    public let notices: [String]
    /// Version 2 only: the play area text, the outside policy and the region table.
    public var version = PatchKitLimits.recipeVersion
    public var playArea = ""
    public var outsidePolicy = ""
    public var regions: [RegionLine] = []

    public func render() -> String {
        if version == PatchKitLimits.recipeVersionTwo { return renderVersionTwo() }
        var lines = ["Patch \"\(name)\" — recipe version \(PatchKitLimits.recipeVersion), mode gate (a note sounds while the hand is inside its band)"]
        lines.append("")
        lines.append("Channels (sound aliases; states are checked for structure only, not listened to)")
        for channel in channels {
            let effects = channel.effects.isEmpty ? "no effects"
                : "effects " + channel.effects.map { "\($0.alias) [\($0.identity), \($0.stateBytes) B]" }.joined(separator: " → ")
            lines.append("  \(PatchKitText.pad(channel.id, 12)) \(channel.instrument) [\(channel.instrumentIdentity), \(channel.instrumentStateBytes) B] · \(effects) · level \(channel.levelDb) dB")
        }
        lines.append("")
        lines.append("Bands (distance from the scanner; front half circle, all \(PolarDeviceLatticeConstants.sectors) beams per ring)")
        lines.append("  " + ["ID", "FROM–TO CM", "NOTES", "CHANNEL", "COLOR", "VEL", "CELLS"]
            .enumerated().map { PatchKitText.pad($0.element, [10, 11, 26, 12, 8, 4, 6][$0.offset]) }.joined(separator: " "))
        for band in bands {
            let notes = band.notes.map { PatchNoteName.name(for: $0) + "=" + String($0) }.joined(separator: ",")
            lines.append("  " + [band.id, "\(band.fromCm)–\(band.toCm)", notes, band.channel, band.color, String(band.velocity), String(band.cells)]
                .enumerated().map { PatchKitText.pad($0.element, [10, 11, 26, 12, 8, 4, 6][$0.offset]) }.joined(separator: " "))
        }
        if !notices.isEmpty {
            lines.append("")
            lines.append("Notes")
            lines.append(contentsOf: notices.map { "  " + $0 })
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum PolarDeviceLatticeConstants { static let sectors = 361 }

/// The cells that will really exist in the preset, kept for the SVG preview.
public struct PatchDrawing: Sendable {
    public struct Region: Sendable {
        public let id: String, label: String, channel: String, color: String
        public let notes: [Int]
        /// Ordered by ring, then tick.
        public let cells: [PolarDeviceLattice]
    }
    public struct Overlap: Equatable, Sendable {
        public let left: String, right: String, cells: Int, sameChannel: Bool
    }
    public let name: String
    public let version: Int
    public let playArea: PatchPlayArea
    public let regions: [Region]
    public let overlaps: [Overlap]
}

public struct PatchBuild: Sendable {
    public let preset: InstrumentPresetV6
    public let data: Data
    public let plan: PatchPlan
    /// Absolute state files read for this build (inputs, never outputs).
    public let inputStateFiles: [URL]
    public let drawing: PatchDrawing
}

/// Recipe + catalog → V6 preset through the production domain types and codec.
public enum PatchCompiler {
    /// Either recipe version through the same compiler.
    public static func compile(_ recipe: PatchKitRecipe, catalog: SoundCatalog) throws -> PatchBuild {
        switch recipe {
        case .v1(let recipe): return try compile(recipe: recipe, catalog: catalog)
        case .v2(let recipe): return try compile(recipe: recipe, catalog: catalog)
        }
    }

    // MARK: Shared steps

    /// Resolves each referenced alias once; reports every missing or damaged one.
    private static func resolveSounds(_ channels: [PatchRecipe.Channel], catalog: SoundCatalog,
                                      problems: inout [String]) -> (sounds: [String: ResolvedSound], stateFiles: [URL]) {
        var sounds: [String: ResolvedSound] = [:]
        var stateFiles: [URL] = []
        func resolve(_ alias: String, role: SoundCatalog.Role, at place: String) {
            if let known = sounds[alias] {
                if known.role != role { problems.append("\(place): \"\(alias)\" is an \(known.role.rawValue) in the catalog but is used as an \(role.rawValue)") }
                return
            }
            do {
                let sound = try catalog.resolve(alias, expecting: role)
                guard sound.role == role else {
                    problems.append("\(place): \"\(alias)\" is an \(sound.role.rawValue) in the catalog but is used as an \(role.rawValue)")
                    return
                }
                sounds[alias] = sound
                if let entry = catalog.entry(alias), let url = try? catalog.stateURL(for: entry) { stateFiles.append(url) }
            } catch let error as PatchKitError {
                problems.append("\(place): " + error.problems.joined(separator: "; "))
            } catch { problems.append("\(place): sound \"\(alias)\" cannot be read") }
        }
        for channel in channels where PatchKitText.isHandle(channel.instrument) || !channel.effects.isEmpty {
            if PatchKitText.isHandle(channel.instrument) { resolve(channel.instrument, role: .instrument, at: "channel \"\(channel.id)\" instrument") }
            for effect in channel.effects where PatchKitText.isHandle(effect) {
                resolve(effect, role: .effect, at: "channel \"\(channel.id)\" effect")
            }
        }
        return (sounds, stateFiles)
    }

    private static func strips(_ channels: [PatchRecipe.Channel], sounds: [String: ResolvedSound]) -> [InstrumentChannel] {
        let palette: [SpatialLayerColor] = [.blue, .orange, .green, .purple]
        var strips: [InstrumentChannel] = []
        for (index, channel) in channels.enumerated() {
            let instrument = sounds[channel.instrument]!
            let inserts = channel.effects.enumerated().map { position, alias -> InstrumentInsert in
                let effect = sounds[alias]!
                return InstrumentInsert(id: PatchIdentity.uuid("insert", channel.id, String(position), alias),
                                        plugin: InstrumentPlugin(identity: effect.identity, state: effect.state))
            }
            strips.append(InstrumentChannel(
                instrument: InstrumentPlugin(identity: instrument.identity, state: instrument.state), inserts: inserts,
                levelDecibels: channel.levelDb, id: PatchIdentity.uuid("channel", channel.id),
                name: channel.name ?? channel.id, color: palette[index % palette.count]))
        }
        return strips
    }

    private static func layer(id: String, name: String, color: String, cells: Set<PolarDeviceLattice>, notes: [Int], velocity: Int,
                              channel: String, stripIDs: [String: UUID]) -> SpatialDocumentLayer {
        let routing = SpatialRouting(
            id: PatchIdentity.uuid("routing", id),
            target: .audioUnitNote(channel: 0, stripID: stripIDs[channel]!),
            program: .chord(notes: notes, velocity: UInt8(velocity), transition: .legato))
        return SpatialDocumentLayer(
            id: PatchIdentity.uuid("layer", id), name: name, color: PatchColor.parse(color)!,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: cells, routings: [routing], cellOverrides: [:])
    }

    /// Document → V6 preset bytes, read back through the production codec.
    private static func encode(name: String, summary: String, layers: [SpatialDocumentLayer],
                               strips: [InstrumentChannel]) throws -> (InstrumentPresetV6, Data) {
        do {
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id)
            let document = InstrumentDocument(spatial: spatial, channel: .init(),
                revision: .init(session: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, counter: 0),
                channels: strips, masterLevelDecibels: 0)
            let preset = InstrumentPresetV6(name: name, document: document, includesChannel: true, summary: summary)
            let data = try PresetV6Codec.encode(preset)
            // The production reader must accept exactly what was written.
            let back = try PresetV6Codec.decode(data)
            guard back == preset, try PresetV6Codec.encode(back) == data else {
                throw PatchKitError("internal check failed: the written preset does not read back identically")
            }
            return (preset, data)
        } catch let error as PatchKitError { throw error }
        catch { throw PatchKitError("the production preset codec rejected the patch: \(error)") }
    }

    private static func channelLines(_ channels: [PatchRecipe.Channel], sounds: [String: ResolvedSound]) -> [PatchPlan.ChannelLine] {
        channels.map { channel in
            let instrument = sounds[channel.instrument]!
            return .init(id: channel.id, name: channel.name ?? channel.id, levelDb: channel.levelDb,
                         instrument: channel.instrument, instrumentIdentity: instrument.identityText,
                         instrumentStateBytes: instrument.state.count,
                         effects: channel.effects.map { (alias: $0, identity: sounds[$0]!.identityText, stateBytes: sounds[$0]!.state.count) })
        }
    }

    // MARK: Version 1

    public static func compile(recipe: PatchRecipe, catalog: SoundCatalog) throws -> PatchBuild {
        var problems = recipe.validate()
        let (sounds, stateFiles) = resolveSounds(recipe.channels, catalog: catalog, problems: &problems)
        guard problems.isEmpty else { throw PatchKitError(problems) }

        let strips = strips(recipe.channels, sounds: sounds)
        let stripIDs = Dictionary(uniqueKeysWithValues: zip(recipe.channels.map(\.id), strips.map(\.id)))
        var layers: [SpatialDocumentLayer] = []
        var lines: [PatchPlan.BandLine] = []
        var drawn: [PatchDrawing.Region] = []
        for band in recipe.bands {
            let notes = band.notes.compactMap(\.midi)
            let velocity = band.velocity ?? recipe.velocity
            var cells = Set<PolarDeviceLattice>()
            var ordered: [PolarDeviceLattice] = []
            for ring in band.fromCm..<band.toCm {
                for sector in 0...PolarDeviceLattice.maxTick {
                    let cell = PolarDeviceLattice(ring: ring, sector: sector)!
                    cells.insert(cell); ordered.append(cell)
                }
            }
            layers.append(layer(id: band.id, name: band.label ?? band.id, color: band.color, cells: cells, notes: notes,
                                velocity: velocity, channel: band.channel, stripIDs: stripIDs))
            lines.append(.init(id: band.id, label: band.label ?? band.id, channel: band.channel, color: band.color,
                               fromCm: band.fromCm, toCm: band.toCm, velocity: velocity, notes: notes))
            drawn.append(.init(id: band.id, label: band.label ?? band.id, channel: band.channel, color: band.color, notes: notes, cells: ordered))
        }
        let (preset, data) = try encode(name: recipe.name, summary: recipe.summary, layers: layers, strips: strips)
        let overlaps = Overlaps.find(drawn)
        return PatchBuild(preset: preset, data: data,
            plan: PatchPlan(name: recipe.name, channels: channelLines(recipe.channels, sounds: sounds), bands: lines, notices: notices(recipe)),
            inputStateFiles: stateFiles,
            drawing: PatchDrawing(name: recipe.name, version: 1,
                                  playArea: .sector(fromCm: 0, toCm: Double(PatchKitLimits.maximumDistanceCentimeters), fromDegrees: -90, toDegrees: 90),
                                  regions: drawn, overlaps: overlaps))
    }

    /// Gaps and unused channels are shown, never filled in.
    private static func notices(_ recipe: PatchRecipe) -> [String] {
        var result: [String] = []
        for channel in recipe.channels {
            let own = recipe.bands.filter { $0.channel == channel.id }.sorted { $0.fromCm < $1.fromCm }
            if own.isEmpty { result.append("channel \"\(channel.id)\" has no bands and will stay silent"); continue }
            for (left, right) in zip(own, own.dropFirst()) where left.toCm < right.fromCm {
                result.append("gap on channel \"\(channel.id)\": \(left.toCm)–\(right.fromCm) cm is silent (between \"\(left.id)\" and \"\(right.id)\")")
            }
        }
        let layered = recipe.bands.enumerated().flatMap { index, left in
            recipe.bands[(index + 1)...].filter { $0.channel != left.channel && left.fromCm < $0.toCm && $0.fromCm < left.toCm }.map { (left.id, $0.id) }
        }
        for (left, right) in layered { result.append("bands \"\(left)\" and \"\(right)\" overlap on different channels: both sounds play together there") }
        return result
    }

    // MARK: Version 2

    public static func compile(recipe: PatchRecipeV2, catalog: SoundCatalog) throws -> PatchBuild {
        var problems = recipe.validate()
        let (sounds, stateFiles) = resolveSounds(recipe.channels, catalog: catalog, problems: &problems)
        guard problems.isEmpty else { throw PatchKitError(problems) }

        // Shapes → grid cells, bounded in work and in size before anything is allocated.
        var candidates = PatchKitLimits.maximumCandidateTests, budget = PatchKitLimits.maximumCellAssignments
        var drawn: [PatchDrawing.Region] = [], lines: [PatchPlan.RegionLine] = [], notices: [String] = []
        let area = recipe.playArea
        for region in recipe.regions {
            let placed = PatchPlacedShape(shape: region.shape, transform: region.transform)
            let generated = try placed.cells(candidates: &candidates, cellBudget: &budget)
            let inside = generated.filter { area.contains(ring: $0.ring, tick: $0.sector) }
            let outside = generated.count - inside.count
            let bounds = placed.worldBounds, e = PatchGrid.epsilon
            var isSector = false
            if case .ringSector = region.shape { isSector = true }
            let behind = !isSector && bounds.minY < -e
            let who = "region \"\(region.id)\""
            let extent = "x \(PatchNumber.text(bounds.minX))…\(PatchNumber.text(bounds.maxX)), y \(PatchNumber.text(bounds.minY))…\(PatchNumber.text(bounds.maxY)) cm"
            if inside.isEmpty {
                if !isSector && bounds.maxY <= e {
                    problems.append("\(who): lies entirely behind the scanner (y < 0), where nothing can be measured — extent \(extent)")
                } else if generated.isEmpty && bounds.disjoint(from: area.bounds) {
                    problems.append("\(who): lies completely outside the play area — extent \(extent), play area \(area.summary)")
                } else if generated.isEmpty {
                    problems.append("\(who): produces no cells — the shape (extent \(extent)) is smaller than the 1 cm / 0.5° grid at this place or lies where no grid point exists; make it larger or move it")
                } else {
                    problems.append("\(who): lies completely outside the play area — all \(generated.count) cells are outside (extent \(extent), play area \(area.summary))")
                }
                continue
            }
            if outside > 0 || behind {
                let reasons = [outside > 0 ? "\(outside) of \(generated.count) cells lie outside the play area" : nil,
                               behind ? "part of the shape lies behind the scanner (y < 0), where nothing can be measured" : nil].compactMap { $0 }.joined(separator: "; ")
                switch recipe.outsidePolicy {
                case .error:
                    problems.append("\(who): \(reasons) (extent \(extent), play area \(area.summary)) — move or shrink it, or set \"outsidePolicy\": \"clip\" to cut it off (the cut is then reported)")
                case .clip:
                    notices.append("\(who) clipped to the play area: \(generated.count) grid cells → \(inside.count) kept, \(outside) removed" + (behind ? "; the part behind the scanner has no cells" : ""))
                }
            }
            let velocity = region.velocity ?? recipe.velocity
            let notes = region.notes.compactMap(\.midi)
            drawn.append(.init(id: region.id, label: region.label ?? region.id, channel: region.channel, color: region.color, notes: notes, cells: inside))
            lines.append(.init(id: region.id, label: region.label ?? region.id, channel: region.channel, color: region.color,
                               velocity: velocity, notes: notes, shape: region.shape.summary,
                               placement: Self.placement(region), extent: extent,
                               generatedCells: generated.count, cells: inside.count))
        }
        guard problems.isEmpty else { throw PatchKitError(problems) }

        // Overlaps are judged on the finished cell sets, not on bounding boxes.
        let overlaps = Overlaps.find(drawn)
        for overlap in overlaps {
            if overlap.sameChannel {
                problems.append("regions \"\(overlap.left)\" and \"\(overlap.right)\" share \(overlap.cells) grid cells on the same channel — the same cell would trigger twice; move or shrink one, or give one its own channel")
            } else {
                notices.append("regions \"\(overlap.left)\" and \"\(overlap.right)\" layer on different channels: \(overlap.cells) shared cells play both sounds together")
            }
        }
        guard problems.isEmpty else { throw PatchKitError(problems) }
        for channel in recipe.channels where !recipe.regions.contains(where: { $0.channel == channel.id }) {
            notices.append("channel \"\(channel.id)\" has no regions and will stay silent")
        }

        let strips = strips(recipe.channels, sounds: sounds)
        let stripIDs = Dictionary(uniqueKeysWithValues: zip(recipe.channels.map(\.id), strips.map(\.id)))
        let layers = zip(recipe.regions, drawn).map { region, shape in
            layer(id: region.id, name: region.label ?? region.id, color: region.color, cells: Set(shape.cells), notes: shape.notes,
                  velocity: region.velocity ?? recipe.velocity, channel: region.channel, stripIDs: stripIDs)
        }
        let (preset, data) = try encode(name: recipe.name, summary: recipe.summary, layers: layers, strips: strips)
        var plan = PatchPlan(name: recipe.name, channels: channelLines(recipe.channels, sounds: sounds), bands: [], notices: notices)
        plan.version = PatchKitLimits.recipeVersionTwo
        plan.playArea = area.summary
        plan.outsidePolicy = recipe.outsidePolicy.rawValue
        plan.regions = lines
        return PatchBuild(preset: preset, data: data, plan: plan, inputStateFiles: stateFiles,
                          drawing: PatchDrawing(name: recipe.name, version: 2, playArea: area, regions: drawn, overlaps: overlaps))
    }

    private static func placement(_ region: PatchRecipeV2.Region) -> String {
        if case .ringSector = region.shape { return "centred on the scanner" }
        let t = region.transform
        return "at (\(PatchNumber.text(t.xCm)), \(PatchNumber.text(t.yCm))) cm, rot \(PatchNumber.text(t.rotationDegrees))°, mirrorX \(t.mirrorX)"
    }
}

/// Which regions share finished cells (never judged from bounding boxes).
enum Overlaps {
    static func find(_ regions: [PatchDrawing.Region]) -> [PatchDrawing.Overlap] {
        var result: [PatchDrawing.Overlap] = []
        for (leftIndex, left) in regions.enumerated() {
            guard let leftFirst = left.cells.first, let leftLast = left.cells.last else { continue }
            let leftRange = PatchGrid.key(leftFirst)...PatchGrid.key(leftLast)
            for right in regions[(leftIndex + 1)...] {
                guard let rightFirst = right.cells.first, let rightLast = right.cells.last,
                      leftRange.overlaps(PatchGrid.key(rightFirst)...PatchGrid.key(rightLast)) else { continue }
                var a = 0, b = 0, shared = 0
                while a < left.cells.count, b < right.cells.count {
                    let x = PatchGrid.key(left.cells[a]), y = PatchGrid.key(right.cells[b])
                    if x == y { shared += 1; a += 1; b += 1 } else if x < y { a += 1 } else { b += 1 }
                }
                if shared > 0 { result.append(.init(left: left.id, right: right.id, cells: shared, sameChannel: left.channel == right.channel)) }
            }
        }
        return result
    }
}

extension PatchPlan {
    func renderVersionTwo() -> String {
        var lines = ["Patch \"\(name)\" — recipe version 2, mode gate (a note sounds while the hand is inside its region)"]
        lines.append("")
        lines.append("Coordinates: centimetres, scanner fixed at (0, 0), +x right, +y forward, visible half space y >= 0.")
        lines.append("Bearing: -90° left, 0° front, +90° right (x = r·sin, y = r·cos). Rotation turns counter-clockwise (mathematically positive);")
        lines.append("mirrorX flips the shape's local x first, then it is rotated about the local origin, then moved.")
        lines.append("Play area: \(playArea) — a chosen playing section, not a measured room or a proven scanner range. Outside policy: \(outsidePolicy).")
        lines.append("")
        lines.append("Channels (sound aliases; states are checked for structure only, not listened to)")
        for channel in channels {
            let effects = channel.effects.isEmpty ? "no effects"
                : "effects " + channel.effects.map { "\($0.alias) [\($0.identity), \($0.stateBytes) B]" }.joined(separator: " → ")
            lines.append("  \(PatchKitText.pad(channel.id, 12)) \(channel.instrument) [\(channel.instrumentIdentity), \(channel.instrumentStateBytes) B] · \(effects) · level \(channel.levelDb) dB")
        }
        lines.append("")
        lines.append("Regions (CELLS = real 1 cm / 0.5° grid cells that exist in the preset; the shape is sampled, not continuous)")
        let widths = [10, 26, 40, 22, 10, 4, 14]
        func row(_ values: [String]) -> String {
            "  " + values.enumerated().map { PatchKitText.pad($0.element, widths[$0.offset]) }.joined(separator: " ")
        }
        lines.append(row(["ID", "SHAPE", "PLACEMENT", "NOTES", "CHANNEL", "VEL", "CELLS"]))
        for region in regions {
            let notes = region.notes.map { PatchNoteName.name(for: $0) + "=" + String($0) }.joined(separator: ",")
            let cells = region.cells == region.generatedCells ? String(region.cells) : "\(region.cells) of \(region.generatedCells)"
            lines.append(row([region.id, region.shape, region.placement, notes, region.channel, String(region.velocity), cells]))
            lines.append("  " + String(repeating: " ", count: widths[0]) + " extent \(region.extent) · color \(region.color)")
        }
        if !notices.isEmpty {
            lines.append("")
            lines.append("Notes")
            lines.append(contentsOf: notices.map { "  " + $0 })
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
