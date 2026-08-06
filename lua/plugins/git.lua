-- Git layer.
--
-- Two plugins, one of them not the one the contract originally named.
--
-- The contract said `lazygit.nvim` (kdheepak). The survey rejected it: last
-- push 2025-12, 52 open issues, and no colourscheme integration. snacks.nvim
-- ships a lazygit module that generates a lazygit theme from the active Neovim
-- colourscheme, so lazygit comes up in Catppuccin Mocha instead of its own
-- palette — which is the whole point of the contract's colour rule. snacks is
-- already on the plugin list, so this removes a dependency rather than adding
-- one.
--
-- API NOTE for gitsigns: the keymap block found in most guides calls three
-- functions that upstream now marks DEPRECATED —
--
--   next_hunk() / prev_hunk()  ->  nav_hunk('next') / nav_hunk('prev')
--   undo_stage_hunk()          ->  stage_hunk() on a staged sign, it toggles
--   toggle_deleted()           ->  preview_hunk_inline()
--
-- The mappings below use the current API.

return {
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      signs = {
        add = { text = "▎" },
        change = { text = "▎" },
        delete = { text = "" },
        topdelete = { text = "" },
        changedelete = { text = "▎" },
        untracked = { text = "▎" },
      },
      -- Off by default; toggled with <leader>gB when it is actually wanted.
      -- Permanent inline blame is noise while writing manifests.
      current_line_blame = false,

      on_attach = function(buf)
        local gs = require("gitsigns")

        local function map(mode, lhs, rhs, desc)
          vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc })
        end

        -- Navigation. In a diff split, ]c and [c are Neovim's own hunk motions
        -- and are left alone; ]h and [h are used here so both work.
        map("n", "]h", function()
          if vim.wo.diff then
            vim.cmd.normal({ "]c", bang = true })
          else
            gs.nav_hunk("next")
          end
        end, "Next hunk")

        map("n", "[h", function()
          if vim.wo.diff then
            vim.cmd.normal({ "[c", bang = true })
          else
            gs.nav_hunk("prev")
          end
        end, "Previous hunk")

        -- Staging. stage_hunk on an already-staged sign unstages it, which is
        -- what replaced the deprecated undo_stage_hunk.
        map("n", "<leader>gs", gs.stage_hunk, "Stage hunk (toggles when staged)")
        map("n", "<leader>gr", gs.reset_hunk, "Reset hunk")
        map("v", "<leader>gs", function()
          gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
        end, "Stage selected lines")
        map("v", "<leader>gr", function()
          gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
        end, "Reset selected lines")
        map("n", "<leader>gS", gs.stage_buffer, "Stage buffer")
        map("n", "<leader>gR", gs.reset_buffer, "Reset buffer")

        -- Inspection
        map("n", "<leader>gp", gs.preview_hunk_inline, "Preview hunk inline")
        map("n", "<leader>gb", function()
          gs.blame_line({ full = true })
        end, "Blame line")
        map("n", "<leader>gB", gs.toggle_current_line_blame, "Toggle inline blame")
        map("n", "<leader>gd", gs.diffthis, "Diff against index")

        -- Hunk as a text object: dih, vih, and so on.
        map({ "o", "x" }, "ih", gs.select_hunk, "Hunk")
      end,
    },
  },

  {
    "folke/snacks.nvim",
    -- Only the lazygit module is enabled, and it is only ever reached through
    -- the keys below, so the plugin is lazy-loaded. Upstream recommends
    -- lazy = false with priority = 1000, but that is for configurations where
    -- other plugins depend on snacks being set up early. Nothing here does yet.
    -- Revisit if a snacks module that must run at startup is adopted.
    keys = {
      {
        "<leader>gg",
        function()
          Snacks.lazygit.open()
        end,
        desc = "Lazygit",
      },
      {
        "<leader>gl",
        function()
          Snacks.lazygit.log()
        end,
        desc = "Lazygit log",
      },
      {
        "<leader>gf",
        function()
          Snacks.lazygit.log_file()
        end,
        desc = "Lazygit file history",
      },
    },
    opts = {
      lazygit = {
        -- Generates a lazygit theme from the current Neovim colourscheme.
        configure = true,
      },
    },
  },

  -- Commit search belongs to the picker, not to lazygit: this is for finding a
  -- commit by message, which lazygit's log is poor at.
  {
    "ibhagwan/fzf-lua",
    optional = true,
    keys = {
      { "<leader>gc", "<cmd>FzfLua git_commits<cr>", desc = "Search commits" },
      { "<leader>gC", "<cmd>FzfLua git_bcommits<cr>", desc = "Search buffer commits" },
    },
  },
}
