import Charts
import FITgapCore
import SwiftUI

/// Everything or one sport group.
enum StatsScope: Hashable {
    case all
    case category(StatsCategory)

    var categories: Set<StatsCategory>? {
        if case .category(let category) = self { [category] } else { nil }
    }
}

extension StatsCategory {
    var title: String {
        switch self {
        case .cycling: String(localized: "Radfahren")
        case .running: String(localized: "Laufen")
        case .swimming: String(localized: "Schwimmen")
        case .walking: String(localized: "Gehen")
        case .hiking: String(localized: "Wandern")
        case .rowing: String(localized: "Rudern")
        case .other: String(localized: "Sonstige")
        }
    }

    var symbol: String {
        switch self {
        case .cycling: "figure.outdoor.cycle"
        case .running: "figure.run"
        case .swimming: "figure.pool.swim"
        case .walking: "figure.walk"
        case .hiking: "figure.hiking"
        case .rowing: "figure.rower"
        case .other: "figure.mixed.cardio"
        }
    }

    var color: Color {
        switch self {
        case .cycling: .green
        case .running: .orange
        case .swimming: .cyan
        case .walking: .yellow
        case .hiking: .brown
        case .rowing: .indigo
        case .other: .gray
        }
    }
}

extension StatsMetric {
    var title: String {
        switch self {
        case .distance: String(localized: "Strecke")
        case .duration: String(localized: "Zeit")
        case .ascent: String(localized: "Höhenmeter")
        case .count: String(localized: "Aktivitäten")
        case .energy: String(localized: "Energie")
        }
    }

    /// Short segment title; the full title is the accessibility label.
    var shortTitle: String {
        switch self {
        case .distance: String(localized: "Strecke")
        case .duration: String(localized: "Zeit")
        case .ascent: String(localized: "Hm")
        case .count: String(localized: "Anzahl")
        case .energy: String(localized: "kcal")
        }
    }

    /// Value in the unit the charts use: km, hours, m, count or kcal.
    func plotted(_ value: Double) -> Double {
        switch self {
        case .distance: value / 1000
        case .duration: value / 3600
        default: value
        }
    }

    var unit: String {
        switch self {
        case .distance: "km"
        case .duration: "h"
        case .ascent: "m"
        case .count: ""
        case .energy: "kcal"
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .distance:
            let km = value / 1000
            return km.formatted(.number.precision(.fractionLength(km < 100 ? 1 : 0))) + " km"
        case .duration:
            return Duration.seconds(value.rounded()).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        case .ascent: return ActivityFormat.meters(value)
        case .count: return ActivityFormat.integer(value)
        case .energy: return ActivityFormat.integer(value) + " kcal"
        }
    }
}

/// Year statistics of FITgap activities and Apple Health workouts: totals, comparison year and animated charts.
/// Sport groups and details sit side by side on wide screens such as the unfolded iPhone Duo; the system sizes the columns.
struct StatisticsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var stats = StatisticsModel()
    @State private var selection: StatsScope?
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var comparison: Int? = Calendar.current.component(.year, from: .now) - 1
    @State private var yearToDate = true
    @State private var metric = StatsMetric.distance
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var currentYear: Int { Calendar.current.component(.year, from: .now) }
    private var period: StatsPeriod {
        StatsPeriod(year: year, comparison: comparison, yearToDate: yearToDate && year == currentYear)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    row(.all, title: String(localized: "Alle Sportarten"), symbol: "chart.bar.xaxis", color: .accentColor)
                }
                let categories = presentCategories
                if !categories.isEmpty {
                    Section("Sportarten") {
                        ForEach(categories) { category in
                            row(.category(category), title: category.title, symbol: category.symbol, color: category.color)
                        }
                    }
                }
                Section {
                } footer: {
                    StatisticsSourcesNote(stats: stats, isDemo: model.isDemo)
                }
            }
            .navigationTitle(String(localized: "Statistik \(String(year))"))
            .toolbar { ToolbarItem(placement: .primaryAction) { periodMenu } }
            .safeAreaInset(edge: .bottom) { DemoIndicator(enabled: model.isDemo) }
        } detail: {
            NavigationStack {
                StatisticsDetail(model: model, stats: stats, scope: selection ?? .all, period: period, metric: $metric)
                    .navigationDestination(for: ActivityKey.self) { key in
                        if let activity = model.activities.first(where: { $0.key == key }) {
                            ActivityDetailView(model: model, initial: activity)
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { if sizeClass == .regular, selection == nil { selection = .all } }
        .onReceive(model.$duplicates) { groups in stats.update(model.activities, hidden: groups.hidden) }
        .task(id: model.isDemo) { await stats.loadHealth(enabled: !model.isDemo) }
        .task(id: [year, comparison ?? 0, stats.healthState == .loaded ? 1 : 0]) {
            await stats.complete(years: [year] + (comparison.map { [$0] } ?? []))
        }
    }

    /// Sport groups with activity in the shown or the comparison year.
    private var presentCategories: [StatsCategory] {
        let years = Set([year] + (comparison.map { [$0] } ?? []))
        let present = Set(stats.entries.filter { years.contains(Calendar.current.component(.year, from: $0.date)) }.map(\.category))
        return StatsCategory.allCases.filter(present.contains)
    }

    private func row(_ scope: StatsScope, title: String, symbol: String, color: Color) -> some View {
        let current = period.summary(stats.entries, categories: scope.categories)
        let previous = period.comparisonSummary(stats.entries, categories: scope.categories)
        return LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(metric.formatted(current.total(metric)))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let previous { ChangeText(value: current.total(metric), previous: previous.total(metric), year: previous.year) }
            }
        } label: {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
        }
        .animation(.default, value: current.total(metric))
        .tag(scope)
        .accessibilityIdentifier("stats-scope-\(scope.categories?.first?.rawValue ?? "all")")
    }

    private var periodMenu: some View {
        Menu {
            Picker("Jahr", selection: $year) {
                ForEach(stats.years, id: \.self) { Text(String($0)).tag($0) }
            }
            Picker("Vergleich", selection: $comparison) {
                Text("Kein Vergleich").tag(Int?.none)
                ForEach(stats.years.filter { $0 != year }, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
            }
            if year == currentYear, comparison != nil {
                Toggle("Bis zum heutigen Datum", isOn: $yearToDate)
            }
        } label: {
            Label("Zeitraum", systemImage: "calendar")
        }
        .accessibilityIdentifier("stats-period")
        .onChange(of: year) { old, new in
            // The comparison follows the shown year unless another one was picked.
            if comparison == old - 1 || comparison == new { comparison = new - 1 }
        }
    }
}

/// The shown year and the one it is compared with; the current year can compare up to today's date.
struct StatsPeriod: Equatable {
    let year: Int
    let comparison: Int?
    let yearToDate: Bool

    func summary(_ entries: [StatsEntry], categories: Set<StatsCategory>?) -> YearSummary {
        YearSummary(year: year, entries: entries, categories: categories)
    }

    func comparisonSummary(_ entries: [StatsEntry], categories: Set<StatsCategory>?) -> YearSummary? {
        comparison.map { other in
            YearSummary(year: other, entries: entries, categories: categories,
                        until: yearToDate ? YearSummary.sameDate(.now, inYear: other) : nil)
        }
    }

    /// End of the curve: today for the current year, otherwise the end of the year.
    func end(of summaryYear: Int) -> Date {
        let range = YearSummary.range(summaryYear)
        if summaryYear == year { return min(.now, range.end) }
        return yearToDate ? YearSummary.sameDate(.now, inYear: summaryYear) : range.end
    }
}

/// Relative change to the comparison year, e.g. “+12 % vs. 2025”.
struct ChangeText: View {
    let value: Double
    let previous: Double
    let year: Int

    var body: some View {
        if let change = YearSummary.change(value, from: previous) {
            Label {
                Text("\(change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))) ggü. \(String(year))")
            } icon: {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
            }
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
        } else if previous == 0, value > 0 {
            Text("Neu ggü. \(String(year))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Where the numbers come from and what is missing.
struct StatisticsSourcesNote: View {
    @ObservedObject var stats: StatisticsModel
    let isDemo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isDemo {
                Text("Im Demo-Modus zählt die Statistik nur die Demo-Aktivitäten.")
            } else {
                switch stats.healthState {
                case .off:
                    Text("Die Statistik zählt die Aktivitäten in FITgap.")
                case .loading:
                    Text("Trainings aus Apple Health werden gelesen …")
                case .loaded:
                    if stats.healthCount > 0 {
                        Text("Enthält \(stats.healthCount) Trainings, die nur in Apple Health liegen, etwa von der Apple Watch oder anderen Apps. Trainings, die auch in FITgap liegen, zählen einmal.")
                    } else {
                        Text("Apple Health liefert keine weiteren Trainings. Falls du das Lesen nicht erlaubt hast: Einstellungen › Apps › Health › Datenzugriff & Geräte › FITgap.")
                    }
                case .failed:
                    Text("Apple Health konnte nicht gelesen werden. Die Statistik zählt nur die Aktivitäten in FITgap.")
                }
            }
            if stats.unread > 0 {
                Text("\(stats.unread) Aktivitäten ohne geladene FIT-Datei sind nicht enthalten.")
            }
        }
    }
}
