import SwiftUI
import SickPLSSimulationLink

private extension PlanariumPalette {
    static var workspaceColor: Color { Color(red: workspace.red, green: workspace.green, blue: workspace.blue, opacity: workspace.alpha) }
    static var canvasColor: Color { Color(red: canvas.red, green: canvas.green, blue: canvas.blue, opacity: canvas.alpha) }
    static var borderColor: Color { Color(red: border.red, green: border.green, blue: border.blue, opacity: border.alpha) }
    static var amberColor: Color { Color(red: amber.red, green: amber.green, blue: amber.blue, opacity: amber.alpha) }
    static var amberBrightColor: Color { Color(red: amberBright.red, green: amberBright.green, blue: amberBright.blue, opacity: amberBright.alpha) }
    static var gridColor: Color { Color(red: grid.red, green: grid.green, blue: grid.blue, opacity: grid.alpha) }
}

struct SimulationView: View {
    @ObservedObject var model: SimulationViewModel

    var body: some View {
        ZStack {
            PlanariumPalette.workspaceColor.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("SIMULATION").font(.system(size: 30, weight: .black, design: .rounded)).foregroundColor(PlanariumPalette.amberColor)
                Text(model.serviceNameForDisplay)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(PlanariumPalette.amberBrightColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("simulation.serviceName")
                Text(model.statusText).font(.subheadline).foregroundColor(.secondary)
                Text("Modus: \(model.deviceModeText)").font(.subheadline).foregroundColor(.secondary)
                SimulationField(model: model)
                    .frame(minHeight: 360, maxHeight: 520)
                ScrollView {
                    controls
                        .padding(.bottom)
                }
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .tint(PlanariumPalette.amberColor)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.toggleSending() } label: {
                    Label(model.isRunning ? "Senden stoppen" : "Senden starten", systemImage: model.isRunning ? "stop.fill" : "dot.radiowaves.left.and.right")
                }
                .help(model.isRunning ? "Senden stoppen" : "Senden starten")
                .accessibilityValue(model.isRunning ? "Läuft" : "Aus")
                Spacer()
                if model.droppedCount > 0 { Text("verworfen \(model.droppedCount)").foregroundColor(PlanariumPalette.amberColor) }
            }
            HStack { Text("Feldbreite \(model.fieldWidthMeters, specifier: "%.1f") m"); Slider(value: $model.fieldWidthMeters, in: 1...5, step: 0.1) }
            HStack { Text("Feldtiefe \(model.fieldDepthMeters, specifier: "%.1f") m"); Slider(value: $model.fieldDepthMeters, in: 1...5, step: 0.1) }
            Picker("Punkte", selection: $model.pointCount) { Text("90").tag(90); Text("361").tag(361) }.pickerStyle(.segmented)
            if model.pointCount == 361 { Text("25 Hz bei 361 am Gerät unbelegt").font(.caption).foregroundColor(.secondary) }
            if model.pointCount == 90 { Picker("Bei 90 Punkten", selection: $model.sampling) { Text("Nächster Treffer je 2°").tag(ProfileSampling.minimumPerBin); Text("Nur Mittelstrahl je 2°").tag(ProfileSampling.singleRay) } }
            HStack { Text("Handdurchmesser \(model.handDiameterMeters * 100, specifier: "%.0f") cm"); Slider(value: $model.handDiameterMeters, in: 0.08...0.10, step: 0.01) }
            Toggle("±3 cm Rauschen", isOn: $model.noiseEnabled)
            Toggle("Messfeldrand senden", isOn: $model.roomBackground)
        }
        .padding()
        .background(PlanariumPalette.canvasColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SimulationField: View {
    @ObservedObject var model: SimulationViewModel
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let mapping = FieldScreenMapping(fieldWidthCm: model.fieldWidthMeters * 100, fieldDepthCm: model.fieldDepthMeters * 100, viewWidth: Double(size.width), viewHeight: Double(size.height))
            ZStack {
                Canvas { context, canvasSize in
                    let rect = CGRect(origin: .zero, size: canvasSize)
                    context.fill(Path(rect), with: .color(PlanariumPalette.canvasColor))
                    context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(PlanariumPalette.borderColor), lineWidth: 2)
                    let scanner = mapping.scannerScreenPoint
                    let center = CGPoint(x: scanner.x, y: scanner.y)
                    context.clip(to: Path(CGRect(x: 0, y: 0, width: canvasSize.width, height: max(0, scanner.y))))
                    let meterStep = model.fieldDepthMeters <= 2.0 ? 0.5 : 1.0
                    var meter = meterStep
                    while meter <= model.fieldDepthMeters + 0.001 {
                        let radius = CGFloat(meter * 100.0 * mapping.scale)
                        let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                        context.stroke(ring, with: .color(PlanariumPalette.gridColor), lineWidth: 1)
                        let label = Text("\(meter, specifier: "%.1f") m")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(PlanariumPalette.amberBrightColor)
                        context.draw(label, at: CGPoint(x: center.x + 5, y: center.y - radius + 10), anchor: .leading)
                        meter += meterStep
                    }
                    for degrees in stride(from: -90, through: 90, by: 30) {
                        let angle = Double(degrees) * .pi / 180.0
                        let end = mapping.screenPoint(for: SimulationPoint(x: sin(angle) * model.fieldDepthMeters * 100.0, y: cos(angle) * model.fieldDepthMeters * 100.0))
                        var spoke = Path()
                        spoke.move(to: center)
                        spoke.addLine(to: CGPoint(x: end.x, y: end.y))
                        context.stroke(spoke, with: .color(PlanariumPalette.gridColor), lineWidth: 0.8)
                    }
                    context.fill(Path(ellipseIn: CGRect(x: scanner.x - 9, y: scanner.y - 5, width: 18, height: 10)), with: .color(PlanariumPalette.amberColor))
                    for point in model.profile(for: size) { context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(PlanariumPalette.amberBrightColor)) }
                }
                ForEach(Array(model.hands.enumerated()), id: \.offset) { _, hand in
                    let point = mapping.screenPoint(for: hand.center)
                    Circle().stroke(PlanariumPalette.amberColor, lineWidth: 2).frame(width: hand.radiusCm * mapping.scale * 2, height: hand.radiusCm * mapping.scale * 2).position(x: point.x, y: point.y)
                }
                TouchCaptureView(mapping: mapping, maximumY: mapping.scannerScreenPoint.y, radiusCm: model.handDiameterMeters * 50) { model.setHands($0) }
            }
        }
        .background(PlanariumPalette.canvasColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
