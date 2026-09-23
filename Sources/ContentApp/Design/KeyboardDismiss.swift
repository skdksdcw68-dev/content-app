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
    /// A tap on this view closes the keyboard. Meant for a background: put it
    /// on the colour behind a screen's content, never on or above the content
    /// itself.
    func dismissesKeyboardOnTap() -> some View {
        contentShape(Rectangle())
            .onTapGesture { KeyboardDismiss.now() }
            .accessibilityHidden(true)
    }
}
