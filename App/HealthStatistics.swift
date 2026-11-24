import FITgapCore
import Foundation
import HealthKit

/// Reads every workout in Apple Health, from any app, for the year statistics.
/// Totals missing on a workout are summed from the samples of all sources during its time span.
struct HealthStatisticsReader: Sendable {
    let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static var quantityTypes: [HKQuantityTypeIdentifier] {
        var types: [HKQuantityTypeIdentifier] = [.distanceCycling, .distanceWalkingRunning, .distanceSwimming,
                                                 .activeEnergyBurned, .stepCount]
        if #available(iOS 18, *) {
            types += [.distanceRowing, .distanceCrossCountrySkiing, .distancePaddleSports, .distanceDownhillSnowSports]
        }
        return types
    }

    static var readTypes: Set<HKObjectType> {
        Set(quantityTypes.map { HKQuantityType($0) as HKObjectType } + [HKObjectType.workoutType()])
    }

    /// Whether iOS still has to ask; the request itself is shown by the view with `healthDataAccessRequest`.
    /// iOS never tells whether reading was denied, only whether every type was decided.
    func needsRequest() async -> Bool {
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        return status != .unnecessary
    }

    /// All workouts of every app, oldest first, with the totals they carry themselves.
    func workouts() async throws -> [StatsEntry] {
        let workouts = try await HKSampleQueryDescriptor(predicates: [.workout()],
            sortDescriptors: [SortDescriptor(\.startDate)], limit: HKObjectQueryNoLimit).result(for: store)
        return workouts.map(Self.entry)
    }

    /// Fills distance and energy that a workout's app did not attach, from the samples recorded during it.
    func completed(_ entries: [StatsEntry]) async -> [StatsEntry] {
        var result = entries
        for index in result.indices {
            guard !Task.isCancelled else { break }
            let entry = result[index]
            if entry.distanceMeters == nil, let type = Self.distanceType(entry.category) {
                result[index].distanceMeters = await sum(type, .meter(), in: entry.interval)
            }
            if entry.energyKilocalories == nil {
                result[index].energyKilocalories = await sum(.activeEnergyBurned, .kilocalorie(), in: entry.interval)
            }
        }
        return result
    }

    /// Steps and walking and running distance of the whole interval from every source, including outside workouts;
    /// Health removes overlaps between devices itself.
    func everyday(_ interval: DateInterval) async -> Everyday {
        Everyday(steps: await sum(.stepCount, .count(), in: interval),
                 walkingMeters: await sum(.distanceWalkingRunning, .meter(), in: interval))
    }

    struct Everyday: Sendable, Equatable {
        var steps: Double?
        var walkingMeters: Double?
    }

    private func sum(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit, in interval: DateInterval) async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let query = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(identifier), predicate: predicate),
                                                options: .cumulativeSum)
        guard let value = try? await query.result(for: store)?.sumQuantity()?.doubleValue(for: unit), value > 0 else { return nil }
        return value
    }

    private static func distanceType(_ category: StatsCategory) -> HKQuantityTypeIdentifier? {
        switch category {
        case .cycling: .distanceCycling
        case .running, .walking, .hiking: .distanceWalkingRunning
        case .swimming: .distanceSwimming
        case .rowing: if #available(iOS 18, *) { .distanceRowing } else { nil }
        case .crossCountrySkiing: if #available(iOS 18, *) { .distanceCrossCountrySkiing } else { nil }
        case .paddling: if #available(iOS 18, *) { .distancePaddleSports } else { nil }
        case .alpineSkiing: if #available(iOS 18, *) { .distanceDownhillSnowSports } else { nil }
        case .strength, .yoga, .fitnessEquipment, .other: nil
        }
    }

    static func category(_ type: HKWorkoutActivityType) -> StatsCategory {
        switch type {
        case .cycling, .handCycling: .cycling
        case .running: .running
        case .swimming: .swimming
        case .walking: .walking
        case .hiking: .hiking
        case .rowing: .rowing
        case .crossCountrySkiing: .crossCountrySkiing
        case .traditionalStrengthTraining, .functionalStrengthTraining: .strength
        case .paddleSports: .paddling
        case .downhillSkiing, .snowboarding: .alpineSkiing
        case .yoga: .yoga
        case .elliptical, .stairClimbing, .stepTraining: .fitnessEquipment
        default: .other
        }
    }

    private static func entry(_ workout: HKWorkout) -> StatsEntry {
        let category = category(workout.workoutActivityType)
        let distance = distanceType(category).flatMap {
            workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter())
        }
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let ascent = (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter())
        let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool ?? false
        return StatsEntry(origin: .health(workout.uuid, workout.sourceRevision.source.name),
                          interval: DateInterval(start: workout.startDate, end: max(workout.startDate, workout.endDate)),
                          category: category, indoor: indoor, duration: workout.duration,
                          distanceMeters: distance.flatMap { $0 > 0 ? $0 : nil }, ascentMeters: ascent,
                          energyKilocalories: energy.flatMap { $0 > 0 ? $0 : nil })
    }
}

/// FITgap activities and Health workouts merged for the statistics; Health is read once per visit and completed per year.
@MainActor
final class StatisticsModel: ObservableObject {
    enum HealthState: Equatable { case off, needsAccess, loading, loaded, failed }

    @Published private(set) var entries: [StatsEntry] = []
    @Published private(set) var healthState = HealthState.off
    @Published private(set) var everyday: [Int: HealthStatisticsReader.Everyday] = [:]
    /// Year goals, kept on this device.
    @Published private(set) var goals: [StatsGoal] = StatisticsModel.loadGoals()

    private var fitgap: [StatsEntry] = []
    private var health: [StatsEntry] = []
    private var completedYears = Set<Int>()
    let reader = HealthStatisticsReader()

    var years: [Int] {
        let current = Calendar.current.component(.year, from: .now)
        return Set(entries.map { Calendar.current.component(.year, from: $0.date) } + [current]).sorted(by: >)
    }

    func update(_ records: [ActivityRecord], hidden: Set<ActivityKey>) {
        let visible = records.filter { !hidden.contains($0.key) }
        fitgap = visible.compactMap(StatsEntry.init)
        merge()
    }

    /// Reads Health unless it is unavailable or the demo is shown; the demo counts its own activities only.
    /// Without a decision on access nothing is asked here; the user starts the request in the view.
    func loadHealth(enabled: Bool) async {
        guard enabled, HealthStatisticsReader.isAvailable else {
            health = []; completedYears = []; everyday = [:]; healthState = .off
            merge()
            return
        }
        guard healthState != .loading, healthState != .loaded else { return }
        if await reader.needsRequest() {
            healthState = .needsAccess
            return
        }
        healthState = .loading
        do {
            health = try await reader.workouts()
            healthState = .loaded
        } catch {
            healthState = .failed
        }
        merge()
    }

    /// Completes missing Health totals and reads everyday movement for the shown years only.
    func complete(years: [Int]) async {
        guard healthState == .loaded else { return }
        for year in years where !completedYears.contains(year) {
            completedYears.insert(year)
            let range = YearSummary.range(year)
            let indices = health.indices.filter { range.contains(health[$0].date) }
            let count = health.count
            let filled = await reader.completed(indices.map { health[$0] })
            // Leaving the view or switching to the demo while reading drops the result.
            guard !Task.isCancelled, healthState == .loaded, health.count == count else { completedYears.remove(year); return }
            for (index, entry) in zip(indices, filled) { health[index] = entry }
            everyday[year] = await reader.everyday(range)
        }
        merge()
    }

    func save(_ goal: StatsGoal) {
        if let index = goals.firstIndex(where: { $0.id == goal.id }) { goals[index] = goal } else { goals.append(goal) }
        storeGoals()
    }

    func delete(_ goal: StatsGoal) {
        goals.removeAll { $0.id == goal.id }
        storeGoals()
    }

    private static let goalsKey = "statsGoals"

    private static func loadGoals() -> [StatsGoal] {
        guard let data = UserDefaults.standard.data(forKey: goalsKey) else { return [] }
        return (try? JSONDecoder().decode([StatsGoal].self, from: data)) ?? []
    }

    private func storeGoals() {
        if let data = try? JSONEncoder().encode(goals) { UserDefaults.standard.set(data, forKey: Self.goalsKey) }
    }

    private func merge() {
        entries = StatsMerge.merge(fitgap: fitgap, health: health)
    }
}
