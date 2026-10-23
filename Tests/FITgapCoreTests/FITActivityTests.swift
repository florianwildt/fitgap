import Foundation
import Testing
@testable import FITgapCore

private func le(_ value: UInt32, _ size: Int) -> [UInt8] {
    (0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}
private func fit(_ body: [UInt8]) -> Data {
    Data([14, 0x20, 0, 0] + le(UInt32(body.count), 4) + Array(".FIT".utf8) + [0, 0] + body + [0, 0])
}

@Test func fitActivityReadsRecordsCompressedTimestampsAndPauses() throws {
    let start: UInt32 = 1_000_000_000
    // Record: timestamp, position_lat/long (sint32 semicircles), heart_rate, power.
    var body: [UInt8] = [0x40, 0, 0] + le(20, 2) + [5, 253, 4, 0x86, 0, 4, 0x85, 1, 4, 0x85, 3, 1, 0x02, 7, 2, 0x84]
    body += [0] + le(start, 4) + le(UInt32(bitPattern: -536_870_912), 4) + le(1_073_741_824, 4) + [120] + le(250, 2)
    // Compressed record (local 1) one second later: heart rate and power only.
    body += [0x41, 0, 0] + le(20, 2) + [2, 3, 1, 0x02, 7, 2, 0x84]
    body += [0x80 | (1 << 5) | UInt8((start + 1) & 0x1F), 121, 0xFF, 0xFF]
    // Timer stop and start.
    body += [0x42, 0, 0] + le(21, 2) + [3, 253, 4, 0x86, 0, 1, 0x00, 1, 1, 0x00]
    body += [2] + le(start + 2, 4) + [0, 4] + [2] + le(start + 5, 4) + [0, 0]
    // Session: start_time, total_elapsed_time, sport.
    body += [0x43, 0, 0] + le(18, 2) + [3, 2, 4, 0x86, 7, 4, 0x86, 5, 1, 0x00]
    body += [3] + le(start, 4) + le(10_000, 4) + [2]

    let activity = try FITActivity.read(fit(body))
    #expect(activity.records.count == 2)
    #expect(activity.records[0].latitude == -45)
    #expect(activity.records[0].longitude == 90)
    #expect(activity.records[0].power == 250)
    #expect(activity.records[1].date.timeIntervalSince(activity.records[0].date) == 1)
    #expect(activity.records[1].heartRate == 121)
    #expect(activity.records[1].power == nil)
    #expect(activity.timerEvents.map(\.running) == [false, true])
    #expect(activity.sessions.first?.sport == 2)
    #expect(activity.end?.timeIntervalSince(activity.start!) == 10)
}

@Test func fitActivityReadsBundledDemoFiles() throws {
    for id in ["recovery", "endurance", "tempo"] {
        let url = try #require(Bundle.module.url(forResource: "FITgap-Demo-\(id)", withExtension: "fit"))
        let activity = try FITActivity.read(Data(contentsOf: url))
        #expect(!activity.records.isEmpty)
        #expect(activity.records.allSatisfy { ($0.date >= activity.start!) && $0.date <= activity.end!.addingTimeInterval(1) })
    }
}
