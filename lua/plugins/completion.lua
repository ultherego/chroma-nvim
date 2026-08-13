-- Completion layer.

return {
  {
    "saghen/blink.cmp",
    dependencies = { "rafamadriz/friendly-snippets" },

    -- A tag, not a range and not a bare commit: v1.10.2 is off the default
    -- branch, so a narrow fetch that misses it leaves `main` — which is v2 —
    -- on disk. See DECISIONS.md, "blink.cmp is pinned by tag".
    tag = "v1.10.2",
    ---@module 'blink.cmp'
    ---@type blink.cmp.Config
    opts = {
      keymap = {
        preset = "default",

        -- Zellij captures <C-n> and <C-p>, so the default preset's keys never
        -- arrive; see :help chroma-nvim-zellij.
        ["<C-j>"] = { "select_next", "fallback" },
        ["<C-k>"] = { "select_prev", "fallback" },
        ["<C-d>"] = { "scroll_documentation_down", "fallback" },
        ["<C-u>"] = { "scroll_documentation_up", "fallback" },

        -- <C-k> was taken over above, so signature help moves to a free key.
        ["<C-l>"] = { "show_signature", "hide_signature", "fallback" },
      },

      appearance = {
        -- Nerd Fonts are installed in their Mono variants, which is what this
        -- setting expects.
        nerd_font_variant = "mono",
      },

      completion = {
        documentation = {
          auto_show = true,
          auto_show_delay_ms = 200,
        },
      },

      sources = {
        default = { "lsp", "path", "snippets", "buffer" },
        providers = {
          buffer = {
            opts = {
              -- Upstream offers every visible window's buffer. A transparently
              -- decrypted vault is an ordinary file buffer, so its secrets were
              -- offered as completions in the file beside it.
              get_bufnrs = function()
                local bufs = {}
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                  local buf = vim.api.nvim_win_get_buf(win)
                  if vim.bo[buf].buftype ~= "nofile" and not vim.b[buf].ansible_vault_plain then
                    table.insert(bufs, buf)
                  end
                end
                return bufs
              end,
            },
          },
        },
      },

      -- Falls back to the Lua matcher with a warning if the prebuilt binary is
      -- unavailable, rather than failing outright.
      fuzzy = { implementation = "prefer_rust_with_warning" },
    },
    opts_extend = { "sources.default" },
  },
}
