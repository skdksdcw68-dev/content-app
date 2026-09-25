import SwiftUI

/// The editor's tools, as a bar the app owns.
///
/// Abel, 25 Sep 2026: *"we are literally using something like bottom editors,
/// the edition things... yeah they are good, but instead let's use not a native
/// things"*, and he confirmed he meant a custom-drawn bar rather than the
/// system one.
///
/// The system bar had a real fault behind the aesthetic one: `tool` is set to
/// nil when a sheet closes, so **no tool was ever shown as selected** and the
/// bar could not say where you were. It also put its own glass behind every
/// item — the same thing that made the Next button read as two buttons — and
/// spaced everything with `Spacer()` at the system's mercy.
///
/// Nothing here is invented. It is `AnalyticsRangeBar`'s recipe
/// (`Features/Analytics/AnalyticsControls.swift`), which the app already calls
/// "the range pills, the way Studio does them": a capsule filled with the
/// accent when chosen and `Color.track` when not, `SoftPressStyle`, and
/// selection feedback on the container.
struct EditorToolBar: View {
    let tools: [EditorView.Tool]
    /// The tool whose sheet is open, or the last one used. Kept by the owner
    /// so the bar still shows where you were after a sheet closes.
    @Binding var active: EditorView.Tool?
    let pick: (EditorView.Tool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tools) { tool in
                let chosen = active == tool
                Button {
                    pick(tool)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .symbolVariant(chosen ? .fill : .none)
                        Text(tool.rawValue)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(chosen ? Theme.onAccent : Color.primary.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(chosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.track), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityLabel(tool.rawValue)
                .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.2), value: active)
        .sensoryFeedback(.selection, trigger: active)
        // The bar's own surface, so it reads as one thing over the video
        // rather than five glass pills the system arranged.
        .background(.bar)
    }
}
