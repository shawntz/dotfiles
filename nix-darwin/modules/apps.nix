{ pkgs, ...}:

###################
### Apps Config ###
###################

{
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = with pkgs; [
    ascii-image-converter
    bat
    deno
    docker
    eza
    fd
    feh
    ffmpeg
    fish
    fzf
    gcc
    gimp
    git
    git-lfs
    google-chrome
    htop
    imagemagick
    inkscape
    jq
    karabiner-elements
    lazygit
    lazydocker
    lua51Packages.lua
    luarocks
    neofetch
    neovim
    nodejs_22
    nushell
    obsidian
    pandoc
    positron-bin
    postman
    raycast
    rclone
    ripgrep
    rustup
    skimpdf
    slack
    starship
    stow
    tlrc
    tmux
    tree
    tree-sitter
    wget
    vscode
    yabai
    yarn
    yazi
    zoom-us
    zoxide
  ];

  homebrew = {
    enable = true;

    onActivation = {
      cleanup = "zap";
      autoUpdate = true;
      upgrade = true;
    };

    brews = [
      "JupyterLab"
      "macos-trash"
      "sketchybar"
    ];

    casks = [
      "1password"
      "beeper"
      "chatgpt"
      "docker"
      "font-sketchybar-app-font"
      "hey"
      "iina"
      "kindle"
      "media-center"
      "messenger"
      "middleclick"
      "rstudio"
      "sf-symbols"
      "the-unarchiver"
      "todoist"
      "via"
      "whatsapp"
    ];

    masApps = {
      "1pwsafari" = 1569813296;
      # "bear" = 1091189122;
      "codye" = 1516894961;
      "color" = 1545870783;
      "excel" = 462058435;
      "keynote" = 409183694;
      "pages" = 409201541;
      "powerpoint" = 462062816;
      "msremote" = 1295203466;
      "word" = 462054704;
      "things" = 904280696;
      "xcode" = 497799835;
      "yoink" = 457622435;
    };
  };
}
