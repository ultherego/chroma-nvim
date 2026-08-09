-- The headless entrypoint the installer drives.
--
-- Go must not know how lazy.nvim, Mason and nvim-treesitter install things.
-- Three plugin APIs in a language that cannot call them, kept in step with
-- versions a lockfile pins, is a copy of this configuration's knowledge living
-- somewhere it cannot be tested. So the configuration exposes two verbs and the
-- installer runs them:
--
--   nvim --headless -c 'lua require("chroma.bootstrap").run("install")' -c 'qa!'
--
-- This module is therefore part of the contract between a release and the CLI
-- that installs it, in the same way `components/` is. A release without it
-- cannot be installed by a CLI that expects it, which is why the source is
-- checked for it before anything is placed rather than after.
--
-- Nothing here waits on an event. Every step polls for the state it wants:
-- measured, mason-tool-installer's `MasonToolsUpdateCompleted` never fires when
-- its list is empty, and its synchronous command loops forever with no timeout
-- at all. "Did an event arrive" is a different question from "is the thing
-- installed", and only the second one is what an installation needs to know.

local M = {}

--- How long any one step may take. Parsers are compiled from source on a
--- machine whose speed nobody here knows, so this is generous; the installer
--- bounds the whole process as well, and that bound is the one that matters.
M.TIMEOUT = 15 * 60 * 1000

--- How often to look again. Polling drives the event loop, which is what lets
--- the downloads this is waiting for make progress.
local INTERVAL = 200

---What the enabled components contribute of one kind.
---@param kind string
---@return string[]
local function contributions(kind)
  local enabled = require("chroma.state").enabled_ids()
  return require("chroma.components").contributions(kind, enabled)
end

---The names in `wanted` that `installed` does not have.
---@param wanted string[]
---@param installed fun(name: string): boolean
---@return string[]
local function absent(wanted, installed)
  local missing = {}
  for _, name in ipairs(wanted) do
    if not installed(name) then
      table.insert(missing, name)
    end
  end
  return missing
end

---Waits for everything in `wanted` to arrive, and says what did not.
---@param wanted string[]
---@param installed fun(name: string): boolean
---@param timeout integer
---@return string[] missing
local function wait_for(wanted, installed, timeout)
  if #wanted == 0 then
    return {}
  end

  vim.wait(timeout, function()
    return #absent(wanted, installed) == 0
  end, INTERVAL)

  return absent(wanted, installed)
end

---Makes lazy load the plugins a step is about to drive.
---
---This exists for a bug that a real installation found and no unit test could
---have. mason-tool-installer's list of packages comes from its `opts`, and lazy
---applies those when it loads the plugin — on `VeryLazy`, which in a headless
---Neovim may never arrive at all. Calling `check_install()` before that gives
---an empty list: nothing is installed, nothing fails, and the wait below
---reports four packages missing a quarter of an hour later.
---
---So the step loads what it is about to use, and does not assume a startup
---sequence that a headless editor has no reason to run.
---@param names string[]
local function load_plugins(names)
  local ok, lazy = pcall(require, "lazy")
  if not ok then
    return
  end

  for _, name in ipairs(names) do
    -- One at a time: lazy reports an unknown plugin by raising, and a name
    -- that is not in this release should not stop the ones that are.
    pcall(lazy.load, { plugins = { name }, wait = true })
  end
end

---Every Mason package the enabled components need, by the name the registry
---knows it as.
---
---Two lists in the contract, one registry. `mason` already holds registry
---names; `servers` holds nvim-lspconfig names, and `bashls` is a package called
---`bash-language-server`. mason-lspconfig owns that translation and publishes
---it, so it is asked rather than guessed at — a hand-written second mapping
---would be a third place for these names to live.
---
---Servers are in here at all because mason-lspconfig's own `ensure_installed`
---does nothing when Neovim is headless, which is exactly where the installer
---runs. Measured: after an install, the servers were absent and the first
---interactive session started fetching them.
---@param servers string[] nvim-lspconfig names, from the contract
---@param tools string[] Mason package names, from the contract
---@return string[]
local function mason_packages(servers, tools)
  local translate = {}
  local ok, lspconfig = pcall(require, "mason-lspconfig")
  if ok and lspconfig.get_mappings then
    local mappings = lspconfig.get_mappings()
    translate = mappings.lspconfig_to_package or {}
  end

  local wanted, seen = {}, {}
  local function want(name)
    local package = translate[name] or name
    if not seen[package] then
      seen[package] = true
      table.insert(wanted, package)
    end
  end

  for _, name in ipairs(servers) do
    want(name)
  end
  for _, name in ipairs(tools) do
    want(name)
  end

  return wanted
end

---Installs the plugins, tools and parsers the enabled components need.
---
---Loud on failure, and failure means failure: a parser that did not compile is
---not a warning to be printed beside the word "installed". The caller decides
---what to do with that, and for the installer the answer is a rollback.
---@param opts { timeout: integer? }|nil
---@return boolean ok, string|nil problem
function M.install(opts)
  local timeout = (opts or {}).timeout or M.TIMEOUT

  -- Plugins first: everything below is a plugin's API.
  local ok, err = pcall(function()
    require("lazy").sync({ wait = true, show = false })
  end)
  if not ok then
    return false, ("installing plugins failed: %s"):format(err)
  end

  -- Mason packages. Asked for through the same plugin the configuration
  -- normally uses, then waited for by asking the registry, because that is the
  -- question with an answer: is it installed.
  local servers = contributions("servers")
  local tools = contributions("mason")
  if #servers > 0 or #tools > 0 then
    load_plugins({ "mason.nvim", "mason-lspconfig.nvim", "mason-tool-installer.nvim" })

    local registry = require("mason-registry")

    local function installed(name)
      return registry.is_installed(name)
    end

    -- Whether anything is still being fetched. `is_installed` alone is true too
    -- early: measured, the first end-to-end install saw every package as
    -- present, returned, and `qa!` closed the editor while one of them was
    -- still downloading — mason said so on the way out ("Neovim is exiting
    -- while packages are still installing"), the package was aborted, and the
    -- installation reported success over it. A step that asks "is it there yet"
    -- has to also ask "and has it stopped arriving".
    local function settled(packages)
      for _, name in ipairs(packages) do
        local found, package = pcall(registry.get_package, name)
        if found and package:is_installing() then
          return false
        end
      end
      return true
    end

    -- The plugin says when it has finished with all of them, which is the only
    -- signal that covers a package that failed rather than arrived.
    local completed = false
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("chroma_bootstrap_mason", { clear = true }),
      pattern = "MasonToolsUpdateCompleted",
      once = true,
      callback = function()
        completed = true
      end,
    })

    ok, err = pcall(function()
      require("mason-tool-installer").check_install(false)
    end)
    if not ok then
      return false, ("installing Mason packages failed: %s"):format(err)
    end

    vim.wait(timeout, function()
      return completed
    end, INTERVAL)

    -- Only now are the names askable.
    --
    -- The contract says `bashls`; the registry knows `bash-language-server`.
    -- mason-lspconfig owns that translation, and it builds it from the registry
    -- index — which does not exist on a machine Chroma has never been installed
    -- on until something downloads it. `check_install` above is what does.
    -- Asking any earlier returns an empty table, and the wait below then
    -- watches for packages under names nothing will ever have: measured, the
    -- first attempt at this reported `bashls, jsonls, lua_ls, yamlls` missing
    -- after everything had installed correctly.
    local packages = mason_packages(servers, tools)

    -- A short second wait for anything still writing itself out.
    vim.wait(timeout, function()
      return #absent(packages, installed) == 0 and settled(packages)
    end, INTERVAL)

    local missing = absent(packages, installed)
    if #missing > 0 then
      return false, ("these Mason packages did not install: %s"):format(table.concat(missing, ", "))
    end
  end

  -- Treesitter parsers. install() returns while its per-parser jobs are still
  -- running — measured during CI work, where the check reported one missing
  -- while the log was still installing others — so the result is polled rather
  -- than awaited.
  local parsers = contributions("parsers")
  if #parsers > 0 then
    load_plugins({ "nvim-treesitter" })

    ok, err = pcall(function()
      require("nvim-treesitter").install(parsers)
    end)
    if not ok then
      return false, ("installing parsers failed: %s"):format(err)
    end

    local missing = wait_for(parsers, function(name)
      for _, installed in ipairs(require("nvim-treesitter.config").get_installed("parsers")) do
        if installed == name then
          return true
        end
      end
      return false
    end, timeout)
    if #missing > 0 then
      return false, ("these parsers did not install: %s"):format(table.concat(missing, ", "))
    end
  end

  return true, nil
end

---Whether this is a Chroma that starts and is the one that was asked for.
---
---Small and binary on purpose. It is not `:checkhealth`, which reports on the
---machine; this reports on the installation, and the only two answers it may
---give are yes and a reason.
---@param expected string[]|nil component ids the installer selected
---@return boolean ok, string|nil problem
function M.verify(expected)
  local state = require("chroma.state")

  local enabled, mode = state.enabled_ids()

  -- Safe mode is a Chroma that came up with the selection or the contract
  -- unreadable. It starts, which is the point of safe mode, and it is not what
  -- anybody asked to have installed.
  if mode == state.SAFE then
    return false, "the installed Chroma came up in safe mode: its selection or its component contract could not be read"
  end

  -- An installation always writes a selection, so finding none means the file
  -- the installer wrote is not the file the editor read.
  if mode == state.LEGACY then
    return false,
      "the installed Chroma found no selection, so it is running every component rather than the chosen ones"
  end

  local running = {}
  for _, id in ipairs(enabled) do
    running[id] = true
  end
  if not running.core then
    return false, "core is not enabled, so there is no editor to speak of"
  end

  local missing = {}
  for _, id in ipairs(expected or {}) do
    if not running[id] then
      table.insert(missing, id)
    end
  end
  if #missing > 0 then
    return false, ("these components were selected but are not running: %s"):format(table.concat(missing, ", "))
  end

  -- Whatever the enabled components bring has to be loadable, or the
  -- installation is a list of names and nothing behind them.
  local components = require("chroma.components")
  local broken = {}
  for _, module in ipairs(components.contributions("modules", enabled)) do
    if not pcall(require, module) then
      table.insert(broken, module)
    end
  end
  if #broken > 0 then
    return false, ("these modules do not load: %s"):format(table.concat(broken, ", "))
  end

  return true, nil
end

---The entry point the installer calls, and the only one that exits.
---
---`nvim --headless -c 'lua ...'` reports a Lua error and then carries on to the
---next command, so a step that failed would end in a process that exited zero.
---This is where that is turned into an exit code, which is what the installer
---reads.
---@param step string "install" or "verify"
---@param expected string[]|nil
function M.run(step, expected)
  local steps = {
    install = function()
      return M.install()
    end,
    verify = function()
      return M.verify(expected)
    end,
  }

  local runner = steps[step]
  if not runner then
    io.write(("chroma-bootstrap: unknown step %q\n"):format(tostring(step)))
    vim.cmd("cquit 1")
    return
  end

  local ok, problem = runner()
  if not ok then
    io.write(("chroma-bootstrap: %s failed: %s\n"):format(step, problem or "no reason given"))
    vim.cmd("cquit 1")
    return
  end

  io.write(("chroma-bootstrap: %s ok\n"):format(step))
end

return M
