import Foundation

public struct ActivityMetrics: Codable, Sendable, Equatable {
    /// Increased when new session fields are read; older caches are read again once from the original FIT.
    public static let currentRevision = 2
    public let revision: Int?
    public let distanceMeters: Double?
    public let ascentMeters: Double?
    public let averageSpeedMetersPerSecond: Double?
    public let descentMeters: Double?
    public let timerSeconds: Double?
    public let elapsedSeconds: Double?
    public let maximumSpeedMetersPerSecond: Double?
    public let energyKilocalories: Double?
    public let averageHeartRate: Double?
    public let maximumHeartRate: Double?
    public let averageCadence: Double?
    public let maximumCadence: Double?
    public let averagePowerWatts: Double?
    public let maximumPowerWatts: Double?
    public let minimumAltitudeMeters: Double?
    public let maximumAltitudeMeters: Double?
    /// FIT `sport` and `sub_sport` enum values.
    public let sport: Int?
    public let subSport: Int?

    public init(distanceMeters: Double? = nil, ascentMeters: Double? = nil, averageSpeedMetersPerSecond: Double? = nil,
                descentMeters: Double? = nil, timerSeconds: Double? = nil, elapsedSeconds: Double? = nil,
                maximumSpeedMetersPerSecond: Double? = nil, energyKilocalories: Double? = nil,
                averageHeartRate: Double? = nil, maximumHeartRate: Double? = nil,
                averageCadence: Double? = nil, maximumCadence: Double? = nil,
                averagePowerWatts: Double? = nil, maximumPowerWatts: Double? = nil,
                minimumAltitudeMeters: Double? = nil, maximumAltitudeMeters: Double? = nil,
                sport: Int? = nil, subSport: Int? = nil) {
        revision = Self.currentRevision
        self.distanceMeters = distanceMeters; self.ascentMeters = ascentMeters
        self.averageSpeedMetersPerSecond = averageSpeedMetersPerSecond
        self.descentMeters = descentMeters; self.timerSeconds = timerSeconds; self.elapsedSeconds = elapsedSeconds
        self.maximumSpeedMetersPerSecond = maximumSpeedMetersPerSecond; self.energyKilocalories = energyKilocalories
        self.averageHeartRate = averageHeartRate; self.maximumHeartRate = maximumHeartRate
        self.averageCadence = averageCadence; self.maximumCadence = maximumCadence
        self.averagePowerWatts = averagePowerWatts; self.maximumPowerWatts = maximumPowerWatts
        self.minimumAltitudeMeters = minimumAltitudeMeters; self.maximumAltitudeMeters = maximumAltitudeMeters
        self.sport = sport; self.subSport = subSport
    }

    public var isCurrent: Bool { revision == Self.currentRevision }
}

/// Reads only native session (global 18) summaries. No re-encoding, record interpolation or developer-field interpretation.
/// Field IDs/scales: Garmin FIT Global Profile; framing: Garmin FIT protocol specification.
public enum FITMetrics {
    public static func read(_ data: Data) -> ActivityMetrics? {
        var reader = Reader(bytes: Array(data))
        return try? reader.read()
    }

    private struct Field { let number: UInt8; let size: Int; let type: UInt8 }
    private struct Definition {
        let global: Int; let bigEndian: Bool; let fields: [Field]; let developerSize: Int
        let payloadSize: Int; let compressedPayloadSize: Int?
    }
    /// Session (global 18) fields with their exact size and base type; any other encoding is skipped.
    private static let sessionFields: [UInt8: (size: Int, type: UInt8)] = [
        5: (1, 0), 6: (1, 0), 7: (4, 6), 8: (4, 6), 9: (4, 6), 11: (2, 4), 14: (2, 4), 15: (2, 4),
        16: (1, 2), 17: (1, 2), 18: (1, 2), 19: (1, 2), 20: (2, 4), 21: (2, 4), 22: (2, 4), 23: (2, 4),
        50: (2, 4), 71: (2, 4), 124: (4, 6), 125: (4, 6), 127: (4, 6), 128: (4, 6)
    ]
    private struct Session {
        let values: [UInt8: Double]
        func value(_ field: UInt8, scale: Double = 1, offset: Double = 0) -> Double? {
            values[field].map { $0 / scale - offset }
        }
        var distance: Double? { value(9, scale: 100) }
        var ascent: Double? { value(22) }
        var descent: Double? { value(23) }
        var speed: Double? { value(124, scale: 1000) ?? value(14, scale: 1000) }
        var maxSpeed: Double? { value(125, scale: 1000) ?? value(15, scale: 1000) }
        var timer: Double? { value(8, scale: 1000) }
        var elapsed: Double? { value(7, scale: 1000) }
        var minAltitude: Double? { value(127, scale: 5, offset: 500) ?? value(71, scale: 5, offset: 500) }
        var maxAltitude: Double? { value(128, scale: 5, offset: 500) ?? value(50, scale: 5, offset: 500) }
    }
    private enum Invalid: Error { case file }
    private struct Reader {
        let bytes: [UInt8]
        var position = 0
        var end = 0
        var definitions: [Int: Definition] = [:]
        var sessions: [Session] = []

        mutating func read() throws -> ActivityMetrics {
            guard bytes.count >= 14, [12, 14].contains(bytes[0]), Array(bytes[8..<12]) == Array(".FIT".utf8) else { throw Invalid.file }
            let header = Int(bytes[0])
            let size = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
            guard header + size + 2 == bytes.count else { throw Invalid.file }
            position = header; end = header + size
            while position < end {
                if Task.isCancelled { throw CancellationError() }
                let header = try byte()
                let compressed = header & 0x80 != 0
                let local = compressed ? Int((header >> 5) & 3) : Int(header & 15)
                if !compressed, header & 0x40 != 0 {
                    _ = try byte()
                    let architecture = try byte()
                    guard architecture <= 1 else { throw Invalid.file }
                    let bigEndian = architecture == 1
                    let global = try unsigned(size: 2, bigEndian: bigEndian)
                    let count = try byte()
                    var fields: [Field] = []
                    for _ in 0..<Int(count) {
                        let number = try byte(), size = try byte(), type = try byte()
                        fields.append(Field(number: number, size: Int(size), type: type))
                    }
                    var developerSize = 0
                    if header & 0x20 != 0 {
                        let count = try byte()
                        for _ in 0..<Int(count) {
                            _ = try byte(); developerSize += Int(try byte()); _ = try byte()
                        }
                    }
                    let payloadSize = fields.reduce(developerSize) { $0 + $1.size }
                    let timestamp = fields.first { $0.number == 253 }
                    let compressedSize: Int?
                    if let timestamp {
                        compressedSize = timestamp.size == 4 && timestamp.type & 31 == 6 ? payloadSize - 4 : nil
                    } else { compressedSize = payloadSize }
                    definitions[local] = Definition(global: Int(global), bigEndian: bigEndian, fields: fields,
                        developerSize: developerSize, payloadSize: payloadSize, compressedPayloadSize: compressedSize)
                } else {
                    guard let definition = definitions[local] else { throw Invalid.file }
                    // Thousands of measurement records contain no session totals. Skip their
                    // already defined payload in one step, including developer fields.
                    if definition.global != 18 {
                        guard let size = compressed ? definition.compressedPayloadSize : definition.payloadSize else { throw Invalid.file }
                        try skip(size)
                        continue
                    }
                    var values: [UInt8: Double] = [:]
                    for field in definition.fields {
                        if compressed && field.number == 253 {
                            guard field.size == 4, field.type & 31 == 6 else { throw Invalid.file }
                            continue
                        }
                        if let expected = FITMetrics.sessionFields[field.number],
                           field.size == expected.size, field.type & 31 == expected.type {
                            let value = try unsigned(size: field.size, bigEndian: definition.bigEndian)
                            let invalid = UInt32.max >> (32 - 8 * field.size)
                            if value != invalid { values[field.number] = Double(value) }
                        } else { try skip(field.size) }
                    }
                    try skip(definition.developerSize)
                    sessions.append(Session(values: values))
                }
            }
            guard !sessions.isEmpty else { throw Invalid.file }
            func sum(_ value: (Session) -> Double?) -> Double? {
                let values = sessions.compactMap(value)
                return values.count == sessions.count ? values.reduce(0, +) : nil
            }
            func maximum(_ value: (Session) -> Double?) -> Double? { sessions.compactMap(value).max() }
            func minimum(_ value: (Session) -> Double?) -> Double? { sessions.compactMap(value).min() }
            let distance = sum(\.distance), timer = sum(\.timer)
            // Several sessions are weighted by timer time; every session must provide value and timer.
            func average(_ field: UInt8) -> Double? {
                if sessions.count == 1 { return sessions[0].value(field) }
                guard let timer, timer > 0,
                      let weighted = sum({ session in session.value(field).flatMap { v in session.timer.map { v * $0 } } })
                else { return nil }
                return weighted / timer
            }
            // Sport is only reported when all sessions agree, e.g. not for multisport files.
            func shared(_ field: UInt8) -> Int? {
                let values = Set(sessions.map { $0.value(field) })
                guard values.count == 1, let value = values.first ?? nil else { return nil }
                return Int(value)
            }
            let derivedSpeed = distance.flatMap { distance in timer.flatMap { $0 > 0 ? distance / $0 : nil } }
            return ActivityMetrics(distanceMeters: distance, ascentMeters: sum(\.ascent),
                averageSpeedMetersPerSecond: sessions.count == 1 ? sessions[0].speed ?? derivedSpeed : derivedSpeed,
                descentMeters: sum(\.descent), timerSeconds: timer, elapsedSeconds: sum(\.elapsed),
                maximumSpeedMetersPerSecond: maximum(\.maxSpeed), energyKilocalories: sum { $0.value(11) },
                averageHeartRate: average(16), maximumHeartRate: maximum { $0.value(17) },
                averageCadence: average(18), maximumCadence: maximum { $0.value(19) },
                averagePowerWatts: average(20), maximumPowerWatts: maximum { $0.value(21) },
                minimumAltitudeMeters: minimum(\.minAltitude), maximumAltitudeMeters: maximum(\.maxAltitude),
                sport: shared(5), subSport: shared(6))
        }

        mutating func byte() throws -> UInt8 {
            guard position < end else { throw Invalid.file }
            defer { position += 1 }
            return bytes[position]
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= end - position else { throw Invalid.file }
            position += count
        }
        mutating func unsigned(size: Int, bigEndian: Bool) throws -> UInt32 {
            var result: UInt32 = 0
            for index in 0..<size {
                let shift = (bigEndian ? size - index - 1 : index) * 8
                result |= UInt32(try byte()) << shift
            }
            return result
        }
    }
}
