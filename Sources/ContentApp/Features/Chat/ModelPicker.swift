import SwiftUI

/// Fast, Normal or Deep: the one choice in the chat bar, and it picks the model
/// by itself (Abel, 7 Nov 2026: a model picker beside it "is making it worse").
///
/// Fast is Haiku, Normal is Auto (Haiku for talk, Sonnet when it needs to
/// think), Deep is Sonnet thinking longer. Looking things up on the web always
/// goes to OpenAI, and pictures and videos keep their own picker. Kept on the
/// phone.
struct ChatModelPrefs: Equatable {
    /// "low", "medium" or "high".
    var effort: String

    private static let effortKey = "chat.effort"

    static var current: ChatModelPrefs {
        get { ChatModelPrefs(effort: UserDefaults.standard.string(forKey: effortKey) ?? "medium") }
        set { UserDefaults.standard.set(newValue.effort, forKey: effortKey) }
    }

    /// What the server reads as `chatModel`.
    var model: String {
        switch effort {
        case "low": "haiku"
        case "high": "sonnet"
        default: "auto"
        }
    }

    /// What the person sees for the three levels.
    static func effortName(_ effort: String) -> String {
        switch effort {
        case "low": "Fast"
        case "high": "Deep"
        default: "Normal"
        }
    }
}

/// Fast, Normal or Deep, picked right in the chat bar.
struct EffortMenu: View {
    @Binding var prefs: ChatModelPrefs

    var body: some View {
        Menu {
            Picker("Analysis", selection: $prefs.effort) {
                Text("Fast").tag("low")
                Text("Normal").tag("medium")
                Text("Deep").tag("high")
            }
        } label: {
            HStack(spacing: 5) {
                Text(ChatModelPrefs.effortName(prefs.effort))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .accessibilityLabel("Analysis: \(ChatModelPrefs.effortName(prefs.effort))")
    }
}
