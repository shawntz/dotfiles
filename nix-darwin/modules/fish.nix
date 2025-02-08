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
	      echo $0

        zoxide init fish | source

        /opt/anaconda3/bin/conda init fish &> /dev/null

        fastfetch
      '';
      functions = {
        # neovim
        n = "nvim -w ~/.vimlog $argv";
        vim = "nvim -w ~/.vimlog $argv";
        #v = "fd --type f --hidden --exclude .git | fzf-tmux -m --preview='bat --color=always {}' -p | xargs nvim";

        # navigation
        cdi = "zi $argv[1]";
        cd = "z $argv[1]";
        b = "cd ..";
        bb = "cd ../..";
        bbb = "cd ../../..";
        bbbb = "cd ../../../..";
        l = "eza $argv[1] --all --color=always --sort=name --long --no-user --icons=always --no-permissions";
        ls = "eza $argv[1] -lh --group-directories-first --icons";
        lsa = "ls $argv[1] -a";
        lt = "eza $argv[1] --tree --level=2 --long --icons --git";
        lta = "lt $argv[1] -a";
        ff = "fzf --preview 'batcat --style=numbers --color=always {}'";
        fy = "fzf --preview 'batcat --style=numbers --color=always {}' | yazi $argv[1]";
        fn = "fzf --preview 'batcat --style=numbers --color=always {}' | nvim $argv[1]";
        home = "cd ~";
        c = "clear";
        dots = "cd ~/Developer/dotfiles";
        dev = "cd ~/Developer";
        desk = "cd ~/Desktop";
        docs = "cd ~/Documents";
        dl = "cd ~/Downloads";
        md = "mkdir -p $argv[1]";
        t = "touch $argv[1]";
        x = "exit";
        o = "open .";
        restart = "sudo reboot";
        bye = "sudo shutdown -r now";
        get = "curl -O -L $argv[1]";

        # tools
        vs = "code -g .";
        s = "source ~/.config/fish/config.fish";
	      g = "lazygit";
	      f = "yazi | xargs nvim";
	      fz = "fzf | xargs nvim";
	      stfu = "osascript -e 'set volume output muted true'";
	      afk = "/System/Library/CoreServices/Menu\ Extras/User.menu/Contents/Resources/CGSession -suspend";
        chromekill = "ps ux | grep '[C]hrome Helper --type=renderer' | grep -v extension-process | tr -s ' ' | cut -d ' ' -f2 | xargs kill";
        rmds = "find . -name '*.DS_Store' -type f -ls -delete";
	      flake = "darwin-rebuild switch --flake ~/Nix --show-trace";

	      # functions
	      cl = ''
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
