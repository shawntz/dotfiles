#!/bin/bash

# Pomodoro Timer Ticker - runs countdown every second

TIMER_FILE="/tmp/sketchybar_pomodoro"
PID_FILE="/tmp/sketchybar_pomodoro.pid"

# Kill any existing ticker
if [[ -f "$PID_FILE" ]]; then
  old_pid=$(cat "$PID_FILE")
  kill "$old_pid" 2>/dev/null
fi

# Save our PID
echo $$ > "$PID_FILE"

# Run timer countdown
while [[ -f "$TIMER_FILE" ]]; do
  sketchybar --trigger pomodoro_tick
  sleep 1
done

# Clean up
rm -f "$PID_FILE"