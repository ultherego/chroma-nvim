-- Which colourscheme this installation draws, in two documents that answer two
-- questions and belong to two different people.
--
-- `themes.json` ships inside the release and says what this release can draw.
-- `chroma/theme.json` sits with the user's own configuration and says which of
-- them they picked — outside the release tree, which an update replaces
-- wholesale, exactly like the component selection beside it.
--
-- The rules must match cli/internal/theme/theme.go; both run against the
-- fixtures in tests/fixtures/theme-choice, so a disagreement is a failure.
--
-- Unlike the component selection, a document that cannot be read here does not
-- drop anything into safe mode. There is nothing to switch off: an editor with
-- no colourscheme is not a safer editor, it is an unreadable one. Every failure
-- is reported and then answered with the next thing down the list.

local M = {}

--- The version of both documents. They move together because neither means
--- anything without the other: the choice names an id, and the catalogue is the
--- only thing that says what an id may be.
M.SCHEMA = 1

--- What a release calls its catalogue, at the root of the tree.
M.CATALOGUE = "themes.json"

--- The last resort, and the only place in the editor that names a colourscheme
--- of its own. It is reached when the release tree itself cannot be read, which
--- is a broken installation rather than a choice — and a broken installation
--- that still comes up in colours is easier to diagnose than one that comes up
--- in none. Held honest by a test: the shipped catalogue must offer it.
M.FALLBACK = "catppuccin"

--- The fields each document may carry.
local KNOWN_CHOICE = { schema = true, theme = true }
local KNOWN_CATALOGUE = { schema = true, default = true, themes = true }
local KNOWN_THEME = { id = true, name = true, description = true, colorscheme = true }

---Where the choice lives: with the user's own configuration, not inside the
---release tree.
---@return string
function M.path()
  local config = vim.env.XDG_CONFIG_HOME
  if not config or config == "" then
    config = vim.fs.joinpath(vim.uv.os_homedir() or vim.fn.expand("~"), ".config")
  end
  return vim.fs.joinpath(config, "chroma", "theme.json")
end

---Where the catalogue lives: at the root of the release tree this file is part
---of. Resolved from this file rather than from stdpath("config"), the way the
---component contract is and for the same reason — it answers the same whether
---the configuration is installed, symlinked or under test.
---@return string
function M.catalogue_path()
  local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p")
  return vim.fs.joinpath(vim.fn.fnamemodify(here, ":h:h:h"), M.CATALOGUE)
end

---Reads one JSON document, or says why it could not.
---
---The question asked first is whether there is an entry at all, which is not
---the same as whether it can be read: `fs_stat` follows a link, so a link to
---nothing would answer exactly like nothing at all. Must match the Go reader.
---@param path string
---@return any|nil decoded, boolean found, string|nil err
local function read_json(path)
  local entry, why = vim.uv.fs_lstat(path)
  if not entry then
    -- Anything other than "it is not there" leaves the question unanswered, and
    -- an unanswered question is not the same as an answer.
    if why and not vim.startswith(why, "ENOENT") then
      return nil, true, ("%s could not be looked at: %s"):format(path, why)
    end
    return nil, false, nil
  end

  -- A symlink to a real file is somebody's own arrangement and is followed.
  local target = vim.uv.fs_stat(path)
  if not target then
    return nil, true, ("%s is a link to something that is not there"):format(path)
  end
  if target.type ~= "file" then
    return nil, true, ("%s is a %s, not a file"):format(path, target.type)
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

  return decoded, true, nil
end

---@param decoded any
---@return string|nil problem
local function problem_with_catalogue(decoded)
  if type(decoded) ~= "table" then
    return "is not an object"
  end

  for key in pairs(decoded) do
    if not KNOWN_CATALOGUE[key] then
      return ("has an unknown field %q"):format(key)
    end
  end

  if decoded.schema ~= M.SCHEMA then
    return ("declares schema %s; this understands %d"):format(tostring(decoded.schema), M.SCHEMA)
  end

  local themes = decoded.themes
  if type(themes) ~= "table" or (next(themes) ~= nil and #themes == 0) then
    return "has a themes that is not an array"
  end
  if #themes == 0 then
    return "offers no themes at all"
  end

  local seen = {}
  for _, one in ipairs(themes) do
    if type(one) ~= "table" then
      return ("offers something that is not a theme: %s"):format(vim.inspect(one))
    end
    for key in pairs(one) do
      if not KNOWN_THEME[key] then
        return ("offers a theme with an unknown field %q"):format(key)
      end
    end
    if type(one.id) ~= "string" or one.id == "" then
      return "offers a theme with no id"
    end
    if seen[one.id] then
      return ("offers %q twice"):format(one.id)
    end
    -- The one field the editor cannot work around. A theme with no name is
    -- ugly; a theme with no colourscheme is a `:colorscheme` call with nothing
    -- to pass.
    if type(one.colorscheme) ~= "string" or one.colorscheme == "" then
      return ("offers %q without a colorscheme to load"):format(one.id)
    end
    seen[one.id] = true
  end

  if type(decoded.default) ~= "string" or decoded.default == "" then
    return "names no default theme"
  end
  if not seen[decoded.default] then
    return ("defaults to %q, which it does not offer"):format(decoded.default)
  end

  return nil
end

---@param decoded any
---@param catalogue table|nil
---@return string|nil problem
local function problem_with_choice(decoded, catalogue)
  if type(decoded) ~= "table" then
    return "is not an object"
  end

  for key in pairs(decoded) do
    if not KNOWN_CHOICE[key] then
      return ("has an unknown field %q"):format(key)
    end
  end

  if decoded.schema ~= M.SCHEMA then
    return ("declares schema %s; this understands %d"):format(tostring(decoded.schema), M.SCHEMA)
  end
  if type(decoded.theme) ~= "string" or decoded.theme == "" then
    return "names no theme"
  end

  -- Checked only against a catalogue that was actually read. Nothing to check
  -- against is not the same as failing the check.
  if catalogue and not M.get(catalogue, decoded.theme) then
    return ("names %q, which this release does not offer"):format(decoded.theme)
  end

  return nil
end

---One theme out of a catalogue, or nil.
---@param catalogue table
---@param id string
---@return table|nil
function M.get(catalogue, id)
  for _, one in ipairs(catalogue.themes or {}) do
    if one.id == id then
      return one
    end
  end
  return nil
end

---Reads what this release offers.
---
---A tree without the file is not an error and not an empty catalogue: it is a
---release from before the colourscheme was a choice. `found` tells them apart.
---@param path string|nil defaults to M.catalogue_path()
---@return table|nil catalogue, boolean found, string|nil err
function M.load_catalogue(path)
  path = path or M.catalogue_path()

  local decoded, found, err = read_json(path)
  if err then
    return nil, found, err
  end
  if not found then
    return nil, false, nil
  end

  local problem = problem_with_catalogue(decoded)
  if problem then
    return nil, true, ("%s %s"):format(path, problem)
  end

  return { schema = decoded.schema, default = decoded.default, themes = decoded.themes }, true, nil
end

---Reads the choice, checked against what the release offers.
---
---A file that is not there is not an error: it is somebody who never chose, and
---the release's own default applies. `found` distinguishes that from a file
---that is there and unreadable, which is a problem to report rather than a
---licence to pick something on their behalf.
---@param path string|nil defaults to M.path()
---@param catalogue table|nil what to check the id against
---@return table|nil choice, boolean found, string|nil err
function M.load(path, catalogue)
  path = path or M.path()

  local decoded, found, err = read_json(path)
  if err then
    return nil, found, err
  end
  if not found then
    return nil, false, nil
  end

  local problem = problem_with_choice(decoded, catalogue)
  if problem then
    return nil, true, ("%s %s"):format(path, problem)
  end

  return { schema = decoded.schema, theme = decoded.theme }, true, nil
end

--- Answered once and cached, so a start costs two stats rather than two per
--- plugin spec that asks, and an unreadable document is reported once.
---@type { id: string, colorscheme: string }|nil
local resolved = nil

---@param problem string
local function complain(problem)
  vim.notify(("Chroma: %s"):format(problem), vim.log.levels.ERROR)
end

---@return { id: string, colorscheme: string }
local function resolve()
  local catalogue, _, err = M.load_catalogue()
  if err then
    complain(err)
  end

  local choice, _, choice_err = M.load(nil, catalogue)
  if choice_err then
    -- Reported and then answered with the release's own default: a colourscheme
    -- nobody can read is a reason to say so, not a reason to come up blank.
    complain(choice_err)
  end

  local id = choice and choice.theme or (catalogue and catalogue.default) or M.FALLBACK

  local one = catalogue and M.get(catalogue, id)
  if one then
    return { id = id, colorscheme = one.colorscheme }
  end

  -- No catalogue to look the name up in. The id is the best guess at the
  -- `:colorscheme` argument, and it is a guess: the two differ for catppuccin,
  -- whose plugin installs four of them under names the flavour is part of. Only
  -- reached on a tree with no themes.json, which is a broken installation.
  return { id = id, colorscheme = id }
end

---@return { id: string, colorscheme: string }
local function current()
  if resolved == nil then
    resolved = resolve()
  end
  return resolved
end

---The id this installation draws.
---@return string
function M.chosen()
  return current().id
end

---Whether this installation draws that one. What a plugin spec asks: it names
---itself, and the choice decides whether it is loaded at all.
---@param id string
---@return boolean
function M.is(id)
  return current().id == id
end

---The argument to `:colorscheme`, which is not the id.
---@return string
function M.colorscheme()
  return current().colorscheme
end

---Forgets the cached answer. For tests.
function M.forget()
  resolved = nil
end

return M
