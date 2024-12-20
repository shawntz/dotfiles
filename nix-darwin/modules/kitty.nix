{ pkgs, username, ... }:

{
  home-manager.users."${username}" = { ... }: {
    programs.kitty = {
      enable = true;
      # theme = "Tokyo Night";
      theme = "Gruvbox Dark";
      font.name = "JetBrainsMono Nerd Font";
      settings = {
        allow_remote_control = "yes";
        font_size = 22.0;
        hide_window_decorations = "titlebar-only";
        macos_window_resizable = "yes";
        macos_show_window_title_in = "menubar";
        macos_traditional_fullscreen = "no";
        macos_titlebar_color = "background";
        macos_menubar_title_max_length = 0;
        macos_quit_when_last_window_closed = "yes";
        macos_colorspace = "displayp3";
        # window_padding_height = 30;
        # window_padding_width = 5;
        # background_opacity = 0.4;
        # background_blur = 128;
        confirm_os_window_close = -0;
        copy_on_select = true;
        clipboard_control = "write-clipboard read-clipboard write-primary read-primary";
      };
    };
    home.stateVersion = "24.11";
  };
}
