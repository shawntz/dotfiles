#!/bin/bash

DOTFILES_DIR="$HOME/dotfiles"
LOG_FILE="$HOME/logs/crontab/backup.log"

cd $DOTFILES_DIR

echo "[ INFO ] - cron job started on $(date)" >> $LOG_FILE
echo "[ INFO ] - backing up dotfiles to github..." >> $LOG_FILE
/usr/bin/git add -A
/usr/bin/git commit -S -m "cron($(date)): daily dotfiles backup"
/usr/bin/git push origin main

if [ $? -eq 0 ]; then
    echo "git backup completed successfully on $(date)" >> $LOG_FILE
else
    echo "git backup failed on $(date)" >> $LOG_FILE
    exit 1
fi

echo "[ OKAY ] - changes pushed to github!" >> $LOG_FILE
echo "[ OKAY ] - cron job completed on $(date)" >> $LOG_FILE
