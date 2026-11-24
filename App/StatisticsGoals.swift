import FITgapCore
import SwiftUI

extension StatsMetric {
    var symbol: String {
        switch self {
        case .distance: "point.topleft.down.to.point.bottomright.curvepath"
        case .duration: "clock"
        case .ascent: "mountain.2"
        case .count: "number"
        case .energy: "flame"
        }
    }

    /// Factor from the unit typed in for a goal (km, h, m, count, kcal) to the stored base unit.
    var inputFactor: Double {
        switch self {
        case .distance: 1000
        case .duration: 3600
        default: 1
        }
    }
}

extension StatsGoal {
    var title: String {
        "\(category?.title ?? String(localized: "Alle Sportarten")) · \(statsMetric.title)"
    }

    var symbol: String { category?.symbol ?? statsMetric.symbol }
    var color: Color { category?.color ?? .accentColor }
}

/// Progress of one goal with the forecast at the pace so far; tapping edits the goal.
struct GoalRow: View {
    let goal: StatsGoal
    let entries: [StatsEntry]
    let edit: () -> Void

    var body: some View {
        let metric = goal.statsMetric
        let total = YearSummary(year: goal.year, entries: entries, categories: goal.category.map { [$0] }).total(metric)
        let share = goal.target > 0 ? total / goal.target : 0
        let forecast = StatsForecast.make(total: total, now: .now, year: goal.year, target: goal.target)
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label { Text(goal.title) } icon: { Image(systemName: goal.symbol).foregroundStyle(goal.color) }
                    Spacer()
                    Text(min(share, 9.99).formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: min(share, 1)).tint(goal.color)
                Text("\(metric.formatted(total)) von \(metric.formatted(goal.target))")
                    .font(.subheadline).monospacedDigit()
                status(total: total, metric: metric, forecast: forecast)
                    .font(.caption)
            }
            .padding(.vertical, 2)
        }
        .tint(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Bearbeitet das Ziel")
    }

    @ViewBuilder
    private func status(total: Double, metric: StatsMetric, forecast: StatsForecast?) -> some View {
        if total >= goal.target {
            Label("Ziel erreicht", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        } else if let forecast {
            VStack(alignment: .leading, spacing: 2) {
                if let reached = forecast.reached {
                    Label("Prognose: erreicht am \(reached.formatted(.dateTime.day().month(.abbreviated)))",
                          systemImage: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.green)
                } else {
                    Label("Prognose: \(metric.formatted(forecast.yearEnd)) bis Jahresende",
                          systemImage: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.orange)
                }
                if let perWeek = forecast.perWeek {
                    Text("Noch \(metric.formatted(goal.target - total)), etwa \(metric.formatted(perWeek)) pro Woche")
                        .foregroundStyle(.secondary)
                }
            }
        } else if goal.year < Calendar.current.component(.year, from: .now) {
            Label("Nicht erreicht", systemImage: "xmark.seal").foregroundStyle(.secondary)
        }
    }
}

/// Creates or changes a year goal; the unit follows the metric.
struct GoalEditor: View {
    @State var goal: StatsGoal
    let isNew: Bool
    let save: (StatsGoal) -> Void
    let delete: (StatsGoal) -> Void
    @State private var value: Double?
    @Environment(\.dismiss) private var dismiss

    init(goal: StatsGoal, isNew: Bool, save: @escaping (StatsGoal) -> Void, delete: @escaping (StatsGoal) -> Void) {
        _goal = State(initialValue: goal)
        _value = State(initialValue: isNew ? nil : goal.target / goal.statsMetric.inputFactor)
        self.isNew = isNew
        self.save = save
        self.delete = delete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sportart", selection: $goal.category) {
                        Label("Alle Sportarten", systemImage: "chart.bar.xaxis").tag(StatsCategory?.none)
                        ForEach(StatsCategory.allCases) { category in
                            Label(category.title, systemImage: category.symbol).tag(StatsCategory?.some(category))
                        }
                    }
                    Picker("Kennzahl", selection: Binding(get: { goal.statsMetric }, set: { goal.metric = $0.rawValue })) {
                        ForEach(StatsMetric.allCases) { metric in
                            Label(metric.title, systemImage: metric.symbol).tag(metric)
                        }
                    }
                    LabeledContent("Ziel") {
                        HStack {
                            TextField("Wert", value: $value, format: .number.precision(.fractionLength(0...1)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("goal-value")
                            if !goal.statsMetric.unit.isEmpty { Text(goal.statsMetric.unit).foregroundStyle(.secondary) }
                        }
                    }
                } footer: {
                    Text("Das Ziel gilt für \(String(goal.year)). Die Prognose rechnet das bisherige Tempo bis zum Jahresende hoch.")
                }
                if !isNew {
                    Section {
                        Button("Ziel löschen", systemImage: "trash", role: .destructive) {
                            delete(goal)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? String(localized: "Neues Ziel") : String(localized: "Ziel"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", systemImage: "checkmark") {
                        guard let value else { return }
                        goal.target = value * goal.statsMetric.inputFactor
                        save(goal)
                        dismiss()
                    }
                    .disabled((value ?? 0) <= 0)
                }
            }
        }
    }
}
