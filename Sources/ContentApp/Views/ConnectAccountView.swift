import SwiftUI

/// First run. One button, because there is exactly one thing to do.
struct ConnectAccountView: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "wand.and.stars")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Autocast plans your posts")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Connect an account and it starts planning short-form video for you \u{2014} the idea, the script, the caption. You approve, or let it post on its own.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button {
                Task { await store.connect(to: .tiktok) }
            } label: {
                HStack {
                    if store.connectionState == .connecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: Platform.tiktok.symbolName)
                    }
                    Text(store.connectionState == .connecting ? "Connecting\u{2026}" : "Connect TikTok")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.connectionState == .connecting)
            .padding(.horizontal, 24)

            Text("Autocast never posts anything until you turn autopilot on.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .navigationTitle("Autocast")
    }
}

#Preview {
    NavigationStack {
        ConnectAccountView()
            .environment(ContentStore())
    }
}
