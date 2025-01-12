#!/bin/bash

/opt/homebrew/bin/sketchybar --add item volume right \
                             --set volume script="$PLUGIN_DIR/volume.sh" \
                             --subscribe volume volume_change 
