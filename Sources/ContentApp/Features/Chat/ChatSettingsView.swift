import SwiftUI

/// How long a reply should be: the first thing Chat settings asks.
enum ReplyLength: String, CaseIterable, Identifiable, Sendable {
    case short = "Short"
    case balanced = "Balanced"
    case detailed = "Detailed"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .short: return "Quick answers, straight to the point"
        case .balanced: return "Enough detail to act on"
        case .detailed: return "Reasons, evidence and next steps. Takes longer."
        }
    }
}

/// What the taps on Chat settings say, and how they sit in the one text the
/// model already reads before every reply.
///
/// The taps are written as a first line in plain words ("Reply length: Short.
/// No hashtags."), and the owner's own words follow on the lines below. Nothing
/// new is stored and the server does not change: the line is read like any
/// other instruction, and this type reads it back so the screen can show the
/// taps again.
struct ChatPreferences: Equatable, Sendable {
    var length: ReplyLength = .balanced
    var noHashtags = false
    var plainWords = false

    private static let lead = "Reply length: "
    private static let hashtags = "No hashtags"
    private static let plain = "Plain words"

    /// The first line, or nil when every tap is at its default.
    var line: String? {
        guard self != ChatPreferences() else { return nil }
        var parts: [String] = [length.rawValue]
        if noHashtags { parts.append(Self.hashtags) }
        if plainWords { parts.append(Self.plain) }
        return Self.lead + parts.joined(separator: ". ") + "."
    }

    /// The taps and the owner's words as the one text that is saved.
    static func compose(_ preferences: ChatPreferences, own: String) -> String {
        let words = own.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = preferences.line else { return words }
        return words.isEmpty ? line : line + "\n" + words
    }

    /// The saved text, taken apart again.
    static func parse(_ saved: String) -> (preferences: ChatPreferences, own: String) {
        let text = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix(lead) else {
            return (ChatPreferences(), text)
        }
        let body = String(first.dropFirst(lead.count))
        let parts = body
            .components(separatedBy: ".")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var preferences = ChatPreferences()
        if let word = parts.first, let length = ReplyLength(rawValue: word) {
            preferences.length = length
        }
        preferences.noHashtags = parts.contains(hashtags)
        preferences.plainWords = parts.contains(plain)
        let own = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (preferences, own)
    }
}

