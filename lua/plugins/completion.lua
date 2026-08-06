-- Completion layer.
--
-- blink.cmp pinned to the v1 line: there is no v2 release tag at all, only an
-- unreleased v2 on the main branch. `version = "1.*"` also selects the
-- prebuilt Rust binaries, so no local cargo toolchain is needed — curl and git
-- are enough, and both are present.
--
-- LSP capabilities are NOT wired up by hand. From Neovim 0.11 onward blink
-- registers its capabilities through vim.lsp.config itself, so the
-- get_lsp_capabilities() dance that older guides describe is obsolete here.
-- Verified: vim.lsp.config['*'] ends up carrying both blink's completion
-- capabilities and the root_markers set in plugins/lsp.lua — they merge rather
-- than overwrite each other.
--
-- This plugin is deliberately NOT lazy-loaded, matching upstream's own
-- snippet. Because blink injects its capabilities into vim.lsp.config, it has
-- to be loaded before the first LSP client starts. Deferring it to InsertEnter
-- would let clients attach on BufReadPre with the plain built-in capabilities,
-- quietly degrading completion. The cost is measured: startup goes from ~15ms
-- to ~20ms, which is worth paying for correctness.

return {
  {
    "saghen/blink.cmp",
    dependencies = { "rafamadriz/friendly-snippets" },
    version = "1.*",
    ---@module 'blink.cmp'
    ---@type blink.cmp.Config
    opts = {
      keymap = {
        preset = "default",

        -- Three keys in the default preset never reach Neovim, because the
        -- local Zellij captures them: <C-n> (resize mode), <C-p> (pane mode)
        -- and <C-b> (tmux mode). In the default preset those are precisely
        -- next item, previous item and scroll-documentation-up — the keys used
        -- most while completing. They are left bound (they are inert, not
        -- harmful) and working alternatives are added on Zellij-free keys.
        ["<C-j>"] = { "select_next", "fallback" },
        ["<C-k>"] = { "select_prev", "fallback" },
        ["<C-d>"] = { "scroll_documentation_down", "fallback" },
        ["<C-u>"] = { "scroll_documentation_up", "fallback" },

        -- <C-k> is signature help in the default preset and has just been
        -- taken over above, so signature help moves here. <C-l> is free in
        -- both Zellij and insert mode.
        ["<C-l>"] = { "show_signature", "hide_signature", "fallback" },
      },

      appearance = {
        -- Nerd Fonts are installed locally in their Mono variants
        -- (MesloLG…NerdFontMono), which is what this setting expects.
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
      },

      -- Falls back to the Lua matcher with a warning if the prebuilt binary is
      -- unavailable, rather than failing outright.
      fuzzy = { implementation = "prefer_rust_with_warning" },
    },
    opts_extend = { "sources.default" },
  },
}
