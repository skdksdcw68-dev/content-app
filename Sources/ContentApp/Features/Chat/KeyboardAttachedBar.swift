import SwiftUI
import UIKit

/// Pins a SwiftUI bar to the top of the system keyboard, from UIKit.
///
/// The bar's vertical position is computed from the keyboard's own frame, in
/// window coordinates, every time the keyboard says it is about to move, and
/// applied inside the keyboard's own animation curve and duration. Nothing
/// about SwiftUI's layout, safe area or keyboard avoidance is involved in
/// where the bar goes, which is the point: every version that leaned on any
/// of those either jumped or ended up behind the keyboard.
///
/// What was tried and why it is not here:
///
/// - `safeAreaInset`: the keyboard changed the safe area, the ScrollView
///   relaid out, SwiftUI recomputed the composer, and only then did it move.
///   Measured drifting 8pt to 40pt from the keyboard mid-dismissal.
/// - `UIKeyboardLayoutGuide`: the right idea, and on this device inside a
///   SwiftUI-hosted controller it did not track. Screenshots with the
///   keyboard up showed no bar at all -- it was sitting at the bottom of the
///   screen, under the keyboard, exactly where a guide that never moved
///   would leave it.
///
/// Rules that still hold:
///
/// 1. The host is exactly as tall as the bar and only its bottom is
///    positioned, so the keyboard moves the host rather than resizing it.
///    Resizing a UIKit host with SwiftUI content inside makes the content
///    snap to the final layout while the container animates.
///
/// 2. The host's height comes from SwiftUI's own measurement of the bar at
///    its real width. Intrinsic content size measures at an unconstrained
///    width, where a vertical text field is always one line.
///
/// 3. The hosted view is rebuilt only when `inputs` change, not on every
///    streamed token.
///
/// `height` comes back out -- the bar's own height -- so the content behind
/// it can leave room and the empty page can centre above it.
struct KeyboardAttachedBar<Bar: View, Inputs: Equatable>: UIViewControllerRepresentable {
    @Binding var height: CGFloat
    let inputs: Inputs
    let bar: Bar

    init(height: Binding<CGFloat>, inputs: Inputs, @ViewBuilder bar: () -> Bar) {
        _height = height
        self.inputs = inputs
        self.bar = bar()
    }

    func makeUIViewController(context: Context) -> KeyboardBarController {
        KeyboardBarController()
    }

    func updateUIViewController(_ controller: KeyboardBarController, context: Context) {
        // Off the current update, so a layout pass never writes SwiftUI
        // state while SwiftUI is still evaluating a body.
        controller.onHeightChange = { measured in
            DispatchQueue.main.async {
                if abs(height - measured) > 0.5 { height = measured }
            }
        }

        if let last = controller.lastInputs as? Inputs, last == inputs { return }
        controller.lastInputs = inputs
        controller.hosting.rootView = AnyView(
            BarHost(bar: bar) { [weak controller] measured in
                controller?.report(height: measured)
            }
        )
    }
}

/// Owns the hosted bar and the two constraints that matter: where its
/// bottom is, and how tall it is.
final class KeyboardBarController: UIViewController {
    let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    var onHeightChange: ((CGFloat) -> Void)?
    var lastInputs: Any?

    /// Measured from ChatGPT: about 12pt above the keyboard when it is up,
    /// resting closer to the home indicator when it is down.
    static let keyboardGap: CGFloat = 12
    static let restingGap: CGFloat = 8

    private var bottomOffset: NSLayoutConstraint?
    private var height: NSLayoutConstraint?
    /// The keyboard's frame in screen coordinates, nil while it is hidden.
    private var keyboardFrame: CGRect?
    private var observers: [NSObjectProtocol] = []
    private var barHeight: CGFloat = 0

    override func loadView() {
        view = PassthroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        hosting.view.backgroundColor = .clear
        // We place the bar above the keyboard ourselves; the hosting
        // controller must not also inset for it.
        hosting.safeAreaRegions = .container

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        // Starts at the resting capsule's height; SwiftUI reports the real
        // number on its first layout and every time the bar grows or shrinks.
        let height = hosting.view.heightAnchor.constraint(equalToConstant: 54)
        let bottomOffset = hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)
        self.height = height
        self.bottomOffset = bottomOffset
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomOffset,
            height,
        ])
        hosting.didMove(toParent: self)

        (view as? PassthroughView)?.interactiveBand = { [weak self] in
            self?.hosting.view.frame ?? .zero
        }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
                self?.keyboardWillChange(note)
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
                self?.keyboardFrame = nil
                self?.place(with: note)
            },
            // The keyboard leaves with the app and does not always say so.
            // Forgetting its frame here is what stops the bar coming back
            // from another app floating in the middle of the screen.
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.keyboardFrame = nil
                self?.updateOffset()
            },
        ]
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Our own frame or safe area changed: re-place without animating.
        if updateOffset() { view.setNeedsLayout() }
    }

    /// SwiftUI measured the bar. The host follows, so the bar is never
    /// squeezed into a smaller frame than it asked for.
    func report(height measured: CGFloat) {
        guard measured > 0, abs(measured - barHeight) > 0.5 else { return }
        barHeight = measured
        height?.constant = measured
        view.setNeedsLayout()
        onHeightChange?(measured)
    }

    // MARK: - Placing

    /// Where the bar's bottom belongs right now: above the keyboard if it
    /// covers any of this view, above the home indicator otherwise.
    private func targetOffset() -> CGFloat {
        if let keyboardFrame {
            let keyboardTop = view.convert(keyboardFrame, from: nil).minY
            let covered = view.bounds.maxY - keyboardTop
            if covered > 0 { return -(covered + Self.keyboardGap) }
        }
        return -(view.safeAreaInsets.bottom + Self.restingGap)
    }

    @discardableResult
    private func updateOffset() -> Bool {
        guard let bottomOffset else { return false }
        let target = targetOffset()
        guard abs(bottomOffset.constant - target) > 0.5 else { return false }
        bottomOffset.constant = target
        return true
    }

    private func keyboardWillChange(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = view.window
        else { return }
        // A frame that starts at or below the bottom of the screen is the
        // keyboard leaving, whatever the notification is called.
        keyboardFrame = end.minY < window.bounds.maxY ? end : nil
        place(with: note)
    }

    /// Moves the bar on the keyboard's own timing, so the two are one motion.
    private func place(with note: Notification) {
        guard updateOffset() else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curve << 16))
        ) {
            self.view.layoutIfNeeded()
        }
    }
}

/// A full-screen host whose only tappable region is the bar itself. A touch
/// anywhere else falls through to the conversation underneath, which is what
/// lets "tap the chat to put the keyboard away" keep working.
private final class PassthroughView: UIView {
    var interactiveBand: () -> CGRect = { .zero }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard interactiveBand().contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// The bar at its own ideal height, bottom-aligned in the host, reporting
/// that height back.
///
/// `fixedSize` in the vertical axis is what makes a new line grow the bar:
/// the bar takes the height its content wants regardless of what the host
/// currently offers, the measurement goes to UIKit, and the host catches up
/// a frame later. Bottom-aligned so that catching up happens at the top
/// edge, where nothing is looking, and the buttons never leave the bottom.
private struct BarHost<Bar: View>: View {
    let bar: Bar
    let onHeight: (CGFloat) -> Void

    var body: some View {
        bar
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: BarHeightKey.self, value: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onPreferenceChange(BarHeightKey.self, perform: onHeight)
    }
}

private struct BarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
