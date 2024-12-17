{ pkgs, username, ... }:

{
  home-manager.users."${username}" = { pkgs, inputs, ... }: {
    programs.git = {
      enable = true;
	    extraConfig = {
          user.name = "Shawn Schwartz";
          user.email = "mail@shawntz.com";
          github.user = "shawntz";
          user.signingkey = "~/.ssh/id_ed25519.pub";
          credential.helper = "cache --timeout=2628000";
          gpg.format = "ssh";
          commit.gpgsign = true;
          column.ui = "auto";
          pull.rebase = true;
          help.autocorrect = 1;
          color.ui = "auto";
          init.defaultBranch = "main";
          aliases = {
            undo = "reset HEAD~1 --mixed";
          };
	    };
    };
  };
}
