import Foundation
import ShawnCLIKit
import ShawnKit

// The `shawn` CLI. All the behaviour lives in ShawnCLIKit; this only supplies the item kinds.
let status = await ShawnCLI.run(arguments: Array(CommandLine.arguments.dropFirst()), registry: ShawnKit.makeRegistry())
exit(status)
