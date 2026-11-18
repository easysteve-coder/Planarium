import Foundation
@preconcurrency import GameController
import PlanariumControllerCore
import PlanariumMusicCore

/// The one owner of the game controller device (PS5 DualSense first, any
/// extended gamepad works). Exactly one controller is the source at a time;
/// it is identified by its object, so a second pad or its disconnect never
/// replaces or resets the first. Every report becomes one complete state on
/// one serial queue, in order, without coalescing button edges.
public final class GameControllerSource: @unchecked Sendable {
    public typealias Receive = @Sendable (ControllerInputEvent) -> Void

    private let queue = DispatchQueue(label: "de.planarium.controller-input", qos: .userInteractive)
    private let now: @Sendable () -> Double
    private var receive: Receive?
    // Touched only on `queue`.
    private var current: GCController?
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var lightColor: SpatialLayerColor?
    /// An explicit stop ends the source; it never picks a replacement pad.
    private var stopping = false

    /// `now` is the runtime's monotonic clock, so report times share its epoch.
    public init(now: @escaping @Sendable () -> Double) { self.now = now }

    /// Starts listening; already connected controllers are picked up at once.
    public func start(_ receive: @escaping Receive) {
        queue.async { [weak self] in
            guard let self else { return }
            self.removeObservers()
            self.stopping = false
            self.receive = receive
            GCController.shouldMonitorBackgroundEvents = true
            let center = NotificationCenter.default
            self.observers = [
                center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: nil) { [weak self] note in
                    guard let controller = note.object as? GCController, let source = self else { return }
                    source.queue.async { [weak source] in source?.connect(controller) }
                },
                center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: nil) { [weak self] note in
                    guard let controller = note.object as? GCController, let source = self else { return }
                    source.queue.async { [weak source] in source?.disconnect(controller) }
                },
            ]
            for controller in GCController.controllers() { self.connect(controller) }
        }
    }

    /// Stops listening and reports the end of a running session.
    public func stop() {
        queue.sync {
            stopping = true
            removeObservers()
            if let current { disconnect(current) }
            receive = nil
        }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Shows a color on the controller's light bar (the active scene or the
    /// played assignment); nil returns it to white.
    public func setLight(_ color: SpatialLayerColor?) {
        queue.async {
            self.lightColor = color
            self.applyLight()
        }
    }

    // MARK: Device

    private func connect(_ controller: GCController) {
        guard current == nil, controller.extendedGamepad != nil else { return }
        current = controller
        let id = UUID()
        session = id; sequence = 0
        controller.handlerQueue = queue
        receive?(.connected(session: id, name: controller.vendorName ?? "Game controller"))
        controller.extendedGamepad?.valueChangedHandler = { [weak self, weak controller] gamepad, _ in
            // Already on `queue` (handlerQueue): one complete state per report.
            guard let controller else { return }
            self?.report(gamepad, of: controller)
        }
        if let pad = controller.physicalInputProfile as? GCDualSenseGamepad {
            pad.touchpadPrimary.valueChangedHandler = { [weak self, weak controller] _, _, _ in
                guard let controller, let gamepad = controller.extendedGamepad else { return }
                self?.report(gamepad, of: controller)
            }
        }
        applyLight()
        report(controller.extendedGamepad!, of: controller)
    }

    private func disconnect(_ controller: GCController) {
        guard controller === current, let id = session else { return }
        controller.extendedGamepad?.valueChangedHandler = nil
        (controller.physicalInputProfile as? GCDualSenseGamepad)?.touchpadPrimary.valueChangedHandler = nil
        current = nil; session = nil
        receive?(.disconnected(session: id))
        // On hot-unplug a remaining controller may take over; never on stop.
        guard !stopping else { return }
        if let next = GCController.controllers().first(where: { $0 !== controller && $0.extendedGamepad != nil }) { connect(next) }
    }

    private func report(_ gamepad: GCExtendedGamepad, of controller: GCController) {
        guard controller === current, let id = session else { return }
        sequence += 1
        receive?(.state(session: id, sequence: sequence, time: now(), Self.state(of: gamepad, controller: controller)))
    }

    private func applyLight() {
        guard let light = current?.light else { return }
        let c = lightColor ?? SpatialLayerColor(red: 1, green: 1, blue: 1)
        light.color = GCColor(red: Float(c.red), green: Float(c.green), blue: Float(c.blue))
    }

    /// Reads one complete, normalized state. Pressed means the element's own
    /// pressed flag; triggers keep their analog travel.
    static func state(of gamepad: GCExtendedGamepad, controller: GCController) -> ControllerState {
        var pressed = Set<ControllerElement>()
        func button(_ input: GCControllerButtonInput?, _ element: ControllerElement) {
            if input?.isPressed == true { pressed.insert(element) }
        }
        button(gamepad.buttonA, .cross); button(gamepad.buttonB, .circle)
        button(gamepad.buttonX, .square); button(gamepad.buttonY, .triangle)
        button(gamepad.dpad.up, .dpadUp); button(gamepad.dpad.down, .dpadDown)
        button(gamepad.dpad.left, .dpadLeft); button(gamepad.dpad.right, .dpadRight)
        button(gamepad.leftShoulder, .l1); button(gamepad.rightShoulder, .r1)
        button(gamepad.leftThumbstickButton, .l3); button(gamepad.rightThumbstickButton, .r3)
        button(gamepad.buttonMenu, .options); button(gamepad.buttonOptions, .create)
        button(gamepad.buttonHome, .home)
        var positions: [ControllerElement: ControllerPoint] = [
            .leftStick: .init(x: Double(gamepad.leftThumbstick.xAxis.value), y: Double(gamepad.leftThumbstick.yAxis.value)),
            .rightStick: .init(x: Double(gamepad.rightThumbstick.xAxis.value), y: Double(gamepad.rightThumbstick.yAxis.value)),
        ]
        if let pad = controller.physicalInputProfile as? GCDualSenseGamepad {
            button(pad.touchpadButton, .touchpadButton)
            let x = Double(pad.touchpadPrimary.xAxis.value), y = Double(pad.touchpadPrimary.yAxis.value)
            // The DualSense reports exactly 0/0 without a finger.
            if x != 0 || y != 0 { positions[.touchpad] = .init(x: x, y: y) }
        }
        return ControllerState(pressed: pressed,
                               values: [.l2: Double(gamepad.leftTrigger.value), .r2: Double(gamepad.rightTrigger.value)],
                               positions: positions)
    }
}
