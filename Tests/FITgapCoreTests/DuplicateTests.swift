import Foundation
import Testing
@testable import FITgapCore

private func copy(_ source: Source, _ id: String, start: Double, duration: Double, status: DownloadStatus = .available,
                  channels: Set<DataRichness.Channel>? = nil, samples: Int = 100) -> ActivityRecord {
    var record = ActivityRecord(source: source, remoteID: id, name: id, date: Date(timeIntervalSince1970: start), duration: duration, status: status)
    if let channels { record.metrics = ActivityMetrics(); record.metrics?.richness = DataRichness(channels: channels, samples: samples) }
    return record
}

@Test func duplicatesPreferTheFullestDownloadedCopy() {
    let wahoo = copy(.wahoo, "w", start: 0, duration: 3600, channels: [.heartRate, .power, .cadence, .speed])
    let zwift = copy(.zwift, "z", start: 30, duration: 3540, channels: [.heartRate, .power, .cadence, .speed, .distance, .altitude])
    let mywhoosh = copy(.mywhoosh, "m", start: 0, duration: 3600, status: .pending)
    let later = copy(.wahoo, "later", start: 3700, duration: 600, channels: [.heartRate])
    let groups = DuplicateGroups([wahoo, zwift, mywhoosh, later])
    #expect(groups.alternatives[zwift.key] == [wahoo.key, mywhoosh.key])
    #expect(groups.hidden == [wahoo.key, mywhoosh.key])
    #expect(groups.preferred(for: mywhoosh.key) == zwift.key && groups.preferred(for: later.key) == later.key)
}

@Test func duplicatesBreakTiesAndKeepOneRecordPerSource() {
    let channels: Set<DataRichness.Channel> = [.heartRate, .power]
    // Equal data: the source order decides; more samples win over that.
    #expect(DuplicateGroups([copy(.mywhoosh, "m", start: 0, duration: 3600, channels: channels),
                             copy(.zwift, "z", start: 0, duration: 3600, channels: channels)]).hidden == [ActivityKey(source: "mywhoosh", id: "m")])
    #expect(DuplicateGroups([copy(.mywhoosh, "m", start: 0, duration: 3600, channels: channels, samples: 200),
                             copy(.zwift, "z", start: 0, duration: 3600, channels: channels)]).hidden == [ActivityKey(source: "zwift", id: "z")])
    // Two Wahoo rides that one Zwift entry overlaps stay separate activities.
    let first = copy(.wahoo, "a", start: 0, duration: 1000, channels: channels)
    let second = copy(.wahoo, "b", start: 600, duration: 1000, channels: channels)
    let spanning = copy(.zwift, "c", start: 300, duration: 1000, status: .pending)
    #expect(DuplicateGroups([first, second, spanning]).hidden == [spanning.key])
    // Short overlaps are different workouts.
    #expect(DuplicateGroups([copy(.wahoo, "x", start: 0, duration: 1000), copy(.zwift, "y", start: 900, duration: 1000)]).hidden.isEmpty)
}
