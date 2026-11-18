@testable import PlanariumPresets
import PlanariumDomain

// Die beiden **internen Prozessor-Inserts** des Kanalzugs (SICK-033a-2):
// Delay und Hall, getrennt voneinander, je mit Ein/Aus, Sendpegel und
// eigenen Klangwerten.
//
// **Ein/Aus ist Parameteraktivierung, keine Graphmutation.** Ein
// ausgeschalteter Insert setzt seinen Sendpegel auf `0` und nimmt sich
// aus der Scannersteuerung heraus (das zugehörige Maximum der
// `LegacyMappingConfiguration` wird `0`); die Knoten bleiben im Graphen,
// wie `AudioOutputHost.prepare` sie **immer** aufbaut. Beim Spielen wird
// nichts angefügt, entfernt oder umverdrahtet.
//
// Beide Typen sind reine Werte mit validierender Fabrik; aus ihnen
// **leiten** Controller und Adapter `EffectParameters` und die beiden
// Sendmaxima ab -- eine Wahrheit, zwei Ableitungen.

/// Der Delay-Insert.
public struct DelayInsert: Equatable, Sendable {
    public enum BuildError: Error, Equatable {
        case sendLevelOutOfRange(Double)
        case timeOutOfRange(Float)
        case feedbackOutOfRange(Float)
    }

    public let isEnabled: Bool
    /// Sendpegel `0...1` bei vollem Steuerwert -- und zugleich der
    /// feste Sendpegel, wenn keine Effekt-Zone zugewiesen ist.
    public let sendLevel: Double
    public let timeSeconds: Float
    public let feedbackPercent: Float

    private init(isEnabled: Bool, sendLevel: Double, timeSeconds: Float, feedbackPercent: Float) {
        self.isEnabled = isEnabled
        self.sendLevel = sendLevel
        self.timeSeconds = timeSeconds
        self.feedbackPercent = feedbackPercent
    }

    /// Der Startwert: **aus**, mit den neutralen Klangwerten des
    /// Effektsatzes und dem Sendmaximum des musikalischen Startpunkts.
    public static let startingPoint = DelayInsert(
        isEnabled: false,
        sendLevel: LegacyMappingConfiguration.musicalStartingPoint.maximumDelaySend,
        timeSeconds: EffectParameters.neutral.delayTimeSeconds,
        feedbackPercent: EffectParameters.neutral.delayFeedbackPercent
    )

    public static func build(
        isEnabled: Bool,
        sendLevel: Double,
        timeSeconds: Float,
        feedbackPercent: Float
    ) throws -> DelayInsert {
        guard sendLevel.isFinite, sendLevel >= 0, sendLevel <= 1 else {
            throw BuildError.sendLevelOutOfRange(sendLevel)
        }
        guard timeSeconds.isFinite, EffectParameters.delayTimeRange.contains(timeSeconds) else {
            throw BuildError.timeOutOfRange(timeSeconds)
        }
        guard feedbackPercent.isFinite, EffectParameters.delayFeedbackRange.contains(feedbackPercent) else {
            throw BuildError.feedbackOutOfRange(feedbackPercent)
        }
        return DelayInsert(
            isEnabled: isEnabled, sendLevel: sendLevel, timeSeconds: timeSeconds, feedbackPercent: feedbackPercent
        )
    }

    /// Der wirksame Sendpegel: `0`, solange der Insert aus ist.
    public var effectiveSendLevel: Double { isEnabled ? sendLevel : 0 }

    public func toggled(_ enabled: Bool) -> DelayInsert {
        DelayInsert(isEnabled: enabled, sendLevel: sendLevel, timeSeconds: timeSeconds, feedbackPercent: feedbackPercent)
    }
}

/// Der Hall-Insert.
public struct ReverbInsert: Equatable, Sendable {
    public enum BuildError: Error, Equatable {
        case sendLevelOutOfRange(Double)
    }

    public let isEnabled: Bool
    public let sendLevel: Double
    public let character: ReverbCharacter

    private init(isEnabled: Bool, sendLevel: Double, character: ReverbCharacter) {
        self.isEnabled = isEnabled
        self.sendLevel = sendLevel
        self.character = character
    }

    public static let startingPoint = ReverbInsert(
        isEnabled: false,
        sendLevel: LegacyMappingConfiguration.musicalStartingPoint.maximumReverbSend,
        character: EffectParameters.neutral.reverbCharacter
    )

    public static func build(isEnabled: Bool, sendLevel: Double, character: ReverbCharacter) throws -> ReverbInsert {
        guard sendLevel.isFinite, sendLevel >= 0, sendLevel <= 1 else {
            throw BuildError.sendLevelOutOfRange(sendLevel)
        }
        return ReverbInsert(isEnabled: isEnabled, sendLevel: sendLevel, character: character)
    }

    public var effectiveSendLevel: Double { isEnabled ? sendLevel : 0 }

    public func toggled(_ enabled: Bool) -> ReverbInsert {
        ReverbInsert(isEnabled: enabled, sendLevel: sendLevel, character: character)
    }
}

extension EffectParameters {
    /// Die Effektwerte, die aus beiden Inserts folgen. Kann strukturell
    /// nicht fehlschlagen: Jeder Wert stammt aus einem validierten
    /// Insert und liegt in den Bereichen von ``EffectParameters/build``.
    public static func derived(from delay: DelayInsert, reverb: ReverbInsert) -> EffectParameters {
        // Die Bereiche sind identisch geprüft; ein Fehlschlag wäre ein
        // Vertragsbruch eines Insert-Typs und würde hier nicht still
        // verschwinden, sondern den Prozess beenden.
        try! EffectParameters.build(
            delaySend: Float(delay.effectiveSendLevel),
            delayTimeSeconds: delay.timeSeconds,
            delayFeedbackPercent: delay.feedbackPercent,
            reverbSend: Float(reverb.effectiveSendLevel),
            reverbCharacter: reverb.character
        )
    }
}

