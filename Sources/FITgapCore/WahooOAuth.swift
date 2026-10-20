import CryptoKit
import Foundation
import Security

public enum WahooError: Error, LocalizedError {
    case random, callback, denied, browser, token(String), scope

    public var errorDescription: String? {
        switch self {
        case .random: "Sichere Anmeldung konnte nicht vorbereitet werden."
        case .callback: "Ungültiger Anmelderücksprung. Prüfung gestoppt."
        case .denied: "Anmeldung abgebrochen oder Zugriff nicht erteilt."
        case .browser: "Systemanmeldung konnte nicht gestartet werden. Bitte die App erneut öffnen und noch einmal versuchen."
        case .token(let code): "Wahoo hat die Sitzung abgelehnt (\(code)). Bitte das Konto erneut verbinden; bei erneutem Fehler die App-Konfiguration prüfen."
        case .scope: "Wahoo hat die benötigten Leseberechtigungen nicht erteilt."
        }
    }
}

public struct WahooOAuth: Sendable {
    // Public identifier supplied by the app owner, never a client secret.
    // Temporarily Sandbox while Production awaits approval.
    // Registered Production client: raFFQvn1_PDQn5CZJyQBpM3RtkSFJaZERKWwiNHZPoc
    public static let clientID = "lUJNWGsSLnlnst3wbyXg0MiCVIxAYfEm4s92wOZAyTI"
    public static let redirect = URL(string: "fitgap://oauth/wahoo")!
    public static let scopes = "user_read workouts_read"
    private let verifier: String
    private let state: String

    func credentials(from response: TokenResponse) throws -> Credentials {
        try response.credentials(verifier: verifier)
    }

    public init() throws {
        func randomValue() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw WahooError.random
            }
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
        var url = URLComponents(string: "https://api.wahooligan.com/oauth/authorize")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirect.absoluteString),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "state", value: state)
        ]
        return url.url!
    }

    public func tokenRequest(callback: URL) throws -> URLRequest {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == Self.redirect.scheme, parts.host == Self.redirect.host,
              parts.path == Self.redirect.path, parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw WahooError.callback }
        let items = parts.queryItems ?? []
        func single(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        guard single("state") == state else { throw WahooError.callback }
        if items.contains(where: { $0.name == "error" }) { throw WahooError.denied }
        guard let code = single("code"), !code.isEmpty else { throw WahooError.callback }
        var request = URLRequest(url: URL(string: "https://api.wahooligan.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "authorization_code", "client_id": Self.clientID,
            "redirect_uri": Self.redirect.absoluteString, "code": code, "code_verifier": verifier
        ])
        return request
    }
}
