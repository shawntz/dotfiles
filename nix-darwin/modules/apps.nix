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
    google-chrome
    htop
    imagemagick
    inkscape
    jq
    karabiner-elements
    kitty
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
    R
    raycast
    rclone
    rectangle
    ripgrep
    rustup
    skimpdf
    slack
    starship
    stow
    tmux
    tree
    tree-sitter
    wget
    vscode
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
    ];

    casks = [
      "1password"
      "chatgpt"
      "hey"
      "iina"
      "kindle"
      "middleclick"
      "rstudio"
      "sf-symbols"
      "the-unarchiver"
      "todoist"
      "via"
    ];

    masApps = {
      "1pwsafari" = 1569813296;
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