import Foundation

public struct ActivityMetrics: Codable, Sendable, Equatable {
    public let distanceMeters: Double?
    public let ascentMeters: Double?
    public let averageSpeedMetersPerSecond: Double?

    public init(distanceMeters: Double? = nil, ascentMeters: Double? = nil, averageSpeedMetersPerSecond: Double? = nil) {
        self.distanceMeters = distanceMeters; self.ascentMeters = ascentMeters
        self.averageSpeedMetersPerSecond = averageSpeedMetersPerSecond
    }
}

/// Reads only native session totals. No re-encoding, record interpolation or developer-field interpretation.
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
    private struct Session { let distance: Double?; let ascent: Double?; let speed: Double?; let timer: Double? }
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
                        let wanted = definition.global == 18 && [8, 9, 14, 22, 124].contains(field.number)
                        let expectedSize = [14, 22].contains(field.number) ? 2 : 4
                        let expectedType: UInt8 = expectedSize == 2 ? 4 : 6
                        if wanted, field.size == expectedSize, field.type & 31 == expectedType {
                            let value = try unsigned(size: field.size, bigEndian: definition.bigEndian)
                            let invalid: UInt32 = field.size == 2 ? 0xffff : 0xffffffff
                            if value != invalid { values[field.number] = Double(value) }
                        } else { try skip(field.size) }
                    }
                    try skip(definition.developerSize)
                    if definition.global == 18 {
                        sessions.append(Session(distance: values[9].map { $0 / 100 }, ascent: values[22],
                            speed: (values[124] ?? values[14]).map { $0 / 1000 }, timer: values[8].map { $0 / 1000 }))
                    }
                }
            }
            guard !sessions.isEmpty else { throw Invalid.file }
            func sum(_ path: KeyPath<Session, Double?>) -> Double? {
                let values = sessions.compactMap { $0[keyPath: path] }
                return values.count == sessions.count ? values.reduce(0, +) : nil
            }
            let distance = sum(\.distance), timer = sum(\.timer)
            let derivedSpeed = distance.flatMap { distance in timer.flatMap { $0 > 0 ? distance / $0 : nil } }
            return ActivityMetrics(distanceMeters: distance, ascentMeters: sum(\.ascent),
                averageSpeedMetersPerSecond: sessions.count == 1 ? sessions[0].speed ?? derivedSpeed : derivedSpeed)
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
