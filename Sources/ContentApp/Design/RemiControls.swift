import SwiftUI

/// Remi's switch, visible in both looks.
///
/// The system switch takes the accent as its "on" colour and keeps a white
/// knob. The accent is white in dark mode, so an "on" switch was a white knob
/// on a white track -- Abel couldn't see it (18 Sep 2026). Here the knob is
/// always the accent's inverse: white on black in light, black on white in
/// dark. Off is the quiet track grey, as Remi's chips are.
struct RemiSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                RemiSwitch(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: configuration.isOn)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct RemiSwitch: View {
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color(uiColor: .systemFill))
            .frame(width: 51, height: 31)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Theme.onAccent : Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .padding(2)
            }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Remi's filled button for anything that is not the big primary action.
///
/// Replaces `.borderedProminent`, which draws its label white whatever the
/// tint: with the accent white in dark mode, that is white on white. The label
/// here is always the accent's inverse.
struct RemiFilledButtonStyle: ButtonStyle {
    @Environment(\.controlSize) private var size
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .small || size == .mini ? .subheadline.weight(.semibold) : .body.weight(.semibold))
            .padding(.horizontal, size == .small || size == .mini ? 14 : 20)
            .frame(minHeight: size == .large ? 50 : (size == .small || size == .mini ? 32 : 44))
            .foregroundStyle(Theme.onAccent)
            .background(Color.accentColor.opacity(isEnabled ? 1 : 0.35), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}
