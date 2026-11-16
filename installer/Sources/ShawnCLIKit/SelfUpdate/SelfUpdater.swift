import Foundation
import ShawnCore

/// Keeps `shawn` current from GitHub (requirement 19).
///
/// With a checkout (`~/Developer/dotfiles`): one `git ls-remote` of the branch and the `shawn-v*` tags.
/// If the branch moved and the checkout is clean, on that branch, with no local commits, it is
/// fast-forwarded. If the Swift sources then differ from the ones the installed binary was built
/// from, or nothing records what it was built from, the binary is rebuilt, swapped in atomically,
/// and the caller re-executes it, so a command added on one Mac shows up on the next `shawn …` call
/// on every other Mac. A checkout ahead of the remote is rebuilt the same way as long as its unpushed
/// commits leave the Swift sources alone: the binary is only ever built from sources the remote has.
///
/// Without a checkout: the same ls-remote against the public repo; a moved branch refreshes the
/// cached remote config (YAML commands come from it), and a newer `shawn-v*` release is downloaded,
/// verified against its sha256 and swapped in.
///
/// One shawn at a time does this (`UpdateLock`); `--check` only reads. Being offline is silent; a remote
/// that answers with an error (a refused ssh key, a missing repository) is mentioned once a day.
/// Nothing here ever stops the command the user asked for.
struct SelfUpdater: Sendable {
    struct Request: Sendable {
        var checkout: URL?
        /// The Swift package inside the checkout (`installer`).
        var packagePath = "installer"
        /// The config folder (`config_path`), relative to the checkout or absolute inside it.
        var configPath = "installer/config"
        /// The command that runs next applies the whole setup config (`shawn sync`), so a pull does not end with a hint
        /// to run it.
        var appliesSetup = false
        /// From `installer.yaml` → `remote:`.
        var remote: RemoteConfigRef?
        var installedBinary: URL
        var currentVersion: String
        /// For `~`-abbreviated paths in notes.
        var home: URL
        /// Scratch space for unpacking a release.
        var temporaryDirectory: URL
        var mode: CLIConfig.SelfUpdateMode = .always
        /// `shawn update`: ignore the mode, the daily schedule and the failed-build and failed-download guards.
        var force = false
        /// `shawn update --check`: report only. Takes no lock and writes nothing.
        var checkOnly = false
        /// `shawn update --rebuild`: rebuild from the checkout even when cli.json says these sources are installed.
        var rebuild = false
        /// The macOS this Mac runs: its major version, and the whole version as people read it ("27.2").
        var macOSMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        var macOSName = MinimumMacOS.describe(ProcessInfo.processInfo.operatingSystemVersion)
    }

    struct Timeouts: Sendable {
        var lsRemote: TimeInterval = 3
        var fetch: TimeInterval = 20
        var merge: TimeInterval = 15
        var build: TimeInterval = 900
        var manifest: TimeInterval = 10
        var download: TimeInterval = 180
        var remoteConfig: TimeInterval = 10
    }

    enum Outcome: Equatable, Sendable {
        /// `self_update.mode: off`.
        case disabled
        /// No checkout and no `remote:` in installer.yaml: nothing to compare with.
        case nothingToCheck
        /// `self_update.mode: daily`, and the last check was less than a day ago.
        case notDue
        /// The remote did not answer (git's reason).
        case offline(String)
        /// Asking the remote failed, and not for want of a network (a refused ssh key, missing credentials, a missing
        /// repository, no git): what failed and what to do.
        case checkFailed(String)
        /// The remote answered, but fetching its new commits failed (git's reason).
        case fetchFailed(String)
        case upToDate
        /// Left alone on purpose: the checkout is being worked on, another shawn is updating, …
        case skipped(String)
        /// Fast-forwarded; shawn itself did not need rebuilding.
        case pulled(commits: Int)
        /// A new binary from source is in place.
        case rebuilt
        case buildFailed(String)
        /// Something newer exists, but this binary is not one to replace in place (app bundle, development
        /// build, unwritable folder).
        case notReplaced(String)
        /// A new binary was built or downloaded but could not be put in place.
        case installFailed(String)
        /// `--check`: what `shawn update` would do.
        case updateAvailable(String)
        case releaseInstalled(String)
        case releaseRejected(String)
        case downloadFailed(String)
    }

    struct Report: Equatable, Sendable {
        var outcome: Outcome
        /// The binary to re-execute (it changed under us).
        var restartWith: URL?
        /// Files under the config directory may have changed.
        var configChanged = false
        /// Commits fast-forwarded into the checkout on this run, whatever then happened to the binary.
        var pulledCommits = 0
    }

    /// Paths (relative to the package) whose change means the binary must be rebuilt.
    static let sourcePaths = ["Sources", "Package.swift", "Package.resolved"]
    static let product = "shawn"

    let git: any GitClient
    let builder: any Builder
    let releases: any ReleaseSource
    let remoteConfig: any RemoteConfigRefreshing
    let clock: any Clock
    let store: any SelfUpdateStateStoring
    let launcher: any ProcessLaunching
    var timeouts = Timeouts()
    /// One-line notes the user should see (also in automatic mode).
    let note: @Sendable (String) -> Void
    /// Extra narration for `shawn update`.
    let detail: @Sendable (String) -> Void

    private enum Source {
        case checkout(URL)
        case releases(RemoteConfigRef)
    }

    func run(_ request: Request) async -> Report {
        if !request.force {
            switch request.mode {
            case .off:
                return Report(outcome: .disabled)
            case .daily:
                if let last = store.load().lastCheck, last.isLessThanADay(before: clock.now()) {
                    return Report(outcome: .notDue)
                }
            case .always:
                break
            }
        }
        let source: Source
        if let checkout = request.checkout, FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path) {
            source = .checkout(checkout)
        } else if let remote = request.remote {
            source = .releases(remote)
        } else {
            detail("no checkout and no 'remote:' in installer.yaml, so there is nothing to check.")
            return Report(outcome: .nothingToCheck)
        }

        var lock: UpdateLock?
        if !request.checkOnly {
            switch store.lockUpdates() {
            case .acquired(let held):
                lock = held
            case .busy(let pid, let activity):
                let reason = UpdateLock.describe(pid: pid, activity: activity)
                // Worth a line when the user asked, or when the other one is busy with something slow.
                if request.force {
                    note("skipped self-update: \(reason). Try again when it is done")
                } else if activity == .rebuilding || activity == .downloading {
                    note("skipped self-update: \(reason); this run uses the current version")
                } else {
                    detail("skipped self-update: \(reason).")
                }
                return Report(outcome: .skipped(reason))
            case .unavailable(let why):
                detail("\(why); updating without coordinating with other shawn processes.")
            }
        }
        defer { lock?.release() }

        switch source {
        case .checkout(let checkout):
            return await fromCheckout(checkout, request, lock: lock)
        case .releases(let remote):
            return await fromRelease(remote, request, lock: lock)
        }
    }

    // MARK: Checkout

    private func fromCheckout(_ checkout: URL, _ request: Request, lock: UpdateLock?) async -> Report {
        let repo = GitRepo(root: checkout, git: git)
        let place = PathExpansion.abbreviate(checkout.path, home: request.home)
        let current = await repo.currentBranch()
        let configured = request.remote?.branch ?? current ?? "main"
        let remote = await repo.remoteName(for: configured)

        detail("checking \(remote)/\(configured) and shawn releases…")
        let listing: RemoteRefs
        switch await repo.lsRemote(remote, patterns: ["HEAD", "refs/heads/\(configured)", "refs/tags/\(VersionNumber.tagPrefix)*"],
                                   timeout: timeouts.lsRemote) {
        case .success(let refs):
            listing = refs
        case .failure(let failure) where failure.noAnswer:
            detail("could not reach \(remote) (\(failure)). Offline? Nothing changed.")
            return Report(outcome: .offline(failure.message))
        case .failure(let failure):
            return checkFailed("couldn't check \(remote) for updates: \(ActionError.sentence("\(failure)")) 'git ls-remote \(remote)' must work in \(place) without a prompt",
                               request: request)
        }
        var state = store.load()
        state.lastCheck = clock.now()
        let release = VersionNumber.latestTag(in: listing.refs)
        state.latestTag = release?.tag
        defer { if !request.checkOnly { store.save(state.keepingRaisedNotes()) } }
        func done(_ report: Report) -> Report { finish(report, release: release, request: request, state: &state) }

        // The configured branch; or, when the remote no longer has it but names another default branch,
        // that one (the default branch was renamed, say master → main). Otherwise this Mac would never
        // see the commit that changes `remote.branch` in installer.yaml.
        var branch = configured
        var renameLocalBranch = false
        let remoteHead: String
        if let sha = listing.refs["refs/heads/\(configured)"] {
            remoteHead = sha
        } else if let renamed = listing.defaultBranch, renamed != configured, let sha = listing.refs["HEAD"] {
            detail("\(remote) has no branch '\(configured)' any more; following its default branch '\(renamed)'.")
            branch = renamed
            remoteHead = sha
            renameLocalBranch = current == configured
        } else {
            let reason = "\(remote) has no branch '\(configured)'"
            noteDaily("missing-branch", "skipped self-update: \(reason). Set remote.branch in installer.yaml to the branch \(place) follows",
                      state: &state, request: request)
            state.lastResult = "skipped: \(reason)"
            return done(Report(outcome: .skipped(reason)))
        }
        state.lastRemoteCommit = remoteHead
        guard let head = await repo.head() else {
            state.lastResult = "the checkout has no commits"
            return done(Report(outcome: .skipped("the checkout has no commits")))
        }

        let package = request.packagePath
        let sourcePaths = Self.sourcePaths.map { package.isEmpty ? $0 : "\(package)/\($0)" }
        var report = Report(outcome: .upToDate)
        // The remote's commit when the checkout is ahead of it: the binary is still only built from sources it has.
        var ahead: Ahead?

        if remoteHead != head {
            // These reasons last until the user does something about the checkout, and this runs before every
            // command. So each reason is said when it starts, and again once a day while it lasts.
            func skip(_ topic: String, _ reason: String) -> Report {
                noteDaily("skipped-\(topic)", "skipped self-update: \(reason)", state: &state, request: request)
                state.lastResult = "skipped: \(reason)"
                return done(Report(outcome: .skipped(reason)))
            }
            if current != branch && !renameLocalBranch {
                return skip("branch", "\(place) is on \(current.map { "'\($0)'" } ?? "a detached HEAD"), not '\(branch)'")
            }
            // An earlier run may have fetched the remote's commit already (and been unable to merge it).
            let fetchedBefore = await repo.hasCommit(remoteHead)
            if fetchedBefore, await repo.isAncestor(remoteHead, of: head) {
                detail("\(branch) is ahead of \(remote)/\(branch) (unpushed commits), so there is nothing to pull.")
                state.lastResult = "ahead of \(remote)/\(branch)"
                ahead = Ahead(remote: remote, branch: branch, commit: remoteHead)
            } else {
                if await repo.hasTrackedChanges() {
                    return skip("uncommitted", "\(place) has uncommitted changes")
                }
                let diverged = renameLocalBranch
                    ? "\(remote)'s default branch '\(branch)' does not contain the commits on '\(configured)' in \(place)"
                    : "local commits on \(branch) are not on \(remote) yet"
                // With the commit here, even --check can tell that it does not fast-forward.
                if fetchedBefore, !(await repo.isAncestor(head, of: remoteHead)) {
                    return skip("diverged", diverged)
                }
                if request.checkOnly {
                    let behind = renameLocalBranch
                        ? "\(remote) renamed '\(configured)' to '\(branch)', which has new commits (\(String(remoteHead.prefix(7))))"
                        : "\(remote)/\(branch) has new commits (\(String(remoteHead.prefix(7))))"
                    note("\(behind). Run 'shawn update' to pull them")
                    return done(Report(outcome: .updateAvailable(behind)))
                }
                lock?.announce(.pulling)
                if !fetchedBefore {
                    let fetched = await repo.fetch(remote, branch: branch, timeout: timeouts.fetch)
                    guard fetched.succeeded else {
                        let reason = GitFailure(fetched, timeout: timeouts.fetch).message
                        noteDaily("fetch-failed", "couldn't fetch \(remote)/\(branch): \(reason)", about: Self.stablePart(reason), state: &state, request: request)
                        state.lastResult = "fetch failed: \(reason)"
                        return done(Report(outcome: .fetchFailed(reason)))
                    }
                    guard await repo.isAncestor(head, of: remoteHead) else {
                        return skip("diverged", diverged)
                    }
                }
                if renameLocalBranch {
                    if await repo.branchExists(branch) {
                        return skip("rename", "\(remote) renamed '\(configured)' to '\(branch)', but \(place) already has a '\(branch)' branch. Switch to it with 'git switch \(branch)'")
                    }
                    let renamed = await repo.renameBranch(configured, to: branch, tracking: remote)
                    guard renamed.succeeded else {
                        return skip("rename", "could not rename '\(configured)' to '\(branch)' in \(place): \(GitFailure(renamed, timeout: 30))")
                    }
                    note("\(remote) renamed '\(configured)' to '\(branch)'; renamed the branch in \(place) to match")
                }
                let merged = await repo.fastForward(to: remoteHead, timeout: timeouts.merge)
                guard merged.succeeded else {
                    let inTheWay = GitRepo.filesInTheWay(merged)
                    if inTheWay.isEmpty {
                        return skip("merge", "could not fast-forward \(place): \(GitFailure(merged, timeout: timeouts.merge))")
                    }
                    return skip("in-the-way", "pulling \(remote)/\(branch) would overwrite \(Self.list(inTheWay)) in \(place). Move or remove "
                                + (inTheWay.count == 1 ? "it" : "them") + ", then run 'shawn update'")
                }
                let count = await repo.commitCount(from: head, to: remoteHead) ?? 1
                note("pulled \(count) new commit\(count == 1 ? "" : "s") into \(place) from \(remote)/\(branch)")
                // New commands in cli.yaml work from the next call on. Steps, files and skills only describe this
                // Mac once they are applied, and nothing applies them behind the user's back.
                if !request.appliesSetup, await repo.changed(from: head, to: remoteHead, under: Self.setupPaths(config: request.configPath)) {
                    note("the setup config changed. Run 'shawn sync' to apply it to this Mac")
                }
                report = Report(outcome: .pulled(commits: count), configChanged: true, pulledCommits: count)
                state.lastResult = "pulled \(count) commit\(count == 1 ? "" : "s")"
            }
        } else {
            detail("\(remote)/\(branch) is at \(String(head.prefix(7))), same as your checkout.")
            state.lastResult = "up to date"
        }

        // The checkout matches the remote, or is ahead of it. Is the binary built from these sources?
        if var rebuild = await rebuildIfNeeded(repo: repo, request: request, sourcePaths: sourcePaths, ahead: ahead, state: &state, place: place, lock: lock) {
            rebuild.configChanged = report.configChanged
            rebuild.pulledCommits = report.pulledCommits
            return done(rebuild)
        }
        return done(report)
    }

    /// The remote's branch, when the checkout has unpushed commits on top of it.
    private struct Ahead {
        var remote: String
        var branch: String
        var commit: String
    }

    private func rebuildIfNeeded(repo: GitRepo, request: Request, sourcePaths: [String], ahead: Ahead?, state: inout SelfUpdateState,
                                 place: String, lock: UpdateLock?) async -> Report? {
        guard let head = await repo.head(), let tree = await repo.contentID(of: sourcePaths, at: head) else { return nil }
        let why: String
        if request.rebuild {
            why = "a rebuild was asked for"
        } else {
            switch await installedProvenance(repo: repo, request: request, sourcePaths: sourcePaths) {
            case .known(let built, _) where built == tree:
                return nil
            case .known:
                why = "the Swift sources changed"
            case .unknown:
                why = "nothing records which sources this shawn was built from"
            }
        }

        if let refusal = BinaryReplacement.refusal(for: request.installedBinary) {
            let reason = "\(why), but this shawn is not replaced in place: \(refusal)"
            detail(reason + ".")
            state.lastResult = "not replaced: \(refusal)"
            return Report(outcome: .notReplaced(reason))
        }
        // Unpushed commits that change the Swift sources are work in progress, like uncommitted changes: the shawn every
        // shell runs is only built from sources the remote has. Unpushed commits that leave them alone change nothing.
        // Said only by `shawn update`: the developer committing on this Mac knows, and is not told on every call.
        if let ahead, await repo.contentID(of: sourcePaths, at: ahead.commit) != tree {
            let reason = "\(place) has unpushed commits on \(ahead.branch) that change the Swift sources; shawn is only rebuilt from "
                + "sources on \(ahead.remote). Push them, then run 'shawn update\(request.rebuild ? " --rebuild" : "")'"
            detail("\(why), but shawn is not rebuilt from unpushed commits.")
            state.lastResult = "skipped rebuild: unpushed commits change the Swift sources"
            return Report(outcome: .skipped(reason))
        }
        if let unfit = await unfitToBuild(repo: repo, request: request, place: place) {
            // A new file in the list needs the same fix as the first, so only another kind of reason is news.
            noteDaily("rebuild-unfit", "skipped rebuilding shawn: \(unfit.reason)", about: unfit.kind, state: &state, request: request)
            state.lastResult = "skipped rebuild: \(unfit.reason)"
            return Report(outcome: .skipped(unfit.reason))
        }
        if state.failedBuildTree == tree && !request.force {
            noteDaily("rebuild-failed", "\(why), but the last rebuild failed. Run 'shawn update' to try again", state: &state, request: request)
            return Report(outcome: .buildFailed("the last rebuild of these sources failed"))
        }
        if request.checkOnly {
            note("\(why). Run 'shawn update' to rebuild shawn")
            return Report(outcome: .updateAvailable("a rebuild of shawn at \(String(head.prefix(7))) (\(why))"))
        }

        lock?.announce(.rebuilding)
        note("\(why). Rebuilding shawn (swift build, about a minute)…")
        let package = request.packagePath.isEmpty ? repo.root : repo.root.appendingPathComponent(request.packagePath)
        switch await builder.build(package: package, product: Self.product, timeout: timeouts.build) {
        case .failure(let failure):
            state.failedBuildTree = tree
            state.lastResult = "rebuild failed"
            note("couldn't rebuild shawn (\(failure.message)); keeping the current version")
            return Report(outcome: .buildFailed(failure.message))
        case .success(let binary):
            do {
                try BinaryReplacement.replace(request.installedBinary, withContentsOf: binary)
            } catch {
                state.failedBuildTree = tree
                state.lastResult = "could not install the rebuilt shawn"
                note("couldn't install the rebuilt shawn (\(error)); keeping the current version")
                return Report(outcome: .installFailed("\(error)"))
            }
            // The version of the binary just built is its own to tell: this process is the old one.
            store.recordInstall(.known(sourceTree: tree, commit: head), version: nil, source: binary.path, date: clock.now())
            state.failedBuildTree = nil
            state.lastResult = "rebuilt at \(String(head.prefix(7)))"
            note("rebuilt at \(String(head.prefix(7)))" + (request.force ? "" : ". Restarting with the new version"))
            return Report(outcome: .rebuilt, restartWith: request.installedBinary)
        }
    }

    /// What the installed binary was built from: cli.json's record, else the sources at the tag of the running
    /// version (`shawn-v<version>`) when this checkout has that tag. Never the checkout's HEAD: a binary that an
    /// older app installed, or that was copied in by hand, says nothing about the sources checked out here.
    private func installedProvenance(repo: GitRepo, request: Request, sourcePaths: [String]) async -> BuildProvenance {
        if let recorded = store.installedSourceTree() { return .known(sourceTree: recorded, commit: nil) }
        let tag = VersionNumber.tagPrefix + request.currentVersion
        if let tagged = await repo.tagCommit(tag), let tree = await repo.contentID(of: sourcePaths, at: tagged) {
            detail("cli.json does not say which sources shawn was built from; going by \(tag).")
            return .known(sourceTree: tree, commit: tagged)
        }
        return .unknown
    }

    /// Why the checkout is not fit to build the installed shawn from right now, or nil. SwiftPM compiles every
    /// file in a target's folder, tracked or not, so a file someone is still writing would end up in the binary
    /// every shell runs (and a broken one would fail the build for sources that are fine). `kind` tells the reasons
    /// apart without the file names.
    private func unfitToBuild(repo: GitRepo, request: Request, place: String) async -> (kind: String, reason: String)? {
        if await repo.hasTrackedChanges() { return ("uncommitted", "\(place) has uncommitted changes") }
        let prefix = request.packagePath.isEmpty ? "" : request.packagePath + "/"
        guard let untracked = await repo.untrackedFiles(under: [prefix + "Sources", prefix + "Package*"]) else {
            return ("status", "could not read the status of \(place)")
        }
        if untracked.isEmpty { return nil }
        return ("untracked", "\(place) has untracked files in the Swift package (\(Self.list(untracked))). Commit or remove them")
    }

    // MARK: Releases (no checkout)

    private func fromRelease(_ remote: RemoteConfigRef, _ request: Request, lock: UpdateLock?) async -> Report {
        let url = "https://github.com/\(remote.repo).git"
        detail("checking \(remote.repo) (\(remote.branch)) and shawn releases…")
        let listing: RemoteRefs
        switch await GitRepo.lsRemote(git: git, in: nil, remote: url,
                                      patterns: ["HEAD", "refs/heads/\(remote.branch)", "refs/tags/\(VersionNumber.tagPrefix)*"],
                                      timeout: timeouts.lsRemote) {
        case .success(let refs):
            listing = refs
        case .failure(let failure) where failure.noAnswer:
            detail("could not reach github.com (\(failure)). Offline? Nothing changed.")
            return Report(outcome: .offline(failure.message))
        case .failure(let failure):
            return checkFailed("couldn't check \(remote.repo) on GitHub for updates: \(ActionError.sentence("\(failure)")) 'git ls-remote \(url)' must work without a prompt "
                               + "(remote.repo in installer.yaml must name a public repository)", request: request)
        }
        var state = store.load()
        state.lastCheck = clock.now()
        defer { if !request.checkOnly { store.save(state.keepingRaisedNotes()) } }
        var report = Report(outcome: .upToDate)
        state.lastResult = "up to date"

        if let head = listing.refs["refs/heads/\(remote.branch)"] {
            if head != state.lastRemoteCommit, !request.checkOnly {
                if let root = await remoteConfig.refresh(timeout: timeouts.remoteConfig) {
                    // The branch also moves for commits that leave the config alone (a Brewfile update, say).
                    // The copy of the commit before is usually still in the cache to compare with.
                    let same = state.remoteConfigRoot.map { $0 != root.path && FileManager.default.contentsEqual(atPath: $0, andPath: root.path) } ?? false
                    state.remoteConfigRoot = root.path
                    state.lastRemoteCommit = head
                    report.configChanged = !same
                    if same {
                        detail("\(remote.repo) is at \(String(head.prefix(7))) now; its config did not change.")
                    } else {
                        note("picked up the latest config (\(String(head.prefix(7))))" + (request.appliesSetup ? "" : ". 'shawn sync' applies setup changes to this Mac"))
                    }
                } else {
                    detail("the newer config could not be fetched; using the one on disk.")
                }
            }
        } else if let renamed = listing.defaultBranch, renamed != remote.branch {
            noteDaily("missing-branch", "\(remote.repo) has no branch '\(remote.branch)' (its default is now '\(renamed)'), so the config on this Mac "
                      + "is not refreshed until installer.yaml says remote.branch: \(renamed)", state: &state, request: request)
        }

        guard let release = VersionNumber.latestTag(in: listing.refs) else {
            detail("no shawn releases published yet.")
            return report
        }
        state.latestTag = release.tag
        guard VersionNumber.isNewer(release.version, than: request.currentVersion) else {
            detail("latest release is \(release.version); you have \(request.currentVersion).")
            return report
        }
        let available = "version \(release.version) is out (you have \(request.currentVersion))"
        if let refusal = BinaryReplacement.refusal(for: request.installedBinary) {
            let reason = "\(available), but this shawn is not replaced in place: \(refusal)"
            noteDaily("not-replaced", reason, state: &state, request: request)
            state.lastResult = "\(release.version) available; not replaced: \(refusal)"
            return Report(outcome: .notReplaced(reason), configChanged: report.configChanged)
        }
        // The new shawn checks the macOS version when it starts. Installed on an older macOS it would refuse every
        // command, 'shawn update' among them, so the one that works stays. The reason lasts until macOS is updated:
        // it is said once a day, and the manifest that gave it is not fetched again for the same release.
        func tooNew(needs needed: Int) -> Report {
            let reason = "shawn \(release.version) needs macOS \(needed) or later, and this Mac runs macOS \(request.macOSName)"
            state.releaseTooNew = SelfUpdateState.ReleaseTooNew(tag: release.tag, minimumMacOS: needed)
            state.lastResult = "\(release.version) is out; it needs macOS \(needed)"
            noteDaily("release-needs-macos", "\(reason); keeping \(request.currentVersion)", about: reason, state: &state, request: request)
            return Report(outcome: .skipped(reason), configChanged: report.configChanged)
        }
        if let known = state.releaseTooNew, known.tag == release.tag, request.macOSMajor < known.minimumMacOS {
            return tooNew(needs: known.minimumMacOS)
        }
        // Another release came out, or macOS was updated.
        state.releaseTooNew = nil

        if request.checkOnly {
            // Only the manifest says which macOS the release needs. It is a few hundred bytes.
            if let manifest = try? await releases.manifest(repo: remote.repo, tag: release.tag, timeout: timeouts.manifest),
               let needed = manifest.minimumMacOS, request.macOSMajor < needed {
                return tooNew(needs: needed)
            }
            note("\(available). Run 'shawn update'")
            return Report(outcome: .updateAvailable("shawn \(release.version)"), configChanged: report.configChanged)
        }
        if !request.force, state.failedRelease == release.tag, let failedAt = state.failedReleaseAt,
           failedAt.isLessThanADay(before: clock.now()) {
            let reason = "the download of shawn \(release.version) failed less than a day ago"
            // The failed download was said when it happened; until it is tried again this is only worth a detail line.
            detail("\(available); \(reason). Run 'shawn update' to try again")
            return Report(outcome: .skipped(reason), configChanged: report.configChanged)
        }
        func failed(_ result: String) {
            state.failedRelease = release.tag
            state.failedReleaseAt = clock.now()
            state.lastResult = result
        }

        func downloadFailed(_ error: Error) -> Report {
            note("couldn't download shawn \(release.version) (\(error)); keeping \(request.currentVersion)")
            failed("download failed: \(error)")
            return Report(outcome: .downloadFailed("\(error)"), configChanged: report.configChanged)
        }
        let manifest: ReleaseManifest
        do {
            manifest = try await releases.manifest(repo: remote.repo, tag: release.tag, timeout: timeouts.manifest)
        } catch {
            return downloadFailed(error)
        }
        if let needed = manifest.minimumMacOS, request.macOSMajor < needed {
            return tooNew(needs: needed)
        }
        lock?.announce(.downloading)
        note("\(available). Downloading…")
        let data: Data
        do {
            data = try await releases.download(manifest.url, timeout: timeouts.download)
        } catch {
            return downloadFailed(error)
        }
        let actual = Checksum.sha256(data)
        guard actual == manifest.sha256.lowercased() else {
            let reason = "checksum mismatch (expected \(manifest.sha256.prefix(12))…, got \(actual.prefix(12))…)"
            note("rejected shawn \(manifest.version): \(reason); keeping \(request.currentVersion)")
            failed("rejected \(manifest.version): checksum mismatch")
            return Report(outcome: .releaseRejected(reason), configChanged: report.configChanged)
        }
        do {
            let binary = try await extractBinary(from: data, scratch: request.temporaryDirectory)
            try BinaryReplacement.replace(request.installedBinary, with: binary)
        } catch {
            note("couldn't install shawn \(manifest.version) (\(error)); keeping \(request.currentVersion)")
            failed("could not install \(manifest.version): \(error)")
            return Report(outcome: .installFailed("\(error)"), configChanged: report.configChanged)
        }
        store.recordInstall(manifest.provenance, version: manifest.version, source: manifest.url.absoluteString, date: clock.now())
        state.failedRelease = nil
        state.failedReleaseAt = nil
        state.lastResult = "updated to \(manifest.version)"
        note("updated shawn \(request.currentVersion) → \(manifest.version)" + (request.force ? "" : ". Restarting with the new version"))
        return Report(outcome: .releaseInstalled(manifest.version), restartWith: request.installedBinary, configChanged: report.configChanged)
    }

    /// The release asset is a `.tar.gz` holding `shawn` (or the bare binary).
    private func extractBinary(from data: Data, scratch: URL) async throws -> Data {
        guard data.starts(with: [0x1F, 0x8B]) else { return data }
        let work = scratch.appendingPathComponent("shawn-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("release.tar.gz")
        try data.write(to: archive)
        // bsdtar refuses absolute paths and `..` in entry names by default.
        let unpacked = await launcher.capture(ProcessRequest("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path],
                                                             environment: ["PATH": "/usr/bin:/bin"], timeout: 60))
        guard unpacked.succeeded else { throw BuildFailure(message: "could not unpack the release: \(unpacked.tail(1))") }
        let enumerator = FileManager.default.enumerator(at: work, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            // A regular file only: a link named shawn would point at some other file on this Mac.
            guard url.lastPathComponent == Self.product,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isExecutableFile(atPath: url.path),
                  let binary = FileManager.default.contents(atPath: url.path) else { continue }
            return binary
        }
        throw BuildFailure(message: "the release archive has no '\(Self.product)' executable")
    }

    // MARK: Notes

    /// A newer release tag than the running version is mentioned once a day while it lasts, and at once when a newer
    /// one comes out. A run that is about to restart into a new binary leaves it out.
    private func finish(_ report: Report, release: (tag: String, version: String)?, request: Request, state: inout SelfUpdateState) -> Report {
        guard let release else {
            detail("no shawn releases published yet.")
            return report
        }
        if report.restartWith == nil, VersionNumber.isNewer(release.version, than: request.currentVersion) {
            noteDaily("release-out", "version \(release.version) is out (you have \(request.currentVersion))", state: &state, request: request)
            return report
        }
        detail("latest release is \(release.version); you have \(request.currentVersion).")
        // This run restarts into a new binary, which may be that release. The note on the release stays as it was.
        if report.restartWith != nil { state.raised.insert("release-out") }
        return report
    }

    /// The remote answered the update check with an error, or git could not ask it. Unlike being offline that does not
    /// pass by itself, and a silent failure would stop self-update for good, so it is said (once a day). It does not
    /// count as a check. The notes on the other topics stay as they were, because this run did not get to their checks.
    private func checkFailed(_ reason: String, request: Request) -> Report {
        var state = store.load()
        noteDaily("check-failed", reason, about: Self.stablePart(reason), state: &state, request: request)
        if !request.checkOnly { store.save(state) }
        return Report(outcome: .checkFailed(reason))
    }

    /// A note for a problem that persists between calls. It is said when it is news, and is a detail line otherwise.
    /// News is a topic that the last finished check did not raise, a reason other than the one said last (`about`, the
    /// text by default), or a day since it was said. `shawn update` always says it. The topic counts as raised either
    /// way, so the saved state keeps its note (`SelfUpdateState.keepingRaisedNotes`).
    private func noteDaily(_ topic: String, _ text: String, about reason: String? = nil, state: inout SelfUpdateState, request: Request) {
        let now = clock.now()
        let reason = reason ?? text
        state.raised.insert(topic)
        if !request.force, let last = state.noted?[topic], last.reason == reason, last.at.isLessThanADay(before: now) {
            detail(text)
            return
        }
        note(text)
        state.noted = (state.noted ?? [:]).merging([topic: SelfUpdateState.Noted(reason: reason, at: now)]) { $1 }
    }

    /// What `shawn sync` applies: everything in the config folder `config` except the parts shawn reads on every
    /// call anyway (its own commands, and the quotes and characters).
    static func setupPaths(config: String) -> [String] {
        var config = config
        while config.count > 1, config.hasSuffix("/") { config.removeLast() }
        return [config, ":(exclude)\(config)/cli.yaml", ":(exclude)\(config)/fun"]
    }

    /// A git failure without the numbers in it (curl's "after 3001 ms", byte counts, the address a host name resolved
    /// to), which change from one call to the next while the cause stays the same.
    static func stablePart(_ reason: String) -> String {
        reason.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
    }

    /// "a", "a and b", "a, b and 3 more".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return "\(items[0]), \(items[1]) and \(items.count - 2) more"
        }
    }
}
