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
            var turns = rows.map { $0.asTurn }

            // An offer or a question somebody already replied to is settled,
            // not live. Left tappable, a reopened model picker would start a
            // second generation -- on somebody's own credits -- for a request
            // that was already made.
            for index in turns.indices where turns[index].role == .assistant {
                guard let reply = turns[(index + 1)...].first(where: { $0.role == .user }) else { continue }
                if turns[index].offer != nil {
                    turns[index].chosenModel = settledChoice(reply.text)
                }
                for question in turns[index].questions {
                    turns[index].answered[question.key] = "Answered"
                }
            }
            return turns
        } catch {
            return []
        }
    }


    /// The reply to a model offer, said as the choice it was. "Use Kling 2.1."
    /// becomes "Kling 2.1"; "You choose." becomes "Auto".
    private func settledChoice(_ reply: String) -> String {
        var said = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.hasPrefix("You choose") { return "Auto" }
        if said.hasPrefix("Use ") { said.removeFirst(4) }
        if said.hasSuffix(".") { said.removeLast() }
        return said.isEmpty ? "Chosen" : said
    }

    /// What the stream can say. One case per server event, so a line we do not
    /// understand is a gap rather than a silently wrong branch.
    enum ChatEvent {
        case step(TaskStep)
        case delta(String)
        case thread(UUID)
        /// Questions to answer, with the request and length they were asked
        /// for, so the answers can go straight on to a strategy.
        case questions([ChatQuestion], request: String?, days: Int?)
        /// Something made on this turn, drawn as its card.
        case artifact(UUID)
        /// The models that can do it, with the request they were offered for.
        case models(ModelOffer, request: String?, references: [String])
        case chose(ModelChoice)
        /// Long work handed to the worker. The card follows it from here.
        case run(UUID, kind: String)
        case failed(String)
    }

    /// What a button asked for, sent as data rather than as a sentence.
    ///
    /// A tap on "PDF" knows exactly what it means. Sending it as the words
    /// "export it as a PDF" and hoping the router reads them back the same way
    /// works until it does not, and then the tap does something else.
    enum ChatAction {
        case export(artifact: UUID, format: String)
        case generate(capability: String, prompt: String, model: String?, references: [String])
        case animate(artifact: UUID)
        /// Every question on a card, answered by tapping -- as values.
        case answers([String: String], request: String?, days: Int?)

        var payload: [String: Any] {
            switch self {
            case .export(let artifact, let format):
                return ["type": "export", "artifactId": artifact.uuidString, "format": format]
            case .generate(let capability, let prompt, let model, let references):
                var out: [String: Any] = [
                    "type": "generate", "capability": capability,
                    "prompt": prompt, "references": references,
                ]
                if let model { out["model"] = model }
                return out
            case .animate(let artifact):
                return ["type": "animate", "artifactId": artifact.uuidString]
            case .answers(let answers, let request, let days):
                var out: [String: Any] = ["type": "answers", "answers": answers]
                if let request { out["request"] = request }
                if let days { out["days"] = days }
                return out
            }
        }
    }

    /// Sends the conversation and calls `onEvent` as each piece arrives.
    ///
    /// Cancellation is the caller's: cancelling the enclosing task stops the
    /// read, which drops the connection, which is what the stop button is for.
    func streamReply(
        for turns: [ChatMessage],
        in thread: UUID? = nil,
        action: ChatAction? = nil,
        attachments: [String] = [],
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
        if let action { body["action"] = action.payload }
        if !attachments.isEmpty { body["attachments"] = attachments }
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
                struct Offer: Decodable {
                    let choices: ModelOffer
                    let request: String?
                    let references: [String]?
                }
                struct Chose: Decodable { let choice: ModelChoice? }
                if kind == "models", let frame = try? JSONDecoder().decode(Offer.self, from: data) {
                    onEvent(.models(frame.choices, request: frame.request, references: frame.references ?? []))
                } else if let frame = try? JSONDecoder().decode(Chose.self, from: data), let choice = frame.choice {
                    onEvent(.chose(choice))
                }
                continue
            }

            if kind == "run", let id = event["id"] as? String, let uuid = UUID(uuidString: id) {
                onEvent(.run(uuid, kind: event["kind"] as? String ?? "run"))
                continue
            }

            if kind == "questions" {
                struct Frame: Decodable {
                    let questions: [ChatQuestion]
                    let request: String?
                    let days: Int?
                }
                if let frame = try? JSONDecoder().decode(Frame.self, from: data) {
                    onEvent(.questions(frame.questions, request: frame.request, days: frame.days))
                }
                continue
            }

            if kind == "artifact", let id = event["id"] as? String, let uuid = UUID(uuidString: id) {
                onEvent(.artifact(uuid))
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
        let request: String?
        let references: [String]?
        let runId: UUID?
        let runKind: String?
        let artifactId: UUID?
        let paths: [String]?
        let days: Int?

        private enum CodingKeys: String, CodingKey {
            case kind, questions, choices, request, references, paths, days
            case runId = "run_id"
            case runKind = "run_kind"
            case artifactId = "artifact_id"
        }
    }

    var asTurn: ChatMessage {
        var turn = ChatMessage(role: role == "user" ? .user : .assistant, text: text)
        turn.questions = renderHint?.questions ?? []
        turn.offer = renderHint?.choices
        turn.offerRequest = renderHint?.request
        turn.offerReferences = renderHint?.references ?? []
        turn.questionRequest = renderHint?.request
        turn.questionDays = renderHint?.days
        turn.runId = renderHint?.runId
        turn.runKind = renderHint?.runKind
        turn.artifactId = renderHint?.artifactId
        turn.attachments = renderHint?.paths ?? []
        return turn
    }
}
