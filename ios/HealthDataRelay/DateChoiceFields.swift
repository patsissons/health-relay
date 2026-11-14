import HealthDataRelayKit
import SwiftUI

/// Dates picked by hand: a preset, or nil for the two dates.
struct DateChoice {
    var preset: DateRangePreset? = .last7Days
    var from = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
    var to = Date.now

    var interval: DateInterval {
        let calendar = Calendar.local()
        if let preset { return preset.interval(now: .now, calendar: calendar) }
        let start = calendar.startOfDay(for: from)
        let last = min(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!, .now)
        return DateInterval(start: start, end: max(last, start.addingTimeInterval(1)))
    }
}

/// The range picker, and the two dates when it's on Custom. A range longer
/// than the plan's history reaches shows a lock and opens the plans instead.
struct DateChoiceFields: View {
    @Environment(AppModel.self) private var model
    @Binding var dates: DateChoice
    let id: String
    @State private var unlocking = false

    private var history: HistoryLimit { model.store.access.history }

    /// The earliest date Custom can start from; nil with Full.
    private var floor: Date? { history.floor(now: .now, calendar: .local()) }

    var body: some View {
        Picker("Range", selection: $dates.preset) {
            ForEach(DateRangePreset.allCases, id: \.self) { preset in
                if history.allows(lastDays: preset.days) {
                    Text(preset.title).tag(DateRangePreset?.some(preset))
                } else {
                    Label(preset.title, systemImage: "lock.fill").tag(DateRangePreset?.some(preset))
                }
            }
            Text("Custom").tag(DateRangePreset?.none)
        }
        .accessibilityIdentifier(id)
        .onChange(of: dates.preset) { old, new in
            if let new, !history.allows(lastDays: new.days) {
                dates.preset = old
                unlocking = true
                return
            }
            // Custom starts from what was just showing.
            guard new == nil, let interval = old?.interval(now: .now, calendar: Calendar.local()) else { return }
            dates.from = interval.start
            dates.to = interval.end
        }
        .sheet(isPresented: $unlocking) { UnlockView() }
        if dates.preset == nil {
            DatePicker("From", selection: $dates.from, in: (floor ?? .distantPast)...dates.to, displayedComponents: .date)
                .accessibilityIdentifier("range-from")
            DatePicker("To", selection: $dates.to, in: dates.from...Date.now, displayedComponents: .date)
        }
        if let days = history.days {
            Button {
                unlocking = true
            } label: {
                Label("Reaches back \(days) days until you unlock Full", systemImage: "lock.fill")
                    .font(.subheadline)
            }
            .accessibilityIdentifier("\(id)-needs-full")
        }
    }
}

extension DateRangePreset {
    var title: String {
        switch self {
        case .last24Hours: "Last 24 hours"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .last90Days: "Last 90 days"
        case .last365Days: "Last 365 days"
        }
    }

    /// How many days back it starts, for checking against the plan's history.
    var days: Int {
        switch self {
        case .last24Hours: 1
        case .last7Days: 7
        case .last30Days: 30
        case .last90Days: 90
        case .last365Days: 365
        }
    }
}
