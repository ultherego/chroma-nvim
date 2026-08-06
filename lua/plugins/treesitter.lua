-- Treesitter layer.
--
-- BRANCH MATTERS. nvim-treesitter has two live branches and they are not
-- compatible:
--
--   master  legacy, for Neovim 0.11
--   main    a full rewrite, recommended for Neovim 0.12+  <- this one
--
-- Almost every guide and config online still targets `master`, where setup
-- looked like this:
--
--   require('nvim-treesitter.configs').setup({ highlight = { enable = true } })
--
-- That module does not exist on `main`. Parsers are installed through
-- require('nvim-treesitter').install(), and highlighting is switched on per
-- buffer with vim.treesitter.start().
--
-- Local prerequisites, all verified present: tree-sitter-cli 0.26.9 (upstream
-- requires >= 0.26.1 and specifically not the npm build — this one comes from
-- pacman), a C compiler, tar and curl.
--
-- Neovim 0.12 already bundles parsers for c, lua, markdown, markdown_inline,
-- query, vim and vimdoc. They are still listed below so that :TSUpdate keeps
-- them current rather than leaving two versions in play.

local parsers = {
  -- Infrastructure as code
  "terraform",
  "hcl",
  -- Kubernetes, Helm, CI
  "yaml",
  "helm",
  "gotmpl",
  "dockerfile",
  -- Scripting and config formats
  "bash",
  "python",
  "lua",
  "json",
  "toml",
  "ini",
  "xml",
  "sql",
  "make",
  "ssh_config",
  -- Go, for reading operators and controllers
  "go",
  "gomod",
  -- Git
  "git_config",
  "gitcommit",
  "gitignore",
  "diff",
  -- Editor and docs
  "markdown",
  "markdown_inline",
  "regex",
  "query",
  "vim",
  "vimdoc",
}

return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    -- Upstream is explicit: this plugin does not support lazy-loading.
    lazy = false,
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter").install(parsers)

      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("devops_treesitter", { clear = true }),
        callback = function(ev)
          -- Fails for any filetype without an installed parser, which is
          -- expected and not an error worth reporting.
          if not pcall(vim.treesitter.start, ev.buf) then
            return
          end

          vim.wo.foldmethod = "expr"
          vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"

          -- Treesitter indentation is deliberately NOT enabled.
          --
          -- Neovim ships mature indent scripts for every language that matters
          -- here — yaml, terraform, hcl, json, lua, bash, python, go all have
          -- one in $VIMRUNTIME/indent. Replacing them with
          -- nvim-treesitter.indentexpr() would trade a known-good
          -- implementation for an experimental one, and YAML indentation in
          -- particular is where that goes wrong first.
        end,
      })
    end,
  },
}
