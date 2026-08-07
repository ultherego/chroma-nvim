-- lazy.nvim bootstrap and setup.

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

  -- SECURITY. lazy.nvim defaults this to true, which makes it load a
  -- project-local `.lazy.lua` from whatever directory Neovim was started in.
  local_spec = false,

  install = {
    missing = true,
    -- Used only while plugins are still installing on first start. habamax is
    -- a built-in fallback in case catppuccin is not on disk yet.
    colorscheme = { "catppuccin-mocha", "habamax" },
  },

  -- No plugin here ships a rockspec, so luarocks would be an unused dependency
  -- that :checkhealth lazy reports as an error.
  rocks = { enabled = false },

  -- On, because the contract commits to maintained plugins and drift should be
  -- visible; quiet, because a notification on every start is not.
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
      disabled_plugins = {
        "gzip",
        "tarPlugin",
        "zipPlugin",
        "tutor",
      },
    },
  },
})
