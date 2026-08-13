-- The headless entrypoint the installer drives, so Go never has to know how
-- lazy.nvim, Mason and nvim-treesitter install things. Part of the contract
-- between a release and the CLI, like `components/`.
--
-- Nothing waits on an event; every step polls. Measured:
-- `MasonToolsUpdateCompleted` never fires when the list is empty, and the
-- synchronous command loops forever with no timeout.

local M = {}

--- Generous, because parsers compile from source on an unknown machine. The
--- installer bounds the whole process too, and that bound is the one that counts.
M.TIMEOUT = 15 * 60 * 1000

--- Polling also drives the event loop, which is what lets the downloads this is
--- waiting for make progress.
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

---Makes lazy load the plugins a step is about to drive, rather than assuming a
---startup sequence a headless editor has no reason to run. mason-tool-installer
---gets its package list from `opts`, applied on `VeryLazy` — which may never
---arrive — so `check_install()` before that installs nothing and fails silently.
---@param names string[]
local function load_plugins(names)
  local ok, lazy = pcall(require, "lazy")
  if not ok then
    return
  end

  for _, name in ipairs(names) do
    -- One at a time: lazy raises on an unknown plugin, and a name that is not
    -- in this release should not stop the ones that are.
    pcall(lazy.load, { plugins = { name }, wait = true })
  end
end

---Every Mason package the enabled components need, by registry name. `servers`
---holds nvim-lspconfig names — `bashls` is `bash-language-server` — and
---mason-lspconfig owns that translation, so it is asked rather than copied.
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

---Installs the plugins, tools and parsers the enabled components need. A parser
---that did not compile is a failure, not a warning printed beside "installed".
---@param opts { timeout: integer? }|nil
---@return boolean ok, string|nil problem
function M.install(opts)
  local timeout = (opts or {}).timeout or M.TIMEOUT

  -- Plugins first: everything below is a plugin's API. `install` then
  -- `restore`, deliberately not `sync` — measured, sync updates every plugin to
  -- the head of its branch and rewrites the lockfile, so one release installed
  -- on two days gives two different editors. install clones what is missing at
  -- the pinned commit, restore moves what is present onto it.
  local ok, err = pcall(function()
    require("lazy").install({ wait = true, show = false, lockfile = true })
    require("lazy").restore({ wait = true, show = false })
  end)
  if not ok then
    return false, ("installing plugins failed: %s"):format(err)
  end

  -- Asked for through the plugin the configuration normally uses, then waited
  -- for by asking the registry, which is the question with an answer.
  local servers = contributions("servers")
  local tools = contributions("mason")
  if #servers > 0 or #tools > 0 then
    load_plugins({ "mason.nvim", "mason-lspconfig.nvim", "mason-tool-installer.nvim" })

    local registry = require("mason-registry")

    local function installed(name)
      return registry.is_installed(name)
    end

    -- `is_installed` alone is true too early: measured, the first end-to-end
    -- install saw every package present, returned, and `qa!` aborted one that
    -- was still downloading — reported as success.
    local function settled(packages)
      for _, name in ipairs(packages) do
        local found, package = pcall(registry.get_package, name)
        if found and package:is_installing() then
          return false
        end
      end
      return true
    end

    -- The only signal that covers a package that failed rather than arrived.
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

    -- Only now are the names askable: mason-lspconfig builds its translation
    -- from the registry index, which `check_install` above is what downloads.
    -- Measured, asking earlier reported `bashls, jsonls, lua_ls, yamlls`
    -- missing after everything had installed correctly.
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

  -- install() returns while its per-parser jobs are still running — measured on
  -- CI — so the result is polled rather than awaited.
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

---Whether this is a Chroma that starts and is the one that was asked for. Not
---`:checkhealth`, which reports on the machine: the answers here are yes and a
---reason.
---@param expected string[]|nil component ids the installer selected
---@return boolean ok, string|nil problem
function M.verify(expected)
  local state = require("chroma.state")

  local enabled, mode = state.enabled_ids()

  -- Safe mode starts, which is its point, and is not what anybody asked to
  -- have installed.
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

  -- Or the installation is a list of names with nothing behind them.
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

---The entry point the installer calls, and the only one that exits. A headless
---`-c 'lua ...'` reports a Lua error and then carries on to the next command,
---so a failed step would otherwise end in a process that exited zero.
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
