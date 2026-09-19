import SwiftUI

/// The top of Profile: you. Your initial, your name, and what you promote.
///
/// Not a TikTok or YouTube identity -- those are accounts you connect, listed
/// under Accounts (Abel, 19 Sep 2026: "do not set the user account with its
/// tiktok or youtube, just ask for a name").
struct ProfileHeader: View {
    @Environment(AppSession.self) private var session
    @State private var editing = false
    @State private var draft = ""

    private var name: String { session.displayName ?? "Add your name" }

    /// The brand line, unless it is still the placeholder name.
    private var subtitle: String? {
        guard let brand = session.brand?.name, brand != "My brand", !brand.isEmpty else {
            return session.accountEmail
        }
        return brand
    }

    var body: some View {
        VStack(spacing: 0) {
            InitialAvatar(initial: session.initial, size: 88)

            Button {
                draft = session.displayName ?? ""
                editing = true
            } label: {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(session.displayName == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .accessibilityHint("Change your name")

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .alert("Your name", isPresented: $editing) {
            TextField("Name", text: $draft)
                .textContentType(.name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = draft
                Task { await session.saveName(name, promoting: "") }
            }
        }
    }
}
