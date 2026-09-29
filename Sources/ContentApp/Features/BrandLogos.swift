import SwiftUI

/// The platform logos, drawn rather than shipped, each in its own real shape.
///
/// Abel, 29 Sep 2026: "on the TikTok, Instagram and YouTube logos, could we make
/// them shaped? I want them to be that way." They were not: every mark filled a
/// hard-cornered square, so TikTok was a black box with a music symbol in it,
/// Instagram a gradient box, YouTube a white box with a red one inside. None of
/// them is what its app is. Now each is the shape its app draws:
///
///  - TikTok: the black rounded tile, with the real note -- the curved "d" with
///    the flag -- in the cyan/red split that is the whole identity of the mark.
///  - Instagram: the gradient rounded tile with the camera outline.
///  - YouTube: the wide red rounded rectangle and its play triangle, on nothing.
///    It is not a square, so it sits centred in the square it is given.
///
/// **Drawn in SwiftUI, not imported.** Three reasons, and the first is the one
/// that matters:
///
/// 1. Nothing is bundled as a file. A PNG of a platform's glyph is their file
///    shipped under their brand terms; a path and a rounded rectangle are
///    geometry, drawn here at the proportions the real marks use.
/// 2. It stays sharp at any size, on any screen, with no asset catalogue.
/// 3. It adapts: no white plate for YouTube to fight the dark screen with.
///
/// They are recognisable at 20pt, which is where the rows use them.
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

/// The corner radius app icons use, as a share of the side.
private let iconCorner: CGFloat = 0.225

// MARK: - TikTok

/// The note itself, in a 24-unit box: the curved body, the stem, and the flag.
/// Traced from the mark, not from a font -- no symbol in SF is this shape.
private struct TikTokNote: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        path.move(to: p(12.525, 0.02))
        path.addCurve(to: p(16.435, 0), control1: p(13.835, 0), control2: p(15.135, 0.01))
        path.addCurve(to: p(18.185, 4.17), control1: p(16.515, 1.53), control2: p(17.065, 3.09))
        path.addCurve(to: p(22.425, 5.96), control1: p(19.305, 5.28), control2: p(20.885, 5.79))
        path.addLine(to: p(22.425, 9.99))
        path.addCurve(to: p(18.225, 9.02), control1: p(20.985, 9.94), control2: p(19.535, 9.64))
        path.addCurve(to: p(16.605, 8.09), control1: p(17.655, 8.76), control2: p(17.125, 8.43))
        path.addCurve(to: p(16.585, 16.84), control1: p(16.595, 11.01), control2: p(16.615, 13.93))
        path.addCurve(to: p(15.235, 20.78), control1: p(16.505, 18.24), control2: p(16.045, 19.63))
        path.addCurve(to: p(9.325, 23.99), control1: p(13.925, 22.7), control2: p(11.655, 23.95))
        path.addCurve(to: p(5.245, 22.96), control1: p(7.895, 24.07), control2: p(6.465, 23.68))
        path.addCurve(to: p(1.595, 17.25), control1: p(3.225, 21.77), control2: p(1.805, 19.59))
        path.addCurve(to: p(1.585, 15.76), control1: p(1.575, 16.75), control2: p(1.565, 16.25))
        path.addCurve(to: p(4.165, 10.8), control1: p(1.765, 13.86), control2: p(2.705, 12.04))
        path.addCurve(to: p(10.315, 9.08), control1: p(5.825, 9.36), control2: p(8.145, 8.67))
        path.addCurve(to: p(10.275, 13.52), control1: p(10.335, 10.56), control2: p(10.275, 12.04))
        path.addCurve(to: p(7.255, 13.89), control1: p(9.285, 13.2), control2: p(8.125, 13.29))
        path.addCurve(to: p(5.895, 15.64), control1: p(6.625, 14.3), control2: p(6.145, 14.93))
        path.addCurve(to: p(5.755, 17.25), control1: p(5.685, 16.15), control2: p(5.745, 16.71))
        path.addCurve(to: p(9.255, 20.12), control1: p(5.995, 18.89), control2: p(7.575, 20.27))
        path.addCurve(to: p(12.025, 18.51), control1: p(10.375, 20.11), control2: p(11.445, 19.46))
        path.addCurve(to: p(12.435, 17.45), control1: p(12.215, 18.18), control2: p(12.425, 17.84))
        path.addCurve(to: p(12.505, 12.09), control1: p(12.535, 15.66), control2: p(12.495, 13.88))
        path.addCurve(to: p(12.525, 0.02), control1: p(12.515, 8.06), control2: p(12.495, 4.04))
        path.closeSubpath()
        return path
    }
}

/// The tile, and the note in TikTok's chromatic offset: a cyan copy up-left, a
/// red copy down-right, the white note over both. That split is the identity;
/// drawn in one colour it reads as a generic music note.
private struct TikTokMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let note = side * 0.56

            ZStack {
                RoundedRectangle(cornerRadius: side * iconCorner, style: .continuous)
                    .fill(Color.black)
                    .frame(width: side, height: side)
                    // A whisper of edge, so the black tile still reads on a
                    // dark screen.
                    .overlay {
                        RoundedRectangle(cornerRadius: side * iconCorner, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    }

                ZStack {
                    TikTokNote()
                        .fill(Color(red: 0.16, green: 0.95, blue: 0.93))
                        .offset(x: -side * 0.030, y: -side * 0.022)

                    TikTokNote()
                        .fill(Color(red: 1.0, green: 0.15, blue: 0.35))
                        .offset(x: side * 0.030, y: side * 0.022)

                    TikTokNote()
                        .fill(Color.white)
                }
                .frame(width: note, height: note)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - Instagram

/// The camera outline: a rounded square, a circle inside it, a dot in the top
/// right -- over the corner-to-corner gradient that runs yellow through pink to
/// purple, on the rounded tile the app icon is. Every part of that is geometry,
/// which is why it draws cleanly.
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
            let inset = side * 0.26
            let stroke = side * 0.075

            ZStack {
                RoundedRectangle(cornerRadius: side * iconCorner, style: .continuous)
                    .fill(Self.gradient)
                    .frame(width: side, height: side)

                RoundedRectangle(cornerRadius: side * 0.17, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: stroke)
                    .frame(width: side - inset, height: side - inset)

                Circle()
                    .strokeBorder(Color.white, lineWidth: stroke)
                    .frame(width: side * 0.30, height: side * 0.30)

                Circle()
                    .fill(Color.white)
                    .frame(width: side * 0.075, height: side * 0.075)
                    .offset(x: side * 0.175, y: -side * 0.175)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - YouTube

/// The red rounded rectangle with a white play triangle.
///
/// On nothing. It used to sit on a white square "so a wide badge is not cropped
/// into a circle" -- which made the mark a white box with a red one in it. The
/// real mark is the red shape alone, about 1.43 wide for every 1 tall, so that
/// is what is drawn, centred in whatever square it is given.
private struct YouTubeMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let height = side * 0.70

            ZStack {
                RoundedRectangle(cornerRadius: height * 0.30, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.0, blue: 0.0))
                    .frame(width: side, height: height)

                Triangle()
                    .fill(Color.white)
                    .frame(width: height * 0.34, height: height * 0.40)
                    .offset(x: height * 0.03)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
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
                .frame(width: 56, height: 56)
        }
    }
    .padding()
}
