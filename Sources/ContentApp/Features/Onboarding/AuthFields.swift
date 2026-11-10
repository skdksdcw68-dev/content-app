import SwiftUI

/// The big, quiet fields of the sign-up mockup ("Home and sign-up redesign",
/// Abel, 10 Nov 2026): what is typed is drawn large in the middle of the page
/// with a blinking caret. The real text field sits invisible on top, so the
/// keyboard, autofill and paste all behave as normal. One plain line, never
/// split into boxes or segments.

// MARK: - Password

/// A password as big dots (or big characters when shown). Each new dot pops in.
/// Against `compareTo`, a dot that does not match turns into a small red
/// square, so a wrong confirmation can be seen at a glance.
struct BigPasswordField: View {
    let prompt: String
    @Binding var text: String
    var show: Bool
    var compareTo: String?
    var isNewPassword: Bool
    /// The page wants this field to have the keyboard.
    var wantsFocus: Bool
    var onFocus: () -> Void = {}
    var onSubmit: () -> Void = {}
    var submitLabel: SubmitLabel = .go

    @FocusState private var focus: Bool

    var body: some View {
        ZStack {
            // The real field: invisible, over everything.
            TextField("", text: $text)
                .textContentType(isNewPassword ? .newPassword : .password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)
                .foregroundStyle(.clear)
                .tint(.clear)
                .focused($focus)
                .accessibilityLabel(prompt)

            HStack(spacing: 0) {
                if text.isEmpty {
                    Text(prompt)
                        .font(.system(size: 22))
                        .foregroundStyle(OB.text3)
                }
                glyphs
                caret
            }
            .scaleEffect(min(1, 13.0 / Double(max(text.count, 1))))
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(height: 64)
        .contentShape(Rectangle())
        .onTapGesture { focus = true }
        .onChange(of: wantsFocus) { _, wanted in focus = wanted }
        .onChange(of: focus) { _, now in if now { onFocus() } }
        .onAppear { if wantsFocus { focus = true } }
    }

    private var glyphs: some View {
        let characters = Array(text)
        let other = compareTo.map { Array($0) }
        return HStack(spacing: show ? 1 : 8) {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                let missing = other.map { index >= $0.count || $0[index] != character } ?? false
                glyph(character, missing: missing)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.3).combined(with: .opacity).combined(with: .offset(y: 14)),
                        removal: .opacity))
            }
        }
        .padding(.horizontal, show ? 0 : 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: text.count)
    }

    @ViewBuilder
    private func glyph(_ character: Character, missing: Bool) -> some View {
        if show {
            Text(String(character))
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(missing ? Color(.systemRed) : Color.primary)
                .underline(missing, color: Color(.systemRed))
        } else if missing {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(.systemRed))
                .frame(width: 18, height: 18)
        } else {
            Circle().fill(Color.primary).frame(width: 18, height: 18)
        }
    }

    private var caret: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(OB.accent)
            .frame(width: 3, height: 34)
            .padding(.leading, 4)
            .modifier(Blink())
            .opacity(focus ? 1 : 0)
    }
}

/// A caret that blinks once a second.
private struct Blink: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                content.opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0)
            }
        }
    }
}

// MARK: - Email

/// The address, big, shrinking in steps as it grows so it always fits on one
/// line: 36, 29, 23, then 19 points.
struct BigEmailField: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}

    @FocusState private var focus: Bool

    private var size: CGFloat {
        switch text.count {
        case ...15: return 36
        case ...20: return 29
        case ...26: return 23
        default: return 19
        }
    }

    var body: some View {
        ZStack {
            TextField("", text: $text)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .onSubmit(onSubmit)
                .foregroundStyle(.clear)
                .tint(.clear)
                .focused($focus)
                .onChange(of: text) { _, value in
                    let clean = value.lowercased().filter { !$0.isWhitespace }
                    if clean != value { text = clean }
                }
                .accessibilityLabel("Email address")

            HStack(spacing: 2) {
                if text.isEmpty {
                    Text("name@example.com")
                        .font(.system(size: 22))
                        .foregroundStyle(OB.text3)
                } else {
                    Text(text)
                        .font(.system(size: size, weight: .semibold))
                        .tracking(-0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(OB.accent)
                    .frame(width: 3, height: size * 1.05)
                    .modifier(Blink())
                    .opacity(focus ? 1 : 0)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.2), value: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(height: 72)
        .contentShape(Rectangle())
        .onTapGesture { focus = true }
        .onAppear { focus = true }
    }
}

/// The address ends in what people usually type next: offered once there is a
/// name before the @ and no full address yet.
struct DomainChips: View {
    let email: String
    let pick: (String) -> Void

    private static let domains = ["@gmail.com", "@icloud.com", "@outlook.com"]

    private var offered: [String] {
        guard let at = email.firstIndex(of: "@") else {
            return email.isEmpty ? [] : Self.domains
        }
        let tail = String(email[at...])
        return Self.domains.filter { $0.hasPrefix(tail) && $0 != tail }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(offered, id: \.self) { domain in
                Button {
                    let head = email.firstIndex(of: "@").map { String(email[..<$0]) } ?? email
                    pick(head + domain)
                } label: {
                    Text(domain)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(OB.surface, in: Capsule())
                }
                .buttonStyle(ObPressStyle())
            }
        }
        .transition(.opacity.combined(with: .offset(y: 8)))
    }
}

/// "Show" / "Hide", the small pill at the top right of the password page.
struct ShowPasswordPill: View {
    @Binding var show: Bool

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: show ? "eye.slash" : "eye")
                    .font(.system(size: 17, weight: .medium))
                Text(show ? "Hide" : "Show")
                    .font(.system(size: 16, weight: .medium))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(OB.surface, in: Capsule())
        }
        .buttonStyle(ObPressStyle())
        .accessibilityLabel(show ? "Hide password" : "Show password")
    }
}
