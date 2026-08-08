-- The persisted selection, from this configuration's side.
--
-- Driven by tests/fixtures/component-state, the same corpus the Go reader uses:
-- "Go accepts, Lua rejects" should be a failing test rather than a machine
-- behaving differently from the editor running on it.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local state = require("chroma.state")
local components = require("chroma.components")

local T = new_set()

---The corpus, resolved from this file so it is found from any working directory.
---@param kind string
---@return string
local function fixtures(kind)
  local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return vim.fs.joinpath(here, "fixtures", "component-state", kind)
end

---@param kind string
---@return string[] paths
local function corpus(kind)
  local paths = {}
  for name, filetype in vim.fs.dir(fixtures(kind)) do
    if filetype == "file" then
      table.insert(paths, vim.fs.joinpath(fixtures(kind), name))
    end
  end
  table.sort(paths)
  return paths
end

T["corpus"] = new_set()

T["corpus"]["every valid fixture loads"] = function()
  local set = components.load()
  local paths = corpus("valid")
  -- An empty corpus would make this pass for nothing.
  eq(#paths > 0, true)

  for _, path in ipairs(paths) do
    local loaded, found, err = state.load(path, set)
    eq({ path, err }, { path, nil })
    eq({ path, found }, { path, true })
    eq({ path, loaded.schema }, { path, state.SCHEMA })
  end
end

T["corpus"]["every invalid fixture is refused"] = function()
  local set = components.load()
  local paths = corpus("invalid")
  eq(#paths > 0, true)

  for _, path in ipairs(paths) do
    local loaded, _, err = state.load(path, set)
    eq({ path, loaded }, { path, nil })
    eq({ path, type(err) }, { path, "string" })
  end
end

-- ---------------------------------------------------------------------------
-- The distinction the migration rests on

T["absence"] = new_set()

-- No file at all is not an empty selection. An update must not switch off the
-- Terraform support somebody has been using for months.
T["absence"]["a missing file is not an empty selection"] = function()
  local set = components.load()

  local loaded, found, err = state.load(vim.fn.tempname(), set)
  eq(err, nil)
  eq(found, false)
  eq(loaded.selected, {})

  local empty = state.load(vim.fs.joinpath(fixtures("valid"), "core-only.json"), set)
  eq(state.enabled(empty, set), { "core" })

  -- And the two lead to different places.
  eq(#components.load_ids() > 1, true)
end

-- ---------------------------------------------------------------------------
-- Resolving

T["resolve"] = new_set()

-- Resolved on read, never stored: a component whose dependencies change must
-- not be described by a list written before the change.
T["resolve"]["walks the graph rather than trusting a stored list"] = function()
  local set = {
    core = { id = "core", requires = {} },
    mid = { id = "mid", requires = { "core" } },
    leaf = { id = "leaf", requires = { "mid" } },
    other = { id = "other", requires = { "core" } },
  }

  local enabled = state.enabled({ schema = 1, selected = { "leaf" } }, set)
  eq(enabled, { "core", "leaf", "mid" })
end

T["resolve"]["core is enabled by an empty selection"] = function()
  local set = components.load()
  eq(state.enabled({ schema = 1, selected = {} }, set), { "core" })
end

T["resolve"]["a real selection pulls in what it needs"] = function()
  local set = components.load()
  eq(state.enabled({ schema = 1, selected = { "vault" } }, set), { "core", "vault" })
end

-- ---------------------------------------------------------------------------
-- What the runtime answers

T["runtime"] = new_set({
  hooks = {
    pre_case = function()
      state.forget()
    end,
    post_case = function()
      state.forget()
    end,
  },
})

---Runs `fn` with the selection file pointed at a throwaway directory.
---@param contents string|nil written when given; absent otherwise
---@param fn function
local function with_selection(contents, fn)
  local home = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(home, "chroma"), "p")
  if contents then
    vim.fn.writefile(vim.split(contents, "\n"), vim.fs.joinpath(home, "chroma", "components.json"))
  end

  local saved = vim.env.XDG_CONFIG_HOME
  vim.env.XDG_CONFIG_HOME = home
  state.forget()

  local ok, err = pcall(fn)

  vim.env.XDG_CONFIG_HOME = saved
  state.forget()
  vim.fn.delete(home, "rf")
  assert(ok, err)
end

-- The migration promise: somebody who has been using this for months and has
-- never seen the CLI must not lose Terraform, Vault or anything else the day
-- gating arrives.
T["runtime"]["no selection means every component"] = function()
  with_selection(nil, function()
    local ids, legacy = state.enabled_ids()
    eq(legacy, true)
    eq(#ids, #components.load_ids())
    eq(state.is_enabled("terraform"), true)
    eq(state.is_enabled("vault"), true)
  end)
end

T["runtime"]["a selection means that selection and its dependencies"] = function()
  with_selection('{ "schema": 1, "selected": ["terraform"] }', function()
    local ids, legacy = state.enabled_ids()
    eq(legacy, false)
    eq(ids, { "core", "terraform" })
    eq(state.is_enabled("core"), true)
    eq(state.is_enabled("terraform"), true)
    eq(state.is_enabled("vault"), false)
    eq(state.is_enabled("kubernetes"), false)
  end)
end

T["runtime"]["an empty selection means core alone"] = function()
  with_selection('{ "schema": 1, "selected": [] }', function()
    local ids, legacy = state.enabled_ids()
    eq(legacy, false)
    eq(ids, { "core" })
    eq(state.is_enabled("aws"), false)
  end)
end

-- A selection that cannot be read is not a reason to start an editor with less
-- in it than yesterday. It is loud, and then it runs everything.
T["runtime"]["an unreadable selection is reported and falls back to everything"] = function()
  with_selection('{ "schema": 1, "selected": ["magic"] }', function()
    local notices = {}
    local saved = vim.notify
    vim.notify = function(message, _)
      table.insert(notices, tostring(message))
    end

    local ids, legacy = state.enabled_ids()
    vim.notify = saved

    eq(legacy, true)
    eq(#ids, #components.load_ids())
    eq(table.concat(notices, " "):find("unknown component") ~= nil, true)
  end)
end

-- ---------------------------------------------------------------------------
-- Where it lives

T["path"] = new_set()

T["path"]["follows XDG_CONFIG_HOME"] = function()
  local saved = vim.env.XDG_CONFIG_HOME
  vim.env.XDG_CONFIG_HOME = "/somewhere"
  local path = state.path()
  vim.env.XDG_CONFIG_HOME = saved

  eq(path, "/somewhere/chroma/components.json")
end

-- Not inside the release tree, which an update replaces wholesale.
T["path"]["is not inside the configuration directory"] = function()
  eq(state.path():find(vim.fn.stdpath("config"), 1, true), nil)
end

return T
