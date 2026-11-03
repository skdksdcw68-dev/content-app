import SwiftUI

/// The tab that took the You page's place (Abel, 3 Nov 2026): somewhere to start
/// from. What is trending, and ready-made starting points that open a chat
/// already asking for the thing. The person's own page is Settings, a sheet from
/// the round photo at the top right of every tab.
struct ExploreView: View {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                NavigationLink(value: AppRoute.library) {
                    ExploreRow(
                        symbol: "photo.on.rectangle.angled",
                        title: "Your library",
                        subtitle: "Everything you've made"
                    )
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Trending today")
                        .font(.title2.bold())
                    NavigationLink(value: AppRoute.chatOpening("What's trending right now for creators on TikTok and Reels? Pick the best one for me and write the post.")) {
                        HStack(spacing: 14) {
                            Image(systemName: "flame.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(
                                    LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.90), Color(red: 0.62, green: 0.30, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("What's trending right now")
                                    .font(.headline)
                                Text("Autocast looks it up live, picks one and writes the post")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Templates")
                        .font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                        ForEach(templates) { template in
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
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .tabChrome(
            title: "Explore",
            mode: .inlineLarge,
            trailing: AnyView(SettingsAvatarButton())
        )
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
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
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
/// close button, the sheet's own dark or light ground, rows in rounded cards.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ProfileView(asSheet: true)
                .scrollContentBackground(.hidden)
                .background(
                    (scheme == .dark
                        ? Color(red: 0.067, green: 0.067, blue: 0.067)
                        : Color(red: 0.949, green: 0.949, blue: 0.949))
                        .ignoresSafeArea()
                )
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
        .presentationDetents([.large])
        .presentationCornerRadius(34)
        .presentationDragIndicator(.hidden)
    }
}
