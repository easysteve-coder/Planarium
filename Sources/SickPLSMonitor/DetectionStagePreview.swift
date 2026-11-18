import SwiftUI
import PlanariumDomain
import PlanariumApplication

/// Owner-review surface, reached only by the explicit offline preview flag.
/// Uses real controls/actions and the stage descriptors; production layout
/// changes wait for approval of the rendered proposal.
struct DetectionStagePreview: View {
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    let availableWidth: CGFloat
    var onEditing: (DetectionOverlayControl, Bool) -> Void = { _, _ in }
    var onHover: (DetectionOverlayControl, Bool) -> Void = { _, _ in }
    // Plain reference intentionally avoids observing the draft in the controls.
    var preview = DetectionCanvasPreview()
    private var configuration: DetectionConfiguration { instrument.document.detection }
    private var performing: Bool { instrument.canvas.isPerformanceLocked }
    private var matchingContour: Bool { instrument.roomContour != nil && instrument.roomContourMatches }
    private var columnCount: Int { availableWidth >= 1450 ? 6 : availableWidth >= 850 ? 3 : 2 }

    var body: some View {
        if columnCount == 6 {
            HStack(alignment: .top, spacing: 8) {
                ForEach(DetectionModule.allCases, id: \.self) { module in
                    moduleView(module).frame(width: wideModuleWidth(module))
                }
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8, alignment: .top), count: columnCount),
                      alignment: .leading, spacing: 8) {
                ForEach(DetectionModule.allCases, id: \.self) { module in
                    moduleView(module)
                }
            }
        }
    }

    private func wideModuleWidth(_ module: DetectionModule) -> CGFloat {
        let weight: CGFloat
        switch module {
        case .room, .fit, .cells: weight = 2
        case .beams, .time: weight = 3
        case .groups: weight = 4
        }
        return max(0, availableWidth - 40) * weight / 16
    }

    private func controlsPerRow(_ module: DetectionModule) -> Int {
        if columnCount == 6 { return module == .groups ? 4 : module == .beams || module == .time ? 3 : 2 }
        let moduleWidth = (availableWidth - CGFloat(columnCount - 1) * 8) / CGFloat(columnCount) - 18
        return max(1, min(4, Int(moduleWidth / 72)))
    }
    private func rowHeight(_ module: DetectionModule) -> CGFloat {
        if columnCount == 6 { return 202 }
        let index = DetectionModule.allCases.firstIndex(of: module)!
        let first = index / columnCount * columnCount
        let row = Array(DetectionModule.allCases[first..<min(first + columnCount, DetectionModule.allCases.count)])
        let rows = row.map { item -> Int in
            let count = max(item == .room || item == .fit ? 2 : 0, item.controls(configuration: configuration).count)
            return (count + controlsPerRow(item) - 1) / controlsPerRow(item)
        }.max() ?? 1
        return CGFloat(rows) * 78 + 64
    }
    @ViewBuilder private func moduleView(_ module: DetectionModule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(module.title, systemImage: module.symbol)
                .font(.caption.weight(.semibold)).foregroundColor(.secondary).frame(height: 16)
                .accessibilityIdentifier("detection.module.\(module.rawValue)")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: controlsPerRow(module)), spacing: 4) {
                if module == .room {
                    action(title: "Capture room", symbol: "record.circle", value: "5 s · 125 scans") {
                        if instrument.contourCapture.isCapturing { instrument.cancelRoomContourCapture() }
                        else { instrument.beginRoomContourCapture() }
                    }
                }
                if module == .fit {
                    action(title: "Fit to room", symbol: module.symbol, value: "Fit layout", enabled: matchingContour && !instrument.canvas.isDragging) {
                        instrument.fitToRoom()
                    }
                    DetectionKnob(title: "Margin", values: Array(0...50), value: instrument.roomFit.marginCentimeters,
                        defaultValue: 10, format: { "\($0) cm" }, help: "Distance from the measured wall. Only applies during this program run.",
                        select: { instrument.setRoomFitMargin(centimeters: $0) }, isEnabled: !performing,
                        accessibilityID: "detection.margin")
                        .frame(height: 74, alignment: .top)
                }
                ForEach(module.controls(configuration: configuration)) { control in
                    controlView(control)
                }
            }
            if module == .room {
                RoomContourCaptureStatus(capture: instrument.contourCapture, contour: instrument.roomContour)
                    .font(.caption2).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .topLeading).frame(height: rowHeight(module))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(StageTheme.border, lineWidth: 1))
    }
    private func action(title: String, symbol: String, value: String, enabled: Bool = true,
                        perform: @escaping () -> Void) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased()).font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
                .lineLimit(1)
            Button(action: perform) { Image(systemName: symbol).font(.system(size: 23)).frame(width: 30, height: 30) }
                .buttonStyle(.plain).disabled(!enabled)
            Text(value).font(.system(size: 10, weight: .medium).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(height: 74, alignment: .top).help(title)
    }
    private func controlView(_ control: DetectionControlDescriptor) -> some View {
        let enabled = control.isAvailable(configuration: configuration, hasMatchingContour: matchingContour, performing: performing)
        let help = performing ? InstrumentAction.performanceLockReason : control.id == .confirmation
            ? DetectionLatency.confirmationTooltip(profiles: configuration.cellSelection.confirmationProfiles, profileRateHertz: 25) : control.tooltip
        return DetectionKnob(title: control.name, values: control.values, value: control.value(in: configuration),
            defaultValue: control.defaultValue, format: control.formatted, help: help,
            select: { value in
                guard instrument.authorize(.edit) else { return }
                instrument.updateDetectionConfiguration(control.applying(value, to: configuration,
                    hasMatchingContour: matchingContour, performing: performing))
            }, onEditing: { onEditing(control.overlay, $0) }, onHover: { onHover(control.overlay, $0) },
            isEnabled: enabled, showsMagnet: control.id == .snap, accessibilityID: "detection.\(control.id.rawValue)",
            onPreview: preview.action(control.id, base: configuration, matchingContour: matchingContour, performing: performing))
            .frame(height: 74, alignment: .top)
    }
}
