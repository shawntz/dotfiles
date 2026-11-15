import CoreGraphics
import Foundation

/// A downloaded resource.
public struct FetchedResource: Sendable {
    public let data: Data
    /// Where it was finally served from, after redirects (relative links resolve against this).
    public let url: URL
    public let mimeType: String?

    public init(data: Data, url: URL, mimeType: String? = nil) {
        self.data = data
        self.url = url
        self.mimeType = mimeType
    }
}

public struct FetchError: Error, Sendable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Downloads pages and icons. The installer uses `URLSessionFetcher`; tests inject canned responses.
public protocol WebAppFetching: Sendable {
    /// Downloads `url`, failing on transport errors, non-2xx HTTP statuses and bodies larger than `maxBytes`.
    func fetch(_ url: URL, userAgent: String, maxBytes: Int, timeout: TimeInterval) async throws -> FetchedResource
}

public struct URLSessionFetcher: WebAppFetching {
    public init() {}

    public func fetch(_ url: URL, userAgent: String, maxBytes: Int, timeout: TimeInterval) async throws -> FetchedResource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,image/png,image/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError("\(url.absoluteString) answered HTTP \(http.statusCode)")
        }
        if response.expectedContentLength > Int64(maxBytes) {
            throw FetchError("\(url.absoluteString) is larger than \(maxBytes / 1024) KB")
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(maxBytes)))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw FetchError("\(url.absoluteString) is larger than \(maxBytes / 1024) KB") }
        }
        return FetchedResource(data: data, url: response.url ?? url, mimeType: response.mimeType)
    }
}

/// Finds a site's own icon: what a home-screen bookmark would use.
enum IconDiscovery {
    static let pageLimit = 3 * 1024 * 1024
    static let iconLimit = 8 * 1024 * 1024
    static let timeout: TimeInterval = 15
    /// Smaller icons are skipped: a 16 or 32 px favicon blown up to 1024 px is a smudge; the letter tile reads better.
    static let minimumPixels = 64

    /// The page's icon candidates, best first: `apple-touch-icon` links (largest first), then `icon` links that
    /// declare `sizes` (largest first), then other `icon` links, then `/apple-touch-icon.png` and `/favicon.ico`.
    /// SVG icons are left out because CoreGraphics cannot draw them.
    static func candidates(inHTML html: String, pageURL: URL) -> [URL] {
        var base = pageURL
        if let baseTag = tags(named: "base", in: html).first, let href = baseTag["href"],
           let resolved = URL(string: decodeEntities(href), relativeTo: pageURL)?.absoluteURL {
            base = resolved
        }

        var touchIcons: [(url: URL, size: Int)] = []
        var sizedIcons: [(url: URL, size: Int)] = []
        var unsizedIcons: [URL] = []
        for link in tags(named: "link", in: html) {
            let rel = Set((link["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let isTouchIcon = !rel.isDisjoint(with: ["apple-touch-icon", "apple-touch-icon-precomposed"])
            guard isTouchIcon || rel.contains("icon"), let href = link["href"].map(decodeEntities),
                  !href.isEmpty, let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            if (link["type"] ?? "").lowercased().contains("svg") || url.pathExtension.lowercased() == "svg" { continue }
            let size = declaredSize(link["sizes"])
            if isTouchIcon {
                // Apple's documented default touch icon is 180 px.
                touchIcons.append((url, size ?? 180))
            } else if let size {
                sizedIcons.append((url, size))
            } else {
                unsizedIcons.append(url)
            }
        }

        var ordered = stableSorted(touchIcons) + stableSorted(sizedIcons) + unsizedIcons
        ordered += fallbacks(for: pageURL)
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.absoluteString).inserted }
    }

    /// Well-known locations at the site's root, for pages that declare nothing (or could not be fetched).
    static func fallbacks(for pageURL: URL) -> [URL] {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: true) else { return [] }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return ["/apple-touch-icon.png", "/favicon.ico"].compactMap { path in
            components.path = path
            return components.url
        }
    }

    /// Fetches the page and tries each candidate until one decodes at a usable size.
    static func find(for pageURL: URL, fetcher: any WebAppFetching, userAgent: String,
                     log: (String) -> Void) async -> (image: CGImage, url: URL)? {
        var candidates: [URL]
        do {
            let page = try await fetcher.fetch(pageURL, userAgent: userAgent, maxBytes: pageLimit, timeout: timeout)
            let html = String(decoding: page.data, as: UTF8.self)
            candidates = Self.candidates(inHTML: html, pageURL: page.url)
            if page.url.host != pageURL.host { candidates += fallbacks(for: pageURL) }
        } catch {
            log("could not read \(pageURL.absoluteString) (\(error)); trying the usual icon locations")
            candidates = fallbacks(for: pageURL)
        }

        var seen = Set<String>()
        for url in candidates where seen.insert(url.absoluteString).inserted {
            do {
                let resource = try await fetcher.fetch(url, userAgent: userAgent, maxBytes: iconLimit, timeout: timeout)
                let image = try IconRenderer.decode(resource.data)
                guard min(image.width, image.height) >= minimumPixels else {
                    log("skipping \(url.absoluteString): only \(image.width)×\(image.height) px")
                    continue
                }
                return (image, url)
            } catch {
                log("skipping \(url.absoluteString): \(error)")
            }
        }
        return nil
    }

    // MARK: HTML scanning

    private static let tagPattern = try! NSRegularExpression(pattern: "<(link|base)\\b([^>]*)>", options: [.caseInsensitive])
    // Unquoted values run to the next space, like a browser reads them (an '=' inside, as in a query string, is kept).
    private static let attributePattern = try! NSRegularExpression(
        pattern: "([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*(?:=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'<>`]+)))?",
        options: []
    )

    /// Attributes (names lowercased) of every `<name …>` tag. A tolerant scan, not a full HTML parser:
    /// head tags are simple enough, and a page this cannot read just falls back to the root icons.
    static func tags(named name: String, in html: String) -> [[String: String]] {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var result: [[String: String]] = []
        for match in tagPattern.matches(in: html, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: html), html[nameRange].lowercased() == name,
                  let bodyRange = Range(match.range(at: 2), in: html) else { continue }
            let body = String(html[bodyRange])
            var attributes: [String: String] = [:]
            let bodyNSRange = NSRange(body.startIndex..<body.endIndex, in: body)
            for attribute in attributePattern.matches(in: body, range: bodyNSRange) {
                guard let keyRange = Range(attribute.range(at: 1), in: body) else { continue }
                let key = body[keyRange].lowercased()
                let value = (2...4).lazy.compactMap { Range(attribute.range(at: $0), in: body).map { String(body[$0]) } }.first ?? ""
                if attributes[key] == nil { attributes[key] = value }
            }
            result.append(attributes)
        }
        return result
    }

    /// The largest edge in a `sizes` attribute (`"16x16 180x180"` → 180); nil for `any` or nothing.
    static func declaredSize(_ sizes: String?) -> Int? {
        guard let sizes else { return nil }
        let edges = sizes.lowercased().split(whereSeparator: \.isWhitespace).compactMap { token -> Int? in
            let parts = token.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
            return max(width, height)
        }
        return edges.max()
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&#x2F;", "/"), ("&#47;", "/")] {
            result = result.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        // Last, so "&amp;lt;" becomes "&lt;" rather than "<".
        return result.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    private static func stableSorted(_ entries: [(url: URL, size: Int)]) -> [URL] {
        entries.enumerated()
            .sorted { $0.element.size != $1.element.size ? $0.element.size > $1.element.size : $0.offset < $1.offset }
            .map(\.element.url)
    }
}
