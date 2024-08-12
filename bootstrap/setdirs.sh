#!/usr/bin/env bash

xdg-user-dirs-update --set DESKTOP ~/desktop
xdg-user-dirs-update --set DOCUMENTS ~/documents
xdg-user-dirs-update --set DOWNLOAD ~/downloads
xdg-user-dirs-update --set MUSIC ~/music
xdg-user-dirs-update --set PICTURES ~/pictures
xdg-user-dirs-update --set PUBLICSHARE ~/public
xdg-user-dirs-update --set TEMPLATES ~/templates
xdg-user-dirs-update --set VIDEOS ~/videos

mkdir -p ~/projects
mkdir -p ~/projects/oss
mkdir -p ~/projects/phd