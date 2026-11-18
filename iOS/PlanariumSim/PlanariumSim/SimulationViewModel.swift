import Foundation
import Network
import SwiftUI
import UIKit
import SickPLSDeviceModel
import SickPLSSimulationBroadcast
import SickPLSSimulationLink

final class SimulationViewModel: ObservableObject {
    @Published var hands: [SimulationHand] = []
    @Published private(set) var sentValues: [UInt16] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false
    @Published private(set) var deviceMode: VirtualPLSMode = .idle
    @Published var deviceModeText: String = "Bereit"
    @Published private(set) var droppedCount = 0
    @Published var fieldWidthMeters = 2.0 { didSet { recompute() } }
    @Published var fieldDepthMeters = 2.0 { didSet { recompute() } }
    @Published var pointCount = 361 { didSet { recompute() } }
    @Published var sampling = ProfileSampling.singleRay { didSet { recompute() } }
    @Published var handDiameterMeters = 0.09 { didSet { recompute() } }
    @Published var noiseEnabled = false { didSet { recompute() } }
    @Published var roomBackground: Bool { didSet { defaults.set(roomBackground, forKey: Self.roomBackgroundDefaultsKey); recompute() } }

    private static let roomBackgroundDefaultsKey = "PlanariumSim.roomBackground"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var rng = SplitMix64(seed: 0x504C_414E_4152_4955)
    private var broadcaster: SimulationBroadcaster?
    private var displayTimer: Timer?
    private var serviceName: String
    private var currentValues: [UInt16] = []
    /// Unattended supervisor runs: hands follow `AutoSweepPath` instead of touch.
    private let autoSweepStart: Date? = CommandLine.arguments.contains("-PlanariumAutoSweep") ? Date() : nil

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        roomBackground = defaults.object(forKey: Self.roomBackgroundDefaultsKey) as? Bool ?? true
        if let saved = defaults.string(forKey: "PlanariumSim.serviceName") {
            serviceName = saved
        } else {
            #if targetEnvironment(simulator)
            let deviceKind = "Simulator"
            #else
            let deviceKind = "iPhone"
            #endif
            serviceName = "Planarium-Sim-\(String(format: "%04X", UInt16.random(in: 0...UInt16.max))) · \(deviceKind)"
            defaults.set(serviceName, forKey: "PlanariumSim.serviceName")
        }
        if CommandLine.arguments.contains("-demoHands") {
            hands = [
                SimulationHand(x: -35, y: 95, radiusCm: 4.5),
                SimulationHand(x: 38, y: 135, radiusCm: 4.5)
            ]
        }
        #if DEBUG
        if CommandLine.arguments.contains("-demoWideField") {
            fieldWidthMeters = 3.8
            fieldDepthMeters = 1.9
        }
        #endif
        recompute()
    }

    var serviceNameForDisplay: String { serviceName }

    func startIfNeeded() {
        guard !isRunning else { return }
        let service = NWListener.Service(name: serviceName, type: SimulationLinkConstants.bonjourServiceType)
        broadcaster = SimulationBroadcaster(service: service, profileProvider: { [weak self] in
            self?.nextProfile() ?? []
        })
        broadcaster?.connectionStateHandler = { [weak self] connected in
            self?.isConnected = connected
            self?.updateDisplayTicker()
        }
        broadcaster?.deviceModeHandler = { [weak self] mode in
            self?.deviceMode = mode
            self?.deviceModeText = Self.deviceModeText(for: mode)
            self?.updateDisplayTicker()
        }
        broadcaster?.start()
        isRunning = true
        updateDisplayTicker()
    }

    func toggleSending() {
        if isRunning {
            stop()
        } else {
            startIfNeeded()
        }
    }

    func stop() {
        stopDisplayTicker()
        broadcaster?.stop()
        broadcaster = nil
        isRunning = false
        isConnected = false
        deviceMode = .idle
        deviceModeText = "Bereit"
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .active {
            startIfNeeded()
        } else if phase == .background {
            stop()
        }
        UIApplication.shared.isIdleTimerDisabled = phase == .active
    }

    func setHands(_ newHands: [SimulationHand]) {
        hands = newHands
        recompute()
    }

    func profile(for size: CGSize) -> [ScreenPoint] {
        let mapping = FieldScreenMapping(fieldWidthCm: fieldWidthMeters * 100, fieldDepthCm: fieldDepthMeters * 100, viewWidth: Double(size.width), viewHeight: Double(size.height))
        return sentValues.enumerated().compactMap { index, value in
            guard value < 8191, pointCount > 1 else { return nil }
            let angle = (-90 + 180 * Double(index) / Double(pointCount - 1)) * .pi / 180
            return mapping.screenPoint(for: SimulationPoint(x: sin(angle) * Double(value), y: cos(angle) * Double(value)))
        }
    }

    var statusText: String {
        guard isRunning else { return "Senden aus" }
        if isConnected { return "Mac verbunden · 25 Hz · \(pointCount) Punkte" }
        return "Wartet auf Mac · 25 Hz · \(pointCount) Punkte"
    }

    static func needsDisplayTick(
        isRunning: Bool,
        isConnected: Bool,
        mode: VirtualPLSMode
    ) -> Bool {
        isRunning && (!isConnected || mode == .minimumPerSegmentRequested)
    }

    static func deviceModeText(for mode: VirtualPLSMode) -> String {
        switch mode {
        case .idle:
            return "Bereit"
        case .fullScan:
            return "Alle Messwerte kontinuierlich"
        case .minimumPerSegmentRequested:
            return "Messwerte min. kontinuierlich – nicht nachgebildet, sendet keine Profile"
        }
    }

    private func recompute() {
        lock.lock()
        let config = SimulationConfiguration(pointCount: pointCount, background: roomBackground ? .room(widthCm: fieldWidthMeters * 100, depthCm: fieldDepthMeters * 100) : .rangeEnd, sampling: sampling, noiseEnabled: noiseEnabled)
        currentValues = SimulatedScanner.profileValues(hands: hands, configuration: config, rng: &rng)
        let values = currentValues
        lock.unlock()
        sentValues = values
    }

    private func nextProfile() -> [UInt16] {
        let sweptHands = autoSweepStart.map { AutoSweepPath.hands(at: Date().timeIntervalSince($0)) }
        lock.lock()
        let config = SimulationConfiguration(pointCount: pointCount, background: roomBackground ? .room(widthCm: fieldWidthMeters * 100, depthCm: fieldDepthMeters * 100) : .rangeEnd, sampling: sampling, noiseEnabled: noiseEnabled)
        let values = SimulatedScanner.profileValues(hands: sweptHands ?? hands, configuration: config, rng: &rng)
        currentValues = values
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            if let sweptHands { self?.hands = sweptHands }
            self?.sentValues = values; self?.droppedCount = self?.broadcaster?.droppedProfileCount ?? 0
        }
        return values
    }

    private func updateDisplayTicker() {
        guard Self.needsDisplayTick(isRunning: isRunning, isConnected: isConnected, mode: deviceMode) else {
            stopDisplayTicker()
            return
        }
        guard displayTimer == nil else { return }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self,
                  Self.needsDisplayTick(isRunning: self.isRunning, isConnected: self.isConnected, mode: self.deviceMode)
            else { return }
            self.recompute()
        }
    }

    private func stopDisplayTicker() {
        displayTimer?.invalidate()
        displayTimer = nil
    }
}
