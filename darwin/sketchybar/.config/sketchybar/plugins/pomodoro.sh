#!/bin/bash

# Pomodoro Timer Plugin for SketchyBar
# Manages timer state and countdown functionality

TIMER_FILE="/tmp/sketchybar_pomodoro"
PID_FILE="/tmp/sketchybar_pomodoro.pid"

# Handle command line argument or SENDER environment variable
EVENT="${1:-$SENDER}"

case "$EVENT" in
  "pomodoro_start_25")
    echo "1500" > "$TIMER_FILE"  # 25 minutes
    sketchybar --set widgets.pomodoro label.drawing=true label="25:00"
    ;;
  "pomodoro_start_15")
    echo "900" > "$TIMER_FILE"   # 15 minutes  
    sketchybar --set widgets.pomodoro label.drawing=true label="15:00"
    ;;
  "pomodoro_start_5")
    echo "300" > "$TIMER_FILE"   # 5 minutes
    sketchybar --set widgets.pomodoro label.drawing=true label="05:00"
    ;;
  "pomodoro_start_1")
    echo "60" > "$TIMER_FILE"    # 1 minute test
    sketchybar --set widgets.pomodoro label.drawing=true label="01:00"
    ;;
  "pomodoro_start_10")
    echo "10" > "$TIMER_FILE"    # 10 second test
    sketchybar --set widgets.pomodoro label.drawing=true label="00:10"
    ;;
  "pomodoro_stop")
    rm -f "$TIMER_FILE" "$PID_FILE"
    sketchybar --set widgets.pomodoro label.drawing=false
    ;;
  "pomodoro_tick")
    if [[ -f "$TIMER_FILE" ]]; then
      remaining=$(cat "$TIMER_FILE")
      if [[ $remaining -gt 0 ]]; then
        remaining=$((remaining - 1))
        echo "$remaining" > "$TIMER_FILE"
        
        minutes=$((remaining / 60))
        seconds=$((remaining % 60))
        sketchybar --set widgets.pomodoro label.drawing=true label="$(printf "%02d:%02d" "$minutes" "$seconds")"
      else
        # Timer finished
        rm -f "$TIMER_FILE" "$PID_FILE"
        
        # Send notification and play sound
        osascript -e 'display notification "Pomodoro session complete! Time for a break." with title "🍅 Timer Complete"' &
        afplay /System/Library/Sounds/Glass.aiff &
        
        # Flash visual alert for 10 seconds
        for i in {1..10}; do
          sketchybar --set widgets.pomodoro label.drawing=true label="🔔 BREAK TIME!" icon.color=0xffffdd00
          sleep 0.5
          sketchybar --set widgets.pomodoro label="BREAK!" icon.color=0xfffc5d7c
          sleep 0.5
        done
        
        # Reset to normal - hide label and reset icon
        sketchybar --set widgets.pomodoro label.drawing=false icon.color=0xfffc5d7c
      fi
    else
      sketchybar --set widgets.pomodoro label.drawing=false
    fi
    ;;
  *)
    # Default case - show current status
    if [[ -f "$TIMER_FILE" ]]; then
      remaining=$(cat "$TIMER_FILE")
      minutes=$((remaining / 60))
      seconds=$((remaining % 60))
      sketchybar --set widgets.pomodoro label.drawing=true label="$(printf "%02d:%02d" "$minutes" "$seconds")"
    else
      sketchybar --set widgets.pomodoro label.drawing=false
    fi
    ;;
esac