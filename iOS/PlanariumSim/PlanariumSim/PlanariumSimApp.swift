import SwiftUI

@main
struct PlanariumSimApp: App {
    @StateObject private var model = SimulationViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SimulationView(model: model)
                .onChange(of: scenePhase) { phase in
                    model.scenePhaseChanged(phase)
                }
                .onAppear { model.startIfNeeded() }
        }
    }
}
