import SwiftUI

/// The Schedule sheet (mockup approved 3 Nov 2026): what arrives, when -- on
/// Apple's own wheel, as Abel asked ("a native date picker, like a wheel") --
/// how it repeats, and the switches. Opens by itself when the chat saves a
/// draft, and again from the card to change or cancel it.
struct ScheduleSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State var schedule: DropSchedule
    var onSaved: (DropSchedule) -> Void = { _ in }

    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                whatSection
                whenSection
                optionsSection
                if schedule.status == "active" || schedule.status == "paused" {
                    Section {
                        Button("Cancel this drop", role: .destructive) { cancel() }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(GrokLook.sheet(scheme).ignoresSafeArea())
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) { scheduleButton }
        }
        .grokSettings()
        .presentationDetents([.large])
        .presentationCornerRadius(34)
    }

    private var whatSection: some View {
        Section("What you get") {
            Label(schedule.summary, systemImage: "photo.on.rectangle")
            if let words = schedule.withText {
                Label(words.prefix(1).uppercased() + words.dropFirst(), systemImage: "text.alignleft")
            }
        }
    }

    private var whenSection: some View {
        Section("When") {
            LabeledContent {
                Text(schedule.whenText).foregroundStyle(Color.green)
            } label: {
                Label("Starts", systemImage: "clock")
            }
            DatePicker("Starts", selection: $schedule.startsAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            NavigationLink {
                RepeatView(schedule: $schedule)
            } label: {
                LabeledContent {
                    Text(RepeatView.title(of: schedule))
                } label: {
                    Label("Repeat", systemImage: "repeat")
                }
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle(isOn: option(\.calendar)) { Label("Add to my Calendar", systemImage: "calendar") }
            Toggle(isOn: option(\.ping)) { Label("Ping me when it arrives", systemImage: "bell") }
            if schedule.repeatRule != "none" {
                Toggle(isOn: option(\.fresh)) { Label("New ideas each time", systemImage: "sparkles") }
            }
        }
    }

    private var scheduleButton: some View {
        Button(action: save) {
            Group {
                if saving { ProgressView().tint(.black) } else { Text(schedule.status == "draft" ? "Schedule" : "Save") }
            }
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color(white: 0.95), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(GrokLook.sheet(scheme))
    }

    /// A switch that is on until it is turned off.
    private func option(_ key: WritableKeyPath<DropSchedule.Options, Bool?>) -> Binding<Bool> {
        Binding(
            get: { schedule.options[keyPath: key] ?? true },
            set: { on in withAnimation(.snappy(duration: 0.25)) { schedule.options[keyPath: key] = on } }
        )
    }

    private func save() {
        saving = true
        let firstTime = schedule.status == "draft"
        Task {
            if let saved = await session.saveSchedule(schedule) {
                if firstTime, saved.options.calendar ?? true { await session.addToCalendar(saved) }
                onSaved(saved)
                dismiss()
            }
            saving = false
        }
    }

    private func cancel() {
        Task {
            await session.cancelSchedule(schedule.id)
            schedule.status = "cancelled"
            onSaved(schedule)
            dismiss()
        }
    }
}

/// Never, every day, weekdays, every week, or the days picked -- and when it ends.
struct RepeatView: View {
    @Binding var schedule: DropSchedule
    @Environment(\.colorScheme) private var scheme

    private struct Choice: Identifiable {
        let id: String
        let title: String
    }

    private static let choices = [
        Choice(id: "none", title: "Never"), Choice(id: "daily", title: "Every day"), Choice(id: "weekdays", title: "Weekdays"),
        Choice(id: "weekly", title: "Every week"), Choice(id: "custom", title: "Pick days"),
    ]

    static func title(of schedule: DropSchedule) -> String {
        choices.first { $0.id == schedule.repeatRule }?.title ?? "Never"
    }

    var body: some View {
        List {
            Section {
                ForEach(Self.choices) { choice in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { pick(choice.id) }
                    } label: {
                        HStack {
                            Text(choice.title).foregroundStyle(Color.primary)
                            Spacer()
                            if schedule.repeatRule == choice.id {
                                Image(systemName: "checkmark").fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            if schedule.repeatRule != "none" {
                Section("On these days") { DayChips(schedule: $schedule) }
                Section("Ends") { EndsRows(schedule: $schedule) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GrokLook.sheet(scheme).ignoresSafeArea())
        .navigationTitle("Repeat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pick(_ key: String) {
        schedule.repeatRule = key
        let weekday = Calendar.current.component(.weekday, from: schedule.startsAt) - 1
        switch key {
        case "weekly": schedule.days = [weekday]
        case "custom" where schedule.days.isEmpty: schedule.days = [weekday]
        default: break
        }
    }
}

/// S M T W T F S. Tapping one makes the schedule "Pick days".
private struct DayChips: View {
    @Binding var schedule: DropSchedule

    private var active: [Int] {
        switch schedule.repeatRule {
        case "daily": return Array(0...6)
        case "weekdays": return [1, 2, 3, 4, 5]
        default: return schedule.days
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { day in
                let on = active.contains(day)
                Button {
                    var picked = Set(active)
                    if on { picked.remove(day) } else { picked.insert(day) }
                    guard !picked.isEmpty else { return }
                    withAnimation(.snappy(duration: 0.2)) {
                        schedule.repeatRule = "custom"
                        schedule.days = picked.sorted()
                    }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[day])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(on ? Color.black : Color.primary)
                        .background(on ? Color(white: 0.95) : Color.clear, in: Circle())
                        .overlay(Circle().strokeBorder(Color.secondary.opacity(on ? 0 : 0.35)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// Never, on a date, or after a number of drops.
private struct EndsRows: View {
    @Binding var schedule: DropSchedule

    var body: some View {
        row("Never", on: schedule.endsAt == nil && schedule.endsAfter == nil) {
            schedule.endsAt = nil
            schedule.endsAfter = nil
        }
        row("On a date", on: schedule.endsAt != nil) {
            schedule.endsAfter = nil
            schedule.endsAt = Calendar.current.date(byAdding: .month, value: 1, to: schedule.startsAt)
        }
        if let ends = schedule.endsAt {
            DatePicker("Last drop", selection: Binding(get: { ends }, set: { schedule.endsAt = $0 }), in: schedule.startsAt..., displayedComponents: .date)
        }
        row("After a number of drops", on: schedule.endsAfter != nil) {
            schedule.endsAt = nil
            schedule.endsAfter = 30
        }
        if let count = schedule.endsAfter {
            Stepper("\(count) drops", value: Binding(get: { count }, set: { schedule.endsAfter = $0 }), in: 1...365)
        }
    }

    private func row(_ title: String, on: Bool, pick: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { pick() }
        } label: {
            HStack {
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                if on { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
        }
    }
}
