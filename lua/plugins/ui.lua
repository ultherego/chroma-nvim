-- UI layer.

-- The wordmark `chroma install` prints (cli/internal/report/banner.go), so the
-- installer and the editor are recognisably one thing.
--
-- Two details that are not decoration: the trailing spaces pad both halves to
-- the same width, because every line is centred on its own and a narrower block
-- would start a column further in; and the empty string closing the first block
-- is the newline that keeps Neovim off the end of Chroma's last line.
local WORDMARK = {
  {
    table.concat({
      "█▀▀ █ █ █▀▄ █▀█ █▀▄▀█ ▄▀█",
      "█   █▀█ █▀▄ █ █ █ ▀ █ █▀█",
      "▀▀▀ ▀ ▀ ▀ ▀ ▀▀▀ ▀   ▀ ▀ ▀",
      "",
    }, "\n"),
    -- Syntax groups rather than hex: mauve and peach under catppuccin-mocha,
    -- and still two related colours under any other colorscheme.
    hl = "Statement",
  },
  {
    table.concat({
      "█▄ █ █▀▀ █▀█ █ █ █ █▀▄▀█ ",
      "█ ▀█ █▀▀ █ █ ▀▄▀ █ █ ▀ █ ",
      "▀  ▀ ▀▀▀ ▀▀▀  ▀  ▀ ▀   ▀ ",
    }, "\n"),
    hl = "Constant",
  },
}

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

      -- The four DevOps groups below label keys that only exist when their
      -- component does; which-key would otherwise show a heading over nothing.
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

      -- A heading follows the components that define the keys under it, not
      -- the one it is named after: `<leader>a` carries both the planner's two
      -- keys and the vault's seven, and the two components are independent. The
      -- name stays Ansible, because Ansible Vault is Ansible's.
      for _, group in ipairs({
        { components = { "terraform" }, lhs = "<leader>t", name = "Terraform" },
        { components = { "kubernetes" }, lhs = "<leader>k", name = "Kubernetes" },
        { components = { "ansible", "vault" }, lhs = "<leader>a", name = "Ansible" },
        { components = { "aws" }, lhs = "<leader>A", name = "AWS" },
      }) do
        for _, component in ipairs(group.components) do
          if state.is_enabled(component) then
            table.insert(spec, { group.lhs, group = group.name })
            break
          end
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
    -- Called through require("snacks") rather than the `Snacks` global, as in
    -- git.lua.
    keys = {
      {
        "<leader>xs",
        function()
          -- No command, so this is a shell in a split and the same one every
          -- time: snacks identifies a terminal by command, directory,
          -- environment and count, so this toggles the one left running.
          require("snacks").terminal.toggle()
        end,
        desc = "Shell",
      },
    },
    opts = {
      dashboard = {
        enabled = true,
        -- One blank line between neighbours and none inside a list; the
        -- built-in header and `keys` section are both looser than that.
        sections = {
          { text = WORDMARK, align = "center", padding = 1 },
          { section = "keys", padding = 1 },
          { section = "recent_files", title = "Recent files", indent = 2, padding = 1 },
          { section = "projects", title = "Projects", indent = 2, padding = 1 },
          { section = "startup" },
        },
        preset = {
          -- Written as the keymaps this config defines, so they cannot drift.
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

  -- Distinct from trouble on purpose: aerial answers "what is in this file and
  -- where", trouble answers "what is wrong and where".
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
        -- Not `{` and `}` as upstream suggests: aerial attaches to source
        -- buffers, where those are the paragraph motions.
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
