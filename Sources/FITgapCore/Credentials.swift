import Foundation
import Security

public enum Source: String, Codable, CaseIterable, Identifiable, Sendable {
    case zwift, wahoo, mywhoosh, hammerhead, demo
    public static let providers: [Source] = [.zwift, .wahoo, .mywhoosh, .hammerhead]
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .zwift: "Zwift"
        case .wahoo: "Wahoo"
        case .mywhoosh: "MyWhoosh"
        case .hammerhead: "Hammerhead"
        case .demo: "Demo"
        }
    }
}

public struct Credentials: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let pkceVerifier: String?
    /// Provider account identifier some routes require (MyWhoosh `WhooshId`); not a secret.
    public let accountID: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, pkceVerifier: String? = nil, accountID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.pkceVerifier = pkceVerifier
        self.accountID = accountID
    }

    public var needsRefresh: Bool { expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false }
}

struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
    let scope: String?

    func credentials(previous: Credentials? = nil, verifier: String? = nil) throws -> Credentials {
        guard !access_token.isEmpty else { throw ProbeError.invalidResponse }
        return Credentials(accessToken: access_token, refreshToken: refresh_token ?? previous?.refreshToken,
                           expiresAt: expires_in.map { Date().addingTimeInterval($0) },
                           pkceVerifier: verifier ?? previous?.pkceVerifier)
    }
}

public enum AccountError: Error, LocalizedError {
    case keychain, reconnect
    public var errorDescription: String? {
        switch self {
        case .keychain: String(localized: "Schlüsselbund nicht verfügbar. Gerät entsperren und erneut versuchen.", bundle: .module)
        case .reconnect: String(localized: "Sitzung abgelaufen. Bitte das Konto erneut verbinden.", bundle: .module)
        }
    }
}

public struct CredentialStore {
    private let service: String
    public init(service: String = "org.fitgap.tokens") { self.service = service }

    private func query(_ source: Source) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: source.rawValue, kSecAttrSynchronizable as String: false]
    }

    public func read(_ source: Source) throws -> Credentials? {
        var query = query(source)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else { throw AccountError.keychain }
        return credentials
    }

    public func write(_ credentials: Credentials, for source: Source) throws {
        let data = try JSONEncoder().encode(credentials)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(source) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query(source)
            addition.merge(attrs) { _, new in new }
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw AccountError.keychain }
        } else if status != errSecSuccess { throw AccountError.keychain }
    }

    public func remove(_ source: Source) throws {
        let status = SecItemDelete(query(source) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.keychain }
    }
}
