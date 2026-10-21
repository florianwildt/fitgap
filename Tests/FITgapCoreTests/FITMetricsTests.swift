import Foundation
import Testing
@testable import FITgapCore

private func uint(_ value: UInt32, _ size: Int, big: Bool = false) -> [UInt8] {
    (0..<size).map { UInt8(truncatingIfNeeded: value >> ((big ? size - $0 - 1 : $0) * 8)) }
}
private func fit(_ body: [UInt8], headerSize: Int = 14) -> Data {
    Data([UInt8(headerSize), 0x20, 0, 0] + uint(UInt32(body.count), 4) + Array(".FIT".utf8)
         + (headerSize == 14 ? [0, 0] : []) + body + [0, 0])
}
private func session(big: Bool = false, local: UInt8 = 0, enhanced: UInt32 = 6578,
                     distance: UInt32 = 3338275, ascent: UInt32 = 440, timer: UInt32 = 5075000) -> [UInt8] {
    [0x40 | local, 0, big ? 1 : 0] + uint(18, 2, big: big) + [5, 9, 4, 0x86, 22, 2, 0x84, 14, 2, 0x84, 124, 4, 0x86, 8, 4, 0x86]
    + [local] + uint(distance, 4, big: big) + uint(ascent, 2, big: big) + uint(6000, 2, big: big)
    + uint(enhanced, 4, big: big) + uint(timer, 4, big: big)
}

@Test(arguments: [false, true])
func fitSessionMetricsUseDocumentedScalesAndEnhancedSpeed(_ big: Bool) {
    let result = FITMetrics.read(fit(session(big: big), headerSize: big ? 12 : 14))
    #expect(result?.distanceMeters == 33382.75)
    #expect(result?.ascentMeters == 440)
    #expect(result?.averageSpeedMetersPerSecond == 6.578)
}

/// Session with every additional summary field, encoded as in the Garmin FIT Global Profile.
private func detailedSession(big: Bool = false, timer: UInt32 = 5075000, heartRate: UInt8 = 140,
                             power: UInt32 = 150, sport: UInt8 = 2) -> [UInt8] {
    let fields: [(UInt8, UInt8, UInt8, UInt32)] = [
        (5, 1, 0x00, UInt32(sport)), (6, 1, 0x00, 0), (7, 4, 0x86, timer + 10000), (8, 4, 0x86, timer),
        (9, 4, 0x86, 3338275), (11, 2, 0x84, 762), (14, 2, 0x84, 6578), (15, 2, 0x84, 18786),
        (16, 1, 0x02, UInt32(heartRate)), (17, 1, 0x02, 185), (18, 1, 0x02, 77), (19, 1, 0x02, 119),
        (20, 2, 0x84, power), (21, 2, 0x84, 763), (22, 2, 0x84, 440), (23, 2, 0x84, 441),
        (127, 4, 0x86, (532 + 500) * 5), (128, 4, 0x86, (788 + 500) * 5)
    ]
    return [0x40, 0, big ? 1 : 0] + uint(18, 2, big: big) + [UInt8(fields.count)] + fields.flatMap { [$0.0, $0.1, $0.2] }
        + [0] + fields.flatMap { uint($0.3, Int($0.1), big: big) }
}

@Test(arguments: [false, true])
func fitSessionDetailsUseGlobalProfileFieldsAndScales(_ big: Bool) {
    let result = FITMetrics.read(fit(detailedSession(big: big), headerSize: big ? 12 : 14))
    #expect(result == ActivityMetrics(distanceMeters: 33382.75, ascentMeters: 440, averageSpeedMetersPerSecond: 6.578,
        descentMeters: 441, timerSeconds: 5075, elapsedSeconds: 5085, maximumSpeedMetersPerSecond: 18.786,
        energyKilocalories: 762, averageHeartRate: 140, maximumHeartRate: 185, averageCadence: 77, maximumCadence: 119,
        averagePowerWatts: 150, maximumPowerWatts: 763, minimumAltitudeMeters: 532, maximumAltitudeMeters: 788,
        sport: 2, subSport: 0))
}

@Test func fitSessionDetailsCombineSessionsWithoutFabricatingValues() {
    // Averages weighted by timer time; maxima across sessions; sport only when all sessions agree.
    let combined = FITMetrics.read(fit(detailedSession(timer: 1000000, heartRate: 100, power: 100)
        + detailedSession(timer: 3000000, heartRate: 140, power: 200, sport: 1)))
    #expect(combined?.averageHeartRate == 130)
    #expect(combined?.averagePowerWatts == 175)
    #expect(combined?.maximumPowerWatts == 763)
    #expect(combined?.energyKilocalories == 1524)
    #expect(combined?.sport == nil)
    // Invalid uint8 and enum values stay missing; a wrongly typed field is skipped, not misread.
    let invalid: [UInt8] = [0x40, 0, 0, 18, 0, 3, 16, 1, 0x02, 5, 1, 0x00, 21, 1, 0x02, 0, 0xff, 0xff, 7]
    #expect(FITMetrics.read(fit(invalid)) == ActivityMetrics())
    // Lap messages (global 19) use other field numbers and are never read as session totals.
    #expect(FITMetrics.read(fit([0x40, 0, 0, 19, 0, 1, 9, 4, 0x86, 0] + uint(100, 4))) == nil)
}

@Test func olderCachedMetricsAreReadAgainOnce() throws {
    var record = ActivityRecord(source: .wahoo, remoteID: "1", name: "", date: nil, duration: nil, status: .available)
    record.metrics = try JSONDecoder().decode(ActivityMetrics.self, from: Data(#"{"distanceMeters":1000}"#.utf8))
    #expect(record.metrics?.distanceMeters == 1000 && record.needsMetrics)
    record.metrics = ActivityMetrics()
    #expect(!record.needsMetrics)
    record.status = .deleted; record.metrics = nil
    #expect(!record.needsMetrics)
}

@Test func fitMetricsSkipDeveloperFieldsCompressedTimestampsAndRedefinedMessages() {
    // Definition 0: record with timestamp/HR plus two developer bytes, then compressed record.
    let record: [UInt8] = [0x60, 0, 0, 20, 0, 2, 253, 4, 0x86, 3, 1, 2, 1, 99, 2, 0]
    let body = record + [0] + uint(100, 4) + [140, 10, 20] + [0x85, 141, 11, 21] + session()
    #expect(FITMetrics.read(fit(body))?.distanceMeters == 33382.75)
    // A compressed message can also reference a definition without an explicit timestamp.
    #expect(FITMetrics.read(fit([0x40, 0, 0, 20, 0, 1, 3, 1, 2, 0x81, 141] + session()))?.ascentMeters == 440)
    // The fast path must still reject truncated payloads and malformed compressed timestamp fields.
    #expect(FITMetrics.read(fit([0x40, 0, 0, 20, 0, 1, 3, 4, 0x86, 0, 1])) == nil)
    #expect(FITMetrics.read(fit([0x40, 0, 0, 20, 0, 1, 253, 2, 0x84, 0x80, 1, 2] + session())) == nil)
}

@Test func fitMetricsDoNotFabricateMissingValuesAndAverageSessionsByTimer() {
    // Invalid enhanced speed falls back to legacy avg_speed.
    #expect(FITMetrics.read(fit(session(enhanced: .max)))?.averageSpeedMetersPerSecond == 6)
    // Zero distance/ascent/speed are real values, not missing.
    let zero = FITMetrics.read(fit(session(enhanced: 0, distance: 0, ascent: 0, timer: 0)))
    #expect(zero?.distanceMeters == 0 && zero?.ascentMeters == 0 && zero?.averageSpeedMetersPerSecond == 0)
    let combined = FITMetrics.read(fit(session(distance: 100000, ascent: 10, timer: 100000)
        + session(distance: 100000, ascent: 20, timer: 300000)))
    #expect(combined?.distanceMeters == 2000)
    #expect(combined?.ascentMeters == 30)
    #expect(combined?.averageSpeedMetersPerSecond == 5)
    let missing = fit([0x40, 0, 0, 18, 0, 2, 9, 4, 0x86, 22, 2, 0x84, 0] + [UInt8](repeating: 255, count: 6))
    #expect(FITMetrics.read(missing) == ActivityMetrics())
}

@Test func fitMetricsRejectTruncatedDefinitionsAndPayloadsWithoutChangingBytes() {
    let complete = fit(session())
    let original = complete
    for count in 0..<complete.count { #expect(FITMetrics.read(Data(complete.prefix(count))) == nil) }
    #expect(FITMetrics.read(fit([0x40, 0, 0, 18, 0, 1, 9])) == nil)
    #expect(FITMetrics.read(fit([0x40, 0, 0, 18, 0, 1, 9, 4, 0x86, 0, 1])) == nil)
    #expect(complete == original)
}

@Test func legacyIndexGainsOfflineMetricsAndPreservesSharingAndOriginalFIT() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = ActivityLibrary(directory: directory)
    var record = ActivityRecord(source: .wahoo, remoteID: "1", name: "Synthetic", date: nil, duration: 5586)
    let data = fit(session())
    record.receipt = try library.files.save(data, key: record.key)
    record.status = .available; record.sharedAt = Date(timeIntervalSince1970: 1000)
    try library.save([record])
    // A missing optional metrics key matches every existing version-1 index.
    let index = directory.appendingPathComponent("activities.json")
    #expect(!String(data: try Data(contentsOf: index), encoding: .utf8)!.contains("metrics"))
    var restored = try library.load()[0]
    #expect(restored.metrics == nil)
    restored.metrics = try library.metrics(for: restored)
    try library.save([restored])
    let merged = ActivityLibrary.merging([record], into: try library.load())[0]
    #expect(merged.metrics?.distanceMeters == 33382.75)
    #expect(merged.sharedAt == record.sharedAt)
    #expect(merged.receipt?.sha256 == record.receipt?.sha256)
    #expect(try Data(contentsOf: library.verifiedFile(for: merged)) == data)
}
