{ pkgs, ... }:

####################
### Fonts Config ###
####################

{
  fonts.packages = with pkgs.nerd-fonts; [
    fira-code
    jetbrains-mono
    noto
  ];
}
