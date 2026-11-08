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

    /// Saved conversations for the app being looked at, newest activity first.
    ///
    /// Conversations belong to the brand they are about: the list under one app
    /// should not show where last week's ad for another one was made. Threads
    /// from before brands were carried still appear, because hiding somebody's
    /// history to introduce a feature is not a trade worth making.
    /// Marks a thread as a generation thread, once, forward-only. Quiet on
    /// failure: the worst outcome is the thread reopening as chat, which is
    /// the bug this exists to fix, not a new one.
    func markThreadGeneration(_ id: UUID) async {
        struct Params: Encodable, Sendable { let p_thread: String }
        _ = try? await client
            .rpc("mark_thread_generation", params: Params(p_thread: id.uuidString))
            .execute()
    }

    /// What a thread is -- "chat" or "generation" -- read from the same list
    /// the chats screen shows. Nil when it cannot be read, and the caller
    /// falls back to chat, which draws everything correctly if plainly.
    func threadKind(_ id: UUID) async -> String? {
        // Asked of the thread itself first. The list is the newest thirty, so
        // a generation older than that came back as "not found" and reopened
        // as plain chat -- the feed, the bar and the meaning of send gone.
        struct Row: Decodable { let kind: String }
        if let rows: [Row] = try? await client
            .from("threads")
            .select("kind")
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value,
           let kind = rows.first?.kind {
            return kind
        }
        return await threads().first(where: { $0.id == id })?.kind
    }

    func threads() async -> [ChatThread] {
        struct Params: Encodable { let p_limit: Int; let p_brand: String? }
        do {
            return try await client
                .rpc("my_threads", params: Params(p_limit: 30, p_brand: brand?.id.uuidString))
                .execute()
                .value
        } catch {
            return []
        }
    }

    /// One conversation, replayed.
    ///
    /// Read from the server rather than kept in the view, which is what makes a
    /// conversation survive the app being closed -- and what lets a long job
    /// finishing while you were away be there when you come back.
    /// What the owner wants the chat to know about talking to them. Saved on
    /// the brand's settings and read into every reply (0056).
    @discardableResult
    func setChatInstructions(_ text: String) async -> Bool {
        guard let brandID = brand?.id else { return false }
        struct Params: Encodable { let p_brand: String; let p_text: String }
        do {
            try await client
                .rpc("set_chat_instructions", params: Params(p_brand: brandID.uuidString, p_text: text))
                .execute()
            await refreshSettings()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// One conversation, moved to Recently Deleted (0102), where it can be
    /// restored for 30 days.
    func deleteThread(_ thread: UUID) async {
        do {
            try await client.rpc("delete_thread", params: ["p_thread": thread.uuidString]).execute()
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// Words found anywhere in a conversation, its messages included.
    func searchThreads(_ query: String) async -> [ChatThread]? {
        struct Params: Encodable { let p_query: String; let p_brand: String?; let p_limit: Int }
        return try? await client
            .rpc("search_threads", params: Params(p_query: query, p_brand: brand?.id.uuidString, p_limit: 50))
            .execute()
            .value
    }

    /// Recently Deleted: the last 30 days.
    func deletedThreads() async -> [DeletedThread] {
        struct Params: Encodable { let p_brand: String? }
        do {
            return try await client
                .rpc("my_deleted_threads", params: Params(p_brand: brand?.id.uuidString))
                .execute()
                .value
        } catch {
            return []
        }
    }

    func restoreThread(_ thread: UUID) async {
        do {
            try await client.rpc("restore_thread", params: ["p_thread": thread.uuidString]).execute()
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// Gone for good, now.
    func purgeThread(_ thread: UUID) async {
        do {
            try await client.rpc("purge_thread", params: ["p_thread": thread.uuidString]).execute()
            ChatCache.shared.remove(thread)
        } catch {
            lastError = readableMessage(error)
        }
    }

    @discardableResult
    func emptyDeletedThreads() async -> Bool {
        do {
            try await client.rpc("empty_deleted_threads").execute()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    func pinThread(_ thread: UUID, pinned: Bool) async {
        struct Params: Encodable { let p_thread: String; let p_pinned: Bool }
        do {
            try await client.rpc("pin_thread", params: Params(p_thread: thread.uuidString, p_pinned: pinned)).execute()
        } catch {
            lastError = readableMessage(error)
        }
    }

    func renameThread(_ thread: UUID, to title: String) async {
        struct Params: Encodable { let p_thread: String; let p_title: String }
        do {
            try await client.rpc("rename_thread", params: Params(p_thread: thread.uuidString, p_title: title)).execute()
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// A link anyone can open to read the conversation on the web
    /// (netrocast.com/s), until sharing is stopped or the chat is deleted.
    func shareLink(for thread: UUID) async -> URL? {
        do {
            let token: String = try await client
                .rpc("share_thread", params: ["p_thread": thread.uuidString])
                .execute()
                .value
            return URL(string: "https://netrocast.com/s/?c=\(token)")
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }

    func stopSharing(_ thread: UUID) async {
        do {
            try await client.rpc("unshare_thread", params: ["p_thread": thread.uuidString]).execute()
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// Every conversation for this brand, gone.
    @discardableResult
    func clearThreads() async -> Bool {
        struct Params: Encodable { let p_brand: String? }
        do {
            try await client.rpc("clear_my_threads", params: Params(p_brand: brand?.id.uuidString)).execute()
            ChatCache.shared.removeAll()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// The conversation as the phone last saw it, at once, or nil when it has
    /// never been opened here. Abel, 3 Nov 2026: leaving a chat and coming
    /// back "automatically reloads the chat ... it doesn't save things
    /// locally". `messages(in:)` then brings it up to date.
    func cachedMessages(in thread: UUID) -> [ChatMessage]? {
        guard let data = ChatCache.shared.read(thread) else { return nil }
        return try? readTurns(from: data)
    }

    /// The conversation from the server, or nil when it is exactly what the
    /// phone already shows -- so a reopened chat does not redraw for nothing.
    func freshMessages(in thread: UUID) async -> [ChatMessage]? {
        guard let data = try? await client
            .rpc("thread_messages", params: ["p_thread": thread.uuidString])
            .execute()
            .data
        else { return nil }
        if data == ChatCache.shared.read(thread) { return nil }
        guard let fresh = try? readTurns(from: data) else { return nil }
        ChatCache.shared.write(data, for: thread)
        return fresh
    }

    func messages(in thread: UUID) async -> [ChatMessage] {
        if let fresh = await freshMessages(in: thread) { return fresh }
        return cachedMessages(in: thread) ?? []
    }

    /// Stored rows, read into turns the way the conversation went.
    private func readTurns(from data: Data) throws -> [ChatMessage] {
        let rows = try JSONDecoder().decode([StoredMessage].self, from: data)
        // An explicit closure rather than a key path. The key path form is
        // tidier and its backslash has now been eaten four times by shell
        // escaping in this project, which is a good enough reason.
        var turns = rows.map { $0.asTurn }

        // An offer or a question somebody already replied to is settled,
        // not live. Left tappable, a reopened model picker would start a
        // second generation -- on somebody's own credits -- for a request
        // that was already made.
        for index in turns.indices where turns[index].role == .assistant {
            let later = turns[(index + 1)...]
            // Something made after an offer settles it too. Abel, 1 Nov
            // 2026: "Right after you generate a photo, you can still click
            // the generate button again." Generate is a tap, which leaves no
            // reply, so when the picture landed and the conversation was
            // read back the card was live again.
            if turns[index].offer != nil,
               later.contains(where: { $0.role == .assistant && ($0.runId != nil || $0.artifactId != nil) }) {
                turns[index].chosenModel = "Generated"
            }
            guard let reply = later.first(where: { $0.role == .user }) else { continue }
            if turns[index].offer != nil, turns[index].chosenModel == nil {
                turns[index].chosenModel = settledChoice(reply.text)
            }
            for question in turns[index].questions {
                turns[index].answered[question.key] = "Answered"
            }
        }
        return turns
    }


    /// The reply to a model offer, said as the choice it was. "Use Kling 2.1."
    /// becomes "Kling 2.1"; "You choose." becomes "Auto".
    private func settledChoice(_ reply: String) -> String {
        var said = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.hasPrefix("You choose") { return "Auto" }
        if said.hasPrefix("Generate with ") { said.removeFirst(14) }
        if said.hasPrefix("Use ") { said.removeFirst(4) }
        if said.hasSuffix(".") { said.removeLast() }
        return said.isEmpty ? "Chosen" : said
    }

    /// What the stream can say. One case per server event, so a line we do not
    /// understand is a gap rather than a silently wrong branch.
    enum ChatEvent {
        case step(TaskStep)
        case delta(String)
        /// A few voices to hear, each with a sample.
        case voices([VoiceSample])
        /// What the server took the message to mean, shown behind "Thinking".
        case thought(String)
        /// A web answer is looking things up, with the sites read so far.
        case searching(String, sites: [String])
        /// The pages that web answer was built from.
        case sources([WebSource])
        case thread(UUID)
        /// The server has the message: its answer to the request came back.
        /// The "Sending" pill gives way to "Thinking".
        case received
        /// Questions to answer, with the request and length they were asked
        /// for, so the answers can go straight on to a strategy.
        case questions([ChatQuestion], request: String?, days: Int?)
        /// Something made on this turn, drawn as its card.
        case artifact(UUID)
        /// The models that can do it, with the request they were offered for.
        case models(ModelOffer, request: String?, references: [String])
        case chose(ModelChoice)
        /// Long work handed to the worker. The card follows it from here.
        /// `all` is every run of a set of pictures, when there are several.
        case run(UUID, kind: String, all: [UUID], makes: String?)
        /// Things worth saying next, as taps. A suggestion ending in a space is
        /// an invitation to finish the sentence rather than a message to send.
        case suggestions([String])
        /// The server refused a generation for want of credits or a plan (0077)
        /// and said so in the conversation. The plans are offered next.
        /// `needs_credits`, `needs_pro` or `needs_tier`.
        case paywall(String)
        /// Something to be made and sent at a time, saved as a draft; the
        /// Schedule sheet opens for it (0095).
        case schedule(UUID)
        /// An answer that needs an account nobody connected: its Connect card,
        /// and the question to ask again once it is read.
        case connect(Platform, question: String?)
        /// An answer's numbers as a chart (mockup screen 7).
        case chart(ChatChart)
        case failed(String)
    }

    /// What a button asked for, sent as data rather than as a sentence.
    ///
    /// A tap on "PDF" knows exactly what it means. Sending it as the words
    /// "export it as a PDF" and hoping the router reads them back the same way
    /// works until it does not, and then the tap does something else.
    enum ChatAction {
        case export(artifact: UUID, format: String)
        case generate(
            capability: String, prompt: String, model: String?, references: [String],
            settings: GenerationSettings, quoted: ModelCost?
        )
        case animate(artifact: UUID)
        /// Every question on a card, answered by tapping -- as values.
        case answers([String: String], request: String?, days: Int?)
        /// "Photo video" on the create card: the story engine with the card's
        /// choices -- style, length, look, voice, captions.
        case story(StoryChoice)

        var payload: [String: Any] {
            switch self {
            case .export(let artifact, let format):
                return ["type": "export", "artifactId": artifact.uuidString, "format": format]
            case .generate(let capability, let prompt, let model, let references, let settings, let quoted):
                var out: [String: Any] = [
                    "type": "generate", "capability": capability,
                    "prompt": prompt, "references": references,
                    "settings": settings.payload,
                ]
                if let model { out["model"] = model }
                if let quoted, let amount = quoted.amount {
                    out["quoted"] = ["amount": amount, "unit": quoted.unit]
                }
                return out
            case .animate(let artifact):
                return ["type": "animate", "artifactId": artifact.uuidString]
            case .answers(let answers, let request, let days):
                var out: [String: Any] = ["type": "answers", "answers": answers]
                if let request { out["request"] = request }
                if let days { out["days"] = days }
                return out
            case .story(let choice):
                return choice.payload
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
        tap: Bool = false,
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
        // A turn that is only a photo carries no text, so it is not in the
        // payload above; the attachments say what it was.

        var body: [String: Any] = ["messages": payload]
        // Which app this is about. Without it the agent reads the oldest brand
        // and talks about the wrong product.
        if let brandID = brand?.id { body["brandId"] = brandID.uuidString }
        if let thread { body["threadId"] = thread.uuidString }
        if let action { body["action"] = action.payload }
        if !attachments.isEmpty { body["attachments"] = attachments }
        // A chip tapped rather than a sentence typed: stored marked, like an
        // action, so a reopened conversation does not show it as a bubble.
        if tap { body["tap"] = true }
        // The generator's settings, set once behind the sliders: anything made
        // from this message starts on them instead of asking.
        body["prefs"] = GeneratorPrefs.current.payload
        // This build draws markdown, so the reply may use it. An older one shows
        // it as plain text and says nothing, and is never sent it.
        body["markdown"] = true
        // Who answers, from the model chip; the effort only for a model that
        // thinks, so Auto decides for itself.
        let models = ChatModelPrefs.current
        body["chatModel"] = models.model
        body["effort"] = models.sentEffort
        // Where they are, so "what's on tonight" comes back in their time and
        // their country -- ChatGPT gave Abel kick-offs in Ethiopian time.
        body["timezone"] = TimeZone.current.identifier
        if let region = Locale.current.region?.identifier { body["region"] = region }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = try await ChatTransport.open(request)
        // A retry's own session has to outlive the stream read from it.
        defer { withExtendedLifetime(started) {} }
        let bytes = started.bytes
        let response = started.response

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            if http.statusCode == 402 {
                // This month's chat allowance is used: say so, and offer Pro.
                showingPaywall = true
                onEvent(.failed("You’ve used this month’s chat messages. Postpilot Pro gives you 1,000 a month."))
                return
            }
            // A wall (0100): too long, or too many too fast. The server says it
            // in words meant for them, so those words are shown.
            if http.statusCode == 413 || http.statusCode == 429 {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 4096 { break }
                }
                let said = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                onEvent(.failed(said ?? (http.statusCode == 413
                    ? "That message is too long to read in one go. Split it into parts."
                    : "You've sent a lot in a short time. Give it a minute, then carry on.")))
                return
            }
            onEvent(.failed(
                http.statusCode == 401
                    ? "Sign in again to keep chatting."
                    : "The agent could not be reached just now."
            ))
            return
        }

        // Headers back and no error: the server has the message.
        onEvent(.received)

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

            if kind == "voices" {
                struct Frame: Decodable { let items: [VoiceSample] }
                if let frame = try? JSONDecoder().decode(Frame.self, from: data) {
                    onEvent(.voices(frame.items))
                }
                continue
            }

            if kind == "sources" {
                struct Frame: Decodable { let items: [WebSource] }
                if let frame = try? JSONDecoder().decode(Frame.self, from: data) {
                    onEvent(.sources(frame.items))
                }
                continue
            }

            if kind == "searching" {
                onEvent(.searching(
                    event["v"] as? String ?? "Searching the web",
                    sites: event["sites"] as? [String] ?? []
                ))
                continue
            }

            if kind == "run", let id = event["id"] as? String, let uuid = UUID(uuidString: id) {
                // A set of pictures is one run each; `ids` lists them all.
                let all = (event["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
                onEvent(.run(uuid, kind: event["kind"] as? String ?? "run", all: all, makes: event["artifact_kind"] as? String))
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

            if kind == "suggestions", let options = event["options"] as? [String] {
                onEvent(.suggestions(options))
                continue
            }

            if kind == "artifact", let id = event["id"] as? String, let uuid = UUID(uuidString: id) {
                onEvent(.artifact(uuid))
                continue
            }

            if kind == "schedule", let id = event["id"] as? String, let uuid = UUID(uuidString: id) {
                onEvent(.schedule(uuid))
                continue
            }

            if kind == "connect", let name = event["platform"] as? String, let platform = Platform(rawValue: name) {
                onEvent(.connect(platform, question: event["question"] as? String))
                continue
            }

            if kind == "chart", let raw = event["chart"],
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let chart = try? JSONDecoder().decode(ChatChart.self, from: data) {
                onEvent(.chart(chart))
                continue
            }

            if kind == "thread", let id = event["id"] as? String, let uuid = UUID(uuidString: id) {
                onEvent(.thread(uuid))
                continue
            }

            switch kind {
            case "delta":
                if let value = event["v"] as? String { onEvent(.delta(value)) }
            case "thought":
                if let value = event["v"] as? String { onEvent(.thought(value)) }
            case "step":
                if let detail = event["detail"] as? String {
                    let name = event["kind"] as? String ?? "reading"
                    onEvent(.step(TaskStep(
                        kind: TaskStep.Kind(rawValue: name) ?? .reading,
                        detail: detail
                    )))
                }
            case "paywall":
                onEvent(.paywall(event["code"] as? String ?? "needs_credits"))
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

/// The first moments of a chat reply: the request goes out and the server's
/// headers come back.
///
/// Abel, 1 Nov 2026, with a screenshot: a message with a photo ended in "That
/// took longer than expected", though the photo itself had uploaded. The server
/// log shows the chat request never arrived -- nothing for two minutes, then
/// the same message typed again went through in five seconds. A connection
/// that had gone stale under the app (the phone moved between Wi-Fi and mobile,
/// or sat idle) takes a request and says nothing, and URLSession waits on it
/// until the 120 s timeout.
///
/// A live server answers with its headers within a second or two, because the
/// turn is stored before anything slow starts. So 20 s of silence means the
/// connection is dead: give up on it and send the same request once more, on a
/// connection of its own. The retry says so (`x-autocast-retry`), so a first
/// try that did arrive late is not stored twice.
private struct StreamStart: @unchecked Sendable {
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    /// Held so a retry's own session lives as long as its stream is read.
    let session: URLSession
}

private enum ChatTransport {
    static let silence: Duration = .seconds(20)

    static func open(_ request: URLRequest) async throws -> StreamStart {
        do {
            return try await attempt(request, on: URLSession.shared)
        } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
            var again = request
            again.setValue("1", forHTTPHeaderField: "x-autocast-retry")
            let fresh = URLSession(configuration: .ephemeral)
            // Lets the stream being read finish, then lets the session go.
            defer { fresh.finishTasksAndInvalidate() }
            return try await attempt(again, on: fresh)
        }
    }

    private static func attempt(_ request: URLRequest, on session: URLSession) async throws -> StreamStart {
        try await withThrowingTaskGroup(of: StreamStart.self) { group -> StreamStart in
            group.addTask {
                let (bytes, response) = try await session.bytes(for: request)
                return StreamStart(bytes: bytes, response: response, session: session)
            }
            group.addTask {
                try await Task.sleep(for: ChatTransport.silence)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
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
    /// When it was said -- what a job's "Worked for 2m 14s" is measured from.
    /// Read as text and parsed leniently: Postgres sends microseconds
    /// ("…57.486518+00:00"), and a date the decoder could not read must not
    /// take the whole conversation down with it.
    let createdAtText: String?

    var createdAt: Date? {
        guard let createdAtText else { return nil }
        // Seconds are all a duration needs; the fraction is what parsers
        // disagree about.
        let whole = createdAtText.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }

    private enum CodingKeys: String, CodingKey {
        case seq, role, text
        case renderHint = "render_hint"
        case createdAtText = "created_at"
    }

    /// What the server attached to this turn, when it was more than prose.
    struct RenderHint: Decodable {
        let kind: String?
        let questions: [ChatQuestion]?
        let choices: ModelOffer?
        let request: String?
        let references: [String]?
        let runId: UUID?
        /// Every run of a set of pictures started together; `runId` is the first.
        let runIds: [UUID]?
        let runKind: String?
        let artifactId: UUID?
        /// A scheduled drop's card (0095).
        let scheduleId: UUID?
        let paths: [String]?
        let days: Int?
        let options: [String]?
        /// What the artefact is and what shape it is, so its card holds the
        /// right space before the file itself has been read.
        let artifactKind: String?
        let width: Int?
        let height: Int?
        /// The set a picture belongs to, when several were asked for at once.
        let batch: String?
        /// Voices offered to be heard, when this turn is a voices card.
        let items: [VoiceSample]?
        /// The pages a web answer was built from.
        let sources: [WebSource]?
        /// What the reply did on the way, for the sheet behind "Thinking".
        let thinking: Thinking?
        /// A Connect card: the network, and the question to ask again.
        let platform: String?
        let question: String?
        /// An answer's numbers, drawn as a chart.
        let chart: ChatChart?

        /// The steps the server took for this reply, in order, what it took the
        /// request to mean, and how long the whole turn took.
        struct Thinking: Decodable {
            struct Step: Decodable {
                let kind: String?
                let detail: String
            }
            let read: String?
            let steps: [Step]?
            let secs: Int?
        }

        private enum CodingKeys: String, CodingKey {
            case kind, questions, choices, request, references, paths, days, options, width, height, batch, items, sources, thinking
            case platform, question, chart
            case artifactKind = "artifact_kind"
            case runId = "run_id"
            case runIds = "run_ids"
            case runKind = "run_kind"
            case artifactId = "artifact_id"
            case scheduleId = "schedule_id"
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
        turn.runIds = renderHint?.runIds ?? []
        turn.runKind = renderHint?.runKind
        turn.artifactId = renderHint?.artifactId
        if renderHint?.kind == "schedule" { turn.scheduleId = renderHint?.scheduleId }
        if renderHint?.kind == "connect", let name = renderHint?.platform {
            turn.connectPlatform = Platform(rawValue: name)
            turn.connectQuestion = renderHint?.question
        }
        turn.chart = renderHint?.chart
        turn.batch = renderHint?.batch
        if let id = renderHint?.artifactId { turn.batchArtifacts = [id] }
        turn.artifactKind = renderHint?.artifactKind
        turn.artifactWidth = renderHint?.width
        turn.artifactHeight = renderHint?.height
        turn.attachments = renderHint?.paths ?? []
        // A picture carries its one-tap remixes ("in winter colours").
        if renderHint?.kind == "suggestions" || renderHint?.kind == "artifact" {
            turn.suggestions = renderHint?.options ?? []
        }
        if renderHint?.kind == "voices" { turn.voices = renderHint?.items ?? [] }
        turn.sources = renderHint?.sources ?? []
        // The trail is kept, unlike the live state around it: it is a record
        // of what was done, and every step of it finished long ago.
        if let thinking = renderHint?.thinking {
            turn.thought = thinking.read
            turn.steps = (thinking.steps ?? []).map { stored in
                var step = TaskStep(kind: TaskStep.Kind(rawValue: stored.kind ?? "") ?? .reading, detail: stored.detail)
                step.isDone = true
                return step
            }
            turn.thinkingSeconds = thinking.secs
        }
        turn.isTap = renderHint?.kind == "tap"
        turn.createdAt = createdAt
        // A job's steps are marked "progress". Lines a story wrote before the
        // mark existed carry no hint and start with its step emoji, so they
        // fold the same way.
        // By first code point, not Character: "🖼️" is U+1F5BC plus a
        // variation selector, and "🖼️".hasPrefix("🖼") is false.
        let stepEmoji: Set<UInt32> = [0x1F4DD, 0x2705, 0x26A0, 0x1F50E, 0x1F501, 0x1F5BC, 0x1F39E, 0x1F399]
        let legacyStep = role == "assistant" && renderHint == nil
            && stepEmoji.contains(text.unicodeScalars.first?.value ?? 0)
        if renderHint?.kind == "progress" || legacyStep {
            turn.isProgress = true
            // The run id on a step names the job; it is not a card to follow.
            turn.runId = nil
        }
        return turn
    }
}
