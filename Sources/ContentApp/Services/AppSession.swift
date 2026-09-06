import Foundation
import Observation
import Supabase

/// The app's one connection to the backend, and everything it knows.
///
/// Replaces the old ContentStore, which faked a backend with a 700ms sleep and
/// a file of fixtures. Every property here is read from Postgres under row-level
/// security, so what the app can see and what it can change are decided by the
/// database rather than by this class remembering to be careful.
@MainActor
@Observable
final class AppSession {
    enum State: Equatable {
        case starting
        case ready
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var userID: UUID?
    private(set) var brand: Brand?
    private(set) var connections: [PlatformConnection] = []
    private(set) var isConnecting = false

    /// Surfaced by the root view and cleared when acknowledged. Not an error log.
    var lastError: String?

    let client: SupabaseClient

    init() {
        client = SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabaseAnonKey
        )
    }

    // MARK: - Starting up

    /// Signs in and loads everything the app needs to draw its first screen.
    ///
    /// The sign-in is anonymous, which means the row in `auth.users` is real --
    /// RLS, brands and connections all behave normally -- but nobody has to get
    /// past a login wall to see whether the product is worth anything. Supabase
    /// can upgrade the same row to a permanent identity later without the person
    /// losing what they made.
    func start() async {
        do {
            try await signInIfNeeded()
            let user = try await client.auth.session.user
            userID = user.id
            try await loadBrand(for: user.id)
            await refreshConnections()
            state = .ready
        } catch {
            state = .failed(readable(error))
        }
    }

    /// Reuses a stored session when there is one, and signs in anonymously when
    /// there is not. Deliberately avoids naming the SDK session type: it is also
    /// called Session, and two types with one name in the same file is a trap
    /// for whoever edits this next.
    private func signInIfNeeded() async throws {
        if (try? await client.auth.session) == nil {
            _ = try await client.auth.signInAnonymously()
        }
    }

    /// One brand for now. The schema supports several and the UI will, but
    /// shipping a brand switcher before there is a second brand is furniture.
    private func loadBrand(for userID: UUID) async throws {
        let existing: [Brand] = try await client
            .from("brands")
            .select()
            .limit(1)
            .execute()
            .value

        if let first = existing.first {
            brand = first
            return
        }

        let created: [Brand] = try await client
            .from("brands")
            .insert(NewBrand(
                userId: userID,
                name: "My brand",
                // The device's own zone, so the first schedule it proposes is
                // already in hours the person recognises.
                timezone: TimeZone.current.identifier
            ))
            .select()
            .execute()
            .value

        brand = created.first
    }

    func refreshConnections() async {
        guard let brandID = brand?.id else { return }
        do {
            connections = try await client
                .from("platform_connections")
                .select("id,brand_id,platform,username,display_name,avatar_url,scopes,status,connected_at,last_error")
                .eq("brand_id", value: brandID.uuidString)
                .order("connected_at", ascending: false)
                .execute()
                .value
        } catch {
            lastError = readable(error)
        }
    }

    // MARK: - Connecting an account

    /// Runs the whole OAuth round trip and comes back with the account linked.
    ///
    /// The app never sees a token or the client secret. It asks the server for a
    /// URL, shows it, and waits for iOS to hand back the `autocast://` callback
    /// once the exchange has already happened server-side.
    func connectTikTok() async {
        guard let brandID = brand?.id, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        do {
            let start: AuthorizeStart = try await client.functions.invoke(
                "oauth-start",
                options: FunctionInvokeOptions(body: [
                    "brand_id": brandID.uuidString,
                    "platform": "tiktok",
                    "return_to": Config.oauthReturnURL,
                ])
            )

            guard let url = URL(string: start.authorizeURL) else {
                lastError = "The sign-in link came back malformed."
                return
            }

            let callback = try await WebAuth.run(url: url, scheme: Config.callbackScheme)
            try handle(callback: callback)
            await refreshConnections()
        } catch is CancellationError {
            // Closed the sheet. Not a failure worth a banner.
        } catch let error as WebAuth.Failure where error == .cancelled {
            // Same.
        } catch {
            lastError = readable(error)
        }
    }

    /// Reads the result the callback carries. The work is already done by the
    /// time this runs; this only decides what to say about it.
    private func handle(callback: URL) throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        switch value("status") {
        case "connected":
            return
        case "denied":
            lastError = "You cancelled on TikTok, so nothing was connected."
        default:
            lastError = Self.message(forReason: value("reason"))
        }
    }

    private static func message(forReason reason: String?) -> String {
        switch reason {
        case "expired":
            return "That took a little too long. Try connecting again."
        case "exchange_failed":
            return "TikTok would not complete the sign-in. Try again."
        case "unknown_state", "missing_state":
            return "That sign-in did not match one we started. Try again."
        default:
            return "The account could not be connected."
        }
    }

    // MARK: - Errors

    /// Postgres and PostgREST errors are not written for people. Anything we do
    /// not recognise becomes something plain rather than a raw code.
    private func readable(_ error: Error) -> String {
        if let postgrest = error as? PostgrestError {
            return postgrest.message
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "No connection. Check your network and try again."
        }
        return error.localizedDescription
    }
}

private struct AuthorizeStart: Decodable {
    let authorizeURL: String

    enum CodingKeys: String, CodingKey {
        case authorizeURL = "authorize_url"
    }
}
