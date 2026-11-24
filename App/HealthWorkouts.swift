import FITgapCore
import HealthKit
import SwiftUI

/// A workout in Apple Health that another app saved and no FITgap activity covers, shown read-only in the activity list.
struct HealthWorkout: Identifiable, Equatable, Sendable {
    let id: UUID
    let interval: DateInterval
    let type: HKWorkoutActivityType
    let indoor: Bool
    let sourceName: String
    let bundleIdentifier: String
    let duration: TimeInterval
    let distanceMeters: Double?
    let ascentMeters: Double?
    let energyKilocalories: Double?

    var date: Date { interval.start }

    var name: String { kind?.title ?? String(localized: "Workout") }

    /// The list's activity type for the filter; types FITgap does not list have none.
    var kind: ActivityKind? {
        switch type {
        case .cycling, .handCycling: indoor ? .indoorCycling : .cycling
        case .running: .running
        case .swimming: .swimming
        case .walking: .walking
        case .hiking: .hiking
        case .rowing: .rowing
        case .elliptical, .stairClimbing, .stepTraining: .fitnessEquipment
        case .traditionalStrengthTraining, .functionalStrengthTraining, .highIntensityIntervalTraining,
             .crossTraining, .coreTraining, .mixedCardio: .training
        default: nil
        }
    }

    init(_ workout: HKWorkout) {
        id = workout.uuid
        interval = DateInterval(start: workout.startDate, end: max(workout.startDate, workout.endDate))
        type = workout.workoutActivityType
        indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool ?? false
        sourceName = workout.sourceRevision.source.name
        bundleIdentifier = workout.sourceRevision.source.bundleIdentifier
        duration = workout.duration
        let distanceTypes: [HKQuantityTypeIdentifier] = [.distanceCycling, .distanceWalkingRunning, .distanceSwimming]
        distanceMeters = distanceTypes.lazy
            .compactMap { workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter()) }
            .first { $0 > 0 }
        ascentMeters = (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter())
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        energyKilocalories = energy.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Reads the workouts of other apps once access to Health was decided; it never asks for access itself.
@MainActor
final class HealthWorkoutsModel: ObservableObject {
    @Published private(set) var workouts: [HealthWorkout] = []
    private let store = HKHealthStore()
    private var loading = false

    func load(enabled: Bool) async {
        guard enabled, HKHealthStore.isHealthDataAvailable() else { workouts = []; return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: [.workoutType()])
        guard status == .unnecessary else { return }
        let own = Bundle.main.bundleIdentifier
        guard let samples = try? await HKSampleQueryDescriptor(predicates: [.workout()],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: HKObjectQueryNoLimit).result(for: store)
        else { return }
        workouts = samples.map(HealthWorkout.init).filter { $0.bundleIdentifier != own }
    }

    /// Workouts no FITgap activity covers, newest first; a FITgap activity holds more data and wins.
    /// Activities whose FIT is not read yet are compared by their listed start and duration.
    func uncovered(by records: [ActivityRecord]) -> [HealthWorkout] {
        let intervals = records.compactMap { record -> DateInterval? in
            guard let date = record.date else { return nil }
            let seconds = record.metrics?.elapsedSeconds ?? record.metrics?.timerSeconds ?? record.duration ?? 0
            return DateInterval(start: date, duration: max(0, seconds))
        }.sorted { $0.start < $1.start }
        return workouts.filter { workout in
            // Only activities starting within a day before the workout can overlap it.
            var low = 0, high = intervals.count
            let earliest = workout.date.addingTimeInterval(-86_400)
            while low < high { let mid = (low + high) / 2; if intervals[mid].start < earliest { low = mid + 1 } else { high = mid } }
            var index = low
            while index < intervals.count, intervals[index].start <= workout.interval.end {
                if StatsMerge.sameWorkout(intervals[index], workout.interval) { return false }
                index += 1
            }
            return true
        }
    }
}

/// One Health workout in the list, laid out like an activity row but without file actions.
struct HealthWorkoutRow: View {
    let workout: HealthWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(workout.name).font(.headline)
                Spacer(minLength: 0)
                Image(systemName: "heart.fill")
                    .font(.subheadline).foregroundStyle(.pink)
                    .accessibilityLabel("Aus Apple Health")
            }
            Text("\(workout.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())) · \(workout.sourceName)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(HealthWorkoutFormat.summary(workout))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Read-only details of a Health workout; the data stays in Apple Health.
struct HealthWorkoutDetailView: View {
    let workout: HealthWorkout

    var body: some View {
        List {
            Section {
                LabeledContent("Datum", value: workout.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))
                LabeledContent("App", value: workout.sourceName)
                LabeledContent("Dauer", value: ActivityFormat.duration(workout.duration))
                if let distance = ActivityFormat.distance(workout.distanceMeters) { LabeledContent("Strecke", value: distance) }
                if let ascent = workout.ascentMeters { LabeledContent("Höhenmeter", value: ActivityFormat.meters(ascent)) }
                if let energy = workout.energyKilocalories { LabeledContent("Kalorien", value: ActivityFormat.integer(energy) + " kcal") }
            } footer: {
                Text("Dieses Workout stammt aus Apple Health. Es hat keine FIT-Datei in FITgap und lässt sich hier weder teilen noch löschen.")
            }
        }
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum HealthWorkoutFormat {
    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func duration(_ seconds: TimeInterval) -> String {
        durationFormatter.string(from: max(0, seconds)) ?? String(localized: "unbekannt")
    }

    static func summary(_ workout: HealthWorkout) -> String {
        var parts = [duration(workout.duration)]
        if let distance = ActivityFormat.distance(workout.distanceMeters) { parts.insert(distance, at: 0) }
        if let ascent = workout.ascentMeters { parts.append("↑ \(ActivityFormat.meters(ascent))") }
        return parts.joined(separator: " · ")
    }
}
