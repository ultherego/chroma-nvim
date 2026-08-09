-- UI layer.

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
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = function()
      local state = require("chroma.state")

      -- The four DevOps groups are labels for keys that only exist when their
      -- component does, so with the component off the group is a heading over
      -- an empty list. which-key shows it anyway, which reads as a feature that
      -- is present and broken rather than one that was not selected.
      local spec = {
        { "<leader>f", group = "Find" },
        { "<leader>p", group = "Project" },
        { "<leader>g", group = "Git" },
        { "<leader>l", group = "LSP" },
        { "<leader>b", group = "Buffers" },
        { "<leader>w", group = "Windows" },
        { "<leader>s", group = "Sessions" },
        { "<leader>x", group = "Tools" },
      }

      for _, group in ipairs({
        { component = "terraform", lhs = "<leader>t", name = "Terraform" },
        { component = "kubernetes", lhs = "<leader>k", name = "Kubernetes" },
        { component = "ansible", lhs = "<leader>a", name = "Ansible" },
        { component = "aws", lhs = "<leader>A", name = "AWS" },
      }) do
        if state.is_enabled(group.component) then
          table.insert(spec, { group.lhs, group = group.name })
        end
      end

      return {
        preset = "modern",
        spec = spec,
      }
    end,
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
          -- Written as the keymaps this config already defines, so the dashboard
          -- cannot drift from them.
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
        -- Not `{` and `}` as upstream suggests: aerial attaches to source buffers,
        -- where those are the paragraph motions.
        vim.keymap.set("n", "[s", "<cmd>AerialPrev<cr>", { buffer = buf, desc = "Previous symbol" })
        vim.keymap.set("n", "]s", "<cmd>AerialNext<cr>", { buffer = buf, desc = "Next symbol" })
      end,
    },
    keys = {
      { "<leader>lo", "<cmd>AerialToggle<cr>", desc = "Outline" },
    },
  },

  -- Diagnostics, quickfix and LSP result lists in a proper panel.
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

  -- Markdown rendered in the buffer; the parsers it needs are already installed.
  {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-mini/mini.icons" },
    ft = { "markdown" },
    opts = {},
  },
}
