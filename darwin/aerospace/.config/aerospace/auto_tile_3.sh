#!/bin/bash

# Auto-tiling script for 3-window Hyprland-style layout
# Creates: 1 large window on left, 2 windows stacked vertically on right

WORKSPACE=$(aerospace list-workspaces --focused)
WINDOW_COUNT=$(aerospace list-windows --workspace "$WORKSPACE" | wc -l | tr -d ' ')

if [ "$WINDOW_COUNT" -eq 3 ]; then
    # Get all window IDs in the workspace
    WINDOWS=($(aerospace list-windows --workspace "$WORKSPACE" --format "%{window-id}"))
    
    if [ ${#WINDOWS[@]} -eq 3 ]; then
        # Reset layout first
        aerospace flatten-workspace-tree
        
        # Focus first window (will be the main/large window)
        aerospace focus --window-id "${WINDOWS[0]}"
        
        # Focus second window and join it to the right of first
        aerospace focus --window-id "${WINDOWS[1]}"
        aerospace join-with right
        
        # Focus third window and join it below second (creating vertical split on right)
        aerospace focus --window-id "${WINDOWS[2]}"
        aerospace join-with down
        
        # Resize to create the desired proportions
        aerospace focus --window-id "${WINDOWS[0]}"
        aerospace resize smart +150
        
        echo "Auto-tiled 3 windows: 1 main left, 2 stacked right"
    fi
else
    echo "Auto-tile works with exactly 3 windows (found: $WINDOW_COUNT)"
fi