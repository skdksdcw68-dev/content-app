import SwiftUI

/// What this connection can and cannot actually do, asked just now.
///
/// Abel, 24 Sep 2026: "I want it to actually hit every single endpoint... and
/// if that's not possible, tell a corrected and a verified answer that it
/// cannot hit the endpoint where it's supposed to hit, and when it can hit,
/// and when it can't."
///
/// So every row here is a round trip, not a stored flag: the session, the tool
/// list, each model list one kind at a time, the balance. A step that answered
/// but returned nothing says so in those words, because that is the failure
/// that took the whole product down and reported itself as "connected".
///
/// Nothing on this screen generates anything, so it can be run as often as
/// somebody likes and can never cost a credit. The button says so.
struct ConnectionCheckView: View {
    let connectionID: UUID?
    let title: String

    @Environment(AppSession.self) private var session
    @State private var report: ConnectionReport?
    @State private var running = false

    var body: some View {
        Form {
            if let report {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: report.canMakeVideo ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(report.canMakeVideo ? Color.green : Color.orange)
                        Text(report.summary)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                Section("What was tried") {
                    ForEach(report.steps) { step in
                        StepRow(step: step)
                    }
                } footer: {
                    Text("Each line is a request made when you tapped the button, with how long it took. Nothing here is remembered from last time.")
                }

                if !report.models.isEmpty {
                    Section("Models it offered") {
                        ForEach(report.models.sorted(by: { $0.key < $1.key }), id: \.key) { kind, count in
                            SettingsRow(kind.capitalized, symbol: symbol(for: kind), value: "\(count)")
                        }
                    }
                }

                Section("The connection") {
                    SettingsRow("Provider", symbol: "shippingbox", value: report.provider)
                    if let family = report.family, family != report.provider {
                        SettingsRow("Read as", symbol: "arrow.triangle.branch", value: family)
                    }
                    if let endpoint = report.endpoint, !endpoint.isEmpty {
                        SettingsRow("Address", symbol: "link", value: endpoint)
                    }
                }
            } else if running {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Asking the provider…").font(.subheadline)
                    }
                }
            } else {
                Section {
                    Text("This opens a session with the provider, lists its tools, asks for every model list it has, and reads your balance. It makes nothing, so it cannot cost you anything.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button {
                    Task { await run() }
                } label: {
                    Text(report == nil ? "Run the check" : "Run it again")
                        .frame(maxWidth: .infinity)
                }
                .disabled(running)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if report == nil { await run() } }
    }

    private func run() async {
        running = true
        defer { running = false }
        report = await session.checkConnection(connectionID)
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "video": "film"
        case "image": "photo"
        case "audio": "waveform"
        default: "square.grid.2x2"
        }
    }
}

private struct StepRow: View {
    let step: ConnectionStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: step.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.body)
                .foregroundStyle(step.ok ? Color.green : Color.red)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(step.step)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if step.ms > 0 {
                        Text("\(step.ms) ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(step.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
