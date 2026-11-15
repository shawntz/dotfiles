import Foundation

/// Loads a config directory:
///
///     config/
///       installer.yaml      name, vars, remote repo
///       steps/*.yaml        one file per installer step, run in filename order
///       files/, skills/, fun/, cli.yaml ...   (read by the modules that own them)
public enum ConfigLoader {
    public struct Result: Sendable {
        public let config: InstallerConfig
        /// Non-fatal problems (warnings). Fatal problems are thrown as `ConfigError`.
        public let warnings: [ConfigIssue]
    }

    public static let metaFileName = "installer.yaml"
    public static let stepsDirectoryName = "steps"

    /// True when `directory` looks like a config directory.
    public static func isConfigDirectory(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(metaFileName).path)
    }

    public static func load(from root: URL, source: ConfigSource? = nil) throws -> Result {
        let collector = IssueCollector()
        let root = root.standardizedFileURL

        guard isConfigDirectory(root) else {
            throw ConfigError([.error("not a config directory (no \(metaFileName)) at \(root.path)")])
        }

        let meta = loadMeta(root: root, collector: collector)
        let steps = loadSteps(root: root, collector: collector)

        if steps.isEmpty && !collector.hasErrors {
            collector.add(.error("no step files found in \(stepsDirectoryName)/", at: SourceRef(file: stepsDirectoryName)))
        }

        if collector.hasErrors { throw ConfigError(collector.errors) }

        let config = InstallerConfig(root: root, meta: meta, steps: steps, source: source ?? .local(root.path))
        return Result(config: config, warnings: collector.issues.filter { $0.severity == .warning })
    }

    // MARK: installer.yaml

    private static func loadMeta(root: URL, collector: IssueCollector) -> ConfigMeta {
        let file = metaFileName
        var meta = ConfigMeta(schema: ShawnCore.schemaVersion, name: "Dotfiles")
        let value: YAMLValue?
        do {
            value = try YAML.parseFile(root.appendingPathComponent(file), displayName: file)
        } catch let error as YAMLParseError {
            collector.add(.error(error.message, at: SourceRef(file: error.file, line: error.line)))
            return meta
        } catch {
            collector.add(.error(String(describing: error), at: SourceRef(file: file)))
            return meta
        }
        guard let map = value?.map else {
            collector.add(.error("must be a mapping with at least 'name'", at: SourceRef(file: file)))
            return meta
        }
        let reader = MapReader(map: map, source: SourceRef(file: file), context: "installer", collector: collector)

        if let schema = reader.int("schema") {
            meta.schema = schema
            if schema > ShawnCore.schemaVersion {
                reader.error("this config needs a newer installer (config schema \(schema), this build understands \(ShawnCore.schemaVersion))", key: "schema")
            }
        }
        meta.name = reader.requiredString("name")
        meta.tagline = reader.string("tagline")

        if let remote = reader.reader("remote") {
            let repo = remote.requiredString("repo")
            let branch = remote.string("branch", default: "main")
            let path = remote.string("path", default: "installer/config")
            if !repo.isEmpty, repo.split(separator: "/").count != 2 {
                remote.error("'repo' must look like owner/name", key: "repo")
            }
            remote.finish()
            meta.remote = RemoteConfigRef(repo: repo, branch: branch, path: path)
        }

        for pair in reader.stringPairs("vars") {
            meta.vars[pair.key] = pair.value
        }
        reader.finish()
        return meta
    }

    // MARK: steps/*.yaml

    private static func loadSteps(root: URL, collector: IssueCollector) -> [StepConfig] {
        let directory = root.appendingPathComponent(stepsDirectoryName)
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            collector.add(.error("missing '\(stepsDirectoryName)/' directory", at: SourceRef(file: stepsDirectoryName)))
            return []
        }
        let stepFiles = names
            .filter { ($0.hasSuffix(".yaml") || $0.hasSuffix(".yml")) && !$0.hasPrefix(".") && !$0.hasPrefix("_") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var steps: [StepConfig] = []
        var seen: [String: String] = [:]
        for name in stepFiles {
            let relative = "\(stepsDirectoryName)/\(name)"
            guard let step = loadStep(url: directory.appendingPathComponent(name), relative: relative, collector: collector) else { continue }
            if let previous = seen[step.id] {
                collector.add(.error("step id '\(step.id)' is already used by \(previous)", at: SourceRef(file: relative)))
                continue
            }
            seen[step.id] = relative
            steps.append(step)
        }
        return steps
    }

    private static func loadStep(url: URL, relative: String, collector: IssueCollector) -> StepConfig? {
        let value: YAMLValue?
        do {
            value = try YAML.parseFile(url, displayName: relative)
        } catch let error as YAMLParseError {
            collector.add(.error(error.message, at: SourceRef(file: error.file, line: error.line)))
            return nil
        } catch {
            collector.add(.error(String(describing: error), at: SourceRef(file: relative)))
            return nil
        }
        guard let map = value?.map else {
            collector.add(.error("a step file must be a mapping with 'id', 'title' and 'items'", at: SourceRef(file: relative)))
            return nil
        }

        let reader = MapReader(map: map, source: SourceRef(file: relative), context: "step", collector: collector)
        let id = reader.requiredString("id")
        if !id.isEmpty, id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) == nil {
            reader.error("'id' may only contain lowercase letters, digits and dashes (got '\(id)')", key: "id")
        }
        let title = reader.requiredString("title")
        let subtitle = reader.string("subtitle")
        let mascot = reader.string("mascot")
        let enabled = reader.bool("enabled", default: true)
        let quips = reader.stringList("quips")

        var rawItems: [RawItem] = []
        let itemsLine = map.line(of: "items")
        for (index, element) in reader.list("items").enumerated() {
            guard let itemMap = element.map else {
                reader.error("item \(index + 1) must be a mapping such as '- brew: eza', not a \(element.typeName)", key: "items")
                continue
            }
            guard !itemMap.isEmpty else {
                reader.error("item \(index + 1) is empty", key: "items")
                continue
            }
            let line = itemMap.entries.first?.line ?? itemsLine
            rawItems.append(RawItem(map: itemMap, source: SourceRef(file: relative, line: line)))
        }
        reader.finish()

        guard !id.isEmpty else { return nil }
        return StepConfig(id: id, title: title.isEmpty ? id : title, subtitle: subtitle, mascot: mascot,
                          enabledByDefault: enabled, quips: quips, rawItems: rawItems, file: relative)
    }
}
