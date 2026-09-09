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
    let status: String
    let accountLabel: String
    let capabilities: [String]
    let modelCount: Int
    let lastErrorCode: String?
    let connectedAt: Date?

    var isHealthy: Bool { status == "active" }

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

    /// How it connects, said the way somebody deciding would want it said.
    var how: String {
        authKind == "api_key" ? "Paste a key" : "Sign in"
    }

    private enum CodingKeys: String, CodingKey {
        case slug, name
        case authKind = "auth_kind"
        case docsUrl = "docs_url"
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

        do {
            let start: ConnectorStart = try await client.functions.invoke(
                "connector-start",
                options: FunctionInvokeOptions(body: ["provider": slug, "scheme": "autocast"])
            )

            guard let url = URL(string: start.url) else {
                lastError = "That provider gave back something unusable."
                return false
            }

            _ = try await WebAuth.run(url: url, scheme: "autocast")

            // The callback already exchanged, sealed and discovered before it
            // redirected here, so by this point the connection is either live
            // or faulted -- reading it back is the honest way to find out which
            // rather than assuming the redirect meant success.
            await refreshConnectedProviders()
            await refreshConnectable()

            guard let made = connectedProviders.first(where: { $0.providerSlug == slug }) else {
                lastError = "That did not finish. Try again."
                return false
            }
            if !made.isHealthy {
                lastError = "Connected, but \(made.providerName) refused. Try reconnecting."
                return false
            }
            return true
        } catch WebAuth.Failure.cancelled {
            // Not an error. Somebody changed their mind.
            return false
        } catch {
            lastError = readableMessage(error)
            return false
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
            let result: DiscoveryResult = try await client.functions.invoke(
                "connector-refresh",
                options: FunctionInvokeOptions(
                    body: connectionId.map { ["connectionId": $0.uuidString] } ?? [:]
                )
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
        } catch {
            lastError = readableMessage(error)
        }
    }
}

private struct ConnectorStart: Decodable {
    let url: String
    let provider: String
}

private struct DiscoveryResult: Decodable {
    let recorded: Int
    let capabilities: [String]
    let tools: [String]?
}
