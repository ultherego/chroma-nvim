-- What the user chose, from this configuration's side.
--
-- Not the component contract. That describes the product and ships with the
-- release; this describes one person's intent, lives in their configuration
-- directory, and outlives any release being replaced over it.
--
-- The rules here must match cli/internal/state/state.go. Both are driven by the
-- same fixtures in tests/fixtures/component-state, so a disagreement is a
-- failing test rather than an editor behaving differently from the CLI that
-- configured it.
--
-- Nothing reads this yet to decide what to load. It answers questions; gating
-- comes next, and separately.

local components = require("chroma.components")

local M = {}

--- The version of this document, deliberately not the component contract's.
--- The two describe different things and have no reason to move together.
M.SCHEMA = 1

--- Enabled always, never a choice, and so never written down.
M.CORE = "core"

--- The fields this document may carry.
local KNOWN = { schema = true, selected = true }

---Where the selection lives: with the user's own configuration, not inside the
---release tree, which an update replaces wholesale.
---@return string
function M.path()
  local config = vim.env.XDG_CONFIG_HOME
  if not config or config == "" then
    config = vim.fs.joinpath(vim.uv.os_homedir() or vim.fn.expand("~"), ".config")
  end
  return vim.fs.joinpath(config, "chroma", "components.json")
end

---@param decoded any
---@param set table<string, table>
---@return string|nil problem
local function problem_with(decoded, set)
  if type(decoded) ~= "table" then
    return "is not an object"
  end

  for key in pairs(decoded) do
    if not KNOWN[key] then
      return ("has an unknown field %q"):format(key)
    end
  end

  if decoded.schema ~= M.SCHEMA then
    return ("declares schema %s; this understands %d"):format(tostring(decoded.schema), M.SCHEMA)
  end

  local selected = decoded.selected
  if type(selected) ~= "table" or (next(selected) ~= nil and #selected == 0) then
    return "has a selected that is not an array"
  end

  local seen = {}
  for _, id in ipairs(selected) do
    if type(id) ~= "string" then
      return ("selects something that is not a string: %s"):format(vim.inspect(id))
    end
    if id == "" then
      return "selects a component with an empty id"
    end
    -- Refused rather than ignored: core is not an optional choice, and a file
    -- naming it was written against a different idea of this document.
    if id == M.CORE then
      return ("selects %q, which is always enabled and is not a choice"):format(M.CORE)
    end
    if seen[id] then
      return ("selects %q twice"):format(id)
    end
    -- Fail closed. A typo and "a newer CLI wrote this for an older Chroma" look
    -- the same here, and both mean what is about to run is not what was chosen.
    if set and not set[id] then
      return ("references unknown component %q"):format(id)
    end
    seen[id] = true
  end

  return nil
end

---Reads the selection.
---
---A file that is not there is not an empty selection: it is a configuration
---from before any of this existed, and everything runs. An update must not
---switch off the Terraform support somebody has been using. `found` is how a
---caller tells the two apart.
---@param path string|nil defaults to M.path()
---@param set table<string, table>|nil components to check ids against
---@return table|nil state, boolean found, string|nil err
function M.load(path, set)
  path = path or M.path()

  if not vim.uv.fs_stat(path) then
    return { schema = M.SCHEMA, selected = {} }, false, nil
  end

  local ok, contents = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, true, ("%s could not be read: %s"):format(path, contents)
  end

  local decoded
  ok, decoded = pcall(vim.json.decode, table.concat(contents, "\n"))
  if not ok then
    return nil, true, ("%s is not valid JSON"):format(path)
  end

  local problem = problem_with(decoded, set)
  if problem then
    return nil, true, ("%s %s"):format(path, problem)
  end

  return { schema = decoded.schema, selected = decoded.selected }, true, nil
end

---Expands a selection into everything that runs, core included, by walking the
---graph now rather than trusting a list written earlier. A component whose
---dependencies change must not be described by a stale copy of them.
---@param state table
---@param set table<string, table>
---@return string[] ids sorted
function M.enabled(state, set)
  local chosen = {}

  local function add(id)
    if chosen[id] or not set[id] then
      return
    end
    chosen[id] = true
    for _, needed in ipairs(set[id].requires or {}) do
      add(needed)
    end
  end

  add(M.CORE)
  for _, id in ipairs(state.selected or {}) do
    add(id)
  end

  local ids = vim.tbl_keys(chosen)
  table.sort(ids)
  return ids
end

--- What this configuration is running with, answered once and cached for the
--- session: reading a file per question would put a stat in every code path
--- that ever asks.
---@type table<string, boolean>|nil
local current = nil

---The ids enabled right now, whether from a selection or from its absence.
---@return string[] ids, boolean legacy
function M.enabled_ids()
  local set = components.load()
  local state, found, err = M.load(nil, set)

  if err then
    -- Loud, and then everything: a selection that cannot be read is not a
    -- reason to start an editor with less in it than the user had yesterday.
    vim.notify(("Chroma: %s\nRunning with every component until that is fixed."):format(err), vim.log.levels.ERROR)
    return components.load_ids(), true
  end

  if not found then
    return components.load_ids(), true
  end

  return M.enabled(state, set), false
end

---Whether one component is enabled.
---@param id string
---@return boolean
function M.is_enabled(id)
  if current == nil then
    current = {}
    for _, enabled in ipairs((M.enabled_ids())) do
      current[enabled] = true
    end
  end
  return current[id] == true
end

---Forgets the cached answer. For tests, and for a `:ChromaReload` that does not
---exist yet.
function M.forget()
  current = nil
end

return M
