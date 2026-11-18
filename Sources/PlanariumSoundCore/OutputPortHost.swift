import Foundation

/// Where sound hosts (Audio Unit strips, CoreMIDI outputs) bind and retire their
/// output ports. The performance runtime implements it; the sound modules never
/// see an input source, a scanner or a document.
public protocol OutputPortHost: AnyObject, Sendable {
    func attach(_ port: OutputPort)
    func retire(_ id: UUID, ack: @escaping @Sendable () -> Void)
    /// Releases sounding audio notes before the audio configuration changes.
    func releaseAudioForConfigurationChange()
}
