{ pkgs, username, system, ... }:

{
  nixpkgs = {
    hostPlatform = "aarch64-darwin";

    config = {
      allowUnfree = true;
    };
  };

  nix.settings = {
    # Enable flakes globally
    experimental-features = "nix-command flakes";
  };
  
  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;
  nix.package = pkgs.nix;
}
