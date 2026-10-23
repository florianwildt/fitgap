import CoreLocation
import FITgapCore
import Foundation
import HealthKit

enum HealthExportError: Error, LocalizedError {
    case unavailable, notAuthorized, notSaved
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Apple Health ist auf diesem Gerät nicht verfügbar.")
        case .notAuthorized: String(localized: "FITgap darf keine Trainings in Apple Health sichern. Erlaube den Zugriff unter Einstellungen › Apps › Health › Datenzugriff & Geräte › FITgap.")
        case .notSaved: String(localized: "Apple Health hat das Training nicht gespeichert. Bitte später erneut versuchen.")
        }
    }
}

/// Writes a verified original FIT to Apple Health: one workout with every record sample Health has a type for,
/// laps, swim lengths, pauses, the GPS route and the session summary as metadata.
/// Read access covers workouts only and serves solely the duplicate check before writing.
struct HealthExporter: Sendable {
    enum Outcome: Sendable { case exported, existing(String) }

    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static var quantityTypes: [HKQuantityTypeIdentifier] {
        var types: [HKQuantityTypeIdentifier] = [
            .heartRate, .respiratoryRate, .activeEnergyBurned, .stepCount, .swimmingStrokeCount,
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair, .distanceDownhillSnowSports,
            .cyclingPower, .cyclingCadence, .cyclingSpeed,
            .runningPower, .runningSpeed, .runningStrideLength, .runningVerticalOscillation, .runningGroundContactTime
        ]
        if #available(iOS 18, *) { types += [.distanceRowing, .distanceCrossCountrySkiing, .distancePaddleSports, .distanceSkatingSports] }
        return types
    }

    var canWrite: Bool { Self.isAvailable && store.authorizationStatus(for: .workoutType()) == .sharingAuthorized }

    /// Asks once per new type; iOS shows no sheet when every type was already decided.
    func requestAuthorization() async throws {
        guard Self.isAvailable else { throw HealthExportError.unavailable }
        let share = Set(Self.quantityTypes.map { HKQuantityType($0) as HKSampleType } + [.workoutType(), HKSeriesType.workoutRoute()])
        try await store.requestAuthorization(toShare: share, read: [.workoutType()])
    }

    /// `includeOverlaps` writes even when another app's workout covers the same time; FITgap's own earlier export is always respected.
    func export(_ activity: FITActivity, syncIdentifier: String, name: String, source: String, sha256: String,
                includeOverlaps: Bool = false) async throws -> Outcome {
        guard canWrite else { throw HealthExportError.notAuthorized }
        guard let start = activity.start, let end = activity.end, end > start,
              let main = activity.sessions.max(by: { $0.interval.duration < $1.interval.duration }) else { throw HealthExportError.notSaved }
        let interval = DateInterval(start: start, end: end)
        if let existing = try await existingSource(syncIdentifier: syncIdentifier, interval: interval, includeOverlaps: includeOverlaps) {
            return .existing(existing)
        }

        let hasRoute = activity.records.contains { $0.latitude != nil }
        let sports = Set(activity.sessions.map { $0.sport ?? -1 })
        // FIT multisport (triathlon) becomes one swim-bike-run workout with an activity per session.
        let multisport = activity.sessions.count > 1 && sports.count > 1 && sports.isSubset(of: [1, 2, 3, 5])
        let configuration = multisport ? Self.multisportConfiguration() : Self.configuration(main, hasRoute: hasRoute)
        let device = Self.device(activity.device, source: source)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: device)
        do {
            try await builder.beginCollection(at: start)
            let samples = samples(activity, device: device)
            for offset in stride(from: 0, to: samples.count, by: 10_000) {
                try Task.checkCancellation()
                try await builder.addSamples(Array(samples[offset..<min(offset + 10_000, samples.count)]))
            }
            let events = Self.events(activity, interval: interval)
            if !events.isEmpty { try await builder.addWorkoutEvents(events) }
            if multisport {
                for session in activity.sessions where session.end > session.start {
                    try await builder.addWorkoutActivity(HKWorkoutActivity(
                        workoutConfiguration: Self.configuration(session, hasRoute: hasRoute),
                        start: max(session.start, start), end: min(session.end, end), metadata: Self.metadata([session])))
                }
            }
            var metadata = Self.metadata(activity.sessions)
            metadata[HKMetadataKeySyncIdentifier] = syncIdentifier
            metadata[HKMetadataKeySyncVersion] = 1
            metadata["FITgapName"] = name
            metadata["FITgapSource"] = source
            metadata["FITgapFileSHA256"] = sha256
            if let indoor = Self.indoor(main, hasRoute: hasRoute), !multisport { metadata[HKMetadataKeyIndoorWorkout] = indoor }
            try await builder.addMetadata(metadata)
            try await builder.endCollection(at: end)
        } catch {
            builder.discardWorkout()
            throw error
        }
        guard let workout = try await builder.finishWorkout() else { throw HealthExportError.notSaved }
        // Every recorded position is kept, including the virtual coordinates of indoor rides (e.g. Zwift worlds);
        // the workout itself stays marked as indoor.
        if hasRoute, store.authorizationStatus(for: HKSeriesType.workoutRoute()) == .sharingAuthorized {
            try? await saveRoute(activity, workout: workout, device: device)
        }
        return .exported
    }

    // MARK: Duplicate check

    /// Name of the app whose workout already covers this activity: FITgap's own earlier export,
    /// or any workout that overlaps at least half of the shorter of both durations (watch, HealthFit, provider apps).
    private func existingSource(syncIdentifier: String, interval: DateInterval, includeOverlaps: Bool) async throws -> String? {
        let own = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncIdentifier]))], sortDescriptors: [], limit: 1)
        if let workout = try await own.result(for: store).first { return workout.sourceRevision.source.name }
        guard !includeOverlaps else { return nil }
        let overlapping = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end))], sortDescriptors: [], limit: HKObjectQueryNoLimit)
        for workout in try await overlapping.result(for: store) {
            let other = DateInterval(start: workout.startDate, end: max(workout.startDate, workout.endDate))
            if Self.sameWorkout(interval, other) { return workout.sourceRevision.source.name }
        }
        return nil
    }

    /// Two workouts are the same when they overlap at least half of the shorter duration.
    static func sameWorkout(_ first: DateInterval, _ second: DateInterval) -> Bool {
        guard let shared = first.intersection(with: second) else { return false }
        return shared.duration >= 0.5 * min(first.duration, second.duration)
    }

    // MARK: Samples

    private enum Kind { case cycling, running, walking, swimming, wheelchair, rowing, crossCountrySkiing, downhill, paddling, skating, other }

    /// FIT `sport`/`sub_sport` values (Garmin FIT Global Profile).
    private static func kind(_ session: FITActivity.Session) -> Kind {
        switch (session.sport, session.subSport) {
        case (2, _), (21, _), (4, 6): .cycling
        case (1, _): .running
        case (11, _), (16, _), (17, _): .walking
        case (5, _): .swimming
        case (65, _), (66, _): .wheelchair
        case (15, _), (4, 14): .rowing
        case (12, _): .crossCountrySkiing
        case (13, _), (14, _): .downhill
        case (19, _), (37, _), (41, _), (42, _): .paddling
        case (30, _), (33, _): .skating
        default: .other
        }
    }

    private static func distanceType(_ kind: Kind) -> HKQuantityTypeIdentifier? {
        switch kind {
        case .cycling: return .distanceCycling
        case .running, .walking: return .distanceWalkingRunning
        case .swimming: return .distanceSwimming
        case .wheelchair: return .distanceWheelchair
        case .downhill: return .distanceDownhillSnowSports
        case .other: return nil
        case .rowing, .crossCountrySkiing, .paddling, .skating:
            guard #available(iOS 18, *) else { return nil }
            switch kind {
            case .rowing: return .distanceRowing
            case .crossCountrySkiing: return .distanceCrossCountrySkiing
            case .paddling: return .distancePaddleSports
            default: return .distanceSkatingSports
            }
        }
    }

    /// Instantaneous record values become point samples; accumulated values become deltas between records.
    /// Session totals are only used where the records carry no accumulated values.
    private func samples(_ activity: FITActivity, device: HKDevice) -> [HKSample] {
        var allowed: [HKQuantityTypeIdentifier: Bool] = [:]
        var result: [HKSample] = []
        func add(_ id: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit, _ start: Date, _ end: Date) {
            guard value.isFinite, value >= 0, end >= start else { return }
            let permitted = allowed[id] ?? (store.authorizationStatus(for: HKQuantityType(id)) == .sharingAuthorized)
            allowed[id] = permitted
            guard permitted else { return }
            result.append(HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value),
                                           start: start, end: end, device: device, metadata: nil))
        }
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        let speed = HKUnit.meter().unitDivided(by: .second())
        var remaining = activity.records[...]
        for (index, session) in activity.sessions.enumerated() {
            let kind = Self.kind(session)
            // Records belong to the session they start in; the last session also takes trailing records.
            let last = index == activity.sessions.count - 1
            let count = remaining.prefix { last || $0.date < session.end }.count
            let records = remaining.prefix(count)
            remaining = remaining.dropFirst(count)
            let lengths = activity.lengths.filter { $0.active && session.interval.contains($0.interval.start) }
            let pool = session.poolLengthMeters.flatMap { $0 > 0 ? $0 : nil }
            let lengthDistance = kind == .swimming && !lengths.isEmpty && pool != nil
            var distance: (date: Date, value: Double)?
            var energy: (date: Date, value: Double)?
            var previous: FITActivity.Record?
            var recordedDistance = false, recordedEnergy = false
            for record in records {
                let date = record.date
                if let value = record.heartRate, value > 0 { add(.heartRate, value, perMinute, date, date) }
                if let value = record.respirationRate, value > 0 { add(.respiratoryRate, value, perMinute, date, date) }
                switch kind {
                case .cycling:
                    if let value = record.power { add(.cyclingPower, value, .watt(), date, date) }
                    if let value = record.cadence { add(.cyclingCadence, value, perMinute, date, date) }
                    if let value = record.speed { add(.cyclingSpeed, value, speed, date, date) }
                case .running:
                    if let value = record.power { add(.runningPower, value, .watt(), date, date) }
                    if let value = record.speed { add(.runningSpeed, value, speed, date, date) }
                    if let value = record.stepLengthMeters { add(.runningStrideLength, value, .meter(), date, date) }
                    if let value = record.verticalOscillationMeters { add(.runningVerticalOscillation, value * 100, .meterUnit(with: .centi), date, date) }
                    if let value = record.groundContactSeconds { add(.runningGroundContactTime, value * 1000, .secondUnit(with: .milli), date, date) }
                default: break
                }
                if !lengthDistance, let value = record.distanceMeters {
                    if let distance, value > distance.value, let id = Self.distanceType(kind) {
                        add(id, value - distance.value, .meter(), distance.date, date)
                    }
                    distance = (date, value); recordedDistance = true
                }
                if let value = record.energyKilocalories {
                    if let energy, value > energy.value { add(.activeEnergyBurned, value - energy.value, .kilocalorie(), energy.date, date) }
                    energy = (date, value); recordedEnergy = true
                }
                // FIT running cadence counts strides (one foot) per minute; Health counts steps.
                if kind == .running || kind == .walking, let previous, let cadence = previous.cadence, cadence > 0 {
                    let seconds = date.timeIntervalSince(previous.date)
                    if seconds > 0, seconds <= 30 { add(.stepCount, cadence * 2 * seconds / 60, .count(), previous.date, date) }
                }
                previous = record
            }
            if lengthDistance, let pool {
                for length in lengths { add(.distanceSwimming, pool, .meter(), length.interval.start, length.interval.end) }
            } else if !recordedDistance, let value = session.distanceMeters, value > 0, let id = Self.distanceType(kind) {
                add(id, value, .meter(), session.start, session.end)
            }
            if kind == .swimming {
                for length in lengths { if let strokes = length.strokes, strokes > 0 { add(.swimmingStrokeCount, strokes, .count(), length.interval.start, length.interval.end) } }
            }
            if !recordedEnergy, let value = session.energyKilocalories, value > 0 {
                add(.activeEnergyBurned, value, .kilocalorie(), session.start, session.end)
            }
        }
        return result
    }

    // MARK: Events, configuration, metadata

    /// Timer stops and starts as pause/resume pairs, FIT laps as segments and active swim lengths as laps.
    private static func events(_ activity: FITActivity, interval: DateInterval) -> [HKWorkoutEvent] {
        var events: [HKWorkoutEvent] = []
        var pausedAt: Date?
        for event in activity.timerEvents where event.date > interval.start && event.date < interval.end {
            if !event.running, pausedAt == nil { pausedAt = event.date }
            else if event.running, let paused = pausedAt {
                events.append(HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: paused, duration: 0), metadata: nil))
                events.append(HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: event.date, duration: 0), metadata: nil))
                pausedAt = nil
            }
        }
        if activity.laps.count > 1 {
            for lap in activity.laps {
                guard let clamped = lap.interval.intersection(with: interval), clamped.duration > 0 else { continue }
                events.append(HKWorkoutEvent(type: .segment, dateInterval: clamped, metadata: nil))
            }
        }
        for length in activity.lengths where length.active {
            guard let clamped = length.interval.intersection(with: interval), clamped.duration > 0 else { continue }
            let style: HKSwimmingStrokeStyle = switch length.stroke {
            case 0: .freestyle
            case 1: .backstroke
            case 2: .breaststroke
            case 3: .butterfly
            case 5, 6: .mixed
            default: .unknown
            }
            events.append(HKWorkoutEvent(type: .lap, dateInterval: clamped,
                                         metadata: [HKMetadataKeySwimmingStrokeStyle: style.rawValue]))
        }
        return events.sorted { $0.dateInterval.start < $1.dateInterval.start }
    }

    private static func multisportConfiguration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .swimBikeRun
        return configuration
    }

    private static func configuration(_ session: FITActivity.Session, hasRoute: Bool) -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType(session)
        switch indoor(session, hasRoute: hasRoute) {
        case true?: configuration.locationType = .indoor
        case false?: configuration.locationType = .outdoor
        case nil: configuration.locationType = .unknown
        }
        if session.sport == 5 {
            switch session.subSport {
            case 17:
                configuration.swimmingLocationType = .pool
                if let pool = session.poolLengthMeters, pool > 0 { configuration.lapLength = HKQuantity(unit: .meter(), doubleValue: pool) }
            case 18: configuration.swimmingLocationType = .openWater
            default: configuration.swimmingLocationType = .unknown
            }
        }
        return configuration
    }

    /// Treadmill, indoor cycling/rowing/walking, elliptical, stairs, virtual activities and fitness equipment are indoors.
    private static func indoor(_ session: FITActivity.Session, hasRoute: Bool) -> Bool? {
        if session.sport == 4 || [1, 6, 14, 15, 16, 27, 58].contains(session.subSport ?? -1) { return true }
        if session.sport == 5 { return nil }
        return hasRoute ? false : nil
    }

    /// FIT `sport`/`sub_sport` values (Garmin FIT Global Profile).
    private static func activityType(_ session: FITActivity.Session) -> HKWorkoutActivityType {
        switch (session.sport, session.subSport) {
        case (1, _): .running
        case (2, _), (21, _), (4, 6): .cycling
        case (3, _): .transition
        case (4, 14), (15, _): .rowing
        case (4, 15): .elliptical
        case (4, 16), (48, _): .stairClimbing
        case (5, _): .swimming
        case (7, _): .soccer
        case (8, _): .tennis
        case (9, _): .americanFootball
        case (10, 20): .traditionalStrengthTraining
        case (10, 26): .mixedCardio
        case (10, 43): .yoga
        case (10, 44): .pilates
        case (10, _): .functionalStrengthTraining
        case (11, _): .walking
        case (12, _): .crossCountrySkiing
        case (13, _): .downhillSkiing
        case (14, _): .snowboarding
        case (16, _), (17, _): .hiking
        case (18, _): .swimBikeRun
        case (19, _), (37, _), (41, _), (42, _): .paddleSports
        case (25, _): .golf
        case (27, _): .equestrianSports
        case (28, _): .hunting
        case (29, _): .fishing
        case (30, _), (33, _): .skatingSports
        case (31, _): .climbing
        case (32, _): .sailing
        case (35, _): .snowSports
        case (38, _): .surfingSports
        case (39, _), (40, _), (43, _), (44, _): .waterSports
        case (47, _): .boxing
        case (53, _): .underwaterDiving
        case (62, _): .highIntensityIntervalTraining
        case (65, _): .wheelchairWalkPace
        case (66, _): .wheelchairRunPace
        case (67, _): .mindAndBody
        default: .other
        }
    }

    /// Session summary as metadata: Health's own keys where they exist, `FITgap…` keys for values Health has no type for.
    private static func metadata(_ sessions: [FITActivity.Session]) -> [String: Any] {
        var metadata: [String: Any] = [:]
        func total(_ value: (FITActivity.Session) -> Double?) -> Double? {
            let values = sessions.compactMap(value)
            return values.count == sessions.count ? values.reduce(0, +) : nil
        }
        func maximum(_ value: (FITActivity.Session) -> Double?) -> Double? { sessions.compactMap(value).max() }
        let single = sessions.count == 1 ? sessions.first : nil
        if let value = total(\.ascentMeters) { metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: value) }
        if let value = total(\.descentMeters) { metadata["FITgapElevationDescended"] = value }
        if let value = single?.averageSpeed { metadata[HKMetadataKeyAverageSpeed] = HKQuantity(unit: .meter().unitDivided(by: .second()), doubleValue: value) }
        if let value = maximum(\.maximumSpeed) { metadata[HKMetadataKeyMaximumSpeed] = HKQuantity(unit: .meter().unitDivided(by: .second()), doubleValue: value) }
        if let value = single?.averageTemperature { metadata[HKMetadataKeyWeatherTemperature] = HKQuantity(unit: .degreeCelsius(), doubleValue: value) }
        if let pool = single?.poolLengthMeters, pool > 0, single?.sport == 5 {
            metadata[HKMetadataKeyLapLength] = HKQuantity(unit: .meter(), doubleValue: pool)
        }
        let custom: [(String, Double?)] = [
            ("FITgapTimerTime", total(\.timerSeconds)),
            ("FITgapDistance", total(\.distanceMeters)),
            ("FITgapEnergy", total(\.energyKilocalories)),
            ("FITgapAverageHeartRate", single?.averageHeartRate), ("FITgapMaximumHeartRate", maximum(\.maximumHeartRate)),
            ("FITgapMinimumHeartRate", sessions.compactMap(\.minimumHeartRate).min()),
            ("FITgapAverageCadence", single?.averageCadence), ("FITgapMaximumCadence", maximum(\.maximumCadence)),
            ("FITgapAveragePower", single?.averagePower), ("FITgapMaximumPower", maximum(\.maximumPower)),
            ("FITgapNormalizedPower", single?.normalizedPower), ("FITgapThresholdPower", single?.thresholdPower),
            ("FITgapTrainingStressScore", total(\.trainingStressScore)), ("FITgapIntensityFactor", single?.intensityFactor),
            ("FITgapWork", total(\.workJoules)),
            ("FITgapAerobicTrainingEffect", single?.aerobicTrainingEffect),
            ("FITgapAnaerobicTrainingEffect", single?.anaerobicTrainingEffect),
            ("FITgapMaximumTemperature", maximum(\.maximumTemperature)),
            ("FITgapLengthCount", total(\.lengthCount)), ("FITgapCycles", total(\.cycles))
        ]
        for (key, value) in custom { if let value { metadata[key] = value } }
        return metadata
    }

    /// FIT `manufacturer` enum values for common training sources.
    private static func device(_ device: FITActivity.Device, source: String) -> HKDevice {
        let manufacturer: String? = switch device.manufacturer {
        case 1: "Garmin"
        case 32: "Wahoo Fitness"
        case 69: "Stages Cycling"
        case 89: "Tacx"
        case 260: "Zwift"
        default: nil
        }
        return HKDevice(name: device.productName ?? manufacturer ?? source, manufacturer: manufacturer,
                        model: device.product.map(String.init), hardwareVersion: nil, firmwareVersion: nil,
                        softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
    }

    // MARK: Route

    private func saveRoute(_ activity: FITActivity, workout: HKWorkout, device: HKDevice) async throws {
        // FIT stores no accuracy; a nominal GNSS accuracy marks the coordinates as valid for Health.
        let locations = activity.records.compactMap { record -> CLLocation? in
            guard let latitude = record.latitude, let longitude = record.longitude, latitude != 0 || longitude != 0 else { return nil }
            return CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                              altitude: record.altitudeMeters ?? 0, horizontalAccuracy: 5,
                              verticalAccuracy: record.altitudeMeters == nil ? -1 : 5,
                              course: -1, speed: record.speed ?? -1, timestamp: record.date)
        }
        guard locations.count > 1 else { return }
        let builder = HKWorkoutRouteBuilder(healthStore: store, device: device)
        for offset in stride(from: 0, to: locations.count, by: 5000) {
            try await builder.insertRouteData(Array(locations[offset..<min(offset + 5000, locations.count)]))
        }
        _ = try await builder.finishRoute(with: workout, metadata: nil)
    }
}
