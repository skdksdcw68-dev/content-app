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

    /// Saved conversations, newest activity first.
    func threads() async -> [ChatThread] {
        do {
            return try await client.rpc("my_threads").execute().value
        } catch {
            return []
        }
    }

    /// One conversation, replayed.
    ///
    /// Read from the server rather than kept in the view, which is what makes a
    /// conversation survive the app being closed -- and what lets a long job
    /// finishing while you were away be there when you come back.
    func messages(in thread: UUID) async -> [ChatMessage] {
        do {
            let rows: [StoredMessage] = try await client
                .rpc("thread_messages", params: ["p_thread": thread.uuidString])
                .execute()
                .value
            // An explicit closure rather than a key path. The key path form is
            // tidier and its backslash has now been eaten four times by shell
            // escaping in this project, which is a good enough reason.
            return rows.map { $0.asTurn }
        } catch {
            return []
        }
    }


    /// What the stream can say. One case per server event, so a line we do not
    /// understand is a gap rather than a silently wrong branch.
    enum ChatEvent {
        case step(TaskStep)
        case delta(String)
        case thread(UUID)
        case questions([ChatQuestion])
        case models(ModelOffer)
        case chose(ModelChoice)
        case failed(String)
    }

    /// Sends the conversation and calls `onEvent` as each piece arrives.
    ///
    /// Cancellation is the caller's: cancelling the enclosing task stops the
    /// read, which drops the connection, which is what the stop button is for.
    func streamReply(
        for turns: [ChatMessage],
        in thread: UUID? = nil,
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

        var body: [String: Any] = ["messages": payload]
        if let thread { body["threadId"] = thread.uuidString }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

            // Decoded from the original bytes rather than from the dictionary
            // above: re-encoding a parsed `Any` back to JSON to decode it again
            // is two conversions that can each lose a type.
            if kind == "models" || kind == "chose" {
                // Decoded from the original bytes for the same reason the
                // questions frame is: re-encoding a parsed `Any` back to JSON
                // to decode it again is two conversions that can each lose a
                // type, and this payload has doubles and optionals in it.
                struct Offer: Decodable { let choices: ModelOffer }
                struct Chose: Decodable { let choice: ModelChoice? }
                if kind == "models", let frame = try? JSONDecoder().decode(Offer.self, from: data) {
                    onEvent(.models(frame.choices))
                } else if let frame = try? JSONDecoder().decode(Chose.self, from: data), let choice = frame.choice {
                    onEvent(.chose(choice))
                }
                continue
            }

            if kind == "questions" {
                struct Frame: Decodable { let questions: [ChatQuestion] }
                if let frame = try? JSONDecoder().decode(Frame.self, from: data) {
                    onEvent(.questions(frame.questions))
                }
                continue
            }

            if kind == "thread", let id = event["id"] as? String, let uuid = UUID(uuidString: id) {
                onEvent(.thread(uuid))
                continue
            }

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

/// A stored turn, as `thread_messages` returns it.
///
/// Rebuilt into a `ChatMessage` rather than decoded straight into one, because
/// the two are different things: the transcript keeps what was said, while a
/// live turn also carries the pending state and the steps of the reply being
/// written. Anything transient is deliberately not restored -- a step that
/// finished yesterday is not still happening.
private struct StoredMessage: Decodable {
    let seq: Int
    let role: String
    let text: String
    let renderHint: RenderHint?

    private enum CodingKeys: String, CodingKey {
        case seq, role, text
        case renderHint = "render_hint"
    }

    /// What the server attached to this turn, when it was more than prose.
    struct RenderHint: Decodable {
        let kind: String?
        let questions: [ChatQuestion]?
        let choices: ModelOffer?
    }

    var asTurn: ChatMessage {
        var turn = ChatMessage(role: role == "user" ? .user : .assistant, text: text)
        turn.questions = renderHint?.questions ?? []
        turn.offer = renderHint?.choices
        return turn
    }
}
