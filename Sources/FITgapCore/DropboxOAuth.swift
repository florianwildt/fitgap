import CryptoKit
import Foundation
import Security

public enum DropboxError: Error, LocalizedError {
    case random, callback, denied, browser, token(String), scope, unavailable

    public var errorDescription: String? {
        switch self {
        case .random: String(localized: "Sichere Anmeldung konnte nicht vorbereitet werden.", bundle: .module)
        case .callback: String(localized: "Ungültiger Anmelderücksprung. Prüfung gestoppt.", bundle: .module)
        case .denied: String(localized: "Anmeldung abgebrochen oder Zugriff nicht erteilt.", bundle: .module)
        case .browser: String(localized: "Systemanmeldung konnte nicht gestartet werden. Bitte die App erneut öffnen und noch einmal versuchen.", bundle: .module)
        case .token(let code): String(localized: "Dropbox hat die Sitzung abgelehnt (\(code)). Bitte das Konto erneut verbinden.", bundle: .module)
        case .scope: String(localized: "Dropbox hat die benötigten Leseberechtigungen nicht erteilt.", bundle: .module)
        case .unavailable: String(localized: "Dropbox ist in dieser Version nicht verfügbar.", bundle: .module)
        }
    }
}

/// Official Dropbox API v2 (docs.dropboxapi.com). Public client with PKCE: no client secret exists in the app;
/// `token_access_type=offline` returns a refresh token that renews with the app key alone.
public struct DropboxOAuth: Sendable {
    // Public app key of the FITgap app in the Dropbox App Console, never a client secret.
    // Builds with an empty key hide Dropbox.
    public static let clientID = "c0xaawzhxso8j9e"
    public static var isConfigured: Bool { !clientID.isEmpty }
    /// Dropbox accepts only https redirects in the App Console; mobile apps use the scheme `db-<app key>` instead.
    public static let redirect = URL(string: "db-\(clientID)://2/token")!
    /// Read-only: list files and download their content. Writing or sharing is never requested.
    public static let scopes = ["files.metadata.read", "files.content.read"]
    static let tokenURL = URL(string: "https://api.dropboxapi.com/oauth2/token")!
    let verifier: String
    private let state: String

    public init() throws {
        func randomValue() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DropboxError.random }
            return Self.base64URL(Data(bytes))
        }
        verifier = try randomValue()
        state = try randomValue()
    }

    init(verifier: String, state: String) { self.verifier = verifier; self.state = state }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public var authorizationURL: URL {
        var url = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirect.absoluteString),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "state", value: state)
        ]
        return url.url!
    }

    /// Accepts only the exact app callback with this sign-in's state and a single code.
    public func tokenRequest(callback: URL) throws -> URLRequest {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == Self.redirect.scheme, parts.host == Self.redirect.host,
              parts.path == Self.redirect.path, parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw DropboxError.callback }
        let items = parts.queryItems ?? []
        func single(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        guard single("state") == state else { throw DropboxError.callback }
        if items.contains(where: { $0.name == "error" }) { throw DropboxError.denied }
        guard let code = single("code"), !code.isEmpty else { throw DropboxError.callback }
        return HammerheadOAuth.form(Self.tokenURL, [
            "grant_type": "authorization_code", "client_id": Self.clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": Self.redirect.absoluteString
        ])
    }

    static func refreshRequest(refreshToken: String) -> URLRequest {
        HammerheadOAuth.form(tokenURL, ["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken])
    }
}
