{ pkgs, username, ... }:

{
  home-manager.users."${username}" = { ... }: {
    programs.kitty = {
      enable = true;
      theme = "Tokyo Night";
      font.name = "JetBrainsMono Nerd Font";
      settings = {
        font_size = 24.0;
        hide_window_decorations = "titlebar-only";
        macos_show_window_title_in = "none";
        macos_titlebar_color = "#1E1E2E";
        macos_menubar_title_max_length = 0;
        macos_quit_when_last_window_closed = "yes";
        macos_colorspace = "displayp3";
        window_padding_width = 30;
        background_opacity = 0.75;
        background_blur = 64;
        confirm_os_window_close = -0;
        copy_on_select = true;
        clipboard_control = "write-clipboard read-clipboard write-primary read-primary";
      };
    };
    home.stateVersion = "24.11";
  };
}
