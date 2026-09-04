import SwiftUI

/// The tinted capsule on a row. Colour carries the same meaning everywhere:
/// grey is waiting on the autopilot, blue is waiting on a clock, green is
/// done, red needs a person.
struct StatusBadge: View {
    let status: PostStatus

    var body: some View {
        Label(status.displayName, systemImage: status.symbolName)
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Self.tint(for: status).opacity(0.15), in: Capsule())
            .foregroundStyle(Self.tint(for: status))
    }

    static func tint(for status: PostStatus) -> Color {
        switch status {
        case .planned:   return .secondary
        case .scripted:  return .indigo
        case .rendering: return .purple
        case .scheduled: return .blue
        case .posted:    return .green
        case .failed:    return .red
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(PostStatus.allCases) { StatusBadge(status: $0) }
    }
    .padding()
}
