import PhotosUI
import SwiftUI

/// The person's picture, or their initial when there is none.
struct ProfileAvatar: View {
    @Environment(AppSession.self) private var session
    var size: CGFloat = 88

    var body: some View {
        Group {
            if let image = session.avatarImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                InitialAvatar(initial: session.initial, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Edit profile: the picture, the name, and the facts about the account.
///
/// Netro, 19 Oct 2026: "When a user opens their profile and clicks the edit
/// button, there is no separate page or sheet to edit the profile picture and
/// name, or to view email and detailed account information." The name was an
/// alert with one field. This is the system's own Form in a sheet, the way
/// Settings edits a profile.
struct EditProfileView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var picked: PhotosPickerItem?
    @State private var working = false
    @State private var copied = false

    var body: some View {
        let facts = session.accountFacts
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        ZStack {
                            ProfileAvatar(size: 104)
                            if working {
                                Circle().fill(.black.opacity(0.35)).frame(width: 104, height: 104)
                                ProgressView().tint(.white)
                            }
                        }
                        HStack(spacing: 16) {
                            PhotosPicker(selection: $picked, matching: .images) {
                                Text(session.avatarPath == nil ? "Add photo" : "Change photo")
                                    .font(.subheadline.weight(.semibold))
                            }
                            if session.avatarPath != nil {
                                Button("Remove", role: .destructive) {
                                    Task {
                                        working = true
                                        await session.removeAvatar()
                                        working = false
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section("Name") {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                        .submitLabel(.done)
                }

                Section {
                    LabeledContent("Email", value: facts.email ?? "Not added")
                    if let method = facts.signInMethod {
                        LabeledContent("Signed in with", value: method)
                    }
                    if let since = facts.memberSince {
                        LabeledContent("Member since", value: since.formatted(date: .long, time: .omitted))
                    }
                    LabeledContent("Plan", value: planLine)
                    if let id = facts.id {
                        Button {
                            UIPasteboard.general.string = id
                            copied = true
                        } label: {
                            LabeledContent("Account ID") {
                                Text(copied ? "Copied" : String(id.prefix(8)).uppercased())
                                    .monospaced()
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Your email and how you sign in come from your Apple or Google account. The account ID helps support find you.")
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if name.trimmingCharacters(in: .whitespacesAndNewlines) != (session.displayName ?? "") {
                                await session.saveName(name, promoting: "")
                            }
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { name = session.displayName ?? "" }
            .task(id: picked) { await usePicked() }
            .sensoryFeedback(.success, trigger: copied)
        }
    }

    private var planLine: String {
        guard let plan = session.subscription else { return "Free" }
        guard plan.isPro, let date = plan.expires else { return plan.title }
        let when = date.formatted(date: .abbreviated, time: .omitted)
        return plan.autoRenew == false ? "\(plan.title), ends \(when)" : "\(plan.title), renews \(when)"
    }

    private func usePicked() async {
        guard let picked else { return }
        working = true
        defer { working = false; self.picked = nil }
        guard let data = try? await picked.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            session.lastError = "That picture couldn't be opened."
            return
        }
        await session.uploadAvatar(image)
    }
}
