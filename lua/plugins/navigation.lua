-- Navigation layer: pickers, file management, project roots.

return {
  -- The one icon provider for the whole config.
  {
    "nvim-mini/mini.icons",
    lazy = true,
    opts = {},
    init = function()
      -- Plugins that require nvim-web-devicons by name get mini.icons instead.
      package.preload["nvim-web-devicons"] = function()
        require("mini.icons").mock_nvim_web_devicons()
        return package.loaded["nvim-web-devicons"]
      end
    end,
  },

  {
    "ibhagwan/fzf-lua",
    cmd = "FzfLua",
    dependencies = { "nvim-mini/mini.icons" },
    -- A function: the action table requires a fzf-lua module, which does not
    -- exist until the plugin is on the runtimepath.
    opts = function()
      local actions = require("fzf-lua.actions")
      return {
        -- Uses fzf's own previewer through bat, which is therefore a requirement.
        "fzf-native",
        actions = {
          -- The moved keys are all ones Zellij takes first: ctrl-s (scroll
          -- mode), alt-h / alt-i / alt-f (pane and tab movement). ctrl-t is
          -- dropped rather than moved, since Zellij owns tabs here.
          files = {
            ["enter"] = actions.file_edit_or_qf,
            ["ctrl-v"] = actions.file_vsplit,
            ["ctrl-x"] = actions.file_split,
            ["alt-."] = actions.toggle_hidden,
            ["alt-,"] = actions.toggle_ignore,
            ["alt-/"] = actions.toggle_follow,
            -- Replaces the upstream defaults outright, so they are repeated here.
            ["alt-q"] = actions.file_sel_to_qf,
            ["alt-Q"] = actions.file_sel_to_ll,
          },
        },
      }
    end,
    keys = {
      { "<leader>ff", "<cmd>FzfLua files<cr>", desc = "Files" },
      { "<leader>fg", "<cmd>FzfLua live_grep<cr>", desc = "Grep" },
      { "<leader>fw", "<cmd>FzfLua grep_cword<cr>", desc = "Word under cursor" },
      { "<leader>fb", "<cmd>FzfLua buffers<cr>", desc = "Buffers" },
      { "<leader>fo", "<cmd>FzfLua oldfiles<cr>", desc = "Recent files" },
      { "<leader>fh", "<cmd>FzfLua helptags<cr>", desc = "Help tags" },
      { "<leader>fk", "<cmd>FzfLua keymaps<cr>", desc = "Keymaps" },
      { "<leader>fd", "<cmd>FzfLua diagnostics_document<cr>", desc = "Diagnostics" },
      { "<leader>fr", "<cmd>FzfLua resume<cr>", desc = "Resume last picker" },
    },
  },

  -- oil.nvim: a directory as a buffer. Upstream states lazy loading is not
  -- recommended, hence lazy = false.
  {
    "stevearc/oil.nvim",
    lazy = false,
    dependencies = { "nvim-mini/mini.icons" },
    opts = {
      -- oil takes over directory buffers; netrw is disabled below, so nothing
      -- competes for them.
      default_file_explorer = true,
      view_options = {
        show_hidden = true,
      },
      keymaps = {
        -- Four oil defaults land on keys Zellij eats, so they are moved and the
        -- originals disabled rather than left dead. Preview goes to a
        -- g-prefixed key, matching oil's own idiom (g?, gs, gx, g., g\).
        ["<C-s>"] = false,
        ["<C-h>"] = false,
        ["<C-t>"] = false,
        ["<C-p>"] = false,
        ["<C-v>"] = { "actions.select", opts = { vertical = true } },
        ["<C-x>"] = { "actions.select", opts = { horizontal = true } },
        ["gp"] = "actions.preview",
      },
    },
    keys = {
      { "-", "<cmd>Oil<cr>", desc = "Open parent directory (oil)" },
      { "<leader>fe", "<cmd>Oil<cr>", desc = "File explorer (oil)" },
    },
  },

  {
    "mikavilpas/yazi.nvim",
    version = "*",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      open_for_directories = false,
      keymaps = {
        show_help = "<f1>",
      },
    },
    init = function()
      -- Consistent with oil owning directory buffers: netrw is not wanted here.
      vim.g.loaded_netrw = 1
      vim.g.loaded_netrwPlugin = 1
    end,
    keys = {
      { "<leader>fy", "<cmd>Yazi<cr>", mode = { "n", "v" }, desc = "Yazi at current file" },
      { "<leader>fY", "<cmd>Yazi cwd<cr>", desc = "Yazi at working directory" },
      { "<leader>ft", "<cmd>Yazi toggle<cr>", desc = "Resume last yazi session" },
    },
  },

  -- The DrKJeff16 fork, not ahmedkhalf/project.nvim.
  {
    "DrKJeff16/project.nvim",
    event = "VeryLazy",
    dependencies = { "ibhagwan/fzf-lua" },
    opts = {
      fzf_lua = {
        enabled = true,
        sort = "newest",
        show = "paths",
      },
    },
    keys = {
      { "<leader>pp", "<cmd>Project fzf-lua<cr>", desc = "Projects" },
    },
  },
}
