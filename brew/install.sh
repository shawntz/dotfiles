#!/usr/bin/env bash

# download Homebrew source
curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh

# add Homebrew to PATH
(echo; echo 'eval "$(/opt/homebrew/bin/brew shellenv)"') >> /Users/shawn/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
