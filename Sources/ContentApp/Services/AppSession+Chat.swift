import Foundation
import Supabase

/// Talking to the agent, one token at a time.
///
/// `functions.invoke` decodes a whole response, which is the wrong shape for a
/// conversation: the reply arrives over several seconds and a person watching a
/// spinner for all of them has no idea whether anything is happening. So this
/// goes to the function directly with `URLSession.bytes` and reads the
/// server-sent events as they land.
///
/// The events are ours, not OpenAI's -- `agent-chat` unwraps their format and
/// re-emits `step`, `delta`, `error` and `done`. The app never learns their
/// event shape, which is what keeps a provider change from reaching this file.
///
/// Deliberately a callback rather than an `AsyncThrowingStream`. The whole type
/// is `@MainActor` and the project builds with strict concurrency: a stream's
/// builder closure would carry `self` across an isolation boundary and the
/// callback does not, because it is non-escaping and runs inside a method that
/// never leaves the main actor. Same shape at the call site, no `Sendable`.
extension AppSession {

    /// What the stream can say. One case per server event, so a line we do not
    /// understand is a gap rather than a silently wrong branch.
    enum ChatEvent {
        case step(TaskStep)
        case delta(String)
        case failed(String)
    }

    /// Sends the conversation and calls `onEvent` as each piece arrives.
    ///
    /// Cancellation is the caller's: cancelling the enclosing task stops the
    /// read, which drops the connection, which is what the stop button is for.
    func streamReply(
        for turns: [ChatMessage],
        onEvent: (ChatEvent) -> Void
    ) async throws {
        let token = try await client.auth.session.accessToken

        var request = URLRequest(
            url: Config.supabaseURL.appendingPathComponent("functions/v1/agent-chat")
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The reply is written as it streams; the default 60s can fire between
        // two tokens of a long answer.
        request.timeoutInterval = 120

        let payload = turns
            .filter { !$0.isPending && !$0.failed && !$0.text.isEmpty }
            .map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] }

        request.httpBody = try JSONSerialization.data(withJSONObject: ["messages": payload])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            onEvent(.failed(
                http.statusCode == 401
                    ? "Sign in again to keep chatting."
                    : "The agent could not be reached just now."
            ))
            return
        }

        for try await line in bytes.lines {
            if Task.isCancelled { return }
            guard line.hasPrefix("data: ") else { continue }

            guard let data = String(line.dropFirst(6)).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = event["t"] as? String
            else { continue }

            switch kind {
            case "delta":
                if let value = event["v"] as? String { onEvent(.delta(value)) }
            case "step":
                if let detail = event["detail"] as? String {
                    let name = event["kind"] as? String ?? "reading"
                    onEvent(.step(TaskStep(
                        kind: TaskStep.Kind(rawValue: name) ?? .reading,
                        detail: detail
                    )))
                }
            case "error":
                onEvent(.failed(event["message"] as? String ?? "Something went wrong."))
            case "done":
                return
            default:
                break
            }
        }
    }
}
