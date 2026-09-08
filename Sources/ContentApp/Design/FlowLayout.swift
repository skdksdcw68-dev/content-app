import SwiftUI

/// Lays views out in a row and wraps to the next when it runs out of width.
///
/// SwiftUI has no built-in flow layout, and the usual workaround -- measuring
/// with GeometryReader and slicing the array into rows by hand -- breaks the
/// moment Dynamic Type changes a label's width, quietly, in a way nobody
/// notices for a month.
///
/// This is the `Layout` protocol instead, which is the system's own answer to
/// exactly this. It measures each subview at its ideal size, packs while there
/// is room, and wraps when there is not. Because the sizes come from the
/// subviews rather than from a table of guesses, it stays correct at every text
/// size, in every language, without being told about any of them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = rows(within: width, subviews: subviews)

        let height = rows.reduce(into: CGFloat.zero) { total, row in
            total += row.height
        } + lineSpacing * CGFloat(max(0, rows.count - 1))

        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY

        for row in rows(within: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func rows(within width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)

            // Wrap, unless the row is empty -- a single item wider than the
            // container still has to go somewhere, and an empty row would put
            // it on a line of its own forever.
            if !current.indices.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row()
                x = 0
            }

            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
