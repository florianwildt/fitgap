import Foundation
import Testing
@testable import FITgapCore

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func entry(_ id: String, _ start: Date, minutes: Double, km: Double?, category: StatsCategory = .cycling,
                   health: Bool = false, ascent: Double? = nil) -> StatsEntry {
    StatsEntry(origin: health ? .health(UUID(), id) : .fitgap(ActivityKey(source: "wahoo", id: id)),
               interval: DateInterval(start: start, duration: minutes * 60), category: category,
               distanceMeters: km.map { $0 * 1000 }, ascentMeters: ascent)
}

@Test func healthWorkoutsCoveredByFITgapCountOnce() {
    let ride = entry("ride", day(2026, 5, 1), minutes: 60, km: 30)
    let watchCopy = entry("watch", day(2026, 5, 1).addingTimeInterval(120), minutes: 55, km: 29, health: true)
    let walk = entry("walk", day(2026, 5, 1, hour: 18), minutes: 30, km: 2, category: .walking, health: true)
    let merged = StatsMerge.merge(fitgap: [ride], health: [walk, watchCopy])
    #expect(merged.map(\.origin) == [ride.origin, walk.origin])
}

@Test func summaryTotalsSeriesAndRecords() {
    let entries = [
        entry("a", day(2026, 1, 3), minutes: 60, km: 30, ascent: 300),
        entry("b", day(2026, 1, 4), minutes: 120, km: 70),
        entry("c", day(2026, 3, 1), minutes: 45, km: 10, category: .running),
        entry("d", day(2025, 12, 31), minutes: 30, km: 15)
    ]
    let year = YearSummary(year: 2026, entries: entries, calendar: utc)
    #expect(year.count == 3 && year.total(.distance) == 110_000 && year.activeDays == 3)
    #expect(year.monthly(.distance)[0] == 100_000 && year.monthly(.distance)[2] == 10_000)
    #expect(year.cumulative(.distance).last?.value == 110_000)
    #expect(year.best(.distance)?.origin == entries[1].origin)
    #expect(year.longestStreak == 2 && year.missing(.ascent) == 2)
    #expect(YearSummary(year: 2026, entries: entries, categories: [.running], calendar: utc).count == 1)
    #expect(YearSummary.change(110, from: 100)! > 0.099 && YearSummary.change(1, from: 0) == nil)
}

@Test func yearToDateComparesUpToTheSameDate() {
    let entries = [entry("early", day(2025, 2, 1), minutes: 60, km: 20), entry("late", day(2025, 9, 1), minutes: 60, km: 40)]
    let cutoff = YearSummary.sameDate(day(2026, 6, 15), inYear: 2025, calendar: utc)
    #expect(YearSummary(year: 2025, entries: entries, until: cutoff, calendar: utc).total(.distance) == 20_000)
    #expect(utc.component(.month, from: YearSummary.sameDate(day(2028, 2, 29), inYear: 2027, calendar: utc)) == 3)
}

@Test func photosArePlacedAlongTheTrackByTime() {
    let start = day(2026, 5, 1)
    let track = [TrackPlacement.Point(date: start, latitude: 50, longitude: 8),
                 TrackPlacement.Point(date: start.addingTimeInterval(100), latitude: 51, longitude: 9)]
    let middle = TrackPlacement.position(at: start.addingTimeInterval(25), in: track)
    #expect(middle?.latitude == 50.25 && middle?.longitude == 8.25)
    #expect(TrackPlacement.position(at: start.addingTimeInterval(-60), in: track)?.latitude == 50)
    #expect(TrackPlacement.position(at: start.addingTimeInterval(3600), in: track) == nil)
    let groups = TrackPlacement.groups([(50.0, 8.0), (50.0001, 8.0), (51.0, 9.0)], meters: 100) { ($0.0, $0.1) }
    #expect(groups.map(\.count) == [2, 1])
}
