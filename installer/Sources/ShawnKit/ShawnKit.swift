import ActionsDev
import ActionsFiles
import ActionsPackages
import ActionsWebApp
import Foundation
@_exported import ShawnCore
@_exported import ShawnFun
@_exported import ShawnSync

/// Everything wired together: the one place that knows every item kind.
public enum ShawnKit {
    /// The registry with every item kind the YAML config can use.
    public static func makeRegistry() -> ActionRegistry {
        var registry = ActionRegistry()
        registry.register(PackageActions.descriptors)
        registry.register(FileActions.descriptors)
        registry.register(DevActions.descriptors)
        registry.register(WebAppActions.descriptors)
        return registry
    }
}
