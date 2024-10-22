#!/bin/bash

DOTFILES_DIR="$HOME/dotfiles"
LOG_FILE="$HOME/logs/crontab/upgrade.log"

cd $DOTFILES_DIR

eval "$(/opt/homebrew/bin/brew shellenv)"

echo "[ INFO ] - cron job started on $(date)" >> $LOG_FILE
echo "[ INFO ] - running updating homebrew and upgrading packages..." >> $LOG_FILE
brew update >> $LOG_FILE 2>&1 && brew upgrade && brew cleanup && brew bundle dump --force >> $LOG_FILE 2>&1

if [ $? -eq 0 ]; then
    echo "brew update and upgrade completed successfully on $(date)" >> $LOG_FILE
else
    echo "brew update or upgrade failed on $(date)" >> $LOG_FILE
    exit 1
fi

echo "[ OKAY ] - homebrew sync complete!" >> $LOG_FILE
echo "[ OKAY ] - cron job completed on $(date)" >> $LOG_FILE