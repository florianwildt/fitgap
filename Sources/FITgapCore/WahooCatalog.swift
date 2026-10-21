import Foundation

/// Contains only pagination metadata, never tokens or signed file URLs.
public struct WahooCatalogCursor: Codable, Sendable {
    public let nextPage: Int
    public let pageSize: Int?
    public let anchorID: Int64?
    public init(nextPage: Int = 1, pageSize: Int? = nil, anchorID: Int64? = nil) {
        self.nextPage = nextPage; self.pageSize = pageSize; self.anchorID = anchorID
    }

    func canResume(after previous: WahooPage, first: WahooPage) -> Bool {
        nextPage > 1 && nextPage <= 500 && pageSize == first.per_page && pageSize == previous.per_page
            && previous.workouts.contains { $0.id == anchorID }
    }
}

extension WahooProbe {
    /// Persist every validated page before advancing. Re-read the last page after interruption:
    /// new/deleted workouts can shift offset pagination; an absent anchor restarts the scan safely.
    public func catalog(
        token: String, cursor: WahooCatalogCursor, known: Set<ActivityKey> = [],
        save: @Sendable (WahooPage, WahooCatalogCursor) async throws -> Void
    ) async throws {
        // Wahoo sorts by start time, newest first: a fresh scan of known activities needs only a small first page.
        let perPage = cursor.nextPage == 1 && !known.isEmpty ? 30 : 100
        let first = try await workoutPage(1, token: token, perPage: perPage)
        var current = first
        let lastPage = first.total == 0 ? 1 : (first.total - 1) / first.per_page + 1
        if cursor.nextPage > 1, cursor.nextPage <= 500, cursor.nextPage - 1 <= lastPage {
            let previous = try await workoutPage(cursor.nextPage - 1, token: token, perPage: perPage)
            if cursor.canResume(after: previous, first: first) {
                // Always pick up the newest page, including backlogs added during a pause.
                try await save(first, cursor)
                current = previous
            }
        }
        var seen = Set<ActivityKey>()
        // Newest first: a fresh scan whose page holds nothing new has reached the known backlog.
        let incremental = cursor.nextPage == 1 && !known.isEmpty
        for _ in 0..<500 {
            try Task.checkCancellation()
            let last = current.total == 0 || current.page >= (current.total - 1) / current.per_page + 1
            let fresh = current.workouts.filter { seen.insert($0.key).inserted }
            guard current.total == 0 || !fresh.isEmpty else {
                throw ProbeError.pagination
            }
            let caughtUp = incremental && current.workouts.allSatisfy { known.contains($0.key) }
            let next = last || caughtUp ? WahooCatalogCursor() : WahooCatalogCursor(
                nextPage: current.page + 1, pageSize: current.per_page, anchorID: current.workouts.last?.id)
            try await save(current, next)
            if last || caughtUp { return }

            guard current.page < 500 else { throw ProbeError.pagination }
            let following = try await workoutPage(current.page + 1, token: token, perPage: perPage)
            guard following.per_page == current.per_page else { throw ProbeError.pagination }
            current = following
        }
        throw ProbeError.pagination
    }

    func workoutPage(_ page: Int, token: String, perPage: Int = 100) async throws -> WahooPage {
        let reply: WahooPage = try decode(await send(apiRequest(path: "/v1/workouts?page=\(page)&per_page=\(perPage)", token: token)))
        guard reply.page == page, reply.total >= 0, reply.per_page > 0, reply.workouts.count <= reply.per_page,
              (reply.total == 0 ? page == 1 && reply.workouts.isEmpty : !reply.workouts.isEmpty) else {
            throw ProbeError.pagination
        }
        return reply
    }
}
