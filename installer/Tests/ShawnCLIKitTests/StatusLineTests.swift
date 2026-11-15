import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

final class StatusLineTests: XCTestCase {
    /// The documented example input (a copy of live-snapshot/research/statusline-input-example.json).
    static let sample = """
    {"cwd":"/current/working/directory","session_id":"abc123...","session_name":"my-session","prompt_id":"550e8400-e29b-41d4-a716-446655440000",
     "transcript_path":"/path/to/transcript.jsonl","model":{"id":"claude-opus-5-5","display_name":"Opus"},
     "workspace":{"current_dir":"/current/working/directory","project_dir":"/original/project/directory","added_dirs":[],"git_worktree":"feature-xyz",
       "repo":{"host":"github.com","owner":"anthropics","name":"claude-code"}},
     "version":"2.1.90","output_style":{"name":"default"},
     "cost":{"total_cost_usd":0.01234,"total_duration_ms":45000,"total_api_duration_ms":2300,"total_lines_added":156,"total_lines_removed":23},
     "context_window":{"total_input_tokens":15500,"total_output_tokens":1200,"context_window_size":200000,"used_percentage":8,"remaining_percentage":92,
       "current_usage":{"input_tokens":8500,"output_tokens":1200,"cache_creation_input_tokens":5000,"cache_read_input_tokens":2000}},
     "exceeds_200k_tokens":false,"effort":{"level":"high"},"thinking":{"enabled":true},
     "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600}},"vim":{"mode":"NORMAL"},"agent":{"name":"security-reviewer"}}
    """

    private let home = URL(fileURLWithPath: "/Users/lsp")
    private let quips = ["lumping along", "what the lump", "so lumpy rn"]

    private func render(_ json: String, columns: Int, root: URL? = nil, git: GitStatus? = nil, directory: String? = nil) -> String {
        let input = StatusLineInput.parse(Data(json.utf8))
        let renderer = StatusLineRenderer(style: .off, columns: columns, home: home, quips: quips)
        let folder = URL(fileURLWithPath: directory ?? input.currentDirectory ?? "/Users/lsp/Desktop")
        return renderer.render(input, directory: folder, repositoryRoot: root, git: git)
    }

    func testParsesTheDocumentedSample() {
        let input = StatusLineInput.parse(Data(Self.sample.utf8))
        XCTAssertEqual(input, StatusLineInput(model: "Opus", currentDirectory: "/current/working/directory", projectDirectory: "/original/project/directory",
                                              sessionID: "abc123...", promptID: "550e8400-e29b-41d4-a716-446655440000", usedPercentage: 8, costUSD: 0.01234))
    }

    func testSampleAtThreeWidths() {
        let quip = quips[Int(StatusLineRenderer.fnv1a("550e8400-e29b-41d4-a716-446655440000") % UInt64(quips.count))]
        XCTAssertEqual(render(Self.sample, columns: 120), "✦ Opus · /current/working/directory · ▰▱▱▱▱▱▱▱▱▱ 8% · $0.01 · \(quip)")
        XCTAssertEqual(render(Self.sample, columns: 70), "✦ Opus · /current/working/directory · ▰▱▱▱▱▱▱▱▱▱ 8% · $0.01")
        XCTAssertEqual(render(Self.sample, columns: 50), "✦ Opus · /current/working/directory · ctx 8%")
        XCTAssertEqual(render(Self.sample, columns: 40), "✦ Opus · …working/directory · ctx 8%")
        XCTAssertEqual(render(Self.sample, columns: 20), "✦ Opus")
    }

    func testInsideAGitRepository() {
        let root = URL(fileURLWithPath: "/Users/lsp/Developer/dotfiles")
        let json = #"{"model":{"display_name":"Sonnet"},"workspace":{"current_dir":"/Users/lsp/Developer/dotfiles/installer/Sources"},"context_window":{"used_percentage":77.6},"cost":{"total_cost_usd":123.4},"prompt_id":"p1"}"#
        let quip = quips[Int(StatusLineRenderer.fnv1a("p1") % UInt64(quips.count))]
        XCTAssertEqual(render(json, columns: 120, root: root, git: GitStatus(branch: "master", dirty: true)),
                       "✦ Sonnet · dotfiles/installer/Sources · ▰▰▰▰▰▰▰▰▱▱ 78% · master* · $123 · \(quip)")
        XCTAssertEqual(render(json, columns: 120, root: root, git: GitStatus(branch: "main", dirty: nil), directory: "/Users/lsp/Developer/dotfiles"),
                       "✦ Sonnet · dotfiles · ▰▰▰▰▰▰▰▰▱▱ 78% · main · $123 · \(quip)", "unknown dirty state: no marker")
        XCTAssertEqual(render(json, columns: 64, root: root, git: GitStatus(branch: "master", dirty: false)),
                       "✦ Sonnet · dotfiles/installer/Sources · ctx 78% · master")
    }

    func testSparseEmptyAndGarbageInput() {
        XCTAssertEqual(render(#"{"model":{"id":"claude-x"}}"#, columns: 80), "✦ claude-x · ~/Desktop · so lumpy rn")
        XCTAssertEqual(render("{}", columns: 80), "✦ · ~/Desktop · so lumpy rn")
        XCTAssertEqual(render("", columns: 80), "✦ · ~/Desktop · so lumpy rn")
        XCTAssertEqual(render("not json {", columns: 80), "✦ · ~/Desktop · so lumpy rn")
        XCTAssertEqual(render("[1,2,3]", columns: 80), "✦ · ~/Desktop · so lumpy rn")
        XCTAssertEqual(render(#"{"model":"Opus","cwd":"/Users/lsp","context_window":{"used_percentage":"oops"},"cost":{"total_cost_usd":true}}"#, columns: 80),
                       "✦ Opus · ~ · so lumpy rn", "wrong types are ignored, not fatal")
    }

    func testContextPercentageFallsBackToTokenCounts() {
        let json = #"{"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000,"cache_read_input_tokens":50000}}}"#
        XCTAssertEqual(StatusLineInput.parse(Data(json.utf8)).usedPercentage, 50)
        XCTAssertEqual(StatusLineInput.parse(Data(#"{"context_window":{"used_percentage":180}}"#.utf8)).usedPercentage, 100)
    }

    func testQuipIsStableWithinAPromptAndChangesAcrossPrompts() {
        let renderer = StatusLineRenderer(style: .off, columns: 100, home: home, quips: (1...20).map { "quip \($0)" })
        let a = StatusLineInput(promptID: "prompt-a")
        XCTAssertEqual(renderer.quip(for: a), renderer.quip(for: a))
        let distinct = Set((1...30).map { renderer.quip(for: StatusLineInput(promptID: "prompt-\($0)")) ?? "" })
        XCTAssertGreaterThan(distinct.count, 5)
        XCTAssertEqual(StatusLineRenderer(style: .off, columns: 100, home: home, quips: []).quip(for: a).map { StatusLineRenderer.fallbackQuips.contains($0) }, true)
    }

    func testMeterColourShiftsAsItFills() {
        let renderer = StatusLineRenderer(style: Style(enabled: true, trueColor: true), columns: 100, home: home, quips: [])
        XCTAssertTrue(renderer.meter(10, compact: false).contains("38;2;124;242;176"), "mint while there is room")
        XCTAssertTrue(renderer.meter(60, compact: false).contains("38;2;255;230;109"), "yellow past half")
        XCTAssertTrue(renderer.meter(80, compact: false).contains("38;2;255;166;92"), "orange past three quarters")
        XCTAssertTrue(renderer.meter(95, compact: false).contains("38;2;255;107;107"), "red when nearly full")
    }

    func testGitPorcelainParsing() {
        XCTAssertEqual(SystemStatusGit.parsePorcelain("# branch.oid abc\n# branch.head master\n# branch.upstream origin/master\n"), GitStatus(branch: "master", dirty: false))
        XCTAssertEqual(SystemStatusGit.parsePorcelain("# branch.oid 1234567890\n# branch.head (detached)\n1 .M N... 100644 100644 100644 a b file\n"), GitStatus(branch: "1234567", dirty: true))
        XCTAssertNil(SystemStatusGit.parsePorcelain("garbage"))
    }

    func testRealGitProbeAndHeadFallback() throws {
        let directory = TempDirectory()
        let repo = directory.url.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        git(["init", "-q", "-b", "trunk"], in: repo)
        let probe = SystemStatusGit(environment: Sandbox().environment)
        XCTAssertEqual(probe.repositoryRoot(for: repo.appendingPathComponent("sub"))?.path, repo.path)
        XCTAssertNil(probe.repositoryRoot(for: directory.url))
        XCTAssertEqual(probe.status(of: repo, directory: repo), GitStatus(branch: "trunk", dirty: false))
        try Data("x".utf8).write(to: repo.appendingPathComponent("new.txt"))
        XCTAssertEqual(probe.status(of: repo, directory: repo), GitStatus(branch: "trunk", dirty: true), "untracked files count as changes")
        XCTAssertEqual(SystemStatusGit.branchFromHead(repo), "trunk")

        // A worktree-style .git file pointing elsewhere.
        let linked = directory.url.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data("gitdir: ../repo/.git\n".utf8).write(to: linked.appendingPathComponent(".git"))
        XCTAssertEqual(SystemStatusGit.branchFromHead(linked), "trunk")
    }

    func testCommandReadsStdinAndAlwaysExitsZero() async {
        let sandbox = Sandbox(extraEnvironment: ["COLUMNS": "60", "NO_COLOR": "1"])
        let harness = Harness(sandbox: sandbox, stdin: Self.sample) { services in
            services.statusGit = FakeStatusGit(root: nil, status: nil)
        }
        do { let code = await harness.run(["statusline"]); XCTAssertEqual(code, 0) }
        XCTAssertEqual(harness.out.text, "✦ Opus · /current/working/directory · ▰▱▱▱▱▱▱▱▱▱ 8%\n")
        XCTAssertEqual(harness.err.text, "")

        let garbage = Harness(sandbox: Sandbox(extraEnvironment: ["NO_COLOR": "1"]), stdin: "\u{0}\u{1}not json") { services in
            services.statusGit = FakeStatusGit(root: nil, status: nil)
        }
        do { let code = await garbage.run(["statusline"]); XCTAssertEqual(code, 0) }
        XCTAssertTrue(garbage.out.text.hasPrefix("✦ · ~"), garbage.out.text)
        XCTAssertEqual(garbage.err.text, "")
    }

    func testColourIsOnWithoutATTYUnlessNoColor() async {
        let harness = Harness(sandbox: Sandbox(extraEnvironment: ["COLUMNS": "100"]), stdin: Self.sample) { services in
            services.statusGit = FakeStatusGit(root: nil, status: nil)
        }
        _ = await harness.run(["statusline"])
        XCTAssertTrue(harness.out.text.contains("\u{1B}[38;2;"), "Claude Code renders ANSI colour even though stdout is a pipe")
        let plain = Harness(sandbox: Sandbox(extraEnvironment: ["COLUMNS": "100"]), stdin: Self.sample) { services in
            services.statusGit = FakeStatusGit(root: nil, status: nil)
        }
        _ = await plain.run(["--no-color", "statusline"])
        XCTAssertFalse(plain.out.text.contains("\u{1B}"))
    }

    func testIsFastWithoutGit() async {
        let harness = Harness(sandbox: Sandbox(extraEnvironment: ["COLUMNS": "120"]), stdin: Self.sample) { services in
            services.statusGit = FakeStatusGit(root: nil, status: nil)
        }
        let started = Date()
        _ = await harness.run(["statusline"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
    }
}
