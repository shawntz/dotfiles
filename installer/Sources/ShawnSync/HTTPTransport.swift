import Foundation
import ShawnCore

/// The only network access remote config needs: an HTTP GET.
///
/// Implementations hand back every HTTP status as a response (the caller decides what a 404 or a 403
/// means) and throw only when no response arrived at all (offline, TLS failure, canceled).
/// Tests substitute an in-memory fake so they never touch the network.
public protocol HTTPTransport: Sendable {
    /// `timeout` is the longest this one request may take.
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse)
}

public extension HTTPTransport {
    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        try await get(url, headers: [:], timeout: timeout)
    }
}

/// The live transport.
///
/// Requests carry nothing about the user or the Mac: an ephemeral session with no cookie store, no
/// credential store and no cache, and a product-only User-Agent (GitHub's API rejects requests without
/// one). Authentication challenges are refused rather than answered from the keychain, and redirects
/// are followed only to https URLs.
public struct URLSessionTransport: HTTPTransport {
    public static let defaultUserAgent = "ShawnsDotfiles/\(ShawnCore.version)"

    let session: URLSession

    public init(userAgent: String = URLSessionTransport.defaultUserAgent) {
        session = URLSession(configuration: Self.configuration(userAgent: userAgent),
                             delegate: SessionPolicy(), delegateQueue: nil)
    }

    static func configuration(userAgent: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Offline should fail fast so the installer can fall back to the config it already has.
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = RemoteConfig.maxConcurrentDownloads
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return configuration
    }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        // URLRequest's timeout is an idle timeout; the caller's deadline bounds the total.
        let idleTimeout = timeout.isFinite ? min(max(timeout, 1), 600) : 600
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: idleTimeout)
        request.httpShouldHandleCookies = false
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

private final class SessionPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Server trust is ordinary TLS validation. Anything else (HTTP auth, client certificates) would
        // mean presenting something that belongs to the user, which this transport never does.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.rejectProtectionSpace, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}
