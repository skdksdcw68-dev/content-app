import Foundation
import Supabase

extension AppSession {
    /// Ideas for the next video, from this account's own posts.
    ///
    /// Two reads in one call. The rows are readable under RLS, so the normal
    /// path is a plain table read -- cheap, offline-tolerant and free. The
    /// Edge Function is only asked when there is nothing to show or when
    /// somebody pulls to refresh, because that call bills a model.
    func refreshInspiration(force: Bool = false) async {
        guard brand != nil else { return }
        if !force, await loadStoredIdeas(), !inspiration.isEmpty { return }
        await computeInspiration(force: force)
    }

    /// What is already in the table. Returns whether the read worked at all,
    /// so a network failure is not mistaken for an empty feed.
    @discardableResult
    private func loadStoredIdeas() async -> Bool {
        guard let brandID = brand?.id else { return false }
        do {
            inspiration = try await client
                .from("inspiration_ideas")
                .select("id,key,hook,angle,because,measured,seconds,format,hashtags")
                .eq("brand_id", value: brandID.uuidString)
                .eq("status", value: "new")
                .order("computed_at", ascending: false)
                .limit(12)
                .execute()
                .value
            return true
        } catch {
            return false
        }
    }

    /// Asks the function to write a fresh set. The only call here that costs
    /// anything, so it is never made on a plain screen appearance.
    private func computeInspiration(force: Bool) async {
        guard let brandID = brand?.id, !isFindingIdeas else { return }
        isFindingIdeas = true
        defer { isFindingIdeas = false }

        struct Request: Encodable, Sendable {
            let brand_id: String
            let force: Bool
        }
        struct Response: Decodable {
            let ideas: [InspirationIdea]
        }
        do {
            let response: Response = try await client.functions.invoke(
                "inspiration",
                options: FunctionInvokeOptions(body: Request(brand_id: brandID.uuidString, force: force))
            )
            inspiration = response.ideas
        } catch {
            // Quiet. An empty ideas row is not worth an alert over a screen
            // somebody did not ask to see -- but if the table already had
            // something, keep showing it rather than blanking the shelf.
            await loadStoredIdeas()
        }
    }

    /// Opens the video page with this idea already written into it, and marks
    /// it used so it stops being suggested.
    func make(_ idea: InspirationIdea) {
        push(.makeVideo(idea.brief))
        Task { await setIdeaStatus(idea, to: "made") }
    }

    /// "Not for me." It goes, and the next refresh will not write it again.
    func dismiss(_ idea: InspirationIdea) {
        inspiration.removeAll { $0.id == idea.id }
        Task { await setIdeaStatus(idea, to: "hidden") }
    }

    private func setIdeaStatus(_ idea: InspirationIdea, to status: String) async {
        struct Params: Encodable, Sendable {
            let p_idea: String
            let p_status: String
        }
        do {
            try await client
                .rpc("set_inspiration_status", params: Params(p_idea: idea.id.uuidString, p_status: status))
                .execute()
        } catch {
            // The card has already gone from the screen. Losing the mark means
            // it comes back tomorrow, which is a smaller harm than an alert
            // over a tap that looked like it worked.
        }
    }
}
