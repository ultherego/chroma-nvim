-- The `ansible-inventory --graph` text tree, and nothing else: handed one
-- subprocess's exact stdout, this answers with groups, hosts and who is inside
-- whom, or with one problem naming the line it could not read (design §7).
--
-- `--graph`, not `--list`: `--list` returns every host variable in plaintext and
-- no flag suppresses them (§7.1). All or nothing (§7.3), because a graph missing
-- some groups looks exactly like a small inventory.
--
-- Measured against 2.21.2: indentation is two spaces, then one `|  ` per level,
-- then `|--`; and a host name may contain spaces, so a name is the rest of the
-- line.

local M = {}

--- The root every graph starts with. Verified on 2.21.2: present even for an
--- empty inventory, which answers `@all:` and `@ungrouped:` and nothing else.
local ROOT = "@all:"

--- The name of that root once the decoration is off.
local ALL = "all"

---Splits one graph line into its depth, its name and its kind. A scan rather
---than one pattern: Lua has no non-capturing groups, and a repeated capture
---answers with its last match rather than its count.
---@param line string
---@return integer|nil depth, string|nil name, boolean|nil is_group
local function dissect(line)
  if not vim.startswith(line, "  ") then
    return nil
  end

  local index = 3
  local depth = 1
  while line:sub(index, index + 2) == "|  " do
    depth = depth + 1
    index = index + 3
  end

  if line:sub(index, index + 2) ~= "|--" then
    return nil
  end

  -- The rest of the line, verbatim: `host with space` is a real answer from a
  -- real inventory, and splitting on whitespace would rename it.
  local name = line:sub(index + 3)
  if name == "" then
    return nil
  end

  if vim.startswith(name, "@") then
    -- A group is `@name:`. An `@` without the colon is a shape this parser
    -- does not know, and guessing is what §7.3 forbids.
    if not vim.endswith(name, ":") then
      return nil
    end
    local group = name:sub(2, -2)
    if group == "" then
      return nil
    end
    return depth, group, true
  end

  -- Anything else is a host, including a name with a colon in it. The one
  -- exception is a variable line from `--graph --vars`, which the planner never
  -- passes. Measured on 2.21.2 and not belt and braces: a host's variables
  -- print under the host, which depth refuses anyway, but a *group's* print at
  -- a depth whose parent is valid — without this, `{api_token = s3cr3t}` would
  -- be recorded as a host and shown in a picker.
  if vim.startswith(name, "{") and vim.endswith(name, "}") then
    return nil
  end

  return depth, name, false
end

---@class chroma_ansible.Graph
---@field groups string[] every group, in the order the tree first names it
---@field hosts string[] every host, deduplicated, in the order first seen
---@field children table<string, { groups: string[], hosts: string[] }>

---Reads one `--graph` output.
---
---@param output string the exact stdout of `ansible-inventory --graph`
---@return chroma_ansible.Graph|nil graph, string|nil problem
function M.read(output)
  if type(output) ~= "string" then
    return nil, "inventory inspection produced no output"
  end

  -- Measured on 2.21.2: every graph ends with a newline, including an empty
  -- inventory's. Output that does not stopped mid-line, and a name cut in half
  -- parses perfectly as a shorter name, so this is the only place that can be
  -- caught. A cut landing on a line boundary is not caught; §7.3 says so.
  if output ~= "" and not vim.endswith(output, "\n") then
    return nil, "the inventory graph ends mid-line, so the output is incomplete"
  end

  local lines = vim.split(output, "\n", { plain = true })

  -- The trailing newline is one empty last element. Only trailing blanks are
  -- dropped: a blank line in the middle is output this parser does not
  -- recognise.
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end

  if #lines == 0 then
    return nil, "the inventory graph is empty"
  end
  if lines[1] ~= ROOT then
    return nil, ("the inventory graph does not start with %q"):format(ROOT)
  end

  local graph = { groups = {}, hosts = {}, children = {} }
  local seen_group, seen_host = {}, {}

  ---Records a group once, keeping first-seen order.
  ---@param name string
  local function add_group(name)
    if not seen_group[name] then
      seen_group[name] = true
      table.insert(graph.groups, name)
      graph.children[name] = { groups = {}, hosts = {} }
    end
  end

  add_group(ALL)

  -- Which group each depth is inside. Depth 0 is the root, so a line at depth 1
  -- belongs to `all`.
  local stack = { [0] = ALL }
  local deepest = 0

  for index = 2, #lines do
    local depth, name, is_group = dissect(lines[index])

    if not depth then
      -- Named by position, never quoted back: a subprocess's raw output is not
      -- repeated (§7.4), and a graph line carries host names.
      return nil, ("the inventory graph could not be read: line %d is not a group or a host"):format(index)
    end

    local parent = stack[depth - 1]
    if not parent then
      -- Real output never skips a level; truncated or interleaved output does.
      return nil, ("the inventory graph could not be read: line %d is indented past its parent"):format(index)
    end

    if is_group then
      add_group(name)
      table.insert(graph.children[parent].groups, name)
      stack[depth] = name

      -- What a previous, deeper subtree left on the stack is not this line's
      -- parent chain; clearing it is what makes "indented past its parent"
      -- detectable rather than resolving to a stale group.
      for below = depth + 1, deepest do
        stack[below] = nil
      end
      deepest = depth
    else
      if not seen_host[name] then
        seen_host[name] = true
        table.insert(graph.hosts, name)
      end
      -- A host may appear in several groups, and every membership is real.
      table.insert(graph.children[parent].hosts, name)

      -- A host is not a parent, so neither this depth nor anything under it can
      -- name one. Without this, a group left on the stack by an earlier, deeper
      -- subtree stayed reachable: a line indented under a *host* resolved to
      -- that group and was recorded as a member of it, where §7.3 wants the
      -- whole graph refused.
      for below = depth, deepest do
        stack[below] = nil
      end
      deepest = depth - 1
    end
  end

  return graph, nil
end

return M
