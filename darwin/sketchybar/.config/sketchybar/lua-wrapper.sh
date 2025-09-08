#!/bin/bash

# SketchyBar Lua wrapper script
# This script dynamically finds the lua executable and runs the SketchyBar config

# Try mise first (if available)
if command -v mise >/dev/null 2>&1; then
    LUA_PATH=$(mise which lua 2>/dev/null)
    if [[ -n "$LUA_PATH" && -x "$LUA_PATH" ]]; then
        exec "$LUA_PATH" "$@"
    fi
fi

# Fall back to homebrew lua
if [[ -x "/opt/homebrew/bin/lua" ]]; then
    exec /opt/homebrew/bin/lua "$@"
fi

# Fall back to system lua
if command -v lua >/dev/null 2>&1; then
    exec lua "$@"
fi

# If no lua found, log error and exit
echo "Error: No lua executable found. Please install lua via mise or homebrew." >&2
exit 1