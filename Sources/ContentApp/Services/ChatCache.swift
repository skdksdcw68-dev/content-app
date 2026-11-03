import Foundation

/// Conversations kept on the phone, exactly as the server last sent them.
///
/// A reopened chat is drawn from here at once and then checked against the
/// server, instead of showing a spinner while every message is fetched again.
/// Kept in Caches: the server holds the real copy, so nothing is lost if iOS
/// clears it. Wiped on sign-out so the next person never sees these.
@MainActor
final class ChatCache {
    static let shared = ChatCache()

    private var memory: [UUID: Data] = [:]

    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Chats", isDirectory: true)

    private func file(_ thread: UUID) -> URL {
        folder.appendingPathComponent("\(thread.uuidString).json")
    }

    func read(_ thread: UUID) -> Data? {
        if let data = memory[thread] { return data }
        guard let data = try? Data(contentsOf: file(thread)) else { return nil }
        memory[thread] = data
        return data
    }

    func write(_ data: Data, for thread: UUID) {
        memory[thread] = data
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(thread), options: .atomic)
    }

    func remove(_ thread: UUID) {
        memory[thread] = nil
        try? FileManager.default.removeItem(at: file(thread))
    }

    func removeAll() {
        memory = [:]
        try? FileManager.default.removeItem(at: folder)
    }
}
