import Foundation

/// A package an item installs, in a form other tools can compare against what is on the machine
/// (`shawn drift`, `shawn add`).
public struct PackageRef: Hashable, Sendable, CustomStringConvertible {
    public enum Manager: String, Sendable, CaseIterable {
        case tap
        case formula
        case cask
        case mas
        case npm
    }

    public let manager: Manager
    /// The name exactly as written in the config (`eza`, `nikitabobko/tap/aerospace`, `937984704`).
    public let name: String
    /// Human name where the identifier is not one (`Amphetamine` for a Mac App Store id).
    public let label: String?

    public init(manager: Manager, name: String, label: String? = nil) {
        self.manager = manager
        self.name = name
        self.label = label
    }

    /// The last path component of a tap-qualified name (`aerospace` for `nikitabobko/tap/aerospace`).
    public var shortName: String {
        manager == .tap ? name : (name.split(separator: "/").last.map(String.init) ?? name)
    }

    public var description: String {
        "\(manager.rawValue): \(name)" + (label.map { " (\($0))" } ?? "")
    }
}

/// Adopted by actions that install a package, so inventory tools can list what the config declares.
public protocol PackageProviding {
    var packageRef: PackageRef { get }
}
