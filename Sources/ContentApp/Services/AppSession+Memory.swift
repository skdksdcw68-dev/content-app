import Foundation
import Supabase

/// One thing the chat remembers about the person (migration 0092). The chat
/// writes these after replies; the person can read and delete them.
struct MemoryNote: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let note: String
}

/// One card under "Trending today" on Explore, from the `trends` function:
/// looked up on the web once a day per country and shared by everyone there.
struct TrendCard: Decodable, Identifiable, Hashable, Sendable {
    let kind: String
    let title: String
    let why: String
    let idea: String
    var id: String { kind + title }
}

/// The two switches that live on the person's account rather than a brand:
/// whether the chat remembers, and whether it searches the web on its own.
/// Kept in the sign-in's own metadata, which the chat function already reads.
enum AccountSwitch: String {
    case memoryOff = "memory_off"
    case webOff = "web_off"
}

extension AppSession {
    func memoryNotes() async -> [MemoryNote] {
        do {
            return try await client
                .from("person_memory")
                .select("id, note")
                .order("created_at", ascending: true)
                .execute()
                .value
        } catch {
            return []
        }
    }

    func forget(_ note: MemoryNote) async -> Bool {
        do {
            try await client.from("person_memory").delete().eq("id", value: note.id.uuidString).execute()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    func clearMemory() async -> Bool {
        guard let user = client.auth.currentUser else { return false }
        do {
            try await client.from("person_memory").delete().eq("user_id", value: user.id.uuidString).execute()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// Off unless it was switched on: both switches default to the chat's normal behaviour.
    func isOn(_ flag: AccountSwitch) -> Bool {
        if case .bool(let value) = client.auth.currentUser?.userMetadata[flag.rawValue] { return value }
        return false
    }

    func set(_ flag: AccountSwitch, _ value: Bool) async {
        do {
            _ = try await client.auth.update(user: UserAttributes(data: [flag.rawValue: .bool(value)]))
        } catch {
            lastError = readableMessage(error)
        }
    }

    func trends() async -> [TrendCard] {
        struct Request: Encodable {
            let region: String?
            let timezone: String
        }
        struct Response: Decodable {
            let items: [TrendCard]
        }
        do {
            let response: Response = try await client.functions.invoke(
                "trends",
                options: FunctionInvokeOptions(body: Request(
                    region: Locale.current.region?.identifier,
                    timezone: TimeZone.current.identifier
                ))
            )
            return response.items
        } catch {
            return []
        }
    }
}
