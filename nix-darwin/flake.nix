{
  description = "sts nix-darwin system flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager.url = "github:nix-community/home-manager";
    nix-homebrew.url = "github:zhaofengli-wip/nix-homebrew";
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };
    homebrew-bundle = {
      url = "github:homebrew/homebrew-bundle";
      flake = false;
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plugin-onedark = {
      url = "github:navarasu/onedark.nvim";
      flake = false;
    };
  };

  outputs = inputs @ { 
    self,
    nix-darwin,
    nixpkgs,
    home-manager,
    flake-utils,
    nix-homebrew,
    homebrew-core,
    homebrew-cask,
    homebrew-bundle,
    ...
  }: let
    username = "sts";
    system = "aarch64-darwin";
    hostname = "iBook";

    # Set Git commit hash for darwin-version.
    configurationRevision = self.rev or self.dirtyRev or null;

    specialArgs = 
      inputs
      // {
        inherit username hostname;
      };
  in {
    darwinConfigurations."${hostname}" = nix-darwin.lib.darwinSystem {
      inherit system specialArgs;
      modules = [ 
        ./modules/core.nix
        ./modules/system.nix
        ./modules/users.nix
        ./modules/apps.nix
        ./modules/fonts.nix
        ./modules/git.nix
        ./modules/kitty.nix
        ./modules/fish.nix
        ./modules/starship.nix
        
	    home-manager.darwinModules.home-manager
	    nix-homebrew.darwinModules.nix-homebrew {
          nix-homebrew = {
            enable = true;
            enableRosetta = true;
            user = username;
            
            # declarative tap management
            taps = {
              "homebrew/homebrew-core" = homebrew-core;
              "homebrew/homebrew-cask" = homebrew-cask;
              "homebrew/homebrew-bundle" = homebrew-bundle;
            };

            # enable fully-declarative tap management
            mutableTaps = false;
          };
	    }
      ];
    };

    # Expose the package set, including overlays, for convenience.
    darwinPackages = self.darwinConfigurations."${hostname}".pkgs;
  };
}
