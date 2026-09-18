import SwiftUI

/// The AI video generators you make things with, and the switch that lets
/// Autopilot use them. Moved off the main Profile list, unchanged in what it
/// does: sign in to the generator you already pay for, see what it offers,
/// disconnect it.
struct GeneratorsView: View {
    @Environment(AppSession.self) private var session

    /// Pasted keys that are not already shown as a connection.
    private var unbridgedGenerators: [Generator] {
        session.generators.filter { generator in
            !session.connectedProviders.contains { $0.id == generator.id }
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(session.connectedProviders) { provider in
                    ProviderRow(provider: provider)
                }

                // Keys pasted before sign-in existed, and only those not
                // already listed above (0028 bridged each key into a
                // connection with the same id).
                ForEach(unbridgedGenerators) { generator in
                    GeneratorRow(generator: generator) {
                        Task { await session.forgetGenerator(generator.id) }
                    }
                }

                if session.connectedProviders.isEmpty && unbridgedGenerators.isEmpty {
                    NoGeneratorRow()
                }

                ForEach(session.connectable) { provider in
                    Button {
                        Task { await session.connectProvider(provider.slug) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.action)
                                Text(provider.how)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                    }
                    .disabled(session.isWorking)
                }
            } footer: {
                Text("Sign in to the generator you already pay for. Autocast never sees or stores your password, and you are billed by them, not by us.")
            }

            Section {
                Toggle("Make videos with AI", isOn: Binding(
                    get: { session.settings?.isOn ?? false },
                    set: { on in Task { await session.setAutopilot(on) } }
                ))
                .disabled(session.settings == nil || !session.hasWorkingGenerator)

                if let settings = session.settings, settings.isOn {
                    LabeledContent("Made") {
                        Text("\(settings.renderLeadHours)h before each post")
                    }
                }
            } footer: {
                // Off by default and said out loud: everything this turns on
                // spends money without asking again.
                if !session.hasWorkingGenerator {
                    Text("Connect a generator above and Autocast can start each video a day before its slot, without being asked.")
                } else if session.settings?.isOn == true {
                    Text("Each video is made about a day before its slot and comes back to you for approval. You are billed by your generator. Nothing is posted until you approve it.")
                } else {
                    Text("Turn this on and Autocast starts each video about a day before its slot. It still comes back to you before anything is posted.")
                }
            }
        }
        .navigationTitle("AI generators")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await session.refreshConnectedProviders()
            await session.refreshConnectable()
        }
        .refreshable {
            await session.refreshGenerators()
            await session.refreshConnectedProviders()
            await session.refreshConnectable()
            await session.refreshSettings()
        }
    }
}

/// One connected provider, with its actions in plain sight -- a destructive
/// action that has to be discovered is one that effectively does not exist.
private struct ProviderRow: View {
    let provider: ProviderConnection

    @Environment(AppSession.self) private var session
    @State private var confirmingDisconnect = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.isHealthy ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(provider.isHealthy && provider.modelCount > 0 ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.providerName)
                Text("\(provider.door) · \(provider.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Menu {
                if provider.isHealthy {
                    Button {
                        Task { await session.refreshCapabilities(provider.id) }
                    } label: {
                        Label("Check what it offers", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    Task { await session.connectProvider(provider.providerSlug) }
                } label: {
                    Label(provider.isPastedKey ? "Sign in instead" : "Sign in again", systemImage: "person.crop.circle")
                }
                Divider()
                Button(role: .destructive) {
                    confirmingDisconnect = true
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Options for \(provider.providerName)")
        }
        .swipeActions {
            Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
        }
        .alert("Disconnect \(provider.providerName)?", isPresented: $confirmingDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                Task { await session.disconnect(provider.id) }
            }
        } message: {
            Text(provider.isPastedKey
                 ? "Your pasted key is deleted from Autocast. Nothing changes in your Higgsfield account."
                 : "Autocast stops using this account and forgets its sign-in. You can sign in again any time.")
        }
    }
}

private struct GeneratorRow: View {
    let generator: Generator
    let forget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon("wand.and.stars")
            VStack(alignment: .leading, spacing: 2) {
                Text(generator.name)
                Text(generator.statusLine)
                    .font(.caption)
                    .foregroundStyle(generator.isWorking ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .swipeActions(edge: .trailing) {
            Button("Remove", role: .destructive, action: forget)
        }
    }
}

private struct NoGeneratorRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No generator connected")
                .font(.subheadline.weight(.medium))
            Text("Sign in to Higgsfield below and Autocast can make the videos your plan describes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
