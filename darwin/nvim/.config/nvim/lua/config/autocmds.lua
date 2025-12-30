-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- vim.api.nvim_create_autocmd("ColorScheme", {
--   callback = function()
--     vim.api.nvim_set_hl(0, "CursorLine", {
--       bg = "NONE",
--       underline = true,
--     })
--   end,
-- })

local function bold_keep_color(group)
  local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
  hl.bold = true
  vim.api.nvim_set_hl(0, group, hl)
end

vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    local groups = {
      "@function",
      "@method",
      "@keyword",
      "@type",
      "@constant",
      "@string",
      "@number",
      "@boolean",
      "@operator",
      "@variable",
    }

    for _, g in ipairs(groups) do
      bold_keep_color(g)
    end

    local transparent = "NONE"
    local subtle = "#1c1c1c"

    -- Main background
    vim.api.nvim_set_hl(0, "Normal", { bg = transparent, bold = true })
    vim.api.nvim_set_hl(0, "NormalNC", { bg = transparent })

    -- Line numbers
    vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#ffffff", bg = transparent, bold = true })
    vim.api.nvim_set_hl(0, "LineNr", { fg = "#d9d9d9", bg = transparent })

    -- Cursor line
    vim.api.nvim_set_hl(0, "CursorLine", {
      bg = "NONE",
      underline = true,
    })

    -- Gutter / sign column
    vim.api.nvim_set_hl(0, "SignColumn", { bg = transparent })
    vim.api.nvim_set_hl(0, "FoldColumn", { bg = transparent })

    -- Statusline (optional, but recommended)
    vim.api.nvim_set_hl(0, "StatusLine", { bg = subtle })
    vim.api.nvim_set_hl(0, "StatusLineNC", { bg = transparent })

    -- Comments: darker + more legible
    vim.api.nvim_set_hl(0, "Comment", {
      fg = "#7a6e8c", -- darker mauve/gray; tweak freely
      italic = true, -- optional
      bold = true, -- set true if you want extra weight
    })

    -- (optional) TODO / NOTE comments pop a bit more
    vim.api.nvim_set_hl(0, "Todo", {
      fg = "#c8a6ff",
      bold = true,
    })

    -- Remove vertical split / file tree separator
    vim.api.nvim_set_hl(0, "WinSeparator", {
      fg = "NONE",
      bg = "NONE",
    })

    vim.api.nvim_set_hl(0, "VertSplit", {
      fg = "NONE",
      bg = "NONE",
    })

    vim.api.nvim_set_hl(0, "NeoTreeWinSeparator", {
      fg = "NONE",
      bg = "NONE",
    })

    vim.api.nvim_set_hl(0, "StatusLine", { bg = "NONE", fg = "#d9d9d9", underline = true })
    vim.api.nvim_set_hl(0, "StatusLineNC", { bg = "NONE", fg = "#7a7a7a" })

    vim.api.nvim_set_hl(0, "NeoTreeNormal", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "NeoTreeNormalNC", { bg = "NONE" })

    -- Make statusline transparent
    vim.api.nvim_set_hl(0, "lualine_c_normal", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "lualine_x_normal", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "lualine_y_normal", { bg = "NONE" })
    vim.api.nvim_set_hl(0, "lualine_z_normal", { bg = "NONE" })

    vim.api.nvim_set_hl(0, "lualine_c_inactive", { bg = "NONE" })
  end,
})
