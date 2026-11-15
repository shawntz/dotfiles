import XCTest
@testable import ShawnCore

final class YAMLValueTests: XCTestCase {
    func testScalarTypingKeepsRawText() throws {
        let value = try XCTUnwrap(YAML.parse("""
        name: eza
        count: 42
        ratio: 1.10
        mode: 0644
        on: yes
        quoted: "true"
        nothing: ~
        version: 7zip
        """))
        let map = try XCTUnwrap(value.map)
        XCTAssertEqual(map["name"]?.string, "eza")
        XCTAssertEqual(map["count"]?.int, 42)
        XCTAssertEqual(map["count"]?.string, "42")
        XCTAssertEqual(map["ratio"]?.double, 1.1)
        XCTAssertEqual(map["ratio"]?.string, "1.10", "raw text must survive numeric typing")
        XCTAssertEqual(map["mode"]?.string, "0644", "octal-looking modes stay readable as text")
        XCTAssertEqual(map["on"]?.bool, true)
        XCTAssertNil(map["quoted"]?.bool, "quoted scalars are always strings")
        XCTAssertEqual(map["quoted"]?.string, "true")
        XCTAssertEqual(map["nothing"]?.isNull, true)
        XCTAssertNil(map["nothing"]?.string)
        XCTAssertEqual(map["version"]?.string, "7zip")
    }

    func testMapsPreserveOrderAndLines() throws {
        let map = try XCTUnwrap(YAML.parse("zeta: 1\nalpha: 2\nmiddle: 3\n")?.map)
        XCTAssertEqual(map.keys, ["zeta", "alpha", "middle"])
        XCTAssertEqual(map.line(of: "alpha"), 2)
    }

    func testListsAndStringListPromotion() throws {
        let map = try XCTUnwrap(YAML.parse("many: [a, b, 3]\none: solo\nnested: [[x]]\n")?.map)
        XCTAssertEqual(map["many"]?.stringList, ["a", "b", "3"])
        XCTAssertEqual(map["one"]?.stringList, ["solo"])
        XCTAssertNil(map["nested"]?.stringList)
    }

    func testBlockScalarIsString() throws {
        let map = try XCTUnwrap(YAML.parse("run: |\n  echo one\n  echo two\n")?.map)
        XCTAssertEqual(map["run"]?.string, "echo one\necho two\n")
    }

    func testDuplicateKeysAreRejected() {
        XCTAssertThrowsError(try YAML.parse("a: 1\na: 2\n", file: "dup.yaml")) { error in
            let description = String(describing: error)
            XCTAssertTrue(description.contains("dup.yaml"), description)
            XCTAssertTrue(description.lowercased().contains("duplicate"), description)
        }
    }

    func testSyntaxErrorCarriesFileAndLine() {
        XCTAssertThrowsError(try YAML.parse("ok: 1\nbad: [unclosed\n", file: "broken.yaml")) { error in
            guard let parseError = error as? YAMLParseError else { return XCTFail("wrong error type: \(error)") }
            XCTAssertEqual(parseError.file, "broken.yaml")
            XCTAssertNotNil(parseError.line)
        }
    }

    func testEmptyDocumentIsNil() throws {
        XCTAssertNil(try YAML.parse(""))
        XCTAssertNil(try YAML.parse("# only a comment\n"))
    }

    func testFoundationObjectConversion() throws {
        let value = try XCTUnwrap(YAML.parse("flag: true\nnumber: 3\ntext: hi\nlist: [1, two]\n"))
        let object = try XCTUnwrap(value.foundationObject() as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"flag":true,"list":[1,"two"],"number":3,"text":"hi"}"#)
    }

    func testMapEqualityIgnoresLines() {
        let left = YAMLMap([.init(key: "a", value: .int(1), line: 1)])
        let right = YAMLMap([.init(key: "a", value: .int(1), line: 99)])
        XCTAssertEqual(left, right)
    }
}

final class TemplateTests: XCTestCase {
    func testExpansion() {
        let vars = TemplateVars(["home": "/Users/lsp", "name": "Lumpy"])
        XCTAssertEqual(vars.expand("{{home}}/Developer"), "/Users/lsp/Developer")
        XCTAssertEqual(vars.expand("hi {{ name }}!"), "hi Lumpy!")
        XCTAssertEqual(vars.expand("{{unknown}} stays"), "{{unknown}} stays")
        XCTAssertEqual(vars.expand("no braces"), "no braces")
        XCTAssertEqual(vars.expand("dangling {{home"), "dangling {{home")
        XCTAssertEqual(vars.unknownVariables(in: "{{home}} {{nope}} {{nope}} {{also}}"), ["nope", "also"])
    }

    func testTildeExpansionAndAbbreviation() {
        let home = URL(fileURLWithPath: "/Users/lsp")
        XCTAssertEqual(PathExpansion.expandTilde("~", home: home), "/Users/lsp")
        XCTAssertEqual(PathExpansion.expandTilde("~/x/y", home: home), "/Users/lsp/x/y")
        XCTAssertEqual(PathExpansion.expandTilde("/abs/~/x", home: home), "/abs/~/x")
        XCTAssertEqual(PathExpansion.expandTilde("~other/x", home: home), "~other/x")
        XCTAssertEqual(PathExpansion.abbreviate("/Users/lsp/x", home: home), "~/x")
        XCTAssertEqual(PathExpansion.abbreviate("/Users/lspx/x", home: home), "/Users/lspx/x")
    }
}

final class MapReaderTests: XCTestCase {
    private func reader(_ yaml: String) throws -> (MapReader, IssueCollector) {
        let map = try XCTUnwrap(YAML.parse(yaml)?.map)
        let collector = IssueCollector()
        return (MapReader(map: map, source: SourceRef(file: "test.yaml", line: 1), context: "thing", collector: collector), collector)
    }

    func testTypedAccessAndUnknownKeySuggestion() throws {
        let (reader, collector) = try reader("to: ~/x\nlaunch: true\ncount: 3\nlauch: true\n")
        XCTAssertEqual(reader.string("to"), "~/x")
        XCTAssertEqual(reader.bool("launch", default: false), true)
        XCTAssertEqual(reader.int("count"), 3)
        XCTAssertNil(reader.string("absent"))
        reader.finish()
        XCTAssertEqual(collector.errors.count, 1)
        let message = collector.errors[0].description
        XCTAssertTrue(message.contains("unknown key 'lauch'"), message)
        XCTAssertTrue(message.contains("Did you mean 'launch'"), message)
        XCTAssertEqual(collector.errors[0].source?.line, 4, "the error should point at the offending key's line")
    }

    func testTypeErrorsAreRecordedNotThrown() throws {
        let (reader, collector) = try reader("flag: maybe\nnumber: three\nlist: {a: 1}\nname: [a]\n")
        XCTAssertNil(reader.bool("flag"))
        XCTAssertNil(reader.int("number"))
        XCTAssertEqual(reader.stringList("list"), [])
        XCTAssertNil(reader.string("name"))
        XCTAssertEqual(collector.errors.count, 4)
    }

    func testRequiredAndOneOf() throws {
        let (reader, collector) = try reader("kind: zip\nempty: \"\"\n")
        XCTAssertEqual(reader.requiredString("missing"), "")
        XCTAssertEqual(reader.requiredString("empty"), "")
        XCTAssertEqual(reader.oneOf("kind", ["dmg", "pkg"], default: "dmg"), "dmg")
        XCTAssertEqual(collector.errors.count, 3)
        XCTAssertTrue(collector.errors[0].message.contains("missing required key 'missing'"))
    }

    func testNestedReadersAndPairs() throws {
        let (reader, collector) = try reader("settings:\n  autohide: true\n  bogus: 1\nenv:\n  B: two\n  A: 1\napps:\n  - name: One\n  - nope\n")
        let settings = try XCTUnwrap(reader.reader("settings"))
        XCTAssertEqual(settings.bool("autohide"), true)
        settings.finish()
        XCTAssertEqual(reader.stringPairs("env").map(\.key), ["B", "A"], "pair order must follow the file")
        let apps = reader.readers("apps")
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].string("name"), "One")
        reader.finish()
        let messages = collector.errors.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("thing → settings") && $0.contains("unknown key 'bogus'") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("entry 2 must be a mapping") }, "\(messages)")
    }
}

final class ConfigLoaderTests: XCTestCase {
    func testLoadsStepsInFilenameOrder() throws {
        let directory = TempDirectory()
        let root = makeConfig(in: directory, meta: """
        schema: 1
        name: Test Dotfiles
        tagline: for testing
        remote:
          repo: shawntz/dotfiles
          branch: master
          path: installer/config
        vars:
          email: lsp@lumpy.space
        """, steps: [
            "10-second.yaml": "id: second\ntitle: Second\nitems:\n  - ok: b\n",
            "02-first.yaml": "id: first\ntitle: First\nsubtitle: sub\nmascot: lsp\nenabled: false\nquips: [hey]\nitems:\n  - ok: a\n    flavor: grape\n  - present: z\n",
            "_ignored.yaml": "id: nope\ntitle: Nope\nitems: []\n",
            "notes.txt": "not yaml",
        ])
        let result = try ConfigLoader.load(from: root)
        let config = result.config
        XCTAssertEqual(config.meta.name, "Test Dotfiles")
        XCTAssertEqual(config.meta.remote, RemoteConfigRef(repo: "shawntz/dotfiles", branch: "master", path: "installer/config"))
        XCTAssertEqual(config.meta.vars["email"], "lsp@lumpy.space")
        XCTAssertEqual(config.steps.map(\.id), ["first", "second"], "2 sorts before 10 (numeric-aware)")
        let first = config.steps[0]
        XCTAssertEqual(first.subtitle, "sub")
        XCTAssertEqual(first.mascot, "lsp")
        XCTAssertFalse(first.enabledByDefault)
        XCTAssertEqual(first.quips, ["hey"])
        XCTAssertEqual(first.rawItems.count, 2)
        XCTAssertEqual(first.rawItems[0].source, SourceRef(file: "steps/02-first.yaml", line: 8))
        XCTAssertEqual(first.file, "steps/02-first.yaml")
    }

    func testReportsEveryProblemAtOnce() {
        let directory = TempDirectory()
        let root = makeConfig(in: directory, meta: "name: X\nschema: 999\nbogus: 1\n", steps: [
            "01.yaml": "id: Bad Id\ntitle: One\nitems:\n  - just a string\n",
            "02.yaml": "id: twin\ntitle: A\nitems: []\n",
            "03.yaml": "id: twin\ntitle: B\nitems: []\n",
            "04.yaml": "title: no id\nitmes: []\n",
            "05.yaml": "- not\n- a mapping\n",
            "06.yaml": "id: broken\ntitle: [unclosed\n",
        ])
        XCTAssertThrowsError(try ConfigLoader.load(from: root)) { error in
            guard let configError = error as? ConfigError else { return XCTFail("wrong error: \(error)") }
            let text = configError.description
            XCTAssertTrue(text.contains("needs a newer installer"), text)
            XCTAssertTrue(text.contains("unknown key 'bogus'"), text)
            XCTAssertTrue(text.contains("lowercase letters, digits and dashes"), text)
            XCTAssertTrue(text.contains("item 1 must be a mapping"), text)
            XCTAssertTrue(text.contains("step id 'twin' is already used by steps/02.yaml"), text)
            XCTAssertTrue(text.contains("missing required key 'id'"), text)
            XCTAssertTrue(text.contains("Did you mean 'items'"), text)
            XCTAssertTrue(text.contains("steps/05.yaml"), text)
            XCTAssertTrue(text.contains("steps/06.yaml"), text)
        }
    }

    func testMissingDirectoryAndEmptySteps() {
        let directory = TempDirectory()
        XCTAssertThrowsError(try ConfigLoader.load(from: directory.url.appendingPathComponent("nowhere")))
        let root = makeConfig(in: directory, steps: [:])
        XCTAssertThrowsError(try ConfigLoader.load(from: root)) { error in
            XCTAssertTrue(String(describing: error).contains("no step files"), "\(error)")
        }
    }

    func testLoadYAMLHelper() throws {
        let directory = TempDirectory()
        let root = makeConfig(in: directory, steps: ["01.yaml": "id: one\ntitle: One\nitems: []\n"])
        directory.write("config/fun/quotes.yaml", "quotes: [\"oh my glob\"]\n")
        let config = try ConfigLoader.load(from: root).config
        XCTAssertEqual(try config.loadYAML("fun/quotes.yaml")?.map?["quotes"]?.stringList, ["oh my glob"])
        XCTAssertNil(try config.loadYAML("fun/missing.yaml"))
    }
}
