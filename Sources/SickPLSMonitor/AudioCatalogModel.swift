import Combine
import Foundation
import PlanariumApplication
import PlanariumAudio
import PlanariumDomain
import PlanariumPresets

/// Catalog metadata and explicit strip parameter lookup. Owns no AU or editor.
@MainActor final class AudioCatalogModel: ObservableObject {
    let document: SpatialInstrumentRuntimeModel
    let host: AudioHost
    private let catalog: AudioUnitEffectCatalog
    private var observations: [AnyCancellable] = []
    init(document: SpatialInstrumentRuntimeModel, source: any AudioUnitComponentSource) {
        self.document = document; host = document.audio; catalog = AudioUnitEffectCatalog(source: source)
        observations = [document.$document.map(\.channels).removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() },
                        host.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }]
    }
    var availableEffects: [AudioUnitEffectCandidate] { catalog.availableEffects() }
    var availableInstruments: [AudioUnitInstrumentCandidate] { catalog.availableInstruments() }
    func parameters(for id: UUID) -> [AudioUnitParameterDescriptor] {
        return host.host(for: id)?.instrument?.parameters ?? []
    }
}

enum AudioUnitInstrumentPreparationState: Equatable {
    case empty, selected(AudioUnitInstrumentIdentity), preparing(AudioUnitInstrumentIdentity), prepared(AudioUnitInstrumentIdentity), failed(AudioUnitInstrumentIdentity)
}
