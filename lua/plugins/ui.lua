-- UI layer.
--
-- Catppuccin, verified against https://github.com/catppuccin/nvim (README).
--
-- IMPORTANT: the colorscheme is `catppuccin-mocha`, not `catppuccin`.
-- Neovim 0.12 ships its own built-in `catppuccin` colorscheme
-- (/usr/share/nvim/runtime/colors/catppuccin.vim), which is a different theme.
-- Because of that clash the plugin renamed its scheme to `catppuccin-nvim`,
-- with per-flavour names `catppuccin-{latte,frappe,macchiato,mocha}`.
-- Using the bare name loads Neovim's built-in without raising any error.

return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    -- Loaded eagerly and first, so no other plugin renders against the
    -- default colorscheme before this one applies.
    lazy = false,
    priority = 1000,
    opts = {
      flavour = "mocha",
      background = {
        light = "latte",
        dark = "mocha",
      },
      transparent_background = false,
    },
    config = function(_, opts)
      require("catppuccin").setup(opts)
      vim.cmd.colorscheme("catppuccin-mocha")
    end,
  },
}
