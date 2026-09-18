import SwiftUI

/// The range pills, the way Studio does them: big, full-height capsules that
/// scroll edge to edge, the chosen one solid ink, the rest quiet grey, and
/// Custom carrying a chevron because it opens something.
struct AnalyticsRangeBar: View {
    @Binding var rangeKey: String
    /// "Sep 1 – Sep 15" once a custom range is chosen.
    let customLabel: String?
    let openCustom: () -> Void

    private let presets = ["7", "28", "60", "365"]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets, id: \.self) { key in
                        pill("\(key) days", isOn: rangeKey == key) {
                            withAnimation(.snappy(duration: 0.25)) { rangeKey = key }
                        }
                        .id(key)
                    }
                    pill(rangeKey == "custom" ? (customLabel ?? "Custom") : "Custom",
                         isOn: rangeKey == "custom",
                         chevron: true) {
                        openCustom()
                    }
                    .id("custom")
                }
            }
            .contentMargins(.horizontal, Style.gutter, for: .scrollContent)
            .onAppear { proxy.scrollTo(rangeKey, anchor: .center) }
            .onChange(of: rangeKey) { _, key in
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(key, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: rangeKey)
    }

    private func pill(_ title: String, isOn: Bool, chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if chevron {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                }
            }
            .font(.body.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Theme.onAccent : Color.primary.opacity(0.75))
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(isOn ? Color.accentColor : Color.track, in: Capsule())
        }
        .buttonStyle(SoftPressStyle())
    }
}

/// Start, end, and the shortcuts people actually reach for.
struct CustomRangeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var start: Date
    @State private var end: Date
    let apply: (Date, Date) -> Void

    init(start: Date, end: Date, apply: @escaping (Date, Date) -> Void) {
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        self.apply = apply
    }

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    /// Two years at most: the report refuses more, and says so.
    private var isValid: Bool {
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return start <= end && end <= today && days <= 730
    }

    private struct Shortcut: Identifiable {
        let title: String
        let start: Date
        let end: Date
        var id: String { title }
    }

    private var shortcuts: [Shortcut] {
        let calendar = Calendar.current
        let day = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let lastMonthEnd = calendar.date(byAdding: .day, value: -1, to: monthStart) ?? today
        let lastMonthStart = calendar.dateInterval(of: .month, for: lastMonthEnd)?.start ?? lastMonthEnd
        let yearStart = calendar.dateInterval(of: .year, for: today)?.start ?? today
        return [
            Shortcut(title: "Last 3 days", start: day(-2), end: today),
            Shortcut(title: "Last 14 days", start: day(-13), end: today),
            Shortcut(title: "Last 30 days", start: day(-29), end: today),
            Shortcut(title: "This month", start: monthStart, end: today),
            Shortcut(title: "Last month", start: lastMonthStart, end: lastMonthEnd),
            Shortcut(title: "This year", start: yearStart, end: today),
        ]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Shortcuts") {
                    ForEach(shortcuts) { shortcut in
                        Button {
                            start = shortcut.start
                            end = shortcut.end
                        } label: {
                            HStack {
                                Text(shortcut.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if Calendar.current.isDate(start, inSameDayAs: shortcut.start)
                                    && Calendar.current.isDate(end, inSameDayAs: shortcut.end) {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }

                Section {
                    DatePicker("Start date", selection: $start, in: ...end, displayedComponents: .date)
                    DatePicker("End date", selection: $end, in: start...today, displayedComponents: .date)
                } footer: {
                    Text(isValid
                         ? "Compared with the same number of days just before it."
                         : "Choose an end date on or after the start, no later than today, within two years.")
                }
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply(Calendar.current.startOfDay(for: start), Calendar.current.startOfDay(for: end))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
            .sensoryFeedback(.selection, trigger: start)
        }
        .presentationDetents([.large])
    }
}

/// Platform and content filters, folded into one menu so Analytics does not
/// turn into a form. Only what exists is offered: connected platforms, formats
/// that have posts, themes and campaigns this brand has.
struct AnalyticsFilterMenu: View {
    let platforms: [String]
    let filters: AnalyticsReport.Filters?
    @Binding var platform: String?
    @Binding var format: String?
    @Binding var pillarId: UUID?
    @Binding var planId: UUID?

    private var activeCount: Int {
        [platform != nil, format != nil, pillarId != nil, planId != nil].filter { $0 }.count
    }

    var body: some View {
        Menu {
            Picker("Platform", selection: $platform) {
                Text("All platforms").tag(String?.none)
                ForEach(platforms, id: \.self) { raw in
                    Text(Platform(rawValue: raw)?.displayName ?? raw.capitalized).tag(String?.some(raw))
                }
            }
            .pickerStyle(.menu)

            if let formats = filters?.formats, formats.count > 1 {
                Picker("Format", selection: $format) {
                    Text("All formats").tag(String?.none)
                    ForEach(formats, id: \.self) { value in
                        Text(value.capitalized).tag(String?.some(value))
                    }
                }
                .pickerStyle(.menu)
            }

            if let pillars = filters?.pillars, !pillars.isEmpty {
                Picker("Theme", selection: $pillarId) {
                    Text("All themes").tag(UUID?.none)
                    ForEach(pillars) { option in
                        Text(option.name).tag(UUID?.some(option.id))
                    }
                }
                .pickerStyle(.menu)
            }

            if let campaigns = filters?.campaigns, !campaigns.isEmpty {
                Picker("Campaign", selection: $planId) {
                    Text("All campaigns").tag(UUID?.none)
                    ForEach(campaigns) { option in
                        Text(option.name).tag(UUID?.some(option.id))
                    }
                }
                .pickerStyle(.menu)
            }

            if activeCount > 0 {
                Divider()
                Button("Clear filters", role: .destructive) {
                    platform = nil
                    format = nil
                    pillarId = nil
                    planId = nil
                }
            }
        } label: {
            // A toolbar icon: filled when something is filtered, so a
            // narrowed page never passes for the whole account.
            Image(systemName: activeCount > 0
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .accessibilityLabel(activeCount > 0 ? "Filters, \(activeCount) on" : "Filter")
        }
        .sensoryFeedback(.selection, trigger: activeCount)
    }
}
