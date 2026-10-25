import Foundation
import Security

public enum HammerheadError: Error, LocalizedError {
    case random, callback, denied, browser, token(String), unavailable

    public var errorDescription: String? {
        switch self {
        case .random: String(localized: "Sichere Anmeldung konnte nicht vorbereitet werden.", bundle: .module)
        case .callback: String(localized: "Ungültiger Anmelderücksprung. Prüfung gestoppt.", bundle: .module)
        case .denied: String(localized: "Anmeldung abgebrochen oder Zugriff nicht erteilt.", bundle: .module)
        case .browser: String(localized: "Systemanmeldung konnte nicht gestartet werden. Bitte die App erneut öffnen und noch einmal versuchen.", bundle: .module)
        case .token(let code): String(localized: "Hammerhead hat die Sitzung abgelehnt (\(code)). Bitte das Konto erneut verbinden.", bundle: .module)
        case .unavailable: String(localized: "Hammerhead ist in dieser Version nicht verfügbar.", bundle: .module)
        }
    }
}

/// Official Hammerhead API (api.hammerhead.io/v1/docs). Hammerhead requires the client secret for every
/// token request and offers no PKCE, so the app carries a masked secret; it is passed in by the app target
/// and never stored, logged or sent anywhere except the token routes of api.hammerhead.io.
public struct HammerheadOAuth: Sendable {
    /// Public identifier of the registered API client.
    public static let clientID = "4fd79047-37e2-492f-b679-7294ae35d383"
    /// Registered redirect. Hammerhead rejects custom schemes, so a static page hands code and state to `callback`.
    public static let redirect = URL(string: "https://florianwildt.github.io/fitgap/oauth/hammerhead/")!
    public static let callback = URL(string: "fitgap://oauth/hammerhead")!
    public static let scope = "activity:read"
    static let tokenURL = URL(string: "https://api.hammerhead.io/v1/auth/oauth/token")!
    static let deauthorizeURL = URL(string: "https://api.hammerhead.io/v1/auth/oauth/deauthorize")!
    private let state: String

    public init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw HammerheadError.random }
        state = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init(state: String) { self.state = state }

    public var authorizationURL: URL {
        var url = URLComponents(string: "https://api.hammerhead.io/v1/auth/oauth/authorize")!
        url.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirect.absoluteString),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state)
        ]
        return url.url!
    }

    /// Accepts only the exact app callback with this sign-in's state and a single code.
    public func tokenRequest(callback: URL, secret: String) throws -> URLRequest {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == Self.callback.scheme, parts.host == Self.callback.host,
              parts.path == Self.callback.path, parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw HammerheadError.callback }
        let items = parts.queryItems ?? []
        func single(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        guard single("state") == state else { throw HammerheadError.callback }
        if items.contains(where: { $0.name == "error" }) { throw HammerheadError.denied }
        guard let code = single("code"), !code.isEmpty else { throw HammerheadError.callback }
        return Self.form(Self.tokenURL, [
            "client_id": Self.clientID, "client_secret": secret, "grant_type": "authorization_code",
            "code": code, "redirect_uri": Self.redirect.absoluteString
        ])
    }

    static func refreshRequest(refreshToken: String, secret: String) -> URLRequest {
        form(tokenURL, ["client_id": clientID, "client_secret": secret, "grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    static func deauthorizeRequest(token: String, secret: String) -> URLRequest {
        form(deauthorizeURL, ["client_id": clientID, "client_secret": secret, "token": token])
    }

    static func form(_ url: URL, _ values: [String: String]) -> URLRequest {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(values.sorted { $0.key < $1.key }.map {
            $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
        return request
    }
}
