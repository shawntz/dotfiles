import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

final class GitClientTests: XCTestCase {
    /// The real client, through a `git` that writes down what it was given and then hangs like a stuck ssh.
    func testGitIsNeverAskedToPromptOrOpenAWindowAndIsCutOff() async {
        var sandbox = Sandbox()
        sandbox.environment.baseEnvironment["GIT_ASKPASS"] = "/Applications/Some.app/askpass"
        sandbox.environment.baseEnvironment["SSH_ASKPASS"] = "/usr/local/bin/ssh-askpass"
        let log = sandbox.directory.url.appendingPathComponent("git.log")
        sandbox.shim("git", """
        {
          echo "PROMPT=$GIT_TERMINAL_PROMPT"
          echo "GIT_ASKPASS=${GIT_ASKPASS-unset}"
          echo "SSH_ASKPASS=${SSH_ASKPASS-unset}"
          echo "SSH_ASKPASS_REQUIRE=$SSH_ASKPASS_REQUIRE"
          echo "GCM_INTERACTIVE=$GCM_INTERACTIVE"
          echo "GIT_SSH_COMMAND=$GIT_SSH_COMMAND"
          echo "TTY=$(/bin/ps -o tty= -p $$ | /usr/bin/tr -d ' ')"
        } > '\(log.path)'
        /bin/sleep 10
        """)
        let client = SystemGitClient(launcher: SystemProcessLauncher(), environment: sandbox.environment)
        let started = Date()
        let result = await client.run(["ls-remote", "origin"], in: nil, timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(GitFailure(result, timeout: 0.5).message, "no answer within 0.5 seconds")
        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertEqual(logged, """
        PROMPT=0
        GIT_ASKPASS=
        SSH_ASKPASS=unset
        SSH_ASKPASS_REQUIRE=never
        GCM_INTERACTIVE=never
        GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=5
        TTY=??

        """)
    }

    func testTheUsersOwnSSHCommandIsKept() {
        let overrides = SystemGitClient.nonInteractiveOverrides(base: ["GIT_SSH_COMMAND": "ssh -i ~/.ssh/work"])
        XCTAssertNil(overrides["GIT_SSH_COMMAND"])
        XCTAssertEqual(overrides["SSH_ASKPASS_REQUIRE"], "never", "still no askpass window")
        XCTAssertEqual(overrides["GIT_TERMINAL_PROMPT"], "0")
    }

    /// The status asked before every command must not take the index lock, and file names come unescaped.
    func testReadsTakeNoOptionalLocksAndNamesComeAsTheyAre() async throws {
        let overrides = SystemGitClient.nonInteractiveOverrides(base: [:])
        XCTAssertEqual(overrides["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(overrides["GIT_LITERAL_PATHSPECS"], "0", "':(exclude)' keeps its meaning whatever the shell exports")
        XCTAssertEqual([overrides["GIT_CONFIG_COUNT"], overrides["GIT_CONFIG_KEY_0"], overrides["GIT_CONFIG_VALUE_0"]], ["1", "core.quotePath", "false"])
        let theirs = SystemGitClient.nonInteractiveOverrides(base: ["GIT_CONFIG_COUNT": "2"])
        XCTAssertNil(theirs["GIT_CONFIG_COUNT"], "settings the caller passes this way are kept")
        XCTAssertNil(theirs["GIT_CONFIG_KEY_0"])

        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/Sources/shawn/Wïp fïle.swift", "let wip = 1\n")
        let repo = GitRepo(root: fixture.checkout, git: fixture.realGit)
        let untracked = await repo.untrackedFiles(under: ["installer/Sources"])
        XCTAssertEqual(untracked, ["installer/Sources/shawn/Wïp fïle.swift"], "not installer/Sources/shawn/W\\303\\257p …")
    }

    func testLsRemoteWithSymrefs() {
        let refs = RemoteRefs.parse([
            "ref: refs/heads/main\tHEAD",
            "abc\tHEAD",
            "abc\trefs/heads/main",
            "111\trefs/tags/shawn-v1.2.0",
            "222\trefs/tags/shawn-v1.2.0^{}",
            "garbage",
        ])
        XCTAssertEqual(refs.defaultBranch, "main")
        XCTAssertEqual(refs.refs["HEAD"], "abc")
        XCTAssertEqual(refs.refs["refs/heads/main"], "abc")
        XCTAssertEqual(refs.refs.count, 4)
        XCTAssertNil(RemoteRefs.parse(["abc\trefs/heads/main"]).defaultBranch)
    }

    func testFailureMessages() {
        XCTAssertEqual(GitFailure(ProcessResult(exitCode: 128, stdout: "", stderr: "hint: try this\nfatal: repository 'x' not found\nmore\n"), timeout: 3).message,
                       "fatal: repository 'x' not found")
        XCTAssertEqual(GitFailure(ProcessResult(exitCode: 124, stdout: "", stderr: "", timedOut: true), timeout: 20).message, "no answer within 20 seconds")
        XCTAssertEqual(GitFailure(ProcessResult(exitCode: 127, stdout: "", stderr: "", launchError: "git is not available"), timeout: 3).message, "git is not available")
        XCTAssertEqual(GitFailure(ProcessResult(exitCode: 1, stdout: "", stderr: ""), timeout: 3).message, "git exited with status 1")
    }

    /// ssh and the server print the cause on the line before git's own (which only says it could not read from the remote).
    func testTheCauseBeforeGitsOwnLineIsKept() {
        func message(_ stderr: String) -> String { GitFailure(ProcessResult(exitCode: 128, stdout: "", stderr: stderr), timeout: 3).message }
        XCTAssertEqual(message("git@github.com: Permission denied (publickey).\r\nfatal: Could not read from remote repository.\n\n"
                               + "Please make sure you have the correct access rights\nand the repository exists.\n"),
                       "git@github.com: Permission denied (publickey). fatal: Could not read from remote repository.")
        XCTAssertEqual(message("remote: Repository not found.\nfatal: repository 'https://github.com/x/y.git/' not found\n"),
                       "remote: Repository not found. fatal: repository 'https://github.com/x/y.git/' not found")
        XCTAssertEqual(message("ssh: connect to host github.com port 22: Operation timed out\r\nfatal: Could not read from remote repository.\n"),
                       "ssh: connect to host github.com port 22: Operation timed out; fatal: Could not read from remote repository.")
        XCTAssertEqual(message("hint: Diverging branches can't be fast-forwarded\nfatal: Not possible to fast-forward, aborting.\n"),
                       "fatal: Not possible to fast-forward, aborting.", "advice is not a cause")
        XCTAssertEqual(message("warning: redirecting to https://github.com/x/y.git/\nfatal: could not read Username for 'https://github.com': terminal prompts disabled\n"),
                       "fatal: could not read Username for 'https://github.com': terminal prompts disabled")
    }

    /// No answer (offline, passes by itself) told apart from an answer that waiting does not change, from what git, curl
    /// and ssh really print.
    func testNoAnswerIsToldApartFromARefusal() {
        func noAnswer(_ stderr: String) -> Bool { GitFailure(ProcessResult(exitCode: 128, stdout: "", stderr: stderr), timeout: 3).noAnswer }
        let offline = [
            "fatal: unable to access 'https://github.com/x/y.git/': Could not resolve host: github.com\n",
            "fatal: unable to access 'https://github.com/x/y.git/': Failed to connect to github.com port 443 after 3 ms: Couldn't connect to server\n",
            "fatal: unable to access 'https://github.com/x/y.git/': Resolving timed out after 3000 milliseconds\n",
            "ssh: Could not resolve hostname github.com: nodename nor servname provided, or not known\r\nfatal: Could not read from remote repository.\n",
            "ssh: connect to host github.com port 22: Network is unreachable\r\nfatal: Could not read from remote repository.\n",
            "kex_exchange_identification: Connection closed by remote host\r\nfatal: Could not read from remote repository.\n",
        ]
        for stderr in offline { XCTAssertTrue(noAnswer(stderr), stderr) }
        let answered = [
            "git@github.com: Permission denied (publickey).\r\nfatal: Could not read from remote repository.\n",
            "Host key verification failed.\r\nfatal: Could not read from remote repository.\n",
            "ERROR: Repository not found.\nfatal: Could not read from remote repository.\n",
            "fatal: could not read Username for 'https://github.com': terminal prompts disabled\n",
            "remote: Invalid username or password.\nfatal: Authentication failed for 'https://github.com/x/y.git/'\n",
            "fatal: '/Volumes/Backup/dotfiles.git' does not appear to be a git repository\nfatal: Could not read from remote repository.\n",
        ]
        for stderr in answered { XCTAssertFalse(noAnswer(stderr), stderr) }
        XCTAssertTrue(GitFailure(ProcessResult(exitCode: 124, stdout: "", stderr: "", timedOut: true), timeout: 3).noAnswer)
        XCTAssertFalse(GitFailure(ProcessResult(exitCode: 127, stdout: "", stderr: "", launchError: "git is not available"), timeout: 3).noAnswer,
                       "a Mac without git does not get git back by waiting")
    }

    /// git lists each file after a tab exactly as it is named, never quoted (checked with git 2.54).
    func testFilesInTheWayOfAMerge() {
        let refused = ProcessResult(exitCode: 1, stdout: "Updating abc..def\n", stderr: """
        error: The following untracked working tree files would be overwritten by merge:
        \tinstaller/config/new.yaml
        \tinstaller/config/with space.yaml
        Please move or remove them before you merge.
        Aborting

        """)
        XCTAssertEqual(GitRepo.filesInTheWay(refused), ["installer/config/new.yaml", "installer/config/with space.yaml"])
        XCTAssertEqual(GitRepo.filesInTheWay(ProcessResult(exitCode: 128, stdout: "", stderr: "fatal: Not possible to fast-forward, aborting.\n")), [])
    }

    /// Spaces and quotes at either end belong to the name.
    func testFilesInTheWayAreNamedAsTheyAre() async {
        let fixture = UpdateFixture()
        let names = ["installer/config/notes ", "installer/config/say \"hi\""]
        for name in names {
            fixture.write(fixture.checkout, name, "mine\n")
            fixture.write(fixture.upstream, name, "theirs\n")
        }
        git(["add", "-A"], in: fixture.upstream)
        git(["commit", "-q", "-m", "add"], in: fixture.upstream)
        git(["push", "-q", "origin", "master"], in: fixture.upstream)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .skipped("pulling origin/master would overwrite \(names[0]) and \(names[1]) in \(fixture.checkout.path). "
                                                + "Move or remove them, then run 'shawn update'"))
    }

    /// git status C-quotes a name with a quote, a backslash, a tab or a space whatever core.quotePath says, and " -> "
    /// inside one name looked like a rename. Read with -z, every name comes as it is.
    func testUntrackedAndChangedNamesComeAsTheyAre() async {
        let fixture = UpdateFixture()
        let names = ["my \"draft\".swift", "x -> y.swift", "tab\there.swift", "back\\slash.swift", "café.swift", "sp ace.swift", " lead.swift"]
        let paths = names.map { "installer/Sources/shawn/" + $0 }
        for path in paths { fixture.write(fixture.checkout, path, "wip\n") }
        let repo = GitRepo(root: fixture.checkout, git: fixture.realGit)
        let untracked = await repo.untrackedFiles(under: ["installer/Sources"]) ?? []
        XCTAssertEqual(Set(untracked), Set(paths))
        XCTAssertEqual(untracked.count, paths.count)

        // A staged rename is listed by its new name; its old name is not a file of its own.
        git(["mv", "installer/Sources/shawn/main.swift", "installer/Sources/shawn/new \"main\".swift"], in: fixture.checkout)
        let changed = await repo.changedFiles(under: "installer/Sources")
        XCTAssertEqual(Set(changed), Set(paths + ["installer/Sources/shawn/new \"main\".swift"]))
        XCTAssertEqual(changed.count, paths.count + 1)
        let staged = await repo.stagedFiles()
        XCTAssertEqual(staged, ["installer/Sources/shawn/new \"main\".swift"], "git diff names a rename by its new name")
    }

    func testUntrackedFilesUnderPathspecs() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/Sources/shawn/WIP.swift", "x\n")
        fixture.write(fixture.checkout, "installer/Package@swift-6.0.swift", "x\n")
        fixture.write(fixture.checkout, "installer/config/notes.md", "x\n")
        fixture.write(fixture.checkout, "installer/Sources/shawn/main.swift", "tracked edit\n")
        let repo = GitRepo(root: fixture.checkout, git: fixture.realGit)
        let untracked = await repo.untrackedFiles(under: ["installer/Sources", "installer/Package*"])
        XCTAssertEqual(untracked.map(Set.init), ["installer/Sources/shawn/WIP.swift", "installer/Package@swift-6.0.swift"])
        let changed = await repo.changedFiles(under: "installer/Sources")
        XCTAssertEqual(Set(changed), ["installer/Sources/shawn/main.swift", "installer/Sources/shawn/WIP.swift"], "the existing API is unchanged")
    }
}
