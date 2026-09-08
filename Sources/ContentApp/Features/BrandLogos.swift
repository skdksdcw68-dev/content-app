import SwiftUI

/// The platform logos, drawn rather than shipped.
///
/// These replace the coloured lettermarks — "T", "I", "Y" in circles — that
/// stood in for them. The lettermark was an honest placeholder and it read as
/// one: a row of three initials tells somebody nothing their eye can catch,
/// and the whole job of that screen is to be scanned.
///
/// **Drawn in SwiftUI, not imported.** Three reasons, and the first is the one
/// that matters:
///
/// 1. Nothing copyrighted is bundled. A PNG of Meta's or TikTok's glyph is
///    their file shipped under their brand terms; a rounded square and a
///    circle are geometry. Using a platform's mark on a "connect your account"
///    row is what their brand guidelines are *for*, but the safe version of
///    that is not to redistribute their artwork.
/// 2. It stays sharp at any size, on any screen, with no asset catalogue.
/// 3. It adapts. The YouTube mark needs a light plate behind it in dark mode;
///    a flat PNG cannot know that.
///
/// Each is built from the shapes the real mark is built from, at the
/// proportions the real mark uses. They are recognisable at 40pt, which is
/// where they are used, and they do not pretend to be pixel-exact.
enum BrandLogo: String {
    case tiktok, instagram, youtube

    @ViewBuilder
    var view: some View {
        switch self {
        case .tiktok:    TikTokMark()
        case .instagram: InstagramMark()
        case .youtube:   YouTubeMark()
        }
    }
}

// MARK: - TikTok

/// The note, in TikTok's chromatic offset: a cyan copy up-left, a red copy
/// down-right, the white note over both. That split is the whole identity of
/// the mark — drawn in one colour it reads as a generic music note.
private struct TikTokMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let note = side * 0.52

            ZStack {
                Rectangle().fill(.black)

                ZStack {
                    glyph(note)
                        .foregroundStyle(Color(red: 0.16, green: 0.95, blue: 0.93))
                        .offset(x: -side * 0.030, y: -side * 0.022)

                    glyph(note)
                        .foregroundStyle(Color(red: 1.0, green: 0.15, blue: 0.35))
                        .offset(x: side * 0.030, y: side * 0.022)

                    glyph(note)
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func glyph(_ size: CGFloat) -> some View {
        Image(systemName: "music.note")
            .font(.system(size: size, weight: .black))
    }
}

// MARK: - Instagram

/// The camera outline: a rounded square, a circle inside it, a dot in the top
/// right — over the corner-to-corner gradient that runs yellow through pink to
/// purple. Every part of that is geometry, which is why it draws cleanly.
private struct InstagramMark: View {
    private static let gradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.98, green: 0.78, blue: 0.31), location: 0.00),
            .init(color: Color(red: 0.96, green: 0.45, blue: 0.22), location: 0.28),
            .init(color: Color(red: 0.84, green: 0.16, blue: 0.44), location: 0.58),
            .init(color: Color(red: 0.51, green: 0.20, blue: 0.78), location: 1.00),
        ],
        startPoint: .bottomLeading,
        endPoint: .topTrailing
    )

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let inset = side * 0.24
            let stroke = side * 0.075

            ZStack {
                Rectangle().fill(Self.gradient)

                RoundedRectangle(cornerRadius: side * 0.17, style: .continuous)
                    .strokeBorder(.white, lineWidth: stroke)
                    .frame(width: side - inset, height: side - inset)

                Circle()
                    .strokeBorder(.white, lineWidth: stroke)
                    .frame(width: side * 0.30, height: side * 0.30)

                Circle()
                    .fill(.white)
                    .frame(width: side * 0.075, height: side * 0.075)
                    .offset(x: side * 0.175, y: -side * 0.175)
            }
        }
    }
}

// MARK: - YouTube

/// The red rounded rectangle with a white play triangle.
///
/// On a white plate rather than bleeding to the edges: YouTube's mark is a
/// wide badge, and a wide badge cropped into a circle loses the shape that
/// makes it recognisable. The plate keeps its proportions and gives it
/// something to sit on in dark mode.
private struct YouTubeMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                Rectangle().fill(.white)

                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.0, blue: 0.0))

                    Triangle()
                        .fill(.white)
                        .frame(width: side * 0.19, height: side * 0.22)
                        .offset(x: side * 0.018)
                }
                .frame(width: side * 0.78, height: side * 0.55)
            }
        }
    }
}

/// A play triangle, pointing right.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview("Marks") {
    HStack(spacing: 16) {
        ForEach([BrandLogo.tiktok, .instagram, .youtube], id: \.rawValue) { logo in
            logo.view
                .frame(width: 40, height: 40)
                .clipShape(Circle())
        }
    }
    .padding()
}
