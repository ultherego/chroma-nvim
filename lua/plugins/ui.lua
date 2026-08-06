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

  -- which-key, verified against https://github.com/folke/which-key.nvim
  -- (v3 spec format; requires Neovim >= 0.9.4).
  --
  -- This is where the contract's keymap groups are declared. Every <leader>
  -- prefix is assigned exactly once, here, so a conflict shows up as a visible
  -- duplicate rather than as a mapping that silently stops working.
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      preset = "modern",
      spec = {
        { "<leader>f", group = "Find" },
        { "<leader>p", group = "Project" },
        { "<leader>g", group = "Git" },
        { "<leader>l", group = "LSP" },
        { "<leader>t", group = "Terraform" },
        { "<leader>k", group = "Kubernetes" },
        { "<leader>a", group = "Ansible" },
        { "<leader>A", group = "AWS" },
        { "<leader>b", group = "Buffers" },
        { "<leader>w", group = "Windows" },
        { "<leader>s", group = "Sessions" },
        { "<leader>x", group = "Tools" },
      },
    },
    keys = {
      {
        "<leader>?",
        function()
          require("which-key").show({ global = false })
        end,
        desc = "Buffer-local keymaps",
      },
    },
  },
}
