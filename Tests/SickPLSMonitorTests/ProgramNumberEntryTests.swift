import AppKit
import SwiftUI
import XCTest
import PlanariumDomain
import PlanariumApplication
import PlanariumAudio
import PlanariumPresets
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class ProgramNumberEntryTests: XCTestCase {
    private final class RenameDraft: ObservableObject {
        @Published var text: String
        init(_ text: String) { self.text = text }
    }
    private struct DraftRenameHarness: View {
        @ObservedObject var draft: RenameDraft
        let save: (String) -> Void
        var body: some View {
            VStack {
                RenameEntryField(text: $draft.text, isDraftBinding: true)
                Button("Rename") { save(draft.text) }
                Button("Cancel") {}
            }
        }
    }
    func testRenameSheetButtonSeesCurrentDraftWithoutFocusLossAndCancelDoesNotCommit() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let original = owner.document.channel.name, revision = owner.document.revision
        let draft = RenameDraft(original)
        let hostWindow = window(DraftRenameHarness(draft: draft, save: { name in
            var channel = owner.document.channel; channel.name = name; owner.updateChannel(channel)
        }), width: 280, height: 160)
        defer { hostWindow.contentView = nil }
        let input = try field(hostWindow, placeholder: "Name")
        try type("ABCDEFGHIJ", into: input, in: hostWindow)
        XCTAssertEqual(owner.document.channel.name, original)
        XCTAssertEqual(draft.text, "ABCDEFGHIJ")
        // A native accessibility action may run before focus-loss onChange.
        try action("accessibilityPerformPress", label: "Rename", window: hostWindow)
        XCTAssertEqual(owner.document.channel.name, "ABCDEFGHIJ")
        XCTAssertEqual(owner.document.revision.counter, revision.counter + 1)
        let saved = owner.document
        try type("Cancelled", into: input, in: hostWindow)
        try action("accessibilityPerformPress", label: "Cancel", window: hostWindow)
        XCTAssertEqual(owner.document, saved)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.channel.name, original)
    }

    func testDeletedChannelCannotAcquirePendingRenameForAnotherStrip() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        try owner.addChannel()
        let id = try XCTUnwrap(owner.document.channels.last?.id)
        let strip = ChannelStripView(spatialInstrument: owner,
            audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()),
            host: try XCTUnwrap(fixture.root.audio.host(for: id)), midiOutput: fixture.root.midi,
            audioDevices: AudioOutputDeviceControlModel(host: fixture.root.audio), stripID: id)
        let binding = strip.channelNameBinding
        let hostWindow = window(RenameEntryField(text: binding, context: id.uuidString), width: 280, height: 80)
        defer { hostWindow.contentView = nil }
        try type("Late rename", into: field(hostWindow, placeholder: "Name"), in: hostWindow)
        try owner.deleteChannel(id)
        let remaining = owner.document
        leave(hostWindow)
        binding.wrappedValue = "Late direct binding callback"
        XCTAssertEqual(owner.document, remaining)
        XCTAssertEqual(binding.wrappedValue, "")
    }

    private struct ChannelRenameHarness: View {
        @ObservedObject var owner: SpatialInstrumentRuntimeModel
        var body: some View {
            RenameEntryField(text: Binding(get: { owner.document.channel.name }, set: { name in
                var channel = owner.document.channel; channel.name = name; owner.updateChannel(channel)
            }), title: "Channel name", context: owner.document.channel.id.uuidString)
        }
    }

    func testChannelRenameTenCharactersCommitsOnceOnEnterOrFocusLossAndEscapeDiscards() throws {
        for submit in [true, false] {
            let fixture = try MonitorRootFixture(), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            let original = owner.document.channel.name, revision = owner.document.revision
            let hostWindow = window(ChannelRenameHarness(owner: owner), width: 280, height: 80)
            defer { hostWindow.contentView = nil }
            let input = try field(hostWindow, placeholder: "Channel name")
            XCTAssertTrue(hostWindow.makeFirstResponder(input)); pump()
            let editor = try XCTUnwrap(hostWindow.firstResponder as? NSTextView)
            editor.setSelectedRange(.init(location: 0, length: editor.string.utf16.count))
            for character in "ABCDEFGHIJ" {
                editor.insertText(String(character), replacementRange: editor.selectedRange()); pump()
                XCTAssertEqual(owner.document.revision, revision)
            }
            let probe = CanvasTimingProbe(); CanvasTimingProbe.current = probe
            defer { CanvasTimingProbe.current = nil }
            if submit { try enter(hostWindow) } else { leave(hostWindow) }
            XCTAssertEqual(owner.document.channel.name, "ABCDEFGHIJ")
            XCTAssertEqual(owner.document.revision.counter, revision.counter + 1)
            XCTAssertEqual(probe.counts["runtime.compile", default: 0], 0)
            XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.channel.name, original)
            XCTAssertTrue(owner.redo()); XCTAssertEqual(owner.document.channel.name, "ABCDEFGHIJ")
            let beforeEscape = owner.document.revision
            let draftEditor = try type("discard", into: input, in: hostWindow)
            draftEditor.keyDown(with: try key("\u{1b}", code: 53, window: hostWindow)); pump(); leave(hostWindow)
            XCTAssertEqual(owner.document.channel.name, "ABCDEFGHIJ")
            XCTAssertEqual(owner.document.revision, beforeEscape)
        }
    }

    private final class Selection: ObservableObject {
        @Published var value = SpatialProgramChange(program: 9)
        @Published var enabled = true
        var commits = 0
    }
    private struct Harness: View {
        @ObservedObject var model: Selection
        var body: some View {
            ProgramChangeEditor(selection: Binding(get: { model.value }, set: {
                model.value = $0; model.commits += 1
            })).disabled(!model.enabled).padding(12)
        }
    }
    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    private func window(_ view: some View, width: CGFloat = 360, height: CGFloat = 650) -> NSWindow {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.layoutSubtreeIfNeeded(); pump()
        return window
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func field(_ window: NSWindow, placeholder: String = "1…128") throws -> NSTextField {
        try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == placeholder })
    }
    @discardableResult private func type(_ text: String, into field: NSTextField, in window: NSWindow) throws -> NSTextView {
        XCTAssertTrue(window.makeFirstResponder(field)); pump()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(.init(location: 0, length: editor.string.utf16.count))
        editor.insertText(text, replacementRange: editor.selectedRange()); pump()
        return editor
    }
    private func key(_ characters: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    private func enter(_ window: NSWindow) throws {
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.keyDown(with: try key("\r", code: 36, window: window)); pump()
    }
    private func leave(_ window: NSWindow) { XCTAssertTrue(window.makeFirstResponder(nil)); pump() }
    private func elements(_ value: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 30, let element = value as? NSObject else { return [] }
        let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren()
            ?? (element.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? element.value(forKey: "accessibilityChildren") as? [Any] : nil)
            ?? element.accessibilityAttributeValue(.children) as? [Any] ?? []
        return [element] + children.flatMap { elements($0, depth: depth + 1) }
    }
    private func label(_ element: NSObject) -> String? {
        (element as? NSAccessibilityProtocol)?.accessibilityLabel()
            ?? (element.responds(to: NSSelectorFromString("accessibilityLabel"))
                ? element.value(forKey: "accessibilityLabel") as? String : nil)
            ?? element.accessibilityAttributeValue(.description) as? String
            ?? element.accessibilityAttributeValue(.title) as? String
    }
    private func action(_ name: String, label title: String, window: NSWindow) throws {
        let all = elements(try XCTUnwrap(window.contentView))
        let element = try XCTUnwrap(all.first { label($0)?.hasSuffix(title) == true }, "Missing \(title): \(all.compactMap(label))")
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString(name), to: element, from: nil)); pump()
    }
    private func visibleText(_ window: NSWindow) -> [String] {
        elements(window.contentView!).compactMap { element in
            if let value = label(element) { return value }
            if element.responds(to: NSSelectorFromString("accessibilityValue")) {
                return element.value(forKey: "accessibilityValue") as? String
            }
            return element.accessibilityAttributeValue(.value) as? String
        }
    }

    func testReturnAndFocusLossCommitOnlyCompleteInputOnceInBothOriginsAndBanks() throws {
        for fromOne in [true, false] {
            let model = Selection(); model.value.countsFromOne = fromOne
            model.value.bankMSB = 3; model.value.bankLSB = 4
            let window = window(Harness(model: model)); defer { window.close() }
            let program = try field(window, placeholder: fromOne ? "1…128" : "0…127")
            let editor = try type(fromOne ? "128" : "127", into: program, in: window)
            XCTAssertEqual(model.value.program, 9); XCTAssertEqual(model.commits, 0)
            XCTAssertEqual(editor.string, fromOne ? "128" : "127")
            try enter(window)
            XCTAssertEqual(model.value.program, 127); XCTAssertEqual(model.commits, 1)
            leave(window); XCTAssertEqual(model.commits, 1, "Return followed by blur must not commit twice")
            try type(fromOne ? "1" : "0", into: program, in: window); leave(window)
            XCTAssertEqual(model.value.program, 0); XCTAssertEqual(model.commits, 2)
            let banks = descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSTextField }
                .filter { $0.placeholderString == "0…127" && $0 !== program }
            XCTAssertEqual(banks.count, 2)
            try type("127", into: banks[0], in: window); try enter(window)
            XCTAssertEqual(model.value.bankMSB, 127)
            try type("0", into: banks[1], in: window); leave(window)
            XCTAssertEqual(model.value.bankLSB, 0); XCTAssertEqual(model.commits, 4)
        }
    }

    func testInvalidAndEscapeRetainPreviousSelectionAndHintWithoutCommit() throws {
        let model = Selection(); model.value.bankMSB = 7; model.value.bankLSB = 8
        let window = window(Harness(model: model)); defer { window.close() }
        let fields = descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSTextField }
            .filter { $0.placeholderString?.contains("…") == true }
        XCTAssertEqual(fields.count, 3)
        let original = model.value
        for field in fields {
            let before = field.stringValue
            for text in ["129", "200", "", "letters", "-1", "1.5", "9999999999999999999999999999", field === fields[0] ? "0" : "128"] {
                for submit in [true, false] {
                    let editor = try type(text, into: field, in: window)
                    if text.isEmpty { editor.deleteBackward(nil); pump() }
                    if submit { try enter(window) } else { leave(window) }
                    XCTAssertEqual(model.value, original, text); XCTAssertEqual(model.commits, 0)
                    XCTAssertEqual(field.stringValue, before, "Rejected \(text) must restore the value")
                    XCTAssertTrue(visibleText(window).contains { $0.hasPrefix("Enter ") }, "\(text): \(visibleText(window))")
                }
            }
            let editor = try type("55", into: field, in: window)
            editor.keyDown(with: try key("\u{1b}", code: 53, window: window)); pump(); leave(window)
            XCTAssertEqual(model.value, original); XCTAssertEqual(model.commits, 0)
            XCTAssertEqual(field.stringValue, before)
            XCTAssertFalse(visibleText(window).contains { $0.hasPrefix("Enter ") })
        }
    }

    func testOpenDraftDoesNotChangeMeaningOnCountingHistoryOrPerformChange() throws {
        let model = Selection()
        let hosted = self.window(Harness(model: model)); defer { hosted.close() }
        let program = try field(hosted)
        let originEditor = try type("77", into: program, in: hosted)
        model.value.countsFromOne = false
        originEditor.keyDown(with: try key("\r", code: 36, window: hosted)); pump(); leave(hosted)
        XCTAssertEqual(model.value.program, 9); XCTAssertEqual(model.commits, 0)
        XCTAssertEqual(program.stringValue, "9")
        let sameDisplayEditor = try type("77", into: program, in: hosted)
        model.value.countsFromOne = true; model.value.program = 8 // Still displayed as 9.
        sameDisplayEditor.keyDown(with: try key("\r", code: 36, window: hosted)); pump(); leave(hosted)
        XCTAssertEqual(model.value.program, 8); XCTAssertEqual(model.commits, 0)
        let historyEditor = try type("77", into: program, in: hosted)
        model.value.program = 24
        historyEditor.keyDown(with: try key("\r", code: 36, window: hosted)); pump(); leave(hosted)
        XCTAssertEqual(model.value.program, 24); XCTAssertEqual(model.commits, 0)
        try type("66", into: program, in: hosted)
        model.enabled = false; pump(); leave(hosted)
        XCTAssertFalse(program.isEnabled)
        XCTAssertEqual(model.value.program, 24); XCTAssertEqual(model.commits, 0)
        model.enabled = true; pump()
        try type("127", into: program, in: hosted); try enter(hosted)
        XCTAssertEqual(model.value.program, 126); XCTAssertEqual(model.commits, 1)
    }

    func testNativeCountingPickerAndRemovingBankDiscardOpenDraft() throws {
        let model = Selection(); model.value.bankMSB = 7
        let window = window(Harness(model: model)); defer { window.close() }
        let program = try field(window)
        try type("128", into: program, in: window)
        let picker = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("Device shows 0–127") })
        let item = try XCTUnwrap(picker.item(withTitle: "Device shows 0–127"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)); pump(); leave(window)
        XCTAssertFalse(model.value.countsFromOne); XCTAssertEqual(model.value.program, 9)
        XCTAssertEqual(model.commits, 1, "Only the counting preference crosses the binding")
        try type("128", into: program, in: window); try enter(window); leave(window)
        XCTAssertEqual(model.value.program, 9); XCTAssertEqual(model.commits, 1)
        let bank = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "0…127" && $0 !== program })
        let bankEditor = try type("55", into: bank, in: window)
        model.value.bankMSB = nil
        bankEditor.keyDown(with: try key("\r", code: 36, window: window)); pump(); leave(window)
        XCTAssertNil(model.value.bankMSB); XCTAssertEqual(model.commits, 1, "Removal cannot resurrect a drafted bank")
    }

    func testLayerSelectionCommitsPreviousDraftToItsOriginalLayer() throws {
        let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
        defer { fixture.root.terminate {} }
        let first = canvas.workspace.selectedLayerID
        var second = first
        canvas.updateWorkspace { second = $0.duplicateSelectedLayer()! }
        _ = canvas.selectLayers([first], active: first)
        let audio = AudioCatalogModel(document: owner, source: EmptyCatalog())
        let window = window(LayerInspectorView(editor: canvas, audioUnits: audio, midiOutput: fixture.root.midi,
            spatialInstrument: owner, evaluationCounter: nil), height: 1000)
        defer { window.close() }
        let before = owner.document
        try type("55", into: field(window), in: window)
        _ = canvas.selectLayers([second], active: second); pump(); leave(window)
        XCTAssertEqual(SpatialAssignmentDraft.current(in: canvas.presentation).programChange.program, 9)
        XCTAssertNotEqual(owner.document.revision, before.revision)
        guard case .programChange(let previous) = owner.document.spatial.layers.first(where: { $0.id == first })?.routings.first?.program else { return XCTFail("Original layer must retain its program") }
        XCTAssertEqual(previous.program, 54)
        try type("56", into: field(window), in: window); try enter(window); leave(window)
        XCTAssertEqual(SpatialAssignmentDraft.current(in: canvas.presentation).programChange.program, 55)
        _ = canvas.selectLayers([first], active: first); pump()
        XCTAssertEqual(SpatialAssignmentDraft.current(in: canvas.presentation).programChange.program, 54)
    }

    func testCellSelectionCommitsPreviousDraftToItsOriginalCell() throws {
        let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
        defer { fixture.root.terminate {} }
        let first = PolarMetricGridCell(ring: 3, angularIndex: 8)
        let second = PolarMetricGridCell(ring: 3, angularIndex: 9)
        let hosted = window(CellInspectorView(editor: canvas)); defer { hosted.close() }
        let before = owner.document
        try type("55", into: field(hosted), in: hosted)
        let size = CGSize(width: 800, height: 800)
        func select(_ cell: PolarMetricGridCell) {
            let center = SpatialFieldPlan.center(.init(cell: cell, grid: canvas.workspace.grid))
            let point = canvas.displayGeometry(canvasSize: size).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
            _ = canvas.selectCell(atScreenPoint: point, canvasSize: size)
            XCTAssertEqual(canvas.selectedPolarCell, cell)
            pump()
        }
        select(second); leave(hosted)
        XCTAssertNotEqual(owner.document.revision, before.revision)
        XCTAssertEqual(try cellProgram(owner).program, 54, "Selection commits to the originating cell before moving")
        try type("56", into: field(hosted), in: hosted); try enter(hosted); leave(hosted)
        let info = try XCTUnwrap(SpatialCellInfo.make(cell: second, layerID: canvas.workspace.selectedLayerID, workspace: canvas.workspace))
        guard case .programChange(let value) = info.value else { return XCTFail("Expected program cell") }
        XCTAssertEqual(value.program, 55)
        select(first)
        XCTAssertEqual(try field(hosted).stringValue, "55")
        XCTAssertEqual(try cellProgram(owner).program, 54)
    }

    func testRetainedNativeHostAndSelectionSubscriptionEndWithWindow() throws {
        let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
        defer { fixture.root.terminate {} }
        weak var native: NSView?
        try autoreleasepool {
            let hosted = window(CellInspectorView(editor: canvas))
            native = try XCTUnwrap(descendants(hosted.contentView!).first {
                $0.identifier?.rawValue == "inspector.retained.cellProgram"
            })
            hosted.contentView = nil; hosted.close()
        }
        pump()
        XCTAssertNil(native, "The document owner must not retain a closed inspector through its selection subscription")
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        canvas.updateWorkspace { $0.updateSelectedLayer {
            $0.routings = [.init(target: .midiCC(channel: 0, controller: 74), program: .constant(0.5))]
        } }
        pump()
        XCTAssertNil(native)
        XCTAssertEqual(probe.counts["inspector.cellInfo", default: 0], 0)
        XCTAssertEqual(probe.counts["inspector.controlPreparation", default: 0], 0)
    }

    func testRetainedLayerCCDraftCannotMoveIntoAMusicalLayer() throws {
        let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
        defer { fixture.root.terminate {} }
        let cc = canvas.workspace.selectedLayerID
        var music = cc
        canvas.updateWorkspace { workspace in
            workspace.updateSelectedLayer {
                $0.routings = [.init(target: .midiCC(channel: 0, controller: 74), program: .constant(0.5))]
            }
            music = workspace.duplicateSelectedLayer()!
            workspace.updateSelectedLayer {
                $0.routings = [.init(target: .midiNote(channel: 0), program: .chord(notes: [60, 64, 67], velocity: 100, transition: .legato))]
            }
            workspace.selectLayer(cc)
        }
        let hosted = window(LayerInspectorView(editor: canvas,
            audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()), midiOutput: fixture.root.midi,
            spatialInstrument: owner, evaluationCounter: nil), height: 1000)
        defer { hosted.close() }
        let before = owner.document
        let oldEditor = try type("2", into: field(hosted, placeholder: "Minimum"), in: hosted)
        _ = canvas.selectLayers([music], active: music)
        oldEditor.keyDown(with: try key("\r", code: 36, window: hosted))
        pump(); leave(hosted)
        XCTAssertEqual(owner.document, before)
        XCTAssertFalse(visibleText(hosted).contains("Discard"), "A CC formatter cannot author a pending musical draft")
        _ = canvas.selectLayers([cc], active: cc); pump()
        let text = try field(hosted, placeholder: "Minimum").stringValue.replacingOccurrences(of: ",", with: ".")
        XCTAssertEqual(Double(text), 0.5)
    }

    func testRetainedCCDraftCannotChangeMeaningWhenTheSameCellChangesTarget() throws {
        let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
        defer { fixture.root.terminate {} }
        canvas.updateWorkspace { $0.updateSelectedLayer {
            $0.routings = [.init(target: .midiCC(channel: 0, controller: 74), program: .constant(0.5))]
        } }
        let hosted = window(CellInspectorView(editor: canvas)); defer { hosted.close() }
        let oldEditor = try type("99", into: field(hosted, placeholder: "Value 0…127"), in: hosted)
        canvas.updateWorkspace { $0.updateSelectedLayer {
            $0.routings[0].target = .midiPitchBend(channel: 0)
        } }
        let before = owner.document
        // Deliver the previous native responder's Return before SwiftUI updates.
        oldEditor.keyDown(with: try key("\r", code: 36, window: hosted))
        pump(); leave(hosted)
        XCTAssertTrue(owner.document == before, "The previous CC Return must not author the new pitch target")
        XCTAssertEqual(try field(hosted, placeholder: "Value 0…100 %").stringValue, "50")
        try type("75", into: field(hosted, placeholder: "Value 0…100 %"), in: hosted)
        try enter(hosted); leave(hosted)
        let cell = try XCTUnwrap(canvas.selectedPolarCell)
        XCTAssertEqual(SpatialCellInfo.make(cell: cell, layerID: canvas.workspace.selectedLayerID,
            workspace: canvas.workspace)?.value, .scalar(0.75))
        XCTAssertTrue(owner.undo()); pump()
        XCTAssertEqual(try field(hosted, placeholder: "Value 0…100 %").stringValue, "50")
    }

    func testRetainedCCFieldCommitsToOriginalCellWithoutRecreatingResponder() throws {
        let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
        defer { fixture.root.terminate {} }
        canvas.updateWorkspace { $0.updateSelectedLayer {
            $0.routings = [.init(target: .midiCC(channel: 0, controller: 74), program: .constant(0.5))]
        } }
        let hosted = window(CellInspectorView(editor: canvas)); defer { hosted.close() }
        let input = try field(hosted, placeholder: "Value 0…127")
        XCTAssertEqual(input.stringValue, "64")
        let oldEditor = try type("99", into: input, in: hosted)
        let before = owner.document
        let second = PolarMetricGridCell(ring: 3, angularIndex: 9), size = CGSize(width: 800, height: 800)
        let center = SpatialFieldPlan.center(.init(cell: second, grid: canvas.workspace.grid))
        let point = canvas.displayGeometry(canvasSize: size).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
        _ = canvas.selectCell(atScreenPoint: point, canvasSize: size)
        // The old native editor may still deliver Return before SwiftUI flushes.
        oldEditor.keyDown(with: try key("\r", code: 36, window: hosted))
        pump(); leave(hosted)
        XCTAssertEqual(canvas.selectedPolarCell, second)
        XCTAssertNotEqual(owner.document.revision, before.revision)
        let originalCell = PolarMetricGridCell(ring: 3, angularIndex: 8)
        XCTAssertEqual(SpatialCellInfo.make(cell: originalCell, layerID: canvas.workspace.selectedLayerID,
            workspace: canvas.workspace)?.value, .scalar(99.0 / 127))
        XCTAssertTrue(try field(hosted, placeholder: "Value 0…127") === input)
        XCTAssertEqual(input.stringValue, "64")
        try type("127", into: input, in: hosted); try enter(hosted); leave(hosted)
        let info = try XCTUnwrap(SpatialCellInfo.make(cell: second, layerID: canvas.workspace.selectedLayerID, workspace: canvas.workspace))
        XCTAssertEqual(info.value, .scalar(1))
        XCTAssertTrue(owner.undo()); pump()
        XCTAssertEqual(input.stringValue, "64")
    }

    func testRetainedProgramFieldsAreDisabledAndDiscardDraftWhileHidden() throws {
        let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
        defer { fixture.root.terminate {} }
        let hosted = window(CellInspectorView(editor: canvas)); defer { hosted.close() }
        let number = try field(hosted)
        try type("55", into: number, in: hosted)
        canvas.updateWorkspace { $0.updateSelectedLayer {
            $0.routings[0].target = .midiNote(channel: 0)
            $0.routings[0].program = .singleNote(note: 60, velocity: 100, transition: .legato)
        } }
        let noteDocument = owner.document
        pump(); leave(hosted)
        XCTAssertFalse(number.isEnabled, "Retaining a hidden field must not leave a native keyboard responder enabled")
        XCTAssertTrue(owner.document == noteDocument)
        canvas.updateWorkspace { $0.updateSelectedLayer {
            $0.routings[0].target = .midiProgramChange(channel: 0)
            $0.routings[0].program = .programChange(.init(program: 9))
        } }
        pump()
        XCTAssertTrue(number.isEnabled)
        XCTAssertEqual(number.stringValue, "10")
        XCTAssertEqual(try cellProgram(owner).program, 9)
        try type("56", into: number, in: hosted); try enter(hosted); leave(hosted)
        XCTAssertEqual(try cellProgram(owner).program, 55)
    }

    func testNativeTextResponderKeepsTCanvasKeysAndTextUndo() throws {
        let model = Selection()
        var canvasKeys = 0
        let hosted = self.window(ZStack {
            Harness(model: model)
            ScanFieldPointerEvents(onScroll: { _, _ in }, onPressedTwoFingerDrag: { _ in }, onMagnify: { _, _ in },
                onKeyCommand: { _ in canvasKeys += 1; return true }).frame(width: 0, height: 0)
        }); defer { hosted.close() }
        var taps = 0
        let monitor = TempoTapShortcutMonitor(tap: { taps += 1 }); defer { monitor.stop() }
        monitor.register(try XCTUnwrap(hosted.contentView))
        let pointer = try XCTUnwrap(descendants(hosted.contentView!).compactMap { $0 as? ScanFieldPointerEvents.PointerView }.first)
        let editor = try type("12", into: field(hosted), in: hosted)
        editor.setSelectedRange(.init(location: editor.string.utf16.count, length: 0))
        for (text, code) in [("t", UInt16(17)), ("v", 9), ("b", 11), ("e", 14), ("h", 4)] {
            let event = try key(text, code: code, window: hosted)
            XCTAssertTrue(monitor.handle(event, keyWindow: hosted, modalWindow: nil) === event)
            XCTAssertTrue(pointer.handle(event) === event)
            editor.keyDown(with: event)
        }
        pump()
        XCTAssertEqual(editor.string, "12tvbeh"); XCTAssertEqual(taps, 0); XCTAssertEqual(canvasKeys, 0)
        XCTAssertEqual(model.commits, 0)
        let beforeUndo = editor.string
        XCTAssertTrue(try XCTUnwrap(editor.undoManager).canUndo)
        editor.undoManager?.undo(); pump()
        XCTAssertNotEqual(editor.string, beforeUndo); XCTAssertEqual(model.commits, 0)
        leave(hosted)
        XCTAssertEqual(model.value.program, 9)
        XCTAssertNil(monitor.handle(try key("t", code: 17, window: hosted), keyWindow: hosted, modalWindow: nil))
        XCTAssertEqual(taps, 1)
        XCTAssertTrue(hosted.makeFirstResponder(pointer))
        XCTAssertNil(pointer.handle(try key("v", code: 9, window: hosted)))
        XCTAssertEqual(canvasKeys, 1, "The same canvas shortcut becomes active after leaving text")
    }

    func testEscapeDiscardsNumberEvenWhenMonitorCancelsCapture() throws {
        let model = Selection()
        let hosted = self.window(Harness(model: model)); defer { hosted.close() }
        var capturing = true, cancellations = 0
        let monitor = TempoTapShortcutMonitor(tap: { XCTFail("Escape must not tap") }, cancelCapture: {
            guard capturing else { return false }
            capturing = false; cancellations += 1; return true
        })
        defer { monitor.stop() }
        monitor.register(try XCTUnwrap(hosted.contentView))
        let number = try field(hosted), editor = try type("77", into: number, in: hosted)
        let event = try key("\u{1b}", code: 53, window: hosted)
        let forwarded = monitor.handle(event, keyWindow: hosted, modalWindow: nil)
        if let forwarded { editor.keyDown(with: forwarded) }
        pump()
        XCTAssertFalse(capturing); XCTAssertEqual(cancellations, 1)
        XCTAssertNil(forwarded, "Capture cancellation still consumes Escape")
        XCTAssertEqual(number.stringValue, "10", "The number draft must also be discarded")
        leave(hosted)
        XCTAssertEqual(model.value.program, 9); XCTAssertEqual(model.commits, 0)
    }

    func testInspectorCountingChangeCommitsTypedProgramUsingPreviousOrigin() throws {
        let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
        defer { fixture.root.terminate {} }
        canvas.rememberProgramCounting = { _, _ in }
        let hosted = window(LayerInspectorView(editor: canvas, audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()),
            midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil), height: 1000)
        defer { hosted.close() }
        try type("3", into: field(hosted), in: hosted)
        let picker = try XCTUnwrap(descendants(hosted.contentView!).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("Device shows 0–127") })
        let item = try XCTUnwrap(picker.item(withTitle: "Device shows 0–127"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)); pump()
        let current = SpatialAssignmentDraft.current(in: canvas.presentation).programChange
        XCTAssertEqual(current.program, 2); XCTAssertFalse(current.countsFromOne)
        leave(hosted)
        XCTAssertEqual(SpatialAssignmentDraft.current(in: canvas.presentation).programChange, current)
    }

    func testControllerStepperAndFreeNumberCommitAsSeparateUndo() throws {
        let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
        defer { fixture.root.terminate {} }
        canvas.updateWorkspace { $0.updateSelectedLayer {
            $0.routings = [.init(target: .midiCC(channel: 8, controller: 74), program: .constant(0.5))]
        } }
        let hosted = window(LayerInspectorView(editor: canvas, audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()),
            midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil), height: 1000)
        defer { hosted.close() }
        try action("accessibilityPerformIncrement", label: "Controller fine adjustment", window: hosted)
        XCTAssertEqual(canvas.workspace.selectedLayer.routings[0].target.controllerNumber, 75)
        let input = try field(hosted, placeholder: "0…127")
        try type("11", into: input, in: hosted); leave(hosted)
        XCTAssertEqual(canvas.workspace.selectedLayer.routings[0].target.controllerNumber, 11)
        XCTAssertTrue(owner.undo()); pump()
        XCTAssertEqual(canvas.workspace.selectedLayer.routings[0].target.controllerNumber, 75)
        XCTAssertTrue(owner.undo()); pump()
        XCTAssertEqual(canvas.workspace.selectedLayer.routings[0].target.controllerNumber, 74)
        try type("100", into: input, in: hosted)
        try action("accessibilityPerformIncrement", label: "Controller fine adjustment", window: hosted)
        XCTAssertEqual(canvas.workspace.selectedLayer.routings[0].target.controllerNumber, 101)
        XCTAssertTrue(owner.undo()); pump()
        XCTAssertEqual(canvas.workspace.selectedLayer.routings[0].target.controllerNumber, 100)
        XCTAssertTrue(owner.undo()); pump()
        XCTAssertEqual(canvas.workspace.selectedLayer.routings[0].target.controllerNumber, 74)
        XCTAssertEqual(MIDIControllerNames.name(11), "Expression")
    }

    func testUnsubmittedProgramBankAndCCReachSavedPresetWithoutPassiveCaptureCommitting() throws {
        for cell in [false, true] { for cc in [false, true] {
            let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
            defer { fixture.root.terminate {} }
            canvas.updateWorkspace { $0.updateSelectedLayer {
                $0.routings = [.init(target: cc ? .midiCC(channel: 8, controller: 74) : .midiProgramChange(channel: 8),
                    program: cc ? .constant(0.5) : .programChange(.init(program: 9, countsFromOne: false, bankMSB: 0, bankLSB: 0)))]
            } }
            canvas.programCountingPreference = { _ in false }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AU-MIDI-save-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PresetFileStore(directory: directory)
            let presets = PresetControlModel(store: store, documentOwner: owner)
            let hosted = window(Group {
                if cell { CellInspectorView(editor: canvas) }
                else { LayerInspectorView(editor: canvas, audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()),
                    midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil) }
            }, height: 1000)
            defer { hosted.close() }
            let input = try field(hosted, placeholder: cc && cell ? "Value 0…127" : "0…127")
            try type(cc ? "11" : "3", into: input, in: hosted)
            let before = owner.document.revision
            _ = try owner.snapshotPresetDocument()
            XCTAssertEqual(owner.document.revision, before, "Passive snapshots must leave the editor draft alone")
            presets.draftName = "Entry without Return"
            XCTAssertTrue(presets.save())
            XCTAssertNotEqual(owner.document.revision, before)
            let saved = try PresetDocumentReader.read(store.load("Entry without Return")).get().replacing(owner.document)
            let layer = try XCTUnwrap(saved.spatial.layers.first)
            if cc && !cell { XCTAssertEqual(layer.routings[0].target.controllerNumber, 11) }
            else if cc {
                XCTAssertTrue(layer.cellOverrides.values.flatMap { $0 }.contains { $0.value == .scalar(11.0 / 127) })
            } else if cell {
                XCTAssertTrue(layer.cellOverrides.values.flatMap { $0 }.contains { $0.value == .programChange(.init(program: 3, countsFromOne: false, bankMSB: 0, bankLSB: 0)) })
            } else { XCTAssertEqual(layer.routings[0].program, .programChange(.init(program: 3, countsFromOne: false, bankMSB: 0, bankLSB: 0))) }
            leave(hosted)
            XCTAssertTrue(owner.undo()); pump()
            XCTAssertEqual(owner.document.spatial.layers.first?.routings.first?.target.controllerNumber, cc ? 74 : nil)
        } }
    }

    func testRetainedInspectorControlsHaveDisjointFramesAcrossTransitions() throws {
        InspectorLayoutProbe.enabled = true
        defer { InspectorLayoutProbe.enabled = false }
        let fixture = try fixture(), owner = fixture.root.document, canvas = owner.canvas
        defer { fixture.root.terminate {} }
        let audio = AudioCatalogModel(document: owner, source: EmptyCatalog())
        for cell in [false, true] {
            let hosted = window(Group {
                if cell { StableCellInspectorView(editor: canvas).equatable() }
                else { StableSpatialLayerInspectorView(editor: canvas, audioUnits: audio, midiOutput: fixture.root.midi,
                    spatialInstrument: owner, evaluationCounter: nil).equatable() }
            }, height: 650)
            defer { hosted.close() }
            for width: CGFloat in [300, 420] {
                hosted.setContentSize(.init(width: width, height: 650))
                let targets: [SpatialRoutingTarget] = [.midiNote(channel: 0), .midiCC(channel: 0, controller: 74),
                    .midiProgramChange(channel: 0), .midiPitchBend(channel: 0), .midiChannelPressure(channel: 0),
                    .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID),
                    .audioUnitCC(channel: 0, controller: 74, stripID: InstrumentChannel.legacyID),
                    .audioUnitProgramChange(channel: 0, stripID: InstrumentChannel.legacyID),
                    .audioUnitPitchBend(channel: 0, stripID: InstrumentChannel.legacyID),
                    .audioUnitChannelPressure(channel: 0, stripID: InstrumentChannel.legacyID)]
                for from in targets {
                    for to in targets {
                        for target in [from, to] {
                            canvas.updateWorkspace { $0.updateSelectedLayer {
                                $0.routings = [.init(target: target, program: target.isProgramChange
                                    ? .programChange(.init(program: 9, bankMSB: 2, bankLSB: 3))
                                    : (target == .midiNote(channel: 0) || target == .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)) ? .singleNote(note: 60, velocity: 100, transition: .legato) : .constant(0.5))]
                            } }
                            pump(); hosted.contentView!.layoutSubtreeIfNeeded()
                        }
                        let root = hosted.contentView!
                        let markers = descendants(root).filter {
                            $0.identifier?.rawValue.hasPrefix("inspector.frame.") == true && !$0.isHiddenOrHasHiddenAncestor
                        }
                        XCTAssertGreaterThan(markers.count, 1, "Real visible row frames are required: \(to)")
                        for (index, a) in markers.enumerated() {
                            let aFrame = a.convert(a.bounds, to: root).insetBy(dx: 1, dy: 1)
                            guard aFrame.width > 0, aFrame.height > 0 else { continue }
                            for b in markers.dropFirst(index + 1) {
                                let bFrame = b.convert(b.bounds, to: root).insetBy(dx: 1, dy: 1)
                                guard bFrame.width > 0, bFrame.height > 0 else { continue }
                                // A marked composite row can contain a marked
                                // number leaf; only unrelated rows may intersect.
                                if aFrame.contains(bFrame) || bFrame.contains(aFrame) { continue }
                                XCTAssertFalse(aFrame.intersects(bFrame), "\(cell ? "cell" : "layer") \(width) \(from) → \(to): \(a.identifier!.rawValue) \(aFrame) overlaps \(b.identifier!.rawValue) \(bFrame)")
                            }
                        }
                        if from == targets[0] && (to.isProgramChange || to.controllerNumber != nil) {
                            let directory = TestImageDirectory.make()
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                            root.cacheDisplay(in: root.bounds, to: bitmap)
                            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(cell ? "cell" : "layer")-\(to.destination)-\(to.isProgramChange ? "pc" : "cc")-\(Int(width)).png"))
                        }
                    }
                }
            }
        }
    }

    private func fixture() throws -> MonitorRootFixture {
        let fixture = try MonitorRootFixture(), canvas = fixture.root.document.canvas
        canvas.updateWorkspace { workspace in
            workspace.updateSelectedLayer {
                $0.name = "Effect programs"
                $0.polarCells = [.init(ring: 3, angularIndex: 8), .init(ring: 3, angularIndex: 9)]
                $0.routings = [.init(target: .midiProgramChange(channel: 0), program: .programChange(.init(program: 9)))]
            }
        }
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 8), size = CGSize(width: 800, height: 800)
        let center = SpatialFieldPlan.center(.init(cell: cell, grid: canvas.workspace.grid))
        let point = MetricCanvasGeometry(size: size, viewport: canvas.viewport).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
        _ = canvas.selectCell(atScreenPoint: point, canvasSize: size)
        return fixture
    }
    private func cellProgram(_ owner: SpatialInstrumentRuntimeModel) throws -> SpatialProgramChange {
        let layer = owner.canvas.workspace.selectedLayer
        let info = try XCTUnwrap(SpatialCellInfo.make(cell: .init(ring: 3, angularIndex: 8), layerID: layer.id, workspace: owner.canvas.workspace))
        guard case .programChange(let value) = info.value else { throw NSError(domain: "PC-NUMMER", code: 1) }
        return value
    }
    private func assertRestored(_ owner: SpatialInstrumentRuntimeModel, original: InstrumentDocument) {
        var restored = owner.document; restored.revision = original.revision
        XCTAssertTrue(restored == original, "Undo restores the complete document apart from its monotonic revision")
    }

    func testRealCellInputUndoRedoStepperGroupsAndPerformGuard() throws {
        let fixture = try fixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let window = window(CellInspectorView(editor: owner.canvas)); defer { window.close() }
        let program = try field(window), original = owner.document
        try type("128", into: program, in: window)
        XCTAssertEqual(owner.document, original)
        try enter(window); leave(window)
        XCTAssertEqual(try cellProgram(owner).program, 127)
        XCTAssertTrue(owner.undo()); pump(); assertRestored(owner, original: original)
        XCTAssertTrue(owner.redo()); pump(); XCTAssertEqual(try cellProgram(owner).program, 127)
        try type("20", into: program, in: window); leave(window)
        try type("21", into: program, in: window); try enter(window); leave(window)
        XCTAssertEqual(try cellProgram(owner).program, 20)
        XCTAssertTrue(owner.undo()); pump(); XCTAssertEqual(try cellProgram(owner).program, 19)
        XCTAssertTrue(owner.undo()); pump(); XCTAssertEqual(try cellProgram(owner).program, 127)
        XCTAssertTrue(owner.redo()); XCTAssertTrue(owner.redo()); pump()
        for _ in 0..<3 { try action("accessibilityPerformIncrement", label: "Preset fine adjustment", window: window) }
        XCTAssertEqual(try cellProgram(owner).program, 23)
        XCTAssertTrue(owner.undo()); pump(); XCTAssertEqual(try cellProgram(owner).program, 20)
        XCTAssertTrue(owner.redo()); pump(); XCTAssertEqual(try cellProgram(owner).program, 23)
        try type("200", into: program, in: window); try enter(window); leave(window)
        XCTAssertEqual(try cellProgram(owner).program, 23)
        let beforeLock = owner.document
        try type("55", into: program, in: window)
        owner.canvas.setPerformanceLocked(true); pump(); leave(window)
        XCTAssertFalse(program.isEnabled); XCTAssertEqual(owner.document, beforeLock)
        _ = owner.canvas.applyToSelection(.setAction(.init(target: .midiProgramChange(channel: 0), value: .programChange(.init(program: 70)))), coalescingKey: "attempt")
        XCTAssertEqual(owner.document, beforeLock)
    }

    func testRealLayerEntryIsOneUndoStepperCoalescesAndPerformDisablesFields() throws {
        let fixture = try fixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let audio = AudioCatalogModel(document: owner, source: EmptyCatalog())
        let window = window(LayerInspectorView(editor: owner.canvas, audioUnits: audio, midiOutput: fixture.root.midi,
            spatialInstrument: owner, evaluationCounter: nil), height: 1000)
        defer { window.close() }
        let program = try field(window), original = owner.document
        try type("128", into: program, in: window); try enter(window); leave(window)
        XCTAssertEqual(SpatialAssignmentDraft.current(in: owner.canvas.presentation).programChange.program, 127)
        XCTAssertTrue(owner.undo()); pump(); assertRestored(owner, original: original)
        XCTAssertTrue(owner.redo()); pump()
        try type("20", into: program, in: window); leave(window)
        try type("21", into: program, in: window); try enter(window); leave(window)
        XCTAssertTrue(owner.undo()); pump()
        XCTAssertEqual(SpatialAssignmentDraft.current(in: owner.canvas.presentation).programChange.program, 19)
        XCTAssertTrue(owner.undo()); pump()
        XCTAssertEqual(SpatialAssignmentDraft.current(in: owner.canvas.presentation).programChange.program, 127)
        XCTAssertTrue(owner.redo()); XCTAssertTrue(owner.redo()); pump()
        for _ in 0..<3 { try action("accessibilityPerformIncrement", label: "Preset fine adjustment", window: window) }
        XCTAssertEqual(SpatialAssignmentDraft.current(in: owner.canvas.presentation).programChange.program, 23)
        XCTAssertTrue(owner.undo()); pump()
        XCTAssertEqual(SpatialAssignmentDraft.current(in: owner.canvas.presentation).programChange.program, 20)
        let beforeInvalid = owner.document
        try type("200", into: program, in: window); try enter(window); leave(window)
        XCTAssertTrue(owner.document == beforeInvalid)
        owner.canvas.setPerformanceLocked(true); pump()
        XCTAssertFalse(try field(window).isEnabled)
    }

    func testLayerAndCellBankEntriesCommitOnFocusTransferAndHaveSeparateUndo() throws {
        for cell in [false, true] {
            let fixture = try fixture(), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            owner.canvas.updateWorkspace { workspace in
                workspace.updateSelectedLayer {
                    $0.routings[0].program = .programChange(.init(program: 9, bankMSB: 0, bankLSB: 0))
                }
            }
            let audio = AudioCatalogModel(document: owner, source: EmptyCatalog())
            let view = cell ? AnyView(CellInspectorView(editor: owner.canvas))
                : AnyView(LayerInspectorView(editor: owner.canvas, audioUnits: audio, midiOutput: fixture.root.midi,
                    spatialInstrument: owner, evaluationCounter: nil))
            let window = window(view, height: 1000); defer { window.close() }
            let banks = descendants(window.contentView!).compactMap { $0 as? NSTextField }.filter { $0.placeholderString == "0…127" }
            XCTAssertEqual(banks.count, 2)
            let original = owner.document
            func current() throws -> SpatialProgramChange {
                cell ? try cellProgram(owner) : SpatialAssignmentDraft.current(in: owner.canvas.presentation).programChange
            }
            try type("127", into: banks[0], in: window)
            XCTAssertTrue(owner.document == original)
            try type("126", into: banks[1], in: window)
            XCTAssertEqual(try current().bankMSB, 127); XCTAssertEqual(try current().bankLSB, 0)
            try enter(window); leave(window)
            XCTAssertEqual(try current().bankLSB, 126)
            XCTAssertTrue(owner.undo()); pump()
            XCTAssertEqual(try current().bankMSB, 127); XCTAssertEqual(try current().bankLSB, 0)
            XCTAssertTrue(owner.undo()); pump(); assertRestored(owner, original: original)
            XCTAssertTrue(owner.redo()); XCTAssertTrue(owner.redo()); pump()
            XCTAssertEqual(try current().bankMSB, 127); XCTAssertEqual(try current().bankLSB, 126)
            let beforeInvalid = owner.document
            try type("200", into: banks[1], in: window); try enter(window); leave(window)
            XCTAssertTrue(owner.document == beforeInvalid)
            owner.canvas.setPerformanceLocked(true); pump()
            XCTAssertTrue(banks.allSatisfy { !$0.isEnabled })
        }
    }
}

extension ProgramNumberEntryTests {
    func testTransposeFieldApplyReturnClampRepeatZeroAndUndo() throws {
        let fixture = try fixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        owner.canvas.updateWorkspace { workspace in
            workspace.updateSelectedLayer { layer in
                layer.routings = [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .legato))]
            }
        }
        owner.canvas.clearSelection()
        let original = owner.document
        let audio = AudioCatalogModel(document: owner, source: EmptyCatalog())
        let w = window(LayerInspectorView(editor: owner.canvas, audioUnits: audio, midiOutput: fixture.root.midi,
            spatialInstrument: owner, evaluationCounter: nil), height: 1000)
        defer { w.close() }
        let amount = try field(w, placeholder: "Semitones")
        func note() -> Int? {
            if case let .singleNote(note, _, _) = owner.document.spatial.layers[0].routings[0].program { return note }
            return nil
        }
        try type("7", into: amount, in: w)
        try action("accessibilityPerformPress", label: "Apply", window: w); pump()
        XCTAssertEqual(note(), 67); XCTAssertEqual(amount.stringValue, "7")
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, original.spatial)
        try type("-13", into: amount, in: w); try enter(w)
        XCTAssertEqual(note(), 47); XCTAssertEqual(amount.stringValue, "-13")
        try enter(w); XCTAssertEqual(note(), 34)
        try type("99", into: amount, in: w); leave(w)
        XCTAssertEqual(amount.stringValue, "48")
        try type("invalid", into: amount, in: w); leave(w)
        XCTAssertEqual(amount.stringValue, "0")
        try type("0", into: amount, in: w); leave(w)
        let before = owner.document
        let apply = try XCTUnwrap(elements(w).first { label($0)?.hasSuffix("Apply") == true })
        let enabled = (apply as? NSAccessibilityProtocol)?.isAccessibilityEnabled()
            ?? (apply.responds(to: NSSelectorFromString("isAccessibilityEnabled")) ? apply.value(forKey: "accessibilityEnabled") as? Bool : nil)
        XCTAssertEqual(enabled, false)
        try action("accessibilityPerformPress", label: "Apply", window: w); pump()
        XCTAssertEqual(owner.document, before)
        try type("7", into: amount, in: w); owner.canvas.setPerformanceLocked(true); pump()
        try action("accessibilityPerformPress", label: "Apply", window: w); pump()
        XCTAssertEqual(owner.document, before)
    }
}
