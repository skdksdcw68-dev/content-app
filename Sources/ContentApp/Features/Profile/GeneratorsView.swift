import SwiftUI

/// Video generators: the one to start with, the ones already connected, the
/// rest of the catalogue, and a door for any MCP server by address.
///
/// Abel, 22 Sep 2026: "connect to video generator should redirect you to some
/// video generator things" -- show people generators to pick from, lead with
/// the best one, and let them "manually [add an] MCP" so a server nobody here
/// has heard of can still be signed in to and used.
///
/// Which one leads is read from the row (`featured`), never written here; the
/// product's own words name no vendor (design rule since 12 Sep 2026).
struct GeneratorsView: View {
    @Environment(AppSession.self) private var session
    @State private var addingServer = false
    @State private var removing: ConnectableProvider?

    private var featured: ConnectableProvider? { session.connectable.first(where: \.isFeatured) }
    private var catalogue: [ConnectableProvider] { session.connectable.filter { !$0.isFeatured && !$0.isMine } }
    private var mine: [ConnectableProvider] { session.connectable.filter(\.isMine) }

    /// Pasted keys that are not already shown as a connection.
    private var unbridgedGenerators: [Generator] {
        session.generators.filter { generator in
            !session.connectedProviders.contains { $0.id == generator.id }
        }
    }

    private var hasConnected: Bool {
        !session.connectedProviders.isEmpty || !unbridgedGenerators.isEmpty
    }

    var body: some View {
        Form {
            if let featured {
                Section {
                    FeaturedProviderCard(provider: featured, busy: session.isWorking) {
                        Task { await session.connectProvider(featured.slug) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Sign in with the account you already have. Autocast never sees your password, and you are billed by them for what they make, never by us.")
                }
            }

            if hasConnected {
                Section("Connected") {
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
                }
            }

            if !catalogue.isEmpty || !mine.isEmpty {
                Section {
                    ForEach(catalogue) { provider in
                        ConnectableRow(provider: provider) {
                            Task { await session.connectProvider(provider.slug) }
                        }
                    }
                    ForEach(mine) { provider in
                        ConnectableRow(provider: provider, symbol: "server.rack") {
                            Task { await session.connectProvider(provider.slug) }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = provider }
                        }
                    }
                } header: {
                    Text(featured == nil && !hasConnected ? "Generators" : "More generators")
                }
            }

            Section {
                Button {
                    addingServer = true
                } label: {
                    Label("Add an MCP server", systemImage: "server.rack")
                }
                .disabled(session.isWorking)
            } footer: {
                Text("Any generator that runs an MCP server behind a sign-in works here. Paste its address and Autocast signs you in, reads what it can make, and uses it like the others.")
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
        .navigationTitle("Video generators")
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
        .sheet(isPresented: $addingServer) { AddMCPServerSheet() }
        .alert("Remove \(removing?.name ?? "this server")?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        )) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                guard let slug = removing?.slug else { return }
                removing = nil
                Task { await session.removeMCPServer(slug) }
            }
        } message: {
            Text("It comes off your list. Nothing changes on the server itself.")
        }
    }
}

// MARK: - The one to start with

/// The recommended generator, as a card with colour on it rather than a row:
/// the best thing on the screen should look like the best thing on the
/// screen. Words and name come from the row.
private struct FeaturedProviderCard: View {
    let provider: ConnectableProvider
    let busy: Bool
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECOMMENDED")
                .font(.caption2.weight(.heavy))
                .kerning(1.4)
                .foregroundStyle(.white.opacity(0.75))

            Text(provider.name)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)

            if let tagline = provider.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: connect) {
                Group {
                    if busy {
                        ProgressView().tint(.black)
                    } else {
                        Text(provider.action)
                    }
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 26)
                .padding(.vertical, 8)
                .background(.white, in: Capsule())
            }
            .buttonStyle(SoftPressStyle())
            .disabled(busy)
            .padding(.top, 6)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous)
                .fill(Color.indigo.gradient)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A generator not yet connected, as a row.
private struct ConnectableRow: View {
    let provider: ConnectableProvider
    var symbol = "person.crop.circle.badge.plus"
    let connect: () -> Void

    @Environment(AppSession.self) private var session

    var body: some View {
        Button(action: connect) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.action)
                    Text(provider.how)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
        .disabled(session.isWorking)
    }
}

// MARK: - Your own server

/// An MCP server by address. The address becomes a provider only this person
/// can see, and signing in starts at once.
private struct AddMCPServerSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""

    private var canConnect: Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("https://") && trimmed.count > 10 && !session.isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://mcp.example.ai/mcp", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Name (optional)", text: $name)
                } header: {
                    Text("MCP address")
                } footer: {
                    Text("From the generator's developer docs. It has to start with https:// and be behind a sign-in; Autocast registers itself with it and opens the sign-in page.")
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            if session.isWorking {
                                ProgressView().controlSize(.small)
                                Text("Connecting…")
                            } else {
                                Image(systemName: "person.crop.circle.badge.plus")
                                Text("Sign in and connect")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canConnect)
                } footer: {
                    Text("Once signed in, Autocast reads what the server can make and offers those models everywhere it offers the others.")
                }
            }
            .navigationTitle("Add an MCP server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(session.isWorking)
                }
            }
            .interactiveDismissDisabled(session.isWorking)
        }
        .presentationDetents([.medium, .large])
    }

    private func connect() async {
        let ok = await session.addMCPServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: address.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if ok { dismiss() }
    }
}

// MARK: - Connected

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
                 ? "Your pasted key is deleted from Autocast. Nothing changes in your \(provider.providerName) account."
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
