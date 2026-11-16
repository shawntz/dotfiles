import Foundation
import ShawnCore

/// File and system kinds: copy, symlink, mkdir, json-merge, defaults, dock, open, manual, login-item, shawn-cli.
public enum FileActions {
    /// Every item kind this module provides.
    public static var descriptors: [ActionDescriptor] {
        [
            CopyAction.descriptor,
            SymlinkAction.descriptor,
            MkdirAction.descriptor,
            JSONMergeAction.descriptor,
            DefaultsAction.descriptor,
            DockAction.descriptor,
            OpenAction.descriptor,
            ManualAction.descriptor,
            LoginItemAction.descriptor,
            ShawnCLIAction.descriptor,
        ]
    }
}
