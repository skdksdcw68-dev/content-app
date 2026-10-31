import SwiftUI

/// A long job's steps, drawn as one block instead of a message each.
///
/// Netro, 31 Oct 2026, with a screenshot of a dozen "Making picture n of 6"
/// messages, each under its own copy / like / dislike / share row: "can we
/// make it as Claude please?" The shape is the one the good agent apps share
/// (Claude, Perplexity, Bevel): a single header that says what is happening,
/// the step it is on while it works, and the whole timeline one tap away. No
/// buttons -- those belong to the answer, not to the working.
struct ProgressBlock: View {
    let steps: [String]
    /// Still going: the block is the last thing in the conversation.
    let live: Bool

    @State private var open = false

    private var current: Step? { steps.last.map(Step.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if live {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(live ? "Working on it" : "Done in \(steps.count) steps")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        if live, !open, let current {
                            // The step it is on, updating in place.
                            Text(current.text)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(live ? "Working on it. \(current?.text ?? "")" : "Done in \(steps.count) steps")
            .accessibilityHint(open ? "Hides the steps" : "Shows the steps")

            if open {
                Divider().padding(.leading, 42)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, raw in
                        timelineRow(Step(raw), isLast: index == steps.count - 1)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .transition(.opacity)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.2), value: steps.count)
    }

    /// One step: its icon on a thin line that joins it to the next.
    private func timelineRow(_ step: Step, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Group {
                    if isLast && live {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: step.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(step.isWarning ? Color.orange : Color.secondary)
                    }
                }
                .frame(width: 20, height: 18)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            Text(step.text)
                .font(.footnote)
                .foregroundStyle(isLast && live ? Color.primary : Color.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A step's words without the emoji the server leads with, and an icon
    /// that says the same thing at this size.
    private struct Step {
        let text: String
        let symbol: String
        let isWarning: Bool

        /// By the emoji's first code point: "🖼️" is U+1F5BC plus a variation
        /// selector, and as Characters "🖼️".hasPrefix("🖼") is false.
        private static let symbols: [UInt32: String] = [
            0x1F4DD: "list.bullet.clipboard", // 📝
            0x2705: "checkmark.circle",       // ✅
            0x26A0: "exclamationmark.triangle", // ⚠️
            0x1F50E: "magnifyingglass",       // 🔎
            0x1F501: "arrow.clockwise",       // 🔁
            0x1F5BC: "photo",                 // 🖼️
            0x1F39E: "film.stack",            // 🎞️
            0x1F399: "waveform",              // 🎙️
            0x1F3AC: "film",                  // 🎬
        ]

        init(_ raw: String) {
            let lead = raw.unicodeScalars.first?.value ?? 0
            let match = Self.symbols[lead]
            symbol = match ?? "circle"
            isWarning = lead == 0x26A0
            // The emoji (with any variation selector) and the space after it.
            let words = match == nil ? raw : String(raw.drop { !$0.isLetter && !$0.isNumber && $0 != "“" && $0 != "\"" })
            text = words.trimmingCharacters(in: .whitespaces)
        }
    }
}
