import Charts
import FITgapCore
import SwiftUI

/// Totals and charts of one sport group or all; values grow in when shown and move to their new place when
/// year, metric or sport group change. With Reduce Motion the charts change without movement.
struct StatisticsDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stats: StatisticsModel
    @Binding var selection: StatsScope?
    /// Sport groups with activity in the shown years, for the filter.
    let categories: [StatsCategory]
    let period: StatsPeriod
    @Binding var metric: StatsMetric
    @State private var grown = false
    @State private var editing: GoalEditing?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: YearSummary { period.summary(stats.entries, categories: scope.categories) }
    private var scope: StatsScope { selection ?? .all }
    private var previous: YearSummary? { period.comparisonSummary(stats.entries, categories: scope.categories) }
    private var others: [YearSummary] { period.chartSummaries(stats.entries, categories: scope.categories) }
    /// Changes of any of these move the chart marks.
    private var animationKey: [String] {
        [String(period.year), String(period.comparison ?? 0), String(period.yearToDate), "\(period.chartYears)", metric.rawValue,
         "\(scope)", String(stats.entries.count)]
    }

    var body: some View {
        let current = current, previous = previous, others = others
        List {
            Section("Überblick") {
                // Two even columns sized by the container, so the tiles stay readable side by side and stacked.
                LazyVGrid(columns: Self.tileColumns, alignment: .leading, spacing: 14) {
                    tile(.distance, current, previous)
                    tile(.duration, current, previous)
                    tile(.ascent, current, previous)
                    tile(.count, current, previous)
                    tile(title: String(localized: "Aktive Tage"), symbol: "calendar", value: ActivityFormat.integer(Double(current.activeDays)),
                         raw: Double(current.activeDays), previous: previous.map { Double($0.activeDays) }, year: previous?.year)
                    tile(.energy, current, previous)
                }
                .padding(.vertical, 6)
            }
            Section {
                ForEach(shownGoals) { goal in
                    GoalRow(goal: goal, entries: stats.entries) { editing = GoalEditing(goal: goal, isNew: false) }
                        .swipeActions {
                            Button("Löschen", systemImage: "trash", role: .destructive) { stats.delete(goal) }
                        }
                }
                Button("Ziel hinzufügen", systemImage: "plus.circle") {
                    editing = GoalEditing(goal: StatsGoal(year: period.year, category: scope.categories?.first, metric: metric,
                                                          target: 0), isNew: true)
                }
                .accessibilityIdentifier("goal-add")
            } header: {
                Text("Ziele \(String(period.year))")
            }
            if current.count == 0 && (previous?.count ?? 0) == 0 && others.allSatisfy({ $0.count == 0 }) {
                Section {
                    ContentUnavailableView("Keine Aktivitäten", systemImage: "chart.bar.xaxis",
                        description: Text("Für diesen Zeitraum gibt es keine Aktivitäten."))
                }
            } else {
                Section {
                    // The metric only changes the charts, so it sits right above them.
                    Picker("Kennzahl", selection: $metric) {
                        ForEach(StatsMetric.allCases) { Text($0.shortTitle).tag($0).accessibilityLabel($0.title) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("stats-metric")
                    YearCurveChart(current: current, others: others, period: period, metric: metric, goal: chartGoal,
                                   progress: grown ? 1 : 0)
                } header: {
                    Text("Jahresverlauf")
                } footer: {
                    missingNote(current)
                }
                Section("Monate") {
                    MonthChart(current: current, others: others, metric: metric, progress: grown ? 1 : 0)
                }
                if scope == .all, current.byCategory(metric).count > 1 {
                    Section("Sportarten") {
                        CategoryChart(summary: current, metric: metric, progress: grown ? 1 : 0)
                    }
                }
                if scope == .all, !categories.isEmpty {
                    Section {
                        LazyVGrid(columns: Self.tileColumns, alignment: .leading, spacing: 14) {
                            ForEach(categories) { category in categoryTile(category) }
                        }
                        .padding(.vertical, 6)
                    } header: {
                        Text("Nach Sportart")
                    } footer: {
                        Text("Tippe auf eine Sportart, um nur sie zu zeigen.")
                    }
                }
                Section {
                    CalendarChart(summary: current, progress: grown ? 1 : 0)
                } header: {
                    Text("Aktivitätskalender")
                } footer: {
                    Text("Je dunkler ein Tag, desto länger war die Trainingszeit.")
                }
                let years = allYears
                Section {
                    record(String(localized: "Längste Strecke"), StatsMetric.distance.symbol, current.best(.distance),
                           overall(years, { $0.best(.distance) }, by: { $0.distanceMeters ?? 0 })) {
                        StatsMetric.distance.formatted($0.distanceMeters ?? 0)
                    }
                    record(String(localized: "Längste Dauer"), StatsMetric.duration.symbol, current.best(.duration),
                           overall(years, { $0.best(.duration) }, by: \.duration)) {
                        StatsMetric.duration.formatted($0.duration)
                    }
                    record(String(localized: "Meiste Höhenmeter"), StatsMetric.ascent.symbol, current.best(.ascent),
                           overall(years, { $0.best(.ascent) }, by: { $0.ascentMeters ?? 0 })) {
                        StatsMetric.ascent.formatted($0.ascentMeters ?? 0)
                    }
                    record(String(localized: "Höchster Schnitt"), "speedometer", current.fastest,
                           overall(years, \.fastest, by: { ($0.distanceMeters ?? 0) / max($0.duration, 1) })) {
                        ActivityFormat.speed(($0.distanceMeters ?? 0) / max($0.duration, 1)) ?? ""
                    }
                    streak(current.longestStreak, overall: years.map(\.longestStreak).max() ?? 0)
                } header: {
                    Text("Bestwerte")
                }
            }
            if scope == .all, let everyday = stats.everyday[period.year] {
                let before = period.comparison.flatMap { stats.everyday[$0] }
                Section {
                    if let steps = everyday.steps {
                        kpi(String(localized: "Schritte"), steps, period.yearToDate ? nil : before?.steps, year: period.comparison) {
                            ActivityFormat.integer($0)
                        }
                    }
                    if let meters = everyday.walkingMeters {
                        kpi(String(localized: "Geh- und Laufstrecke"), meters, period.yearToDate ? nil : before?.walkingMeters,
                            year: period.comparison) { StatsMetric.distance.formatted($0) }
                    }
                } header: {
                    Text("Alltag")
                } footer: {
                    Text("Alle Schritte und Gehstrecken aus Apple Health, auch außerhalb von Trainings.")
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: animationKey)
        .navigationTitle(scopeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { filterMenu } }
        .sheet(item: $editing) { item in
            GoalEditor(goal: item.goal, isNew: item.isNew, save: stats.save, delete: stats.delete)
        }
        .onAppear {
            guard !grown else { return }
            if reduceMotion { grown = true } else { withAnimation(.smooth(duration: 0.9)) { grown = true } }
        }
    }

    private struct GoalEditing: Identifiable {
        let goal: StatsGoal
        let isNew: Bool
        var id: UUID { goal.id }
    }

    /// Goals of the shown year: all of them for every sport, otherwise those of the filtered sport.
    private var shownGoals: [StatsGoal] {
        stats.goals.filter { $0.year == period.year && (scope == .all || $0.category == scope.categories?.first) }
    }

    /// The goal drawn in the year curve: same sport selection and metric.
    private var chartGoal: StatsGoal? {
        stats.goals.first { $0.year == period.year && $0.category == scope.categories?.first && $0.statsMetric == metric }
    }

    @ViewBuilder
    private func tile(_ metric: StatsMetric, _ current: YearSummary, _ previous: YearSummary?) -> some View {
        let empty = current.count > 0 && current.missing(metric) == current.count
        tile(title: metric.title, symbol: metric.symbol, value: empty ? "–" : metric.formatted(current.total(metric)),
             raw: current.total(metric), previous: empty ? nil : previous?.total(metric), year: previous?.year)
    }

    private func tile(title: String, symbol: String, value: String, raw: Double, previous: Double?, year: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let previous, let year { ChangeText(value: raw, previous: previous, year: year) }
        }
        .accessibilityElement(children: .combine)
    }

    /// Filters every number and chart to one sport group; the same choice as in the sidebar.
    private var filterMenu: some View {
        Menu {
            Picker("Sportart", selection: Binding(get: { scope }, set: { selection = $0 })) {
                Label("Alle Sportarten", systemImage: "chart.bar.xaxis").tag(StatsScope.all)
                ForEach(categories) { category in
                    Label(category.title, systemImage: category.symbol).tag(StatsScope.category(category))
                }
            }
        } label: {
            Label("Sportart", systemImage: scope == .all ? "line.3.horizontal.decrease.circle"
                                                         : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("stats-filter")
    }

    /// Two even columns sized by the container, shared by the overview, sport and record tiles.
    private static let tileColumns = [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]

    /// One sport group with its total, activity count and change to the comparison year; tapping filters to it.
    private func categoryTile(_ category: StatsCategory) -> some View {
        let value = period.summary(stats.entries, categories: [category])
        let before = period.comparisonSummary(stats.entries, categories: [category])
        return Button {
            selection = .category(category)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label { Text(category.title) } icon: { Image(systemName: category.symbol).foregroundStyle(category.color) }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(metric.formatted(value.total(metric)))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(value.count) Aktivitäten").font(.caption).foregroundStyle(.secondary)
                if let before { ChangeText(value: value.total(metric), previous: before.total(metric), year: before.year) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Zeigt nur diese Sportart")
    }

    private var scopeTitle: String {
        if case .category(let category) = scope { return "\(category.title) \(period.year)" }
        return String(localized: "Statistik \(String(period.year))")
    }

    private func kpi(_ title: String, _ value: Double, _ previous: Double?, year: Int?, format: @escaping (Double) -> String) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(format(value)).monospacedDigit().contentTransition(.numericText())
                if let previous, let year { ChangeText(value: value, previous: previous, year: year) }
            }
        } label: {
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }

    /// Every year with activity in the selected sport groups, for the records of all years.
    private var allYears: [YearSummary] {
        stats.years.map { YearSummary(year: $0, entries: stats.entries, categories: scope.categories) }
    }

    private func overall(_ years: [YearSummary], _ best: (YearSummary) -> StatsEntry?,
                         by value: (StatsEntry) -> Double) -> StatsEntry? {
        years.compactMap(best).max { value($0) < value($1) }
    }

    /// The record of all years below the shown year's; a star when the shown year holds it.
    @ViewBuilder
    private func overallLine(_ text: String, isShownYear: Bool) -> some View {
        if isShownYear {
            Label("Bestwert aller Jahre", systemImage: "star.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.orange)
        } else {
            Text(String(localized: "Gesamt: \(text)")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func days(_ count: Int) -> String {
        count == 1 ? String(localized: "1 Tag") : String(localized: "\(count) Tage")
    }

    private func streak(_ days: Int, overall: Int) -> some View {
        LabeledContent {
            Text(Self.days(days)).monospacedDigit()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Längste Serie")
                    if overall > 0 { overallLine(Self.days(overall), isShownYear: days == overall) }
                }
            } icon: {
                Image(systemName: "calendar")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The shown year's record with its activity, and the record of all years; opens the activity when it is in FITgap.
    @ViewBuilder
    private func record(_ title: String, _ symbol: String, _ best: StatsEntry?, _ overall: StatsEntry?,
                        value: @escaping (StatsEntry) -> String) -> some View {
        if let best {
            let key: ActivityKey? = if case .fitgap(let key) = best.origin, model.activities.contains(where: { $0.key == key }) {
                key
            } else {
                nil
            }
            // One record per row: title, activity and the record of all years on the left, the value on the right.
            let content = LabeledContent {
                Text(value(best)).monospacedDigit()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(recordSubtitle(best)).font(.caption).foregroundStyle(.secondary)
                        if let overall {
                            let year = Calendar.current.component(.year, from: overall.date)
                            overallLine("\(value(overall)) (\(String(year)))",
                                        isShownYear: overall == best || value(overall) == value(best))
                        }
                    }
                } icon: {
                    Image(systemName: symbol)
                }
            }
            .accessibilityElement(children: .combine)
            if let key {
                NavigationLink(value: key) { content }
            } else {
                content
            }
        }
    }

    private func recordSubtitle(_ entry: StatsEntry) -> String {
        let date = entry.date.formatted(.dateTime.day().month(.abbreviated))
        switch entry.origin {
        case .fitgap(let key):
            return model.activities.first { $0.key == key }.map { "\(date) · \($0.displayName)" } ?? date
        case .health(_, let source):
            return "\(date) · \(source)"
        }
    }

    @ViewBuilder private func missingNote(_ summary: YearSummary) -> some View {
        let missing = summary.missing(metric)
        if missing > 0 { Text("\(missing) Aktivitäten ohne Angabe für \(metric.title).") }
    }
}

/// Colours of the shown year and the further chart years; the comparison year keeps the neutral grey.
private func yearColors(_ count: Int) -> [Color] {
    let palette: [Color] = [.secondary, .orange, .purple, .teal, .pink, .brown, .indigo, .mint]
    return [.accentColor] + (0..<count).map { palette[$0 % palette.count] }
}

/// The running total over the year, the other years dashed beneath; touching the chart shows every value.
private struct YearCurveChart: View {
    let current: YearSummary
    let others: [YearSummary]
    let period: StatsPeriod
    let metric: StatsMetric
    let goal: StatsGoal?
    let progress: Double
    @State private var selected: Date?

    /// Straight line from today to the year end at the pace so far; only while the shown year runs.
    private func projection(_ points: [Point]) -> [(date: Date, value: Double)] {
        let range = YearSummary.range(current.year, calendar: current.calendar)
        guard let last = points.last(where: { $0.series == String(current.year) }),
              let forecast = StatsForecast.make(total: current.total(metric), now: .now, year: current.year,
                                                calendar: current.calendar),
              let end = current.calendar.date(byAdding: .day, value: -1, to: range.end) else { return [] }
        return [(last.date, last.value), (end, metric.plotted(forecast.yearEnd))]
    }

    private struct Point: Identifiable {
        let series: String
        let date: Date
        let value: Double
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    /// Both years on the shown year's dates, so the curves lie on top of each other.
    private var points: [Point] {
        let calendar = current.calendar
        let start = YearSummary.range(current.year, calendar: calendar).start
        func curve(_ summary: YearSummary) -> [Point] {
            let series = String(summary.year)
            var result = summary.cumulative(metric).map { day, value in
                Point(series: series, date: calendar.date(byAdding: .day, value: day - 1, to: start)!, value: metric.plotted(value))
            }
            // The line runs flat to today or the end of the year.
            let ownStart = YearSummary.range(summary.year, calendar: calendar).start
            let days = calendar.dateComponents([.day], from: ownStart, to: period.end(of: summary.year)).day ?? 0
            let end = calendar.date(byAdding: .day, value: max(0, days), to: start)!
            if let last = result.last, end > last.date { result.append(Point(series: series, date: end, value: last.value)) }
            return result
        }
        return curve(current) + others.flatMap(curve)
    }

    /// The shown year's total so far and the difference to the comparison year at the same point.
    @ViewBuilder
    private func difference(_ points: [Point]) -> some View {
        let currentSeries = String(current.year)
        if let last = points.last(where: { $0.series == currentSeries }) {
            let unit = metric.unit.isEmpty ? "" : " \(metric.unit)"
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(last.value.formatted(.number.precision(.fractionLength(0...1))))\(unit)")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                if let other = others.first,
                   let before = points.last(where: { $0.series == String(other.year) && $0.date <= last.date })?.value {
                    let delta = last.value - before
                    let sign = delta >= 0 ? "+" : "−"
                    let amount = "\(sign)\(abs(delta).formatted(.number.precision(.fractionLength(0...1))))\(unit)"
                    Label {
                        Text(String(localized: "\(amount) ggü. \(String(other.year))"))
                    } icon: {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
                    .foregroundStyle(delta >= 0 ? Color.green : Color.red)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    var body: some View {
        let points = points
        let currentSeries = String(current.year)
        difference(points)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Datum", point.date), y: .value(metric.title, point.value * progress),
                         series: .value("Jahr", point.series))
                    .foregroundStyle(by: .value("Jahr", point.series))
                    .lineStyle(StrokeStyle(lineWidth: point.series == currentSeries ? 3 : 2,
                                           dash: point.series == currentSeries ? [] : [5, 4]))
                    .interpolationMethod(.stepEnd)
            }
            ForEach(projection(points), id: \.date) { point in
                LineMark(x: .value("Datum", point.date), y: .value(metric.title, point.value * progress),
                         series: .value("Prognose", "Prognose"))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [2, 4]))
            }
            if let goal {
                RuleMark(y: .value("Ziel", metric.plotted(goal.target) * progress))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Ziel \(metric.formatted(goal.target))").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    }
            }
            if let selected {
                RuleMark(x: .value("Datum", selected))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        callout(selected, points)
                    }
            }
        }
        .chartForegroundStyleScale(domain: [currentSeries] + others.map { String($0.year) },
                                   range: yearColors(others.count))
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxisLabel(metric.unit)
        .chartXSelection(value: $selected)
        .frame(height: 220)
        .padding(.vertical, 8)
        .accessibilityLabel(Text("Jahresverlauf \(metric.title)"))
    }

    private func callout(_ date: Date, _ points: [Point]) -> some View {
        let series = [String(current.year)] + others.map { String($0.year) }
        let colors = yearColors(others.count)
        return VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(.dateTime.day().month(.abbreviated))).font(.caption.weight(.semibold))
            ForEach(Array(series.enumerated()), id: \.element) { index, name in
                if let value = points.last(where: { $0.series == name && $0.date <= date })?.value {
                    CalloutLine(color: colors[index],
                                text: "\(name): \(value.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)")
                }
            }
        }
        .statsCallout()
    }
}

extension View {
    /// Opaque, outlined background, so the callout stands out from the lines and bars behind it.
    func statsCallout() -> some View {
        padding(8)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

/// One year's value in a callout with the year's chart colour.
private struct CalloutLine: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: text).font(.caption).monospacedDigit()
        }
    }
}

/// Monthly totals of the shown years side by side.
private struct MonthChart: View {
    let current: YearSummary
    let others: [YearSummary]
    let metric: StatsMetric
    let progress: Double
    @State private var selected: Date?

    private struct Bar: Identifiable {
        let series: String
        let month: Date
        let value: Double
        var id: String { "\(series)-\(month.timeIntervalSince1970)" }
    }

    private var bars: [Bar] {
        let calendar = current.calendar
        let start = YearSummary.range(current.year, calendar: calendar).start
        func bars(_ summary: YearSummary) -> [Bar] {
            summary.monthly(metric).enumerated().map { index, value in
                Bar(series: String(summary.year), month: calendar.date(byAdding: .month, value: index, to: start)!,
                    value: metric.plotted(value))
            }
        }
        return bars(current) + others.flatMap(bars)
    }

    var body: some View {
        let bars = bars
        let colors = yearColors(others.count)
        Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Monat", bar.month, unit: .month), y: .value(metric.title, bar.value * progress))
                    .foregroundStyle(by: .value("Jahr", bar.series))
                    .position(by: .value("Jahr", bar.series))
                    .cornerRadius(3)
                    .opacity(selected == nil || Calendar.current.isDate(bar.month, equalTo: selected!, toGranularity: .month) ? 1 : 0.4)
            }
            if let selected, let month = Calendar.current.dateInterval(of: .month, for: selected)?.start {
                // Invisible line over the month, carrying the callout above its bars.
                RuleMark(x: .value("Monat", month, unit: .month))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        let shown = bars.filter { Calendar.current.isDate($0.month, equalTo: month, toGranularity: .month) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(month.formatted(.dateTime.month(.wide))).font(.caption.weight(.semibold))
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, bar in
                                CalloutLine(color: colors[min(index, colors.count - 1)],
                                            text: "\(bar.series): \(bar.value.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)")
                            }
                        }
                        .statsCallout()
                    }
            }
        }
        .chartForegroundStyleScale(domain: [String(current.year)] + others.map { String($0.year) },
                                   range: yearColors(others.count))
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
            }
        }
        .chartYAxisLabel(metric.unit)
        .chartXSelection(value: $selected)
        .frame(height: 200)
        .padding(.vertical, 8)
        .accessibilityLabel(Text("Monate \(metric.title)"))
    }
}

/// Share of each sport group as a ring.
private struct CategoryChart: View {
    let summary: YearSummary
    let metric: StatsMetric
    let progress: Double
    @State private var selectedAngle: Double?

    var body: some View {
        let parts = summary.byCategory(metric)
        let total = parts.reduce(0) { $0 + $1.value }
        let selected = selectedAngle.flatMap { angle in
            var sum = 0.0
            return parts.first { sum += $0.value; return angle <= sum }?.category
        }
        HStack(spacing: 16) {
            Chart(parts, id: \.category) { part in
                SectorMark(angle: .value(metric.title, part.value * progress),
                           innerRadius: .ratio(0.62), outerRadius: .ratio(selected == part.category ? 1 : 0.92), angularInset: 1.5)
                    .foregroundStyle(part.category.color)
                    .cornerRadius(3)
            }
            .chartAngleSelection(value: $selectedAngle)
            .chartBackground { _ in
                if let selected, let part = parts.first(where: { $0.category == selected }) {
                    VStack(spacing: 0) {
                        Image(systemName: selected.symbol)
                        Text((part.value / max(total, 1)).formatted(.percent.precision(.fractionLength(0)))).font(.headline)
                    }
                }
            }
            .frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(parts, id: \.category) { part in
                    HStack(spacing: 6) {
                        Circle().fill(part.category.color).frame(width: 10, height: 10)
                        Text(part.category.title).font(.subheadline)
                        Spacer(minLength: 4)
                        Text((part.value / max(total, 1)).formatted(.percent.precision(.fractionLength(0))))
                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// Every day of the year as a square, coloured by training time.
private struct CalendarChart: View {
    let summary: YearSummary
    let progress: Double

    private struct Day: Identifiable {
        let id: Int
        let column: Int
        let row: Int
        let minutes: Double
    }

    private var days: [Day] {
        let calendar = summary.calendar
        let range = YearSummary.range(summary.year, calendar: calendar)
        let count = calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 365
        let offset = (calendar.component(.weekday, from: range.start) - calendar.firstWeekday + 7) % 7
        let daily = summary.daily(.duration)
        return (0..<count).map { index in
            Day(id: index, column: (index + offset) / 7, row: (index + offset) % 7, minutes: (daily[index + 1] ?? 0) / 60)
        }
    }

    var body: some View {
        let days = days
        let maximum = max(days.map(\.minutes).max() ?? 1, 1)
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        let labels = (0..<7).map { symbols[(first + $0) % 7] }
        Chart(days) { day in
            RectangleMark(xStart: .value("Woche", Double(day.column)), xEnd: .value("Woche", Double(day.column) + 0.85),
                          yStart: .value("Tag", Double(day.row)), yEnd: .value("Tag", Double(day.row) + 0.85))
                .foregroundStyle(day.minutes > 0
                    ? Color.accentColor.opacity(0.25 + 0.75 * min(1, day.minutes / maximum) * progress)
                    : Color.secondary.opacity(0.12))
        }
        .chartYScale(domain: .automatic(includesZero: true, reversed: true))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0.4, 2.4, 4.4, 6.4]) { value in
                AxisValueLabel {
                    if let position = value.as(Double.self) { Text(labels[Int(position)]).font(.caption2) }
                }
            }
        }
        .frame(height: 110)
        .padding(.vertical, 8)
        .accessibilityLabel(Text("Aktivitätskalender"))
        .accessibilityValue(Text("\(summary.activeDays) aktive Tage"))
    }
}
