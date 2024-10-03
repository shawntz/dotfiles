#!/usr/bin/env bash

killall polybar
#(sleep 1; polybar -r)
(sleep 1; /bin/bash /home/$USER/dotfiles/polybar/.config/polybar/launch_polybar.sh)
