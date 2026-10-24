import Foundation

/// How much a FIT holds, to pick the fullest copy when several sources deliver the same workout.
public struct DataRichness: Codable, Sendable, Equatable {
    /// Measurement series in the record messages.
    public enum Channel: String, Codable, CaseIterable, Sendable {
        case position, altitude, heartRate, cadence, distance, speed, power, temperature
        case verticalOscillation, groundContact, stepLength, respiration, energy
    }

    public let channels: Set<Channel>
    /// Developer fields defined for records, e.g. core temperature or muscle oxygen.
    public let developerFields: Int
    /// Session totals and analyses that are set, such as normalized power or training effect.
    public let summaryFields: Int
    public let laps: Int
    public let lengths: Int
    public let samples: Int

    public init(channels: Set<Channel>, developerFields: Int = 0, summaryFields: Int = 0, laps: Int = 0, lengths: Int = 0, samples: Int = 0) {
        self.channels = channels; self.developerFields = developerFields; self.summaryFields = summaryFields
        self.laps = laps; self.lengths = lengths; self.samples = samples
    }

    public init(_ activity: FITActivity) {
        var channels = Set<Channel>()
        let probes: [(Channel, (FITActivity.Record) -> Bool)] = [
            (.position, { $0.latitude != nil && $0.longitude != nil }), (.altitude, { $0.altitudeMeters != nil }),
            (.heartRate, { $0.heartRate != nil }), (.cadence, { $0.cadence != nil }),
            (.distance, { $0.distanceMeters != nil }), (.speed, { $0.speed != nil }), (.power, { $0.power != nil }),
            (.temperature, { $0.temperature != nil }), (.verticalOscillation, { $0.verticalOscillationMeters != nil }),
            (.groundContact, { $0.groundContactSeconds != nil }), (.stepLength, { $0.stepLengthMeters != nil }),
            (.respiration, { $0.respirationRate != nil }), (.energy, { $0.energyKilocalories != nil })
        ]
        for (channel, probe) in probes where activity.records.contains(where: probe) { channels.insert(channel) }
        let totals: [KeyPath<FITActivity.Session, Double?>] = [
            \.timerSeconds, \.distanceMeters, \.energyKilocalories, \.ascentMeters, \.descentMeters, \.averageSpeed,
            \.maximumSpeed, \.averageHeartRate, \.maximumHeartRate, \.minimumHeartRate, \.averageCadence, \.maximumCadence,
            \.averagePower, \.maximumPower, \.normalizedPower, \.thresholdPower, \.trainingStressScore, \.intensityFactor,
            \.workJoules, \.aerobicTrainingEffect, \.anaerobicTrainingEffect, \.averageTemperature, \.maximumTemperature,
            \.poolLengthMeters, \.lengthCount, \.cycles
        ]
        self.init(channels: channels, developerFields: activity.developerFields,
                  summaryFields: totals.filter { field in activity.sessions.contains { $0[keyPath: field] != nil } }.count,
                  laps: activity.laps.count, lengths: activity.lengths.count, samples: activity.records.count)
    }

    /// Measurement series weigh most, then session analyses, laps and swim lengths, and finally sample density.
    var rank: [Int] { [channels.count + developerFields, summaryFields, laps + lengths, samples] }

    public static func > (lhs: DataRichness, rhs: DataRichness) -> Bool {
        rhs.rank.lexicographicallyPrecedes(lhs.rank)
    }
}

/// The same workout delivered by several sources, e.g. recorded on a Wahoo head unit and ridden in Zwift.
/// Only the fullest copy is shown, shared and saved to Apple Health; the others stay stored.
public struct DuplicateGroups: Sendable {
    /// Copies another source covers with a fuller or already downloaded file.
    public private(set) var hidden: Set<ActivityKey> = []
    /// Other copies of a preferred record, fullest first.
    public private(set) var alternatives: [ActivityKey: [ActivityKey]] = [:]
    private var preferred: [ActivityKey: ActivityKey] = [:]

    public init() {}

    public init(_ records: [ActivityRecord]) {
        let candidates = records.compactMap { record -> (record: ActivityRecord, interval: DateInterval)? in
            guard record.source != .demo, let start = record.date,
                  let duration = record.duration ?? record.metrics?.elapsedSeconds, duration > 0 else { return nil }
            return (record, DateInterval(start: start, duration: duration))
        }.sorted { $0.interval.start < $1.interval.start }
        guard candidates.count > 1 else { return }

        // Union-find over overlapping workouts; a group never takes two records of one source.
        var parent = Array(candidates.indices)
        var sources = candidates.map { Set([$0.record.source]) }
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { parent[index] = parent[parent[index]]; index = parent[index] }
            return index
        }
        for first in candidates.indices {
            for second in candidates.indices.dropFirst(first + 1) {
                guard candidates[second].interval.start < candidates[first].interval.end else { break }
                guard Self.sameWorkout(candidates[first].interval, candidates[second].interval) else { continue }
                let a = root(first), b = root(second)
                guard a != b, sources[a].isDisjoint(with: sources[b]) else { continue }
                parent[b] = a
                sources[a].formUnion(sources[b])
            }
        }
        var groups: [Int: [ActivityRecord]] = [:]
        for index in candidates.indices { groups[root(index), default: []].append(candidates[index].record) }
        for group in groups.values where group.count > 1 {
            let ordered = group.sorted(by: Self.better)
            let best = ordered[0].key
            alternatives[best] = ordered.dropFirst().map(\.key)
            for other in ordered.dropFirst() { hidden.insert(other.key); preferred[other.key] = best }
        }
    }

    /// Same rule as the Apple Health check: the workouts overlap at least half of the shorter one.
    public static func sameWorkout(_ first: DateInterval, _ second: DateInterval) -> Bool {
        guard let shared = first.intersection(with: second) else { return false }
        return shared.duration >= 0.5 * min(first.duration, second.duration)
    }

    /// A downloaded file beats one still to load; then the fuller file wins, then the source order.
    static func better(_ lhs: ActivityRecord, _ rhs: ActivityRecord) -> Bool {
        let lhsAvailable = lhs.status == .available, rhsAvailable = rhs.status == .available
        if lhsAvailable != rhsAvailable { return lhsAvailable }
        let lhsRichness = lhs.metrics?.richness, rhsRichness = rhs.metrics?.richness
        if let lhsRichness, let rhsRichness {
            if lhsRichness > rhsRichness { return true }
            if rhsRichness > lhsRichness { return false }
        } else if (lhsRichness == nil) != (rhsRichness == nil) { return lhsRichness != nil }
        let order = Source.providers
        let lhsOrder = order.firstIndex(of: lhs.source) ?? order.count, rhsOrder = order.firstIndex(of: rhs.source) ?? order.count
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        return lhs.id < rhs.id
    }

    /// The record shown in place of a hidden copy.
    public func preferred(for key: ActivityKey) -> ActivityKey { preferred[key] ?? key }
}
