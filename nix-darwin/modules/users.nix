{ pkgs, hostname, username, ... }:

#################################
###    Host & Users Config    ###
#################################

{
  networking.hostName = hostname;
  networking.computerName = hostname;
  system.defaults.smb.NetBIOSName = hostname;

  users.users."${username}" = {
    home = "/Users/${username}";
    description = username;
  };

  nix.settings.trusted-users = [ username ];

  home-manager.useGlobalPkgs = true; # Use nixpkgs from the flake
  home-manager.useUserPackages = true; # Allow per-user packages

  home-manager.users.${username} = { pkgs, lib, ... }: {
    home.stateVersion = "24.11"; # Match this to your system
    programs.fish.enable = true; # Enable fish shell
    home.packages = [ pkgs.fish ]; # Add fish shell explicitly

    programs.neovim = {
      enable = true;
      viAlias = true;
	    vimAlias = true;
	    vimdiffAlias = true;
	  };
  };
}
