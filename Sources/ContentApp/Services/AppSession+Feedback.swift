import Foundation
import Supabase

extension AppSession {
    /// Keeps a like or dislike with what was asked and what was answered, so
    /// the bad answers can be read and the prompts fixed against them (0041).
    /// Quiet on failure: a rating that did not save is not worth an alert.
    func rateReply(thread: UUID?, asked: String?, reply: String, rating: String, reason: String?) async {
        struct Row: Encodable, Sendable {
            let thread_id: String?
            let asked: String?
            let reply: String
            let rating: String
            let reason: String?
        }
        do {
            try await client
                .from("chat_feedback")
                .insert(Row(
                    thread_id: thread?.uuidString,
                    asked: asked,
                    reply: String(reply.prefix(8000)),
                    rating: rating,
                    reason: reason
                ))
                .execute()
        } catch {
            // Deliberately silent.
        }
    }
}
