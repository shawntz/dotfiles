-- Delete words and lines from the home row, in every app. Terminals get the
-- shell's own keys instead of the macOS text-field ones.

-- Herdr, Ghostty and Terminal, by bundle ID so a renamed app still matches.
local terminals = {
  ['dev.herdr.app'] = true,
  ['com.mitchellh.ghostty'] = true,
  ['com.apple.Terminal'] = true,
}

local isInTerminal = function()
  local app = hs.application.frontmostApplication()
  return app ~= nil and terminals[app:bundleID()] == true
end

-- Use option + h to delete previous word
hs.hotkey.bind({'alt'}, 'h', function()
  if isInTerminal() then
    keyUpDown({'ctrl'}, 'w')
  else
    keyUpDown({'alt'}, 'delete')
  end
end)

-- Use option + l to delete next word
hs.hotkey.bind({'alt'}, 'l', function()
  if isInTerminal() then
    keyUpDown({}, 'escape')
    keyUpDown({}, 'd')
  else
    keyUpDown({'alt'}, 'forwarddelete')
  end
end)

-- Use control + u to delete to beginning of line
--
-- Shells already treat control + u as "delete to the beginning of the line",
-- so this hotkey is only enabled outside the terminals (window filters match
-- apps by name).
local wf = hs.window.filter.new():setFilters({Herdr = false, Ghostty = false, Terminal = false})
enableHotkeyForWindowsMatchingFilter(wf, hs.hotkey.new({'ctrl'}, 'u', function()
  keyUpDown({'cmd'}, 'delete')
end))

-- Use control + ; to delete to end of line
--
-- Keeps "delete to end of line" on the home row. In a terminal it sends
-- control + k, which the shell reads as kill-to-end-of-line; elsewhere it
-- selects to the end of the line and deletes the selection.
hs.hotkey.bind({'ctrl'}, ';', function()
  if isInTerminal() then
    keyUpDown({'ctrl'}, 'k')
  else
    keyUpDown({'cmd', 'shift'}, 'right')
    keyUpDown({}, 'forwarddelete')
  end
end)
