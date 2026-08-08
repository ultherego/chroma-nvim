-- Git layer.

return {
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      signs = {
        add = { text = "▎" },
        change = { text = "▎" },
        -- Deleted lines have no line of their own, so the mark goes on the boundary;
        -- leaving it empty hides the deletion entirely.
        delete = { text = "▁" },
        topdelete = { text = "▔" },
        changedelete = { text = "▎" },
        untracked = { text = "▎" },
      },
      -- Off by default; toggled with <leader>gB when it is actually wanted.
      -- Permanent inline blame is noise while writing manifests.
      current_line_blame = false,

      on_attach = function(buf)
        -- Staging does not write the working tree, it writes `.git/index` and a
        -- blob object — so a buffer holding a decrypted vault would put the
        -- plaintext in git, past everything that guards the file itself.
        -- Measured: `stage_buffer` on such a buffer left the secret in the index
        -- and the ciphertext gone. Returning false here means never attaching.
        if vim.b[buf].ansible_vault_plain then
          return false
        end

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
    -- Called through require("snacks") rather than the `Snacks` global.
    keys = {
      {
        "<leader>gg",
        function()
          require("snacks").lazygit.open()
        end,
        desc = "Lazygit",
      },
      {
        "<leader>gl",
        function()
          require("snacks").lazygit.log()
        end,
        desc = "Lazygit log",
      },
      {
        "<leader>gf",
        function()
          require("snacks").lazygit.log_file()
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
