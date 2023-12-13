#!/usr/bin/env bash

# based on https://gist.github.com/troyfontaine/18c9146295168ee9ca2b30c00bd1b41e

mkdir ~/.gnupg

echo "pinentry-program $(brew --prefix)/bin/pinentry-mac" > ~/.gnupg/gpg-agent.conf

echo 'use-agent' > ~/.gnupg/gpg.conf

source ~/.zshrc

chmod 700 ~/.gnupg

killall gpg-agent

gpg --full-gen-key

gpg -k

GPGKEYSHORT=$(gpg -K --keyid-format SHORT)
echo $GPGKEYSHORT

KEYID=$(echo $GPGKEYSHORT | grep -v "^$" | awk 'NR == 3' | awk -F/ '{print $NF}' | head -c 8 | grep -v "^$")
echo $KEYID

git config --global gpg.program $(which gpg)
git config --global user.signingkey $KEYID
git config --global commit.gpgsign true

# test it
git commit -S -s -m "Test Signed Commit" --allow-empty

# final messages
echo 'Done! Now submit the PGP key block pasted below to GitHub:'
gpg --armor --export $KEYID

