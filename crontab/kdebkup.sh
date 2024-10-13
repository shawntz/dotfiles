#!/bin/bash

cd ~/dotfiles/crontab || exit

./transfuse.sh -bt shawn

#git add .

#git commit -S -m "daily backup: $(date +%Y-%m-%d)"

#git push origin main
