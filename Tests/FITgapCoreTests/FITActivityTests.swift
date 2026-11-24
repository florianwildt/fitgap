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

@Test func routeSkipsMissingPositionsAndThinsEvenly() {
    var activity = FITActivity()
    let start = Date(timeIntervalSince1970: 0)
    activity.records = (0..<101).map {
        FITActivity.Record(date: start.addingTimeInterval(Double($0)), latitude: $0 == 50 ? nil : Double($0) / 1000,
                           longitude: 1)
    }
    activity.records.append(FITActivity.Record(date: start.addingTimeInterval(200), latitude: 0, longitude: 0))
    #expect(activity.route().count == 100)
    let thinned = activity.route(limit: 10)
    #expect(thinned.count == 10)
    #expect(thinned.first?.latitude == 0)
    #expect(thinned.last?.latitude == 0.1)
    #expect(thinned.first?.speed == nil)
    // Without recorded distance the speed follows the straight line: 0.011° latitude in 11 s ≈ 111 m/s.
    #expect(abs((thinned[1].speed ?? 0) - 111.2) < 0.5)
}

@Test func fitWriterRoundTripsThroughTheReaders() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var export = FITExport(start: start, end: start.addingTimeInterval(600), sport: 2, subSport: 0)
    export.timerSeconds = 540
    export.distanceMeters = 5_000
    export.energyKilocalories = 150
    export.ascentMeters = 42
    export.averageHeartRate = 141; export.maximumHeartRate = 172
    export.averagePower = 210; export.maximumPower = 480
    export.averageSpeed = 9.26
    export.productName = "Fahrrad-App ü"
    export.pauses = [DateInterval(start: start.addingTimeInterval(300), duration: 60)]
    export.laps = [DateInterval(start: start, duration: 300), DateInterval(start: start.addingTimeInterval(300), duration: 300)]
    export.records = (0...600).map { second in
        var record = FITActivity.Record(at: start.addingTimeInterval(Double(second)))
        record.latitude = 50 + Double(second) / 100_000; record.longitude = -8.5
        record.altitudeMeters = 100 + Double(second) / 10
        record.heartRate = second % 2 == 0 ? 140 : nil
        record.power = 200; record.cadence = 90
        record.distanceMeters = Double(second) * 8.3
        record.speed = 8.3
        return record
    }
    let data = FITWriter.encode(export)
    #expect(OriginalFITStore.isComplete(data))
    // The CRC over the whole file including its trailing CRC is zero.
    #expect(FITWriter.crc(Array(data)) == 0)

    let activity = try FITActivity.read(data)
    #expect(activity.records.count == 601)
    #expect(abs(activity.records[10].latitude! - 50.0001) < 0.000_001)
    #expect(activity.records[1].heartRate == nil && activity.records[2].heartRate == 140)
    #expect(abs(activity.records[600].altitudeMeters! - 160) < 0.2)
    #expect(activity.laps.count == 2)
    #expect(activity.timerEvents.map(\.running) == [true, false, true, false])
    #expect(activity.device.productName == "Fahrrad-App ü")

    let metrics = try #require(FITMetrics.read(data))
    #expect(metrics.sport == 2 && metrics.timerSeconds == 540 && metrics.elapsedSeconds == 600)
    #expect(metrics.distanceMeters == 5_000 && metrics.ascentMeters == 42 && metrics.averagePowerWatts == 210)
    #expect(metrics.averageSpeedMetersPerSecond == 9.26 && metrics.maximumAltitudeMeters == 160)
}
