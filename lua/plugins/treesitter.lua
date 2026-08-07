-- Treesitter layer.

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
      -- Only what is missing: install() on the full list checks every parser on
      -- every start.
      local installed = {}
      for _, name in ipairs(require("nvim-treesitter.config").get_installed("parsers")) do
        installed[name] = true
      end

      local missing = vim.tbl_filter(function(name)
        return not installed[name]
      end, parsers)

      if #missing > 0 then
        require("nvim-treesitter").install(missing)
      end

      local group = vim.api.nvim_create_augroup("devops_treesitter", { clear = true })

      -- 'foldmethod' and 'foldexpr' are window options, not buffer options.
      local function set_folding(buf)
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          -- [win][0] is `:setlocal` for this window-buffer pair.
          vim.wo[win][0].foldmethod = "expr"
          vim.wo[win][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
        end
      end

      vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function(ev)
          if vim.b[ev.buf].devops_treesitter then
            set_folding(ev.buf)
          end
        end,
      })

      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        callback = function(ev)
          -- Fails for any filetype without an installed parser, which is
          -- expected and not an error worth reporting.
          if not pcall(vim.treesitter.start, ev.buf) then
            return
          end

          vim.b[ev.buf].devops_treesitter = true
          set_folding(ev.buf)

          -- Treesitter indentation is deliberately NOT enabled.
        end,
      })
    end,
  },
}
