import SwiftUI
import UIKit

/// Text you can select part of, the way you can in Messages or Notes.
///
/// Abel, 17 Sep 2026: in Chat, "let them select the text response". SwiftUI's
/// `.textSelection(.enabled)` only copies the whole block on iOS; a read-only
/// UITextView gives the real handles, so a sentence can be picked out of an
/// answer. It sizes itself to the width it is given and never scrolls.
struct SelectableText: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .body
    var color: UIColor = .label

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = [.link]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.attributedText = attributed
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Streaming updates this many times a second; only touch it on change.
        if view.attributedText.string != text {
            view.attributedText = attributed
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    private var attributed: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: textStyle),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}
