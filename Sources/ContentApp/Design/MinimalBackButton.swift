import SwiftUI

extension View {
    /// The back arrow alone, without the previous page's title beside it.
    ///
    /// SwiftUI has no modifier for it; UIKit's `backButtonDisplayMode` on the
    /// pushed page's navigation item does it, so a marker view reaches that
    /// item from inside the page.
    func minimalBackButton() -> some View {
        background { MinimalBackButtonMarker() }
    }
}

private struct MinimalBackButtonMarker: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Marker { Marker() }

    func updateUIViewController(_ controller: Marker, context: Context) {}

    final class Marker: UIViewController {
        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            parent?.navigationItem.backButtonDisplayMode = .minimal
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            parent?.navigationItem.backButtonDisplayMode = .minimal
        }
    }
}
