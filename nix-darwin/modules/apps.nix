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
    chatgpt-cli
    deno
    docker
    eza
    fastfetch
    fd
    feh
    ffmpeg
    fish
    freetype
    fzf
    gcc
    gimp
    git
    git-lfs
    htop
    imagemagick
    inkscape
    jq
    karabiner-elements
    lazygit
    lazydocker
    lua51Packages.lua
    luarocks
    neovim
    nodejs_22
    nushell
    pandoc
    positron-bin
    postman
    rclone
    rectangle
    ripgrep
    rustup
    shfmt
    skimpdf
    slack
    starship
    stow
    tlrc
    tree
    tree-sitter
    wget
    xld
    vscode
    yarn
    yazi
    zellij
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
      "basecamp"
      "beeper"
      "claude"
      "chromium"
      "commander-one"
      "docker"
      "font-sketchybar-app-font"
      "hey"
      "iina"
      "kindle"
      "media-center"
      "proton-mail"
      "raycast"
      "rstudio"
      "sf-symbols"
      "sunsama"
      "the-unarchiver"
      "via"
      "zen-browser"
    ];

    masApps = {
      "codye" = 1516894961;
      "color" = 1545870783;
      "excel" = 462058435;
      "keynote" = 409183694;
      "pages" = 409201541;
      "powerpoint" = 462062816;
      "msremote" = 1295203466;
      "word" = 462054704;
      "xcode" = 497799835;
    };
  };
}
