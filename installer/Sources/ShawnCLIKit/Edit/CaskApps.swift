import Foundation
import ShawnCore

/// The `app:` a cask item carries (`Slack.app`), so a copy that is already in /Applications (installed
/// by hand or by IT) counts as installed instead of making `brew install --cask` fail with "already an App".
enum CaskApps {
    /// The cask kind's option that names the app bundle.
    static let optionKey = "app"

    /// The app bundle each cask installs, from `brew info --cask --json=v2` (read-only, no auto-update).
    /// Empty when Homebrew is missing or does not know the casks.
    static func lookup(_ tokens: [String], context: CLIContext) async -> [String: String] {
        let brew = context.environment.brewExecutable
        guard !tokens.isEmpty, FileManager.default.isExecutableFile(atPath: brew) else { return [:] }
        let environment = context.environment.processEnvironment(overrides: [
            "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1",
        ])
        let result = await context.launcher.capture(ProcessRequest(brew, ["info", "--cask", "--json=v2"] + tokens, environment: environment, timeout: 60))
        guard result.succeeded else { return [:] }
        return parse(result.stdout)
    }

    /// token (and full tap-qualified token) → the first app bundle the cask installs. An app artifact is
    /// `["Foo.app"]`, or `["Foo.app", {"target": "Bar.app"}]` when Homebrew renames it on the way in.
    static func parse(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = object["casks"] as? [[String: Any]] else { return [:] }
        var apps: [String: String] = [:]
        for cask in casks {
            let artifacts = cask["artifacts"] as? [Any] ?? []
            let app = artifacts.lazy.compactMap { artifact -> String? in
                guard let parts = (artifact as? [String: Any])?["app"] as? [Any], let source = parts.first as? String else { return nil }
                let target = parts.dropFirst().compactMap { ($0 as? [String: Any])?["target"] as? String }.first
                return ((target ?? source) as NSString).lastPathComponent
            }.first
            guard let app else { continue }
            for key in ["token", "full_token"] {
                if let token = cask[key] as? String { apps[token] = app }
            }
        }
        return apps
    }

    /// True when an item of `kind` takes an `app:` option and the cask is not given one yet.
    static func wanted(kind: String, entries: [YAMLMap.Entry], registry: ActionRegistry) -> Bool {
        guard !entries.contains(where: { $0.key == optionKey }) else { return false }
        let raw = RawItem(map: YAMLMap(entries + [YAMLMap.Entry(key: optionKey, value: .string("Probe.app"))]), source: SourceRef(file: "probe"))
        guard case .success(let resolved) = registry.resolve(raw, stepID: "probe", index: 0) else { return false }
        return (resolved.action as? any PackageProviding)?.packageRef.manager == .cask
    }

    /// True when the step file's items of `kind` name their app (the file's convention, e.g. 04-apps.yaml).
    static func fileUsesApps(kind: String, text: String) -> Bool {
        guard let items = (try? YAML.parse(text))??.map?["items"]?.list else { return false }
        return items.contains { $0.map?.entries.first?.key == kind && $0.map?[optionKey] != nil }
    }
}
