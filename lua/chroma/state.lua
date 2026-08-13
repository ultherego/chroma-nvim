-- What the user chose — their intent, in their configuration directory, not the
-- component contract that ships with the release.
--
-- The rules must match cli/internal/state/state.go; both run against the
-- fixtures in tests/fixtures/component-state, so a disagreement is a failure.

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
    -- Refused rather than ignored: a file naming core was written against a
    -- different idea of this document.
    if id == M.CORE then
      return ("selects %q, which is always enabled and is not a choice"):format(M.CORE)
    end
    if seen[id] then
      return ("selects %q twice"):format(id)
    end
    -- Fail closed: a typo and a newer CLI writing for an older Chroma look the
    -- same here, and both mean what runs is not what was chosen.
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
---from before any of this existed, and everything runs. `found` tells them
---apart.
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

--- Answered once and cached: a stat per question, and one report of an
--- unreadable selection per caller rather than one in total.
---@type { ids: string[], mode: string }|nil
local resolved = nil

--- The same answer as a set, for the callers that ask about one id.
---@type table<string, boolean>|nil
local current = nil

--- How the answer was arrived at, which is a different question from what it
--- is. A caller that only wants to know what runs can ignore it.
M.LEGACY = "legacy" -- no selection has ever been written: everything runs
M.SELECTED = "selected" -- a selection was read: it decides
M.SAFE = "safe" -- the selection or the contract cannot be trusted: core alone

---Reports a problem and drops to safe mode: whatever core alone means with the
---contract that could be read, which is core if it loaded and nothing at all if
---it did not.
---@param set table<string, table>
---@param problem string
---@return string[] ids, string mode
local function unsafe(set, problem)
  local running = M.enabled({ schema = M.SCHEMA, selected = {} }, set)

  vim.notify(
    ("Chroma: %s\n%s"):format(
      problem,
      #running > 0 and "Running with core alone until that is fixed; everything optional is switched off."
        or "Even core could not be read, so nothing is enabled."
    ),
    vim.log.levels.ERROR
  )

  return running, M.SAFE
end

---@return string[] ids, string mode
local function resolve()
  local set, problems = components.load()

  -- The contract first, because the selection is read against it. A partial
  -- contract is refused rather than used: measured, a broken core.json left
  -- `core` out of the set and a Terraform selection resolved to Terraform
  -- alone, reported as `selected`. A missing core is the same failure by
  -- another route. See DECISIONS.md, "A partial contract is not a contract".
  if #problems > 0 then
    return unsafe(set, ("the component contract cannot be read: %s"):format(table.concat(problems, "; ")))
  end
  if set[M.CORE] == nil then
    return unsafe(set, ("the component contract declares no %q, so there is nothing to build on"):format(M.CORE))
  end

  local state, found, err = M.load(nil, set)

  if err then
    -- Loud, and then core alone rather than everything: the file's presence
    -- says somebody chose, possibly `"selected": []`. See DECISIONS.md, "An
    -- unreadable selection runs core alone".
    return unsafe(set, err)
  end

  if not found then
    return components.load_ids(), M.LEGACY
  end

  return M.enabled(state, set), M.SELECTED
end

---The ids enabled right now, and how that was decided.
---@return string[] ids, string mode one of M.LEGACY, M.SELECTED, M.SAFE
function M.enabled_ids()
  if resolved == nil then
    local ids, mode = resolve()
    resolved = { ids = ids, mode = mode }
  end
  return resolved.ids, resolved.mode
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

---Whether anything enabled contributes `name` as `kind`.
---
---What a plugin spec asks: it names itself, and the contract decides whether
---that name is switched on.
---@param kind string
---@param name string
---@return boolean
function M.contributes(kind, name)
  return components.contributes(kind, name, (M.enabled_ids()))
end

---Forgets the cached answer. For tests, and for a `:ChromaReload` that does not
---exist yet.
function M.forget()
  resolved = nil
  current = nil
end

return M
