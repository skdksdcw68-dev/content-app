import SwiftUI

/// Chat | Create, drawn so the side you are on can be told at a glance.
///
/// Abel, 2 Nov 2026, of the system's segmented control in the bar and on the
/// list: "change the color because it's not that visible now." A segmented
/// control is grey on grey; this one fills the chosen side with the page's
/// opposite -- black on a light page, white on a dark one -- and leaves the
/// other side as quiet text.
struct ModeSwitch: View {
    @Binding var isCreate: Bool

    var body: some View {
        HStack(spacing: 0) {
            side("Chat", chosen: !isCreate) { isCreate = false }
            side("Create", chosen: isCreate) { isCreate = true }
        }
        // No track behind the two words: only the chosen side is drawn (Abel,
        // 2 Nov 2026: "the thing on the background that covers everything --
        // can we remove it?").
        .frame(width: 190)
        .accessibilityElement(children: .contain)
    }

    private func side(_ title: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !chosen else { return }
            withAnimation(.easeOut(duration: 0.18)) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chosen ? Color(.systemBackground) : Color.primary.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if chosen { Capsule().fill(Color.primary) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}
