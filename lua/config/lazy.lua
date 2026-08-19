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

  -- The lockfile pins lazy.nvim itself but only means anything once lazy is
  -- running, so on a fresh machine the first lazy to execute would be whatever
  -- `stable` pointed at that day. Checked out before it reaches the runtimepath.
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
  spec = { { import = "plugins" } },

  -- Tracked in git, so the plugin set is reproducible across machines.
  lockfile = lockfile,

  -- SECURITY. Defaults to true, which loads a project-local `.lazy.lua` from
  -- whatever directory Neovim was started in.
  local_spec = false,

  install = {
    missing = true,
    -- The chosen one, asked of the two documents rather than named here: this
    -- file used to say `catppuccin-mocha`, and a name written twice is a name
    -- that eventually says two things. habamax is the built-in fallback for the
    -- first start, before anything at all is on disk.
    colorscheme = { require("chroma.theme").colorscheme(), "habamax" },
  },

  -- No plugin here ships a rockspec, so luarocks would be an unused dependency
  -- that :checkhealth lazy reports as an error.
  rocks = { enabled = false },

  -- On, because drift should be visible; quiet, because a notification on every
  -- start is not.
  checker = {
    enabled = true,
    notify = false,
    frequency = 3600,
  },

  change_detection = {
    enabled = true,
    notify = false,
  },

  performance = {
    cache = { enabled = true },
    rtp = {
      -- Ship with Neovim 0.12 and are unused in this workflow.
      disabled_plugins = {
        "gzip",
        "tarPlugin",
        "zipPlugin",
        "tutor",
      },
    },
  },
})
