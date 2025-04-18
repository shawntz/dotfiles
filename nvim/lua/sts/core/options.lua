--- Options
vim.opt.modifiable = true
vim.opt.breakindent = true -- Wrap indent to match  line start.
vim.opt.clipboard = "unnamedplus" -- Connection to the system clipboard.
vim.opt.cmdheight = 0 -- Hide command line unless needed.
vim.opt.completeopt = { "menu", "menuone", "noselect" } -- Options for insert mode completion.
vim.opt.copyindent = true -- Copy the previous indentation on autoindenting.
vim.opt.cursorline = true -- Highlight the text line of the cursor.
vim.opt.expandtab = true -- Enable the use of space in tab.
vim.opt.fileencoding = "utf-8" -- File content encoding for the buffer.
vim.opt.fillchars = { eob = " " } -- Disable `~` on nonexistent lines.
vim.opt.foldenable = true -- Enable fold for nvim-ufo.
vim.opt.foldlevel = 99 -- set highest foldlevel for nvim-ufo.
vim.opt.foldlevelstart = 99 -- Start with all code unfolded.
vim.opt.foldcolumn = "1" -- Show foldcolumn in nvim 0.9+.
vim.opt.ignorecase = true -- Case insensitive searching.
vim.opt.infercase = true -- Infer cases in keyword completion.
vim.opt.background = "dark" -- Colorschemes that can be light or dark will be made dark.

vim.opt.laststatus = 3 -- Global statusline.
vim.opt.linebreak = true -- Wrap lines at 'breakat'.
vim.opt.number = true -- Show numberline.
vim.opt.numberwidth = 5 -- Set number column width to 2 {default 4}.
vim.opt.preserveindent = true -- Preserve indent structure as much as possible.
vim.opt.pumheight = 10 -- Height of the pop up menu.
vim.opt.relativenumber = true -- Show relative numberline.
vim.opt.shiftwidth = 2 -- Number of space inserted for indentation.
vim.opt.showmode = false -- Disable showing modes in command line.
vim.opt.showtabline = 2 -- always display tabline.
vim.opt.signcolumn = "yes" -- Always show the sign column.
vim.opt.smartcase = true -- Case sensitivie searching.
vim.opt.smartindent = true -- Smarter autoindentation.
vim.opt.splitbelow = true -- Splitting a new window below the current one.
vim.opt.splitright = true -- Splitting a new window at the right of the current one.
vim.opt.tabstop = 2 -- Number of space in a tab.

-- Define an augroup for toggling relative numbers
local numbertoggle_group = vim.api.nvim_create_augroup("numbertoggle", { clear = true })

-- Toggle relative numbers when entering/leaving insert mode or focusing/defocusing windows
vim.api.nvim_create_autocmd(
  { "BufEnter", "FocusGained", "InsertLeave", "WinEnter" },
  {
    group = numbertoggle_group,
    pattern = "*",
    callback = function()
      if vim.opt.number:get() and vim.fn.mode() ~= "i" then
        vim.opt.relativenumber = true
      end
    end
  }
)

vim.api.nvim_create_autocmd(
  { "BufLeave", "FocusLost", "InsertEnter", "WinLeave" },
  {
    group = numbertoggle_group,
    pattern = "*",
    callback = function()
      if vim.opt.number:get() then
        vim.opt.relativenumber = false
      end
    end
  }
)

vim.opt.termguicolors = true -- Enable 24-bit RGB color in the TUI.
vim.opt.undofile = true -- Enable persistent undo between session and reboots.
vim.opt.updatetime = 250 -- Length of time to wait before triggering the plugin.
vim.opt.virtualedit = "block" -- Allow going past end of line in visual block mode.
vim.opt.writebackup = false -- Disable making a backup before overwriting a file.
vim.opt.shada = "!,'1000,<50,s10,h" -- Remember the last 1000 opened files
vim.opt.history = 1000 -- Number of commands to remember in a history table (per buffer).
vim.opt.swapfile = false -- Ask what state to recover when opening a file that was not saved.
vim.opt.wrap = true -- Disable wrapping of lines longer than the width of window.
vim.opt.colorcolumn = "80" -- PEP8 like character limit vertical bar.
vim.opt.mousescroll = "ver:1,hor:0" -- Disables hozirontal scroll in neovim.
vim.opt.guicursor = "n:blinkon200,i-ci-ve:ver25" -- Enable cursor blink.
vim.opt.autochdir = true -- Use current file dir as working dir (See project.nvim).
vim.opt.scrolloff = 1000 -- Number of lines to leave before/after the cursor when scrolling. Setting a high value keep the cursor centered.
vim.opt.sidescrolloff = 8 -- Same but for side scrolling.
vim.opt.selection = "old" -- Don't select the newline symbol when using <End> on visual mode.

vim.opt.viewoptions:remove "curdir" -- Disable saving current directory with views.
vim.opt.shortmess:append { s = true, I = true } -- Disable startup message.
vim.opt.backspace:append { "nostop" } -- Don't stop backspace at insert.
vim.opt.diffopt:append { "algorithm:histogram", "linematch:60" } -- Enable linematch diff algorithm
vim.opt.breakindent = true -- Wrap indent to match  line start.

--:hi normal guibg=NONE
vim.api.nvim_set_hl(0, "Normal", { bg = "NONE" })
-- vim.api.nvim_set_hl(0, "CursorLine", { bg = "NONE" })
--vim.api.nvim_set_hl(0, "CursorLine", {default=true, blend=50})
--vim.api.nvim_set_hl(0, "CursorLine", { bg = "NONE", fg = "#F5261D" })
vim.api.nvim_set_hl(0, "CursorLine", { bg = "#222020" })
--vim.api.nvim_set_hl(0, "CursorLine", { bg = "NONE", underline = true, bold = true, sp = "#EEDAAD", italic = true, blend = 15 })
vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#FFD700", bold = true }) -- Gold color for the line number
vim.api.nvim_set_hl(0, "NvimTreeNormal", { bg = "NONE" })
vim.api.nvim_set_hl(0, "EndOfBuffer", { bg = "NONE" })
--vim.api.nvim_set_hl(0, "SignColumn", { bg = "NONE" })

-- Sidebar
--vim.api.nvim_set_hl(0, "LineNr", { bg = "NONE", fg = "#AAAAAA" })
--vim.api.nvim_set_hl(0, "CursorLineNr", { bg = "NONE", fg = "#FFFFFF" })
vim.api.nvim_set_hl(0, "LineNr", { bg = "NONE" })
-- vim.api.nvim_set_hl(0, "CursorLineNr", { bg = "NONE" })
vim.api.nvim_set_hl(0, "SignColumn", { bg = "NONE" })

-- Diagnostics
vim.api.nvim_set_hl(0, "DiagnosticSignWarn", { bg = "NONE", fg = "#FFA500" })
vim.api.nvim_set_hl(0, "DiagnosticSignError", { bg = "NONE", fg = "#FF0000" })
vim.api.nvim_set_hl(0, "DiagnosticSignInfo", { bg = "NONE", fg = "#00FFFF" })
vim.api.nvim_set_hl(0, "DiagnosticSignHint", { bg = "NONE", fg = "#00FF00" })

-- Top bar
vim.api.nvim_set_hl(0, "StatusLine", { bg = "NONE", fg = "#FFFFFF" })
vim.api.nvim_set_hl(0, "StatusLineNC", { bg = "NONE", fg = "#AAAAAA" })

-- Tabline
vim.api.nvim_set_hl(0, "TabLine", { bg = "NONE", fg = "#AAAAAA" })
vim.api.nvim_set_hl(0, "TabLineSel", { bg = "NONE", fg = "#FFFFFF" })
vim.api.nvim_set_hl(0, "TabLineFill", { bg = "NONE" })

-- WinBar
vim.api.nvim_set_hl(0, "WinBar", { bg = "NONE", fg = "#FFFFFF" })
vim.api.nvim_set_hl(0, "WinBarNC", { bg = "NONE", fg = "#AAAAAA" })
