import SwiftUI
import UIKit

/// Tap an empty part of the screen to put the keyboard away (Abel, 23 Sep
/// 2026: "everywhere a keyboard opens clicking a free place on the screen
/// should close the keyboard").
///
/// 🔴 The obvious way to do this is a `TapGesture` on the whole app, and it
/// breaks the app. A gesture recogniser attached above the `TabView` takes
/// part in arbitration for EVERY touch, and against a List row, a
/// NavigationLink, a toolbar button or the tab bar it sometimes wins -- so
/// taps land nowhere and only some controls still work. Build 81 shipped
/// exactly that ("you cannot click the settings, the chats and anything").
///
/// The safe place for it is the screen's own BACKGROUND. Hit testing runs
/// front to back, so every button, row and link takes the touch first and the
/// background only ever sees the gaps between them. A background can never be
/// in front of a control, so it can never steal one's tap.
///
/// Use it where the background is set:
///
///     .background(Color.canvas.ignoresSafeArea().dismissesKeyboardOnTap())
///
/// Scrollable screens also dismiss on a drag, from `.scrollDismissesKeyboard`
/// on the root; this is for the screens where there is empty space to tap.
enum KeyboardDismiss {
    /// Ends editing wherever it is happening, without needing to know which
    /// field had it.
    static func now() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}

extension View {
    /// For a Form, List or ScrollView that has text fields: a tap that lands
    /// anywhere on it also closes the keyboard.
    ///
    /// 🔴 This was `simultaneousGesture(TapGesture())` on the List, and it
    /// broke the very screens it was put on (Abel, 8 Nov 2026: "clicking on a
    /// chat history doesn't even work"). A SwiftUI tap gesture on a List takes
    /// the touch from its NavigationLink rows, "simultaneous" or not. Now it
    /// is a UIKit tap recogniser on the window, only while this screen is on
    /// it, that never cancels or delays a touch: the row, link or button gets
    /// its tap exactly as before, and the keyboard closes as well. A tap on a
    /// text field itself is ignored, so tapping into a field still types.
    func dismissesKeyboardOnTapInside() -> some View {
        background(KeyboardTapCatcher().allowsHitTesting(false))
    }

    /// A tap on this view closes the keyboard. Meant for a background: put it
    /// on the colour behind a screen's content, never on or above the content
    /// itself.
    func dismissesKeyboardOnTap() -> some View {
        contentShape(Rectangle())
            .onTapGesture { KeyboardDismiss.now() }
            .accessibilityHidden(true)
    }
}

/// Puts a passive tap recogniser on the window while its screen is showing.
/// It recognises alongside everything else and never cancels or delays a
/// touch, so it cannot take a tap away from a control.
private struct KeyboardTapCatcher: UIViewRepresentable {
    func makeUIView(context: Context) -> CatcherView { CatcherView() }
    func updateUIView(_ uiView: CatcherView, context: Context) {}

    final class CatcherView: UIView, UIGestureRecognizerDelegate {
        private lazy var tap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            return tap
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tap.view?.removeGestureRecognizer(tap)
            window?.addGestureRecognizer(tap)
        }

        @objc private func tapped() { KeyboardDismiss.now() }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// A tap inside a text field or text view is for typing, not for
        /// closing the keyboard.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }
    }
}
