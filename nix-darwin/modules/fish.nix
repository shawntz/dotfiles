{ pkgs, username, ... }:

{
  home-manager.users."${username}" = { ... }: {
    programs.fish = {
      enable = true;
      interactiveShellInit = ''
        # Manually export the PATH
        set -x PATH /nix/var/nix/profiles/default/bin /run/current-system/sw/bin $PATH
        # silence shell messages
        printf '\33c\e[3J'  # hide 'last login' message
        set -g fish_greeting ""
        # neofetch
        neofetch
        # zoxide
        zoxide init fish | source
      '';
      functions = {
        # neovim
        v = "nvim -w ~/.vimlog $argv";
        vi = "fd --type f --hidden --exclude .git | fzf-tmux -m --preview='bat --color=always {}' -p | xargs nvim";
        vim = "nvim -w ~/.vimlog $argv";

        # navigation
        c = "zi $argv[1]";
        cl = "clear";
        cd = "z $argv[1]";
        b = "cd ..";
        bb = "cd ../..";
        bbb = "cd ../../..";
        bbbb = "cd ../../../..";
        l = "ls $argv[1]";
        ls = "eza $argv[1] --all --color=always --sort=name --long --no-user --icons=always --no-permissions";
        home = "cd ~";
        dots = "cd ~/Developer/dotfiles";
        dotfiles = "cd ~/Developer/dotfiles";
        dev = "cd ~/Developer";
        desk = "cd ~/Desktop";
        docs = "cd ~/Documents";
        dl = "cd ~/Downloads";
        md = "mkdir -p";
        t = "touch";
        x = "exit";
        k = "killall kitty";
        o = "open .";
        restart = "sudo reboot";
        bye = "sudo shutdown -r now";
        get = "curl -O -L";
        ssh = "kitty +kitten ssh";

        # tools
        vs = "code -g .";
        s = "source ~/.config/fish/config.fish";
        trim = "awk '{\$1=\$1;print}'";
	      g = "lazygit";
	      f = "yazi";
	      stfu = "osascript -e 'set volume output muted true'";
	      afk = "/System/Library/CoreServices/Menu\ Extras/User.menu/Contents/Resources/CGSession -suspend";
        chromekill = "ps ux | grep '[C]hrome Helper --type=renderer' | grep -v extension-process | tr -s ' ' | cut -d ' ' -f2 | xargs kill";
        rmds = "find . -name '*.DS_Store' -type f -ls -delete";
	      flake = "darwin-rebuild switch --flake ~/Nix --show-trace";

	      # functions
	      cs = ''
          z $argv[1]
          eza --all --color=always --sort=name --no-filesize --no-user --icons=always --no-permissions
	      '';

	      take = ''
          mkdir -p $argv[1]
          cd $argv
	      '';

	      hs = ''
	        curl https://httpstat.us/$argv[1];
	      '';
      };
    };
    home.stateVersion = "24.11";
  };
}
