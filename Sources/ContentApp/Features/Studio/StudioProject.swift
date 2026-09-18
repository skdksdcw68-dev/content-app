import Foundation

/// Everything the editor knows about one video being made: the clips in order,
/// the music, the look and the text. A value type, so undo is a copy.
///
/// Times are in seconds. A clip's `trimStart`/`trimEnd` are in its SOURCE
/// time; its length on the timeline is the trimmed length divided by speed.
struct StudioProject: Equatable, Sendable {
    var clips: [StudioClip]
    var music: StudioMusic?
    /// The clips' own sound, before each clip's volume.
    var originalVolume: Float = 1
    var filter: StudioFilter = .none
    var filterIntensity: Double = 1
    var adjust = StudioAdjust()
    var texts: [StudioText] = []

    /// Photos show this long when added.
    static let photoSeconds: Double = 3
    /// Photos are rendered this long, so a photo can be stretched up to it.
    static let photoMaxSeconds: Double = 10
    /// Nothing is cut shorter than this.
    static let shortest: Double = 0.2

    var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    /// Where a clip starts on the timeline.
    func start(of index: Int) -> Double {
        clips.prefix(index).reduce(0) { $0 + $1.duration }
    }

    /// The clip under a timeline time, and how far into it.
    func clip(at time: Double) -> (index: Int, offset: Double)? {
        guard !clips.isEmpty else { return nil }
        var cursor = 0.0
        for (index, clip) in clips.enumerated() {
            if time < cursor + clip.duration || index == clips.count - 1 {
                return (index, min(max(0, time - cursor), clip.duration))
            }
            cursor += clip.duration
        }
        return nil
    }

    // MARK: - Edits

    /// Cuts the clip under `time` in two. Refused within `shortest` of an end.
    @discardableResult
    mutating func split(at time: Double) -> Bool {
        guard let (index, offset) = clip(at: time) else { return false }
        let clip = clips[index]
        let sourceCut = clip.trimStart + offset * clip.speed
        guard sourceCut - clip.trimStart >= Self.shortest, clip.trimEnd - sourceCut >= Self.shortest else { return false }
        var first = clip
        first.trimEnd = sourceCut
        var second = clip
        second.id = UUID()
        second.trimStart = sourceCut
        clips.replaceSubrange(index...index, with: [first, second])
        return true
    }

    /// Sets a clip's trim, kept inside its source and at least `shortest` long.
    mutating func trim(_ id: UUID, start: Double, end: Double) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let limit = clips[index].sourceDuration
        var s = min(max(0, start), limit - Self.shortest)
        var e = min(max(end, s + Self.shortest), limit)
        if e - s < Self.shortest { s = max(0, e - Self.shortest); e = s + Self.shortest }
        clips[index].trimStart = s
        clips[index].trimEnd = e
    }

    mutating func setSpeed(_ id: UUID, _ speed: Double) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].speed = min(max(speed, 0.3), 3)
    }

    mutating func setVolume(_ id: UUID, _ volume: Float) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].volume = min(max(volume, 0), 2)
    }

    /// Moves a clip one place left (-1) or right (+1).
    mutating func move(_ id: UUID, by step: Int) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let target = index + step
        guard clips.indices.contains(target) else { return }
        clips.swapAt(index, target)
    }

    /// Removes a clip. The last one stays: an empty project is not a video.
    mutating func remove(_ id: UUID) {
        guard clips.count > 1 else { return }
        clips.removeAll { $0.id == id }
        // Text that now starts after the end is pulled back in.
        let end = duration
        for index in texts.indices where texts[index].start >= end {
            texts[index].start = max(0, end - 1)
        }
    }
}

struct StudioClip: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case video, photo }

    var id = UUID()
    var kind: Kind
    /// A local file: the original video, or the photo as JPEG.
    var url: URL
    /// The whole source's length. For a photo, `StudioProject.photoMaxSeconds`.
    var sourceDuration: Double
    var trimStart: Double = 0
    var trimEnd: Double
    var speed: Double = 1
    var volume: Float = 1

    var trimmedLength: Double { max(0, trimEnd - trimStart) }
    /// Length on the timeline.
    var duration: Double { trimmedLength / speed }

    static func video(_ url: URL, duration: Double) -> StudioClip {
        StudioClip(kind: .video, url: url, sourceDuration: duration, trimEnd: duration)
    }

    static func photo(_ url: URL) -> StudioClip {
        StudioClip(kind: .photo, url: url, sourceDuration: StudioProject.photoMaxSeconds, trimEnd: StudioProject.photoSeconds)
    }
}

/// A track under the video.
struct StudioMusic: Equatable, Sendable {
    var title: String
    var artist: String
    /// Credit the licence asks for, added to the description. Nil for the
    /// person's own audio.
    var attribution: String?
    var fileURL: URL
    var trackDuration: Double
    /// Where in the track the video starts.
    var startOffset: Double = 0
    var volume: Float = 0.8
}

enum StudioFilter: String, CaseIterable, Identifiable, Sendable {
    case none, vivid, warm, cool, mono, fade, noir, film

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:  "Normal"
        case .vivid: "Vivid"
        case .warm:  "Warm"
        case .cool:  "Cool"
        case .mono:  "Mono"
        case .fade:  "Fade"
        case .noir:  "Noir"
        case .film:  "Film"
        }
    }
}

struct StudioAdjust: Equatable, Sendable {
    /// -0.3 ... 0.3
    var brightness: Double = 0
    /// 0.5 ... 1.5
    var contrast: Double = 1
    /// 0 ... 2
    var saturation: Double = 1
    /// -1 (cooler) ... 1 (warmer)
    var warmth: Double = 0

    var isNeutral: Bool { self == StudioAdjust() }
}

struct StudioText: Identifiable, Equatable, Sendable {
    enum Style: String, CaseIterable, Sendable { case classic, bold, outline, label }

    var id = UUID()
    var text: String
    var style: Style = .bold
    /// "#RRGGBB"
    var color: String = "#FFFFFF"
    /// Centre of the text, as a fraction of the frame (0,0 top left).
    var x: Double = 0.5
    var y: Double = 0.5
    /// Font size as a fraction of the frame's height.
    var size: Double = 0.045
    var start: Double = 0
    /// Nil shows it to the end.
    var end: Double?

    func isVisible(at time: Double) -> Bool {
        time >= start && time < (end ?? .infinity)
    }
}

/// Undo and redo as copies of the project.
struct EditHistory<Value: Equatable> {
    private(set) var past: [Value] = []
    private(set) var future: [Value] = []
    private let limit = 50

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Call with the value from BEFORE a change.
    mutating func record(_ before: Value) {
        if past.last == before { return }
        past.append(before)
        if past.count > limit { past.removeFirst() }
        future.removeAll()
    }

    mutating func undo(_ current: Value) -> Value? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    mutating func redo(_ current: Value) -> Value? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }
}
