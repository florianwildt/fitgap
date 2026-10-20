import AuthenticationServices
import FITgapCore
import UIKit

@MainActor
final class WahooSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<URL, Error>?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    func login(_ oauth: WahooOAuth) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                let auth = ASWebAuthenticationSession(url: oauth.authorizationURL, callbackURLScheme: WahooOAuth.redirect.scheme) { url, _ in
                    Task { @MainActor in
                        if let url { self.finish(.success(url)) }
                        else { self.finish(.failure(WahooError.denied)) }
                    }
                }
                auth.presentationContextProvider = self
                auth.prefersEphemeralWebBrowserSession = true
                session = auth
                if !auth.start() { finish(.failure(WahooError.browser)) }
            }
        } onCancel: {
            Task { @MainActor in self.session?.cancel(); self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let callback = pending
        pending = nil; session = nil
        callback?.resume(with: result)
    }
}
