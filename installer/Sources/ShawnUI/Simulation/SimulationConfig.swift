import Foundation
import ShawnFun

/// The simulation's config directory, generated at launch. It uses the real config format (and the real
/// loaders), with its own placeholder sprites, characters' lines, quips and header, so the layout can be judged
/// before the real art exists and stays exercisable afterward.
enum SimulationConfig {
    /// Writes `config/` into `directory` and returns its URL.
    static func write(into directory: URL) throws -> URL {
        let root = directory.appendingPathComponent("config", isDirectory: true)
        var files: [String: String] = [
            "installer.yaml": installer,
            "fun/header.txt": header,
            "fun/quotes.yaml": quotes,
        ]
        for (name, body) in steps { files["steps/\(name)"] = body }
        for sprite in sprites { files["fun/sprites/\(sprite.id).yaml"] = sprite.yaml }
        for voice in voices { files["\(FunConfig.voicesDirectory)/\(voice.id).yaml"] = voice.yaml }

        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    static let installer = """
    schema: 1
    name: "Shawn's Dotfiles"
    tagline: one Mac, zero lumps
    vars:
      full_name: Simulated Person
    """

    // MARK: Steps

    static let steps: [(String, String)] = [
        ("01-bootstrap.yaml", """
        id: bootstrap
        title: Bootstrap
        subtitle: Command line tools and a package manager
        mascot: hero
        quips:
          - "Bootstrapping. It's like a makeover, but for computers."
        items:
          - sim-ask: Git email
            prompt: Your email address for Git commits
            default: lumpy@example.com
            format: email
          - sim-present: Xcode Command Line Tools
            reason: already installed
          - sim-admin: Package manager
            command: sudo installer -pkg Homebrew.pkg -target /
            reason: "Installing the package manager writes to /opt and needs administrator rights."
            seconds: 3
            output:
              - "installer: Package name is Homebrew"
              - "installer: Installing at base path /"
              - "installer: The install was successful."
          - sim-install: Package index
            command: brew update
            seconds: 2
            output:
              - "==> Updating Homebrew..."
              - "Updated 2 taps (homebrew/core and homebrew/cask)."
              - "==> New Formulae"
              - "lumpy-cli    glob-utils    whatever-sh"
        """),
        ("02-packages.yaml", """
        id: packages
        title: Packages
        subtitle: Command line tools, freshly brewed
        mascot: pup
        quips:
          - "Brewing. Like, literally."
          - "So many packages. I'm not even gonna count them."
        items:
          - sim-install: ripgrep
            command: brew install --formula ripgrep
            progress: true
            seconds: 2.5
            output:
              - "==> Fetching downloads for: ripgrep"
              - "==> Downloading https://ghcr.io/v2/homebrew/core/ripgrep/blobs/sha256:4f1c…"
          - sim-install: fd
            command: brew install --formula fd
            seconds: 2
            warnings:
              - "Warning: fd 10.3.0 is already installed but outdated; upgrading."
            output:
              - "==> Fetching downloads for: fd"
              - "==> Upgrading fd 10.2.0 -> 10.3.0"
              - "==> Pouring fd--10.3.0.arm64_tahoe.bottle.tar.gz"
              - "/opt/homebrew/Cellar/fd/10.3.0: 14 files, 3.1MB"
          - sim-present: git
            reason: already installed (2.53.0)
          - sim-install: lazygit
            command: brew install --formula lazygit
            progress: true
            seconds: 2
            output:
              - "==> Fetching downloads for: lazygit"
              - "==> Pouring lazygit--0.58.1.arm64_tahoe.bottle.tar.gz"
          - sim-fail: Lumpy Space Radio
            command: brew install --cask lumpy-space-radio
            seconds: 1.5
            output:
              - "==> Fetching downloads for: lumpy-space-radio"
            error: "Error: Cask 'lumpy-space-radio' is unavailable: No Cask with this name exists."
            hint: "check the token with `brew search lumpy`, then fix steps/02-packages.yaml"
          - sim-install: neovim
            optional: true
            note: off by default; check it in Customize
            command: brew install --formula neovim
            output:
              - "==> Pouring neovim--0.12.0.arm64_tahoe.bottle.tar.gz"
        """),
        ("03-apps.yaml", """
        id: apps
        title: Apps
        subtitle: The App Store and friends
        mascot: cube
        quips:
          - "Apps! I love apps. Mostly the ones about me."
        items:
          - sim-question: Amphetamine
            question: Sign in to the App Store
            message: "Open the App Store, sign in with your Apple Account, then come back. The installer cannot install App Store apps until you do."
            options: ["I'm signed in", "Skip App Store apps"]
            url: "macappstore://apps.apple.com/app/id937984704"
            command: sudo mas install 937984704
            output:
              - "==> Downloading Amphetamine (5.3.2)"
              - "==> Installed Amphetamine (5.3.2)"
          - sim-skip: Helper for older Macs
            reason: not needed on this Mac
          - sim-install: Spotify
            command: brew install --cask spotify
            progress: true
            seconds: 3
            output:
              - "==> Downloading https://download.scdn.co/SpotifyARM64.dmg"
              - "==> Installing Cask spotify"
              - "==> Moving App 'Spotify.app' to '/Applications/Spotify.app'"
          - sim-install: Optional extra app
            optional: true
            command: brew install --cask extra-app
        """),
        ("04-github.yaml", """
        id: github
        title: GitHub
        subtitle: Sign in, then upload an SSH key for pushing and signing
        mascot: penguin
        quips:
          - "Git it? Get it? Ugh, nobody gets me."
        items:
          - sim-install: SSH key
            command: ssh-keygen -t ed25519 -a 100 -N '' -f ~/.ssh/id_ed25519 -q
            seconds: 1
            output:
              - "Generated ~/.ssh/id_ed25519 (ed25519)"
          - sim-sign-in: Sign in to GitHub
            code: LUMP-5PCE
            url: "https://github.com/login/device"
            message: "Enter this code in the browser window that just opened, then approve the sign-in."
            seconds: 6
          - sim-install: Upload signing key
            command: gh ssh-key add ~/.ssh/id_ed25519.pub --type signing
            seconds: 1
            output:
              - "✓ Public key added to your account"
        """),
        ("05-macos.yaml", """
        id: macos
        title: macOS Settings
        subtitle: Keyboard, Finder, Dock
        mascot: moon
        items:
          - sim-install: Key repeat
            command: defaults write -g KeyRepeat -int 1
            seconds: 1
          - sim-manual: Allow Accessibility for Hammerspoon
            detail: "System Settings → Privacy & Security → Accessibility → turn on Hammerspoon."
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
          - sim-install: Dock
            command: killall Dock
            seconds: 1
            output:
              - "Dock: 6 apps, 1 folder (~/Developer)"
        """),
        ("06-extras.yaml", """
        id: extras
        title: Extras
        subtitle: Off unless you switch it on
        enabled: false
        items:
          - sim-install: Screen saver
          - sim-install: Wallpaper
        """),
        ("07-finish.yaml", """
        id: finish
        title: Finish
        subtitle: The bits only you can do
        mascot: lumpy
        items:
          - sim-manual: Log out and back in
            detail: Key repeat settings apply after you log in again.
        """),
    ]

    // MARK: Quips (the narrator's simulation lines; the real ones live in the real config)

    static let quotes = """
    speaker: lumpy
    about: "Simulation mode: placeholder characters and lines."
    moments:
      launch:
        - "Oh my glob, a whole new Mac. Let's make it lumpy."
        - "Ready when you are. No pressure. Some pressure."
      idle:
        - "Still here. Still fabulous."
        - "Take your time. I'll just stand here being lumpy."
      password:
        - "I need your password. Don't make it weird."
      working:
        - "Working on it. Don't rush me."
        - "This is going great. Probably."
      waiting:
        - "I'm waiting on YOU now. Rude, but fine."
      success:
        - "Nailed it. Obviously."
      failure:
        - "Ugh. That one totally flopped."
      skipped:
        - "Skipped it. It wasn't worth my time anyway."
      dry_run:
        - "Dry run! We're just pretending. Pretending is my thing."
      finished:
        - "Done! This Mac is officially lumpy."
      finished_with_failures:
        - "Mostly done. Some stuff was being difficult."
      cancelled:
        - "Fine. Stopping. Whatever."
    steps:
      macos:
        - "Fixing the settings. You're welcome."
    """

    // MARK: Voices (each placeholder character's own lines, said while the step it hosts runs)

    /// One placeholder character's `fun/voices/<id>.yaml`, with a line for each step moment. The `quips:` in the step
    /// file of the step it hosts join these as extra working lines when the config loads.
    struct VoiceFile {
        let id: String
        let lines: [Moment: String]

        var yaml: String {
            var rows = ["id: \(id)", "moments:"]
            for moment in Moment.stepMoments {
                guard let line = lines[moment] else { continue }
                rows.append("  \(moment.rawValue):")
                rows.append("    - \"\(line)\"")
            }
            return rows.joined(separator: "\n") + "\n"
        }
    }

    /// The characters who host a step. The narrator (lumpy) has no voice file, because her lines are in `quotes`.
    static var voices: [VoiceFile] {
        [
            VoiceFile(id: "hero", lines: [
                .working: "Hero on duty. This step is in good hands.",
                .success: "That one went in clean. On to the next quest.",
                .failure: "The machine threw that one back. We'll get it next run.",
                .skipped: "Leaving that one out of this run. The quest goes on.",
                .waiting: "I'll hold the line until you're back.",
                .question: "One question first, and then I'm off again.",
                .password: "This needs your password. I'll look away while you type.",
                .cancelled: "Standing down. The quest can wait.",
                .dryRun: "A practice round. Nothing on this Mac changes.",
            ]),
            VoiceFile(id: "pup", lines: [
                .working: "Fetching packages. Fetching is my best trick.",
                .success: "Done and done! Who wants to go next?",
                .failure: "The download dropped that one. Not my fault, I promise.",
                .skipped: "That one stays out of this run. On to the next toy!",
                .waiting: "Sitting. Staying. Waiting for you.",
                .question: "Ooh, a question! I'll wait right here with my tail going.",
                .password: "Your password, please. I won't tell the other dogs.",
                .cancelled: "Okay, stopping. I'll go lie down.",
                .dryRun: "Pretend fetch! Nothing actually comes back.",
            ]),
            VoiceFile(id: "cube", lines: [
                .working: "Processing. Please enjoy this blinking cursor.",
                .success: "Result OK. Logging a small victory.",
                .failure: "Error from the system, not from me. Flagged for the next run.",
                .skipped: "Item excluded from this run. Skipping ahead.",
                .waiting: "Input required. Standing by.",
                .question: "Query pending. Please type an answer.",
                .password: "Authentication needed. Type carefully, I can't see it either.",
                .cancelled: "Halt received. Powering down this task.",
                .dryRun: "Simulation mode. Every output is imaginary.",
            ]),
            VoiceFile(id: "penguin", lines: [
                .working: "Sliding through this one on my belly. Very efficient.",
                .success: "Smooth. Cool. Done.",
                .failure: "The server left that one out in the cold. We'll retry later.",
                .skipped: "Leaving that one out this run. I'll waddle on.",
                .waiting: "Chilling until you're ready.",
                .question: "Quick question before we slide on.",
                .password: "Password time. I'll keep it on ice.",
                .cancelled: "Stopping here. Back to the iceberg.",
                .dryRun: "Just a practice slide. The ice stays smooth.",
            ]),
            VoiceFile(id: "moon", lines: [
                .working: "Slowly, steadily, like a tide coming in.",
                .success: "That one landed softly.",
                .failure: "The machine said no to that one. The tide will turn.",
                .skipped: "That one sits out this run. The tide moves on.",
                .waiting: "I'll keep the light on until you're back.",
                .question: "A question for you, whenever you're ready.",
                .password: "Your password, please. I'll dim the lights.",
                .cancelled: "Setting early tonight.",
                .dryRun: "A rehearsal by moonlight. Nothing really moves.",
            ]),
        ]
    }

    // MARK: Header (ANSI Shadow lettering, built from glyphs so every row has the same width)

    static var header: String {
        let word1 = ["S", "H", "A", "W", "N", "'", "S"]
        let word2 = ["D", "O", "T", "F", "I", "L", "E", "S"]
        let rows = (0..<6).map { row -> String in
            let left = word1.map { glyphs[$0]![row] }.joined()
            let right = word2.map { glyphs[$0]![row] }.joined()
            return left + "   " + right
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static let glyphs: [String: [String]] = [
        "S": ["███████╗", "██╔════╝", "███████╗", "╚════██║", "███████║", "╚══════╝"],
        "H": ["██╗  ██╗", "██║  ██║", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"],
        "A": [" █████╗ ", "██╔══██╗", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"],
        "W": ["██╗    ██╗", "██║    ██║", "██║ █╗ ██║", "██║███╗██║", "╚███╔███╔╝", " ╚══╝╚══╝ "],
        "N": ["███╗   ██╗", "████╗  ██║", "██╔██╗ ██║", "██║╚██╗██║", "██║ ╚████║", "╚═╝  ╚═══╝"],
        "'": ["██╗", "██║", "╚═╝", "   ", "   ", "   "],
        "D": ["██████╗ ", "██╔══██╗", "██║  ██║", "██║  ██║", "██████╔╝", "╚═════╝ "],
        "O": [" ██████╗ ", "██╔═══██╗", "██║   ██║", "██║   ██║", "╚██████╔╝", " ╚═════╝ "],
        "T": ["████████╗", "╚══██╔══╝", "   ██║   ", "   ██║   ", "   ██║   ", "   ╚═╝   "],
        "F": ["███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "██║     ", "╚═╝     "],
        "I": ["██╗", "██║", "██║", "██║", "██║", "╚═╝"],
        "L": ["██╗     ", "██║     ", "██║     ", "██║     ", "███████╗", "╚══════╝"],
        "E": ["███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "███████╗", "╚══════╝"],
    ]

    // MARK: Placeholder sprites (simple shapes in a range of sizes, so the layout is tested from 14 to 32 px)

    struct SpriteFile {
        let id: String
        let name: String
        let frameMilliseconds: Int
        let palette: [(Character, String)]
        let frames: [PixelSketch]

        var yaml: String {
            var lines = ["id: \(id)", "name: \"\(name)\"", "frame_ms: \(frameMilliseconds)", "palette:", "  \".\": transparent"]
            for (symbol, color) in palette { lines.append("  \"\(symbol)\": \"\(color)\"") }
            lines.append("frames:")
            for frame in frames {
                lines.append("  - |")
                for row in frame.rows { lines.append("    " + row) }
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static var sprites: [SpriteFile] {
        [lumpy, cube, pup, penguin, hero, moon]
    }

    /// A lumpy purple cloud with a star, half-lidded eyes; bobs and blinks.
    static var lumpy: SpriteFile {
        func frame(lift: Int, blink: Bool) -> PixelSketch {
            var sketch = PixelSketch(width: 24, height: 20)
            let y = 11.5 - Double(lift)
            sketch.ellipse(cx: 11.5, cy: y, rx: 10.5, ry: 6.5, "P")
            sketch.ellipse(cx: 6.5, cy: y - 5, rx: 3.6, ry: 3.2, "P")
            sketch.ellipse(cx: 12, cy: y - 6.5, rx: 3.8, ry: 3.2, "P")
            sketch.ellipse(cx: 17.5, cy: y - 4.5, rx: 3.4, ry: 3, "P")
            sketch.outline(["P"], with: "O")
            let top = Int(y) - 8
            for (dx, dy) in [(0, 0), (-1, 1), (0, 1), (1, 1), (0, 2)] { sketch.set(12 + dx, top + dy + 1, "Y") }
            let eyeRow = Int(y) - 1
            if blink {
                for x in [7, 8, 9, 14, 15, 16] { sketch.set(x, eyeRow + 1, "K") }
            } else {
                for x in [7, 8, 9, 14, 15, 16] { sketch.set(x, eyeRow, "K") }
                for x in [8, 9, 15, 16] { sketch.set(x, eyeRow + 1, "W") }
            }
            sketch.set(11, eyeRow + 3, "M")
            sketch.set(12, eyeRow + 3, "M")
            return sketch
        }
        return SpriteFile(id: "lumpy", name: "Lumpy Space Princess", frameMilliseconds: 520,
                          palette: [("O", "#4E2F72"), ("P", "#A97BD0"), ("Y", "#FFD93B"), ("K", "#1E1A24"), ("W", "#FFFFFF"), ("M", "#6B3F92")],
                          frames: [frame(lift: 0, blink: false), frame(lift: 1, blink: false), frame(lift: 1, blink: true)])
    }

    /// A small teal console with a face on its screen.
    static var cube: SpriteFile {
        func frame(smile: Bool) -> PixelSketch {
            var sketch = PixelSketch(width: 16, height: 18)
            sketch.rect(x: 2, y: 1, width: 12, height: 14, "T")
            sketch.outline(["T"], with: "D")
            sketch.rect(x: 4, y: 3, width: 8, height: 6, "S")
            sketch.set(6, 5, "K")
            sketch.set(9, 5, "K")
            if smile {
                sketch.set(6, 7, "K"); sketch.set(7, 7, "K"); sketch.set(8, 7, "K"); sketch.set(9, 7, "K")
            } else {
                sketch.set(7, 7, "K"); sketch.set(8, 7, "K")
            }
            sketch.set(5, 11, "Y"); sketch.set(10, 11, "R"); sketch.set(11, 12, "B")
            sketch.rect(x: 4, y: 15, width: 2, height: 2, "D")
            sketch.rect(x: 10, y: 15, width: 2, height: 2, "D")
            return sketch
        }
        return SpriteFile(id: "cube", name: "Placeholder Console", frameMilliseconds: 700,
                          palette: [("T", "#5FC9B5"), ("D", "#2B6E64"), ("S", "#C8F7DC"), ("K", "#1E2A28"), ("Y", "#FFD93B"), ("R", "#FF6482"), ("B", "#5B8CFF")],
                          frames: [frame(smile: true), frame(smile: false)])
    }

    /// An orange pup whose tail wags.
    static var pup: SpriteFile {
        func frame(wag: Bool) -> PixelSketch {
            var sketch = PixelSketch(width: 22, height: 14)
            sketch.ellipse(cx: 11, cy: 8, rx: 8, ry: 4.5, "G")
            sketch.ellipse(cx: 16.5, cy: 5, rx: 3.5, ry: 3.2, "G")
            sketch.rect(x: 5, y: 11, width: 2, height: 3, "G")
            sketch.rect(x: 14, y: 11, width: 2, height: 3, "G")
            if wag { sketch.rect(x: 1, y: 4, width: 2, height: 3, "G") } else { sketch.rect(x: 1, y: 7, width: 3, height: 2, "G") }
            sketch.outline(["G"], with: "D")
            sketch.set(17, 4, "K")
            sketch.set(20, 5, "K")
            return sketch
        }
        return SpriteFile(id: "pup", name: "Placeholder Pup", frameMilliseconds: 300,
                          palette: [("G", "#F4B740"), ("D", "#A0661C"), ("K", "#2A1C0E")],
                          frames: [frame(wag: false), frame(wag: true)])
    }

    /// A penguin that flaps.
    static var penguin: SpriteFile {
        func frame(flap: Bool) -> PixelSketch {
            var sketch = PixelSketch(width: 14, height: 16)
            sketch.ellipse(cx: 6.5, cy: 8, rx: 5, ry: 7, "K")
            sketch.ellipse(cx: 6.5, cy: 9.5, rx: 3.2, ry: 4.6, "W")
            sketch.set(4, 4, "W"); sketch.set(8, 4, "W")
            sketch.set(6, 6, "Y"); sketch.set(7, 6, "Y")
            sketch.rect(x: 4, y: 15, width: 2, height: 1, "Y")
            sketch.rect(x: 8, y: 15, width: 2, height: 1, "Y")
            if flap { sketch.set(0, 7, "K"); sketch.set(13, 7, "K"); sketch.set(0, 6, "K"); sketch.set(13, 6, "K") }
            return sketch
        }
        return SpriteFile(id: "penguin", name: "Placeholder Penguin", frameMilliseconds: 450,
                          palette: [("K", "#22202A"), ("W", "#F2F0F7"), ("Y", "#F7B500")],
                          frames: [frame(flap: false), frame(flap: true)])
    }

    /// A kid in a white hat who waves.
    static var hero: SpriteFile {
        func frame(wave: Bool) -> PixelSketch {
            var sketch = PixelSketch(width: 16, height: 20)
            sketch.ellipse(cx: 7.5, cy: 5.5, rx: 5.5, ry: 5, "H")
            sketch.rect(x: 3, y: 0, width: 2, height: 2, "H")
            sketch.rect(x: 11, y: 0, width: 2, height: 2, "H")
            sketch.rect(x: 4, y: 4, width: 8, height: 5, "F")
            sketch.set(6, 6, "K"); sketch.set(9, 6, "K")
            sketch.rect(x: 4, y: 11, width: 8, height: 5, "B")
            sketch.rect(x: 4, y: 16, width: 8, height: 2, "N")
            sketch.rect(x: 5, y: 18, width: 2, height: 2, "K")
            sketch.rect(x: 9, y: 18, width: 2, height: 2, "K")
            if wave { sketch.rect(x: 13, y: 8, width: 2, height: 4, "F") } else { sketch.rect(x: 13, y: 12, width: 2, height: 3, "F") }
            sketch.rect(x: 1, y: 12, width: 2, height: 3, "F")
            sketch.outline(["H"], with: "O")
            return sketch
        }
        return SpriteFile(id: "hero", name: "Placeholder Hero", frameMilliseconds: 600,
                          palette: [("H", "#F7F7FA"), ("O", "#9A9AB0"), ("F", "#FFD7B0"), ("K", "#202030"), ("B", "#5BC0F8"), ("N", "#2E5FA8")],
                          frames: [frame(wave: false), frame(wave: true)])
    }

    /// The largest size a sprite may have (32×32), to prove the layout copes.
    static var moon: SpriteFile {
        func frame(phase: Int) -> PixelSketch {
            var sketch = PixelSketch(width: 32, height: 32)
            sketch.ellipse(cx: 15.5, cy: 15.5, rx: 14.5, ry: 14.5, "M")
            sketch.ellipse(cx: 10, cy: 11, rx: 3, ry: 2.5, "C")
            sketch.ellipse(cx: 20, cy: 19, rx: 4, ry: 3.2, "C")
            sketch.ellipse(cx: 13, cy: 23, rx: 2, ry: 1.6, "C")
            sketch.outline(["M", "C"], with: "O")
            sketch.set(11 + phase, 15, "K")
            sketch.set(19 + phase, 15, "K")
            return sketch
        }
        return SpriteFile(id: "moon", name: "Placeholder Moon", frameMilliseconds: 900,
                          palette: [("M", "#E9DFFF"), ("C", "#C5B5EE"), ("O", "#7D68B0"), ("K", "#2A2240")],
                          frames: [frame(phase: 0), frame(phase: 1)])
    }
}

/// A character grid for drawing placeholder sprites with simple shapes.
struct PixelSketch: Equatable {
    private(set) var grid: [[Character]]
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        grid = Array(repeating: Array(repeating: ".", count: width), count: height)
    }

    var rows: [String] { grid.map { String($0) } }

    mutating func set(_ x: Int, _ y: Int, _ symbol: Character) {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return }
        grid[y][x] = symbol
    }

    mutating func rect(x: Int, y: Int, width: Int, height: Int, _ symbol: Character) {
        for row in y..<(y + height) {
            for column in x..<(x + width) { set(column, row, symbol) }
        }
    }

    mutating func ellipse(cx: Double, cy: Double, rx: Double, ry: Double, _ symbol: Character) {
        for row in 0..<height {
            for column in 0..<width {
                let dx = (Double(column) - cx) / rx
                let dy = (Double(row) - cy) / ry
                if dx * dx + dy * dy <= 1 { grid[row][column] = symbol }
            }
        }
    }

    /// Turns the edge pixels of the given fills into an outline.
    mutating func outline(_ fills: Set<Character>, with symbol: Character) {
        let original = grid
        for row in 0..<height {
            for column in 0..<width where fills.contains(original[row][column]) {
                let neighbors = [(column - 1, row), (column + 1, row), (column, row - 1), (column, row + 1)]
                let onEdge = neighbors.contains { x, y in
                    !(0..<width).contains(x) || !(0..<height).contains(y) || original[y][x] == "."
                }
                if onEdge { grid[row][column] = symbol }
            }
        }
    }
}
