import SwiftUI

/// Who this account is, what the autopilot may do, and everything to do with
/// the person rather than the posts.
///
/// The brief sits at the top because it is the input to everything else: a
/// planner with no audience and no niche writes generically, and no amount of
/// tuning further down this screen fixes that.
struct ProfileView: View {
    @Environment(ContentStore.self) private var store
    @State private var showingDisconnectConfirmation = false

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        BrandProfileView()
                    } label: {
                        BrandHeader()
                    }
                }

                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Autopilot rules")
                                Text(store.settings.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }

                    NavigationLink {
                        MemoryView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AI memory")
                                Text(memorySummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "brain")
                        }
                    }
                } header: {
                    Text("Content preferences")
                }

                Section {
                    if store.accounts.isEmpty {
                        Text("Nothing connected")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.accounts) { account in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.handle)
                                Text(account.isConnected
                                     ? account.platform.displayName
                                     : "\(account.platform.displayName) \u{2014} disconnected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: account.platform.symbolName)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                } header: {
                    Text("Connected accounts")
                } footer: {
                    Text("The autopilot will not plan for a platform with no account linked \u{2014} an unpostable queue is worse than an empty one.")
                }

                Section {
                    Toggle("When a post goes out", isOn: $store.notifyOnPublish)
                    Toggle("When something fails", isOn: $store.notifyOnFailure)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Autocast works while the app is closed, so these are the only way you find out what it did.")
                }

                Section {
                    LabeledContent("Plan", value: "TestFlight")
                } header: {
                    Text("Subscription")
                } footer: {
                    Text("Billing is not connected while Autocast is in TestFlight. Nothing is charged and there is nothing to manage yet.")
                }

                Section {
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                } header: {
                    Text("Privacy")
                }

                if store.connectionState == .connected {
                    Section {
                        Button("Disconnect account", role: .destructive) {
                            showingDisconnectConfirmation = true
                        }
                    } footer: {
                        Text("Your brand profile and memory stay on this device. Only the queue and the linked account are cleared.")
                    }
                }
            }
            .navigationTitle("Profile")
            .confirmationDialog(
                "Disconnect this account?",
                isPresented: $showingDisconnectConfirmation,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) { store.disconnect() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The queue is cleared and autopilot turns off. Anything already posted stays up.")
            }
        }
    }

    private var memorySummary: String {
        guard store.brand.usesMemory else { return "Off" }
        let count = store.brand.memory.count
        if count == 0 { return "Nothing learned yet" }
        return "\(count) \(count == 1 ? "thing" : "things") it applies on its own"
    }
}

// MARK: - Brand header

private struct BrandHeader: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.brand.name.isEmpty ? "Your brand" : store.brand.name)
                    .font(.headline)

                Text(store.brand.summary)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !store.brand.isComplete {
                    // Not an error, but the planner writes noticeably worse
                    // without it, so it is worth saying on the row.
                    Text("Fill this in and the writing gets sharper")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Brand profile

/// The brief. Free text on purpose -- it is handed to the model as written,
/// so a sentence works better here than a set of dropdowns would.
struct BrandProfileView: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                TextField("Name", text: $store.brand.name)
            } header: {
                Text("Brand")
            } footer: {
                Text("What the account is called. Used when it writes in the first person.")
            }

            Section {
                TextField("What it is about", text: $store.brand.niche, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("Subject")
            } footer: {
                Text("The thing every post comes back to. Narrow beats broad.")
            }

            Section {
                TextField("Who it is for", text: $store.brand.audience, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("Audience")
            } footer: {
                Text("Written as a sentence rather than keywords \u{2014} this goes to the model exactly as you type it.")
            }
        }
        .navigationTitle("Brand")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Memory

/// What the planner has worked out and now applies without being told.
///
/// Shown in full and removable line by line. An autopilot that quietly
/// accumulates opinions about you and never shows them is not one people end
/// up trusting with an unattended publish switch.
struct MemoryView: View {
    @Environment(ContentStore.self) private var store
    @State private var showingClearConfirmation = false

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                Toggle("Use memory", isOn: $store.brand.usesMemory)
            } footer: {
                Text(store.brand.usesMemory
                     ? "The planner is given everything below along with your brief."
                     : "The planner is given your brief only. Nothing below is used, and nothing is deleted.")
            }

            if store.brand.memory.isEmpty {
                Section {
                    Text("Nothing learned yet. This fills in once enough posts have gone out to draw a conclusion from.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(store.brand.memory, id: \.self) { item in
                        Text(item)
                            .font(.subheadline)
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.forget(item)
                                } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("What it has learned")
                } footer: {
                    Text("Swipe any line to remove it. The planner stops applying it immediately.")
                }

                Section {
                    Button("Forget everything", role: .destructive) {
                        showingClearConfirmation = true
                    }
                }
            }
        }
        .navigationTitle("AI memory")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Forget everything it has learned?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget everything", role: .destructive) { store.forgetAllMemory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your brand profile stays. Only what the planner worked out on its own is cleared, and it starts learning again from the next post.")
        }
    }
}

// MARK: - Privacy

private struct PrivacyView: View {
    var body: some View {
        Form {
            Section {
                Text("Autocast stores your queue, brand profile and connected account. It does not read anything from your camera roll unless you hand it a file.")
                    .font(.subheadline)
            }

            Section {
                Text("Scripts and captions are written by a model. What is sent is your brief, your pillars and your memory \u{2014} never your followers or their messages.")
                    .font(.subheadline)
            } header: {
                Text("What goes to the model")
            }

            Section {
                Text("Disconnecting an account clears its queue from this device. Posts already published stay up on the platform, because Autocast cannot take back something you have posted.")
                    .font(.subheadline)
            } header: {
                Text("Deleting things")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    let store = ContentStore()
    return ProfileView()
        .environment(store)
        .task { await store.connect() }
}
