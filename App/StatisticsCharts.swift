import Charts
import FITgapCore
import SwiftUI

/// Totals and charts of one sport group or all; values grow in when shown and move to their new place when
/// year, metric or sport group change. With Reduce Motion the charts change without movement.
struct StatisticsDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stats: StatisticsModel
    let scope: StatsScope
    let period: StatsPeriod
    @Binding var metric: StatsMetric
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: YearSummary { period.summary(stats.entries, categories: scope.categories) }
    private var previous: YearSummary? { period.comparisonSummary(stats.entries, categories: scope.categories) }
    /// Changes of any of these move the chart marks.
    private var animationKey: [String] {
        [String(period.year), String(period.comparison ?? 0), String(period.yearToDate), metric.rawValue,
         "\(scope)", String(stats.entries.count)]
    }

    var body: some View {
        let current = current, previous = previous
        List {
            Section {
                Picker("Kennzahl", selection: $metric) {
                    ForEach(StatsMetric.allCases) { Text($0.shortTitle).tag($0).accessibilityLabel($0.title) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("stats-metric")
            }
            Section("Überblick") {
                total(StatsMetric.distance.title, .distance, current, previous)
                total(StatsMetric.duration.title, .duration, current, previous)
                total(StatsMetric.ascent.title, .ascent, current, previous)
                total(StatsMetric.count.title, .count, current, previous)
                kpi(String(localized: "Aktive Tage"), Double(current.activeDays), previous.map { Double($0.activeDays) },
                    year: previous?.year) { ActivityFormat.integer($0) }
                total(StatsMetric.energy.title, .energy, current, previous)
            }
            if current.count == 0 && (previous?.count ?? 0) == 0 {
                Section {
                    ContentUnavailableView("Keine Aktivitäten", systemImage: "chart.bar.xaxis",
                        description: Text("Für diesen Zeitraum gibt es keine Aktivitäten."))
                }
            } else {
                Section {
                    YearCurveChart(current: current, previous: previous, period: period, metric: metric, progress: grown ? 1 : 0)
                } header: {
                    Text("Jahresverlauf")
                } footer: {
                    missingNote(current)
                }
                Section("Monate") {
                    MonthChart(current: current, previous: previous, metric: metric, progress: grown ? 1 : 0)
                }
                Section("Wochen") {
                    WeekChart(current: current, metric: metric, progress: grown ? 1 : 0)
                }
                if scope == .all, current.byCategory(metric).count > 1 {
                    Section("Sportarten") {
                        CategoryChart(summary: current, metric: metric, progress: grown ? 1 : 0)
                    }
                }
                Section {
                    CalendarChart(summary: current, progress: grown ? 1 : 0)
                } header: {
                    Text("Aktivitätskalender")
                } footer: {
                    Text("Je dunkler ein Tag, desto länger war die Trainingszeit.")
                }
                Section("Bestwerte") {
                    record(String(localized: "Längste Strecke"), current.best(.distance), previous?.best(.distance)) {
                        StatsMetric.distance.formatted($0.distanceMeters ?? 0)
                    }
                    record(String(localized: "Längste Dauer"), current.best(.duration), previous?.best(.duration)) {
                        StatsMetric.duration.formatted($0.duration)
                    }
                    record(String(localized: "Meiste Höhenmeter"), current.best(.ascent), previous?.best(.ascent)) {
                        StatsMetric.ascent.formatted($0.ascentMeters ?? 0)
                    }
                    record(String(localized: "Höchster Schnitt"), current.fastest, previous?.fastest) {
                        ActivityFormat.speed(($0.distanceMeters ?? 0) / max($0.duration, 1)) ?? ""
                    }
                    kpi(String(localized: "Längste Serie"), Double(current.longestStreak), previous.map { Double($0.longestStreak) },
                        year: previous?.year) { String(localized: "\(Int($0)) Tage") }
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
        .onAppear {
            guard !grown else { return }
            if reduceMotion { grown = true } else { withAnimation(.smooth(duration: 0.9)) { grown = true } }
        }
    }

    private var scopeTitle: String {
        if case .category(let category) = scope { return "\(category.title) \(period.year)" }
        return String(localized: "Statistik \(String(period.year))")
    }

    /// A total no counted activity has a value for shows a dash instead of zero, e.g. energy of files without calories.
    @ViewBuilder
    private func total(_ title: String, _ metric: StatsMetric, _ current: YearSummary, _ previous: YearSummary?) -> some View {
        if current.count > 0, current.missing(metric) == current.count {
            LabeledContent(title, value: "–")
        } else {
            kpi(title, current.total(metric), previous?.total(metric), year: previous?.year, format: metric.formatted)
        }
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

    @ViewBuilder
    private func record(_ title: String, _ best: StatsEntry?, _ previous: StatsEntry?, value: @escaping (StatsEntry) -> String) -> some View {
        if let best {
            let content = LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value(best)).monospacedDigit()
                    if let previous, let year = period.comparison {
                        Text(verbatim: "\(String(year)): \(value(previous))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(recordSubtitle(best)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            if case .fitgap(let key) = best.origin, model.activities.contains(where: { $0.key == key }) {
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

/// The running total over the year, the comparison year dashed beneath; touching the chart shows both values.
private struct YearCurveChart: View {
    let current: YearSummary
    let previous: YearSummary?
    let period: StatsPeriod
    let metric: StatsMetric
    let progress: Double
    @State private var selected: Date?

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
        return curve(current) + (previous.map(curve) ?? [])
    }

    var body: some View {
        let points = points
        let currentSeries = String(current.year)
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Datum", point.date), y: .value(metric.title, point.value * progress),
                         series: .value("Jahr", point.series))
                    .foregroundStyle(by: .value("Jahr", point.series))
                    .lineStyle(StrokeStyle(lineWidth: point.series == currentSeries ? 3 : 2,
                                           dash: point.series == currentSeries ? [] : [5, 4]))
                    .interpolationMethod(.monotone)
            }
            if let selected {
                RuleMark(x: .value("Datum", selected))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        callout(selected, points)
                    }
            }
        }
        .chartForegroundStyleScale(domain: [currentSeries] + (previous.map { [String($0.year)] } ?? []),
                                   range: [Color.accentColor, Color.secondary])
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
        let series = [String(current.year)] + (previous.map { [String($0.year)] } ?? [])
        return VStack(alignment: .leading, spacing: 2) {
            Text(date.formatted(.dateTime.day().month(.abbreviated))).font(.caption.weight(.semibold))
            ForEach(series, id: \.self) { name in
                if let value = points.last(where: { $0.series == name && $0.date <= date })?.value {
                    Text(verbatim: "\(name): \(value.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)")
                        .font(.caption).monospacedDigit()
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
    }
}

/// Monthly totals of both years side by side.
private struct MonthChart: View {
    let current: YearSummary
    let previous: YearSummary?
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
        return bars(current) + (previous.map(bars) ?? [])
    }

    var body: some View {
        let bars = bars
        Chart(bars) { bar in
            BarMark(x: .value("Monat", bar.month, unit: .month), y: .value(metric.title, bar.value * progress))
                .foregroundStyle(by: .value("Jahr", bar.series))
                .position(by: .value("Jahr", bar.series))
                .cornerRadius(3)
                .opacity(selected == nil || Calendar.current.isDate(bar.month, equalTo: selected!, toGranularity: .month) ? 1 : 0.4)
        }
        .chartForegroundStyleScale(domain: [String(current.year)] + (previous.map { [String($0.year)] } ?? []),
                                   range: [Color.accentColor, Color.secondary.opacity(0.6)])
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
            }
        }
        .chartYAxisLabel(metric.unit)
        .chartXSelection(value: $selected)
        .frame(height: 200)
        .padding(.vertical, 8)
        .overlay(alignment: .topLeading) {
            if let selected {
                let month = bars.filter { Calendar.current.isDate($0.month, equalTo: selected, toGranularity: .month) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.formatted(.dateTime.month(.wide))).font(.caption.weight(.semibold))
                    ForEach(month) { bar in
                        Text(verbatim: "\(bar.series): \(bar.value.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)")
                            .font(.caption).monospacedDigit()
                    }
                }
                .padding(6)
                .background(.regularMaterial, in: .rect(cornerRadius: 8))
            }
        }
        .accessibilityLabel(Text("Monate \(metric.title)"))
    }
}

/// Totals per calendar week with the weekly average.
private struct WeekChart: View {
    let current: YearSummary
    let metric: StatsMetric
    let progress: Double

    var body: some View {
        let weeks = current.weekly(metric).map { (week: $0.key, value: metric.plotted($0.value)) }.sorted { $0.week < $1.week }
        let range = YearSummary.range(current.year, calendar: current.calendar)
        let active = weeks.filter { $0.value > 0 }
        let average = active.isEmpty ? 0 : active.reduce(0) { $0 + $1.value } / Double(active.count)
        Chart {
            ForEach(weeks, id: \.week) { week in
                BarMark(x: .value("Woche", week.week, unit: .weekOfYear), y: .value(metric.title, week.value * progress))
                    .foregroundStyle(Color.accentColor.gradient)
            }
            if average > 0 {
                RuleMark(y: .value("Durchschnitt", average * progress))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(verbatim: "Ø \(average.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: range.start...range.end)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
            }
        }
        .chartYAxisLabel(metric.unit)
        .frame(height: 160)
        .padding(.vertical, 8)
        .accessibilityLabel(Text("Wochen \(metric.title)"))
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
