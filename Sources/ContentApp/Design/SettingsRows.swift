import SwiftUI

// Remi's settings rows (remi/native/.../Profile/SettingsViews.swift), brought
// across for the Profile rebuild on 18 Sep 2026. One weight of ink, outline
// symbols in one column, the way iPhone Settings draws them -- Remi's owner
// rejected coloured tiles, and so would this one.

/// The symbol beside a settings row, in a column wide enough that every title
/// on the screen starts at the same place.
struct SettingsIcon: View {
    let symbol: String

    /// 28 points at the default text size, and wider with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 28

    init(_ symbol: String) {
        self.symbol = symbol
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.body)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.primary)
            .frame(width: width, alignment: .center)
            .accessibilityHidden(true)
    }
}

/// A network's own mark in the icon column, so a row for TikTok looks like
/// TikTok. The same width as `SettingsIcon`, so every title still starts in
/// the same place.
struct SettingsLogo: View {
    let logo: BrandLogo

    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 28

    init(_ logo: BrandLogo) { self.logo = logo }

    var body: some View {
        logo.view
            .frame(width: 20, height: 20)
            .frame(width: width, alignment: .center)
            .accessibilityHidden(true)
    }
}

/// A symbol and a title -- what goes inside a `NavigationLink`.
struct SettingsLabel: View {
    let title: String
    let symbol: String?
    let logo: BrandLogo?

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
        self.logo = nil
    }

    init(_ title: String, logo: BrandLogo) {
        self.title = title
        self.symbol = nil
        self.logo = logo
    }

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(Color.primary)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        } icon: {
            if let logo {
                SettingsLogo(logo)
            } else if let symbol {
                SettingsIcon(symbol)
            }
        }
    }
}

/// A `NavigationLink` label with a value on the right, before the chevron the
/// system adds.
struct SettingsValueLabel: View {
    let title: String
    let symbol: String
    let value: String?

    init(_ title: String, symbol: String, value: String?) {
        self.title = title
        self.symbol = symbol
        self.value = value
    }

    var body: some View {
        HStack(spacing: 8) {
            SettingsLabel(title, symbol: symbol)
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
            }
        }
    }
}

/// A whole row for a `Button` or a `Link`, which get no chevron from the
/// system: the symbol, the title, an optional value, and where a tap goes.
struct SettingsRow: View {
    enum Accessory {
        case none
        /// Opens a screen or a sheet inside Autocast.
        case chevron
        /// Leaves Autocast -- Settings, Mail, the App Store.
        case external
    }

    let title: String
    let symbol: String?
    let logo: BrandLogo?
    let value: String?
    let accessory: Accessory

    init(_ title: String, symbol: String, value: String? = nil, accessory: Accessory = .none) {
        self.title = title
        self.symbol = symbol
        self.logo = nil
        self.value = value
        self.accessory = accessory
    }

    /// The same row wearing a network's own mark.
    init(_ title: String, logo: BrandLogo, value: String? = nil, accessory: Accessory = .none) {
        self.title = title
        self.symbol = nil
        self.logo = logo
        self.value = value
        self.accessory = accessory
    }

    private var mark: String? {
        switch accessory {
        case .none: nil
        case .chevron: "chevron.forward"
        case .external: "arrow.up.forward"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let logo {
                SettingsLabel(title, logo: logo)
            } else {
                SettingsLabel(title, symbol: symbol ?? "circle")
            }
            Spacer(minLength: 0)
            if let shown = value {
                Text(shown)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
            }
            if let symbolName = mark {
                Image(systemName: symbolName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
