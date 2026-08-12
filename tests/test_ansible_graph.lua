-- Reading the `ansible-inventory --graph` tree.
--
-- The fixtures under `tests/fixtures/ansible/graph/` are real output, captured
-- from ansible-core 2.21.2 rather than typed out here, because the whole point
-- of the parser is that it agrees with a program nobody in this repository
-- controls. The malformed cases are built in the test: no real Ansible produces
-- them, and that is what makes them worth checking.
--
-- Every case is about a refusal or about a name surviving intact. There is no
-- case asserting "it parsed something", because a parser that answers with half
-- an inventory is the failure this module exists to prevent
-- (`doc/chroma-ansible-design.md`, §7.3).

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local graph = require("chroma-ansible.graph")

local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")

---One fixture, byte for byte.
---
---Binary mode, then joined: a file ending in a newline gives one empty last
---item, so this reproduces the exact bytes including that newline. Reading it
---any other way would invent the trailing newline the truncation case is about.
---@param name string
---@return string
local function fixture(name)
  local path = vim.fs.joinpath(root, "tests", "fixtures", "ansible", "graph", name)
  return table.concat(vim.fn.readfile(path, "b"), "\n")
end

---The problem `read` answers with, or nil when it did not refuse.
---@param output string
---@return string|nil
local function refusal(output)
  local parsed, problem = graph.read(output)
  if parsed then
    return nil
  end
  return problem
end

local T = new_set()

-- ---------------------------------------------------------------------------
-- Real output

T["real output"] = new_set()

T["real output"]["reads groups in the order the tree names them"] = function()
  local parsed = graph.read(fixture("nested.txt"))

  eq(parsed.groups, {
    "all",
    "ungrouped",
    "webservers",
    "databases",
    "dbservers",
    "redis_servers",
    "empty_group",
    "shared",
  })
end

T["real output"]["deduplicates a host that is in two groups, and keeps both memberships"] = function()
  local parsed = graph.read(fixture("nested.txt"))

  -- web01 is in webservers and in shared.
  eq(parsed.hosts, { "standalone", "web01", "web02", "db01", "redis01" })
  eq(parsed.children.webservers.hosts, { "web01", "web02" })
  eq(parsed.children.shared.hosts, { "web01" })
end

T["real output"]["nests a group inside a group"] = function()
  local parsed = graph.read(fixture("nested.txt"))

  eq(parsed.children.databases.groups, { "dbservers", "redis_servers" })
  eq(parsed.children.databases.hosts, {})
  eq(parsed.children.dbservers.hosts, { "db01" })
end

T["real output"]["an empty group is a group with nothing in it"] = function()
  local parsed = graph.read(fixture("nested.txt"))

  eq(parsed.children.empty_group, { groups = {}, hosts = {} })
end

T["real output"]["keeps a host name that contains a space"] = function()
  local parsed = graph.read(fixture("two-sources.txt"))

  -- Real inventories have these, and a parser that took the next word would
  -- answer "host" and lose the rest without saying so.
  eq(vim.tbl_contains(parsed.hosts, "host with space"), true)
  eq(vim.tbl_contains(parsed.children.prod.hosts, "host with space"), true)
end

T["real output"]["merges several -i sources into one tree"] = function()
  local one = graph.read(fixture("nested.txt"))
  local both = graph.read(fixture("two-sources.txt"))

  eq(vim.tbl_contains(one.groups, "prod"), false)
  eq(vim.tbl_contains(both.groups, "prod"), true)
  eq(vim.tbl_contains(both.groups, "webservers"), true)
end

T["real output"]["an empty inventory is two groups and no hosts"] = function()
  local parsed = graph.read(fixture("empty.txt"))

  eq(parsed.groups, { "all", "ungrouped" })
  eq(parsed.hosts, {})
end

-- ---------------------------------------------------------------------------
-- Refusals

T["refuses"] = new_set()

T["refuses"]["--graph --vars where the variables belong to a host"] = function()
  -- The planner does not pass --vars. A host's variables print *under the host*,
  -- and a host is never a parent, so depth is what refuses this one.
  eq(refusal(fixture("with-host-vars.txt")) ~= nil, true)
end

T["refuses"]["--graph --vars where the variables belong to a group"] = function()
  -- A different case with a different guard behind it, and the reason the two
  -- fixtures are separate. A *group's* variables print directly under the
  -- group, at a depth whose parent is perfectly valid, so depth lets them
  -- through and only the `{…}` shape refuses them. Without it
  -- `{api_token = s3cr3t}` is recorded as a host and shown in a picker.
  --
  -- The fixture is a group with variables and no hosts on purpose: with hosts,
  -- their variable lines come first and the file is already refused before the
  -- group's own line is reached — which is exactly how a first attempt at this
  -- case passed while proving nothing.
  eq(refusal(fixture("with-group-vars.txt")) ~= nil, true)
end

T["refuses"]["output that stops in the middle of a line"] = function()
  -- The one truncation a parser can see. `  |  |--dns` is a perfectly good line
  -- for a host called `dns`, so the missing final newline is the only evidence.
  eq(refusal(fixture("truncated.txt")) ~= nil, true)
end

T["refuses"]["anything that is not a string"] = function()
  eq(refusal(nil) ~= nil, true)
  eq(refusal(42) ~= nil, true)
end

T["refuses"]["output that does not start with the root"] = function()
  eq(refusal("@prod:\n  |--web01\n") ~= nil, true)
  eq(refusal("") ~= nil, true)
end

T["refuses"]["a blank line in the middle"] = function()
  eq(refusal("@all:\n  |--@prod:\n\n  |  |--web01\n") ~= nil, true)
end

T["refuses"]["indentation that skips a level"] = function()
  -- Two levels deeper than the line before it. Nothing real produces this;
  -- interleaved or clipped output does.
  eq(refusal("@all:\n  |  |  |--web01\n") ~= nil, true)
end

T["refuses"]["a depth the tree has left behind"] = function()
  -- `deep` was at depth 2, then the tree came back up to depth 1 for `later`.
  -- A line at depth 3 now has no parent — unless the stack still holds the
  -- group it walked out of, which would file the host under a group it is not
  -- in. Skipping a level is the visible symptom; the stale entry is the bug.
  eq(refusal("@all:\n  |--@first:\n  |  |--@deep:\n  |--@later:\n  |  |  |--web01\n") ~= nil, true)
end

T["refuses"]["a tab where the rung should be"] = function()
  eq(refusal("@all:\n\t|--@prod:\n") ~= nil, true)
end

T["refuses"]["a group marker without its colon"] = function()
  eq(refusal("@all:\n  |--@prod\n") ~= nil, true)
end

T["refuses"]["a group with no name"] = function()
  eq(refusal("@all:\n  |--@:\n") ~= nil, true)
end

T["refuses"]["a branch with no name at all"] = function()
  eq(refusal("@all:\n  |--\n") ~= nil, true)
end

T["refuses"]["a line with no branch marker"] = function()
  eq(refusal("@all:\n  web01\n") ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- What a refusal says

T["a refusal"] = new_set()

T["a refusal"]["names the line by number and does not quote it back"] = function()
  -- §7.4: the raw output of an Ansible subprocess is never repeated by this
  -- module, and a graph line carries host names. Three spaces rather than the
  -- rung, so the line is genuinely unreadable — a control character would not
  -- do, because a name is taken verbatim and one containing `\x01` is a name.
  local problem = refusal("@all:\n  |--@prod:\n   |--secret-host.internal\n")

  eq(problem ~= nil, true)
  eq(problem:find("line 3", 1, true) ~= nil, true)
  eq(problem:find("secret-host", 1, true), nil)
end

T["a refusal"]["is not what an unusual character in a name earns"] = function()
  -- The complement of the case above, and the reason it had to be rewritten:
  -- names are taken verbatim, so oddness in one is not a parse failure. Making
  -- it printable is the preview's job, not this module's.
  --
  -- `string.char` rather than an escape: `\x01` is Lua 5.2, and while LuaJIT
  -- accepts it the linter reads this file as 5.1 and is right to.
  local odd = "host" .. string.char(1) .. "name"
  local parsed = graph.read(("@all:\n  |--@prod:\n  |  |--%s\n"):format(odd))

  eq(parsed.hosts, { odd })
end

T["a refusal"]["comes with no graph at all"] = function()
  local parsed, problem = graph.read(fixture("truncated.txt"))

  eq(parsed, nil)
  eq(type(problem), "string")
end

return T
