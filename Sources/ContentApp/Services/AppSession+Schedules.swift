import EventKit
import Foundation
import Supabase

/// Something made ahead and sent at a set time, once or on repeat (0095).
/// Abel, 3 Nov 2026: "it must send it at the exact time I asked."
struct DropSchedule: Decodable, Identifiable, Equatable, Sendable {
    struct Options: Codable, Equatable, Sendable {
        var calendar: Bool?
        var ping: Bool?
        var fresh: Bool?
    }

    let id: UUID
    var status: String
    let summary: String
    let withText: String?
    var timezone: String
    var startsAt: Date
    var repeatRule: String
    var days: [Int]
    var endsAt: Date?
    var endsAfter: Int?
    let delivered: Int
    var nextAt: Date?
    var options: Options
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, status, summary, timezone, days, delivered, options
        case createdAt = "created_at"
        case withText = "with_text"
        case startsAt = "starts_at"
        case repeatRule = "repeat"
        case endsAt = "ends_at"
        case endsAfter = "ends_after"
        case nextAt = "next_at"
    }

    static let columns = "id, status, summary, with_text, timezone, starts_at, repeat, days, ends_at, ends_after, delivered, next_at, options, created_at"

    var zone: TimeZone { TimeZone(identifier: timezone) ?? .current }

    /// "Every day · 2:00 AM", "Wed, Nov 4 · 2:00 AM".
    var whenText: String {
        let time = startsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
        switch repeatRule {
        case "daily": return "Every day · \(time)"
        case "weekdays": return "Weekdays · \(time)"
        case "weekly", "custom":
            let names = Calendar.current.shortWeekdaySymbols
            let picked = days.sorted().compactMap { names.indices.contains($0) ? names[$0] : nil }
            let label = picked.count == 1 ? "Every \(picked[0])" : picked.joined(separator: ", ")
            return "\(label) · \(time)"
        default:
            let day = startsAt.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day())
            return "\(day) · \(time)"
        }
    }
}

extension AppSession {
    func dropSchedule(_ id: UUID) async -> DropSchedule? {
        try? await client
            .from("schedules")
            .select(DropSchedule.columns)
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    /// Everything still coming, soonest first.
    func dropSchedules() async -> [DropSchedule] {
        (try? await client
            .from("schedules")
            .select(DropSchedule.columns)
            .in("status", values: ["active", "paused"])
            .order("next_at", ascending: true)
            .execute()
            .value) ?? []
    }

    /// Confirms a draft or saves a change; the server works out the next time.
    func saveSchedule(_ schedule: DropSchedule) async -> DropSchedule? {
        struct Params: Encodable {
            let schedule: DropSchedule
            enum Keys: String, CodingKey {
                case p_id, p_starts_at, p_timezone, p_repeat, p_days, p_ends_at, p_ends_after, p_options
            }
            func encode(to encoder: Encoder) throws {
                let iso = ISO8601DateFormatter()
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(schedule.id.uuidString, forKey: .p_id)
                try c.encode(iso.string(from: schedule.startsAt), forKey: .p_starts_at)
                try c.encode(TimeZone.current.identifier, forKey: .p_timezone)
                try c.encode(schedule.repeatRule, forKey: .p_repeat)
                try c.encode(schedule.days, forKey: .p_days)
                if let ends = schedule.endsAt { try c.encode(iso.string(from: ends), forKey: .p_ends_at) } else { try c.encodeNil(forKey: .p_ends_at) }
                if let after = schedule.endsAfter { try c.encode(after, forKey: .p_ends_after) } else { try c.encodeNil(forKey: .p_ends_after) }
                try c.encode(schedule.options, forKey: .p_options)
            }
        }
        do {
            // The function returns the whole row, as one object.
            let saved: DropSchedule = try await client
                .rpc("save_schedule", params: Params(schedule: schedule))
                .execute()
                .value
            return saved
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }

    func cancelSchedule(_ id: UUID) async {
        _ = try? await client.rpc("cancel_schedule", params: ["p_id": id.uuidString]).execute()
    }

    func pauseSchedules(_ paused: Bool) async {
        _ = try? await client.rpc("pause_schedules", params: ["p_paused": paused]).execute()
    }

    /// "Add to my Calendar": one event, repeating the way the drop does. Asked
    /// for write access only -- Postpilot never reads the calendar.
    func addToCalendar(_ schedule: DropSchedule) async {
        let store = EKEventStore()
        guard (try? await store.requestWriteOnlyAccessToEvents()) == true,
              let calendar = store.defaultCalendarForNewEvents else { return }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "Postpilot: \(schedule.summary)"
        event.notes = "Arrives in your Postpilot chat."
        event.startDate = schedule.nextAt ?? schedule.startsAt
        event.endDate = event.startDate.addingTimeInterval(15 * 60)
        if let rule = Self.recurrence(for: schedule) { event.addRecurrenceRule(rule) }
        try? store.save(event, span: .futureEvents)
    }

    private static func recurrence(for schedule: DropSchedule) -> EKRecurrenceRule? {
        let end: EKRecurrenceEnd? = schedule.endsAfter.map { EKRecurrenceEnd(occurrenceCount: $0) }
            ?? schedule.endsAt.map { EKRecurrenceEnd(end: $0) }
        let weekdays: [Int]
        switch schedule.repeatRule {
        case "daily":
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: end)
        case "weekdays": weekdays = [1, 2, 3, 4, 5]
        case "weekly", "custom": weekdays = schedule.days
        default: return nil
        }
        let days = weekdays.compactMap { EKWeekday(rawValue: $0 + 1) }.map { EKRecurrenceDayOfWeek($0) }
        return EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days,
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
            end: end
        )
    }
}

extension AppSession {
    /// The drops made by the same request as this one ("3 pictures a day" is
    /// three schedules saved in the same moment), this one included, soonest
    /// time of day first.
    func dropSiblings(of drop: DropSchedule) async -> [DropSchedule] {
        guard let made = drop.createdAt else { return [drop] }
        let all: [DropSchedule] = (try? await client
            .from("schedules")
            .select(DropSchedule.columns)
            .in("status", values: ["draft", "active", "paused"])
            .gte("created_at", value: ISO8601DateFormatter().string(from: made.addingTimeInterval(-15)))
            .lte("created_at", value: ISO8601DateFormatter().string(from: made.addingTimeInterval(15)))
            .execute()
            .value) ?? [drop]
        let same = all.filter { $0.summary == drop.summary }
        return (same.isEmpty ? [drop] : same).sorted { $0.startsAt < $1.startsAt }
    }
}
