import Foundation

/// A provider key somebody typed into the chat.
///
/// Abel, 24 Sep 2026: "they can just generate a key and paste it on the chat.
/// When the AI knows it's an API key, it will automatically change it to a hash
/// number -- hide some of the numbers on the UI -- and save it as their own key
/// to generate."
///
/// 🔴 The important half is what does NOT happen. A pasted key is caught before
/// the message is sent, so it never reaches the model, never lands in the
/// conversation on the server, and never sits in a transcript that gets read
/// back into a later prompt. It goes straight to `connect-generator`, which
/// verifies it against the provider and seals it. What stays on screen is the
/// masked form, which is all anybody needs to recognise which key they pasted.
struct PastedKey: Equatable {
    /// Everything before the key, if they wrote a sentence around it.
    let preamble: String
    let id: String
    let secret: String

    /// Four characters at each end, the rest hidden: enough to recognise, not
    /// enough to use.
    static func masked(_ value: String) -> String {
        guard value.count > 12 else { return String(repeating: "•", count: max(value.count, 8)) }
        return "\(value.prefix(4))\(String(repeating: "•", count: 8))\(value.suffix(4))"
    }

    var maskedSecret: String { Self.masked(secret) }

    /// Reads a message that might carry a key.
    ///
    /// Higgsfield issues a pair -- an id and a secret -- so both shapes are
    /// looked for: two long opaque tokens, or one labelled `id:secret`. A
    /// single long token is taken as the secret with no id, which the server
    /// rejects honestly rather than storing something that cannot work.
    static func find(in text: String) -> PastedKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return nil }

        // A run of key-ish characters: letters, digits, dash, underscore. Long
        // enough that ordinary words and URLs do not qualify.
        let pattern = #"(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{16,120}(?![A-Za-z0-9_\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = regex.matches(in: trimmed, range: range).compactMap { match -> String? in
            guard let r = Range(match.range, in: trimmed) else { return nil }
            return String(trimmed[r])
        }
        // Words are not keys. A real key mixes cases or digits; "understanding"
        // and "congratulations" do not.
        let candidates = matches.filter(looksLikeKey)
        guard let first = candidates.first else { return nil }

        // Where the key starts, so anything they wrote before it is kept.
        let preamble = trimmed.range(of: first).map {
            String(trimmed[trimmed.startIndex..<$0.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""

        if candidates.count >= 2 {
            return PastedKey(preamble: preamble, id: first, secret: candidates[1])
        }
        // `id:secret` on one line.
        if let colon = first.firstIndex(of: ":"), colon != first.startIndex {
            return PastedKey(
                preamble: preamble,
                id: String(first[first.startIndex..<colon]),
                secret: String(first[first.index(after: colon)...])
            )
        }
        return PastedKey(preamble: preamble, id: "", secret: first)
    }

    /// Long, opaque, and not an English word.
    private static func looksLikeKey(_ value: String) -> Bool {
        guard value.count >= 16 else { return false }
        let digits = value.contains { $0.isNumber }
        let upper = value.contains { $0.isUppercase }
        let lower = value.contains { $0.isLowercase }
        let marks = value.contains("_") || value.contains("-")
        // Two of: has digits, mixes case, carries separators. A long lowercase
        // word passes none of them.
        let signals = [digits, upper && lower, marks].filter { $0 }.count
        return signals >= 2
    }
}
