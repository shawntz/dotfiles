-- Hammerspoon config. Installed by Shawn's Dotfiles to ~/.hammerspoon.
-- Based on Jason Rudolph's keyboard setup (MIT, see LICENSE).
--
--   Hyper + key        open an app (keyboard/hyper-apps.lua); Hyper is Right
--                      Option, turned into ⇧⌃⌥⌘ by Karabiner-Elements
--   Control+S, key     window layout mode (keyboard/windows-bindings-defaults.lua)
--   Control+M, key     Markdown mode (keyboard/markdown.lua)
--   Option+H / L       delete the previous / next word (keyboard/delete-words.lua)
--   Control+`          reload this config

local log = hs.logger.new('init.lua', 'debug')

-- Start Hammerspoon at login (the same switch as in its Preferences window).
hs.autoLaunch(true)

hs.hotkey.bind({'ctrl'}, '`', nil, function()
  hs.reload()
end)

keyUpDown = function(modifiers, key)
  -- Un-comment & reload config to log each keystroke that we're triggering
  -- log.d('Sending keystroke:', hs.inspect(modifiers), key)

  hs.eventtap.keyStroke(modifiers, key, 0)
end

-- Subscribe to the necessary events on the given window filter such that the
-- given hotkey is enabled for windows that match the window filter and disabled
-- for windows that don't match the window filter.
--
-- windowFilter - An hs.window.filter object describing the windows for which
--                the hotkey should be enabled.
-- hotkey       - The hs.hotkey object to enable/disable.
--
-- Returns nothing.
enableHotkeyForWindowsMatchingFilter = function(windowFilter, hotkey)
  windowFilter:subscribe(hs.window.filter.windowFocused, function()
    hotkey:enable()
  end)

  windowFilter:subscribe(hs.window.filter.windowUnfocused, function()
    hotkey:disable()
  end)
end

require('keyboard.delete-words')
require('keyboard.hyper')
require('keyboard.markdown')
require('keyboard.windows')

hs.notify.new({title='Hammerspoon', informativeText='Ready to rock 🤘'}):send()
