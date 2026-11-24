import Foundation

/// An activity to encode as FIT, e.g. from an Apple Health workout. Values stay as measured; nothing is interpolated.
public struct FITExport: Sendable {
    public var start: Date
    public var end: Date
    /// FIT `sport` and `sub_sport` enum values (Garmin FIT Global Profile).
    public var sport: Int
    public var subSport: Int
    public var timerSeconds: Double?
    public var distanceMeters: Double?
    public var energyKilocalories: Double?
    public var ascentMeters: Double?
    public var averageHeartRate: Double?
    public var maximumHeartRate: Double?
    public var averageCadence: Double?
    public var maximumCadence: Double?
    public var averagePower: Double?
    public var maximumPower: Double?
    public var averageSpeed: Double?
    public var maximumSpeed: Double?
    /// Strokes for swimming, strides for running.
    public var cycles: Double?
    public var poolLengthMeters: Double?
    /// Name of the app or device that recorded the workout, kept as `product_name`.
    public var productName: String?
    public var records: [FITActivity.Record] = []
    public var laps: [DateInterval] = []
    public var pauses: [DateInterval] = []

    public init(start: Date, end: Date, sport: Int, subSport: Int = 0) {
        self.start = start; self.end = max(start, end); self.sport = sport; self.subSport = subSport
    }
}

/// Encodes an activity FIT (little endian) with file_id, timer events, records, laps, one session and the activity.
/// Field IDs, types and scales: Garmin FIT Global Profile; framing and CRC: Garmin FIT protocol specification.
public enum FITWriter {
    public static func encode(_ export: FITExport) -> Data {
        var body = Body()
        let start = export.start, end = export.end
        let elapsed = end.timeIntervalSince(start)
        let timer = export.timerSeconds ?? elapsed - export.pauses.reduce(0) { $0 + $1.duration }

        // file_id: type activity, manufacturer development, time_created, product_name.
        body.define(local: 0, global: 0, [(0, 1, .enumeration), (1, 2, .uint16), (2, 2, .uint16), (4, 4, .uint32), (8, 32, .string)])
        body.message(local: 0, [.int(4), .int(255), .int(0), .date(start), .text(export.productName ?? "FITgap", 32)])

        // event: timer start, stop_all at each pause, start after it, stop_all at the end.
        body.define(local: 1, global: 21, [(253, 4, .uint32), (0, 1, .enumeration), (1, 1, .enumeration)])
        body.message(local: 1, [.date(start), .int(0), .int(0)])
        for pause in export.pauses.sorted(by: { $0.start < $1.start }) where pause.start > start && pause.end < end {
            body.message(local: 1, [.date(pause.start), .int(0), .int(4)])
            body.message(local: 1, [.date(pause.end), .int(0), .int(0)])
        }

        body.define(local: 2, global: 20, [(253, 4, .uint32), (0, 4, .sint32), (1, 4, .sint32), (2, 2, .uint16), (3, 1, .uint8),
                                           (4, 1, .uint8), (5, 4, .uint32), (6, 2, .uint16), (7, 2, .uint16), (108, 2, .uint16)])
        let semicircles = 2_147_483_648.0 / 180
        for record in export.records.sorted(by: { $0.date < $1.date }) where record.date >= start && record.date <= end {
            body.message(local: 2, [
                .date(record.date),
                .value(record.latitude.map { $0 * semicircles }), .value(record.longitude.map { $0 * semicircles }),
                .value(record.altitudeMeters.map { ($0 + 500) * 5 }), .value(record.heartRate), .value(record.cadence),
                .value(record.distanceMeters.map { $0 * 100 }), .value(record.speed.map { $0 * 1000 }), .value(record.power),
                .value(record.respirationRate.map { $0 * 100 })
            ])
        }

        // lap: the recorded laps, or the whole activity as one lap.
        let laps = export.laps.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        let lapIntervals = laps.isEmpty ? [DateInterval(start: start, end: end)] : laps
        body.define(local: 3, global: 19, [(253, 4, .uint32), (2, 4, .uint32), (7, 4, .uint32), (8, 4, .uint32), (9, 4, .uint32),
                                           (0, 1, .enumeration), (1, 1, .enumeration)])
        for lap in lapIntervals {
            let paused = export.pauses.reduce(0.0) { $0 + ($1.intersection(with: lap)?.duration ?? 0) }
            body.message(local: 3, [.date(lap.end), .date(lap.start), .value(lap.duration * 1000), .value((lap.duration - paused) * 1000),
                                    .value(distance(in: lap, export.records).map { $0 * 100 }), .int(9), .int(1)])
        }

        let altitudes = export.records.compactMap(\.altitudeMeters)
        body.define(local: 4, global: 18, [
            (253, 4, .uint32), (2, 4, .uint32), (7, 4, .uint32), (8, 4, .uint32), (9, 4, .uint32), (5, 1, .enumeration), (6, 1, .enumeration),
            (11, 2, .uint16), (22, 2, .uint16), (16, 1, .uint8), (17, 1, .uint8), (18, 1, .uint8), (19, 1, .uint8),
            (20, 2, .uint16), (21, 2, .uint16), (14, 2, .uint16), (15, 2, .uint16), (10, 4, .uint32), (44, 2, .uint16),
            (50, 2, .uint16), (71, 2, .uint16), (25, 2, .uint16), (26, 2, .uint16), (0, 1, .enumeration), (1, 1, .enumeration)
        ])
        body.message(local: 4, [
            .date(end), .date(start), .value(elapsed * 1000), .value(timer * 1000), .value(export.distanceMeters.map { $0 * 100 }),
            .int(export.sport), .int(export.subSport), .value(export.energyKilocalories), .value(export.ascentMeters),
            .value(export.averageHeartRate), .value(export.maximumHeartRate), .value(export.averageCadence), .value(export.maximumCadence),
            .value(export.averagePower), .value(export.maximumPower),
            .value(export.averageSpeed.map { $0 * 1000 }), .value(export.maximumSpeed.map { $0 * 1000 }),
            .value(export.cycles), .value(export.poolLengthMeters.map { $0 * 100 }),
            .value(altitudes.max().map { ($0 + 500) * 5 }), .value(altitudes.min().map { ($0 + 500) * 5 }),
            .int(0), .int(lapIntervals.count), .int(8), .int(1)
        ])

        // timer stop at the end, then the activity with its local time.
        body.message(local: 1, [.date(end), .int(0), .int(4)])
        body.define(local: 5, global: 34, [(253, 4, .uint32), (0, 4, .uint32), (1, 2, .uint16), (2, 1, .enumeration),
                                           (3, 1, .enumeration), (4, 1, .enumeration), (5, 4, .uint32)])
        let offset = Double(TimeZone.current.secondsFromGMT(for: end))
        body.message(local: 5, [.date(end), .value(timer * 1000), .int(1), .int(0), .int(26), .int(1),
                                .date(end.addingTimeInterval(offset))])

        var header: [UInt8] = [14, 0x20] + Body.le(2172, 2) + Body.le(UInt64(body.bytes.count), 4) + Array(".FIT".utf8)
        header += Body.le(UInt64(crc(header)), 2)
        let file = header + body.bytes
        return Data(file + Body.le(UInt64(crc(file)), 2))
    }

    /// Distance covered within the interval, from the accumulated record distance.
    private static func distance(in interval: DateInterval, _ records: [FITActivity.Record]) -> Double? {
        let inside = records.filter { interval.contains($0.date) }.compactMap(\.distanceMeters)
        guard let first = inside.min(), let last = inside.max() else { return nil }
        return last - first
    }

    /// FIT CRC-16 (nibble table from the FIT protocol specification).
    static func crc(_ bytes: [UInt8]) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        var crc: UInt16 = 0
        for byte in bytes {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }

    private enum BaseType: UInt8 {
        case enumeration = 0x00, uint8 = 0x02, uint16 = 0x84, sint32 = 0x85, uint32 = 0x86, string = 0x07
        var invalid: UInt64 {
            switch self {
            case .enumeration, .uint8: 0xFF
            case .uint16: 0xFFFF
            case .sint32: 0x7FFF_FFFF
            case .uint32: 0xFFFF_FFFF
            case .string: 0
            }
        }
    }

    private enum Value {
        case int(Int), value(Double?), date(Date), text(String, Int)
    }

    private struct Body {
        var bytes: [UInt8] = []
        var definitions: [UInt8: [(number: UInt8, size: Int, type: BaseType)]] = [:]

        static func le(_ value: UInt64, _ size: Int) -> [UInt8] {
            (0..<size).map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) }
        }

        mutating func define(local: UInt8, global: UInt16, _ fields: [(UInt8, Int, BaseType)]) {
            definitions[local] = fields.map { (number: $0.0, size: $0.1, type: $0.2) }
            bytes += [0x40 | local, 0, 0] + Self.le(UInt64(global), 2) + [UInt8(fields.count)]
            for field in fields { bytes += [field.0, UInt8(field.1), field.2.rawValue] }
        }

        mutating func message(local: UInt8, _ values: [Value]) {
            guard let fields = definitions[local] else { return }
            bytes.append(local)
            for (field, value) in zip(fields, values) {
                switch value {
                case .text(let text, let size):
                    var utf8 = Array(text.utf8.prefix(size - 1))
                    // Never cut inside a multi-byte character.
                    while !utf8.isEmpty, String(bytes: utf8, encoding: .utf8) == nil { utf8.removeLast() }
                    bytes += utf8 + [UInt8](repeating: 0, count: size - utf8.count)
                case .date(let date):
                    bytes += Self.le(UInt64(max(0, date.timeIntervalSince1970 - 631_065_600).rounded(.down)), field.size)
                case .int(let number):
                    bytes += Self.encode(Double(number), field.type, field.size)
                case .value(let number):
                    bytes += Self.encode(number, field.type, field.size)
                }
            }
        }

        /// Rounds to the field's integer; missing or out-of-range values become the type's invalid marker.
        static func encode(_ number: Double?, _ type: BaseType, _ size: Int) -> [UInt8] {
            guard let number, number.isFinite else { return le(type.invalid, size) }
            let rounded = number.rounded()
            if type == .sint32 {
                guard rounded > -2_147_483_647, rounded < 2_147_483_647 else { return le(type.invalid, size) }
                return le(UInt64(bitPattern: Int64(rounded)), size)
            }
            guard rounded >= 0, rounded < Double(type.invalid) else { return le(type.invalid, size) }
            return le(UInt64(rounded), size)
        }
    }
}

extension FITActivity.Record {
    /// A sample at one moment; every measurement is optional.
    public init(at date: Date) { self.init(date: date) }
}
