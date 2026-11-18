import SwiftUI
import UniformTypeIdentifiers
import PlanariumDomain

struct MIDIEffectSlotsView: View {
    @Environment(\.studioMixer) private var studioMixer
    let slots: [InstrumentMIDIEffect]
    var ownerID: UUID? = nil
    var revision: SpatialDocumentRevision? = nil
    var locked = false
    let add: () -> Void
    var addArpeggiator: (() -> Void)? = nil
    let toggle: (UUID) -> Void
    let open: (UUID) -> Void
    let remove: (UUID) -> Void
    let move: (UUID, UUID) -> Void
    /// Owner 21.10.2026: power and drag handle appear on hover only.
    var controlsAreVisibleForPreview = false
    @State private var hoveredSlot: UUID?
    private var dragPrefix: String { (ownerID?.uuidString ?? "preview") + ":" + (revision.map { "\($0.session):\($0.counter)" } ?? "preview") + ":" }
    var body: some View {
        VStack(spacing: 4) {
            Text("MIDI FX").font(.system(size: studioMixer ? StudioMaterials.labelSize : 8)).foregroundColor(studioMixer ? StudioMaterials.inkOnLight : Color.secondary)
            ForEach(slots) { slot in
                let name = slot.kind == .chord ? "Chord" : "Arpeggiator"
                HStack(spacing: 0) {
                    Button { toggle(slot.id) } label: { Image(systemName: "power").font(.system(size: 8)).opacity((controlsAreVisibleForPreview || hoveredSlot == slot.id) ? 1 : 0) }
                        .buttonStyle(StudioSlotPartStyle()).frame(width: 20, height: 30).contentShape(Rectangle()).help(slot.bypassed ? "Enable \(name)" : "Bypass \(name)").accessibilityLabel("Bypass \(name)").accessibilityValue(slot.bypassed ? "off" : "on")
                    Button { open(slot.id) } label: {
                        Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, minHeight: 30).contentShape(Rectangle())
                    }.buttonStyle(StudioSlotPartStyle()).help("Open \(name) editor")
                    Image(systemName: "line.3.horizontal").font(.system(size: 8)).opacity((controlsAreVisibleForPreview || hoveredSlot == slot.id) ? 1 : 0).frame(width: 12, height: 28)
                        .help("Drag to reorder MIDI effects")
                        .onDrag { NSItemProvider(object: (dragPrefix + slot.id.uuidString) as NSString) }
                }.frame(height: 30)
                    .onHover { inside in
                        if inside { hoveredSlot = slot.id } else if hoveredSlot == slot.id { hoveredSlot = nil }
                    }
                    .foregroundColor(slot.bypassed ? Color.white : Color(red: 0.035, green: 0.045, blue: 0.05))
                    .cornerRadius(3)
                    .contextMenu { Button("Remove \(name)") { remove(slot.id) } }
                    .auditedButtonSurface(name, font: 10, foreground: slot.bypassed ? .white : Color(red: 0.035, green: 0.045, blue: 0.05),
                        background: slot.bypassed ? (studioMixer ? StudioMaterials.midiBypass : Color(red: 0.361, green: 0.487, blue: 0.506)) : HelmutChrome.midiFX, group: "midi-slot-" + slot.id.uuidString)
                    .overlay { if studioMixer { StudioPlastic(tint: .clear, pressed: slot.bypassed) } }
                    .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                        guard !locked, let provider = providers.first else { return false }
                        let prefix = dragPrefix
                        provider.loadObject(ofClass: NSString.self) { value, _ in
                            guard let text = value as? String, text.hasPrefix(prefix),
                                  let id = UUID(uuidString: String(text.dropFirst(prefix.count))) else { return }
                            DispatchQueue.main.async { move(id, slot.id) }
                        }
                        return true
                    }
            }
            ForEach(slots.count..<4, id: \.self) { _ in
                Menu {
                    Button("Chord", action: add)
                    if let addArpeggiator { Button("Arpeggiator", action: addArpeggiator).disabled(slots.contains { $0.kind == .arpeggiator }) }
                } label: { Image(systemName: "plus").font(.system(size: 10)).frame(maxWidth: .infinity, minHeight: 22).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth: .infinity, minHeight: 22).contentShape(Rectangle()).foregroundColor(.white).background(StudioPlastic(tint: HelmutChrome.controlRaised)).cornerRadius(3).help("Add MIDI effect")
            }
        }.disabled(locked).accessibilityIdentifier("strip.midi-fx")
    }
}
