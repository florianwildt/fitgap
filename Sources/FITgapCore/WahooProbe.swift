import Foundation

public struct WahooWorkout: Decodable, Sendable, Identifiable {
    public let id: Int64
    public let name: String?
    public let starts: String?
    public let minutes: Double?
    public let workout_summary: Summary?
    public var key: ActivityKey { ActivityKey(source: "wahoo", id: String(id)) }

    public struct Summary: Decodable, Sendable {
        public let file: File?
        public let duration_total_accum: String?
        public struct File: Decodable, Sendable { public let url: URL? }
    }
}

public struct WahooPage: Decodable, Sendable {
    public let workouts: [WahooWorkout]
    public let total: Int
    public let page: Int
    public let per_page: Int
}

enum WahooPages {
    static func collect(
        maximumPages: Int = 500,
        fetch: @Sendable (Int) async throws -> WahooPage
    ) async throws -> [WahooWorkout] {
        guard maximumPages > 0 else { throw ProbeError.pagination }
        var result: [WahooWorkout] = []
        var seen = Set<ActivityKey>()
        var expectedPageSize: Int?
        for requestedPage in 1...maximumPages {
            try Task.checkCancellation()
            let reply = try await fetch(requestedPage)
            guard reply.page == requestedPage, reply.total >= 0, reply.per_page > 0,
                  reply.per_page == (expectedPageSize ?? reply.per_page),
                  reply.workouts.count <= reply.per_page else { throw ProbeError.pagination }
            expectedPageSize = reply.per_page
            let fresh = reply.workouts.filter { seen.insert($0.key).inserted }
            if reply.total == 0 {
                guard requestedPage == 1, reply.workouts.isEmpty else { throw ProbeError.pagination }
                return []
            }
            guard !fresh.isEmpty else { throw ProbeError.pagination }
            result.append(contentsOf: fresh)
            if requestedPage >= (reply.total - 1) / reply.per_page + 1 {
                guard result.count >= reply.total else { throw ProbeError.pagination }
                return result
            }
        }
        throw ProbeError.pagination
    }
}

public final class WahooProbe: Sendable {
    private let session: URLSession
    private let budget = WahooRequestBudget()

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    init(session: URLSession) { self.session = session }
    public func close() { session.invalidateAndCancel() }

    public func authenticate(_ oauth: WahooOAuth, callback: URL) async throws -> String {
        try await connect(oauth, callback: callback).accessToken
    }

    public func connect(_ oauth: WahooOAuth, callback: URL) async throws -> Credentials {
        let response = try await exchange(oauth.tokenRequest(callback: callback))
        return try oauth.credentials(from: response)
    }

    public func refresh(_ credentials: Credentials) async throws -> Credentials {
        guard let refresh = credentials.refreshToken, let verifier = credentials.pkceVerifier else { throw AccountError.reconnect }
        var request = URLRequest(url: URL(string: "https://api.wahooligan.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["client_id": WahooOAuth.clientID,
            "grant_type": "refresh_token", "refresh_token": refresh, "code_verifier": verifier])
        let response = try await exchange(request)
        return try response.credentials(previous: credentials)
    }

    private func exchange(_ request: URLRequest) async throws -> TokenResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        guard response.statusCode == 200 else {
            // Only allow known OAuth error identifiers into UI diagnostics; never response descriptions.
            struct Failure: Decodable { let error: String }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? ""
            if ["invalid_client", "invalid_grant", "invalid_scope", "access_denied", "unsupported_grant_type"].contains(code) {
                throw WahooError.token(code)
            }
            throw ProbeError.http(response.statusCode)
        }
        let token: TokenResponse = try decode(data)
        guard !token.access_token.isEmpty else { throw ProbeError.invalidResponse }
        if let scope = token.scope {
            guard Set(scope.split(separator: " ")).isSuperset(of: ["user_read", "workouts_read"]) else { throw WahooError.scope }
        }
        return token
    }

    public func activities(token: String) async throws -> [WahooWorkout] {
        try await WahooPages.collect { page in
            try self.decode(await self.send(self.apiRequest(path: "/v1/workouts?page=\(page)&per_page=30", token: token)))
        }
    }

    public func downloadFirstFIT(
        from workouts: [WahooWorkout], token: String, store: OriginalFITStore
    ) async throws -> FITReceipt {
        // Completed workouts have a summary. Scheduled/incomplete entries have none.
        for workout in workouts where workout.workout_summary != nil {
            do { return try await download(workout, token: token, store: store) }
            catch ProbeError.noFIT { continue }
        }
        throw ProbeError.noFIT
    }

    public func download(_ workout: WahooWorkout, token: String, store: OriginalFITStore) async throws -> FITReceipt {
        try Task.checkCancellation()
        var file = workout.workout_summary?.file?.url
        if file == nil {
            let detail: WahooWorkout = try decode(await send(apiRequest(path: "/v1/workouts/\(workout.id)", token: token)))
            guard detail.id == workout.id else { throw ProbeError.invalidResponse }
            file = detail.workout_summary?.file?.url
        }
        guard let file else { throw ProbeError.noFIT }
        guard file.scheme == "https", file.host != nil, file.user == nil, file.password == nil else { throw ProbeError.unsafeURL }
        var request = URLRequest(url: file)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let data = try await send(request)
        return try store.save(data, key: workout.key)
    }

    public func download(id: String, token: String, store: OriginalFITStore) async throws -> FITReceipt {
        guard Int64(id) != nil else { throw ProbeError.invalidResponse }
        let workout: WahooWorkout = try decode(await send(apiRequest(path: "/v1/workouts/\(id)", token: token)))
        guard String(workout.id) == id else { throw ProbeError.invalidResponse }
        return try await download(workout, token: token, store: store)
    }

    func apiRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.wahooligan.com" + path)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func send(_ request: URLRequest) async throws -> Data {
        let isAPI = request.url?.host == "api.wahooligan.com"
        if isAPI { try await budget.check() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        if isAPI {
            await budget.update(response)
            if response.statusCode == 429 { throw await budget.failure() }
        }
        guard response.statusCode == 200 else { throw ProbeError.http(response.statusCode) }
        return data
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ProbeError.invalidResponse }
    }
}
