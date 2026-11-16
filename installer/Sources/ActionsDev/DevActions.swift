import Foundation
import ShawnCore

/// Developer kinds: git-config, ssh-key, github, git-signing, clone, skill, claude-plugin.
public enum DevActions {
    /// Every item kind this module provides.
    public static var descriptors: [ActionDescriptor] {
        [
            GitConfigAction.descriptor,
            SSHKeyAction.descriptor,
            GitHubAction.descriptor,
            GitSigningAction.descriptor,
            CloneAction.descriptor,
            SkillAction.descriptor,
            ClaudePluginAction.descriptor,
        ]
    }
}
