import Foundation
import XCTest
@testable import ShawnCLIKit

/// SU-8: a release download has a real overall deadline, not just an idle timeout. Loopback only.
final class SelfUpdateDownloadTests: XCTestCase {
    func testATricklingDownloadIsCutOffAtTheDeadline() async throws {
        // 200 bytes, one every 0.1 s: never quiet for long, but 20 s in all.
        let server = try TrickleServer(body: Data(repeating: 0x61, count: 200), chunk: 1, interval: 0.1)
        defer { server.stop() }
        let started = Date()
        do {
            let data = try await GitHubReleaseSource().download(server.url, timeout: 2)
            XCTFail("got \(data.count) bytes after \(Date().timeIntervalSince(started)) s")
        } catch {
            XCTAssertEqual("\(error)", "shawn.tar.gz did not download within 2 seconds")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5)
    }

    func testAPromptDownloadArrivesWhole() async throws {
        let body = Data((0..<5000).map { UInt8($0 % 251) })
        let server = try TrickleServer(body: body, chunk: 5000, interval: 0)
        defer { server.stop() }
        let data = try await GitHubReleaseSource().download(server.url, timeout: 5)
        XCTAssertEqual(data, body)
    }

    func testAnHTTPErrorIsAFailure() async throws {
        let server = try TrickleServer(status: 404, body: Data("Not Found".utf8), chunk: 100, interval: 0)
        defer { server.stop() }
        do {
            _ = try await GitHubReleaseSource().download(server.url, timeout: 5)
            XCTFail("a 404 is not a release")
        } catch {
            XCTAssertEqual("\(error)", "shawn.tar.gz: HTTP 404")
        }
    }
}
