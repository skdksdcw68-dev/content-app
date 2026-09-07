import Foundation

/// A generator the person pays for, as the app is allowed to see it.
///
/// Never the key. `my_generators()` returns the fact that a credential exists,
/// when it was last checked and whether it worked -- deliberately not enough to
/// reconstruct anything. The secret is sealed in a schema PostgREST cannot
/// reach and is only ever opened inside an Edge Function.
struct Generator: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let provider: String
    let label: String
    let lastProbeAt: Date?
    /// Nil means never tried, which should not happen -- connecting probes
    /// before it stores. False means it worked once and has since stopped.
    let lastProbeOK: Bool?
    let lastProbeDetail: String?

    enum CodingKeys: String, CodingKey {
        case id, provider, label
        case lastProbeAt = "last_probe_at"
        case lastProbeOK = "last_probe_ok"
        case lastProbeDetail = "last_probe_detail"
    }

    var name: String {
        if !label.isEmpty { return label }
        switch provider {
        case "higgsfield": return "Higgsfield"
        default:           return provider.capitalized
        }
    }

    var isWorking: Bool { lastProbeOK == true }

    /// What to say about it on one line.
    var statusLine: String {
        guard let lastProbeOK else { return "Not checked yet" }
        if lastProbeOK {
            guard let lastProbeAt else { return "Working" }
            return "Working — checked \(Self.relative.localizedString(for: lastProbeAt, relativeTo: .now))"
        }
        return lastProbeDetail ?? "That key stopped working"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
