import Foundation
import SickPLSActiveControl
import SickPLSCore

enum HexTelegramInputError: Error, Equatable {
    case empty
    case invalidToken(String)
    case notACompleteFrame
    case wrongTargetAddress(UInt8)
}

enum HexTelegramInput {
    /// Liest eine vollständige, CRC-gültige Drahtdarstellung. Die freie
    /// Konsole bleibt damit wirklich eine Telegrammkonsole und wird nicht
    /// zu einem beliebigen Byte-Sender. Die Scanner→Host-Adresse 0x81
    /// bleibt als Sendeziel strukturell ausgeschlossen.
    static func parse(_ text: String) -> Result<[UInt8], HexTelegramInputError> {
        let tokens = text
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return .failure(.empty) }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(tokens.count)
        for tokenSlice in tokens {
            let original = String(tokenSlice)
            let token = original.lowercased().hasPrefix("0x")
                ? String(original.dropFirst(2)) : original
            guard token.count == 2, let byte = UInt8(token, radix: 16) else {
                return .failure(.invalidToken(original))
            }
            bytes.append(byte)
        }

        guard case .success(let frame) = Frame.decodeExact(from: bytes) else {
            return .failure(.notACompleteFrame)
        }
        guard ConfirmedTargetAddress(rawValue: frame.address) != nil else {
            return .failure(.wrongTargetAddress(frame.address))
        }
        return .success(bytes)
    }
}

enum TargetAddressInput {
    static func parse(_ text: String) -> ConfirmedTargetAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.lowercased().hasPrefix("0x")
            ? String(trimmed.dropFirst(2)) : trimmed
        guard (1...2).contains(digits.count), let raw = UInt8(digits, radix: 16) else {
            return nil
        }
        return ConfirmedTargetAddress(rawValue: raw)
    }
}
