#!/usr/bin/env bash

echo "setting custom app icons..."

fileicon set "/Applications/iTerm.app" $HOME/.init/iTerm2-nord-chevron.icns
fileicon set "/Applications/Visual Studio Code.app" $HOME/.init/citylights.icns
fileicon set "/Applications/Arc.app" $HOME/.init/Arc-Developer-Glow.png
fileicon set "/Applications/RStudio.app" $HOME/.init/R-DarkIcon-Rect.icns
fileicon set "/Applications/Spotify.app" $HOME/.init/Spotify-Big-Sur-Icon-Dark.icns

echo "done!"