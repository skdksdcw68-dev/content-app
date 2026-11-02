import SwiftUI

/// The sites a piece of research has read: their logos in a row, overlapping,
/// with how many there are -- the way ChatGPT shows its sources while it works.
struct SourceLogos: View {
    let domains: [String]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: -6) {
                ForEach(Array(domains.prefix(6).enumerated()), id: \.element) { index, domain in
                    logo(domain)
                        .zIndex(Double(domains.count - index))
                }
            }
            Text(domains.count == 1 ? "1 source" : "\(domains.count) sources")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Read \(domains.count) sites")
    }

    private func logo(_ domain: String) -> some View {
        AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                Image(systemName: "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .background(Color(.systemBackground), in: Circle())
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}
