-- The `ansible-inventory --graph` text tree, and nothing else.
--
-- This is the first half of inventory inspection and touches nothing: it is
-- handed the exact stdout of one subprocess and answers with the groups, the
-- hosts and who is inside whom — or with one problem naming the line it could
-- not read. It starts no process, reads no file, and knows no Ansible semantics
-- beyond the shape of this one output. The rules are
-- `doc/chroma-ansible-design.md`, section 7.
--
-- **`--graph`, not `--list`.** `--list` returns every host variable in
-- plaintext and no flag suppresses them, so the planner never asks for it
-- (§7.1). That is why this parser exists at all: carrying somebody else's text
-- format is a real maintenance cost, taken deliberately over the promise "we
-- read every secret and will never print one by accident".
--
-- **All or nothing** (§7.3). One unreadable line discards the whole tree. A
-- graph that parses to some of the groups looks exactly like a small inventory,
-- and the operator would pick a limit from a list quietly missing the group
-- they were looking for.
--
-- Measured against ansible-core 2.21.2, with the fixtures in
-- `tests/fixtures/ansible/`:
--
--     @all:
--       |--@ungrouped:
--       |  |--standalone
--       |--@databases:
--       |  |--@dbservers:
--       |  |  |--db01
--
-- Two properties of that output decide the code below. Indentation is exactly
-- two spaces, then one `|  ` per level, then `|--`; and **a host name may
-- contain spaces** — `host with space` came back from a real inventory — so a
-- name is the rest of the line, never the next whitespace-separated word.

local M = {}

--- The root every graph starts with. Verified on 2.21.2: present even for an
--- empty inventory file, which answers `@all:` and `@ungrouped:` and nothing
--- else.
local ROOT = "@all:"

--- The name of that root once the decoration is off.
local ALL = "all"

---Splits one graph line into its depth, its name and its kind.
---
---A scan rather than one pattern: Lua has no non-capturing groups, and a
---repeated capture answers with its last match rather than its count.
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

  -- The rest of the line, verbatim. Not a word: `host with space` is a real
  -- answer from a real inventory, and splitting on whitespace would silently
  -- rename it.
  local name = line:sub(index + 3)
  if name == "" then
    return nil
  end

  if vim.startswith(name, "@") then
    -- A group is `@name:`. An `@` without the colon is a shape this parser does
    -- not know, and guessing at it is what §7.3 forbids.
    if not vim.endswith(name, ":") then
      return nil
    end
    local group = name:sub(2, -2)
    if group == "" then
      return nil
    end
    return depth, group, true
  end

  -- Anything else is a host, including a name with a colon in it, which Ansible
  -- allows and which is not this parser's business to reject. The one exception
  -- is a variable line from `--graph --vars`: the planner never passes `--vars`,
  -- so one appearing here means this is not the output that was asked for.
  --
  -- This guard is not belt and braces. Measured on 2.21.2: a *host's* variables
  -- print under the host, which is never a valid parent, so depth refuses them
  -- anyway — but a *group's* variables print directly under the group, at a
  -- depth whose parent is perfectly valid. Without this line
  -- `{api_token = s3cr3t}` would be recorded as a host and shown in a picker.
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

  -- Measured on 2.21.2: every graph ends with a newline, including the one an
  -- empty inventory produces. Output that does not is output that stopped in
  -- the middle of a line — and a name cut in half parses perfectly as a shorter
  -- name, so this is the only place that case can be caught. What it does not
  -- catch is a cut that lands exactly on a line boundary; §7.3 says so rather
  -- than implying the parser sees every truncation.
  if output ~= "" and not vim.endswith(output, "\n") then
    return nil, "the inventory graph ends mid-line, so the output is incomplete"
  end

  local lines = vim.split(output, "\n", { plain = true })

  -- The trailing newline is one empty last element. Only trailing blanks are
  -- dropped: a blank line in the middle is output this parser does not
  -- recognise, and recognising it loosely is how a truncated tree gets read as
  -- a complete one.
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

  -- Which group each depth is currently inside. Depth 0 is the root, so a line
  -- at depth 1 belongs to `all`.
  local stack = { [0] = ALL }
  local deepest = 0

  for index = 2, #lines do
    local depth, name, is_group = dissect(lines[index])

    if not depth then
      -- Named by position, never quoted back. The raw output of an Ansible
      -- subprocess is not something this module repeats (§7.4), and a line of a
      -- graph carries host names somebody may consider private.
      return nil, ("the inventory graph could not be read: line %d is not a group or a host"):format(index)
    end

    local parent = stack[depth - 1]
    if not parent then
      -- More than one level deeper than the line before it. Real output never
      -- does this; truncated or interleaved output does.
      return nil, ("the inventory graph could not be read: line %d is indented past its parent"):format(index)
    end

    if is_group then
      add_group(name)
      table.insert(graph.children[parent].groups, name)
      stack[depth] = name

      -- Whatever a previous, deeper subtree left on the stack is not this
      -- line's parent chain. Clearing it is what makes "indented past its
      -- parent" detectable at all rather than resolving to a stale group.
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
      if depth > deepest then
        deepest = depth
      end
    end
  end

  return graph, nil
end

return M
