-- lazy.nvim bootstrap and setup.

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local lockfile = vim.fn.stdpath("config") .. "/lazy-lock.json"

---Stops with a message rather than a stack trace: this runs before anything else.
---@param message string
---@param detail string
local function give_up(message, detail)
  vim.api.nvim_echo({
    { message .. "\n", "ErrorMsg" },
    { detail, "WarningMsg" },
    { "\nPress any key to exit..." },
  }, true, {})
  vim.fn.getchar()
  os.exit(1)
end

---The commit lazy-lock.json pins for a plugin, if it can be read.
---@param name string
---@return string|nil
local function pinned(name)
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(lockfile), "\n"))
  end)
  return ok and type(decoded) == "table" and decoded[name] and decoded[name].commit or nil
end

if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    give_up("Failed to clone lazy.nvim:", out)
  end

  -- The lockfile pins every plugin including lazy.nvim itself, but it only starts
  -- meaning anything once lazy is running — so on a fresh machine the first lazy
  -- to execute was whatever `stable` pointed at that day, not the commit this
  -- repository was tested with. Checked out before it is put on the runtimepath.
  local commit = pinned("lazy.nvim")
  if commit then
    out = vim.fn.system({ "git", "-C", lazypath, "checkout", "--quiet", commit })
    if vim.v.shell_error ~= 0 then
      give_up(("Failed to check lazy.nvim out at %s:"):format(commit), out)
    end
  end
end

vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  -- Every file under lua/plugins/ is a spec module. One file per domain.
  spec = { { import = "plugins" } },

  -- Tracked in git, so the plugin set is reproducible across machines.
  lockfile = lockfile,

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
