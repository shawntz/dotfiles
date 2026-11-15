import Foundation
import ShawnCore
import XCTest
@testable import ActionsDev

final class DeviceFlowWatcherTests: XCTestCase {
    func testFirstCopyFormat() {
        let watcher = DeviceFlowWatcher()
        XCTAssertNil(watcher.feed(""))
        XCTAssertEqual(watcher.feed("! First copy your one-time code: 1A2B-C3D4"), .init(code: "1A2B-C3D4", url: nil))
        XCTAssertEqual(watcher.feed("Open this URL to continue in your web browser: https://github.com/login/device"),
                       .init(code: "1A2B-C3D4", url: URL(string: "https://github.com/login/device")))
        XCTAssertNil(watcher.feed("✓ Authentication complete."))
        XCTAssertNil(watcher.feed("- gh config set -h github.com git_protocol ssh"))
        XCTAssertNil(watcher.feed("✓ Logged in as shawntz"))
        XCTAssertEqual(watcher.login, "shawntz")
        XCTAssertNil(watcher.failure)
        XCTAssertFalse(watcher.savedInPlainText)
    }

    func testClipboardFormatAndWarnings() {
        let watcher = DeviceFlowWatcher()
        XCTAssertEqual(watcher.feed("! One-time code (A9A9-AA99) copied to clipboard")?.code, "A9A9-AA99")
        XCTAssertNil(watcher.feed("! One-time code (A9A9-AA99) copied to clipboard"), "the same code twice is not news")
        XCTAssertNil(watcher.feed("! Authentication credentials saved in plain text"))
        XCTAssertTrue(watcher.savedInPlainText)
    }

    func testWebFallbackHasOnlyAURL() {
        let watcher = DeviceFlowWatcher()
        let prompt = watcher.feed("Open this URL to continue in your web browser: https://example.ghe.com/login/oauth/authorize?client_id=x&state=y")
        XCTAssertNil(prompt?.code)
        XCTAssertEqual(prompt?.url?.host, "example.ghe.com")
        let attention = GitHubAction.attention(for: prompt!, host: "example.ghe.com", waiting: "15 minutes")
        XCTAssertNil(attention.code)
        XCTAssertTrue(attention.message.contains("browser"))
    }

    func testFailures() {
        let denied = DeviceFlowWatcher()
        _ = denied.feed("failed to authenticate via web browser: access_denied (access_denied)")
        XCTAssertEqual(denied.failure, "access_denied (access_denied)")

        let token = DeviceFlowWatcher()
        _ = token.feed("The value of the GH_TOKEN environment variable is being used for authentication.")
        XCTAssertTrue(token.failure?.contains("GH_TOKEN") == true)

        let offline = DeviceFlowWatcher()
        _ = offline.feed("error connecting to github.com")
        XCTAssertTrue(offline.failure?.contains("could not connect to github.com") == true)

        // An expired code is not a failure (it ends as needs-attention); a refusal is.
        XCTAssertTrue(GitHubAction.codeExpired("context deadline exceeded"))
        XCTAssertTrue(GitHubAction.codeExpired("the device code has expired (expired_token)"))
        XCTAssertFalse(GitHubAction.codeExpired("access_denied (access_denied)"))
        XCTAssertFalse(GitHubAction.codeExpired("could not connect to github.com; check the internet connection"))
    }

    func testAttentionCarriesCodeAndURL() {
        let attention = GitHubAction.attention(for: .init(code: "1A2B-C3D4", url: URL(string: "https://github.com/login/device")),
                                               host: "github.com", waiting: TimeLimit.describe(900))
        XCTAssertEqual(attention.title, "Sign in to GitHub (github.com)")
        XCTAssertEqual(attention.code, "1A2B-C3D4")
        XCTAssertEqual(attention.url, URL(string: "https://github.com/login/device"))
        XCTAssertTrue(attention.message.contains("15 minutes"), attention.message)
        XCTAssertEqual(TimeLimit.describe(2), "2 seconds")
        XCTAssertEqual(TimeLimit.describe(1), "1 second")
    }
}

final class GitHubStatusTests: XCTestCase {
    func testSignedIn() throws {
        let json = #"{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"shawntz","tokenSource":"keyring","scopes":"admin:public_key, gist, read:org, repo","gitProtocol":"ssh"}]}}"#
        let account = try XCTUnwrap(GitHubStatusParser.parse(json, host: "github.com"))
        XCTAssertTrue(account.isSignedIn)
        XCTAssertEqual(account.login, "shawntz")
        XCTAssertEqual(account.scopes, ["admin:public_key", "gist", "read:org", "repo"])
        XCTAssertEqual(account.gitProtocol, "ssh")
    }

    func testSignedOutAndOtherHosts() throws {
        XCTAssertNil(try GitHubStatusParser.parse(#"{"hosts":{}}"#, host: "github.com"))
        let other = #"{"hosts":{"example.ghe.com":[{"state":"success","active":true,"host":"example.ghe.com","login":"me","tokenSource":"keyring","scopes":"repo","gitProtocol":"https"}]}}"#
        XCTAssertNil(try GitHubStatusParser.parse(other, host: "github.com"))
    }

    func testPrefersTheActiveAccount() throws {
        let json = #"{"hosts":{"github.com":[{"state":"error","active":false,"host":"github.com","login":"old","tokenSource":"keyring","gitProtocol":"ssh"},{"state":"success","active":true,"host":"github.com","login":"new","tokenSource":"keyring","scopes":"repo","gitProtocol":"ssh"}]}}"#
        XCTAssertEqual(try GitHubStatusParser.parse(json, host: "github.com")?.login, "new")
    }

    func testMalformed() {
        XCTAssertThrowsError(try GitHubStatusParser.parse("unknown flag: --json", host: "github.com"))
    }

    func testScopeArithmetic() {
        let granted = ["admin:public_key", "gist", "read:org", "repo"]
        XCTAssertTrue(OAuthScopes.covers(granted, "write:public_key"))
        XCTAssertTrue(OAuthScopes.covers(granted, "read:public_key"))
        XCTAssertTrue(OAuthScopes.covers(granted, "repo:status"))
        XCTAssertTrue(OAuthScopes.covers(granted, "public_repo"))
        XCTAssertFalse(OAuthScopes.covers(granted, "write:ssh_signing_key"))
        XCTAssertFalse(OAuthScopes.covers(["write:public_key"], "admin:public_key"))
        XCTAssertTrue(OAuthScopes.covers(["write:org"], "read:org"))
        XCTAssertEqual(OAuthScopes.missing(required: ["write:public_key", "write:ssh_signing_key", "workflow", "workflow"], granted: granted),
                       ["write:ssh_signing_key", "workflow"])
        XCTAssertEqual(OAuthScopes.split("a, b,c  d"), ["a", "b", "c", "d"])
    }
}

final class SSHSupportTests: XCTestCase {
    func testPublicKeyParsingAndFingerprints() throws {
        let keys = gitHubHostKeyLines.compactMap(SSHPublicKey.init(line:))
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(keys.map(\.fingerprint), [
            "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
            "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
            "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
        ])
        let withComment = try XCTUnwrap(SSHPublicKey(line: gitHubHostKeyLines[0] + " me@example.com laptop\n"))
        XCTAssertEqual(withComment.comment, "me@example.com laptop")
        XCTAssertEqual(withComment.material, gitHubHostKeyLines[0])

        XCTAssertNil(SSHPublicKey(line: "ssh-rsa " + gitHubHostKeyLines[0].split(separator: " ")[1]), "type must match the blob")
        XCTAssertNil(SSHPublicKey(line: "ssh-ed25519 not-base64!"))
        XCTAssertNil(SSHPublicKey(line: "-----BEGIN OPENSSH PRIVATE KEY-----"))
    }

    func testFingerprintMatchesSSHKeygen() throws {
        let sandbox = DevSandbox()
        let key = sandbox.generateKey()
        let pub = try SSHPublicKey.read(URL(fileURLWithPath: key.path + ".pub"), display: "fixture")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-l", "-E", "sha256", "-f", key.path + ".pub"]
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(printed.contains(pub.fingerprint), "\(printed) vs \(pub.fingerprint)")
    }

    func testHostKeyVerification() {
        let real = gitHubHostKeyLines.compactMap(SSHPublicKey.init(line:))
        XCTAssertEqual(GitHubHostKeys.verify(real + [real[0]]), .trusted(real), "duplicates are dropped")

        let sandbox = DevSandbox()
        let impostor = try! SSHPublicKey.read(URL(fileURLWithPath: sandbox.generateKey().path + ".pub"), display: "x")
        guard case .rejected(let reason) = GitHubHostKeys.verify([real[0], impostor]) else { return XCTFail("must reject") }
        XCTAssertTrue(reason.contains(impostor.fingerprint), reason)
        XCTAssertEqual(GitHubHostKeys.verify([]), .rejected("no host keys were returned"))

        XCTAssertEqual(GitHubHostKeys.parseMeta(gitHubHostKeyLines.joined(separator: "\n") + "\n").count, 3)
        let scan = "# github.com:22 SSH-2.0-babeld\ngithub.com \(gitHubHostKeyLines[0])\nevil.com \(gitHubHostKeyLines[1])\n"
        XCTAssertEqual(GitHubHostKeys.parseKeyscan(scan, host: "github.com").map(\.material), [gitHubHostKeyLines[0]])
    }

    func testMarkedBlockInsertReplaceAndIdempotence() throws {
        let block = MarkedBlock(begin: "# >>> test >>>", end: "# <<< test <<<")
        XCTAssertEqual(try block.apply(body: ["a"], to: ""), "# >>> test >>>\na\n# <<< test <<<\n")

        // A new block goes at the end, after a blank line, so what the file already says keeps priority.
        let original = "Include ~/.orbstack/ssh/config\n\nHost work\n  User me\n"
        let inserted = try block.apply(body: ["a"], to: original)
        XCTAssertEqual(inserted, original + "\n# >>> test >>>\na\n# <<< test <<<\n")
        XCTAssertEqual(try block.apply(body: ["a"], to: inserted), inserted)

        let replaced = try block.apply(body: ["b", "c"], to: inserted)
        XCTAssertEqual(replaced, original + "\n# >>> test >>>\nb\nc\n# <<< test <<<\n")

        // No trailing newline: one is added, the rest of the file is untouched.
        XCTAssertEqual(try block.apply(body: ["a"], to: "Host work\n  User me"), "Host work\n  User me\n\n# >>> test >>>\na\n# <<< test <<<\n")
        // Already ends with a blank line (CRLF too): no second one.
        XCTAssertEqual(try block.apply(body: ["a"], to: "Host w\n\n"), "Host w\n\n# >>> test >>>\na\n# <<< test <<<\n")
        XCTAssertEqual(try block.apply(body: ["a"], to: "Host w\r\n\r\n"), "Host w\r\n\r\n# >>> test >>>\na\n# <<< test <<<\n")
        XCTAssertEqual(try block.apply(body: ["a"], to: "Host w\r\n"), "Host w\r\n\n# >>> test >>>\na\n# <<< test <<<\n")

        // A block the person moved stays where they put it.
        let moved = "# >>> test >>>\nold\n# <<< test <<<\nHost later\n"
        XCTAssertEqual(try block.apply(body: ["new"], to: moved), "# >>> test >>>\nnew\n# <<< test <<<\nHost later\n")

        // In the middle of a file without a trailing newline, CRLF and all.
        let middle = "Host a\r\n# >>> test >>>\nold\n# <<< test <<<\nHost z"
        XCTAssertEqual(try block.apply(body: ["new"], to: middle), "Host a\r\n# >>> test >>>\nnew\n# <<< test <<<\nHost z")

        XCTAssertThrowsError(try block.apply(body: [], to: "# >>> test >>>\nno end\n"))
        XCTAssertThrowsError(try block.apply(body: [], to: "# <<< test <<<\n# >>> test >>>\n"))
        XCTAssertThrowsError(try block.apply(body: [], to: "# >>> test >>>\n# <<< test <<<\n# >>> test >>>\n# <<< test <<<\n"))
    }

    /// On bytes, everything outside the block is kept whatever its encoding, and the block is UTF-8.
    func testMarkedBlockOnBytesKeepsWhatIsNotUTF8() throws {
        let block = MarkedBlock(begin: "# >>> ~/.ssh/id_ü >>>", end: "# <<< ~/.ssh/id_ü <<<")
        let latin1 = Data("# caf".utf8) + Data([0xE9]) + Data("\r\nHost w\n".utf8)
        let inserted = try block.apply(body: ["IdentityFile ~/.ssh/id_ü"], to: latin1)
        XCTAssertEqual(inserted, latin1 + Data("\n# >>> ~/.ssh/id_ü >>>\nIdentityFile ~/.ssh/id_ü\n# <<< ~/.ssh/id_ü <<<\n".utf8))
        XCTAssertEqual(try block.apply(body: ["IdentityFile ~/.ssh/id_ü"], to: inserted), inserted, "the block is found again")

        // Replaced in place: the bytes after it are kept too, even ones that are whitespace in Latin-1.
        let tail = Data("Host z\n# ".utf8) + Data([0xFF, 0xFE, 0x85, 0xA0])
        XCTAssertEqual(try block.apply(body: ["x"], to: inserted + tail),
                       latin1 + Data("\n# >>> ~/.ssh/id_ü >>>\nx\n# <<< ~/.ssh/id_ü <<<\n".utf8) + tail)

        // UTF-8 comes out exactly as the text form makes it.
        for text in ["", "Host é\n  User me\n", "Host w\r\n", "# ✓ done\nHost z"] {
            XCTAssertEqual(try block.apply(body: ["a"], to: Data(text.utf8)), Data(try block.apply(body: ["a"], to: text).utf8), text)
        }

        // A damaged block is described with the markers as they read.
        XCTAssertThrowsError(try block.apply(body: [], to: Data("# >>> ~/.ssh/id_ü >>>\n".utf8))) { error in
            XCTAssertEqual((error as? MarkedBlock.Unbalanced)?.description,
                           "expected exactly one '# >>> ~/.ssh/id_ü >>>' line followed by one '# <<< ~/.ssh/id_ü <<<' line, found 1 and 0")
        }
    }

    func testAllowedSigners() throws {
        let key = try XCTUnwrap(SSHPublicKey(line: gitHubHostKeyLines[0] + " comment"))
        let other = try XCTUnwrap(SSHPublicKey(line: gitHubHostKeyLines[2]))
        let line = "me@example.com namespaces=\"git\" \(key.material)"
        XCTAssertEqual(AllowedSigners.line(email: "me@example.com", key: key), line)

        XCTAssertEqual(AllowedSigners.updated("", email: "me@example.com", key: key), line + "\n")

        // Other people's and other keys' lines stay; ours is appended (newline added if missing).
        let existing = "# team keys\nfriend@example.com \(other.material)\nme@example.com namespaces=\"git\" \(other.material)"
        let appended = AllowedSigners.updated(existing, email: "me@example.com", key: key)
        XCTAssertEqual(appended, existing + "\n" + line + "\n")
        XCTAssertEqual(AllowedSigners.updated(appended, email: "me@example.com", key: key), appended, "idempotent")

        // The same email + key with other options is rewritten in place; duplicates of it go.
        let stale = "a@x.com \(other.material)\nME@example.com,work@example.com valid-after=\"20200101\" \(key.material) old comment\nz@x.com \(other.material)\nme@example.com \(key.material)\n"
        XCTAssertEqual(AllowedSigners.updated(stale, email: "me@example.com", key: key),
                       "a@x.com \(other.material)\n\(line)\nz@x.com \(other.material)\n")

        let quoted = AllowedSigners.Entry(line: "\"me@example.com\" namespaces=\"git,file\" \(key.material)")
        XCTAssertEqual(quoted?.principals, ["me@example.com"])
        XCTAssertEqual(quoted?.material, key.material)
        XCTAssertNil(AllowedSigners.Entry(line: "# comment"))
    }
}

final class ToolTests: XCTestCase {
    func testToolCommandRemovesAndSetsVariables() {
        let command = ToolCommand.make("/opt/tool/bin/gh", ["auth", "status"], unset: ["GH_TOKEN", "GH_HOST", "GH_TOKEN"],
                                       set: ["GH_HOST": "github.com", "NO_COLOR": "1"], display: "gh")
        // The tool itself runs (no env(1) wrapper), so errors and time-outs name it.
        XCTAssertEqual(command.executable, "/opt/tool/bin/gh")
        XCTAssertEqual(command.arguments, ["auth", "status"])
        XCTAssertEqual(command.environment, ["GH_HOST": "github.com", "NO_COLOR": "1"])
        XCTAssertEqual(command.unsetEnvironment, ["GH_TOKEN"], "a name that is also set is not removed")
        XCTAssertEqual(command.displayString, "gh auth status")
    }

    func testATimeOutNamesTheToolNotEnv() async throws {
        let sandbox = DevSandbox()
        let runner = CommandRunner(environment: sandbox.environment)
        let command = ToolCommand.make("/bin/sleep", ["5"], unset: ["CLAUDECODE"], display: "npx").timeout(1)
        do {
            try await runner.run(command)
            XCTFail("sleep 5 must be stopped after 1 second")
        } catch let error as CommandError {
            XCTAssertTrue(error.isTimeout, "\(error)")
            XCTAssertEqual(error.description, "npx 5 did not finish within 1 second")
            XCTAssertFalse(error.description.contains("/usr/bin/env"))
        }

        // Call sites that wait on the network add what to do about it.
        do {
            try await runner.run(command, hintIfTimedOut: "Check the network connection, then run this again")
            XCTFail("expected a time-out")
        } catch let error as ActionError {
            XCTAssertEqual(error.message, "npx 5 did not finish within 1 second")
            XCTAssertEqual(error.hint, "Check the network connection, then run this again")
        }
    }

    func testAVariableBothRemovedAndSetKeepsItsNewValue() async throws {
        var base = ProcessInfo.processInfo.environment
        base["GH_HOST"] = "evil.example.com"
        let sandbox = DevSandbox(baseEnvironment: base)
        let runner = CommandRunner(environment: sandbox.environment)
        let output = try await runner.runChecked(ToolCommand.make("/usr/bin/printenv", [], unset: ["GH_HOST"], set: ["GH_HOST": "github.com"],
                                                                  display: "printenv")).stdout
        XCTAssertTrue(output.contains("GH_HOST=github.com\n"), output)
        XCTAssertFalse(output.contains("evil.example.com"), output)
    }

    func testRemovedVariablesReallyDisappear() async throws {
        let sandbox = DevSandbox(baseEnvironment: ProcessInfo.processInfo.environment.merging(["CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli"]) { _, new in new })
        let runner = CommandRunner(environment: sandbox.environment)
        let command = ToolCommand.make("/usr/bin/printenv", [], unset: ToolCommand.agentSessionVariables(sandbox.environment),
                                       set: ["CLAUDE_CODE_PLUGIN_PREFER_HTTPS": "1"], display: "printenv")
        let output = try await runner.runChecked(command).stdout
        XCTAssertFalse(output.contains("CLAUDECODE="))
        XCTAssertFalse(output.contains("CLAUDE_CODE_ENTRYPOINT="))
        XCTAssertTrue(output.contains("CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1"))
        XCTAssertTrue(output.contains("HOME=\(sandbox.home.path)"))
    }

    func testGitIsNeverTheXcodeSelectShim() {
        let sandbox = DevSandbox()
        let candidates = GitTool.candidates(sandbox.environment)
        XCTAssertFalse(candidates.contains("/usr/bin/git"))
        XCTAssertEqual(candidates.first, sandbox.bin.appendingPathComponent("git").path, "a Homebrew git comes first")
        XCTAssertTrue(candidates.contains(GitTool.commandLineToolsGit))
        if let git = GitTool.locate(sandbox.environment) { XCTAssertNotEqual(git, "/usr/bin/git") }

        XCTAssertTrue(GitTool.isolationVariables(sandbox.environment).contains("GIT_CONFIG_GLOBAL"), "sandboxes never reach the real git config")
        var live = sandbox.environment
        live.isSandbox = false
        XCTAssertFalse(GitTool.isolationVariables(live).contains("XDG_CONFIG_HOME"), "a real Mac keeps the user's XDG setup")
    }
}

final class GitGlobalConfigTests: XCTestCase {
    func testParsesTheNulSeparatedList() {
        let output = "user.name\nTest Person\0core.bare\0url.git@github.com:.insteadof\nhttps://github.com/\0includeif.gitdir:~/Work/.path\n~/w\0"
        XCTAssertEqual(GitGlobalConfig.parse(output), [
            .init(key: "user.name", value: "Test Person"),
            .init(key: "core.bare", value: nil),
            .init(key: "url.git@github.com:.insteadof", value: "https://github.com/"),
            .init(key: "includeif.gitdir:~/Work/.path", value: "~/w"),
        ])
        XCTAssertEqual(GitGlobalConfig.parse("a.b\nline one\nline two\0"), [.init(key: "a.b", value: "line one\nline two")])
        XCTAssertEqual(GitGlobalConfig.parse(""), [])
    }

    func testKeyShapes() {
        XCTAssertEqual(GitGlobalConfig.normalize("Init.DefaultBranch"), "init.defaultbranch")
        XCTAssertEqual(GitGlobalConfig.normalize("includeIf.gitdir:~/Work/.Path"), "includeif.gitdir:~/Work/.path", "subsections keep their case")
        XCTAssertEqual(GitGlobalConfig.normalize("credential.https://github.com.helper"), "credential.https://github.com.helper")

        XCTAssertTrue(GitGlobalConfig.isInclude("include.path"))
        XCTAssertTrue(GitGlobalConfig.isInclude("includeIf.gitdir:~/work/.path"))
        XCTAssertFalse(GitGlobalConfig.isInclude("include.x.path"))
        XCTAssertFalse(GitGlobalConfig.isInclude("includeIf.path"))
        XCTAssertFalse(GitGlobalConfig.isInclude("user.path"))

        for key in ["url.git@github.com:.insteadOf", "url.x.pushInsteadOf", "safe.directory", "credential.helper",
                    "credential.https://github.com.helper", "remote.origin.fetch", "http.extraHeader"] {
            XCTAssertTrue(GitGlobalConfig.isList(key), key)
        }
        for key in ["user.name", "url.insteadOf", "include.path", "pull.rebase"] {
            XCTAssertFalse(GitGlobalConfig.isList(key), key)
        }
    }

    func testAnIncludeIsLastOnlyWithNothingButIncludesAfterIt() {
        let home = URL(fileURLWithPath: "/Users/me")
        let local = GitGlobalConfig.Entry(key: "include.path", value: "~/.gitconfig.local")
        let user = GitGlobalConfig.Entry(key: "user.name", value: "Me")
        let work = GitGlobalConfig.Entry(key: "includeif.gitdir:~/work/.path", value: "~/.gitconfig.work")
        let signing = GitGlobalConfig.Entry(key: "commit.gpgsign", value: "true")

        XCTAssertTrue(GitGlobalConfig(entries: [user, local]).includeIsLast("include.path", path: "~/.gitconfig.local", home: home))
        XCTAssertTrue(GitGlobalConfig(entries: [user, local, work]).includeIsLast("include.path", path: "~/.gitconfig.local", home: home),
                      "the person's own includes may follow it")
        XCTAssertFalse(GitGlobalConfig(entries: [local, signing]).includeIsLast("include.path", path: "~/.gitconfig.local", home: home))
        XCTAssertFalse(GitGlobalConfig(entries: [user]).includeIsLast("include.path", path: "~/.gitconfig.local", home: home))
        XCTAssertTrue(GitGlobalConfig(entries: [local, signing, .init(key: "include.path", value: "/Users/me/.gitconfig.local")])
            .includeIsLast("include.path", path: "~/.gitconfig.local", home: home), "the same file spelled out in full counts")
        XCTAssertEqual(GitGlobalConfig(entries: [local, signing, .init(key: "include.path", value: "/Users/me/.gitconfig.local"), local])
            .spellings(of: "~/.gitconfig.local", under: "include.path", home: home), ["~/.gitconfig.local", "/Users/me/.gitconfig.local"])
    }

    func testSectionsAreWrittenTheWayGitWritesThem() {
        XCTAssertEqual(GitGlobalConfig.section(for: "include.path", value: "~/.gitconfig.local"), "[include]\n\tpath = ~/.gitconfig.local\n")
        XCTAssertEqual(GitGlobalConfig.section(for: "includeIf.gitdir:~/my \"work\"/.path", value: "~/w"),
                       "[includeIf \"gitdir:~/my \\\"work\\\"/\"]\n\tpath = ~/w\n")
        XCTAssertEqual(GitGlobalConfig.quoted("plain"), "plain")
        XCTAssertEqual(GitGlobalConfig.quoted("has # hash"), "\"has # hash\"")
        XCTAssertEqual(GitGlobalConfig.quoted(" lead"), "\" lead\"")
        XCTAssertEqual(GitGlobalConfig.quoted("a\\b\"c\td\ne"), "a\\\\b\\\"c\\td\\ne")
    }

    func testFilesFollowGitsRules() {
        let sandbox = DevSandbox()
        let home = sandbox.home
        XCTAssertEqual(GitGlobalConfig.files(sandbox.environment), [home.appendingPathComponent(".config/git/config"), home.appendingPathComponent(".gitconfig")])
        let files = FileOps(environment: sandbox.environment)
        XCTAssertEqual(GitGlobalConfig.writeTarget(sandbox.environment, files: files), home.appendingPathComponent(".gitconfig"))
        sandbox.writeHome(".config/git/config", "[user]\n\tname = x\n")
        XCTAssertEqual(GitGlobalConfig.writeTarget(sandbox.environment, files: files), home.appendingPathComponent(".config/git/config"),
                       "with only the XDG file, git writes that one")
        sandbox.writeHome(".gitconfig", "")
        XCTAssertEqual(GitGlobalConfig.writeTarget(sandbox.environment, files: files), home.appendingPathComponent(".gitconfig"))

        var live = sandbox.environment
        live.isSandbox = false
        live.baseEnvironment["GIT_CONFIG_GLOBAL"] = "~/elsewhere/gitconfig"
        XCTAssertEqual(GitGlobalConfig.files(live), [home.appendingPathComponent("elsewhere/gitconfig")])
    }
}
