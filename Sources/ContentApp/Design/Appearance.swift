import SwiftUI

/// Light, dark, or follow the phone -- Remi's setting, with Remi's default.
///
/// Abel, 15 Sep 2026: Remi's colours in both light and dark mode. Remi
/// (`Services/AppSettings.swift`) is black buttons on a white screen and white
/// buttons on a black one, and **light is its default**: dark is something a
/// person chooses, not something the phone imposes the first time they open
/// the app. Autocast now does the same.
enum AppAppearance: String, CaseIterable, Sendable {
    case light, dark, system

    var colorScheme: ColorScheme? {
        switch self {
        case .light:  .light
        case .dark:   .dark
        case .system: nil
        }
    }

    var title: String {
        switch self {
        case .light:  "Light"
        case .dark:   "Dark"
        case .system: "System"
        }
    }

    private static let key = "preferences.appearance"

    static var current: AppAppearance {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .light
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .appearanceChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted when the appearance changes, so `RootView` applies it to every
    /// screen at once, sheets included.
    static let appearanceChanged = Notification.Name("autocast.appearanceChanged")
}
