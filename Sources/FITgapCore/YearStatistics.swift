import Foundation

/// Sport groups of the year statistics; FIT and Apple Health types map onto the same groups.
public enum StatsCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case cycling, running, swimming, walking, hiking, rowing, paddling, crossCountrySkiing, alpineSkiing
    case strength, yoga, fitnessEquipment, other
    public var id: String { rawValue }

    /// FIT `sport` and `sub_sport` enum values (Garmin FIT Global Profile). Training (10) counts as strength training
    /// or yoga only with that sub sport; fitness equipment (4) on an indoor rower counts as rowing.
    public init(fitSport sport: Int?, subSport: Int? = nil) {
        switch sport {
        case 2, 21: self = .cycling                       // cycling, e-biking
        case 1: self = .running
        case 5: self = .swimming
        case 11: self = .walking
        case 17, 16: self = .hiking                       // hiking, mountaineering
        case 15: self = .rowing
        case 4 where subSport == 14: self = .rowing       // indoor rowing
        case 4: self = .fitnessEquipment
        case 19, 37, 41, 42: self = .paddling             // paddling, stand-up paddling, kayaking, rafting
        case 12: self = .crossCountrySkiing
        case 13, 14: self = .alpineSkiing                 // alpine skiing, snowboarding
        case 10 where subSport == 20: self = .strength
        case 10 where subSport == 43: self = .yoga
        default: self = .other
        }
    }
}

/// One workout counted in the statistics, from a FITgap activity or a workout in Apple Health.
public struct StatsEntry: Sendable, Equatable, Identifiable {
    public enum Origin: Sendable, Equatable, Hashable {
        case fitgap(ActivityKey)
        /// Apple Health workout with its UUID and the name of the app that saved it.
        case health(UUID, String)
    }

    public let origin: Origin
    public let interval: DateInterval
    public let category: StatsCategory
    public let indoor: Bool
    /// Moving time; falls back to the elapsed time.
    public let duration: TimeInterval
    public var distanceMeters: Double?
    public var ascentMeters: Double?
    public var energyKilocalories: Double?

    public var id: Origin { origin }
    public var date: Date { interval.start }

    public init(origin: Origin, interval: DateInterval, category: StatsCategory, indoor: Bool = false,
                duration: TimeInterval? = nil, distanceMeters: Double? = nil, ascentMeters: Double? = nil,
                energyKilocalories: Double? = nil) {
        self.origin = origin; self.interval = interval; self.category = category; self.indoor = indoor
        self.duration = duration ?? interval.duration
        self.distanceMeters = distanceMeters; self.ascentMeters = ascentMeters; self.energyKilocalories = energyKilocalories
    }

    /// Statistics entry of a downloaded FITgap activity; nil until its FIT summary is read.
    public init?(_ record: ActivityRecord) {
        guard let metrics = record.metrics, let date = record.date else { return nil }
        let elapsed = metrics.elapsedSeconds ?? metrics.timerSeconds ?? record.duration ?? 0
        self.init(origin: .fitgap(record.key), interval: DateInterval(start: date, duration: max(0, elapsed)),
                  category: StatsCategory(fitSport: metrics.sport, subSport: metrics.subSport),
                  indoor: metrics.subSport == 6 || metrics.subSport == 58,
                  duration: metrics.timerSeconds ?? record.duration ?? elapsed,
                  distanceMeters: metrics.distanceMeters, ascentMeters: metrics.ascentMeters,
                  energyKilocalories: metrics.energyKilocalories)
    }
}

public enum StatsMerge {
    /// Two workouts are the same when they overlap at least half of the shorter duration.
    public static func sameWorkout(_ first: DateInterval, _ second: DateInterval) -> Bool {
        guard let shared = first.intersection(with: second) else { return false }
        return shared.duration >= 0.5 * min(first.duration, second.duration)
    }

    /// FITgap activities plus the Health workouts no FITgap activity covers; the FIT copy holds more data and wins.
    /// Both lists are sorted by start, so each Health workout is only compared with FITgap activities near it.
    public static func merge(fitgap: [StatsEntry], health: [StatsEntry]) -> [StatsEntry] {
        let own = fitgap.sorted { $0.date < $1.date }
        var result = own
        var lower = 0
        for workout in health.sorted(by: { $0.date < $1.date }) {
            while lower < own.count, own[lower].interval.end < workout.date.addingTimeInterval(-86_400) { lower += 1 }
            var index = lower, covered = false
            while index < own.count, own[index].date <= workout.interval.end {
                if sameWorkout(own[index].interval, workout.interval) { covered = true; break }
                index += 1
            }
            if !covered { result.append(workout) }
        }
        return result.sorted { $0.date < $1.date }
    }
}

/// What the charts measure.
public enum StatsMetric: String, CaseIterable, Sendable, Identifiable {
    case distance, duration, ascent, count, energy
    public var id: String { rawValue }

    public func value(_ entry: StatsEntry) -> Double {
        switch self {
        case .distance: entry.distanceMeters ?? 0
        case .duration: entry.duration
        case .ascent: entry.ascentMeters ?? 0
        case .count: 1
        case .energy: entry.energyKilocalories ?? 0
        }
    }
}

/// Totals and series of one calendar year, optionally cut off at a date (year to date).
public struct YearSummary: Sendable, Equatable {
    public let year: Int
    public let entries: [StatsEntry]
    public let calendar: Calendar

    public init(year: Int, entries: [StatsEntry], categories: Set<StatsCategory>? = nil,
                until: Date? = nil, calendar: Calendar = .current) {
        self.year = year
        self.calendar = calendar
        let range = Self.range(year, calendar: calendar)
        let end = until.map { min($0, range.end) } ?? range.end
        self.entries = entries.filter { entry in
            entry.date >= range.start && entry.date < end && (categories?.contains(entry.category) ?? true)
        }
    }

    public static func range(_ year: Int, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        return DateInterval(start: start, end: calendar.date(byAdding: .year, value: 1, to: start)!)
    }

    /// The same day and time one year earlier, so the current year compares with the previous one up to the same point.
    public static func sameDate(_ date: Date, inYear year: Int, calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: date)
        parts.year = year
        // 29 February becomes 1 March in a common year.
        return calendar.date(from: parts) ?? date
    }

    public var count: Int { entries.count }
    public func total(_ metric: StatsMetric) -> Double { entries.reduce(0) { $0 + metric.value($1) } }
    /// Entries without a value for the metric, e.g. Health workouts without elevation.
    public func missing(_ metric: StatsMetric) -> Int {
        switch metric {
        case .distance: entries.filter { $0.distanceMeters == nil }.count
        case .ascent: entries.filter { $0.ascentMeters == nil }.count
        case .energy: entries.filter { $0.energyKilocalories == nil }.count
        case .duration, .count: 0
        }
    }

    public var activeDays: Int { Set(entries.map { calendar.startOfDay(for: $0.date) }).count }

    /// Twelve monthly totals, January first.
    public func monthly(_ metric: StatsMetric) -> [Double] {
        var result = Array(repeating: 0.0, count: 12)
        for entry in entries { result[calendar.component(.month, from: entry.date) - 1] += metric.value(entry) }
        return result
    }

    /// Totals per day of the year (1-based), only for days with activity.
    public func daily(_ metric: StatsMetric) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for entry in entries { result[calendar.ordinality(of: .day, in: .year, for: entry.date) ?? 1, default: 0] += metric.value(entry) }
        return result
    }

    /// Running total at the end of every day with activity, starting at zero on day 1.
    public func cumulative(_ metric: StatsMetric) -> [(day: Int, value: Double)] {
        var total = 0.0
        return [(1, 0)] + daily(metric).sorted { $0.key < $1.key }.map { day, value in
            total += value
            return (day, total)
        }
    }

    public func byCategory(_ metric: StatsMetric) -> [(category: StatsCategory, value: Double)] {
        var result: [StatsCategory: Double] = [:]
        for entry in entries { result[entry.category, default: 0] += metric.value(entry) }
        return StatsCategory.allCases.compactMap { category in result[category].map { (category, $0) } }
    }

    /// The entry with the highest value; nil when no entry has one.
    public func best(_ metric: StatsMetric) -> StatsEntry? {
        entries.filter { metric.value($0) > 0 }.max { metric.value($0) < metric.value($1) }
    }

    /// Highest average speed among entries with distance, ignoring very short ones.
    public var fastest: StatsEntry? {
        entries.filter { ($0.distanceMeters ?? 0) >= 1000 && $0.duration >= 300 }
            .max { $0.distanceMeters! / $0.duration < $1.distanceMeters! / $1.duration }
    }

    /// Longest run of consecutive days with activity.
    public var longestStreak: Int {
        let days = Set(entries.compactMap { calendar.ordinality(of: .day, in: .era, for: $0.date) }).sorted()
        var best = 0, current = 0, previous: Int?
        for day in days {
            current = previous == day - 1 ? current + 1 : 1
            best = max(best, current)
            previous = day
        }
        return best
    }

    /// Relative change from `previous`; nil without a base to compare with.
    public static func change(_ value: Double, from previous: Double) -> Double? {
        previous > 0 ? (value - previous) / previous : nil
    }
}

/// A year goal for one metric, for every sport or one sport group.
public struct StatsGoal: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var year: Int
    /// nil counts every sport.
    public var category: StatsCategory?
    public var metric: String
    /// In the metric's base unit: metres, seconds, count or kcal.
    public var target: Double

    public init(id: UUID = UUID(), year: Int, category: StatsCategory?, metric: StatsMetric, target: Double) {
        self.id = id; self.year = year; self.category = category; self.metric = metric.rawValue; self.target = target
    }

    public var statsMetric: StatsMetric { StatsMetric(rawValue: metric) ?? .distance }
}

/// Where the year ends at the pace so far, and when a target is reached at that pace.
public struct StatsForecast: Sendable, Equatable {
    /// Total at the end of the year.
    public let yearEnd: Double
    /// Day the target is reached; nil when it is already reached, out of reach this year or there is no target.
    public let reached: Date?
    /// Still needed per remaining week to reach the target; nil when reached or without target.
    public let perWeek: Double?

    /// Only for a running year: before or after it there is nothing to project.
    public static func make(total: Double, now: Date, year: Int, target: Double? = nil,
                            calendar: Calendar = .current) -> StatsForecast? {
        let range = YearSummary.range(year, calendar: calendar)
        let elapsed = now.timeIntervalSince(range.start)
        guard elapsed > 0, now < range.end else { return nil }
        let pace = total / elapsed
        var reached: Date?
        var perWeek: Double?
        if let target, total < target {
            if pace > 0 {
                let date = range.start.addingTimeInterval(target / pace)
                if date <= range.end { reached = date }
            }
            perWeek = (target - total) / max(range.end.timeIntervalSince(now) / (7 * 86_400), 1.0 / 7)
        }
        return StatsForecast(yearEnd: pace * range.duration, reached: reached, perWeek: perWeek)
    }
}

/// A position along the recorded track at a given time, for placing photos without their own location.
public enum TrackPlacement {
    public struct Point: Sendable, Equatable {
        public let date: Date
        public let latitude: Double
        public let longitude: Double
        public init(date: Date, latitude: Double, longitude: Double) {
            self.date = date; self.latitude = latitude; self.longitude = longitude
        }
    }

    /// Linear interpolation between the two recorded positions around `date`;
    /// within `tolerance` before the start or after the end the first or last position is used.
    public static func position(at date: Date, in track: [Point], tolerance: TimeInterval = 300) -> Point? {
        guard let first = track.first, let last = track.last else { return nil }
        if date <= first.date { return first.date.timeIntervalSince(date) <= tolerance ? first : nil }
        if date >= last.date { return date.timeIntervalSince(last.date) <= tolerance ? last : nil }
        var low = 0, high = track.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if track[middle].date <= date { low = middle } else { high = middle }
        }
        let a = track[low], b = track[high]
        let span = b.date.timeIntervalSince(a.date)
        let t = span > 0 ? date.timeIntervalSince(a.date) / span : 0
        return Point(date: date, latitude: a.latitude + (b.latitude - a.latitude) * t,
                     longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Groups positions closer than `meters` to the first position of a group, in the given order.
    public static func groups<T>(_ items: [T], meters: Double, position: (T) -> (latitude: Double, longitude: Double)) -> [[T]] {
        var groups: [(anchor: FITActivity.Coordinate, items: [T])] = []
        for item in items {
            let p = position(item)
            let point = FITActivity.Coordinate(latitude: p.latitude, longitude: p.longitude)
            if let index = groups.firstIndex(where: { FITActivity.meters(from: $0.anchor, to: point) < meters }) {
                groups[index].items.append(item)
            } else {
                groups.append((point, [item]))
            }
        }
        return groups.map(\.items)
    }
}

extension FITActivity {
    /// Every recorded position with its time, for placing photos along the route.
    public func track() -> [TrackPlacement.Point] {
        records.compactMap { record in
            guard let latitude = record.latitude, let longitude = record.longitude, latitude != 0 || longitude != 0 else { return nil }
            return TrackPlacement.Point(date: record.date, latitude: latitude, longitude: longitude)
        }
    }
}
