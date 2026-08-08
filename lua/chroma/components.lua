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
M.CONTRACT = 1

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
  tool = { id = true, any = true, reason = true },
  nvim = { modules = true, plugins = true },
}

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
    end
  end

  for key in pairs(decoded.nvim or {}) do
    if not KNOWN.nvim[key] then
      return ("nvim.%s"):format(key)
    end
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
  if not ok or type(decoded) ~= "table" then
    return nil, "is not valid JSON"
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

---Every component this configuration ships, keyed by id.
---@return table<string, table> components, string[] problems
function M.load()
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

  return components, problems
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
      })
    end
  end
  return tools
end

---Whether any of a tool's accepted names is on PATH.
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
