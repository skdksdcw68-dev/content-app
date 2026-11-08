import SwiftUI

/// The tab that took the You page's place (Abel, 3 Nov 2026): somewhere to start
/// from. What is trending today -- looked up live, once a day per country -- and
/// ready-made starting points that open a chat already asking for the thing. The
/// person's own page is Settings, a sheet from the round photo at the top right.
struct ExploreView: View {
    @Environment(AppSession.self) private var session

    @State private var query = ""
    @State private var trends: [TrendCard] = []
    @State private var loadingTrends = true

    private struct Template: Identifiable {
        let id: String
        let title: String
        let blurb: String
        let caption: String
        let colors: [Color]
        let route: AppRoute
    }

    private let templates: [Template] = [
        Template(
            id: "scary", title: "Scary story", blurb: "Deep voice, dark pictures, word-by-word captions",
            caption: "SHE HEARD IT AGAIN", colors: [Color(red: 0.08, green: 0.07, blue: 0.10), Color(red: 0.22, green: 0.12, blue: 0.30)],
            route: .makeVideo("a scary story video")
        ),
        Template(
            id: "motivation", title: "Motivation reel", blurb: "One idea, music and bold captions",
            caption: "NOBODY SAW THE FIRST 20 TRIES", colors: [Color(red: 0.09, green: 0.15, blue: 0.29), Color(red: 0.16, green: 0.35, blue: 0.60)],
            route: .makeVideo("a motivational video")
        ),
        Template(
            id: "animate", title: "Photo to video", blurb: "Bring one of your pictures to life",
            caption: "▶", colors: [Color(red: 0.18, green: 0.16, blue: 0.15), Color(red: 0.40, green: 0.30, blue: 0.24)],
            route: .chatOpening("Turn a picture of mine into a short video")
        ),
        Template(
            id: "thumbnail", title: "YouTube thumbnail", blurb: "16:9, a face and three big words",
            caption: "I TRIED IT FOR 30 DAYS", colors: [Color(red: 0.91, green: 0.27, blue: 0.17), Color(red: 0.98, green: 0.55, blue: 0.20)],
            route: .chatOpening("Make a YouTube thumbnail")
        ),
    ]

    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var shownTrends: [TrendCard] {
        typed.isEmpty ? trends : trends.filter {
            $0.title.localizedCaseInsensitiveContains(typed) || $0.why.localizedCaseInsensitiveContains(typed)
                || $0.kind.localizedCaseInsensitiveContains(typed)
        }
    }

    private var shownTemplates: [Template] {
        typed.isEmpty ? templates : templates.filter {
            $0.title.localizedCaseInsensitiveContains(typed) || $0.blurb.localizedCaseInsensitiveContains(typed)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SearchPill(text: $query, prompt: "Search templates and trends")

                if !typed.isEmpty {
                    // Whatever they typed is also something to ask for.
                    NavigationLink(value: AppRoute.chatOpening(typed)) {
                        ExploreRow(symbol: "sparkles", title: "Ask Postpilot", subtitle: "“\(typed)”")
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: AppRoute.library) {
                        ExploreRow(symbol: "photo.on.rectangle.angled", title: "Your library", subtitle: "Everything you've made")
                    }
                    .buttonStyle(.plain)
                }

                if loadingTrends || !shownTrends.isEmpty {
                    trendingSection
                }

                if !shownTemplates.isEmpty {
                    templatesSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .animation(.snappy(duration: 0.25), value: typed)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.canvas.ignoresSafeArea())
        .tabChrome(
            title: "Explore",
            mode: .inlineLarge,
            trailing: AnyView(SettingsAvatarButton())
        )
        .task {
            guard trends.isEmpty else { return }
            let found = await session.trends()
            withAnimation(.snappy(duration: 0.3)) {
                trends = found
                loadingTrends = false
            }
        }
        .refreshable {
            trends = await session.trends()
        }
    }

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Trending today")
                    .font(.title2.bold())
                Spacer()
                NavigationLink(value: AppRoute.chatOpening("What's trending right now for creators on TikTok and Reels? Pick the best one for me and write the post.")) {
                    Text("Ask")
                        .font(.subheadline.weight(.semibold))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    if loadingTrends {
                        ForEach(0..<3, id: \.self) { _ in
                            TrendCardView(trend: TrendCard(kind: "Sound", title: "Looking up today's trends", why: "One moment while Postpilot checks TikTok and Reels.", idea: ""))
                                .redacted(reason: .placeholder)
                        }
                    } else {
                        ForEach(shownTrends) { trend in
                            NavigationLink(value: AppRoute.chatOpening("Make me a post on this trend: \(trend.title). \(trend.idea)")) {
                                TrendCardView(trend: trend)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Templates")
                .font(.title2.bold())
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                ForEach(shownTemplates) { template in
                    NavigationLink(value: template.route) {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                LinearGradient(colors: template.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                                Text(template.caption)
                                    .font(.system(size: 17, weight: .heavy))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.white)
                                    .padding(12)
                            }
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            Text(template.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(template.blurb)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
    }
}

/// One trend: what kind it is, its name, why it is moving, and a way in.
private struct TrendCardView: View {
    let trend: TrendCard

    private var symbol: String {
        switch trend.kind.lowercased() {
        case "sound": return "waveform"
        case "challenge": return "flag.checkered"
        case "topic": return "newspaper"
        default: return "film.stack"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [Color(red: 0.17, green: 0.14, blue: 0.27), Color(red: 0.36, green: 0.30, blue: 0.90)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(trend.kind.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.18), in: Capsule())
                    .padding(10)
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(trend.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(trend.why)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Text("Make this")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Theme.accent, in: Capsule())
        }
        .padding(10)
        .frame(width: 228, height: 268, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ExploreRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Shrinks a little under the finger, springs back.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Grok's settings colours, measured from Abel's recording (3 Nov 2026).
enum GrokLook {
    static func sheet(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.067, green: 0.067, blue: 0.067) : Color(red: 0.949, green: 0.949, blue: 0.949)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.129, green: 0.129, blue: 0.129) : .white
    }
}

/// A grey label over a group, Grok's size.
struct GrokCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
    }
}

/// Grok's "Search settings" pill: a magnifier, the field, a clear button.
struct SearchPill: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { text = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }
}

/// The round photo at the top right of every tab. Opens Settings as a sheet.
/// A red dot when something needs attention -- where the You tab's badge was.
struct SettingsAvatarButton: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Button {
            session.showingSettings = true
        } label: {
            ProfileAvatar(size: 30)
                .overlay(alignment: .topTrailing) {
                    if session.attentionCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .accessibilityLabel("Settings")
    }
}

/// Settings, as a sheet over whatever tab you are on, the way Grok's is: a round
/// close button, the sheet's own dark or light ground, rows in rounded cards,
/// the search pill at the bottom.
struct SettingsSheet: View {
    /// A sheet does not follow the page behind it the moment the theme is
    /// changed inside it, so it reads the choice itself and applies it to its
    /// own content (Abel, 8 Nov 2026: it stayed white until reopened).
    @State private var appearance = AppAppearance.current

    var body: some View {
        SettingsSheetContent()
            .preferredColorScheme(appearance.colorScheme)
            .onReceive(NotificationCenter.default.publisher(for: .appearanceChanged)) { _ in
                appearance = AppAppearance.current
            }
    }
}

private struct SettingsSheetContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ProfileView(asSheet: true)
                .scrollContentBackground(.hidden)
                .background(GrokLook.sheet(scheme).ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                    }
                }
        }
        .grokSettings()
        .presentationDetents([.large])
        .presentationCornerRadius(34)
        .presentationDragIndicator(.hidden)
    }
}

extension View {
    /// Grok's settings, measured from Abel's recordings (3 Nov 2026): 15 pt
    /// rows 45 pt tall, and Apple's own green switches. On the whole sheet, so
    /// every page pushed inside it gets them too.
    func grokSettings() -> some View {
        font(.system(size: 15))
            .environment(\.defaultMinListRowHeight, 45)
            .toggleStyle(SwitchToggleStyle(tint: .green))
    }
}
