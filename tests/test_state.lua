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
    local ids, mode = state.enabled_ids()
    eq(mode, state.LEGACY)
    eq(#ids, #components.load_ids())
    eq(state.is_enabled("terraform"), true)
    eq(state.is_enabled("vault"), true)
  end)
end

T["runtime"]["a selection means that selection and its dependencies"] = function()
  with_selection('{ "schema": 1, "selected": ["terraform"] }', function()
    local ids, mode = state.enabled_ids()
    eq(mode, state.SELECTED)
    eq(ids, { "core", "terraform" })
    eq(state.is_enabled("core"), true)
    eq(state.is_enabled("terraform"), true)
    eq(state.is_enabled("vault"), false)
    eq(state.is_enabled("kubernetes"), false)
  end)
end

T["runtime"]["an empty selection means core alone"] = function()
  with_selection('{ "schema": 1, "selected": [] }', function()
    local ids, mode = state.enabled_ids()
    eq(mode, state.SELECTED)
    eq(ids, { "core" })
    eq(state.is_enabled("aws"), false)
  end)
end

---Collects what `fn` sends to vim.notify rather than printing it.
---@param fn function
---@return string[]
local function notices_from(fn)
  local collected = {}
  local saved = vim.notify
  vim.notify = function(message, _)
    table.insert(collected, tostring(message))
  end

  local ok, err = pcall(fn)
  vim.notify = saved
  assert(ok, err)

  return collected
end

-- A selection that exists but cannot be read is not a licence to run
-- everything. The file being there says somebody chose, and an unreadable
-- choice is still a choice — one of the things it could have said is
-- `"selected": []`. Every shape the corpus refuses lands in safe mode, not
-- just the one this was first written for.
T["runtime"]["an unreadable selection is reported and falls back to core alone"] = function()
  local paths = corpus("invalid")
  eq(#paths > 0, true)

  for _, path in ipairs(paths) do
    with_selection(table.concat(vim.fn.readfile(path), "\n"), function()
      local ids, mode
      local notices = notices_from(function()
        ids, mode = state.enabled_ids()
      end)

      eq({ path, mode }, { path, state.SAFE })
      eq({ path, ids }, { path, { "core" } })
      -- The half that matters: a file nobody can read did not switch on the
      -- components somebody may have deliberately switched off.
      eq({ path, #components.load_ids() > 1 }, { path, true })
      eq({ path, notices[1] ~= nil and notices[1]:find("core alone", 1, true) ~= nil }, { path, true })
    end)
  end
end

-- And the report names the problem, rather than saying only that there was one.
T["runtime"]["safe mode says what was wrong with the file"] = function()
  with_selection('{ "schema": 1, "selected": ["magic"] }', function()
    local notices = notices_from(function()
      state.enabled_ids()
    end)

    eq(table.concat(notices, " "):find("unknown component") ~= nil, true)
  end)
end

-- ---------------------------------------------------------------------------
-- The contract the selection is read against

T["contract"] = new_set({
  hooks = {
    pre_case = function()
      state.forget()
    end,
    post_case = function()
      state.forget()
    end,
  },
})

---Runs `fn` with the contract reader answering with exactly this set and these
---problems. Patched on the module table rather than in package.loaded, because
---state.lua holds the table it required and would not see a replacement.
---@param set table<string, table>
---@param problems string[]
---@param fn function
local function with_contract(set, problems, fn)
  local real = components.load
  components.load = function()
    return set, problems
  end
  state.forget()

  local ok, err = pcall(fn)

  components.load = real
  state.forget()
  assert(ok, err)
end

local WHOLE = {
  core = { id = "core", requires = {}, nvim = {} },
  terraform = { id = "terraform", requires = { "core" }, nvim = {} },
}

-- The failure this exists for, measured before it was fixed: a broken core.json
-- left `core` out of the set, `enabled` skips ids it does not know, and a
-- selection of Terraform resolved to Terraform alone — a component running
-- without the one thing every component requires, reported as `selected`.
T["contract"]["a contract that could not be read fully is not run from"] = function()
  with_selection('{ "schema": 1, "selected": ["terraform"] }', function()
    with_contract({ terraform = WHOLE.terraform }, { "core.json nvim is not an object" }, function()
      local ids, mode
      local notices = notices_from(function()
        ids, mode = state.enabled_ids()
      end)

      eq(mode, state.SAFE)
      eq(ids, {})
      eq(notices[1]:find("core.json", 1, true) ~= nil, true)
    end)
  end)
end

-- A component nobody selected being unreadable is the same problem: the file
-- that failed to parse is the one that would have said what depends on what.
T["contract"]["one bad file is enough, even for a component nobody chose"] = function()
  with_selection('{ "schema": 1, "selected": ["terraform"] }', function()
    with_contract(WHOLE, { "docker.json is not valid JSON" }, function()
      local ids, mode
      notices_from(function()
        ids, mode = state.enabled_ids()
      end)

      eq(mode, state.SAFE)
      eq(ids, { "core" })
    end)
  end)
end

-- No components directory at all yields no components and no problems, so the
-- absence of core is refused by name rather than left to be noticed.
T["contract"]["an empty contract is refused rather than read as legacy"] = function()
  with_selection(nil, function()
    with_contract({}, {}, function()
      local ids, mode
      local notices = notices_from(function()
        ids, mode = state.enabled_ids()
      end)

      eq(mode, state.SAFE)
      eq(ids, {})
      eq(notices[1]:find("core", 1, true) ~= nil, true)
    end)
  end)
end

-- And the healthy contract still resolves, or the three above would pass with
-- the whole module switched off.
T["contract"]["a whole contract resolves normally"] = function()
  with_selection('{ "schema": 1, "selected": ["terraform"] }', function()
    with_contract(WHOLE, {}, function()
      local ids, mode = state.enabled_ids()
      eq(mode, state.SELECTED)
      eq(ids, { "core", "terraform" })
    end)
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
