import SwiftUI

/// The percentage while something is being made.
///
/// Abel, 26 Sep 2026: "while generating its better to set it as a 100% thing?
/// so it counts from 0 to 100 which is a psychologycal game".
///
/// 🔴 AND THE HONEST VERSION OF THAT, because `Loaders.swift` opens with a
/// rule against inventing percentages and it is a good rule. fal reports
/// `IN_QUEUE` and `IN_PROGRESS` and nothing in between -- there is no measured
/// fraction to show, and pretending otherwise is how a progress bar ends up
/// sitting at 80% for a minute.
///
/// So this counts TIME, not work, and never claims to be finished. It is an
/// estimate against how long this kind of generation usually takes -- measured,
/// not guessed: a 5-second Wan clip took 101 seconds end to end on 25 Sep. The
/// curve eases so it moves quickly at first and slows as it approaches, and it
/// stops at 99. The thing arriving is the hundred, because that is the only
/// moment anybody actually knows.
///
/// When a film of several shots exists, this gets replaced by a real fraction:
/// clip three of eight finished IS 37%, and nothing has to be estimated.
struct MakingProgress: View {
    /// How long this kind of thing usually takes, in seconds.
    let expected: TimeInterval
    var compact = false

    @State private var began = Date.now

    /// Eases towards the estimate without ever arriving. At `expected` it
    /// reads about 90; twice that, about 99. A job running long slows down
    /// rather than stalling on a number it already claimed.
    private func percent(at now: Date) -> Int {
        let elapsed = max(0, now.timeIntervalSince(began))
        let curve = 1 - exp(-elapsed / max(1, expected * 0.43))
        return min(99, Int(curve * 100))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            Text("\(percent(at: context.date))%")
                .font(compact
                      ? .caption.weight(.semibold).monospacedDigit()
                      : .title3.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: percent(at: context.date))
        }
        .accessibilityLabel("Making it")
    }
}

extension MakingProgress {
    /// Roughly how long each kind takes, from what this app has actually seen
    /// rather than from a provider's marketing. A 5-second Wan video measured
    /// 101 seconds on 25 Sep 2026; images come back in a fraction of that.
    static func expected(for kind: String?) -> TimeInterval {
        switch kind {
        case "image": return 18
        case "audio": return 30
        default:      return 110
        }
    }
}
