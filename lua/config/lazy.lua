-- lazy.nvim bootstrap and setup.
--
-- Verified against https://lazy.folke.io/installation and the default option
-- table at https://lazy.folke.io/configuration, lazy.nvim v11.17.5 (2025-11-06).
-- lazy.nvim requires Neovim >= 0.8 (LuaJIT) and git >= 2.19.

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    lazyrepo,
    lazypath,
  })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end

vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  -- Every file under lua/plugins/ is a spec module. One file per domain.
  spec = { { import = "plugins" } },

  -- Tracked in git, so the plugin set is reproducible across machines.
  lockfile = vim.fn.stdpath("config") .. "/lazy-lock.json",

  install = {
    missing = true,
    -- Used only while plugins are still installing on first start. habamax is
    -- a built-in fallback in case catppuccin is not on disk yet.
    colorscheme = { "catppuccin-mocha", "habamax" },
  },

  -- No plugin in this config ships a rockspec, so hererocks/luarocks would be
  -- an unused dependency that :checkhealth lazy reports as an error. Re-enable
  -- if a future plugin genuinely requires it.
  rocks = { enabled = false },

  -- Off by default upstream. Enabled here because the contract commits to
  -- actively maintained plugins, so drift should be visible. notify = false
  -- keeps it from interrupting; check the state in :Lazy.
  checker = {
    enabled = true,
    notify = false,
    frequency = 3600,
  },

  -- Reload specs on change, but without a popup on every write.
  change_detection = {
    enabled = true,
    notify = false,
  },

  performance = {
    cache = { enabled = true },
    rtp = {
      -- Built-ins that ship with Neovim 0.12 and are unused in this workflow.
      -- Archive browsing is handled by yazi/oil, not by the vim archive plugins.
      -- netrw is deliberately NOT disabled here — that belongs with the
      -- oil.nvim setup, which documents how it wants netrw handled.
      disabled_plugins = {
        "gzip",
        "tarPlugin",
        "zipPlugin",
        "tutor",
      },
    },
  },
})
