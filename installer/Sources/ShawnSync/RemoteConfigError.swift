import Foundation

/// Why the config could not be fetched from GitHub. `description` is written for the person at the
/// keyboard and is used verbatim inside the installer's notes.
public enum RemoteConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No connection to GitHub at all.
    case offline
    /// The overall deadline (or GitHub's own request timeout) passed.
    case timedOut(seconds: TimeInterval)
    /// GitHub's API refused because the unauthenticated rate limit is used up.
    case rateLimited(resetsAt: Date?, retryAfter: TimeInterval?)
    /// The branch, tag or commit does not exist (or the repo is missing or private).
    case refNotFound(repo: String, ref: String)
    case invalidRepo(String)
    case invalidRef(String)
    case invalidConfigPath(String)
    /// The recursive tree listing did not fit in one response.
    case treeTruncated(repo: String)
    /// The tree listing named a path that would land outside the cache directory.
    case unsafePath(String)
    case missingDirectory(repo: String, path: String, commit: String)
    case notAConfig(path: String, commit: String)
    case tooLarge(files: Int, bytes: Int)
    case downloadFailed(path: String, reason: String)
    case checksumMismatch(path: String)
    case httpStatus(Int, what: String, message: String?)
    case unexpectedResponse(what: String)
    case insecureConnection
    case cancelled
    case network(String)
    /// Writing the downloaded files to the cache failed.
    case cache(String)

    public var description: String {
        switch self {
        case .offline:
            return "GitHub could not be reached; this Mac looks offline"
        case .timedOut(let seconds):
            return "GitHub did not answer within \(Self.formatSeconds(seconds))"
        case .rateLimited(let resetsAt, let retryAfter):
            var text = "GitHub's API rate limit for this network is used up"
            if let resetsAt {
                text += " (it resets at \(Self.clockTime(resetsAt)))"
            } else if let retryAfter {
                text += " (try again in \(Self.formatSeconds(retryAfter)))"
            }
            return text
        case .refNotFound(let repo, let ref):
            return "\(repo) has no branch, tag or commit named '\(ref)' (or the repo is missing or private)"
        case .invalidRepo(let repo):
            return "'\(repo)' is not a GitHub repo name like owner/name"
        case .invalidRef(let ref):
            return "'\(ref)' is not a valid branch, tag or commit name"
        case .invalidConfigPath(let path):
            return "the remote config path '\(path)' is not a plain relative path"
        case .treeTruncated(let repo):
            return "GitHub's file list for \(repo) was truncated (too many files for one listing), so the config could not be fetched completely"
        case .unsafePath(let path):
            return "GitHub's file list contains an unsafe path ('\(path)'), so it was not used"
        case .missingDirectory(let repo, let path, let commit):
            return "\(repo) has no \(path.isEmpty ? "files" : "'\(path)' directory") at \(commit.prefix(7))"
        case .notAConfig(let path, let commit):
            return "'\(path.isEmpty ? "/" : path)' at \(commit.prefix(7)) has no installer.yaml"
        case .tooLarge(let files, let bytes):
            return "the remote config is unexpectedly large (\(files) files, \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
        case .downloadFailed(let path, let reason):
            return "downloading \(path) failed (\(reason))"
        case .checksumMismatch(let path):
            return "\(path) arrived damaged (its contents do not match GitHub's checksum)"
        case .httpStatus(let status, let what, let message):
            let detail = message.map { ": \($0)" } ?? ""
            if (500..<600).contains(status) {
                return "GitHub had a problem answering \(what) (HTTP \(status)\(detail))"
            }
            return "GitHub refused \(what) (HTTP \(status)\(detail))"
        case .unexpectedResponse(let what):
            return "GitHub sent an unexpected answer for \(what) (a captive portal or proxy in the way?)"
        case .insecureConnection:
            return "a secure connection to GitHub could not be made (a captive portal or network filter in the way?)"
        case .cancelled:
            return "the download was canceled"
        case .network(let message):
            return "network error: \(message)"
        case .cache(let message):
            return "the download could not be saved: \(message)"
        }
    }

    /// Turns anything thrown while fetching into a `RemoteConfigError`.
    static func classify(_ error: Error) -> RemoteConfigError {
        switch error {
        case let error as RemoteConfigError:
            return error
        case is CancellationError:
            return .cancelled
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
                return .offline
            case .timedOut:
                return .timedOut(seconds: 0)
            case .cancelled:
                return .cancelled
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                return .insecureConnection
            default:
                return .network(error.localizedDescription)
            }
        case let error as CocoaError:
            return .cache(error.localizedDescription)
        default:
            return .network(String(describing: error))
        }
    }

    /// "3:05 PM" (or the local equivalent).
    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func formatSeconds(_ seconds: TimeInterval) -> String {
        if !seconds.isFinite || seconds <= 0 || seconds > 1e9 { return "the time allowed" }
        let rounded = seconds.rounded()
        if abs(seconds - rounded) < 0.05 {
            let whole = Int(rounded)
            return whole == 1 ? "1 second" : "\(whole) seconds"
        }
        return String(format: "%.1f seconds", seconds)
    }
}
