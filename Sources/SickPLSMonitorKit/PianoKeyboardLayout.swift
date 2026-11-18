import CoreGraphics

/// Gemeinsame Geometrie und Trefferordnung aller Klaviaturen.
public enum PianoKeyboardLayout {
    public struct Key: Equatable, Sendable {
        public let note: Int
        public let isBlack: Bool
        public let frame: CGRect

        public init(note: Int, isBlack: Bool, frame: CGRect) {
            self.note = note
            self.isBlack = isBlack
            self.frame = frame
        }
    }

    public static func layout(for notes: [Int], width: CGFloat, height: CGFloat) -> [Key] {
        let whiteNotes = notes.filter { !PianoKeyboardModel.isBlackKey($0) }
        guard !whiteNotes.isEmpty, width > 0, height > 0 else { return [] }

        let whiteWidth = width / CGFloat(whiteNotes.count)
        let whites = whiteNotes.enumerated().map { index, note in
            Key(
                note: note,
                isBlack: false,
                frame: CGRect(x: CGFloat(index) * whiteWidth, y: 0,
                              width: whiteWidth, height: height)
            )
        }
        let blackHeight = height * 0.62
        let blackWidth = whiteWidth * 0.6
        let blacks = notes.filter(PianoKeyboardModel.isBlackKey).compactMap { note -> Key? in
            let precedingWhites = whiteNotes.filter { $0 < note }.count
            let offset: CGFloat
            switch note % 12 {
            case 1, 6: offset = -0.08
            case 3, 10: offset = 0.08
            default: offset = 0
            }
            let boundary = (CGFloat(precedingWhites) + offset) * whiteWidth
            return Key(
                note: note,
                isBlack: true,
                frame: CGRect(x: boundary - blackWidth / 2, y: 0,
                              width: blackWidth, height: blackHeight)
            )
        }
        return whites + blacks
    }

    /// Schwarze Tasten haben Vorrang an gemeinsamen Grenzen; darunter liegt
    /// die lückenlose weiße Tastenteilung.
    public static func hitTest(keys: [Key], point: CGPoint) -> Int? {
        keys.filter(\.isBlack).first { $0.frame.contains(point) }?.note
            ?? keys.first { !$0.isBlack && $0.frame.contains(point) }?.note
    }
}
