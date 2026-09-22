import Foundation
import Supabase

/// One provider this person has connected, as the app needs to show it.
///
/// Never carries a credential. The database is shaped so it cannot: tokens live
/// in a schema with no grants, and `my_connections` returns a label and a
/// status. What somebody sees is "Higgsfield · Connected", which is the whole
/// point of the connector work.
struct ProviderConnection: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let providerSlug: String
    let providerName: String
    /// Which door it came through. Optional so an older server that does not
    /// say still decodes.
    let authKind: String?
    let status: String
    let accountLabel: String
    let capabilities: [String]
    let modelCount: Int
    let lastErrorCode: String?
    let connectedAt: Date?

    var isHealthy: Bool { status == "active" }

    /// A key somebody pasted, as opposed to an account they signed in to.
    var isPastedKey: Bool { authKind == "api_key" }

    /// "API key" or "Signed in" -- the difference matters to somebody deciding
    /// which one to keep.
    var door: String { isPastedKey ? "API key" : "Signed in" }

    /// What to show under the name. Deliberately not the raw status: "expired"
    /// is a state, "Sign in again" is a thing to do.
    var summary: String {
        switch status {
        case "active":
            if modelCount == 0 { return "Connected, nothing available yet" }
            return "Connected · \(modelCount) model\(modelCount == 1 ? "" : "s")"
        case "expired": return "Sign in again to keep using it"
        case "error":   return "Something went wrong — reconnect"
        case "pending": return "Finishing…"
        default:        return "Disconnected"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case providerSlug = "provider_slug"
        case providerName = "provider_name"
        case authKind = "auth_kind"
        case status
        case accountLabel = "account_label"
        case capabilities
        case modelCount = "model_count"
        case lastErrorCode = "last_error_code"
        case connectedAt = "connected_at"
    }
}

/// Something connectable that is not connected yet.
struct ConnectableProvider: Identifiable, Decodable, Hashable, Sendable {
    var id: String { slug }
    let slug: String
    let name: String
    let authKind: String
    let docsUrl: String?
    /// The person has a pasted key for this provider, which signing in will
    /// replace. Said on the button, because that is what pressing it does.
    let replacesKey: Bool?
    /// The one the app leads with. Read from the row, never decided here.
    let featured: Bool?
    /// A sentence about it, from the row.
    let tagline: String?
    /// An MCP server this person added by address (0055).
    let mine: Bool?

    var isFeatured: Bool { featured == true }
    var isMine: Bool { mine == true }

    /// The button's words.
    var action: String {
        authKind == "api_key" ? "Connect \(name)" : "Sign in to \(name)"
    }

    /// How it connects, said the way somebody deciding would want it said.
    var how: String {
        if replacesKey == true { return "Replaces your pasted key" }
        return authKind == "api_key" ? "Paste a key" : "Use the account you already have"
    }

    private enum CodingKeys: String, CodingKey {
        case slug, name, featured, tagline, mine
        case authKind = "auth_kind"
        case docsUrl = "docs_url"
        case replacesKey = "replaces_key"
    }
}

extension AppSession {

    /// Everything connected, for the Plus menu and You.
    func refreshConnectedProviders() async {
        do {
            connectedProviders = try await client.rpc("my_connections").execute().value
        } catch {
            connectedProviders = []
        }
    }

    func refreshConnectable() async {
        do {
            connectable = try await client.rpc("connectable_providers").execute().value
        } catch {
            connectable = []
        }
    }

    /// Connects a provider by signing in to it.
    ///
    /// The app's entire part is opening a URL and waiting for the callback. It
    /// never sees a client id, a code, a verifier or a token -- the redirect
    /// lands on our own server, which exchanges the code and seals the result.
    /// That is why this returns nothing but success.
    ///
    /// `ASWebAuthenticationSession` is the same sheet TikTok already uses: it
    /// watches for the scheme itself, closes on its own, and keeps the login
    /// inside the app.
    @discardableResult
    func connectProvider(_ slug: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }

        // Keys this sign-in replaces, noted before anything changes. The
        // button said "replaces your pasted key", so once signing in works
        // the key goes -- and not before, so a sign-in that fails leaves
        // somebody with what they had.
        let replaced = connectedProviders.filter { $0.providerSlug == slug && $0.isPastedKey }

        do {
            let start: ConnectorStart = try await client.functions.invoke(
                "connector-start",
                options: FunctionInvokeOptions(body: ["provider": slug, "scheme": "autocast"])
            )

            // An open server (no sign-in behind it) is connected by the
            // server on the spot; there is no page to open.
            if start.connected != true {
                guard let raw = start.url, let url = URL(string: raw) else {
                    lastError = "That provider gave back something unusable."
                    return false
                }

                let returned = try await WebAuth.run(url: url, scheme: "autocast")

                // The callback says how it went. Before this the app dropped
                // the answer and every failure read "That did not finish",
                // which told nobody anything (22 Sep 2026).
                let items = URLComponents(url: returned, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let status = items.first { $0.name == "status" }?.value
                let reason = items.first { $0.name == "reason" }?.value ?? ""
                if status == "failed" {
                    switch reason {
                    case "cancelled", "access_denied":
                        return false
                    case "expired":
                        lastError = "The sign-in took too long and was dropped. Try again."
                    case "exchange_failed":
                        lastError = "The sign-in came back, but the server refused to finish it. Try again in a moment."
                    default:
                        lastError = "The sign-in did not finish (\(reason)). Try again."
                    }
                    return false
                }
            }

            // The callback already exchanged, sealed and discovered before it
            // redirected here, so by this point the connection is either live
            // or faulted -- reading it back is the honest way to find out which
            // rather than assuming the redirect meant success.
            await refreshConnectedProviders()
            await refreshConnectable()

            guard let made = connectedProviders.first(where: { $0.providerSlug == slug && !$0.isPastedKey }) else {
                lastError = "That did not finish. Try again."
                return false
            }
            if !made.isHealthy {
                lastError = "Connected, but \(made.providerName) refused. Try reconnecting."
                return false
            }

            for key in replaced where key.id != made.id {
                await disconnect(key.id)
            }
            if !replaced.isEmpty { await refreshGenerators() }
            return true
        } catch WebAuth.Failure.cancelled {
            // Not an error. Somebody changed their mind.
            return false
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// Adds an MCP server by address and signs in to it.
    ///
    /// The address becomes a provider row only this person can see (0055),
    /// and from there it is the same door as any catalogue provider: the app
    /// opens a URL and waits. Returns true once the server is connected.
    @discardableResult
    func addMCPServer(name: String, url: String) async -> Bool {
        let slug: String
        do {
            slug = try await client
                .rpc("add_mcp_server", params: ["p_name": name, "p_url": url])
                .execute()
                .value
        } catch {
            lastError = readableMessage(error)
            return false
        }
        await refreshConnectable()
        return await connectProvider(slug)
    }

    /// Takes one of this person's own servers off the list.
    func removeMCPServer(_ slug: String) async {
        do {
            try await client.rpc("remove_mcp_server", params: ["p_slug": slug]).execute()
            await refreshConnectedProviders()
            await refreshConnectable()
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// Asks a connection again what it can do.
    ///
    /// Offered because a provider granting access to a new model should not
    /// need a reconnection, and because a connection that discovered nothing at
    /// connect time is recoverable rather than broken.
    @discardableResult
    func refreshCapabilities(_ connectionId: UUID? = nil) async -> Int {
        do {
            // Typed rather than `?? [:]`: an empty dictionary literal has no
            // element type to infer from, so the compiler cannot decide what
            // the encodable body is.
            var payload: [String: String] = [:]
            if let connectionId { payload["connectionId"] = connectionId.uuidString }

            let result: DiscoveryResult = try await client.functions.invoke(
                "connector-refresh",
                options: FunctionInvokeOptions(body: payload)
            )
            await refreshConnectedProviders()
            return result.recorded
        } catch {
            lastError = readableMessage(error)
            return 0
        }
    }

    func disconnect(_ connectionId: UUID) async {
        do {
            try await client
                .rpc("forget_connection", params: ["p_connection": connectionId.uuidString])
                .execute()
            await refreshConnectedProviders()
            await refreshConnectable()
            // A bridged key is also a legacy generator row; forgetting the
            // connection revokes both, and the old list should agree.
            await refreshGenerators()
        } catch {
            lastError = readableMessage(error)
        }
    }
}

private struct ConnectorStart: Decodable {
    /// The page to sign in on. Nil when there was nothing to sign in to.
    let url: String?
    let provider: String
    /// True when the server connected an open endpoint on the spot.
    let connected: Bool?
}

private struct DiscoveryResult: Decodable {
    let recorded: Int
    let capabilities: [String]
    let tools: [String]?
}
