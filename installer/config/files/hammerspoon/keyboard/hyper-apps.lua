-- Apps on Hyper + key. Hyper is Right Option (Karabiner-Elements turns it
-- into ⇧⌃⌥⌘).
--
-- Each line is { key, app }. The app can be its name as it appears in
-- /Applications without ".app", its bundle ID, or a Lua function. Add a line
-- such as { "n", "Notion" }, then press Control+` to reload.
return {
  { "a", "ChatGPT" },                    -- Ask
  { "c", "Carbon" },                     -- the Carbon web app (my.carbonapp.co)
  { "e", "Cursor" },                     -- Editor
  { "f", "Finder" },
  { "l", "LocalSend" },
  { "p", "1Password" },
  { "r", "RStudio" },
  { "s", "com.tinyspeck.slackmacgap" },  -- Slack, by bundle ID
  { "w", "Google Chrome" },              -- Web
  { "x", "X" },                          -- the X web app (x.com)
  { "return", "dev.herdr.app" },         -- Herdr, the terminal
}
