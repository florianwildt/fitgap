import Foundation

public struct WahooRateLimit: Error, LocalizedError, Sendable {
    public let until: Date
    public init(until: Date) { self.until = until }
    public var errorDescription: String? {
        String(localized: "Abruflimit erreicht. Wahoo pausiert bis \(until.formatted(date: .abbreviated, time: .shortened)). Bei geöffneter App wird danach automatisch fortgesetzt.", bundle: .module)
    }

    static func deadline(_ response: HTTPURLResponse, now: Date = Date()) -> Date? {
        let exhausted = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?
            .split(separator: ",").contains { Int($0.trimmingCharacters(in: .whitespaces)) == 0 } == true
        guard response.statusCode == 429 || exhausted else { return nil }
        let reset = Double(response.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "") ?? 0
        let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
        // Wahoo documents seconds until reset. Missing/invalid headers must not cause a retry loop.
        let seconds = max(reset.isFinite ? reset : 0, retry.isFinite ? retry : 0)
        return now.addingTimeInterval(seconds > 0 ? seconds + 1 : 301)
    }
}

actor WahooRequestBudget {
    private var until: Date?
    func check() throws {
        if let until, until > Date() { throw WahooRateLimit(until: until) }
    }
    func update(_ response: HTTPURLResponse) {
        if let date = WahooRateLimit.deadline(response) { until = max(until ?? .distantPast, date) }
    }
    func failure() -> WahooRateLimit { WahooRateLimit(until: until ?? Date().addingTimeInterval(301)) }
}
