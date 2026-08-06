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

  -- snacks.nvim — base spec.
  --
  -- The contract named `alpha` for the start screen. snacks is already a
  -- dependency (it provides lazygit in the git layer) and ships a dashboard
  -- module that detects fzf-lua on its own, so using it removes a plugin
  -- rather than adding one. alpha is not abandoned — last push 2026-04 — so
  -- this is a deduplication, not a rejection.
  --
  -- The dashboard has to draw on an empty start, which is why snacks now
  -- loads eagerly with a high priority, as upstream recommends. The git layer
  -- only adds its lazygit keys and options on top of this spec.
  {
    "folke/snacks.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      dashboard = {
        enabled = true,
        sections = {
          { section = "header" },
          { section = "keys", gap = 1, padding = 1 },
          { section = "recent_files", title = "Recent files", indent = 2, padding = 1 },
          { section = "projects", title = "Projects", indent = 2, padding = 1 },
          { section = "startup" },
        },
        preset = {
          -- Actions are written as the keymaps this config already defines,
          -- so the dashboard stays in step with them instead of duplicating
          -- command strings that could drift.
          keys = {
            { icon = " ", key = "f", desc = "Find file", action = "<leader>ff" },
            { icon = " ", key = "g", desc = "Grep", action = "<leader>fg" },
            { icon = " ", key = "r", desc = "Recent files", action = "<leader>fo" },
            { icon = " ", key = "p", desc = "Projects", action = "<leader>pp" },
            { icon = " ", key = "e", desc = "File explorer", action = "<leader>fe" },
            { icon = " ", key = "c", desc = "Config", action = ":e $MYVIMRC" },
            { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
            { icon = " ", key = "m", desc = "Mason", action = ":Mason" },
            { icon = " ", key = "q", desc = "Quit", action = ":qa" },
          },
        },
      },
    },
  },

  -- Code outline. Distinct from trouble on purpose: aerial answers "what is
  -- in this file and where", trouble answers "what is wrong and where".
  -- Backends default to treesitter first, then LSP, so it works even for
  -- filetypes with no language server attached.
  {
    "stevearc/aerial.nvim",
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-mini/mini.icons" },
    cmd = { "AerialToggle", "AerialOpen", "AerialNavToggle" },
    opts = {
      backends = { "treesitter", "lsp", "markdown", "man" },
      layout = {
        default_direction = "prefer_right",
        resize_to_content = true,
      },
      on_attach = function(buf)
        -- Upstream's example binds `{` and `}` here. Those are Neovim's
        -- paragraph motions, and aerial attaches to ordinary source buffers,
        -- so taking them would remove a core movement everywhere the outline
        -- is active — the opposite of what the contract asks for. `[s` and
        -- `]s` follow the bracket-motion convention instead and shadow only
        -- spell-check navigation, which is off in this config.
        vim.keymap.set("n", "[s", "<cmd>AerialPrev<cr>", { buffer = buf, desc = "Previous symbol" })
        vim.keymap.set("n", "]s", "<cmd>AerialNext<cr>", { buffer = buf, desc = "Next symbol" })
      end,
    },
    keys = {
      { "<leader>lo", "<cmd>AerialToggle<cr>", desc = "Outline" },
    },
  },

  -- Diagnostics, quickfix and LSP result lists in a proper panel.
  --
  -- v3 is a full rewrite and the old command is gone: `TroubleToggle` no
  -- longer exists, the syntax is now `Trouble <mode> <action>`. Anything
  -- copied from a pre-2024 guide will fail.
  --
  -- The `symbols` mode is deliberately unused: aerial already owns outlines,
  -- and having two ways to list the same thing is exactly the kind of
  -- accidental duplication the contract rules out.
  {
    "folke/trouble.nvim",
    cmd = "Trouble",
    opts = {},
    keys = {
      { "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>", desc = "Diagnostics (workspace)" },
      { "<leader>xX", "<cmd>Trouble diagnostics toggle filter.buf=0<cr>", desc = "Diagnostics (buffer)" },
      { "<leader>xq", "<cmd>Trouble qflist toggle<cr>", desc = "Quickfix list" },
      { "<leader>xL", "<cmd>Trouble loclist toggle<cr>", desc = "Location list" },
      {
        "<leader>lt",
        "<cmd>Trouble lsp toggle focus=false win.position=right<cr>",
        desc = "LSP references and definitions",
      },
    },
  },

  -- Markdown rendered in the buffer. Every infrastructure repository is half
  -- README, and this config already installs the markdown and markdown_inline
  -- parsers it needs.
  {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-mini/mini.icons" },
    ft = { "markdown" },
    opts = {},
  },
}
