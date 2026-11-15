import XCTest
@testable import ActionsWebApp

final class IconDiscoveryTests: XCTestCase {
    private let page = URL(string: "https://www.example.com/app/home?tab=1#top")!

    private static let fixture = """
    <!DOCTYPE html>
    <html><head>
      <meta charset="utf-8">
      <link rel="stylesheet" href="/style.css">
      <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
      <LINK REL="icon" sizes="192x192" href='icons/android-192.png'>
      <link rel="shortcut icon" href="/favicon.ico">
      <link rel="mask-icon" href="/safari-pinned.svg" color="#000">
      <link rel="icon" type="image/svg+xml" href="/logo.svg">
      <link rel="icon" sizes="any" href="https://cdn.example.com/icon-any.png?v=1&amp;size=big">
      <link rel="apple-touch-icon" href="/touch-default.png">
      <link rel="apple-touch-icon-precomposed" sizes="152x152" href="/touch-152.png">
      <link rel="apple-touch-icon" sizes="76x76 512x512" href="//static.example.com/touch-512.png">
      <link rel="icon" href="data:image/png;base64,AAAA">
    </head><body><link rel="icon" sizes="16x16" href="/late-16.png"></body></html>
    """

    func testCandidatesAreRankedTouchIconsThenSizedThenUnsizedThenRootFallbacks() {
        let urls = IconDiscovery.candidates(inHTML: Self.fixture, pageURL: page).map(\.absoluteString)
        XCTAssertEqual(urls, [
            "https://static.example.com/touch-512.png",
            "https://www.example.com/touch-default.png",
            "https://www.example.com/touch-152.png",
            "https://www.example.com/app/icons/android-192.png",
            "https://www.example.com/favicon-32.png",
            "https://www.example.com/late-16.png",
            "https://www.example.com/favicon.ico",
            "https://cdn.example.com/icon-any.png?v=1&size=big",
            "https://www.example.com/apple-touch-icon.png",
        ])
    }

    func testBaseHrefAndEntityDecoding() {
        let html = #"<head><base href="https://assets.example.net/v2/"><link rel=icon sizes=64x64 href=img/i.png?a=1&amp;b=2></head>"#
        let urls = IconDiscovery.candidates(inHTML: html, pageURL: page).map(\.absoluteString)
        XCTAssertEqual(urls.first, "https://assets.example.net/v2/img/i.png?a=1&b=2")
        XCTAssertEqual(IconDiscovery.decodeEntities("a&amp;lt;b &quot;c&quot; &#39;d&#x27;"), "a&lt;b \"c\" 'd'")
    }

    func testPageWithoutIconsFallsBackToRootLocationsOnTheSameOrigin() {
        let withPort = URL(string: "https://user:pw@dev.example.com:8443/deep/page?q=1")!
        XCTAssertEqual(IconDiscovery.candidates(inHTML: "<html><head><title>x</title></head></html>", pageURL: withPort).map(\.absoluteString), [
            "https://dev.example.com:8443/apple-touch-icon.png",
            "https://dev.example.com:8443/favicon.ico",
        ])
    }

    func testDeclaredSizes() {
        XCTAssertEqual(IconDiscovery.declaredSize("180x180"), 180)
        XCTAssertEqual(IconDiscovery.declaredSize("16x16 32x32 48X48"), 48)
        XCTAssertEqual(IconDiscovery.declaredSize("120x60"), 120)
        XCTAssertNil(IconDiscovery.declaredSize("any"))
        XCTAssertNil(IconDiscovery.declaredSize(nil))
        XCTAssertNil(IconDiscovery.declaredSize("big"))
    }

    func testFindTriesCandidatesInOrderAndSkipsBrokenOrTinyIcons() async throws {
        let fetcher = FakeFetcher()
        // The site redirects to its www host; relative icon links resolve against the final address.
        fetcher.serve("https://example.com/", html: """
        <link rel="apple-touch-icon" sizes="180x180" href="/missing.png">
        <link rel="apple-touch-icon" sizes="120x120" href="/broken.png">
        <link rel="icon" sizes="32x32" href="/tiny.png">
        <link rel="icon" sizes="16x16" href="/good.png">
        """, finalURL: "https://www.example.com/")
        fetcher.serve("https://www.example.com/broken.png", html: "<html>not an image</html>")
        fetcher.serve("https://www.example.com/tiny.png", TestImages.solidPNG(size: 32))
        fetcher.serve("https://www.example.com/good.png", TestImages.solidPNG(size: 96))
        let log = Recorder<String>()

        let found = await IconDiscovery.find(for: URL(string: "https://example.com/")!, fetcher: fetcher,
                                             userAgent: "test", log: { log.add($0) })

        XCTAssertEqual(found?.url.absoluteString, "https://www.example.com/good.png")
        XCTAssertEqual(found?.image.width, 96)
        XCTAssertEqual(fetcher.requests, [
            "https://example.com/",
            "https://www.example.com/missing.png",
            "https://www.example.com/broken.png",
            "https://www.example.com/tiny.png",
            "https://www.example.com/good.png",
        ])
        XCTAssertTrue(log.all.contains { $0.contains("tiny.png: only 32×32 px") }, "\(log.all)")
    }

    func testFindFallsBackToRootIconsWhenThePageCannotBeFetched() async {
        let fetcher = FakeFetcher()
        fetcher.serve("https://offline.example.com/favicon.ico", TestImages.solidPNG(size: 128))

        let found = await IconDiscovery.find(for: URL(string: "https://offline.example.com/app")!, fetcher: fetcher,
                                             userAgent: "test", log: { _ in })

        XCTAssertEqual(found?.url.absoluteString, "https://offline.example.com/favicon.ico")
        XCTAssertEqual(fetcher.requests, [
            "https://offline.example.com/app",
            "https://offline.example.com/apple-touch-icon.png",
            "https://offline.example.com/favicon.ico",
        ])
    }

    func testFindGivesUpWhenNothingIsUsable() async {
        let fetcher = FakeFetcher()
        let found = await IconDiscovery.find(for: URL(string: "https://nothing.example.com")!, fetcher: fetcher,
                                             userAgent: "test", log: { _ in })
        XCTAssertNil(found)
        XCTAssertEqual(fetcher.requests.count, 3)
    }

    func testURLSessionFetcherReadsLocalFilesAndEnforcesTheSizeLimit() async throws {
        let directory = TempDirectory()
        let file = directory.write("page.html", String(repeating: "a", count: 4096))
        let fetcher = URLSessionFetcher()

        let resource = try await fetcher.fetch(file, userAgent: "test", maxBytes: 10_000, timeout: 10)
        XCTAssertEqual(resource.data.count, 4096)
        XCTAssertEqual(resource.url.standardizedFileURL, file.standardizedFileURL)

        do {
            _ = try await fetcher.fetch(file, userAgent: "test", maxBytes: 1000, timeout: 10)
            XCTFail("expected the size limit to apply")
        } catch let error as FetchError {
            XCTAssertTrue(error.description.contains("larger than"), error.description)
        }
    }
}
