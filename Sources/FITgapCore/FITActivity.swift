import Foundation

/// Complete timeline of an activity FIT for export: sessions, laps, swim lengths, timer pauses,
/// and every record sample. Values are only decoded and scaled, never interpolated.
/// Developer fields are skipped because their meaning is not standardized.
/// Field IDs/scales: Garmin FIT Global Profile; framing: Garmin FIT protocol specification.
public struct FITActivity: Sendable {
    public struct Device: Sendable {
        /// FIT `manufacturer` enum value.
        public var manufacturer: Int?
        public var product: Int?
        public var productName: String?
        public var serialNumber: Int?
    }

    public struct Session: Sendable {
        public let start: Date
        public let end: Date
        public let sport: Int?
        public let subSport: Int?
        public let timerSeconds: Double?
        public let distanceMeters: Double?
        public let energyKilocalories: Double?
        public let ascentMeters: Double?
        public let descentMeters: Double?
        public let averageSpeed: Double?
        public let maximumSpeed: Double?
        public let averageHeartRate: Double?
        public let maximumHeartRate: Double?
        public let minimumHeartRate: Double?
        public let averageCadence: Double?
        public let maximumCadence: Double?
        public let averagePower: Double?
        public let maximumPower: Double?
        public let normalizedPower: Double?
        public let thresholdPower: Double?
        public let trainingStressScore: Double?
        public let intensityFactor: Double?
        public let workJoules: Double?
        public let aerobicTrainingEffect: Double?
        public let anaerobicTrainingEffect: Double?
        public let averageTemperature: Double?
        public let maximumTemperature: Double?
        public let poolLengthMeters: Double?
        public let lengthCount: Double?
        /// Strokes for swimming and rowing, strides for running (`total_cycles`).
        public let cycles: Double?
        public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
    }

    public struct Record: Sendable {
        public let date: Date
        public var latitude: Double?
        public var longitude: Double?
        public var altitudeMeters: Double?
        public var heartRate: Double?
        /// Revolutions or strides per minute including `fractional_cadence`.
        public var cadence: Double?
        /// Accumulated distance.
        public var distanceMeters: Double?
        public var speed: Double?
        public var power: Double?
        public var temperature: Double?
        public var verticalOscillationMeters: Double?
        public var groundContactSeconds: Double?
        public var stepLengthMeters: Double?
        public var respirationRate: Double?
        /// Accumulated calories.
        public var energyKilocalories: Double?
    }

    public struct Lap: Sendable {
        public let interval: DateInterval
        public let distanceMeters: Double?
    }

    public struct Length: Sendable {
        public let interval: DateInterval
        public let active: Bool
        public let strokes: Double?
        /// FIT `swim_stroke` enum value.
        public let stroke: Int?
    }

    public struct TimerEvent: Sendable {
        public let date: Date
        public let running: Bool
    }

    public var device = Device()
    public var sessions: [Session] = []
    public var laps: [Lap] = []
    public var lengths: [Length] = []
    public var timerEvents: [TimerEvent] = []
    public var records: [Record] = []
    /// Distinct developer fields defined for records; their values are skipped, only their presence is counted.
    public var developerFields = 0

    public var start: Date? { sessions.map(\.start).min() }
    public var end: Date? { sessions.map(\.end).max() }

    public struct Coordinate: Codable, Sendable, Equatable {
        public let latitude: Double
        public let longitude: Double
        /// Average speed in m/s since the previous returned position; nil for the first one or without elapsed time.
        public var speed: Double?
    }

    /// Recorded positions in order for a map preview, thinned evenly to at most `limit` points;
    /// first and last position are always kept. Virtual worlds (e.g. Zwift) are kept like real GPS.
    public func route(limit: Int = 2000) -> [Coordinate] {
        let all = records.filter { record in
            guard let latitude = record.latitude, let longitude = record.longitude else { return false }
            return latitude != 0 || longitude != 0
        }
        let count = max(limit, 2)
        let picked = all.count > count
            ? (0..<count).map { all[Int((Double($0) * Double(all.count - 1) / Double(count - 1)).rounded())] } : all
        var result: [Coordinate] = []
        for (index, record) in picked.enumerated() {
            var coordinate = Coordinate(latitude: record.latitude!, longitude: record.longitude!)
            if index > 0 {
                let previous = picked[index - 1]
                let seconds = record.date.timeIntervalSince(previous.date)
                // The recorded distance follows the real path; the straight line is only the fallback.
                let meters = record.distanceMeters.flatMap { end in previous.distanceMeters.map { end - $0 } }
                    ?? Self.meters(from: result[index - 1], to: coordinate)
                if seconds > 0, meters >= 0 { coordinate.speed = meters / seconds }
            }
            result.append(coordinate)
        }
        return result
    }

    /// Great-circle distance (haversine, mean earth radius).
    static func meters(from a: Coordinate, to b: Coordinate) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * radians, dLon = (b.longitude - a.longitude) * radians
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * radians) * cos(b.latitude * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6_371_000 * asin(min(1, sqrt(h)))
    }

    public enum ReadError: Error { case invalid }

    public static func read(_ data: Data) throws -> FITActivity {
        var reader = Reader(bytes: Array(data))
        return try reader.read()
    }

    /// FIT timestamps count seconds since 1989-12-31T00:00:00Z.
    static func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value + 631_065_600) }

    private struct Field { let number: UInt8; let size: Int; let type: UInt8 }
    private struct Definition {
        let global: Int; let bigEndian: Bool; let fields: [Field]; let developerSize: Int
    }
    private struct Message {
        var values: [UInt8: Double] = [:]
        var strings: [UInt8: String] = [:]
        func value(_ field: UInt8, scale: Double = 1, offset: Double = 0) -> Double? {
            values[field].map { $0 / scale - offset }
        }
        func date(_ field: UInt8) -> Date? { values[field].map(FITActivity.date) }
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0
        var end = 0
        var definitions: [Int: Definition] = [:]
        var lastTimestamp: UInt32?
        var activity = FITActivity()
        var developerFields = Set<[UInt8]>()

        /// Messages FITgap exports; everything else is skipped by its defined size.
        static let globals: Set<Int> = [0, 18, 19, 20, 21, 101]

        mutating func read() throws -> FITActivity {
            guard bytes.count >= 14, [12, 14].contains(bytes[0]), Array(bytes[8..<12]) == Array(".FIT".utf8) else { throw ReadError.invalid }
            let header = Int(bytes[0])
            let size = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
            guard header + size + 2 == bytes.count else { throw ReadError.invalid }
            position = header; end = header + size
            while position < end {
                if Task.isCancelled { throw CancellationError() }
                let header = try byte()
                let compressed = header & 0x80 != 0
                let local = compressed ? Int((header >> 5) & 3) : Int(header & 15)
                if !compressed, header & 0x40 != 0 {
                    _ = try byte()
                    let architecture = try byte()
                    guard architecture <= 1 else { throw ReadError.invalid }
                    let bigEndian = architecture == 1
                    let global = try raw(size: 2, bigEndian: bigEndian)
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
                            let number = try byte(); developerSize += Int(try byte()); let index = try byte()
                            if global == 20 { developerFields.insert([index, number]) }
                        }
                    }
                    definitions[local] = Definition(global: Int(global), bigEndian: bigEndian, fields: fields, developerSize: developerSize)
                } else {
                    guard let definition = definitions[local] else { throw ReadError.invalid }
                    var message = Message()
                    if compressed {
                        // Compressed headers carry a 5-bit offset to the last full timestamp.
                        guard let last = lastTimestamp else { throw ReadError.invalid }
                        let offset = UInt32(header & 0x1F)
                        var timestamp = (last & ~0x1F) + offset
                        if offset < last & 0x1F { timestamp += 0x20 }
                        lastTimestamp = timestamp
                        message.values[253] = Double(timestamp)
                    }
                    let wanted = Self.globals.contains(definition.global)
                    for field in definition.fields {
                        if compressed && field.number == 253 { try skip(field.size); continue }
                        guard wanted else { try skip(field.size); continue }
                        try decode(field, bigEndian: definition.bigEndian, into: &message)
                    }
                    try skip(definition.developerSize)
                    if !compressed, let timestamp = message.values[253] { lastTimestamp = UInt32(timestamp) }
                    if wanted { collect(definition.global, message) }
                }
            }
            guard !activity.sessions.isEmpty else { throw ReadError.invalid }
            activity.developerFields = developerFields.count
            activity.sessions.sort { $0.start < $1.start }
            activity.records.sort { $0.date < $1.date }
            activity.laps.sort { $0.interval.start < $1.interval.start }
            activity.lengths.sort { $0.interval.start < $1.interval.start }
            activity.timerEvents.sort { $0.date < $1.date }
            return activity
        }

        private mutating func collect(_ global: Int, _ m: Message) {
            switch global {
            case 0:
                activity.device = Device(manufacturer: m.value(1).map(Int.init), product: m.value(2).map(Int.init),
                                         productName: m.strings[8], serialNumber: m.value(3).map(Int.init))
            case 18:
                guard let start = m.date(2) else { return }
                let elapsed = m.value(7, scale: 1000)
                let end = elapsed.map { start.addingTimeInterval($0) } ?? m.date(253) ?? start
                activity.sessions.append(Session(
                    start: start, end: end, sport: m.value(5).map(Int.init), subSport: m.value(6).map(Int.init),
                    timerSeconds: m.value(8, scale: 1000), distanceMeters: m.value(9, scale: 100),
                    energyKilocalories: m.value(11), ascentMeters: m.value(22), descentMeters: m.value(23),
                    averageSpeed: m.value(124, scale: 1000) ?? m.value(14, scale: 1000),
                    maximumSpeed: m.value(125, scale: 1000) ?? m.value(15, scale: 1000),
                    averageHeartRate: m.value(16), maximumHeartRate: m.value(17), minimumHeartRate: m.value(64),
                    averageCadence: m.value(18).map { $0 + (m.value(92, scale: 128) ?? 0) },
                    maximumCadence: m.value(19).map { $0 + (m.value(93, scale: 128) ?? 0) },
                    averagePower: m.value(20), maximumPower: m.value(21), normalizedPower: m.value(34),
                    thresholdPower: m.value(45), trainingStressScore: m.value(35, scale: 10),
                    intensityFactor: m.value(36, scale: 1000), workJoules: m.value(48),
                    aerobicTrainingEffect: m.value(24, scale: 10), anaerobicTrainingEffect: m.value(137, scale: 10),
                    averageTemperature: m.value(57), maximumTemperature: m.value(58),
                    poolLengthMeters: m.value(44, scale: 100), lengthCount: m.value(33), cycles: m.value(10)))
            case 19:
                guard let start = m.date(2) else { return }
                let end = m.value(7, scale: 1000).map { start.addingTimeInterval($0) } ?? m.date(253) ?? start
                guard end > start else { return }
                activity.laps.append(Lap(interval: DateInterval(start: start, end: end), distanceMeters: m.value(9, scale: 100)))
            case 20:
                guard let date = m.date(253) else { return }
                let semicircle = 180 / 2_147_483_648.0
                let latitude = m.value(0).map { $0 * semicircle }, longitude = m.value(1).map { $0 * semicircle }
                var record = Record(date: date)
                if let latitude, let longitude, abs(latitude) <= 90, abs(longitude) <= 180 {
                    record.latitude = latitude; record.longitude = longitude
                }
                record.altitudeMeters = m.value(78, scale: 5, offset: 500) ?? m.value(2, scale: 5, offset: 500)
                record.heartRate = m.value(3)
                record.cadence = m.value(4).map { $0 + (m.value(53, scale: 128) ?? 0) }
                record.distanceMeters = m.value(5, scale: 100)
                record.speed = m.value(73, scale: 1000) ?? m.value(6, scale: 1000)
                record.power = m.value(7)
                record.temperature = m.value(13)
                record.verticalOscillationMeters = m.value(39, scale: 10_000)
                record.groundContactSeconds = m.value(41, scale: 10_000)
                record.stepLengthMeters = m.value(85, scale: 10_000)
                record.respirationRate = m.value(108, scale: 100)
                record.energyKilocalories = m.value(33)
                activity.records.append(record)
            case 21:
                // Timer events: start resumes recording; stop, stop_all and stop_disable_all pause it.
                guard let date = m.date(253), m.value(0) == 0, let type = m.value(1).map(Int.init) else { return }
                if type == 0 { activity.timerEvents.append(TimerEvent(date: date, running: true)) }
                else if [1, 4, 9].contains(type) { activity.timerEvents.append(TimerEvent(date: date, running: false)) }
            case 101:
                guard let start = m.date(2), let elapsed = m.value(3, scale: 1000), elapsed > 0 else { return }
                activity.lengths.append(Length(interval: DateInterval(start: start, duration: elapsed),
                    active: m.value(12) != 0, strokes: m.value(5), stroke: m.value(7).map(Int.init)))
            default: break
            }
        }

        /// Decodes one field by its base type; invalid markers become missing values.
        private mutating func decode(_ field: Field, bigEndian: Bool, into message: inout Message) throws {
            let base = field.type & 31
            if base == 7 {
                let start = position
                try skip(field.size)
                let text = bytes[start..<position].prefix { $0 != 0 }
                if !text.isEmpty, let string = String(bytes: text, encoding: .utf8) { message.strings[field.number] = string }
                return
            }
            let width: Int
            switch base {
            case 0, 1, 2, 10, 13: width = 1
            case 3, 4, 11: width = 2
            case 5, 6, 8, 12: width = 4
            case 9, 14, 15, 16: width = 8
            default: try skip(field.size); return
            }
            // Arrays are not needed by any exported field.
            guard field.size == width else { try skip(field.size); return }
            if let value = Self.number(try raw(size: width, bigEndian: bigEndian), base: base, width: width) {
                message.values[field.number] = value
            }
        }

        private static func number(_ raw: UInt64, base: UInt8, width: Int) -> Double? {
            let all = width == 8 ? UInt64.max : (UInt64(1) << (8 * width)) - 1
            switch base {
            case 1, 3, 5, 14:
                let signBit = UInt64(1) << (8 * width - 1)
                guard raw != signBit - 1 else { return nil }
                return raw & signBit != 0 ? -Double((~raw & all) + 1) : Double(raw)
            case 8:
                let value = Float(bitPattern: UInt32(raw))
                return raw == all || !value.isFinite ? nil : Double(value)
            case 9:
                let value = Double(bitPattern: raw)
                return raw == all || !value.isFinite ? nil : value
            case 10, 11, 12, 16:
                return raw == 0 ? nil : Double(raw)
            default:
                return raw == all ? nil : Double(raw)
            }
        }

        mutating func byte() throws -> UInt8 {
            guard position < end else { throw ReadError.invalid }
            defer { position += 1 }
            return bytes[position]
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= end - position else { throw ReadError.invalid }
            position += count
        }
        mutating func raw(size: Int, bigEndian: Bool) throws -> UInt64 {
            var result: UInt64 = 0
            for index in 0..<size {
                let shift = (bigEndian ? size - index - 1 : index) * 8
                result |= UInt64(try byte()) << shift
            }
            return result
        }
    }
}
