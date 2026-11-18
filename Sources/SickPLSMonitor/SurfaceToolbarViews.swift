import SwiftUI
import PlanariumApplication
import PlanariumDomain
import SickPLSMonitorKit

/// The tool group of the field toolbar: the surface tools, or the older cell tools in the advanced cell editor.
struct SurfaceToolsGroup: View {
    @ObservedObject var model: SurfaceEditorModel
    @ObservedObject var editor: CanvasSession
    let cells: AnyView
    var body: some View {
        HStack(spacing: 4) {
            if model.mode == .surfaces {
                ForEach(SurfaceTool.allCases, id: \.self) { tool in
                    let on = model.tool == tool && editor.presentation.tool == .select
                    button(tool.label, symbol: tool.symbol, on: on, id: "field.surface.\(tool.rawValue)") { model.select(tool: tool) }
                }
                ForEach([MetricCanvasTool.pan, .audition], id: \.self) { tool in
                    button(tool.label, symbol: tool.symbol, on: editor.presentation.tool == tool, id: "field.tool.\(tool.rawValue)") { editor.select(tool: tool) }
                }
            } else {
                cells
            }
        }.fixedSize()
    }
    private func button(_ title: String, symbol: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { FieldToolbarIconLabel(title: title, symbol: symbol) }
            .buttonStyle(.plain).help(title).iconAccessibility(title).padding(6)
            .foregroundColor(on ? .black : .white)
            .background(on ? StageTheme.amber : HelmutChrome.control)
            .cornerRadius(4)
            .accessibilityValue(on ? "selected" : "not selected")
            .accessibilityIdentifier(id)
    }
}

/// Switches between the surface editor and the advanced cell editor.
struct SurfaceModeButton: View {
    @ObservedObject var model: SurfaceEditorModel
    var body: some View {
        let surfaces = model.mode == .surfaces
        Button { model.setMode(surfaces ? .cells : .surfaces) } label: {
            FieldToolbarIconLabel(title: surfaces ? "Cell editor (advanced)" : "Surface editor", symbol: surfaces ? "square.grid.3x3" : "square.on.circle")
        }
        .buttonStyle(.plain).padding(6).foregroundColor(.white).background(HelmutChrome.control).cornerRadius(4)
        .help(surfaces ? "Cell editor (advanced): edit single cells like in older presets" : "Back to the surface editor")
        .accessibilityLabel(surfaces ? "Cell editor (advanced)" : "Surface editor").accessibilityIdentifier("field.surface.mode")
    }
}

/// Replaces the cell-size group in the surface editor: the measuring grid is an optional aid, off by default.
struct SurfaceGridGroup: View {
    @ObservedObject var model: SurfaceEditorModel
    let cells: AnyView
    var body: some View {
        if model.mode == .surfaces {
            IconToggle("Measuring grid", symbol: "grid", isOn: Binding(get: { model.showsGrid }, set: { model.setShowsGrid($0) }))
                .help("Show a 10 cm / 10° measuring grid as an alignment aid. It changes nothing in the instrument.")
                .fixedSize()
        } else { cells }
    }
}

/// What is selected, in the words the surface editor uses.
struct SurfaceSummaryText: View {
    @ObservedObject var model: SurfaceEditorModel
    @ObservedObject var editor: CanvasSession
    var body: some View {
        let count = editor.selection.surfaceIDs.count
        let all = editor.workspace.layers.count
        Text(count == 0 ? "\(all) \(all == 1 ? "layer" : "layers")" : "\(count) \(count == 1 ? "surface" : "surfaces") selected")
            .font(.caption.monospacedDigit()).lineLimit(1).foregroundColor(.secondary)
    }
}
