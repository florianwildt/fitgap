import FITgapCore
import CoreLocation
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

/// Everything Apple Health keeps about one workout beyond its summary: measurements, route, laps, pauses and metadata.
/// Health stores no FIT file, only these values; measurements the app did not attach are taken from all sources
/// during the workout, e.g. the heart rate of an Apple Watch worn on a ride recorded by another app.
struct HealthWorkoutDetails: Sendable, Equatable {
    struct Range: Sendable, Equatable { var average: Double?; var maximum: Double? }

    var heartRate = Range()
    var power = Range()
    var cadence = Range()
    var speed = Range()
    var respiratoryRate: Double?
    var steps: Double?
    var strokes: Double?
    var route: [FITActivity.Coordinate] = []
    var track: [TrackPlacement.Point] = []
    var laps = 0
    var pauses = 0
    var device: String?
    var appVersion: String?
    var temperature: String?
    var humidity: Double?
    var mets: Double?
    var lapLength: Double?
}

struct HealthWorkoutReader: Sendable {
    let store = HKHealthStore()

    static var readTypes: Set<HKObjectType> {
        var types: [HKQuantityTypeIdentifier] = [
            .heartRate, .respiratoryRate, .activeEnergyBurned, .stepCount, .swimmingStrokeCount,
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
            .cyclingPower, .cyclingCadence, .cyclingSpeed, .runningPower, .runningSpeed
        ]
        if #available(iOS 18, *) { types.append(.distanceRowing) }
        return Set(types.map { HKQuantityType($0) as HKObjectType } + [HKObjectType.workoutType(), HKSeriesType.workoutRoute()])
    }

    /// Whether iOS still has to ask for some of the types; it never tells whether reading was denied.
    func needsRequest() async -> Bool {
        (try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)) != .unnecessary
    }

    func details(_ id: UUID) async -> HealthWorkoutDetails? {
        let query = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObject(with: id))], sortDescriptors: [], limit: 1)
        guard let workout = try? await query.result(for: store).first else { return nil }
        let cycling = [.cycling, .handCycling].contains(workout.workoutActivityType)
        let running = [.running, .walking, .hiking].contains(workout.workoutActivityType)
        var result = HealthWorkoutDetails()
        result.heartRate = await range(.heartRate, HKUnit.count().unitDivided(by: .minute()), workout)
        if cycling {
            result.power = await range(.cyclingPower, .watt(), workout)
            result.cadence = await range(.cyclingCadence, HKUnit.count().unitDivided(by: .minute()), workout)
            result.speed = await range(.cyclingSpeed, HKUnit.meter().unitDivided(by: .second()), workout)
        } else if running {
            result.power = await range(.runningPower, .watt(), workout)
            result.speed = await range(.runningSpeed, HKUnit.meter().unitDivided(by: .second()), workout)
        }
        result.respiratoryRate = await range(.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), workout).average
        if running { result.steps = await total(.stepCount, .count(), workout) }
        if workout.workoutActivityType == .swimming { result.strokes = await total(.swimmingStrokeCount, .count(), workout) }
        let events = workout.workoutEvents ?? []
        result.laps = events.filter { $0.type == .lap }.count
        result.pauses = events.filter { $0.type == .pause || $0.type == .motionPaused }.count
        result.device = workout.device?.name ?? workout.device?.model
        result.appVersion = workout.sourceRevision.version
        let metadata = workout.metadata ?? [:]
        if let temperature = metadata[HKMetadataKeyWeatherTemperature] as? HKQuantity {
            result.temperature = Measurement(value: temperature.doubleValue(for: .degreeCelsius()), unit: UnitTemperature.celsius)
                .formatted(.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
        result.humidity = (metadata[HKMetadataKeyWeatherHumidity] as? HKQuantity)?.doubleValue(for: .percent())
        result.mets = (metadata[HKMetadataKeyAverageMETs] as? HKQuantity)?
            .doubleValue(for: HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour())))
        result.lapLength = (metadata[HKMetadataKeyLapLength] as? HKQuantity)?.doubleValue(for: .meter())
        let locations = await route(workout)
        result.track = locations.map { TrackPlacement.Point(date: $0.timestamp, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        result.route = Self.thinned(locations)
        if result.speed.maximum == nil {
            result.speed.maximum = locations.map(\.speed).filter { $0 >= 0 }.max()
        }
        return result
    }

    /// Statistics the app attached to the workout, else those of every source during its time span.
    private func range(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit, _ workout: HKWorkout) async -> HealthWorkoutDetails.Range {
        let type = HKQuantityType(identifier)
        if let own = workout.statistics(for: type), own.averageQuantity() != nil {
            return .init(average: own.averageQuantity()?.doubleValue(for: unit), maximum: own.maximumQuantity()?.doubleValue(for: unit))
        }
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)
        let query = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate),
                                                options: [.discreteAverage, .discreteMax])
        guard let statistics = try? await query.result(for: store) else { return .init() }
        return .init(average: statistics.averageQuantity()?.doubleValue(for: unit), maximum: statistics.maximumQuantity()?.doubleValue(for: unit))
    }

    private func total(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit, _ workout: HKWorkout) async -> Double? {
        let type = HKQuantityType(identifier)
        if let own = workout.statistics(for: type)?.sumQuantity() { return own.doubleValue(for: unit) }
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)
        let query = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: .cumulativeSum)
        guard let value = (try? await query.result(for: store))?.sumQuantity()?.doubleValue(for: unit), value > 0 else { return nil }
        return value
    }

    /// All recorded positions of the workout's routes, in order.
    private func route(_ workout: HKWorkout) async -> [CLLocation] {
        let routes = HKSampleQueryDescriptor(predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
                                             sortDescriptors: [SortDescriptor(\.startDate)])
        guard let samples = try? await routes.result(for: store) else { return [] }
        var locations: [CLLocation] = []
        for sample in samples {
            do {
                for try await location in HKWorkoutRouteQueryDescriptor(sample).results(for: store) { locations.append(location) }
            } catch { continue }
        }
        return locations
    }

    /// At most 2000 positions for the map, first and last kept, with the speed since the previous one.
    private static func thinned(_ locations: [CLLocation], limit: Int = 2000) -> [FITActivity.Coordinate] {
        let picked = locations.count > limit
            ? (0..<limit).map { locations[Int((Double($0) * Double(locations.count - 1) / Double(limit - 1)).rounded())] } : locations
        return picked.indices.map { index in
            let location = picked[index]
            var speed: Double?
            if index > 0 {
                let seconds = location.timestamp.timeIntervalSince(picked[index - 1].timestamp)
                if seconds > 0 { speed = location.distance(from: picked[index - 1]) / seconds }
            }
            return FITActivity.Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, speed: speed)
        }
    }
}

/// Read-only details of a Health workout, laid out like a FITgap activity; the data stays in Apple Health.
struct HealthWorkoutDetailView: View {
    let workout: HealthWorkout
    @State private var details: HealthWorkoutDetails?
    @State private var loadedID: UUID?
    @State private var read = false
    @State private var needsAccess = false
    @State private var request = false
    @State private var reload = 0
    @StateObject private var photos = ActivityPhotos()
    @State private var photosReload = 0
    private let reader = HealthWorkoutReader()

    var body: some View {
        List {
            // Health keeps routes for outdoor workouts only; the section appears once one is read.
            RouteSection(id: workout.id.uuidString, title: workout.name, expected: !(details?.route.isEmpty ?? true),
                         virtual: false, route: details?.route ?? [], read: read, photos: photos)
            PhotoSection(photos: photos) { photosReload += 1 }
            Section {
                row("Sportart", workout.name)
                row("Start", workout.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                row("Quelle", workout.sourceName)
                row("Gerät", details?.device)
                if workout.indoor { row("Ort", String(localized: "Drinnen")) }
            }
            Section {
                row("Anstieg", workout.ascentMeters.map(ActivityFormat.meters))
                row("Strecke", ActivityFormat.distance(workout.distanceMeters))
                row("Dauer", ActivityFormat.duration(workout.duration))
                if abs(workout.interval.duration - workout.duration) >= 1 { row("Gesamtzeit", ActivityFormat.duration(workout.interval.duration)) }
                row("Ø Geschwindigkeit", ActivityFormat.speed(details?.speed.average ?? averageSpeed))
                row("Max. Geschwindigkeit", ActivityFormat.speed(details?.speed.maximum))
                row("Kalorien", workout.energyKilocalories.map { ActivityFormat.integer($0) + " kcal" })
                row("Schritte", details?.steps.map(ActivityFormat.integer))
                row("Schwimmzüge", details?.strokes.map(ActivityFormat.integer))
                row("Bahnlänge", details?.lapLength.map(ActivityFormat.meters))
            }
            Section {
                row("Ø Herzfrequenz", details?.heartRate.average.map(heartRate))
                row("Max. Herzfrequenz", details?.heartRate.maximum.map(heartRate))
                row("Ø Trittfrequenz", details?.cadence.average.map(cadence))
                row("Max. Trittfrequenz", details?.cadence.maximum.map(cadence))
                row("Ø Leistung", details?.power.average.map { ActivityFormat.integer($0) + " W" })
                row("Max. Leistung", details?.power.maximum.map { ActivityFormat.integer($0) + " W" })
                row("Ø Atemfrequenz", details?.respiratoryRate.map { String(localized: "\(Int($0.rounded())) Atemzüge/min") })
            } footer: {
                if !read { Text("Messwerte werden aus Apple Health gelesen …") }
            }
            if let details, details.laps > 0 || details.pauses > 0 || details.temperature != nil || details.humidity != nil || details.mets != nil {
                Section {
                    if details.laps > 0 { row("Runden", String(details.laps)) }
                    if details.pauses > 0 { row("Pausen", String(details.pauses)) }
                    row("Temperatur", details.temperature)
                    row("Luftfeuchtigkeit", details.humidity.map { $0.formatted(.percent.precision(.fractionLength(0))) })
                    row("Ø MET", details.mets.map { $0.formatted(.number.precision(.fractionLength(1))) })
                }
            }
            Section {
                if needsAccess {
                    Button("Alle Messwerte lesen", systemImage: "heart.text.square") { request.toggle() }
                        .accessibilityIdentifier("health-workout-access")
                }
                row("App-Version", details?.appVersion)
            } header: {
                Text("Apple Health")
            } footer: {
                Text(needsAccess
                     ? "Für Herzfrequenz, Leistung, Trittfrequenz, Tempo und Route braucht FITgap Lesezugriff auf diese Werte in Apple Health."
                     : "Dieses Workout stammt aus Apple Health. Health speichert keine FIT-Datei, nur die Messwerte; FITgap zeigt sie hier an. Teilen oder Löschen ist hier nicht möglich.")
            }
        }
        .task(id: "\(workout.id)-\(reload)") {
            // Side by side the details view stays while the selection changes, so the last values are cleared.
            if loadedID != workout.id { details = nil }
            read = false
            needsAccess = await reader.needsRequest()
            let loaded = await reader.details(workout.id)
            guard !Task.isCancelled else { return }
            details = loaded
            loadedID = workout.id
            read = true
            photosReload += 1
        }
        .task(id: "\(workout.id)-\(photosReload)") {
            let track = details?.track ?? []
            await photos.load(workout.interval, onMap: !workout.indoor && (details?.route.count ?? 0) > 1) { track }
        }
        .healthDataAccessRequest(store: reader.store, shareTypes: [], readTypes: HealthWorkoutReader.readTypes, trigger: request) { _ in
            Task { @MainActor in reload += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in photosReload += 1 }
        .onDisappear { photos.removeFiles() }
        .photoViewer($photos.listPreview, in: photos.previewURLs)
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var averageSpeed: Double? {
        guard let meters = workout.distanceMeters, workout.duration > 0 else { return nil }
        return meters / workout.duration
    }

    @ViewBuilder private func row(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value { LabeledContent(title, value: value) }
    }

    private func heartRate(_ value: Double) -> String { String(localized: "\(Int(value.rounded())) S/min") }
    private func cadence(_ value: Double) -> String { String(localized: "\(Int(value.rounded())) U/min") }
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
