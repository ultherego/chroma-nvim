-- The component contract, from this configuration's side.
--
-- One file per component in `components/`, read by the Lua configuration and by
-- the Go CLI. Neither owns it. See cli/DESIGN.md for the whole arrangement and
-- why the format is JSON rather than YAML.
--
-- This module reads and validates. It does not decide what is enabled — that is
-- the installed state, which the CLI writes and which does not exist yet.

local M = {}

--- The contract version this configuration understands. A component file
--- declaring a higher one was written for a newer Chroma than this, and reading
--- it as though the difference did not matter is how the two sides drift apart
--- quietly. See cli/DESIGN.md, "The component contract".
M.CONTRACT = 5

---Dotted numbers, with an optional leading v and whatever suffix a release
---carries: 0.26.1, v1.14.3, 2.51.0-rc1.
---@param value string
---@return boolean
function M.looks_like_version(value)
  local numbers = (value:gsub("^v", "")):match("^[^-+]+") or ""
  if numbers == "" then
    return false
  end

  for part in (numbers .. "."):gmatch("([^.]*)%.") do
    if part == "" or part:match("^%d+$") == nil then
      return false
    end
  end
  return true
end

---Orders two dotted versions: -1, 0 or 1. Missing components count as zero, so
---1.2 and 1.2.0 are the same. Anything after the numbers is ignored.
---@param a string
---@param b string
---@return integer
function M.compare_versions(a, b)
  local function parts(value)
    local numbers = ((value:gsub("^%s*v?", "")):match("^[^-+]+") or "")
    local out = {}
    for part in (numbers .. "."):gmatch("([^.]*)%.") do
      table.insert(out, tonumber(part:match("^%d+")) or 0)
    end
    return out
  end

  local left, right = parts(a), parts(b)
  for i = 1, math.max(#left, #right) do
    local l, r = left[i] or 0, right[i] or 0
    if l < r then
      return -1
    elseif l > r then
      return 1
    end
  end
  return 0
end

---Where the component files live: alongside this configuration, not in state.
---Resolved from this file rather than from stdpath("config"), so it answers the
---same whether the configuration is installed, symlinked, or being tested from a
---checkout that is nobody's config directory.
---@return string
local function directory()
  local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p")
  return vim.fs.joinpath(vim.fn.fnamemodify(here, ":h:h:h"), "components")
end

--- The fields each level of the contract may carry. Anything else is a mistake
--- worth reporting rather than ignoring.
local KNOWN = {
  component = {
    contract = true,
    id = true,
    name = true,
    description = true,
    requires = true,
    tools = true,
    nvim = true,
  },
  tools = { required = true, recommended = true, optional = true },
  tool = { id = true, any = true, reason = true, version = true },
  version = { min = true, max = true },
  nvim = {
    servers = true,
    mason = true,
    linters = true,
    parsers = true,
    plugins = true,
    modules = true,
    formatters = true,
    schemas = true,
  },
}

---Whether a decoded value is a JSON array, and whether it is a JSON object.
---
---Asked of the decoder rather than guessed from the table afterwards. Measured
---on Neovim 0.12.4: `[]` decodes to a list and `{}` to `vim.empty_dict`, which
---`vim.islist` tells apart even when both are empty. Counting keys does not,
---and this file promises something stronger than "close enough" — the Go
---reader decodes into typed fields, so an object where `[]string` belongs is
---an error there, and a Lua reader that shrugs at it accepts documents the
---installer refuses.
---@param value any
---@return boolean
local function array(value)
  return type(value) == "table" and vim.islist(value)
end

---@param value any
---@return boolean
local function object(value)
  return type(value) == "table" and not vim.islist(value)
end

---Whether a decoded value is an array of non-empty strings.
---@param value any
---@param what string
---@return string|nil problem
local function string_array_problem(value, what)
  if not array(value) then
    return ("%s is not an array"):format(what)
  end
  for _, entry in ipairs(value) do
    if type(entry) ~= "string" then
      return ("%s holds %s, which is not a string"):format(what, vim.inspect(entry))
    end
    if entry == "" then
      return ("%s holds an empty name"):format(what)
    end
  end
  return nil
end

---Whether the document is shaped like a component at all.
---
---This runs before anything walks it. Everything below iterates with `pairs`
---and `ipairs`, and both of those raise on a value that is not a table —
---measured on 0.12.4: `bad argument #1 to 'ipairs' (table expected, got
---string)`. Raising is the wrong answer twice over: it is not the "component
---is invalid" this module promises to report, and it happens on the startup
---path, where the reader is called before anything has drawn a window. The Go
---side gets this free from decoding into a typed struct, which is exactly why
---it had to be written out here.
---@param decoded table
---@return string|nil problem
local function shape_problem(decoded)
  for _, field in ipairs({ "id", "name", "description" }) do
    if decoded[field] ~= nil and type(decoded[field]) ~= "string" then
      return ("%s is not a string"):format(field)
    end
  end

  if decoded.contract ~= nil and type(decoded.contract) ~= "number" then
    return "contract is not a number"
  end

  if decoded.requires ~= nil then
    local problem = string_array_problem(decoded.requires, "requires")
    if problem then
      return problem
    end
  end

  if decoded.tools ~= nil then
    if not object(decoded.tools) then
      return "tools is not an object"
    end
    for key, level in pairs(decoded.tools) do
      if type(key) ~= "string" then
        return "tools is not an object"
      end
      if not array(level) then
        return ("tools.%s is not an array"):format(key)
      end
      for _, tool in ipairs(level) do
        if not object(tool) then
          return ("tools.%s holds something that is not an object"):format(key)
        end
        if tool.any ~= nil then
          local problem = string_array_problem(tool.any, ("tools.%s[].any"):format(key))
          if problem then
            return problem
          end
        end
        if tool.version ~= nil and not object(tool.version) then
          return ("tools.%s[].version is not an object"):format(key)
        end
      end
    end
  end

  if decoded.nvim ~= nil then
    if not object(decoded.nvim) then
      return "nvim is not an object"
    end
    for key, list in pairs(decoded.nvim) do
      if type(key) ~= "string" then
        return "nvim is not an object"
      end
      local problem = string_array_problem(list, ("nvim.%s"):format(key))
      if problem then
        return problem
      end
    end
  end

  return nil
end

---The first field name that does not belong, anywhere in the component.
---@param decoded table
---@return string|nil
local function unknown_fields(decoded)
  for key in pairs(decoded) do
    if not KNOWN.component[key] then
      return key
    end
  end

  for key, level in pairs(decoded.tools or {}) do
    if not KNOWN.tools[key] then
      return ("tools.%s"):format(key)
    end
    for _, tool in ipairs(level) do
      for field in pairs(tool) do
        if not KNOWN.tool[field] then
          return ("tools.%s[].%s"):format(key, field)
        end
      end
      for field in pairs(tool.version or {}) do
        if not KNOWN.version[field] then
          return ("tools.%s[].version.%s"):format(key, field)
        end
      end
    end
  end

  for key in pairs(decoded.nvim or {}) do
    if not KNOWN.nvim[key] then
      return ("nvim.%s"):format(key)
    end
  end

  return nil
end

---Whether a version constraint says one thing, and says it in numbers.
---The rules are the Go reader's, because a contract with two meanings has none.
---
---`min` and `max` are compatibility boundaries: the earliest version known to
---work, and the latest, the second only where a real incompatibility was found.
---Neither says which version Chroma would prefer. Contract 5 removed `exact`
---because it was the one way to write "the machine must run this release" about
---a tool that belongs to the user, so `exact` now fails as an unknown field.
---@param version table|nil
---@return string|nil problem
local function version_problem_of(version)
  if version == nil then
    return nil
  end
  if type(version) ~= "table" then
    return "is not an object"
  end

  local min, max = version.min, version.max
  if not min and not max then
    return "says nothing"
  end

  for name, value in pairs({ min = min, max = max }) do
    if type(value) ~= "string" or not M.looks_like_version(value) then
      return ("has a %s that is not a version: %s"):format(name, vim.inspect(value))
    end
  end

  if min and max and M.compare_versions(min, max) > 0 then
    return ("has min %s above max %s"):format(min, max)
  end

  return nil
end

---Whether every tool names exactly one thing to look for.
---@param tools table|nil
---@return string|nil problem
local function tool_problem(tools)
  for _, level in ipairs({ "required", "recommended", "optional" }) do
    for _, tool in ipairs((tools or {})[level] or {}) do
      local named = type(tool.id) == "string" and tool.id ~= ""
      local alternatives = type(tool.any) == "table" and #tool.any > 0

      -- Exactly one, not at least one: with both set a reader picks a winner and
      -- drops the other, and whoever wrote the file never finds out.
      if named and alternatives then
        return ("has a %s tool with both id and any"):format(level)
      end
      if not named and not alternatives then
        return ("has a %s tool with neither id nor any"):format(level)
      end
      if type(tool.reason) ~= "string" or tool.reason == "" then
        return ("has a %s tool with no reason"):format(level)
      end
      for _, name in ipairs(tool.any or {}) do
        if name == "" then
          return ("has a %s tool with an empty name in any"):format(level)
        end
      end

      local version_problem = version_problem_of(tool.version)
      if version_problem then
        return ("has a %s tool whose version %s"):format(level, version_problem)
      end
    end
  end

  return nil
end

---@param path string
---@return table|nil component, string|nil err
local function read_one(path)
  local ok, contents = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, ("could not be read: %s"):format(contents)
  end

  local decoded
  ok, decoded = pcall(vim.json.decode, table.concat(contents, "\n"))
  if not ok then
    return nil, "is not valid JSON"
  end
  -- A bare string parses, and so does a top-level array; neither is a
  -- component, and saying "is not valid JSON" about a file whose JSON is fine
  -- sends somebody looking for a syntax error that is not there.
  if not object(decoded) then
    return nil, "is not a JSON object"
  end

  -- Before anything walks it: see shape_problem.
  local shape = shape_problem(decoded)
  if shape then
    return nil, shape
  end

  if type(decoded.id) ~= "string" or decoded.id == "" then
    return nil, "has no id"
  end

  -- Strict, and for the same reason the Go reader is: `require` written for
  -- `requires` decodes cleanly and leaves a component with no dependencies,
  -- which is the worst way to be wrong about a file that decides what an
  -- installer installs.
  local unknown = unknown_fields(decoded)
  if unknown then
    return nil, ("has an unknown field %q"):format(unknown)
  end

  local tools_problem = tool_problem(decoded.tools)
  if tools_problem then
    return nil, tools_problem
  end

  if decoded.contract ~= M.CONTRACT then
    return nil,
      ("declares contract %s; this configuration understands %d"):format(tostring(decoded.contract), M.CONTRACT)
  end

  -- Absent lists are read as empty ones, so callers never branch on nil.
  decoded.requires = decoded.requires or {}
  decoded.tools = decoded.tools or {}
  decoded.tools.required = decoded.tools.required or {}
  decoded.tools.recommended = decoded.tools.recommended or {}
  decoded.tools.optional = decoded.tools.optional or {}
  decoded.nvim = decoded.nvim or {}

  return decoded
end

--- Read once and kept: the contract ships with the release and does not change
--- while Neovim is running. Measured before it was added: 0.197 ms per read,
--- and a startup asks eight times — parsers, linters, Mason, servers,
--- formatters, schemas and the plugin specs — which is 1.6 ms of a budget the
--- whole configuration keeps at about 26.
---@type { components: table<string, table>, problems: string[] }|nil
local loaded = nil

---Forgets the contract, so the next read goes back to the files. For tests, and
---for `:checkhealth chroma`, which is somebody looking at the contract and is
---the one moment a cached copy would be the wrong answer: this repository is
---also somebody's configuration directory, so the files can be edited in the
---session that is reading them.
function M.forget()
  loaded = nil
end

---Every component this configuration ships, keyed by id.
---@return table<string, table> components, string[] problems
function M.load()
  if loaded then
    return loaded.components, loaded.problems
  end

  local components, problems = {}, {}

  local dir = directory()
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.json$") then
      local component, err = read_one(vim.fs.joinpath(dir, name))
      if component then
        if components[component.id] then
          table.insert(problems, ("%s: id %q is already declared elsewhere"):format(name, component.id))
        else
          components[component.id] = component
        end
      else
        table.insert(problems, ("%s %s"):format(name, err))
      end
    end
  end

  loaded = { components = components, problems = problems }
  return components, problems
end

---Every component id this configuration ships, sorted. The answer to "what does
---legacy mean", which is: all of it.
---@return string[]
function M.load_ids()
  local ids = vim.tbl_keys(M.load())
  table.sort(ids)
  return ids
end

---Whether the set resolves: every dependency exists, and nothing depends on
---itself through any path. A contract that does not resolve is a broken
---installation plan, so it is worth saying so where someone will read it.
---@param components table<string, table>
---@return string[] problems
function M.resolve_problems(components)
  local problems = {}

  for id, component in pairs(components) do
    for _, needed in ipairs(component.requires) do
      if not components[needed] then
        table.insert(problems, ("%s requires %q, which is not declared"):format(id, needed))
      end
    end
  end

  -- Depth-first, colouring as it goes: grey means "on the current path", so
  -- meeting grey again is a cycle rather than a diamond.
  local colour = {}
  local function visit(id, trail)
    if colour[id] == "black" then
      return
    end
    if colour[id] == "grey" then
      table.insert(problems, ("dependency cycle: %s"):format(table.concat(trail, " -> ")))
      return
    end

    colour[id] = "grey"
    for _, needed in ipairs((components[id] or { requires = {} }).requires) do
      if components[needed] then
        table.insert(trail, needed)
        visit(needed, trail)
        table.remove(trail)
      end
    end
    colour[id] = "black"
  end

  -- Sorted, so the same broken contract reports the same problem every time.
  local ids = vim.tbl_keys(components)
  table.sort(ids)
  for _, id in ipairs(ids) do
    visit(id, { id })
  end

  return problems
end

---Every tool a component needs, flattened, with the level it was listed at.
---@param component table
---@return table[] tools each { names = string[], level = string, reason = string }
function M.tools(component)
  local tools = {}
  for _, level in ipairs({ "required", "recommended", "optional" }) do
    for _, tool in ipairs(component.tools[level] or {}) do
      table.insert(tools, {
        names = tool.any or { tool.id },
        level = level,
        reason = tool.reason or "",
        version = tool.version,
      })
    end
  end
  return tools
end

---Everything the enabled components contribute of one kind, deduplicated and
---sorted. The answer to "which servers should be enabled", asked once per kind
---rather than by each spec inventing its own filter.
---@param kind string one of servers, mason, linters, parsers, formatters, schemas, plugins, modules
---@param enabled string[] component ids
---@return string[]
function M.contributions(kind, enabled)
  local set = M.load()
  local seen, out = {}, {}

  for _, id in ipairs(enabled) do
    for _, name in ipairs(((set[id] or {}).nvim or {})[kind] or {}) do
      if not seen[name] then
        seen[name] = true
        table.insert(out, name)
      end
    end
  end

  table.sort(out)
  return out
end

---Whether any of `enabled` contributes `name` as `kind`.
---
---The question a plugin spec has, which is not "is component X on" but "does
---anything switched on bring this plugin". Asking it this way is what keeps the
---relation in one place: `components/kubernetes.json` says kubectl.nvim is
---Kubernetes', and the spec repeats the plugin's own name rather than repeating
---the mapping.
---@param kind string one of servers, mason, linters, parsers, formatters, schemas, plugins, modules
---@param name string
---@param enabled string[] component ids
---@return boolean
function M.contributes(kind, name, enabled)
  local set = M.load()

  for _, id in ipairs(enabled) do
    for _, contributed in ipairs(((set[id] or {}).nvim or {})[kind] or {}) do
      if contributed == name then
        return true
      end
    end
  end

  return false
end

---Whether any of a tool's accepted names is on PATH.
---
---Presence only. Whether the version meets the contract is checked by `chroma
---doctor`, which owns the knowledge of how to ask each executable what it is;
---duplicating that here would be a second registry to keep in step. The health
---check says so rather than implying it has checked.
---@param tool table
---@return boolean
function M.satisfied(tool)
  for _, name in ipairs(tool.names) do
    if vim.fn.executable(name) == 1 then
      return true
    end
  end
  return false
end

return M
