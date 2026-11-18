import SwiftUI
import UIKit
import SickPLSSimulationLink

struct TouchCaptureView: UIViewRepresentable {
    let mapping: FieldScreenMapping
    let maximumY: CGFloat
    let radiusCm: Double
    let onHandsChanged: ([SimulationHand]) -> Void
    func makeUIView(context: Context) -> TouchView { let view = TouchView(); view.isMultipleTouchEnabled = true; view.onTouchesChanged = onHandsChanged; view.mapping = mapping; view.maximumY = maximumY; view.radiusCm = radiusCm; return view }
    func updateUIView(_ view: TouchView, context: Context) { view.mapping = mapping; view.maximumY = maximumY; view.radiusCm = radiusCm }
}

final class TouchView: UIView {
    var mapping = FieldScreenMapping(fieldWidthCm: 200, fieldDepthCm: 200, viewWidth: 1, viewHeight: 1)
    var maximumY = CGFloat.greatestFiniteMagnitude
    var radiusCm = 4.5
    var onTouchesChanged: (([SimulationHand]) -> Void)?
    private var positions: [ObjectIdentifier: CGPoint] = [:]
    private var ignored: Set<ObjectIdentifier> = []
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.location(in: self).y > maximumY { ignored.insert(ObjectIdentifier(touch)) }
        update(touches)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { remove(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { remove(touches) }
    private func update(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard !ignored.contains(id) else { continue }
            let location = touch.location(in: self)
            if location.y <= maximumY { positions[id] = location } else { positions.removeValue(forKey: id) }
        }
        publish()
    }
    private func remove(_ touches: Set<UITouch>) { for touch in touches { let id = ObjectIdentifier(touch); positions.removeValue(forKey: id); ignored.remove(id) }; publish() }
    private func publish() { onTouchesChanged?(positions.values.map { let point = mapping.fieldPoint(for: ScreenPoint(x: Double($0.x), y: Double($0.y))); return SimulationHand(center: point, radiusCm: radiusCm) }) }
}
