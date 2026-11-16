import Foundation
import ShawnCore

/// Bootstrap and package kinds: xcode-clt, homebrew, rosetta, xcode, tap, brew, cask, mas, npm, download, script.
public enum PackageActions {
    /// Every item kind this module provides.
    public static var descriptors: [ActionDescriptor] { descriptors(system: .standard) }

    /// The same kinds, using the given system tools and locations (tests point these at shims).
    static func descriptors(system: MacSystem) -> [ActionDescriptor] {
        [
            ActionDescriptor(
                kind: "xcode-clt",
                summary: "Xcode Command Line Tools, installed headlessly with softwareupdate (Apple's dialog as a fallback)",
                example: "- xcode-clt: install"
            ) { CommandLineToolsAction.parse($0, system: system) },
            ActionDescriptor(
                kind: "homebrew",
                summary: "Homebrew itself, from the signed Homebrew.pkg (install.sh as a fallback), then brew update",
                example: "- homebrew: install\n  method: pkg"
            ) { HomebrewAction.parse($0, system: system) },
            ActionDescriptor(
                kind: "rosetta",
                summary: "Rosetta 2, which runs apps and tools built only for Intel",
                example: "- rosetta: install"
            ) { RosettaAction.parse($0, system: system) },
            ActionDescriptor(
                kind: "xcode",
                summary: "Full Xcode from the Mac App Store: 'download' starts it in the background, 'finish' waits for it and sets it up",
                example: "- xcode: finish\n  timeout_minutes: 180\n  platforms: [iOS]"
            ) { XcodeAction.parse($0, system: system) },
            ActionDescriptor(
                kind: "tap",
                summary: "A third-party Homebrew tap (brew tap), trusted with brew trust when 'trusted: true'",
                example: "- tap: nikitabobko/tap\n  trusted: true"
            ) { TapAction.parse($0) },
            ActionDescriptor(
                kind: "brew",
                summary: "A Homebrew formula; third-party ones fully qualified as user/tap/name",
                example: "- brew: withgraphite/tap/graphite"
            ) { FormulaAction.parse($0) },
            ActionDescriptor(
                kind: "cask",
                summary: "A Homebrew cask; with 'app:' a copy installed some other way counts as installed",
                example: "- cask: dropbox\n  app: Dropbox.app\n  launch: true"
            ) { CaskAction.parse($0, system: system) },
            ActionDescriptor(
                kind: "mas",
                summary: "A Mac App Store app by its numeric id ('name:' required; asks you to sign in to the App Store once)",
                example: "- mas: 937984704\n  name: Amphetamine"
            ) { MasAction.parse($0, system: system) },
            ActionDescriptor(
                kind: "npm",
                summary: "A global npm package (npm install -g)",
                example: "- npm: ghostty-config-cli"
            ) { NpmAction.parse($0) },
            ActionDescriptor(
                kind: "download",
                summary: "An app from a .dmg, .zip or .pkg address, checked with Gatekeeper (and sha256/team) before it is installed",
                example: "- download: https://dl.aeromail.ai/desktop/dogfood/Aero-Dogfood-latest-mac-universal.dmg\n  app: Aero Dogfood.app\n  team_id: ZL4K35VM2L"
            ) { DownloadAction.parse($0, system: system) },
            ActionDescriptor(
                kind: "script",
                summary: "A shell script for anything else; 'check:' and/or 'creates:' make it run only when needed",
                example: "- script: Claude Code\n  run: curl -fsSL https://claude.ai/install.sh | bash\n  creates: ~/.local/bin/claude"
            ) { ScriptAction.parse($0, system: system) },
        ]
    }
}
