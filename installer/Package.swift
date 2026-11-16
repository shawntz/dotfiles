// swift-tools-version: 6.4
import PackageDescription

// Shawn's Dotfiles — a native installer app, the `shawn` CLI, and the web-app shell.
//
//   ShawnCore        config model, YAML, process runner, sudo, file ops, install engine
//   Actions*         the item kinds the YAML config can use (brew, cask, copy, dock, webapp, ...)
//   ShawnFun         quotes, pixel sprites and the ASCII header
//   ShawnSync        finding the config (bundle, checkout, GitHub) and keeping it current
//   ShawnKit         umbrella: every action kind registered in one place
//   ShawnUI          the SwiftUI installer
//   ShawnCLIKit      the `shawn` command line tool
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "ShawnsDotfiles",
    // Resources/Info.plist names the same minimum, and so does MinimumMacOS in ShawnCore, which shawn
    // and the web apps read. MinimumMacOSTests fails when the three disagree.
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "ShawnsDotfiles", targets: ["ShawnsDotfiles"]),
        .executable(name: "shawn", targets: ["shawn"]),
        .executable(name: "WebAppShell", targets: ["WebAppShell"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(name: "ShawnCore", dependencies: [.product(name: "Yams", package: "Yams")], swiftSettings: swift5),
        .target(name: "ActionsPackages", dependencies: ["ShawnCore"], swiftSettings: swift5),
        .target(name: "ActionsFiles", dependencies: ["ShawnCore"], swiftSettings: swift5),
        .target(name: "ActionsDev", dependencies: ["ShawnCore"], swiftSettings: swift5),
        .target(name: "ActionsWebApp", dependencies: ["ShawnCore"], swiftSettings: swift5),
        .target(name: "ShawnFun", dependencies: ["ShawnCore"], swiftSettings: swift5),
        .target(name: "ShawnSync", dependencies: ["ShawnCore"], swiftSettings: swift5),
        .target(
            name: "ShawnKit",
            dependencies: ["ShawnCore", "ActionsPackages", "ActionsFiles", "ActionsDev", "ActionsWebApp", "ShawnFun", "ShawnSync"],
            swiftSettings: swift5
        ),
        .target(name: "ShawnUI", dependencies: ["ShawnCore", "ShawnFun", "ShawnSync"], swiftSettings: swift5),
        .target(name: "ShawnCLIKit", dependencies: ["ShawnCore", "ShawnFun", "ShawnSync"], swiftSettings: swift5),
        .executableTarget(name: "ShawnsDotfiles", dependencies: ["ShawnKit", "ShawnUI"], swiftSettings: swift5),
        .executableTarget(name: "shawn", dependencies: ["ShawnKit", "ShawnCLIKit"], swiftSettings: swift5),
        .executableTarget(name: "WebAppShell", swiftSettings: swift5),

        .testTarget(name: "ShawnCoreTests", dependencies: ["ShawnCore"], swiftSettings: swift5),
        .testTarget(name: "ActionsPackagesTests", dependencies: ["ActionsPackages"], swiftSettings: swift5),
        .testTarget(name: "ActionsFilesTests", dependencies: ["ActionsFiles"], swiftSettings: swift5),
        .testTarget(name: "ActionsDevTests", dependencies: ["ActionsDev"], swiftSettings: swift5),
        .testTarget(name: "ActionsWebAppTests", dependencies: ["ActionsWebApp"], swiftSettings: swift5),
        .testTarget(name: "ShawnFunTests", dependencies: ["ShawnFun"], swiftSettings: swift5),
        .testTarget(name: "ShawnSyncTests", dependencies: ["ShawnSync"], swiftSettings: swift5),
        .testTarget(name: "ShawnKitTests", dependencies: ["ShawnKit"], swiftSettings: swift5),
        .testTarget(name: "ShawnUITests", dependencies: ["ShawnUI"], swiftSettings: swift5),
        .testTarget(name: "ShawnCLIKitTests", dependencies: ["ShawnCLIKit"], swiftSettings: swift5),
    ]
)
