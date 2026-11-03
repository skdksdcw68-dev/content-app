import SwiftUI

/// The sites a piece of research has read: their logos in a row, overlapping,
/// with how many there are -- the way ChatGPT shows its sources while it works.
struct SourceLogos: View {
    let domains: [String]

    var body: some View {
        HStack(spacing: 8) {
            SiteIcons(domains: domains)
            Text(domains.count == 1 ? "1 source" : "\(domains.count) sources")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Read \(domains.count) sites")
    }
}

/// Site logos in a row, each tucked under the one before it.
struct SiteIcons: View {
    let domains: [String]
    var size: CGFloat = 22
    var limit = 6

    var body: some View {
        HStack(spacing: -size * 0.27) {
            ForEach(Array(domains.prefix(limit).enumerated()), id: \.element) { index, domain in
                SiteIcon(domain: domain, size: size)
                    .zIndex(Double(domains.count - index))
            }
        }
    }
}

/// One site's logo in a circle, or a globe until it loads (or if it has none).
struct SiteIcon: View {
    let domain: String
    var size: CGFloat = 22

    var body: some View {
        AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                Image(systemName: "globe")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.systemBackground), in: Circle())
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}
